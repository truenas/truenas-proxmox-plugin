#!/usr/bin/perl
# Unit test for the #159 fix: when auth.mechanism_choices returns a
# well-formed JSON-RPC error envelope (not "method not found", not
# "rate limited"), treat it as evidence that the server has
# auth.login_ex and pick T2 instead of silently dropping to the
# legacy T3 floor.
#
# Reporter's trigger: TN 25.10.4 crashes the pre-auth probe with
# EINVAL ('NoneType' object has no attribute 'may_create_auth_token').
# The envelope proves middleware is routing requests; login_ex works
# on the same server. The pre-fix selector left %have empty and auto
# returned T3, which breaks once TN removes auth.login_with_api_key.

use strict;
use warnings;
use Test::More;
use JSON::PP;

# Loads subs only; main() is guarded by `unless caller`.
require "./tools/truenas-plugin-broker";

plan skip_all => "_select_mechanism signature has fewer than 6 args"
    unless defined &main::_select_mechanism;

# The exact envelope the reporter sees on TN 25.10.4.
my $EINVAL_ENVELOPE = encode_json({
    code    => -32001,
    message => "Method call error",
    data    => {
        error   => 22,
        errname => "EINVAL",
        reason  => "'NoneType' object has no attribute 'may_create_auth_token'",
    },
});

my $CB_UNAVAILABLE = 0;
my $HAD_ENVELOPE   = 1;
my $NO_ENVELOPE    = 0;

subtest 'auto + username: server-error envelope -> T2 (was T3)' => sub {
    is main::_select_mechanism("alice", "auto", undef, $EINVAL_ENVELOPE,
                               $CB_UNAVAILABLE, $HAD_ENVELOPE),
       "T2",
       "EINVAL envelope + envelope-flag set -> T2 (#159)";
};

subtest 'plain + username: server-error envelope -> T2 (was T3)' => sub {
    is main::_select_mechanism("alice", "plain", undef, $EINVAL_ENVELOPE,
                               $CB_UNAVAILABLE, $HAD_ENVELOPE),
       "T2",
       "EINVAL envelope, plain mech, envelope-flag set -> T2 (#159)";
};

subtest 'envelope-flag off -> old behavior (T3 floor)' => sub {
    # Without the envelope flag we can't distinguish transport failure
    # from a server-error envelope, so the selector stays conservative.
    is main::_select_mechanism("alice", "auto", undef, $EINVAL_ENVELOPE,
                               $CB_UNAVAILABLE, $NO_ENVELOPE),
       "T3",
       "EINVAL string without envelope-flag -> T3 (transport-like)";
    is main::_select_mechanism("alice", "plain", undef, $EINVAL_ENVELOPE,
                               $CB_UNAVAILABLE, $NO_ENVELOPE),
       "T3",
       "plain + EINVAL string without envelope-flag -> T3";
};

subtest 'method-not-found envelope still goes to T3 even with the flag' => sub {
    # A genuinely old TN without auth.mechanism_choices probably also
    # lacks auth.login_ex. Don't try T2 on method-not-found; keep the
    # T3 floor.
    my $mnf = "Method 'auth.mechanism_choices' not found";
    is main::_select_mechanism("alice", "auto", undef, $mnf,
                               $CB_UNAVAILABLE, $HAD_ENVELOPE),
       "T3",
       "method-not-found + envelope-flag -> T3";
    is main::_select_mechanism("alice", "plain", undef, $mnf,
                               $CB_UNAVAILABLE, $HAD_ENVELOPE),
       "T3",
       "plain + method-not-found + envelope-flag -> T3";
};

subtest 'rate-limited envelope still goes to T1 in auto (old behavior)' => sub {
    # Rate-limited probe keeps the old "optimistic T1 so we don't
    # add to the rate-limiter pressure with a T3 retry" path.
    is main::_select_mechanism("alice", "auto", undef, "Rate Limit Exceeded",
                               $CB_UNAVAILABLE, $HAD_ENVELOPE),
       "T1",
       "rate-limited + envelope-flag -> T1 (unchanged)";
};

subtest 'no username: still T3 regardless of envelope' => sub {
    # Without a username we can't do SCRAM or API_KEY_PLAIN anyway.
    is main::_select_mechanism(undef, "auto", undef, $EINVAL_ENVELOPE,
                               $CB_UNAVAILABLE, $HAD_ENVELOPE),
       "T3",
       "no username + envelope -> T3 (nothing we can do)";
};

subtest 'scram / scram-plus: explicit SCRAM request still dies on no SCRAM' => sub {
    # If the user explicitly asked for SCRAM, an envelope saying
    # "server barfed" is not evidence SCRAM is available. Stay fatal.
    eval {
        main::_select_mechanism("alice", "scram", undef, $EINVAL_ENVELOPE,
                                $CB_UNAVAILABLE, $HAD_ENVELOPE);
    };
    like $@, qr/does not support SCRAM/,
         "scram + envelope -> die (not silently T2)";
    eval {
        main::_select_mechanism("alice", "scram-plus", undef, $EINVAL_ENVELOPE,
                                1, $HAD_ENVELOPE);
    };
    like $@, qr/does not advertise SCRAM/,
         "scram-plus + envelope -> die (not silently T2)";
};

subtest 'back-compat: 5-arg callers still work (envelope arg defaults to 0)' => sub {
    # Old code paths that pre-date the new flag mustn't regress.
    is main::_select_mechanism("alice", "auto", ["SCRAM"], undef),       "T1";
    is main::_select_mechanism("alice", "auto", ["API_KEY_PLAIN"], undef), "T2";
    is main::_select_mechanism("alice", "auto", undef, undef),           "T3";
};

done_testing();
