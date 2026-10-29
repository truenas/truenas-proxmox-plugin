use strict;
use warnings;
use Test::More;
use JSON::PP;

# Loads subs only; main() is guarded by `unless caller`.
require "./tools/truenas-plugin-broker";

subtest '_is_rate_limited' => sub {
    ok  main::_is_rate_limited(q{truenas API error (code 16): [EBUSY] Rate Limit Exceeded});
    ok  main::_is_rate_limited(q{code 22: Rate limit exceeded, try again});
    ok  main::_is_rate_limited(q{code 0: concurrent calls limit});
    ok  main::_is_rate_limited(q{code -32000: rate limit});
    ok  main::_is_rate_limited(q{{"code":16,"message":"EBUSY"}}), 'JSON-serialized error, code only';
    ok  main::_is_rate_limited(q{broker: {"code":-32000,"message":"x"}});
    ok !main::_is_rate_limited(q{Method 'auth.mechanism_choices' not found});
    ok !main::_is_rate_limited(q{EINVAL: login_data: Input tag 'SCRAM'});
    ok !main::_is_rate_limited(q{{"code":-32601,"message":"Method not found"}});
    ok !main::_is_rate_limited(undef);
    ok !main::_is_rate_limited("");
};

subtest '_do_t3_login' => sub {
    my @calls;
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { push @calls, $_[1]; return JSON::PP::true; };
        my $conn = { sock => undef, next_id => 1 };
        main::_do_t3_login($conn, "17-abc");
        is $calls[0]->{method}, "auth.login_with_api_key";
        is_deeply $calls[0]->{params}, ["17-abc"];
        is $calls[0]->{jsonrpc}, "2.0";
    }
    my $conn = { sock => undef, next_id => 1 };
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { return JSON::PP::false };
        eval { main::_do_t3_login($conn, "17-abc") };
        like $@, qr/legacy API-key login rejected/, "false -> die";
    }
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { return { jsonrpc => "2.0", id => 1, result => JSON::PP::true } };
        ok eval { main::_do_t3_login($conn, "17-abc"); 1 }, "envelope with result true accepted";
    }
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { return { jsonrpc => "2.0", id => 1, result => JSON::PP::false } };
        eval { main::_do_t3_login($conn, "17-abc") };
        like $@, qr/legacy API-key login rejected/, "envelope with result false -> die";
    }
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { return { error => { code => 16, message => "Rate Limit Exceeded" } } };
        eval { main::_do_t3_login($conn, "17-abc") };
        ok main::_is_rate_limited($@), "envelope error is classifiable as rate limit";
    }
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { return undef };
        eval { main::_do_t3_login($conn, "17-abc") };
        like $@, qr/TrueNAS authentication failed/, "no response keeps legacy message";
    }
    {
        no warnings 'redefine';
        local *main::ws_rpc = sub { die "concurrent calls limit\n" };
        eval { main::_do_t3_login($conn, "17-abc") };
        like $@, qr/concurrent calls limit/, "ws_rpc errors propagate";
    }
};

done_testing;
