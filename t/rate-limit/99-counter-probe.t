#!/usr/bin/perl
# Diagnostic: drive N known ephemeral logins through the plugin, count what
# audit.query reports during the same window. If counter <<< N, the audit
# path is the wrong instrument for the rate-limit story; switch to journal.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep);
use Data::Dumper;
use RateLimit::Harness qw(env_require drain_limiter new_audit_conn count_logins
                          now_iso test_scfg say_diag);

plan tests => 2;

new_audit_conn();
drain_limiter();

my $scfg = test_scfg();
require PVE::Storage::Custom::TrueNASPlugin;

my $N = 15;   # well under the 20/60s limit so we don't trip
my $t_start = now_iso();
my $opened = 0;
for (1 .. $N) {
    eval {
        my $c = PVE::Storage::Custom::TrueNASPlugin::_ws_open_ephemeral($scfg);
        PVE::Storage::Custom::TrueNASPlugin::_ws_close_ephemeral($c);
        $opened++;
    };
    if ($@) {
        say_diag("ephemeral open #$_ FAILED: " . substr($@, 0, 120));
    }
}
sleep 2;
my $t_end = now_iso();

is($opened, $N, "drove $N ephemeral logins via plugin");

my $counted = count_logins($t_start, $t_end);
say_diag("audit.query reported $counted logins for a known $N-burst");

# Dump a sample to see the actual schema TN is using.
require PVE::Storage::Custom::TrueNASPlugin;
my $sample = eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'audit.query', [{
            'query-filters' => [['message_timestamp', '>=', $t_start.'Z']],
            'query-options' => { limit => 3, order_by => ['-message_timestamp'] },
        }]
    );
};
if ($@) {
    say_diag("sample dump failed: $@");
} else {
    say_diag("sample of last 3 audit events in window:");
    say_diag(Data::Dumper->new([$sample])->Indent(1)->Sortkeys(1)->Dump);
}

# Tolerance: we accept the counter as 'valid for our purposes' if it
# reports at least half the known burst. Anything less = wrong instrument.
cmp_ok($counted, '>=', int($N/2),
    "audit.query observes >= N/2 of the known logins (sanity)");

done_testing();
