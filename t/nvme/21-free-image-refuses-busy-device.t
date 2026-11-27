#!/usr/bin/perl
# free_image on NVMe must check local use before its first mutation.
# Runs without a TrueNAS or PVE host: the API, the device lookup and the
# in-use probe are stubbed, and the test counts the destructive calls.

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $UUID = '00000000-0000-0000-0000-000000000021';
my $OTHER = '00000000-0000-0000-0000-000000000022';
my $DEVICE = '/dev/nvme21n1';
my $scfg = {
    tn_dataset        => 'tank/pve',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.example:free-image',
};

my (@namespaces, %deletes, %lookup, %busy, $query_fails, @looked_up);
{
    no strict 'refs';
    no warnings 'redefine';

    *{"${PKG}::_log"} = sub {};
    *{"${PKG}::_defer_after_lock"} = sub {};
    *{"${PKG}::_unlink_status_stamp"} = sub {};
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub {
        my (undef, $uuid) = @_;
        push @looked_up, $uuid;
        return $lookup{$uuid} // { selector_outcome => 'metadata_failure',
            mismatch_reason => 'namespace_uuid_not_returned' };
    };
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { return $busy{$_[1]} ? 1 : 0 };
    *{"${PKG}::_api_call"} = sub {
        my (undef, $method, $params) = @_;
        if ($method eq 'nvmet.namespace.query') {
            die "simulated API failure\n" if $query_fails;
            my ($field, undef, $value) = @{$params->[0][0]};
            return [ grep { $_->{subsys}{id} eq $value } @namespaces ] if $field eq 'subsys.id';
            return [ grep { $_->{$field} eq $value } @namespaces ];
        }
        return [ { id => 1 } ] if $method eq 'nvmet.subsys.query';
        return { children => [] } if $method eq 'pool.dataset.get_instance';
        if ($method eq 'nvmet.namespace.delete' || $method eq 'pool.dataset.delete') {
            $deletes{$method}++;
            return undef;
        }
        die "unexpected API method $method\n";
    };
    *{"${PKG}::_api_call_mutate"} = sub { goto &{"${PKG}::_api_call"} };
}

my $zname = 'vm-100-disk-0';
my $with_uuid = "vol-$zname-ns$UUID";   # volname carries the namespace UUID
my $legacy = 'vm-100-cloudinit';        # volname without a UUID

sub selected { { selector_outcome => 'exact_match', selected_device_path => $DEVICE } }

# %o: volname, zname, ns_uuid (UUID of the namespace on the zvol, undef = none),
# lookup (uuid => selector result), busy (device => 1), query_fails.
sub run_free {
    my (%o) = @_;
    @namespaces = defined($o{ns_uuid}) ? ({
        id => 1, nsid => 1, subsys => { id => 1 },
        device_path => "zvol/$scfg->{tn_dataset}/$o{zname}", device_uuid => $o{ns_uuid},
    }) : ();
    %lookup = %{ $o{lookup} // {} };
    %busy = %{ $o{busy} // {} };
    $query_fails = $o{query_fails};
    @looked_up = ();
    %deletes = ();
    my $err = eval {
        my $worker = $PKG->free_image('nvme', $scfg, $o{volname}, undef, 'raw');
        $worker->() if ref($worker) eq 'CODE';
        '';
    };
    return defined($err) ? $err : $@;
}

sub counts_are {
    my ($ns, $ds, $label) = @_;
    is($deletes{'nvmet.namespace.delete'} // 0, $ns, "$label: namespace delete calls");
    is($deletes{'pool.dataset.delete'} // 0, $ds, "$label: dataset delete calls");
}

for my $vol ([$with_uuid, $zname], [$legacy, $legacy]) {
    my ($volname, $name) = @$vol;
    my %base = (volname => $volname, zname => $name, ns_uuid => $UUID);

    my $err = run_free(%base, lookup => { $UUID => selected() }, busy => { $DEVICE => 1 });
    like($err, qr/\Q$DEVICE\E is still in use/, "busy device refuses ($name)");
    counts_are(0, 0, "busy ($name)");

    $err = run_free(%base, lookup => { $UUID => { selector_outcome => 'metadata_failure',
        mismatch_reason => 'namespace_metadata_query_failed' } });
    like($err, qr/could not tell whether.*namespace_metadata_query_failed/, "failed lookup refuses ($name)");
    counts_are(0, 0, "lookup failed ($name)");

    $err = run_free(%base, lookup => { $UUID => { selector_outcome => 'publication_mismatch',
        mismatch_reason => 'linux_device_missing' } });
    like($err, qr/could not tell whether/, "publication mismatch refuses ($name)");
    counts_are(0, 0, "publication mismatch ($name)");

    $err = run_free(%base, lookup => { $UUID => { selector_outcome => 'publication_mismatch',
        mismatch_reason => 'subsystem_not_visible' } });
    is($err, '', "subsystem not connected on this node is freed ($name)");
    counts_are(1, 1, "subsystem not visible ($name)");

    $err = run_free(%base, lookup => { $UUID => selected() });
    is($err, '', "idle device is freed ($name)");
    counts_are(1, 1, "idle ($name)");
}

# The volname UUID is stale: the zvol's real namespace has another UUID and is
# in use. The guard must check the namespace that would actually be deleted.
my $err = run_free(volname => $with_uuid, zname => $zname, ns_uuid => $OTHER,
    lookup => { $OTHER => selected() }, busy => { $DEVICE => 1 });
like($err, qr/\Q$DEVICE\E is still in use/, 'stale volname UUID: the real namespace is checked');
ok((grep { $_ eq $OTHER } @looked_up), 'stale volname UUID: the zvol namespace was looked up');
counts_are(0, 0, 'stale volname UUID');

# Namespace already gone, volname without UUID: nothing to check.
$err = run_free(volname => $legacy, zname => $legacy, ns_uuid => undef);
is($err, '', 'absent namespace (legacy volname) still frees the zvol');
is(scalar(@looked_up), 0, 'absent namespace (legacy volname): no device lookup');
counts_are(0, 1, 'absent namespace (legacy volname)');

# Namespace already gone, volname with UUID: TrueNAS no longer returns it.
$err = run_free(volname => $with_uuid, zname => $zname, ns_uuid => undef);
is($err, '', 'absent namespace (UUID volname) still frees the zvol');
counts_are(0, 1, 'absent namespace (UUID volname)');

# A failed namespace query must not be read as "nothing to check".
$err = run_free(volname => $legacy, zname => $legacy, ns_uuid => $UUID, query_fails => 1,
    lookup => { $UUID => selected() });
like($err, qr/simulated API failure/, 'failed namespace query refuses');
counts_are(0, 0, 'namespace query failed');

done_testing();
