#!/usr/bin/perl
# D2: every short-lived Proxmox process (qm, pvesh, forked pveproxy worker)
# starts with an empty %_ws_connections cache and re-authenticates.
# Reads ride the persistent socket inside one process, but each forked
# process makes its own.
# Expected after fix: a session broker daemon holds the WS for the node
# so 10 parallel pvesh invocations share <= 1 login.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep);
use RateLimit::Harness qw(env_require drain_limiter new_audit_conn count_logins
                          now_iso pvesh_status_async say_diag);

plan tests => 2;

new_audit_conn();
drain_limiter();

my $sid = env_require('STORAGE_ID');
my $n   = 10;

my $t_start = now_iso();
my $rc = pvesh_status_async($sid, $n);
sleep 2;
my $t_end = now_iso();

my $logins = count_logins($t_start, $t_end);
say_diag("logins during $n parallel pvesh status: $logins; max child rc=$rc");

is($rc, 0, "all $n parallel pvesh status calls succeed");
cmp_ok($logins, '<=', 1,
    "$n forked-process status calls share at most 1 auth.login_* (D2 fix)");

done_testing();
