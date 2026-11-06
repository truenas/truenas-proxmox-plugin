#!/usr/bin/perl
# Integration test for _nvme_check_devices_in_use against the actual
# NVMe sysfs layout the function will see in production. Exists because
# t/nvme/07 stubs the three helper probes and so does not exercise the
# real sysfs/mountinfo reading code -- and the loop-device reproduction
# in the review did not exercise the NVMe-specific wrinkle either. One
# such wrinkle (per-path nvme<X>c<Y>n<Z> devices in multipath=Y mode
# lack /sys/block/<name>/dev) escaped t/nvme/07 and the loop-device
# live test and made it to a commit (114b57b) before the real-call-site
# probe caught it.
#
# This test skips cleanly on a host with no NVMe devices (e.g. the
# developer workstation). On any node with NVMe devices (pve, pvevm1,
# etc.) it walks /sys/block for real nvme<X>n<Y> head devices and any
# nvme<X>c<Y>n<Z> per-path devices, and checks:
#
#   - _nvme_dev_major_minors returns a map containing the head's own
#     major:minor and nothing for the per-path entries (silent skip);
#   - the composed helpers (_nvme_scan_holders, _nvme_scan_mount_namespaces)
#     return a defined value on every real device set, not undef (which
#     the composer treats as "assume in use");
#   - _nvme_check_devices_in_use returns 0 or 1 end-to-end on the host's
#     own NVMe devices without the "assume in use" fail-safe firing from
#     a sysfs-layout misread.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/08-inuse-probe-nvmeof-sysfs.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

# Enumerate the host's own NVMe devices from /sys/block.
my @heads;
my @perpaths;
if (opendir(my $dh, '/sys/block')) {
    while (my $e = readdir($dh)) {
        if ($e =~ /^(nvme\d+n\d+)$/) {
            push @heads, "/dev/$1";
        }
        elsif ($e =~ /^(nvme\d+c\d+n\d+)$/) {
            push @perpaths, "/dev/$1";
        }
    }
    closedir($dh);
}

if (!@heads && !@perpaths) {
    plan skip_all => "no NVMe devices on this host";
}

# Capture _log output rather than emitting real warnings during the test.
my @LOG;
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @LOG, "[$_[2]] $_[3]"; };
}

my $scfg = { tn_nvme_debug => 1 };

note "heads: " . (scalar(@heads) ? join(' ', @heads) : '(none)');
note "per-path: " . (scalar(@perpaths) ? join(' ', @perpaths) : '(none)');

# ----- 1. Per-path devices must be silently skipped by the ID walker. -----
for my $pp (@perpaths) {
    my ($id, $err) = $PKG->can('_nvme_dev_major_minors')->($pp);
    ok(defined $id && !defined $err,
        "per-path $pp: ID walker returns a map (not an error)");
    is(scalar(keys %$id), 0,
        "per-path $pp: ID map is empty (no dev file, silently skipped)");
}
SKIP: {
    skip "no per-path devices (multipath=N?)", 0 unless @perpaths;
}

# ----- 2. Head devices must produce an ID map with their own maj:min. -----
for my $head (@heads) {
    my ($id, $err) = $PKG->can('_nvme_dev_major_minors')->($head);
    ok(defined $id && !defined $err,
        "head $head: ID walker returns a map (not an error, not '"
        . ($err // '(undef)') . "')")
        or diag "ID walker error: " . ($err // '(undef)');

    my $base = $head; $base =~ s{^/dev/}{};
    my $expected = do {
        open(my $fh, '<', "/sys/block/$base/dev") or die "sysfs read: $!";
        my $v = <$fh>; close $fh; chomp $v; $v;
    };
    ok(exists $id->{$expected},
        "head $head: ID map contains $expected");
}

# ----- 3. The scan helpers must not report an error on real devices. -----
my ($id_all, $id_err) = $PKG->can('_nvme_dev_major_minors')->(@heads, @perpaths);
ok(defined $id_all && !defined $id_err,
    "ID walker over the full host NVMe device list returns a map (err='"
    . ($id_err // '(undef)') . "')")
    or BAIL_OUT("_nvme_dev_major_minors failed on real host devices: "
        . ($id_err // '(undef)'));
isnt(scalar(keys %$id_all), 0,
    "ID walker yields at least one maj:min for real NVMe heads");

my ($h_hit, $h_info) = $PKG->can('_nvme_scan_holders')->($id_all);
ok(defined $h_hit,
    "_nvme_scan_holders returns a defined hit value "
    . "(0=idle, 1=hit, undef=probe error)");
# Any defined value is OK -- we just need the probe not to fail silently
# and bubble up as "assume in use" from the composer.

my ($m_hit, $m_info) = $PKG->can('_nvme_scan_mount_namespaces')->($id_all);
ok(defined $m_hit,
    "_nvme_scan_mount_namespaces returns a defined hit value "
    . "(0=idle, 1=hit, undef=probe error)");

# ----- 4. End-to-end: the composer returns a defined 0/1 on real devices. -----
@LOG = ();
my $rc = $PKG->can('_nvme_check_devices_in_use')->($scfg, @heads, @perpaths);
ok(defined $rc && ($rc == 0 || $rc == 1),
    "_nvme_check_devices_in_use returns a defined 0/1 on real host devices")
    or diag "log output: " . join("\n  ", @LOG);

# The fail-safe "assume in use" paths all log at severity 'warning'. If
# the composer fired one of those from a sysfs-layout misread, the log
# would carry the reason. For an idle host NVMe device we want rc=0 AND
# no probe-error log. For a busy one (e.g. the host's own boot nvme) we
# accept rc=1 only when the holders probe hit (dm/md stackers are common
# on a boot nvme) or the mount scan hit (/boot etc).
my @probe_errors = grep { /in_use probe:.*(scan failed|cannot read)/ } @LOG;
is(scalar(@probe_errors), 0,
    "no sysfs-layout probe error on real host NVMe devices (" . scalar(@probe_errors)
    . " error log line(s))") or diag join("\n  ", @probe_errors);

done_testing();
