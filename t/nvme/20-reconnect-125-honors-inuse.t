#!/usr/bin/perl
# Offline regression test for the i==75 / i==125 reconnect gates (GitHub #146).

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $UUID = '00000000-0000-0000-0000-000000000000';
my $SCFG = {
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.truenas:uuid:test:pve',
    tn_api_host       => 'truenas.example.invalid',
};

my ($in_use, $lookups, $disconnects, $connects);
my @log;

{
    no strict 'refs';
    no warnings 'redefine';

    *{"${PKG}::usleep"} = sub ($) { 1 };
    *{"${PKG}::_log"} = sub { push @log, $_[3] };
    *{"${PKG}::run_command"} = sub { 0 };
    *{"${PKG}::_nvme_rescan_subsystem_controllers"} = sub { 1 };

    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub {
        $lookups++;
        return { linux_device_count => 2 };
    };

    # The first lookup is at i==0. Expose a connection to the i==75/125
    # gates while keeping the earlier gates and the i==150 emergency out.
    *{"${PKG}::_nvme_is_connected"} = sub { $lookups >= 76 && $lookups < 150 };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub {
        return ('/dev/nvme0n1', '/dev/nvme0n2');
    };
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { $in_use };

    *{"${PKG}::_api_call"} = sub {
        my (undef, $method) = @_;
        return $method eq 'nvmet.namespace.query' ? [{ id => 1 }] : [];
    };

    *{"${PKG}::_nvme_disconnect"} = sub { $disconnects++; 1 };
    *{"${PKG}::_nvme_connect"} = sub { $connects++; 1 };
}

sub run_lookup {
    ($in_use) = @_;
    $lookups = $disconnects = $connects = 0;
    @log = ();

    my $device = eval {
        $PKG->can('_nvme_device_for_uuid')->($SCFG, $UUID, allow_reconnect => 1);
    };
    return ($device, $@);
}

subtest 'busy subsystem skips both reconnects' => sub {
    my ($device, $error) = run_lookup(1);

    is($disconnects, 0, 'busy subsystem is never disconnected');
    is($connects, 0, 'busy subsystem is never reconnected');
    ok(!$device, 'no device path is returned');
    like($error, qr/Could not locate NVMe device/, 'lookup reports the missing device');
    for my $tier (75, 125) {
        ok(scalar(grep { /i==$tier reconnect SKIPPED/ } @log),
            "i==$tier logs that the reconnect was skipped");
    }
};

subtest 'idle subsystem can reconnect' => sub {
    run_lookup(0);

    cmp_ok($disconnects, '>=', 1, 'idle subsystem is disconnected for recovery');
    cmp_ok($connects, '>=', 1, 'idle subsystem is reconnected for recovery');
};

done_testing();
