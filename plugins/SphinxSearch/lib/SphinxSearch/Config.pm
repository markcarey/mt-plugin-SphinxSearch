
package SphinxSearch::Config;

use strict;
use warnings;

use List::Util qw( max );
use MT::Util qw( ts2epoch epoch2ts encode_html );

sub _get_data_rows {
	my ($class, $index_type) = @_;
	
	require SphinxSearch::Index;
    my %indexes = %{SphinxSearch::Index::_get_sphinx_indexes()};

    my $index_hash = $indexes{$class};
	die "Unsupported index $class" if(!$index_hash);
	
    my $source = $index_hash->{class}->datasource;
	$class = $index_hash->{class};
	eval("use $class");

	my %args;
	if($index_type eq 'delta') {		
		
        if ( my $delta = $index_hash->{delta} ) {
            if ( exists $index_hash->{date_columns}->{$delta} ) {
                $args{sort} = $delta;
				$args{start_val} = epoch2ts(undef, time - (36*60*60)); # 36 hours prior to current
            }
        }
	}
	my %terms;
    if ( my $sel_values = $index_hash->{select_values} ) {
		@terms{keys %$sel_values} = values %$sel_values;
    }
	my @objs = $class->load(\%terms, \%args);

	use String::CRC32 qw( crc32 );
	
	my @docs_loop;
	foreach my $obj (@objs) {
		
		my @group_fields;
		my @string_fields;
		my @date_fields;
		my @mva_fields;
		my @normal_fields;

		foreach(@{ $index_hash->{columns}}) {
			my %tmp_field;
			$tmp_field{key} = $_;
			$tmp_field{value} = encode_html($obj->$_);
			
			if ($index_hash->{date_columns}->{$_}) {
				my $blog = undef;
                $blog = $class->has_column('blog_id')? MT::Blog->load($obj->blog_id): MT::Blog->load(0);
				$tmp_field{value} = ts2epoch($blog, $tmp_field{value});
				
				push @date_fields, \%tmp_field;

			} elsif ($index_hash->{string_group_columns}->{$_}) {

				$tmp_field{key} = $_."_crc32";
				$tmp_field{value} = $obj->$_?crc32($obj->$_):'';
				push @string_fields, \%tmp_field;
				
			} elsif ($index_hash->{group_columns}->{$_}) {
				push @group_fields, \%tmp_field;

			} else {
				push @normal_fields, \%tmp_field;
			}
		}

		if ($index_hash->{mva}) {
			
            foreach my $mva ( keys %{ $index_hash->{mva} } ) {

                my $cur_mva = $index_hash->{mva}->{$mva};

				my %terms;
				my $mva_key = "id";
                if ( my $sel_values = $cur_mva->{select_values} ) {	
					@terms{keys %$sel_values} = values %$sel_values;
				}
				if( my $id_columns = $cur_mva->{by} ) {
					$terms{$id_columns->[0]} = $obj->id;
					$mva_key = $id_columns->[1];
				} else {
					%terms = ( "${mva}_".$index_hash->{id_column} => $obj->id );
				}
				
				my $mva_source = $cur_mva->{with};
				next if(!$mva_source || $mva_source eq '');
				
				eval("use $mva_source");

				my @mva_value;
				my @mva_vals = $mva_source->load( \%terms );
				foreach(@mva_vals) {
					push @mva_value, $_->$mva_key;
				}

				my %tmp_field;
				$tmp_field{key} = $mva;				
				$tmp_field{value} = join(',',@mva_value);

				push @mva_fields, \%tmp_field;
            }
		}

		my %temp_obj;
		$temp_obj{docid} = $obj->id;
		$temp_obj{group_loop} = \@group_fields;
		$temp_obj{string_group_loop} = \@string_fields;
		$temp_obj{date_loop} = \@date_fields;
		$temp_obj{mva_loop} = \@mva_fields;
		$temp_obj{field_loop} = \@normal_fields;

		push @docs_loop, \%temp_obj;
	}
	\@docs_loop;
}

sub _get_sphinx_xml_stream {

    require MT::Request;
    my $r             = MT::Request->instance;
    my $class    = $r->stash('index_class');
    my $index_type = $r->stash('index_type');
	
	$index_type = 'delta' if($index_type eq '');
	
    my $plugin = MT->component('sphinxsearch');

    my $app = MT->instance;
	my $tmpl = $plugin->load_tmpl('xmlpipe.tmpl') or die $plugin->errstr;
    my %params;

    $params{tmp}     = $app->{cfg}->TempDir;
    $params{file_path} =
         $plugin->get_config_value( 'sphinx_file_path', 'system' )
      || $app->{cfg}->TempDir;
    $params{charset_type} =
      $plugin->get_config_value( 'charset_type', 'system' ) || 'utf-8';

	#Get pluggable data
	$params{'document_loop'} = _get_data_rows($class, $index_type);
	$params{'lt'} = "<";
	$params{'gt'} = ">";
	
    $tmpl->param( \%params );
    $tmpl;
}

sub _get_source_config {
	my $return_agent = shift;
	my $return_body = shift;

	return if(!ref($return_agent));
	$return_body = 'source_loop' if $return_body eq '';
	
    my %info_query;
    my %delta_query;
    my %delta_pre_query;
    my %query;
    my %mva;
    my %counts;
    my %field_loop;

    require SphinxSearch::Index;
    my %indexes = %{SphinxSearch::Index::_get_sphinx_indexes()};
    foreach my $index ( keys %indexes ) {
        my $index_hash = $indexes{$index};
        my $source     = $index_hash->{class}->datasource;

        # build any count columns first
        if ( my $counts = $index_hash->{count_columns} ) {
            for my $count ( keys %$counts ) {
                my $what_class  = $counts->{$count}->{what};
                my $with_column = $counts->{$count}->{with};
                my $wheres      = $counts->{$count}->{select_values};
                eval("require $what_class;");
                next if ($@);

                my $what_ds = $what_class->datasource;
                my $count_query =
"SELECT count(*) from mt_$what_ds WHERE ${what_ds}_$with_column = ${source}_"
                  . $index_hash->{id_column};
                if ($wheres) {
                    $count_query .= ' AND '
                      . join( ' AND ',
                        map { "${what_ds}_$_ = \"" . $wheres->{$_} . "\"" }
                          keys %$wheres );
                }
                $counts{$index}->{$count} = $count_query;
            }
        }

        # build main query
        $query{$index} = "SELECT " . join(
            ", ",
            map {
                $index_hash->{date_columns}->{$_}
                  ? 'UNIX_TIMESTAMP(' . $source . '_' . $_ . ') as ' . $_
                  : $index_hash->{group_columns}->{$_}
                  ? "${source}_$_ as " . $index_hash->{group_columns}->{$_}
                  : $index_hash->{string_group_columns}->{$_}
                  ? ( $source . '_' . $_, "CRC32(${source}_$_) as ${_}_crc32" )
                  : $counts{$index}->{$_}
                  ? "(" . $counts{$index}->{$_} . ") as $_"
                  : $source . '_'
                  . $_
              } (
                $index_hash->{id_column},
                @{ $index_hash->{columns} },
                keys %{ $counts{$index} }
              )
        ) . " FROM mt_$source";
        if ( my $sel_values = $index_hash->{select_values} ) {
            $query{$index} .= " WHERE "
              . join( " AND ",
                map { "${source}_$_ = \"" . $sel_values->{$_} . "\"" }
                  keys %$sel_values );
        }

        # build info query
        $info_query{$index} =
            "SELECT * from mt_$source where ${source}_"
          . $index_hash->{id_column}
          . ' = $id';

        # build multi-value attributes
        if ( $index_hash->{mva} ) {
            foreach my $mva ( keys %{ $index_hash->{mva} } ) {
                my $cur_mva = $index_hash->{mva}->{$mva};
                my $mva_query;
                if ( ref($cur_mva) ) {
                    if (!$cur_mva->{query}) {
						eval("use ".$cur_mva->{with});
                        my $mva_source = $cur_mva->{with}->datasource;
                        $mva_query = "SELECT "
                          . join( ', ',
                            map { "${mva_source}_$_" } @{ $cur_mva->{by} } )
                          . " from mt_"
                          . $mva_source;
                        if ( my $sel_values = $cur_mva->{select_values} ) {
                            $mva_query .= " WHERE " . join(
                                " AND ",
                                map {
                                    "${mva_source}_$_ = \""
                                      . $sel_values->{$_} . "\""
                                  } keys %$sel_values
                            );
                        }                        
                    }
                    else {
                        $mva_query = $cur_mva->{query};
                    }
                }
                else {
                    $mva_query = $cur_mva;
                }
                push @{ $mva{$index} },
                  { mva_query => $mva_query, mva_name => $mva };
            }
        }

        # build delta query
        if ( my $delta = $index_hash->{delta} ) {
            $delta_query{$index} = $query{$index};
            $delta_query{$index} .=
              $indexes{$index}->{select_values} ? " AND " : " WHERE ";
            if ( exists $index_hash->{date_columns}->{$delta} ) {
                $delta_pre_query{$index} =
                  'set @cutoff = date_sub(NOW(), INTERVAL 36 HOUR)';
                $delta_query{$index} .= "${source}_${delta} > \@cutoff";
            }
        }

		# setup the default fields and then strip them
		my %fields;
		@fields{($index_hash->{id_column}, @{ $index_hash->{columns} })} = ($index_hash->{id_column}, @{ $index_hash->{columns} });
		foreach( keys %fields ) {
			delete $fields{$_} if ($index_hash->{date_columns}->{$_});
			delete $fields{$_} if ($index_hash->{group_columns}->{$_});
			delete $fields{$_} if ($index_hash->{string_group_columns}->{$_});
		}
		$field_loop{$index} = \%fields;
    }

	$return_agent->{$return_body} = [
        map {
            {
                index        => $_,
                  source     => $indexes{$_}->{class}->datasource,
                  query      => $query{$_},
                  info_query => $info_query{$_},
                  group_loop => [
                    map { { group_column => $_ } } (
                        values %{ $indexes{$_}->{group_columns} },
                        keys %{ $counts{$_} }
                    )
                  ],
                  string_group_loop => [
                    map { { string_group_column => $_ } }
                      keys %{ $indexes{$_}->{string_group_columns} }
                  ],
                  date_loop => [
                    map { { date_column => $_ } }
                      keys %{ $indexes{$_}->{date_columns} }
                  ],
                  field_loop => [
                    map { { field_column => $_ } }
                      keys %{$field_loop{$_}}
                  ],
                  delta_pre_query => $delta_pre_query{$_},
                  delta_query     => $delta_query{$_},
                  mva_loop        => $mva{$_} || [],
            }
          }
          keys %indexes
    ];

}

sub _gen_sphinx_conf_tmpl {
    my $plugin = MT->component('sphinxsearch');
    my $conf_type = $plugin->get_config_value( 'sphinx_conf_type', 'system' ) || '';

    my $app = MT->instance;
	my $tmpl = '';
    my %params;

	if($conf_type eq '' || $conf_type !~ /xml/ ) {
		$tmpl = $plugin->load_tmpl('sphinx.conf.tmpl') or die $plugin->errstr;
	    $params{db_host} = $plugin->get_config_value( 'db_host', 'system' )
	      || $app->{cfg}->DBHost;
	    $params{db_user} = $plugin->get_config_value( 'db_user', 'system' )
	      || $app->{cfg}->DBUser;
	    my $db_pass = $plugin->get_config_value( 'db_pass', 'system' )
	      || $app->{cfg}->DBPassword;
	    $db_pass =~ s/#/\\#/g if ($db_pass);
	    $params{db_pass} = $db_pass;
	    $params{db_db}   = $app->{cfg}->Database;

	} else {
		$tmpl = $plugin->load_tmpl('sphinx.xpipe.conf.tmpl') or die $plugin->errstr if($conf_type ne '' && $conf_type =~ /xml/ );
	}

    $params{searchd_port} =
      $plugin->get_config_value( 'searchd_port', 'system' );

    $params{tmp}     = $app->{cfg}->TempDir;
    $params{file_path} =
         $plugin->get_config_value( 'sphinx_file_path', 'system' )
      || $app->{cfg}->TempDir;
    $params{pid_path} = $plugin->_pid_path;
    $params{morphology} =
      $plugin->get_config_value( 'index_morphology', 'system' ) || 'none';
    $params{min_word_len} =
      $plugin->get_config_value( 'min_word_len', 'system' ) || '1';
    $params{charset_type} =
      $plugin->get_config_value( 'charset_type', 'system' ) || 'utf-8';
    $params{mtinstallpath} =
      $app->{cfg}->installpath || '/MISSING/PATH/TO/MT/INSTALL/BASE';

    require MT::Entry;
    my @num_entries = ();
    my $iter = MT::Entry->count_group_by( { status => MT::Entry::RELEASE() },
        { group => ['blog_id'] } );
    my $entry_count;
    push @num_entries, $entry_count while ( ($entry_count) = $iter->() );
    my $max_entries = scalar @num_entries ? int( 1.5 * max @num_entries ) : 0;
    $params{max_matches} = $max_entries > 1000 ? $max_entries : 1000;

	#Get pluggable data
	_get_source_config(\%params, "source_loop");
	
    $tmpl->param( \%params );
    $tmpl;
}

sub gen_sphinx_conf {
    my $app	= shift;
	my $q = $app->{query};

    my $plugin = MT->component('sphinxsearch');

	my $conf_type = $q->param ('type') || $plugin->get_config_value( 'sphinx_conf_type', 'system' );
    $plugin->set_config_value( 'sphinx_conf_type', $conf_type, 'system' );

    my $tmpl   = &_gen_sphinx_conf_tmpl;

    my $str = $app->build_page($tmpl);
    die $app->errstr if ( !$str );
    $app->{no_print_body} = 1;
    $app->set_header(
        "Content-Disposition" => "attachment; filename=sphinx.conf" );
    $app->send_http_header('text/plain');
    $app->print($str);
}

1;
