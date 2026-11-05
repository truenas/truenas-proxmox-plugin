#!/usr/bin/perl
# Offline test for the i==150 "emergency reconnect" in-use gate added
# for GitHub #131.
#
# What's under test (TrueNASPlugin.pm, inside _nvme_device_for_uuid):
#   - When the 150-iter device-lookup loop exhausts and the subsystem
#     is in use by another process on this host, the post-loop
#     "emergency reconnect" must be refused: NO call to _nvme_disconnect
#     + _nvme_connect, and the SKIPPED/#131 log line must fire.
#   - When the loop exhausts and the subsystem is idle, the emergency
#     reconnect still runs: _nvme_disconnect + _nvme_connect are
#     invoked, and the "EMERGENCY RECONNECT ... flushing stale kernel
#     namespace cache" log line fires.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/06-emergency-reconnect-gate.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $NQN = 'nqn.2011-06.com.truenas:uuid:test:pve';

# Stub state the tests manipulate.
my $STUB_IN_USE   = 0;   # value _nvme_check_devices_in_use returns
my @DISCONNECTS   = ();
my @CONNECTS      = ();
my @LOG           = ();

{
    no strict 'refs';
    no warnings 'redefine';

    # Make the retry loop instant.
    *{"${PKG}::usleep"} = sub ($) { 1 };

    # Capture log entries so we can assert on them.
    *{"${PKG}::_log"} = sub {
        my (undef, $lvl, $sev, $msg) = @_;
        push @LOG, { lvl => $lvl, sev => $sev, msg => $msg };
    };

    # Device lookup always misses: no device matched, 4 Linux-visible
    # devices (so $ever_saw_devices=1, which keeps the i==25
    # "no-devices-ever" gate from firing). match_tier undef, so
    # $nguid_ever_matched stays 0. nguid_contradicted undef so the
    # i==10 gate also skips. The i==35 gate still has grounds to
    # fire; see _nvme_check_devices_in_use below.
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub {
        return {
            selected_device_path => undef,
            linux_device_count   => 4,
            match_tier           => undef,
            reason               => 'namespace_uuid_not_returned',
            detail               => 'TrueNAS API did not return the target namespace UUID',
        };
    };
    *{"${PKG}::_nvme_selector_selected_device_path"} = sub {
        my ($r) = @_; return undef unless $r && ref($r) eq 'HASH';
        return $r->{selected_device_path};
    };
    *{"${PKG}::_nvme_selector_linux_device_count"} = sub {
        my ($r) = @_; return 0 unless $r && ref($r) eq 'HASH';
        return $r->{linux_device_count} // 0;
    };
    *{"${PKG}::_nvme_selector_failure_detail"} = sub {
        my ($r, $nqn) = @_;
        return "stub failure detail for ${nqn}";
    };

    # Subsystem is connected; a nonempty device path set exists.
    *{"${PKG}::_nvme_is_connected"} = sub { 1 };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub {
        return ('/dev/nvme0n1', '/dev/nvme0n2');
    };

    # The gate under test: honor the per-test setting.
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { $STUB_IN_USE };

    # TN API: namespace query for the bogus UUID returns empty, so the
    # i==75 / i==125 mid-loop reconnect gates (which require
    # tn_has_uuid) do not fire.
    *{"${PKG}::_api_call"}         = sub { return []; };
    *{"${PKG}::_api_call_mutate"}  = sub { return []; };

    # Count reconnect-related calls (the actual thing we're asserting on).
    *{"${PKG}::_nvme_disconnect"}  = sub { push @DISCONNECTS, [@_]; 1 };
    *{"${PKG}::_nvme_connect"}     = sub { push @CONNECTS,    [@_]; 1 };

    # Supporting stubs so the emergency `else` branch doesn't blow up
    # when it runs in the negative-case test.
    *{"${PKG}::_nvme_rescan_subsystem_controllers"} = sub { 1 };
    *{"${PKG}::_nvme_reap_orphan_namespaces"}       = sub { 0 };
    *{"${PKG}::run_command"} = sub { 0 };
}

sub reset_capture {
    $STUB_IN_USE = 0;
    @DISCONNECTS = ();
    @CONNECTS    = ();
    @LOG         = ();
}

sub make_scfg {
    return {
        tn_dataset        => 'tank/pve',
        tn_api_host       => '203.0.113.1',
        tn_transport_mode => 'nvme-tcp',
        tn_subsystem_nqn  => $NQN,
        tn_api_scheme     => 'wss',
    };
}

sub run_lookup {
    my $scfg = make_scfg();
    my $uuid = '00000000-0000-0000-0000-000000000000';
    # Function dies at the end because the device is never found.
    eval { $PKG->can('_nvme_device_for_uuid')
        ->($scfg, $uuid, allow_reconnect => 1); };
    return $@;
}

sub log_matches {
    my ($rx) = @_;
    for my $e (@LOG) {
        return 1 if $e->{msg} =~ $rx;
    }
    return 0;
}

# ----- Case 1: fuser says in-use → gate must SKIP the reconnect ------
{
    reset_capture();
    $STUB_IN_USE = 1;
    my $err = run_lookup();
    ok($err, 'in-use case: function dies as expected (no device found)');

    is(scalar @DISCONNECTS, 0,
        'in-use case: _nvme_disconnect must NOT be called by the emergency path');
    is(scalar @CONNECTS, 0,
        'in-use case: _nvme_connect must NOT be called by the emergency path');

    ok(log_matches(qr/emergency reconnect SKIPPED/),
        'in-use case: SKIPPED log line fired');
    ok(log_matches(qr/subsystem is in use by other process/),
        'in-use case: log explains why');
    ok(log_matches(qr/GitHub #131/),
        'in-use case: log references the issue');
    ok(!log_matches(qr/EMERGENCY RECONNECT after 150-iteration budget/),
        'in-use case: emergency reconnect line NOT fired');
}

# ----- Case 2: fuser says clear → emergency reconnect runs ---------
{
    reset_capture();
    $STUB_IN_USE = 0;
    my $err = run_lookup();
    ok($err, 'idle case: function dies as expected (device still not visible)');

    ok(scalar @DISCONNECTS >= 1,
        'idle case: _nvme_disconnect called by the emergency path (count='
        . scalar(@DISCONNECTS) . ')');
    ok(scalar @CONNECTS >= 1,
        'idle case: _nvme_connect called by the emergency path (count='
        . scalar(@CONNECTS) . ')');

    ok(log_matches(qr/i==150 emergency reconnect FIRING/),
        'idle case: emergency reconnect FIRING log line fired');
    ok(!log_matches(qr/emergency reconnect SKIPPED.+subsystem is in use/),
        'idle case: SKIPPED(in-use) log line NOT fired');
}

# ----- Case 3: fuser-not-installed fallback (fail-safe assume-in-use) ---
{
    # _nvme_check_devices_in_use returning 1 is also what the real
    # helper does when `fuser` is not on PATH. The gate must still skip.
    reset_capture();
    $STUB_IN_USE = 1;
    run_lookup();
    is(scalar @DISCONNECTS, 0,
        'fuser-missing fallback: gate still skips (fail-safe path)');
    ok(log_matches(qr/emergency reconnect SKIPPED/),
        'fuser-missing fallback: SKIPPED log line fired');
}

done_testing();
