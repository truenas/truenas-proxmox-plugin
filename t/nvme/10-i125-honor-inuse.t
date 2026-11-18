#!/usr/bin/perl
# Offline test for the i==125 "last-resort reconnect" tier of
# _nvme_device_for_uuid (GitHub #146).
#
# What's under test:
#   - At i==75 AND i==125, when the subsystem is in use by another
#     process on this host, the mid-loop reconnect gate must SKIP the
#     disconnect/reconnect call.
#   - When the subsystem is idle, the reconnect still fires (at i==75;
#     the $reconnect_attempted latch prevents a second fire at i==125).
#
# Earlier plugin versions forced the reconnect at i==125 regardless of
# in-use. The holders+mountinfo probe added in #134 makes the in-use
# signal reliable enough to honour, and forcing the reconnect under
# live consumers caused real data-plane disruption on other VMs and
# containers sharing the subsystem.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/10-i125-honor-inuse.t

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
my $UUID = '11111111-2222-3333-4444-555555555555';

# Stub state the tests manipulate.
my $STUB_IN_USE   = 0;
my @DISCONNECTS   = ();
my @CONNECTS      = ();
my @LOG           = ();

{
    no strict 'refs';
    no warnings 'redefine';

    *{"${PKG}::usleep"} = sub ($) { 1 };

    *{"${PKG}::_log"} = sub {
        my (undef, $lvl, $sev, $msg) = @_;
        push @LOG, { lvl => $lvl, sev => $sev, msg => $msg };
    };

    # Device never found — forces the loop to iterate through 150 ticks
    # and hit both reconnect tiers.
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub {
        return {
            selected_device_path => undef,
            linux_device_count   => 4,
            match_tier           => undef,
            reason               => 'namespace_uuid_not_returned',
            detail               => 'stubbed',
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
        my ($r, $nqn) = @_; return "stub failure detail for ${nqn}";
    };

    *{"${PKG}::_nvme_is_connected"} = sub { 1 };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub {
        return ('/dev/nvme0n1', '/dev/nvme0n2');
    };

    # Gate under test.
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { $STUB_IN_USE };

    # Crucial difference from 06: TN API returns the UUID, so both
    # mid-loop tiers DO enter the reconnect branch.
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $args) = @_;
        if ($method eq 'nvmet.namespace.query') {
            return [ { id => 1, device_uuid => $UUID } ];
        }
        return [];
    };
    *{"${PKG}::_api_call_mutate"} = sub { return []; };

    *{"${PKG}::_nvme_disconnect"} = sub { push @DISCONNECTS, [@_]; 1 };
    *{"${PKG}::_nvme_connect"}    = sub { push @CONNECTS,    [@_]; 1 };

    # Supporting stubs to keep the emergency `else` branch quiet.
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
    eval { $PKG->can('_nvme_device_for_uuid')->($scfg, $UUID, allow_reconnect => 1); };
    return $@;
}

sub log_count {
    my ($rx) = @_;
    return scalar(grep { $_->{msg} =~ $rx } @LOG);
}

# ----- Case 1: in_use=1 → BOTH tiers skip (no disconnect ever) ------
{
    reset_capture();
    $STUB_IN_USE = 1;
    my $err = run_lookup();
    ok($err, 'in-use case: function dies (device never found)');

    is(scalar @DISCONNECTS, 0,
        'in-use case: no _nvme_disconnect calls at i==75 or i==125');
    is(scalar @CONNECTS, 0,
        'in-use case: no _nvme_connect calls either');

    is(log_count(qr/i==75 reconnect SKIPPED/), 1,
        'in-use case: i==75 SKIPPED fires exactly once');
    is(log_count(qr/i==125 reconnect SKIPPED/), 1,
        'in-use case: i==125 SKIPPED fires exactly once (previously FIRING)');
    is(log_count(qr/i==\d+ reconnect FIRING/), 0,
        'in-use case: no FIRING log at either tier');
    ok(log_count(qr/holding off to avoid disrupting live consumers/) >= 1,
        'in-use case: skip log explains why');
}

# Case 2 is covered by t/nvme/06: when any mid-loop reconnect gate
# (i==35 stale-NGUID, i==75 halfway, i==125 last-resort) sees in_use=0,
# it fires and latches $reconnect_attempted. The specific firing tier
# depends on earlier gates, which 06 already exercises. Here the point
# is strictly that i==125 no longer overrides an in-use signal.

done_testing();
