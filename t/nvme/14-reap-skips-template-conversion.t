#!/usr/bin/perl -T
# Run with:  perl -T -I t/nvme/lib t/nvme/14-reap-skips-template-conversion.t
# argo-management/26: the orphan reaper must not delete the namespace of a disk
# that create_base is converting (namespace disabled, vm- zvol renamed to base-),
# or the rewire fails ENOENT and leaves a half-converted template.
use strict; use warnings; use Test::More; use FindBin; use JSON::PP ();
my ($PLUGIN) = ("$FindBin::Bin/../../TrueNASPlugin.pm" =~ /^(.*)$/);
require $PLUGIN;
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $DS = 'pool/eph';
my (@ns, %ds, @deleted, @logs);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, $_[3] };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $m, $args) = @_;
        return [ { id => 1 } ] if $m eq 'nvmet.subsys.query';
        if ($m eq 'nvmet.namespace.query') {
            # #162's re-check filters by id: [ [ 'subsys.id', '=', X ], [ 'id', '=', NSID ] ].
            # When a second clause is present, return just that namespace.
            my $filters = $args->[0];
            if (ref($filters) eq 'ARRAY' && @$filters >= 2) {
                my $want = $filters->[1][2];
                return [ grep { ($_->{id} // '') eq $want } @ns ];
            }
            return [ @ns ];
        }
        return [ map { { id => $_ } } keys %ds ] if $m eq 'pool.dataset.query';
        # #162's re-check calls pool.dataset.get_instance before each delete.
        if ($m eq 'pool.dataset.get_instance') {
            my $full = $args->[0];
            return { id => $full } if $ds{$full};
            die "[ENOENT] Dataset does not exist\n";
        }
        if ($m eq 'nvmet.namespace.delete') { push @deleted, $args->[0]; return 1; }
        die "unexpected $m";
    };
}
my $reap = $PKG->can('_nvme_reap_orphan_namespaces');
my $scfg = { tn_subsystem_nqn => 'nqn.x', tn_dataset => $DS };
my $ns = sub { my ($id, $z, $en) = @_;
    { id => $id, nsid => $id, device_uuid => "u$id", device_path => "zvol/$DS/$z", enabled => $en } };
my $run = sub { @deleted = (); @logs = (); $reap->($scfg); [ sort { $a <=> $b } @deleted ] };

# 1. The 9074 case: disabled, vm- gone, base- present -> kept.
@ns = ($ns->(17107, 'vm-9074-disk-3', JSON::PP::false));
%ds = ("$DS/base-9074-disk-3" => 1);
is_deeply($run->(), [], 'disabled namespace mid-conversion (base- sibling exists) is not reaped');
ok((grep { /keeping id=17107 .*base- sibling exists/ } @logs), 'a kept conversion is logged');

# 2. Race: the namespace snapshot predates create_base's disable (enabled=true),
#    the dataset snapshot postdates its rename -> still kept.
@ns = ($ns->(5, 'vm-9074-disk-3', JSON::PP::true));
is_deeply($run->(), [], 'enabled vm- namespace with a base- sibling is kept (query-order race)');

# 2b. `enabled` absent -> same rule, kept.
@ns = ({ id => 9, nsid => 9, device_uuid => 'u9', device_path => "zvol/$DS/vm-9074-disk-3" });
is_deeply($run->(), [], 'namespace without an enabled field is kept when a base- sibling exists');

# 3. Disabled vm- namespace, no base- sibling -> real orphan, reaped.
@ns = ($ns->(6, 'vm-9075-disk-0', JSON::PP::false));
%ds = ();
is_deeply($run->(), [6], 'disabled orphan without a base- sibling is reaped');

# 4. Backing dataset exists -> kept (unchanged behaviour).
@ns = ($ns->(7, 'vm-9076-disk-0', JSON::PP::true));
%ds = ("$DS/vm-9076-disk-0" => 1);
is_deeply($run->(), [], 'namespace with its dataset present is kept');

# 5. A base- namespace with nothing behind it is not mapped to base-base-; reaped.
@ns = ($ns->(8, 'base-9077-disk-0', JSON::PP::false));
%ds = ();
is_deeply($run->(), [8], 'disabled base- orphan is reaped (no sibling rule for base-)');

# 6. Mixed batch: only the mid-conversion one survives.
@ns = ($ns->(10, 'vm-1-disk-0', JSON::PP::false), $ns->(11, 'vm-2-disk-0', JSON::PP::true),
       $ns->(12, 'vm-3-disk-0', JSON::PP::false));
%ds = ("$DS/base-1-disk-0" => 1);
is_deeply($run->(), [11, 12], 'mixed batch: conversion kept, the rest reaped');

done_testing();
