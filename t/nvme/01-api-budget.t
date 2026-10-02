#!/usr/bin/perl
# One API call must be bounded in TIME, not just in attempts - but only when
# something asked for that: tn_api_budget_s is opt-in, so this file also
# pins the default (unconfigured) path to the plugin's original behavior.
#
# _retry_with_backoff() used to count attempts and never look at the clock,
# so the worst case was a product nobody multiplied: tn_api_retry_max times
# the per-attempt timeout, plus the backoff sum. Against an unreachable
# array, one call could hold a locked storage operation for far longer than
# any single timeout suggests.
#
# The budget bounds when a new attempt may START. It cannot interrupt an
# attempt already blocked in a syscall, so the honest ceiling is "budget
# plus one attempt" - these tests assert that, not something tighter that
# would be a lie.
#
# Assertions tagged EXPECT-FAIL(unbudgeted) must FAIL against a tree without
# the budget change. If they pass there, this file is not testing anything.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/01-api-budget.t

use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $retry = $PKG->can('_retry_with_backoff');
plan skip_all => "_retry_with_backoff not found" unless $retry;

my @logs;
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, [@_[1..3]]; 1 };
}

# A retryable failure, so the loop actually loops. "connection reset" is on
# the retryable list; if that ever changes this test would silently stop
# testing anything, so the first case pins the attempt count on its own.
my $RETRYABLE = "connection reset by peer\n";

sub drive {
    my (%opt) = @_;
    @logs = ();
    my $scfg = {
        tn_api_retry_max   => $opt{retry_max}   // 8,
        tn_api_retry_delay => $opt{retry_delay} // 0.05,
        (exists $opt{budget} ? (tn_api_budget_s => $opt{budget}) : ()),
    };
    my $attempts = 0;
    my $t0 = time();
    my $ok = eval {
        $retry->($scfg, 'test op', sub { $attempts++; die $RETRYABLE }, undef);
        1;
    };
    return { ok => $ok, err => $@, attempts => $attempts, elapsed => time() - $t0 };
}

# --------------------------------------------- default mode is unchanged ----
# tn_api_budget_s unset, no outer deadline: this must behave exactly like
# the plugin always has - unbounded by wall clock, bounded only by
# tn_api_retry_max, and the classic exhaustion message.

{
    my $r = drive(retry_max => 3, retry_delay => 0.01);
    is($r->{attempts}, 4, 'unconfigured: a retryable error is attempted retry_max+1 times');
    ok(!$r->{ok}, '...and the call still fails in the end');
    like($r->{err} // '', qr/^Operation failed after 3 retries: /,
         '...with the classic exhaustion message, not the budget one');
    unlike($r->{err} // '', qr/Gave up on/,
           '...never the budget death sentence when no budget is configured');
}

# ------------------------------------------------------ the loop does loop --

{
    my $r = drive(retry_max => 3, retry_delay => 0.01, budget => 900);
    is($r->{attempts}, 4, 'a retryable error is attempted retry_max+1 times');
    ok(!$r->{ok}, '...and the call still fails in the end');
}

# ---------------------------------------------- a spent budget stops early --

{
    # 8 retries at 0.05s doubling is ~12.8s of pure backoff. A 2s budget must
    # cut that off long before the attempts run out.
    my $r = drive(retry_max => 8, retry_delay => 0.05, budget => 2);

    # EXPECT-FAIL(unbudgeted): without the budget this runs all 9 attempts.
    cmp_ok($r->{attempts}, '<', 9,
           'the call gives up before exhausting retry_max when the budget is spent')
        or diag("ran $r->{attempts} attempts in $r->{elapsed}s");

    # EXPECT-FAIL(unbudgeted): without the budget this takes ~12.8s.
    cmp_ok($r->{elapsed}, '<', 6,
           '...and returns in about the budget, not the full backoff sum')
        or diag("took $r->{elapsed}s");

    ok(!$r->{ok}, '...and it is a failure, not a silent success');

    # EXPECT-FAIL(unbudgeted): the old message says "after N retries", which
    # reads as "the array answered N times and refused".
    like($r->{err} // '', qr/gave up|budget/i,
         '...and the error says we stopped waiting, not that the array said no');
    like($r->{err} // '', qr/unknown/i,
         '...and admits the outcome is unknown');
}

# --------------------------------------- the budget never truncates success --
# If this breaks, the fix has traded a hang for an outage.

{
    my $scfg = { tn_api_retry_max => 3, tn_api_retry_delay => 0.01, tn_api_budget_s => 10 };
    my $calls = 0;
    my $res = $retry->($scfg, 'test op', sub { $calls++; return { ok => 1 } }, undef);
    is($calls, 1, 'a call that works is made exactly once');
    is_deeply($res, { ok => 1 }, '...and its result is returned untouched');
}

{
    # Succeeds on the third try, well inside the budget: retries must still work.
    my $scfg = { tn_api_retry_max => 5, tn_api_retry_delay => 0.01, tn_api_budget_s => 30 };
    my $n = 0;
    my $res = $retry->($scfg, 'test op', sub {
        $n++;
        die $RETRYABLE if $n < 3;
        return 'third time';
    }, undef);
    is($res, 'third time', 'a transient failure is still retried to success');
    is($n, 3, '...on the attempt where it recovered');
}

# --------------------------------------------- a bad budget is not obeyed ----
# retry_max kept low here (3, not 8): these two only need to prove the
# fallback picks the default budget, not that retries work under it - a
# higher retry_max just burns real backoff sleeps for nothing.

{
    my $r = drive(retry_max => 3, retry_delay => 0.05, budget => 'banana');
    is($r->{attempts}, 4, 'a non-numeric budget falls back to the default, not to zero');
    cmp_ok($r->{elapsed}, '<', 30, '...and the call still terminates');
}

{
    my $r = drive(retry_max => 3, retry_delay => 0.05, budget => 0);
    is($r->{attempts}, 4, 'a zero budget falls back to the default, not to give-up-at-once');
    cmp_ok($r->{elapsed}, '<', 30, '...and the call still terminates');
}

done_testing();
