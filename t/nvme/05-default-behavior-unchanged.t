#!/usr/bin/perl
# Golden-rule test: with no tn_api_budget_s, no tn_status_probe_backoff_s
# override, and a healthy array, activate_storage() and status() must behave
# exactly as they did before this series - no deadline installed anywhere,
# no "marked down" note ever logged, and the classic retry-exhaustion message
# on the one path that can still fail. This is the negative space the other
# files in this directory do not cover: every marker/budget test in them
# arms the marker or configures a budget on purpose.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/05-default-behavior-unchanged.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "activate_storage/status not found"
    unless $PKG->can('activate_storage') && $PKG->can('status');

my @LOG;
my ($deadline_at_ensure, $deadline_at_status_probe, $connect_calls);

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { my (undef, $lvl, $sev, $msg) = @_;
                              push @LOG, { lvl => $lvl, sev => $sev, msg => $msg }; };
    *{"${PKG}::_nvme_check_cli"} = sub { 1 };
    *{"${PKG}::_nvme_connect"}   = sub { $connect_calls++; 1 };
    *{"${PKG}::_nvme_ensure_subsystem"} = sub {
        $deadline_at_ensure = ${"${PKG}::_api_deadline"};
        return 1;
    };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method) = @_;
        $deadline_at_status_probe = ${"${PKG}::_api_deadline"}
            if $method eq 'pool.dataset.get_instance';
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

my $scfg = {
    tn_dataset        => 'tank/pve',
    tn_api_host       => '198.51.100.200',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.example:default',
};

# ---------------------------------------- a healthy array, nothing configured --

{
    @LOG = ();
    ($deadline_at_ensure, $deadline_at_status_probe) = (undef, undef);
    my $rc = $PKG->activate_storage('store1', $scfg, undef);
    is($rc, 1, 'activate_storage succeeds against a healthy array, unconfigured');
    ok(!defined($deadline_at_ensure),
       'no deadline is installed around the ensure with nothing configured');
    ok(!(grep { $_->{msg} =~ /marked down for another/ } @LOG),
       'no recent-failure note is ever logged against a healthy array');

    @LOG = ();
    my @r = $PKG->status('store1', $scfg, undef);
    ok($r[3], 'status reports active against a healthy array, unconfigured');
    ok(!defined($deadline_at_status_probe),
       'no deadline is installed around the capacity probe either');
    ok(!(grep { $_->{msg} =~ /marked down for another/ } @LOG),
       '...and status logs no marker note either');
}

# ---------------- classification does not apply without the marker -----------
# Without tn_api_budget_s and without an armed marker, a failing ensure must
# still produce the plain, unclassified warning it always has - at the same
# log level as before - and, since the ensure and the connect run in
# separate evals, the connect must still be attempted regardless.

{
    no strict 'refs';
    local *{"${PKG}::_nvme_ensure_subsystem"} = sub {
        die "Operation failed after 3 retries: connection reset by peer\n";
    };
    @LOG = ();
    $connect_calls = 0;
    $PKG->activate_storage('store1', $scfg, undef);
    my @warn = grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG;
    is(scalar @warn, 1, 'an ensure failure with no marker standing is a plain warning');
    is($warn[0]{lvl}, 0, '...logged at level 0, same as before this series');
    ok(!(grep { $_->{msg} =~ /hit the probe budget|ensure-fault/ } @LOG),
       '...never routed through the marker-note classifier without a marker');
    is($connect_calls, 1,
       '...and _nvme_connect still runs (separate eval), even unconfigured');
}

done_testing();
