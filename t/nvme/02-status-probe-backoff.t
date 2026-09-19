#!/usr/bin/perl
# status() must stop asking an array that just said no.
#
# One probe against a dead API costs a full broker deadline. pvestatd is a
# single process that walks every storage every 10 seconds, so with two
# truenasplugin storages configured that is the whole metrics pipeline
# stopped for the length of the outage.
#
# The fix is a marker: after a connectivity failure, answer inactive from
# memory for tn_status_probe_backoff_s without touching the network.
#
# The marker is the part that can go wrong in a way that matters, so the
# assertions here are mostly about when it must NOT apply: it must not
# survive the array coming back, and it must not swallow a configuration
# error, which answers instantly and needs no suppression.
#
# Assertions tagged EXPECT-FAIL(unpatched) must FAIL without the marker.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/02-status-probe-backoff.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "status not found" unless $PKG->can('status');

my @calls;
my $fail_with;

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method) = @_;
        push @calls, $method;
        die $fail_with if defined $fail_with;
        # pool.dataset.get_instance returns ONE dataset, not a list. Returning
        # an arrayref here made the happy path fail in both worlds, which is
        # the test being wrong rather than the code.
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

my %SCFG = (
    tn_dataset        => 'tank/pve',
    tn_api_host       => '198.51.100.7',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.example:test',
);

# Each case gets a distinct api_host so it gets its own marker slot: the
# marker is keyed per host and package-global, so reusing one host would let
# an earlier case decide a later one.
my $HOSTN = 0;
sub fresh_scfg {
    my (%extra) = @_;
    $HOSTN++;
    return { %SCFG, tn_api_host => "198.51.100.$HOSTN", %extra };
}

sub call_status {
    my ($scfg) = @_;
    @calls = ();
    my @r = $PKG->status('store1', $scfg, undef);
    return { total => $r[0], avail => $r[1], used => $r[2], active => $r[3],
             api_calls => scalar(@calls) };
}

my $CONN_ERR = "broker: TLS connect to 198.51.100.7:443 failed: connection timed out\n";

# ----------------------------------------------------------------- premise --

{
    $fail_with = undef;
    my $scfg = fresh_scfg();
    my $r = call_status($scfg);
    ok($r->{active}, 'a reachable array reports active');
    cmp_ok($r->{api_calls}, '>', 0, '...having actually asked it something');
}

# ------------------------------------------- the marker suppresses probing --

{
    my $scfg = fresh_scfg();
    $fail_with = $CONN_ERR;

    my $first = call_status($scfg);
    ok(!$first->{active}, 'a connectivity failure reports inactive');
    cmp_ok($first->{api_calls}, '>', 0, '...after really trying');

    my $second = call_status($scfg);
    ok(!$second->{active}, 'the next poll still reports inactive');
    # EXPECT-FAIL(unpatched): without the marker this probes again every time.
    is($second->{api_calls}, 0,
       '...without touching the API again while the marker stands');
}

# ------------------------------------------ recovery is not held hostage ----

{
    my $scfg = fresh_scfg();
    $fail_with = $CONN_ERR;
    call_status($scfg);                      # arm it
    $fail_with = undef;

    # With backoff disabled the very next poll must find the array again --
    # this is the escape hatch, and it has to work.
    my $r = call_status({ %$scfg, tn_status_probe_backoff_s => 0 });
    ok($r->{active}, 'with the backoff disabled a recovered array is seen at once');

    # And once it has answered, the marker must be gone for good. Reporting
    # active is the proof on its own: a standing marker returns inactive
    # without asking anyone.
    my $again = call_status($scfg);
    ok($again->{active}, 'the marker does not outlive the array coming back');
    # Not an api_calls assertion: the capacity cache legitimately serves this
    # one, so "no API call" here means the cache worked, not that the marker
    # is still standing. What distinguishes a real answer from a suppressed
    # one is that a suppressed answer is all zeros.
    cmp_ok($again->{total}, '>', 0,
           '...and answers with real capacity, not the zeros of a suppressed poll');
}

# ----------------------------------- a config error is not a connectivity one --
# The marker exists to stop pointless network waits. A rejected dataset name
# answers instantly, so suppressing it would only hide a real misconfiguration.

{
    my $scfg = fresh_scfg();
    $fail_with = "dataset does not exist\n";
    my $first = call_status($scfg);
    ok(!$first->{active}, 'a missing dataset reports inactive');

    my $second = call_status($scfg);
    cmp_ok($second->{api_calls}, '>', 0,
           'a configuration error does NOT arm the marker -- it is still probed');
}

# ------------------------------------------------ zeros when it is inactive --

{
    my $scfg = fresh_scfg();
    $fail_with = $CONN_ERR;
    my $r = call_status($scfg);
    is($r->{total}, 0, 'an inactive storage reports zero capacity, not a stale figure');
    is($r->{avail}, 0, '...and zero available');
    my $second = call_status($scfg);
    is($second->{total}, 0, '...and the suppressed answer says zero too, not garbage');
}

done_testing();
