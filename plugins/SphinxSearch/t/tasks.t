
use lib 't/lib', 'lib', 'extlib';
use Test::More tests => 16;
use Test::Exception;
use Test::Deep;

use Data::Dumper;

use strict;
use warnings;

use MT::Test qw(:cms);

my $fail = 1;
my @args;

use MT;
# use MT::App;
my $mt = MT->instance or die MT->errstr;

require_ok('SphinxSearch::Worker::Indexer');
{
    local $SIG{__WARN__} = sub {};
    *SphinxSearch::Worker::Indexer::run_cmd = sub {
        @args = @_;
        shift @args; # don't need the first one
        return $fail ? $fail : $_[0]->error ("Testing!");
    };
}

my $plugin = MT->component('sphinxsearch');
ok ($plugin, "Load the plugin instance");

SKIP:
{
    # skip them all unless we're using the tasks
    skip "Sphinx tasks are not being used", 14 unless MT->config->UseSphinxTasks;
    
    # first, let's test start_indexer
    ok ( $plugin->start_indexer, 'start_indexer should return true if launching succeeds' );

    $fail = 0;
    ok (!$plugin->start_indexer, 'start_indexer should return false if launching fails');

    $fail = 1;

    $plugin->start_indexer;
    my @indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
    cmp_bag (\@indexes, [qw( entry_index comment_index tag_index )], "Entry, comment and tag indexes present for unspecified indexer");

    $plugin->start_indexer ('delta');
    @indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
    cmp_bag (\@indexes, [qw( entry_delta_index comment_delta_index )], "Entry and comment delta indexes present");

    $plugin->start_indexer ('all');
    @indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
    cmp_bag (\@indexes, [ qw( entry_index entry_delta_index comment_index comment_delta_index tag_index )], "All indexes being indexed");

    ok (!$plugin->start_indexer ('gobbledeegook'), "start_indexer with garbage argument should return false");

    $fail = 0;
    throws_ok { $plugin->sphinx_indexer_task ('main') } qr/Error starting [^:]*: Testing!/;

    $fail = 1;
    lives_ok { $plugin->sphinx_indexer_task ('main') } 'sphinx_indexer_task should live if launching succeeds';

    @indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
    cmp_bag (\@indexes, [qw( entry_index comment_index tag_index )], "Entry, comment and tag indexes present for sphinx_indexer_task");

    $fail = 0;
    throws_ok { $plugin->sphinx_indexer_task ('delta') } qr/Error starting [^:]*: Testing!/;

    $fail = 1;
    lives_ok { $plugin->sphinx_indexer_task ('delta') } 'delta_indexer_task should live if launching succeeds';

    @indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
    cmp_bag (\@indexes, [qw( entry_delta_index comment_delta_index )], "Entry and comment delta indexes not present");

    my $pd = $plugin->get_config_obj ('system');
    $pd->data ({ sphinx_path => '' });
    ok (!$plugin->start_indexer, "start_indexer should fail if sphinx_path isn't set");

    $pd->data ({ sphinx_path => '/usr/bin', sphinx_conf_path => '' });
    ok (!$plugin->start_indexer, "start_indexer should fail if sphinx_conf_path isn't set");
}