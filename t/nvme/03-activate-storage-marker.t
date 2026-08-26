#!/usr/bin/perl
# activate_storage() must honour the recent-failure marker too - by CAPPING the
# work, never by skipping it.
#
# 02-status-probe-backoff.t proved the marker stops status() from re-probing a
# dead array. It does not cover the caller that actually dominates the cost:
# PVE::Storage::storage_info() calls activate_storage() BEFORE status() on
# every sweep, and the nvme-tcp branch calls _nvme_ensure_subsystem(), whose
# first act is an unconditional nvmet.subsys.query. Without a cap there, the
# marker suppresses status()'s own probes and none of the real bill.
#
# The first attempt at this SKIPPED the ensure while the marker stood. That is
# wrong: _nvme_ensure_subsystem() is the only periodic caller of
# _nvme_sync_portals(), which republishes ports the target lost - and that
# cache is invalidated exactly when a connect fails, i.e. precisely when the
# skip would kick in. So the contract under test is:
#
#   with the marker standing, the ensure STILL RUNS, under a short deadline.
#
# The assertions that matter most are the negative ones - that the cap does NOT
# apply when it should not - because a gate that is always on is indistinguishable
# from the skip that was rejected.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/03-activate-storage-marker.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "activate_storage not found" unless $PKG->can('activate_storage');
plan skip_all => "_api_recently_down not found (unpatched tree?)"
    unless $PKG->can('_api_recently_down');

my ($ensure_calls, $connect_calls, $cli_calls, $deadline_seen, $fail_api, $ensure_dies);

# Plain functions, not methods: calling them with -> would pass the package name
# as $scfg. Take real code refs instead.
my ($recently_down, $probe_backoff);
{ no strict "refs";
  $recently_down = \&{"${PKG}::_api_recently_down"};
  $probe_backoff = \&{"${PKG}::_status_probe_backoff"}; }

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_nvme_check_cli"} = sub { $cli_calls++; 1 };
    *{"${PKG}::_nvme_connect"}   = sub { $connect_calls++; 1 };
    *{"${PKG}::_nvme_ensure_subsystem"} = sub {
        $ensure_calls++;
        # Snapshot the deadline the caller installed: this is how we tell a
        # capped call from an uncapped one without reaching into the guts.
        my $dl = ${"${PKG}::_api_deadline"};
        $deadline_seen = defined($dl) ? $dl - time() : undef;
        die "ensure exploded\n" if $ensure_dies;
        return 1;
    };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method) = @_;
        die $fail_api if defined $fail_api;
        return {
            id => 'tank/pve', type => 'FILESYSTEM',
            available => { parsed => 500 }, used => { parsed => 500 },
            written   => { parsed => 500 }, quota => { parsed => 0 },
        } if $method eq 'pool.dataset.get_instance';
        return [ { name => 'tank', status => 'ONLINE', healthy => 1 } ]
            if $method eq 'pool.query';
        return [];
    };
    *{"${PKG}::_api_call_mutate"} = sub { goto &{"${PKG}::_api_call"} };
}

my $HOSTN = 0;
sub fresh_scfg {
    my (%extra) = @_;
    $HOSTN++;
    # A distinct api_host per case: the marker is package-global and keyed per
    # host, so sharing one would let an earlier case decide a later one.
    return {
        tn_dataset        => 'tank/pve',
        tn_api_host       => "198.51.100.$HOSTN",
        tn_transport_mode => 'nvme-tcp',
        tn_subsystem_nqn  => 'nqn.2011-06.com.example:test',
        %extra,
    };
}

my $CONN_ERR = "broker: read timeout after 5s\n";

# Arm the marker the only way production does: let status() fail on connectivity.
sub arm_marker {
    my ($scfg) = @_;
    $fail_api = $CONN_ERR;
    $PKG->status('store1', $scfg, undef);
    $fail_api = undef;
    return defined($recently_down->($scfg));
}

sub activate {
    my ($scfg) = @_;
    ($ensure_calls, $connect_calls, $cli_calls, $deadline_seen) = (0, 0, 0, undef);
    my $rc = $PKG->activate_storage('store1', $scfg, undef);
    return { rc => $rc, ensure => $ensure_calls, connect => $connect_calls,
             cli => $cli_calls, budget => $deadline_seen };
}

# ------------------------------------------------------------- the premise --
{
    my $scfg = fresh_scfg();
    my $r = activate($scfg);
    is($r->{ensure}, 1, 'with no marker, activate_storage ensures the subsystem');
    ok(!defined($r->{budget}) || $r->{budget} > 5,
       '...with no short deadline imposed on it');
    is($r->{connect}, 1, '...and connects');
}

# ------------------------------------- the marker caps, and does NOT skip --
{
    my $scfg = fresh_scfg();
    ok(arm_marker($scfg), 'a connectivity failure arms the marker');

    my $r = activate($scfg);
    # THE assertion. The rejected first attempt scored 0 here, and that is the
    # regression this file exists to catch: no ensure means no portal re-sync.
    is($r->{ensure}, 1, 'with the marker standing, the ensure STILL RUNS');
    ok(defined($r->{budget}) && $r->{budget} <= 3,
       '...but under a short deadline (cap, not skip)');
    is($r->{connect}, 1, 'and _nvme_connect runs regardless of the marker');
    is($r->{cli}, 1, 'and so does _nvme_check_cli');
}

# --------------------------------------- the negative direction: no marker --
{
    my $scfg = fresh_scfg();
    my $r = activate($scfg);
    is($r->{ensure}, 1, 'without a marker the ensure runs');
    ok(!defined($r->{budget}) || $r->{budget} > 5,
       '...uncapped - a gate that is always on is just the rejected skip');
}

# ------------------------------- the escape hatch: backoff 0 disables it all --
{
    my $scfg = fresh_scfg(tn_status_probe_backoff_s => 0);
    arm_marker($scfg);
    is($recently_down->($scfg), undef,
       'tn_status_probe_backoff_s 0 disables the marker entirely');
    my $r = activate($scfg);
    is($r->{ensure}, 1, '...so the ensure runs');
    ok(!defined($r->{budget}) || $r->{budget} > 5, '...and is not capped');
}

# ------------------------------ a dying ensure must not swallow the connect --
{
    my $scfg = fresh_scfg();
    $ensure_dies = 1;
    my $r = activate($scfg);
    is($r->{ensure}, 1, 'the ensure was attempted');
    # Before this change the two calls shared one eval, so a die in the ensure
    # took _nvme_connect() with it: with the API down the fabric was not even
    # retried over sysfs, which needs no API at all.
    is($r->{connect}, 1, 'a dying ensure does not take _nvme_connect with it');
    is($r->{rc}, 1, 'activate_storage still returns 1 (fail-open, unchanged)');
    $ensure_dies = 0;
}

# --------------------------------------------- the backoff default is shared --
{
    my $scfg = fresh_scfg();
    is($probe_backoff->($scfg), 30, 'backoff default is 30 when unset');
    is($probe_backoff->(fresh_scfg(tn_status_probe_backoff_s => 45)), 45,
       'and honours an explicit value');
    is($probe_backoff->(fresh_scfg(tn_status_probe_backoff_s => 'nonsense')), 30,
       'and falls back to 30 on garbage rather than crashing');
}

done_testing();
