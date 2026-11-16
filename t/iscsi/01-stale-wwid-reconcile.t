#!/usr/bin/perl
# Unit tests for the cross-node stale-WWID reconcile path added for #147.
#
# These exercise the pure-Perl helpers directly. Filesystem roots
# ($STALE_WWID_HINT_ROOT, $ISCSI_SESSION_ROOT, $SYS_BLOCK_ROOT,
# $RECONCILE_STAMP_DIR) are local-overridden to tempdirs so the module's
# production paths (/etc/pve, /sys, /run) are never touched.
#
# Run with:  prove -v -I t/iscsi/lib t/iscsi/01-stale-wwid-reconcile.t

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

# All helpers under test live here.
plan skip_all => "stale-wwid reconcile helpers not loaded"
    unless $PKG->can('_sane_wwid')
        && $PKG->can('_naa_to_wwid')
        && $PKG->can('_write_stale_wwid_hint')
        && $PKG->can('_read_stale_wwid_hint')
        && $PKG->can('_enum_local_iscsi_wwids_for_target')
        && $PKG->can('_teardown_stale_wwid')
        && $PKG->can('_reconcile_stale_wwids')
        && $PKG->can('_floor_reconcile_wwids');

# Convenience: call the plugin's own subs as plain functions (not methods).
# The sub $t->{name} style keeps the test readable and avoids passing $PKG
# as the first argument.
sub _call { my ($name, @a) = @_; no strict 'refs'; return &{"${PKG}::$name"}(@a); }

# Shared tempdir layout.
my $TOP     = tempdir(CLEANUP => 1);
my $HINTS   = "$TOP/etc-pve-stale-wwid";
my $ISCSI_S = "$TOP/sys-class-iscsi_session";
my $SYSBLK  = "$TOP/sys-block";
my $RUNDIR  = "$TOP/run-truenas-plugin";

make_path($HINTS, $ISCSI_S, $SYSBLK, $RUNDIR);

no strict 'refs';
no warnings 'redefine';

${"${PKG}::STALE_WWID_HINT_ROOT"} = $HINTS;
${"${PKG}::ISCSI_SESSION_ROOT"}   = $ISCSI_S;
${"${PKG}::SYS_BLOCK_ROOT"}       = $SYSBLK;
${"${PKG}::RECONCILE_STAMP_DIR"}  = $RUNDIR;
${"${PKG}::FLOOR_RECONCILE_MIN_S"} = 0;  # don't rate-limit in tests

# Quiet logging; keep a tap in case a test wants it.
my @LOG;
*{"${PKG}::_log"} = sub { my (undef,$l,$s,$m) = @_; push @LOG, { l=>$l, s=>$s, m=>$m }; };

# Captured run_command calls (kpartx / multipath / udevadm).
my @RUN;
*{"PVE::Tools::run_command"} = sub {
    my ($cmd, %opts) = @_;
    push @RUN, [@$cmd];
    return 0;
};

# ---- 1. WWID parsing ----

ok(!defined _call('_sane_wwid', undef), "sane_wwid rejects undef");
ok(!defined _call('_sane_wwid', ''), "sane_wwid rejects empty");
ok(!defined _call('_sane_wwid', '36589cfcDEADBEEF'), "sane_wwid rejects short");
ok(!defined _call('_sane_wwid', '26589cfc' . 'a' x 24), "sane_wwid rejects non-3 prefix");
is(_call('_sane_wwid', '3' . 'a' x 32), '3' . 'a' x 32, "sane_wwid accepts valid shape");

ok(!defined _call('_naa_to_wwid', 'garbage'), "naa_to_wwid rejects garbage");
is(_call('_naa_to_wwid', '0x6589cfc0000007e14b2248c1e5fa7768'),
   '36589cfc0000007e14b2248c1e5fa7768',
   "naa_to_wwid prepends '3' and lowercases");
is(_call('_naa_to_wwid', '0X6589CFC0000007E14B2248C1E5FA7768'),
   '36589cfc0000007e14b2248c1e5fa7768',
   "naa_to_wwid handles upper-case 0X");

# ---- 2. hint write/read round-trip ----

my $storeid = 'truenas-foo';
my $wwid    = '36589cfc0000007e14b2248c1e5fa7768';

_call('_write_stale_wwid_hint', {}, $storeid, $wwid);
my $path = _call('_stale_wwid_hint_path', $storeid, $wwid);
ok(-f $path, "hint file written: $path");

my $hint = _call('_read_stale_wwid_hint', $path);
ok($hint && ref $hint eq 'HASH', "read_stale_wwid_hint returns hashref");
is($hint->{wwid}, $wwid, "hint carries wwid");
ok(defined $hint->{by} && length $hint->{by}, "hint carries 'by' node");
ok($hint->{removed_at} > 0 && $hint->{removed_at} <= time(), "hint carries sane removed_at");

# ---- 3. sysfs enum: happy path ----

# Build a mock sysfs tree:
#   $ISCSI_S/session1/targetname -> "iqn.2005-10...:prox"
#   $ISCSI_S/session1/device/target1:0:0/1:0:0:7/block/sdm
#   $SYSBLK/sdm/device/wwid -> "naa.6589cfc0000007e14b2248c1e5fa7768"

sub build_session {
    my ($sess, $iqn, $sds) = @_;
    my $sdir = "$ISCSI_S/$sess";
    my $dev  = "$sdir/device/target1:0:0";
    make_path($dev);
    open(my $t, '>', "$sdir/targetname") or die "targetname: $!";
    print $t "$iqn\n";
    close $t;
    for my $sd (@$sds) {
        my $host = "$dev/1:0:0:7";
        make_path("$host/block");
        # link-less: just make an sdX directory
        make_path("$host/block/$sd");
        # And the matching /sys/block entry with wwid + delete file
        make_path("$SYSBLK/$sd/device");
        open(my $w, '>', "$SYSBLK/$sd/device/wwid") or die "wwid: $!";
        my $naa = $wwid;
        $naa =~ s/^3//;
        print $w "naa.$naa\n";
        close $w;
        open(my $d, '>', "$SYSBLK/$sd/device/delete") or die "delete: $!";
        print $d "";  # will be overwritten by teardown
        close $d;
    }
}

my $target_iqn = 'iqn.2005-10.org.freenas.ctl:prox';
build_session('session1', $target_iqn, ['sdm', 'sdao']);

my $enum = _call('_enum_local_iscsi_wwids_for_target', { tn_target_iqn => $target_iqn });
ok(exists $enum->{$wwid}, "enum found wwid under matching session");
is_deeply([sort @{ $enum->{$wwid} }], ['sdao','sdm'], "both path sd devices collected");

# A session for a DIFFERENT target must not contribute.
build_session('session9', 'iqn.another:unrelated', ['sdz']);
make_path("$SYSBLK/sdz/device");
open(my $uw, '>', "$SYSBLK/sdz/device/wwid") or die;
print $uw "naa.6589cfcDEADBEEFDEADBEEFDEADBEEFDE\n";
close $uw;
my $enum2 = _call('_enum_local_iscsi_wwids_for_target', { tn_target_iqn => $target_iqn });
ok(!grep({ $_ eq 'sdz' } map { @$_ } values %$enum2), "other-target sd never appears");

# ---- 4. teardown: happy path ----

@RUN = ();
my $torn = _call('_teardown_stale_wwid', {}, $wwid, ['sdm','sdao']);
is($torn, 1, "teardown returned 1");
my @multipath_calls = grep { $_->[0] eq 'multipath' } @RUN;
is(scalar @multipath_calls, 1, "exactly one multipath -f call");
is($multipath_calls[0][2], $wwid, "multipath -f target is the WWID");
my @kpartx_calls = grep { $_->[0] eq 'kpartx' } @RUN;
is(scalar @kpartx_calls, 1, "kpartx -d called once");
# delete files should contain "1"
for my $sd (qw(sdm sdao)) {
    open(my $r, '<', "$SYSBLK/$sd/device/delete") or die;
    my $v = do { local $/; <$r> };
    close $r;
    is($v, '1', "$sd delete written");
}

# ---- 5. teardown: multipath -f fails (busy) ----

@RUN = ();
my $fail_run = sub { die "multipath: map in use\n" if $_[0]->[0] eq 'multipath'; };
*{"PVE::Tools::run_command"} = sub { my ($c,%o)=@_; push @RUN, [@$c]; $fail_run->([@$c]); 0; };
# Re-create delete files so we can observe non-writes.
for my $sd (qw(sdm sdao)) {
    open(my $r, '>', "$SYSBLK/$sd/device/delete") or die;
    print $r "0";
    close $r;
}
my $torn_busy = _call('_teardown_stale_wwid', {}, $wwid, ['sdm','sdao']);
is($torn_busy, 0, "teardown returns 0 on multipath -f failure");
for my $sd (qw(sdm sdao)) {
    open(my $r, '<', "$SYSBLK/$sd/device/delete") or die;
    my $v = do { local $/; <$r> };
    close $r;
    is($v, '0', "$sd delete NOT written when map busy");
}
# Restore working run_command.
*{"PVE::Tools::run_command"} = sub { my ($c,%o)=@_; push @RUN, [@$c]; 0; };

# ---- 6. hint-driven reconcile end-to-end ----

# Re-create delete files writable.
for my $sd (qw(sdm sdao)) {
    open(my $r, '>', "$SYSBLK/$sd/device/delete") or die;
    print $r "";
    close $r;
}
# Ensure the hint exists for our wwid under this storeid.
my $scfg = {
    tn_reconcile          => 1,
    tn_transport_mode     => 'iscsi',
    tn_use_multipath      => 1,
    tn_target_iqn         => $target_iqn,
    tn_reconcile_hint_ttl_s => 600,
};
# Write a fresh hint owned by a different node — should trigger teardown
# locally but NOT be removed.
my $hint_path = _call('_stale_wwid_hint_path', $storeid, $wwid);
make_path(_call('_stale_wwid_hint_dir', $storeid));
open(my $h, '>', $hint_path) or die;
print $h encode_json({ wwid => $wwid, by => 'some-other-node', removed_at => time() });
close $h;

@RUN = ();
_call('_reconcile_stale_wwids', $storeid, $scfg);
ok(grep({ $_->[0] eq 'multipath' && $_->[2] eq $wwid } @RUN),
    "reconcile_stale_wwids tears down the WWID on peer hint");
ok(-f $hint_path, "peer-owned hint NOT removed by local reconcile");

# Now write an OWN expired hint — it should be unlinked.
my $me = _call('_local_node_name');
open(my $h2, '>', $hint_path) or die;
print $h2 encode_json({ wwid => $wwid, by => $me, removed_at => time() - 10_000 });
close $h2;
_call('_reconcile_stale_wwids', $storeid, $scfg);
ok(!-e $hint_path, "own expired hint unlinked");

# ---- 7. floor reconcile: grace window + fail-closed ----

# Clear previous delete-file state so we can observe non-writes.
for my $sd (qw(sdm sdao)) {
    open(my $r, '>', "$SYSBLK/$sd/device/delete") or die;
    print $r "";
    close $r;
}
unlink $_ for glob "$RUNDIR/reconcile-*";
unlink $_ for glob "$RUNDIR/orphan-*/*";

# TN returns NO extent for our dataset: our local WWID is an orphan.
my $tn_mode = 'orphan';
*{"${PKG}::_api_call"} = sub {
    my ($scfg, $method, $args) = @_;
    if ($method eq 'iscsi.extent.query') {
        return [] if $tn_mode eq 'orphan';          # orphan
        die "simulated TN failure\n" if $tn_mode eq 'fail';
        return [ { id => 1, naa => '0x6589cfc0000007e14b2248c1e5fa7768',
                   disk => 'zvol/tank/pve/vol-foo' } ]
            if $tn_mode eq 'live';
    }
    return [];
};

my $floor_scfg = {
    tn_reconcile          => 1,
    tn_transport_mode     => 'iscsi',
    tn_use_multipath      => 1,
    tn_target_iqn         => $target_iqn,
    tn_dataset            => 'tank/pve',
    tn_reconcile_grace_s  => 100,
};

# 1st pass: stamps the orphan, does NOT tear down (within grace).
@RUN = ();
_call('_floor_reconcile_wwids', $storeid, $floor_scfg);
ok(!grep({ $_->[0] eq 'multipath' } @RUN),
    "floor 1st pass does not tear down within grace");
my $orphan_stamp = "$RUNDIR/orphan-$storeid/$wwid";
ok(-f $orphan_stamp, "orphan stamp created");

# 2nd pass with the stamp backdated past grace: tears down.
utime(time() - 9999, time() - 9999, $orphan_stamp);
unlink "$RUNDIR/reconcile-$storeid";   # reset rate-limit stamp
@RUN = ();
_call('_floor_reconcile_wwids', $storeid, $floor_scfg);
ok(grep({ $_->[0] eq 'multipath' && $_->[2] eq $wwid } @RUN),
    "floor 2nd pass tears down past grace");
ok(!-e $orphan_stamp, "orphan stamp cleared after teardown");

# TN returns the extent live → orphan stamp cleared, nothing torn down.
$tn_mode = 'live';
# re-stamp as orphan (simulating transient)
open(my $os, '>', $orphan_stamp) or die;
print $os time() - 9999;
close $os;
utime(time() - 9999, time() - 9999, $orphan_stamp);
unlink "$RUNDIR/reconcile-$storeid";
@RUN = ();
_call('_floor_reconcile_wwids', $storeid, $floor_scfg);
ok(!grep({ $_->[0] eq 'multipath' } @RUN),
    "floor does not tear down a live WWID");
ok(!-e $orphan_stamp, "floor cleared orphan stamp when WWID came back live");

# TN query fails: floor must bail without touching anything.
$tn_mode = 'fail';
# Re-create a hinted orphan locally.
unlink "$RUNDIR/reconcile-$storeid";
@RUN = ();
_call('_floor_reconcile_wwids', $storeid, $floor_scfg);
ok(!grep({ $_->[0] eq 'multipath' } @RUN),
    "floor fails-closed on TN query exception");

# ---- 8. config guards ----

@RUN = ();
my $off = { %$floor_scfg, tn_reconcile => 0 };
_call('_reconcile_stale_wwids', $storeid, $off);
_call('_floor_reconcile_wwids', $storeid, $off);
ok(!@RUN, "tn_reconcile=0 disables both sweeps");

@RUN = ();
my $nvme = { %$floor_scfg, tn_transport_mode => 'nvme-tcp' };
_call('_reconcile_stale_wwids', $storeid, $nvme);
_call('_floor_reconcile_wwids', $storeid, $nvme);
ok(!@RUN, "nvme-tcp mode skips iSCSI reconcile");

@RUN = ();
my $nomp = { %$floor_scfg, tn_use_multipath => 0 };
_call('_reconcile_stale_wwids', $storeid, $nomp);
_call('_floor_reconcile_wwids', $storeid, $nomp);
ok(!@RUN, "tn_use_multipath=0 skips reconcile");

done_testing();
