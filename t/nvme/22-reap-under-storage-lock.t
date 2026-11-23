#!/usr/bin/perl
# Offline regression for GitHub #154: create_base can rename the backing
# dataset while its namespace still points at the old path.

use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $STORE = 'test-store';
my $scfg = {
    storeid => $STORE,
    shared => 1,
    tn_use_cluster_lock => 1,
    tn_dataset => 'tank/test',
    tn_subsystem_nqn => 'nqn.test',
    tn_transport_mode => 'nvme-tcp',
    tn_api_host => 'truenas.invalid',
};
my $orphan = { id => 7, device_path => 'zvol/tank/test/vm-100-disk-0' };
my ($current, $new_path, $locked, $lock_busy, $dataset_exists, $in_use, $reads);
my (@locks, @deletes, @disconnects);

{
    no strict 'refs';
    no warnings 'redefine', 'once';

    *PVE::Storage::config = sub { {} };
    *PVE::Storage::storage_config = sub { $scfg };
    *PVE::Storage::Plugin::cluster_lock_storage = sub {
        my (undef, $storeid, $shared, $timeout, $work, @args) = @_;
        push @locks, [$storeid, $shared, $timeout];
        die "recursive lock\n" if $locked;
        die "storage lock timed out\n" if $lock_busy;

        $current->{device_path} = $new_path if defined $new_path;
        $locked = 1;
        my $result = eval { $work->(@args) };
        $locked = 0;
        die $@ if $@;
        return $result;
    };

    *{"${PKG}::_log"} = sub {};
    *{"${PKG}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        return [{ id => 23 }] if $method eq 'nvmet.subsys.query';
        if ($method eq 'nvmet.namespace.query') {
            return [] if grep { $_->[0] eq 'device_uuid' } @{$args->[0]};
            $reads++;
            # The bulk snapshot can still show the old path. Only the
            # targeted read sees the update completed by the lock holder.
            return [$current] if grep { $_->[0] eq 'id' } @{$args->[0]};
            return [$orphan];
        }
        if ($method eq 'pool.dataset.query') {
            $reads++;
            return [{ id => 'tank/test/live' }];
        }
        if ($method eq 'pool.dataset.get_instance') {
            $reads++;
            return { id => $args->[0] } if $dataset_exists;
            die "[ENOENT] InstanceNotFound\n";
        }
        if ($method eq 'nvmet.namespace.delete') {
            push @deletes, [$args->[0], $locked];
            return 1;
        }
        die "unexpected RPC $method\n";
    };

    *{"${PKG}::_nvme_delete_namespace"} = sub {};
    *{"${PKG}::_api_call_mutate"} = sub {};
    *{"${PKG}::usleep"} = sub ($) {};
    *{"${PKG}::run_command"} = sub {};
    *{"${PKG}::_nvme_rescan_subsystem_controllers"} = sub {};
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { { linux_device_count => 1 } };
    *{"${PKG}::_nvme_is_connected"} = sub { 1 };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub { '/dev/nvme0n1' };
    # Suppress the unrelated i==35 reconnect, leaving i==150 eligible.
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { $in_use++ == 0 };
    *{"${PKG}::_nvme_connect"} = sub {};
    *{"${PKG}::_nvme_disconnect"} = sub { push @disconnects, $locked };
}

sub reset_capture {
    $current = { %$orphan };
    $new_path = undef;
    ($locked, $lock_busy, $dataset_exists, $in_use, $reads) = (0, 0, 0, 0, 0);
    @locks = @deletes = @disconnects = ();
}

sub run_activation {
    local $scfg->{storeid};
    eval { $PKG->activate_volume($STORE, $scfg, 'vol-vm-101-disk-0-nsdeadbeef', undef, {}) };
}

my $reap = $PKG->can('_nvme_reap_orphan_namespaces');

reset_capture();
$new_path = 'zvol/tank/test/base-100-disk-0';
$reap->($scfg);
is(scalar @deletes, 0, 'keeps a namespace whose device path changed');

reset_capture();
$dataset_exists = 1;
$reap->($scfg);
is(scalar @deletes, 0, 'keeps a namespace whose dataset now exists');

reset_capture();
{
    local $scfg->{storeid};
    $PKG->cluster_lock_storage($STORE, 1, undef, sub {
        $PKG->free_image($STORE, $scfg, 'vm-101-disk-0', 0, 'raw');
    });
}
is_deeply(\@deletes, [[7, 1]], 'deferred free_image reaps the unchanged orphan under the lock');
is(scalar @locks, 2, 'deferred free_image acquires the storage lock again');

reset_capture();
$PKG->cluster_lock_storage($STORE, 1, undef, sub { $reap->($scfg) });
is_deeply(\@deletes, [[7, 1]], 'reaps under the caller-held lock');
is(scalar @locks, 1, 'does not reacquire the caller-held lock');

reset_capture();
$lock_busy = 1;
eval { $reap->($scfg) };
is($reads, 0, 'does not read candidates when the storage lock is unavailable');
is(scalar @deletes, 0, 'does not delete when the storage lock is unavailable');

reset_capture();
$lock_busy = 1;
run_activation();
is_deeply(\@locks, [[$STORE, 1, 1]], 'emergency reconnect requests the same lock with a one-second timeout');
is($reads, 0, 'emergency reconnect does not read candidates on lock timeout');
is(scalar @deletes, 0, 'emergency reconnect does not delete on lock timeout');
is(scalar @disconnects, 0, 'emergency reconnect does not disconnect on lock timeout');

reset_capture();
run_activation();
is_deeply(\@deletes, [[7, 1]], 'emergency reconnect reaps under the storage lock');
is_deeply(\@disconnects, [1], 'emergency reconnect disconnects under the storage lock');

reset_capture();
{
    local $scfg->{storeid};
    local $scfg->{tn_use_cluster_lock} = 0;
    $reap->($scfg);
}
is(scalar @locks, 0, 'opt-out makes no storage lock attempts');
is_deeply(\@deletes, [[7, 0]], 'opt-out still deletes an orphan without the lock');

done_testing();
