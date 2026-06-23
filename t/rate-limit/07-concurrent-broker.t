#!/usr/bin/perl
# Concurrent broker contention: N child processes each drive M API
# calls through the broker simultaneously. The broker's accept loop is
# single-threaded; this test exercises whether it correctly serialises
# many client connections without losing requests, deadlocking, or
# leaking sockets.
#
# Assertions:
#   - All children complete without error.
#   - Total auth.login_with_api_key count in the window stays at <= 1.
#     The broker holds ONE upstream WS per (host, key); N parallel
#     plugin clients funnel through it via N Unix-socket round trips.
#     If the broker accidentally opens an upstream WS per client (race
#     in get_or_open_ws), this assertion catches it.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep time);
use POSIX qw(:sys_wait_h);
use RateLimit::Harness qw(env_require drain_limiter new_audit_conn count_logins
                          now_iso test_scfg say_diag);

plan tests => 3;

new_audit_conn();
drain_limiter();

my $scfg = test_scfg();
require PVE::Storage::Custom::TrueNASPlugin;

my $N_PROCS = 5;   # fork this many children
my $M_CALLS = 4;   # each child issues this many API calls

# Sanity: parent makes one call first to ensure the broker has an
# upstream WS ready. Without this, the first child's call races every
# other child's call against broker startup, and we'd be measuring
# broker-cold-start, not steady-state contention.
eval { PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, 'system.version', []) };
diag("warmup call failed: $@") if $@;

my $t_start = now_iso();

my @kids;
for my $i (1 .. $N_PROCS) {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        # Child: hammer the broker. Use a mix of read methods so we
        # exercise different code paths.
        my @methods = (
            ['system.version',       []],
            ['pool.dataset.query',   [[], { limit => 1 }]],
            ['iscsi.extent.query',   [[], { limit => 1 }]],
            ['iscsi.target.query',   [[], { limit => 1 }]],
        );
        my $fail = 0;
        for my $j (1 .. $M_CALLS) {
            my ($m, $p) = @{ $methods[($j-1) % @methods] };
            eval {
                PVE::Storage::Custom::TrueNASPlugin::_api_call(
                    $scfg, $m, $p,
                );
            };
            $fail++ if $@;
        }
        exit($fail == 0 ? 0 : 1);
    }
    push @kids, $pid;
}

# Wait for all children. Bound the wait so a stuck broker doesn't hang
# the test indefinitely.
my $deadline = time() + 60;
my %rc;
while (@kids && time() < $deadline) {
    my $reaped = waitpid(-1, WNOHANG);
    if ($reaped > 0) {
        $rc{$reaped} = $?;
        @kids = grep { $_ != $reaped } @kids;
        next;
    }
    sleep 0.1;
}

my $all_ok = 1;
for my $pid (sort keys %rc) {
    my $code = $rc{$pid} >> 8;
    $all_ok = 0 if $code != 0;
}
my $stragglers = scalar @kids;
say_diag("children: " . scalar(keys %rc) . " reaped, $stragglers still running")
    if $stragglers;

is($stragglers, 0, "all $N_PROCS children completed within 60s");
ok($all_ok, "all $N_PROCS x $M_CALLS concurrent calls succeeded");

# Final audit check.
sleep 2;
my $t_end = now_iso();
my $logins = count_logins($t_start, $t_end);
say_diag("logins during $N_PROCS x $M_CALLS concurrent burst: $logins");
cmp_ok($logins, '<=', 1,
    "$N_PROCS x $M_CALLS concurrent broker calls share <= 1 auth.login_*");

# Reap any stragglers so we don't leak zombies.
for my $pid (@kids) {
    kill 'TERM', $pid;
    waitpid($pid, 0);
}

done_testing();
