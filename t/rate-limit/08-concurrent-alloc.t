#!/usr/bin/perl
# Concurrent iSCSI VM allocation under load.
#
# Drives N qm-create-with-disk operations in parallel, each in a
# separate forked PVE-side process (i.e., each is a fresh perl
# interpreter that loads the plugin cold and hits the broker via the
# normal path). Measures:
#
#   - completion rate (how many of N succeed)
#   - wall-clock per child (min/median/max)
#   - aggregate elapsed for the whole batch
#   - upstream auth.login_with_api_key count in the batch window
#
# Pass criteria:
#   - All N qm-create calls succeed (rc=0).
#   - Every child completes within $WALL_BUDGET seconds.
#   - Total upstream logins remain <= 1 (broker correctly pools the
#     concurrent calls onto its single upstream WS).
#
# What it catches that 02 / 03 / 07 don't:
#
# - 02 (D1 burst) creates 8 VMs SEQUENTIALLY in one process. No
#   concurrency, no fork-per-create.
# - 03 (D2 per-process) forks 10 children but each child does the
#   LIGHTEST possible read (`pvesh status`). Cheap call, ~one RPC.
# - 07 (concurrent broker) forks 5 children doing 4 read RPCs each.
#   Still all reads.
#
# This test is the missing case: concurrent HEAVY operations. Each
# qm-create triggers the alloc_image -> pool.dataset.create +
# iscsi.extent.create + iscsi.targetextent.create chain, plus PVE-side
# iSCSI login + multipath + udev. It's the realistic backup-window
# /multi-disk-VM/clone-storm shape and the workload that originally
# tripped the limiter.
#
# Tunable via env:
#   RL_CONCURRENT_N     - children to fork (default 10)
#   RL_CONCURRENT_BUDGET - per-child wall-clock budget seconds (default 120)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep time);
use POSIX qw(:sys_wait_h);
use RateLimit::Harness qw(env_require env_get drain_limiter new_audit_conn count_logins
                          now_iso qm_create_with_disk qm_destroy say_diag);

plan tests => 5;

new_audit_conn();
drain_limiter();

my $sid          = env_require('STORAGE_ID');
my $base         = env_get('TEST_VMID_BASE', 99000) + 40;
my $N            = env_get('RL_CONCURRENT_N', 10) + 0;
my $WALL_BUDGET  = env_get('RL_CONCURRENT_BUDGET', 120) + 0;

say_diag("config: N=$N children, budget=${WALL_BUDGET}s/child, vmid range "
         . "$base..".($base + $N - 1));

my $batch_start = time();
my $t_start_iso = now_iso();

# Fork all children up front so they start as close to simultaneously
# as possible.
my %kid_meta;       # pid -> { vmid => N, t0 => epoch }
for my $i (0 .. $N - 1) {
    my $vmid = $base + $i;
    my $t0 = time();
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        # Child: do the heavy create and exit with rc.
        my ($rc, $out) = qm_create_with_disk($vmid, $sid, 1);
        # Don't print on success (avoid TAP noise from parallel writers);
        # parent uses exit code only.
        if ($rc != 0) {
            print STDERR "[child vmid=$vmid pid=$$] rc=$rc out="
                . substr($out, 0, 200) . "\n";
        }
        exit($rc & 0xff);
    }
    $kid_meta{$pid} = { vmid => $vmid, t0 => $t0 };
}

# Wait for all children, capturing per-child wall clock.
my $deadline = time() + $WALL_BUDGET + 30;   # +30s parent slop
my %rc;
my %dur;
while (%kid_meta && time() < $deadline) {
    my $reaped = waitpid(-1, WNOHANG);
    if ($reaped > 0) {
        my $meta = delete $kid_meta{$reaped};
        $rc{$meta->{vmid}}  = $? >> 8;
        $dur{$meta->{vmid}} = time() - $meta->{t0};
        next;
    }
    sleep 0.1;
}

# Anything still running past the deadline -> SIGTERM + record as fail.
my @stragglers;
for my $pid (keys %kid_meta) {
    my $meta = $kid_meta{$pid};
    push @stragglers, $meta->{vmid};
    kill 'TERM', $pid;
    waitpid($pid, 0);
    $rc{$meta->{vmid}}  = -1;
    $dur{$meta->{vmid}} = time() - $meta->{t0};
}

my $batch_elapsed = time() - $batch_start;
sleep 2;
my $t_end_iso = now_iso();

# Stats.
my $ok_count  = scalar grep { $rc{$_} == 0 } keys %rc;
my $fail_count = $N - $ok_count;

my @durs = sort { $a <=> $b } values %dur;
my ($dmin, $dmed, $dmax) = (0, 0, 0);
if (@durs) {
    $dmin = $durs[0];
    $dmax = $durs[-1];
    $dmed = $durs[int(@durs / 2)];
}

my $logins = count_logins($t_start_iso, $t_end_iso);

say_diag(sprintf(
    "results: ok=%d fail=%d  stragglers=%d  "
  . "batch=%.1fs  per-child min=%.1fs med=%.1fs max=%.1fs  "
  . "upstream_logins=%d",
    $ok_count, $fail_count, scalar(@stragglers),
    $batch_elapsed, $dmin, $dmed, $dmax,
    $logins,
));

# Assertions.
is($fail_count, 0, "all $N concurrent qm-creates succeeded");
is(scalar(@stragglers), 0,
    "no child exceeded the ${WALL_BUDGET}s wall-clock budget");
cmp_ok($dmax, '<=', $WALL_BUDGET,
    "slowest child completed within ${WALL_BUDGET}s (max=${dmax}s)");
cmp_ok($logins, '<=', 1,
    "$N concurrent allocs share at most 1 auth.login_* via broker (got $logins)");

# Cleanup. Destroy whatever succeeded; ignore destroy failures here
# but report count.
my $cleanup_fail = 0;
for my $vmid (sort { $a <=> $b } keys %rc) {
    next if $rc{$vmid} != 0;   # didn't get created
    my ($crc, undef) = qm_destroy($vmid);
    $cleanup_fail++ if $crc != 0;
}
is($cleanup_fail, 0, "cleanup destroyed every created VM");

done_testing();
