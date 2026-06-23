#!/usr/bin/perl
# Positive control: 100 mixed operations issued in a single Perl process,
# using the plugin's helpers directly, must require exactly 1 auth.login_*.
# This proves the plugin CAN reuse a session when its own code path doesn't
# force ephemeral-WS reauth (i.e. read paths via _api_call_read).
#
# Pre-fix: passes (reads already use persistent socket within one process).
# Post-fix: still passes (reads + writes both use persistent socket).
#
# If this test FAILS pre-fix, the persistent-session machinery is broken
# for reasons beyond D1/D2/D3 and needs separate investigation.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep);
use RateLimit::Harness qw(env_require drain_limiter new_audit_conn count_logins
                          now_iso test_scfg say_diag);

plan tests => 2;

new_audit_conn();
drain_limiter();

my $scfg = test_scfg();

my $t_start = now_iso();
my $ops_ok = 0;
my $ops_fail = 0;

# Drive 100 read calls through the plugin's persistent-socket path.
# Mix queries so we exercise multiple endpoints.
my @methods = (
    ['system.version', []],
    ['pool.dataset.query', [[], { limit => 1 }]],
    ['iscsi.extent.query', [[], { limit => 1 }]],
    ['iscsi.target.query', [[], { limit => 1 }]],
);
for my $i (1 .. 100) {
    my ($m, $p) = @{ $methods[$i % @methods] };
    eval { PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, $m, $p) };
    if ($@) { $ops_fail++; }
    else    { $ops_ok++; }
}

sleep 2;
my $t_end = now_iso();
my $logins = count_logins($t_start, $t_end);
say_diag("100 mixed reads in one process: ok=$ops_ok fail=$ops_fail logins=$logins");

is($ops_fail, 0, "all 100 in-process reads succeed");
cmp_ok($logins, '<=', 1,
    "100 mixed reads in one process require exactly 1 auth.login_* (persistent socket)");

done_testing();
