#!/usr/bin/perl
# D1 + D3 combined repro:
# 8 sequential VM-with-disk creates from a single PVE node. Each alloc
# pre-fix emits ~3 logins (D1) -> ~24 logins inside one 60s window ->
# limiter trips around #7 -> D3 retry-on-EBUSY then fires more logins
# inside the same window -> death spiral.
#
# fix/rate-limit-connection-reuse branch (this branch): writes ride the
# persistent socket via _api_call_mutate, so each forked qm worker spends
# 1 login on auth.login_with_api_key instead of ~3. D2 (cross-process
# re-auth) is NOT addressed here, so each of N qm calls still costs 1
# login. Bar: total logins <= burst (verifies D1 only). Pre-fix would be
# ~3*burst + retries.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep);
use RateLimit::Harness qw(env_require env_get drain_limiter new_audit_conn count_logins
                          now_iso qm_create_with_disk qm_destroy say_diag);

plan tests => 4;

new_audit_conn();
drain_limiter();

my $sid  = env_require('STORAGE_ID');
my $base = env_get('TEST_VMID_BASE', 99000) + 10;
my $burst = 8;

my $t_start = now_iso();

my @failed;
my @ebusy;
my @created;
for my $i (0 .. $burst - 1) {
    my $vmid = $base + $i;
    my ($rc, $out) = qm_create_with_disk($vmid, $sid, 1);
    if ($rc != 0) {
        push @failed, $vmid;
        push @ebusy,  $vmid if $out =~ /Rate Limit Exceeded|EBUSY|errno\s*16/i;
        say_diag("create $vmid failed (rc=$rc): "
                 . substr($out, 0, 200) . (length($out) > 200 ? "..." : ""));
    } else {
        push @created, $vmid;
    }
}

sleep 2;
my $t_end = now_iso();

my $logins = count_logins($t_start, $t_end);
say_diag("logins during $burst-burst: $logins; failed=" . scalar(@failed)
         . "; ebusy=" . scalar(@ebusy));

is(scalar(@failed), 0, "all $burst VM-disk creates succeed (no D3 lockout)");
is(scalar(@ebusy),  0, "zero Rate Limit Exceeded responses");
cmp_ok($logins, '<=', $burst,
    "$burst sequential writes generate at most $burst auth.login_* (D1 fix: ~1 login per qm process; pre-fix was ~3*$burst)");

# Cleanup whatever succeeded
my $cleanup_failures = 0;
for my $vmid (@created) {
    my ($crc, $cout) = qm_destroy($vmid);
    $cleanup_failures++ if $crc != 0;
}
is($cleanup_failures, 0, "cleanup: all created VMs destroyed");

done_testing();
