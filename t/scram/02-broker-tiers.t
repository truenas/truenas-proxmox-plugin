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
    ok  main::_is_rate_limited(q{Rate Limit Exceeded}), "substring-only: Rate Limit Exceeded (no code)";
    ok  main::_is_rate_limited(q{too many concurrent calls}), "substring-only: concurrent calls (no code)";
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

subtest '_do_t2_login success' => sub {
    my @calls;
    no warnings 'redefine';
    local *main::ws_rpc = sub {
        push @calls, $_[1];
        return {
            response_type   => "SUCCESS",
            user_info       => {},
            authenticator   => "LEVEL_1",
            reconnect_token => undef,
        };
    };
    my $conn = { sock => undef, next_id => 1 };
    ok eval { main::_do_t2_login($conn, "alice", "17-abc"); 1 }, "lives";
    is scalar(@calls), 1, "one call";
    is $calls[0]->{method}, "auth.login_ex";
    is_deeply $calls[0]->{params}, [{
        mechanism     => "API_KEY_PLAIN",
        username      => "alice",
        api_key       => "17-abc",
        login_options => {},
    }];
};

subtest '_do_t2_login refuses non-SUCCESS' => sub {
    my $conn = { sock => undef, next_id => 1 };
    no warnings 'redefine';
    for my $rt (qw(AUTH_ERR DENIED EXPIRED OTP_REQUIRED REDIRECT WEIRD)) {
        local *main::ws_rpc = sub { return { response_type => $rt } };
        eval { main::_do_t2_login($conn, "alice", "17-abc") };
        like $@, qr/API_KEY_PLAIN login rejected: \Q$rt\E/, "$rt rejected";
    }
};

subtest '_do_t2_login propagates ws_rpc die' => sub {
    my $conn = { sock => undef, next_id => 1 };
    no warnings 'redefine';
    local *main::ws_rpc = sub { die "Method 'auth.login_ex' not found\n" };
    eval { main::_do_t2_login($conn, "alice", "17-abc") };
    like $@, qr/not found/;
};

subtest '_do_t2_login no response' => sub {
    my $conn = { sock => undef, next_id => 1 };
    no warnings 'redefine';
    local *main::ws_rpc = sub { return undef };
    eval { main::_do_t2_login($conn, "alice", "17-abc") };
    like $@, qr/no response from server/;
};

subtest '_do_t2_login success with envelope shape' => sub {
    my $conn = { sock => undef, next_id => 1 };
    no warnings 'redefine';
    local *main::ws_rpc = sub {
        return { jsonrpc => "2.0", id => 1, result => {
            response_type => "SUCCESS", user_info => {},
            authenticator => "LEVEL_1", reconnect_token => undef } };
    };
    ok eval { main::_do_t2_login($conn, "alice", "17-abc"); 1 }, "lives";
};

subtest '_do_t2_login AUTH_ERR with envelope shape' => sub {
    my $conn = { sock => undef, next_id => 1 };
    no warnings 'redefine';
    local *main::ws_rpc = sub {
        return { jsonrpc => "2.0", id => 1, result => { response_type => "AUTH_ERR" } };
    };
    eval { main::_do_t2_login($conn, "alice", "17-abc") };
    like $@, qr/API_KEY_PLAIN login rejected.*AUTH_ERR/;
};

subtest '_do_t2_login JSON-RPC error envelope' => sub {
    my $conn = { sock => undef, next_id => 1 };
    no warnings 'redefine';
    local *main::ws_rpc = sub {
        return { jsonrpc => "2.0", id => 1,
                 error => { code => -32601, message => "Method 'auth.login_ex' not found" } };
    };
    eval { main::_do_t2_login($conn, "alice", "17-abc") };
    like $@, qr/API_KEY_PLAIN login error/, "error prefix";
    like $@, qr/not found/, "server detail carried";
};

done_testing;
