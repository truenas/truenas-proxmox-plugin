#!/usr/bin/perl -T
# Run with:  perl -T -I t/nvme/lib t/nvme/12-nsid-ghost.t   (PVE daemons run under -T)
# argo-management/23: the nsid picker skips ghost nsids (seen on this host on the
# subsystem, not in TN's DB), never persists them, and never fails a create over them.
use strict; use warnings; use Test::More; use FindBin; use File::Temp qw(tempdir);
my ($PLUGIN) = ("$FindBin::Bin/../../TrueNASPlugin.pm" =~ /^(.*)$/);
require $PLUGIN;
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $dir = tempdir(CLEANUP => 1);
my $sys = tempdir(CLEANUP => 1);
my %db;              # nsid => 1
my @devs;            # what _nvme_get_subsystem_device_paths returns
my $devs_die = 0;
my @logs;
{
    no strict 'refs'; no warnings 'redefine';
    ${"${PKG}::TN_NSID_CURSOR_DIR"} = $dir;
    ${"${PKG}::TN_SYSFS_BLOCK"} = $sys;
    *{"${PKG}::_log"} = sub { push @logs, $_[3] };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $m) = @_;
        return [ map { { nsid => $_ } } keys %db ] if $m eq 'nvmet.namespace.query';
        die "unexpected $m";
    };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub {
        die "sysfs gone\n" if $devs_die;
        return @devs;
    };
}
my $pick = $PKG->can('_nvme_pick_nsid_cursor');
my $cursor_file = "$dir/nsid-cursor-7";
my $set_cursor = sub { open(my $f, '>', $cursor_file) or die; print $f "$_[0]\n"; close $f };
my $host_ns = sub {   # make /sys/block/<name>/nsid and expose /dev/<name>
    my ($name, $nsid) = @_;
    mkdir "$sys/$name";
    open(my $f, '>', "$sys/$name/nsid") or die; print $f "$nsid\n"; close $f;
    push @devs, "/dev/$name";
};
my $reset = sub { %db = (); @devs = (); @logs = (); $devs_die = 0;
                  unlink $cursor_file; $sys = tempdir(CLEANUP => 1);
                  { no strict q(refs); ${"${PKG}::TN_SYSFS_BLOCK"} = $sys; } };

# 1. A host-visible nsid with no DB row is skipped.
$reset->();
$db{$_} = 1 for 1..5;
$host_ns->('nvme1n1', 1);
$host_ns->('nvme1n71', 7);          # ghost
$set_cursor->(6);
is($pick->({}, 7), 8, 'ghost nsid 7 (host-only) is skipped');
ok((grep { /skipping ghost nsid\(s\).*7\(nvme1n71\)/ } @logs), 'ghost skip is logged with the device name');

# 2. A host nsid that IS in the DB is not a ghost and does not log.
$reset->();
$db{$_} = 1 for 1..5;
$host_ns->('nvme1n3', 3);
$set_cursor->(5);
is($pick->({}, 7), 6, 'host nsid present in the DB is just a used nsid');
ok(!(grep { /ghost/ } @logs), 'no ghost logged when host and DB agree');

# 3. Multipath: the head node and the hidden path node carry the same nsid; one ghost.
$reset->();
$host_ns->('nvme1n71', 9);
$host_ns->('nvme1c3n71', 9);
$set_cursor->(8);
is($pick->({}, 7), 10, 'ghost seen via head and path node is skipped once');
my ($line) = grep { /skipping ghost/ } @logs;
like($line, qr/: 9\(nvme1n71\)$/, 'ghost listed once, by the first device seen');

# 4. Ghosts are never persisted to nsid-reserved.
ok(!-e "$dir/nsid-reserved", 'nsid-reserved not created by a ghost skip');

# 5. The host view failing does not fail the pick.
$reset->();
$devs_die = 1;
$set_cursor->(2);
is($pick->({}, 7), 3, 'host view error: pick proceeds without ghost skip');
ok((grep { /host namespace view unavailable \(sysfs gone\)/ } @logs), 'host view error is logged');

# 6. Unreadable or non-numeric nsid files are ignored.
$reset->();
push @devs, '/dev/nvme1n50';                 # no sysfs entry
$host_ns->('nvme1n51', 'abc');               # junk
push @devs, '/dev/../etc/passwd';            # not an nvme name
$set_cursor->(0);
is($pick->({}, 7), 1, 'missing, junk and odd device entries are ignored');
ok(!(grep { /ghost/ } @logs), 'nothing logged for ignored entries');

# 7. Ghost skip composes with nsid-reserved and the caller's exclude set.
$reset->();
open(my $rf, '>', "$dir/nsid-reserved") or die; print $rf "1\n"; close $rf;
$host_ns->('nvme1n2', 2);
$set_cursor->(0);
is($pick->({}, 7, { 3 => 1 }), 4, 'reserved 1, ghost 2 and excluded 3 all skipped');
unlink "$dir/nsid-reserved";

# 8. The ghost's nsid is not written as the cursor.
$reset->();
$host_ns->('nvme1n5', 5);
$set_cursor->(4);
$pick->({}, 7);
open(my $cf, '<', $cursor_file) or die; my $c = <$cf>; close $cf;
is($c, "6\n", 'cursor advances past the ghost to the picked nsid');

done_testing();
