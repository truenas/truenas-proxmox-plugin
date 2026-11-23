#!/usr/bin/perl
# Unit test for the #161 fix: get_or_open_ws's liveness probe must treat
# an ENOTAUTHENTICATED error envelope from auth.me as failure, not
# success. The pre-fix code did `if ($ok)` on the ws_rpc return value,
# which is truthy for a matched reply even when the reply carries a
# JSON-RPC error -- so a 30-day-expired session pinned the pool entry
# forever (reporter observed ~16,000 ENOTAUTHENTICATED errors over 6h
# without a single pool reopen).

use strict;
use warnings;
use Test::More;
use JSON::PP;

# Loads subs only; main() is guarded by `unless caller`.
require "./tools/truenas-plugin-broker";

plan skip_all => "_liveness_probe_passed helper missing"
    unless defined &main::_liveness_probe_passed;

sub probe_passed { return main::_liveness_probe_passed(@_); }

# ----- pre-fix regression cases: these used to pass as success ------------

subtest 'ENOTAUTHENTICATED error envelope fails the probe' => sub {
    my $reply = {
        jsonrpc => "2.0", id => 999999,
        error => {
            code    => -32001,
            message => "Method call error",
            data    => { error => 24, errname => "ENOTAUTHENTICATED" },
        },
    };
    ok !probe_passed($reply),
       'reply with ENOTAUTHENTICATED error -> probe fails (#161)';
};

subtest 'any JSON-RPC error envelope fails the probe' => sub {
    for my $errname (qw(ENOTAUTHENTICATED EACCES EINVAL)) {
        my $reply = {
            jsonrpc => "2.0", id => 999999,
            error => { code => -32001, message => "x", data => { errname => $errname } },
        };
        ok !probe_passed($reply), "$errname error -> probe fails";
    }
    # Even a bare error without data.
    ok !probe_passed({ jsonrpc => "2.0", id => 1, error => "something broke" }),
       'bare error field -> probe fails';
};

# ----- happy-path and other-failure cases --------------------------------

subtest 'successful auth.me reply passes the probe' => sub {
    my $reply = {
        jsonrpc => "2.0", id => 999999,
        result  => { username => "root", pw_uid => 0 },
    };
    ok probe_passed($reply), 'reply with result and no error -> probe passes';
};

subtest 'transport failures and unexpected shapes fail the probe' => sub {
    ok !probe_passed(undef),
       'undef (ws_rpc returned undef on transport failure) -> probe fails';
    ok !probe_passed(""),
       'empty string -> probe fails';
    ok !probe_passed(0),
       'bare 0 -> probe fails';
    ok !probe_passed("something"),
       'bare string -> probe fails';
    ok !probe_passed([1, 2, 3]),
       'array ref -> probe fails';
};

done_testing();
