#!/usr/bin/perl
# Three subjects share this file because they share one fixture (a captured
# _log):
#
#   1. _log_api_down_note's throttle - collapsing distinct call sites or
#      storeids into one bucket is the kind of regression that passes every
#      test which stubs _log to `sub { 1 }` instead of capturing it.
#   2. activate_storage must CLASSIFY a failing ensure: its own probe budget
#      expiring under the marker is expected (throttled note), anything else
#      (401, DHCHAP, EINVAL, a wrapped death) keeps the loud level-0 warning
#      or - if it repeats while the marker stands - a throttled one.
#   3. _capped_api_deadline() and _retry_with_backoff()'s effective-budget
#      message, exercised on both the unconfigured and the capped path.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/04-api-down-log-and-guards.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "_capped_api_deadline not found (unpatched tree?)"
    unless $PKG->can('_capped_api_deadline');

my @LOG;
my ($fail_api, $ensure_err);

my ($note, $capped, $recently_down, $reset_throttle, $seed_throttle);
{ no strict 'refs';
  $note           = \&{"${PKG}::_log_api_down_note"};
  $capped         = \&{"${PKG}::_capped_api_deadline"};
  $recently_down  = \&{"${PKG}::_api_recently_down"};
  $reset_throttle = \&{"${PKG}::_reset_api_down_throttle"};
  $seed_throttle  = \&{"${PKG}::_seed_api_down_throttle"}; }

{
    no strict 'refs';
    no warnings 'redefine';
    # THE fixture: capture, don't discard. Stubbing this to `sub { 1 }` is
    # exactly how a throttle bug would go untested.
    *{"${PKG}::_log"} = sub { my (undef, $lvl, $sev, $msg) = @_;
                              push @LOG, { lvl => $lvl, sev => $sev, msg => $msg }; };
    *{"${PKG}::_nvme_check_cli"} = sub { 1 };
    *{"${PKG}::_nvme_connect"}   = sub { 1 };
    *{"${PKG}::_nvme_ensure_subsystem"} = sub {
        die $ensure_err if defined $ensure_err; return 1; };
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
    return {
        tn_dataset        => 'tank/pve',
        tn_api_host       => "203.0.113.$HOSTN",
        tn_transport_mode => 'nvme-tcp',
        tn_subsystem_nqn  => 'nqn.2011-06.com.example:t04',
        %extra,
    };
}

sub notes_logged { scalar grep { $_->{msg} =~ /marked down for another/ } @LOG }

# ------------------------------------------------ 1. the throttle contract --
{
    $reset_throttle->();
    my $scfg = fresh_scfg();
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'reported inactive');
    is(notes_logged(), 1, 'first note logs');
    is($LOG[0]{lvl}, 0, '...at level 0, visible without tn_debug');
    $note->($scfg, 'status', 'store1', 24, 'reported inactive');
    is(notes_logged(), 1, 'immediate repeat with the same key is suppressed');
    $note->($scfg, 'activate_storage', 'store1', 24, 'capping');
    is(notes_logged(), 2, 'a different call site logs its own line');
    $note->($scfg, 'status', 'store2', 24, 'reported inactive');
    is(notes_logged(), 3, 'a sibling storeid on the same array logs its own line');
    $note->(fresh_scfg(), 'status', 'store1', 24, 'reported inactive');
    is(notes_logged(), 4, 'a different array logs its own line');
}

# ------------------------------------------------------- 2. tn_debug bypass --
{
    $reset_throttle->();
    my $scfg = fresh_scfg(tn_debug => 1);
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'x');
    $note->($scfg, 'status', 'store1', 24, 'x');
    is(notes_logged(), 2, 'tn_debug >= 1 bypasses the throttle entirely');
}

# ----------------------------------- 3. the window follows a SHORT backoff --
{
    # The default marker is 30s; a throttle ceiling fixed at 60s would mean
    # every other marker period logs nothing.
    $reset_throttle->();
    my $scfg = fresh_scfg(tn_status_probe_backoff_s => 30);
    $seed_throttle->($scfg, 'status', 'store1', 31);   # older than 30s, younger than 60
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, 'backoff 30: a 31s-old entry no longer throttles');
    $seed_throttle->($scfg, 'status', 'store1', 20);
    $note->($scfg, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, '...but a 20s-old one still does');

    my $scfg2 = fresh_scfg(tn_status_probe_backoff_s => 300);
    $seed_throttle->($scfg2, 'status', 'store1', 61);
    @LOG = ();
    $note->($scfg2, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, 'backoff 300: the ceiling (60s) wins, 61s-old logs');
    $seed_throttle->($scfg2, 'status', 'store1', 40);
    $note->($scfg2, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, '...and 40s-old is still inside the ceiling');
}

# ------------------------------------------------- 4. clock-backwards guard --
{
    $reset_throttle->();
    my $scfg = fresh_scfg();
    $seed_throttle->($scfg, 'status', 'store1', -9999);   # NTP stepped the clock back
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, 'a last-logged timestamp in the future does not mute forever');
}

# ---------------------------------------------- 5. _capped_api_deadline math --
{
    no strict 'refs';
    my $now = time();
    my $d = $capped->();
    ok($d >= $now + 1 && $d <= $now + 3, 'no outer deadline: cap is ~now+2');
    {
        local ${"${PKG}::_api_deadline"} = $now + 1;
        is($capped->(), $now + 1, 'a NEARER outer deadline wins - the cap only shrinks');
    }
    {
        local ${"${PKG}::_api_deadline"} = $now + 100;
        my $d2 = $capped->();
        ok($d2 <= $now + 3, 'a FARTHER outer deadline is ignored - the cap still caps');
    }
}

# -------------------------- 6. activate_storage classifies a failing ensure --
sub arm_marker {
    my ($scfg) = @_;
    $fail_api = "broker: read timeout after 5s\n";
    $PKG->status('store1', $scfg, undef);
    $fail_api = undef;
    return defined($recently_down->($scfg));
}

{
    $reset_throttle->();
    # Expected shape: probe budget expired while the marker stands.
    my $scfg = fresh_scfg();
    ok(arm_marker($scfg), 'marker armed');
    $ensure_err = "Gave up on nvmet.subsys.query after 2s (budget 2s, 1 attempt(s)); "
                . "the array did not answer in time, so the outcome is unknown: x\n";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg, undef);
    ok(!(grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'budget-expired under the marker does NOT emit the level-0 warning');
    ok((grep { $_->{msg} =~ /hit the probe budget/ } @LOG),
       '...it emits the throttled ensure-budget note instead');

    # Unexpected shape: same marker, but the error is an auth failure.
    my $scfg2 = fresh_scfg();
    ok(arm_marker($scfg2), 'marker armed on second array');
    $ensure_err = "nvme_ensure_host: failed to update DHCHAP keys: 401 Unauthorized\n";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2, undef);
    ok((grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'a NON-timeout error under the marker keeps the loud warning');

    # A NON-retryable integrity error whose Python traceback happens to
    # contain the word "timeout". A substring regex would file this as
    # budget noise - erasing the only visible trace of the one error class
    # the retry engine logs at debug level only.
    my $scfg2b = fresh_scfg();
    ok(arm_marker($scfg2b), 'marker armed on third array');
    $ensure_err = "[EINVAL] FOREIGN KEY constraint failed: Traceback (most recent "
                . "call last): socket.timeout: timed out in middlewared/plugins
";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2b, undef);
    ok((grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'an integrity error towing "timeout" in its traceback stays LOUD');

    # The retry engine's OTHER death sentence. With a low retry delay the
    # loop exhausts attempts before the deadline, and that death must be
    # filed as expected too or the warning storm the classifier exists to
    # stop comes back for those configs.
    my $scfg2c = fresh_scfg();
    ok(arm_marker($scfg2c), 'marker armed on fourth array');
    $ensure_err = "Operation failed after 3 retries: WS read failed: connection closed
";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2c, undef);
    ok(!(grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'retries-exhausted on a connection error under the marker is expected');
    ok((grep { $_->{msg} =~ /hit the probe budget.*connection closed/ } @LOG),
       '...and the throttled note carries the error excerpt, not just a verdict');

    # A WRAPPED death (an outer call reporting an inner "Gave up on...") must
    # never file as probe budget (the ^ anchor is the load-bearing half of
    # the classifier), and must not re-open the per-poll warning storm
    # either: one throttled ensure-fault note per window, cause in the
    # excerpt.
    my $scfg2d = fresh_scfg();
    ok(arm_marker($scfg2d), 'marker armed (wrapped-death case)');
    $ensure_err = "nvme_ensure_subsystem: failed to create subsystem nqn.x:t: "
                . "Gave up on nvmet.subsys.create after 2s
";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2d, undef);
    $PKG->activate_storage('store1', $scfg2d, undef);   # second poll, same outage
    ok(!(grep { $_->{msg} =~ /hit the probe budget/ } @LOG),
       'a wrapped death never files as probe budget (anchors hold)');
    my @faults = grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure-fault/ } @LOG;
    is(scalar @faults, 1, 'a repeated real fault under the marker throttles to ONE note');
    ok($faults[0]{msg} =~ /subsys\.create/, '...that carries the excerpt');
    ok(!(grep { $_->{msg} =~ /activate_storage: subsystem ensure failed/ } @LOG),
       '...replacing the unthrottled per-poll warning');

    # No marker at all: any failure is loud.
    my $scfg3 = fresh_scfg();
    $ensure_err = "Gave up on nvmet.subsys.query after 10s (budget 10s...)\n";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg3, undef);
    ok((grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'without the marker even a timeout stays a warning - classification is gated');
    $ensure_err = undef;
}

# --------------- 7. the effective-budget message, exercised both ways --
{
    # The one code path with the least obvious coverage: "capped to" and the
    # clamp against a negative "capped to -3s".
    no strict 'refs';
    my $retry = \&{"${PKG}::_retry_with_backoff"};
    my $dies  = sub { die "WS read failed: connection closed
" };
    my $opts  = { retry_max => 99, retry_delay => 0.5 };

    my $err = do { local $@;
        eval { $retry->(fresh_scfg(tn_api_budget_s => 2), 'test.op', $dies, $opts) }; $@ };
    like($err, qr/^Gave up on /, 'budget death still opens with the anchored phrase');
    unlike($err, qr/capped/, 'no outer deadline: the plain budget names itself');

    my $err2 = do { local $@; eval {
        local ${"${PKG}::_api_deadline"} = time() + 1;
        $retry->(fresh_scfg(tn_api_budget_s => 120), 'test.op', $dies, $opts);
    }; $@ };
    like($err2, qr/capped to \d+s by an outer deadline/,
        'a shrunken budget says so - and as a whole number');

    my $err3 = do { local $@; eval {
        local ${"${PKG}::_api_deadline"} = time() - 5;   # already expired
        $retry->(fresh_scfg(tn_api_budget_s => 120), 'test.op', $dies, $opts);
    }; $@ };
    like($err3, qr/capped to 0s/, 'an already-expired outer deadline clamps to 0');
    unlike($err3, qr/capped to -/, '...never a negative');
}

done_testing();
