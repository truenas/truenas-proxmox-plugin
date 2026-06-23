#!/usr/bin/perl
# D1: every write opens a fresh ephemeral WS and re-authenticates.
# Expected after fix: one disk alloc -> 0 or 1 logins.
# Pre-fix: ~3 logins per alloc (dataset.create + extent.create +
# targetextent.create, each via _api_call_write -> use_ephemeral ->
# _ws_open -> auth.login_*).
# fix/rate-limit-connection-reuse branch: writes go through
# _api_call_mutate (alias of _api_call) -> _ws_get_persistent -> 1 login
# per process. qm runs as a fresh perl process so the whole alloc is 1
# login.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep);
use RateLimit::Harness qw(env_require env_get drain_limiter new_audit_conn count_logins
                          now_iso qm_create_with_disk qm_destroy say_diag);

plan tests => 3;

new_audit_conn();
drain_limiter();

my $sid  = env_require('STORAGE_ID');
my $vmid = env_get('TEST_VMID_BASE', 99000) + 1;

my $t_start = now_iso();
my ($rc, $out) = qm_create_with_disk($vmid, $sid, 1);
sleep 2;   # let audit flush
my $t_end = now_iso();

is($rc, 0, "qm create $vmid on $sid succeeded")
    or diag("output: $out");

my $logins = count_logins($t_start, $t_end);
say_diag("logins during single VM create with disk: $logins");

# Goal post-fix: <= 1. Strict: == 0 if persistent session already exists in
# pvedaemon, or == 1 for cold child that opened its own session.
cmp_ok($logins, '<=', 1,
    "single VM-disk alloc should require at most 1 auth.login_* (D1 fix asserts <=1)");

# Cleanup
my ($crc, $cout) = qm_destroy($vmid);
is($crc, 0, "cleanup: qm destroy $vmid")
    or diag("cleanup output: $cout");

done_testing();
