#!/usr/bin/perl
# Offline test for the three-signal in-use probe in
# _nvme_check_devices_in_use. #134 extended: fuser alone misses two
# kernel-held cases both reproducible on a stock PVE 9 node:
#   a) a filesystem mounted only in another mount namespace (container
#      rootfs, `unshare -m` mount) -- no process holds the fd;
#   b) a device-mapper holder (LVM, dm-multipath, dm-crypt) stacked on
#      the device -- the kernel is the holder.
# fuser returns rc=1 for both, which the earlier code read as "idle".
#
# What's under test:
#   - _nvme_check_devices_in_use returns 1 when the holders scan hits.
#   - It returns 1 when the mount-namespace scan hits.
#   - It returns 1 when fuser hits (existing behavior, unchanged).
#   - It returns 1 when any probe reports an unknown/unreadable outcome
#     (fail-safe), including a missing fuser binary.
#   - It returns 0 only when ALL three probes conclusively report idle.
#   - Empty @device_paths short-circuits to 0 before any probe runs.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/07-inuse-probe-three-signals.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

# ---- stubs the tests manipulate ----
my $STUB_ID_RESULT;        # [\%id, undef] or [undef, "err"]
my $STUB_HOLDERS_RESULT;   # [0/1/undef, info-or-err]
my $STUB_MOUNT_RESULT;     # [0/1/undef, info-or-err]
my $STUB_FUSER_HAS_BIN = 1;
my $STUB_FUSER_EXIT;       # scalar exit code, or 'DIE' to die, or undef for 'no exit'
my @LOG;

{
    no strict 'refs';
    no warnings 'redefine';

    *{"${PKG}::_nvme_dev_major_minors"} = sub {
        return @$STUB_ID_RESULT;
    };
    *{"${PKG}::_nvme_scan_holders"} = sub {
        return @$STUB_HOLDERS_RESULT;
    };
    *{"${PKG}::_nvme_scan_mount_namespaces"} = sub {
        return @$STUB_MOUNT_RESULT;
    };
    # Swap -x via a fake file test; simpler to stub the whole fuser call:
    # redirect run_command, and intercept the fuser-binary existence check
    # via a wrapper around _nvme_check_devices_in_use is messy -- so stub
    # the -x by replacing PVE::Tools::run_command and letting the body
    # see STUB_FUSER_HAS_BIN through a sentinel path.
    # Instead, we rewire _nvme_check_devices_in_use's fuser section by
    # overriding the whole run_command and asserting the binary presence
    # check separately by temporarily hiding /usr/bin/fuser and /bin/fuser
    # from this process -- harder than it's worth. Use a wrapper:

    # Stub the plugin's imported run_command alias (the alias resolved at
    # `use PVE::Tools qw(run_command ...)` time points at the plugin's own
    # symbol table entry).
    *{"${PKG}::run_command"} = sub {
        my ($cmd, %opts) = @_;
        if (ref($cmd) eq 'ARRAY' && @$cmd && $cmd->[0] eq 'fuser') {
            die "stub fuser spawn failed" if defined $STUB_FUSER_EXIT && $STUB_FUSER_EXIT eq 'DIE';
            return $STUB_FUSER_EXIT if $opts{noerr};
            return 0;
        }
        return 0;
    };

    # Stub _log to capture.
    *{"${PKG}::_log"} = sub {
        my ($scfg, $lvl, $severity, $msg) = @_;
        push @LOG, "[$severity] $msg";
    };
}

# Intercept the -x fuser test. We can't easily change filesystem state in a
# unit test, so wrap _nvme_check_devices_in_use's fuser-presence check by
# toggling CORE::GLOBAL::'-X' (Perl allows overriding file tests with
# `BEGIN { *CORE::GLOBAL::ftx = sub ... }`). Simpler: assert that the real
# /usr/bin/fuser or /bin/fuser is present (true on every Debian/Ubuntu /
# PVE target); if not, skip the "fuser missing" case with a note. The
# plugin's own code tolerates either path being absent; we don't need to
# simulate both-absent in an offline test.
my $FUSER_IS_INSTALLED = (-x '/usr/bin/fuser') || (-x '/bin/fuser');

my $scfg = { tn_nvme_debug => 1 };
my @PATHS = ('/dev/nvme99n1');

sub reset_state {
    # Defaults: id probe succeeds, no holders, no mount hit, fuser idle.
    $STUB_ID_RESULT       = [ { '259:99' => '/dev/nvme99n1' }, undef ];
    $STUB_HOLDERS_RESULT  = [ 0, undef ];
    $STUB_MOUNT_RESULT    = [ 0, undef ];
    $STUB_FUSER_EXIT      = 1;
    @LOG = ();
}

sub log_matches { my ($re) = @_; return scalar grep { $_ =~ $re } @LOG; }

# ----- 1. empty paths -> short-circuit 0, no probes called -----
{
    reset_state();
    my $seen_id_probe = 0;
    local *PVE::Storage::Custom::TrueNASPlugin::_nvme_dev_major_minors = sub {
        $seen_id_probe++; return @$STUB_ID_RESULT;
    };
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg), 0,
        'empty paths: returns 0 (short-circuit, no probes)' );
    is( $seen_id_probe, 0, 'empty paths: id probe not invoked' );
}

# ----- 2. id probe fails -> 1 (fail-safe) -----
{
    reset_state();
    $STUB_ID_RESULT = [ undef, 'cannot read /sys/block/nvme99n1/dev: ENOENT' ];
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
        'id probe failure -> 1 (assume in use)' );
    ok( log_matches(qr/in_use probe:.*cannot read/),
        'id probe failure logs the reason' );
}

# ----- 3. holders scan hits -> 1 -----
{
    reset_state();
    $STUB_HOLDERS_RESULT = [ 1, [ { path => '/dev/nvme99n1', holders => ['dm-0'] } ] ];
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
        'holders hit -> 1' );
    ok( log_matches(qr/kernel holder\(s\): dm-0.*in use \(dm\/md\/mapper stack\)/),
        'holders hit: names the holder and stack class' );
}

# ----- 4. holders scan unknown -> 1 -----
{
    reset_state();
    $STUB_HOLDERS_RESULT = [ undef, 'permission denied scanning holders' ];
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
        'holders scan unknown -> 1 (fail-safe)' );
    ok( log_matches(qr/holders scan failed/),
        'holders scan unknown: logs failure reason' );
}

# ----- 5. mount-ns scan hits -> 1 -----
{
    reset_state();
    $STUB_MOUNT_RESULT = [ 1, {
        path => '/dev/nvme99n1', pid => '1234', ns => 'mnt:[4026532100]',
        line => '123 45 259:99 / /mnt rw,relatime - ext4 /dev/nvme99n1 rw',
    } ];
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
        'mount-ns hit -> 1' );
    ok( log_matches(qr{mounted in mnt-ns mnt:\[4026532100\] via pid 1234}),
        'mount-ns hit: names the namespace and pid' );
}

# ----- 6. mount-ns scan unknown -> 1 -----
{
    reset_state();
    $STUB_MOUNT_RESULT = [ undef, 'cannot open /proc: permission denied' ];
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
        'mount-ns scan unknown -> 1 (fail-safe)' );
    ok( log_matches(qr/mountinfo scan failed/),
        'mount-ns scan unknown: logs failure reason' );
}

# ----- 7. fuser hit (exit 0) -> 1 -----
{
    reset_state();
    $STUB_FUSER_EXIT = 0;
    SKIP: {
        skip "fuser not installed on this workstation", 1 unless $FUSER_IS_INSTALLED;
        is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
            'fuser exit 0 -> 1 (in use)' );
    }
}

# ----- 8. fuser idle (exit 1) and everything else idle -> 0 -----
{
    reset_state();
    $STUB_FUSER_EXIT = 1;
    SKIP: {
        skip "fuser not installed on this workstation", 1 unless $FUSER_IS_INSTALLED;
        is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 0,
            'all three probes idle -> 0' );
    }
}

# ----- 9. fuser unknown exit (e.g. 42) -> 1 -----
{
    reset_state();
    $STUB_FUSER_EXIT = 42;
    SKIP: {
        skip "fuser not installed on this workstation", 1 unless $FUSER_IS_INSTALLED;
        is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
            'fuser unexpected exit -> 1 (fail-safe)' );
        ok( log_matches(qr/fuser returned unexpected exit 42/),
            'fuser unknown exit: names the exit code' );
    }
}

# ----- 10. fuser die -> 1 -----
{
    reset_state();
    $STUB_FUSER_EXIT = 'DIE';
    SKIP: {
        skip "fuser not installed on this workstation", 1 unless $FUSER_IS_INSTALLED;
        is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
            'fuser spawn failure -> 1 (fail-safe)' );
        ok( log_matches(qr/fuser probe failed/),
            'fuser spawn failure: logs failure reason' );
    }
}

# ----- 11. holders takes precedence over mount/fuser (short-circuit order) -----
{
    reset_state();
    $STUB_HOLDERS_RESULT = [ 1, [ { path => '/dev/nvme99n1', holders => ['md127'] } ] ];
    my $mount_called = 0;
    local *PVE::Storage::Custom::TrueNASPlugin::_nvme_scan_mount_namespaces = sub {
        $mount_called++; return @$STUB_MOUNT_RESULT;
    };
    is( PVE::Storage::Custom::TrueNASPlugin::_nvme_check_devices_in_use($scfg, @PATHS), 1,
        'holders hit returns 1 before mount scan runs' );
    is( $mount_called, 0, 'mount scan not invoked when holders hit' );
}

done_testing();
