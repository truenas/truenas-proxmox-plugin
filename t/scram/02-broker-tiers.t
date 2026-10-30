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

use TrueNAS::SCRAM ();

my $KA_SERVER_FIRST = "r=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQg==,s=MDEyMzQ1Njc4OWFiY2RlZg==,i=50000";
my $KA_SERVER_FINAL = "v=100k8G7PP/AmrdBCfvOEgpU6vwmMpY3JpeN5eVtJMFi3iOC+qIBrwgfIoiBSTqU+vlwcH/Va3YprRcpwitFuoQ==";

sub _scram_env {
    my ($type, $rfc) = @_;
    return { jsonrpc => "2.0", id => 1, result => {
        response_type => "SCRAM_RESPONSE", scram_type => $type,
        rfc_str => $rfc, user_info => undef } };
}

subtest '_is_scram_unsupported_error' => sub {
    ok  main::_is_scram_unsupported_error(q{EINVAL: login_data: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags});
    ok !main::_is_scram_unsupported_error("server signature verification failed");
    ok !main::_is_scram_unsupported_error("Rate Limit Exceeded");
    ok !main::_is_scram_unsupported_error(undef);
};

subtest '_do_t1_login happy path' => sub {
    no warnings 'redefine';
    local *TrueNAS::SCRAM::urandom = sub ($) { "A" x 32 };
    my @calls;
    local *main::ws_rpc = sub {
        push @calls, $_[1];
        my $p = $_[1]{params}[0];
        return _scram_env("SERVER_FIRST_RESPONSE", $KA_SERVER_FIRST)
            if $p->{scram_type} eq 'CLIENT_FIRST_MESSAGE';
        return _scram_env("SERVER_FINAL_RESPONSE", $KA_SERVER_FINAL);
    };
    my $conn = { sock => undef, next_id => 1 };
    ok eval { main::_do_t1_login($conn, "testuser", "1-testsecret_for_vector_01") }, "lives" or diag $@;
    is scalar(@calls), 2, "two calls";
    is $calls[0]{method}, "auth.login_ex";
    is $calls[0]{params}[0]{mechanism}, "SCRAM";
    is $calls[0]{params}[0]{scram_type}, "CLIENT_FIRST_MESSAGE";
    is $calls[1]{params}[0]{scram_type}, "CLIENT_FINAL_MESSAGE";
    like $calls[1]{params}[0]{rfc_str}, qr/,p=/, "client-final carries proof";
};

subtest '_do_t1_login server signature mismatch' => sub {
    no warnings 'redefine';
    local *TrueNAS::SCRAM::urandom = sub ($) { "A" x 32 };
    (my $bad = $KA_SERVER_FINAL) =~ s/^v=./v=Z/;
    local *main::ws_rpc = sub {
        return $_[1]{params}[0]{scram_type} eq 'CLIENT_FIRST_MESSAGE'
            ? _scram_env("SERVER_FIRST_RESPONSE", $KA_SERVER_FIRST)
            : _scram_env("SERVER_FINAL_RESPONSE", $bad);
    };
    eval { main::_do_t1_login({ next_id => 1 }, "testuser", "1-testsecret_for_vector_01") };
    like $@, qr/SCRAM auth failed: (?:scram: )?server signature verification failed/;
};

subtest '_do_t1_login SCRAM-unsupported (ws_rpc die path)' => sub {
    no warnings 'redefine';
    local *main::ws_rpc = sub {
        die "Method 'auth.login_ex' error: EINVAL: login_data: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags\n";
    };
    eval { main::_do_t1_login({ next_id => 1 }, "testuser", "1-testsecret_for_vector_01") };
    like $@, qr/SCRAM unsupported by server/;
};

subtest '_do_t1_login SCRAM-unsupported (envelope-error path)' => sub {
    no warnings 'redefine';
    local *main::ws_rpc = sub {
        return { jsonrpc => "2.0", id => 1, error => { code => 22,
            message => "[EINVAL] login_data: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags" } };
    };
    eval { main::_do_t1_login({ next_id => 1 }, "testuser", "1-testsecret_for_vector_01") };
    like $@, qr/SCRAM unsupported by server/;
    like $@, qr/does not match any of the expected tags/, "server text carried";
};

subtest '_do_t1_login undef response' => sub {
    no warnings 'redefine';
    local *main::ws_rpc = sub { return undef };
    eval { main::_do_t1_login({ next_id => 1 }, "testuser", "1-testsecret_for_vector_01") };
    like $@, qr/no response from server/;
};

subtest '_do_t1_login malformed server-first' => sub {
    no warnings 'redefine';
    local *main::ws_rpc = sub { return _scram_env("SERVER_FIRST_RESPONSE", "garbage") };
    eval { main::_do_t1_login({ next_id => 1 }, "testuser", "1-testsecret_for_vector_01") };
    ok $@, "dies" and diag $@;
};

subtest '_select_mechanism' => sub {
    is main::_select_mechanism("alice", "auto", ["SCRAM","API_KEY_PLAIN"], undef), "T1";
    is main::_select_mechanism("alice", "auto", ["API_KEY_PLAIN"], undef), "T2";
    is main::_select_mechanism(undef,   "auto", ["API_KEY_PLAIN"], undef), "T3", "no username -> T3 even on new TN";
    is main::_select_mechanism("alice", "auto", undef, "Method 'auth.mechanism_choices' not found"), "T3";
    is main::_select_mechanism("alice", "auto", undef, "Rate Limit Exceeded"), "T1", "rate-limited probe + username -> attempt T1";
    is main::_select_mechanism(undef,   "auto", undef, "Rate Limit Exceeded"), "T3", "rate-limited probe, no user -> T3 (floor)";
    is main::_select_mechanism("alice", "plain", ["SCRAM"], undef), "T2", "plain never picks SCRAM";
    is main::_select_mechanism("alice", "plain", undef, "method not found"), "T3";

    eval { main::_select_mechanism(undef, "scram", ["SCRAM"], undef) };
    like $@, qr/tn_auth_mechanism=scram requires tn_api_username/, "scram without username -> die";
    eval { main::_select_mechanism("alice", "scram", ["API_KEY_PLAIN"], undef) };
    like $@, qr/server does not support SCRAM/, "scram-forced on no-SCRAM server -> die";
    eval { main::_select_mechanism("alice", "scram", undef, "method not found") };
    like $@, qr/server does not support SCRAM/, "scram-forced on pre-login_ex -> die";
};

subtest '_select_mechanism: unsupported is checked before rate-limit' => sub {
    my $both = q{{"code":22,"message":"Method 'auth.mechanism_choices' not found"}};
    ok  main::_is_rate_limited($both), "fixture matches the rate-limit heuristic";
    my $scram = q{{"code":22,"message":"Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags"}};
    ok  main::_is_rate_limited($scram), "SCRAM-tag fixture also matches rate-limit";
    is main::_select_mechanism("alice", "auto", undef, $both),  "T3", "not-found + code 22 -> fallback, not T1";
    is main::_select_mechanism("alice", "auto", undef, $scram), "T3", "SCRAM-unsupported + code 22 -> fallback, not T1";
    eval { main::_select_mechanism("alice", "scram", undef, $both) };
    like $@, qr/server does not support SCRAM/, "forced scram dies rather than attempting T1";
};

subtest '_is_method_not_found' => sub {
    ok  main::_is_method_not_found(q{Method 'auth.login_ex' not found});
    ok  main::_is_method_not_found(q{{"code":-32601,"message":"Method not found"}});
    ok  main::_is_method_not_found(q{unknown method auth.login_ex});
    ok !main::_is_method_not_found(q{user not found});
    ok !main::_is_method_not_found(q{API_KEY_PLAIN login rejected: AUTH_ERR});
    ok !main::_is_method_not_found(undef);
};

subtest '_authenticate' => sub {
    no warnings qw(redefine once);
    my @calls;
    my ($probe, $t1, $t2, $t3);
    local *main::linfo = sub { };
    local *main::lwarn = sub { };
    local *main::ws_rpc = sub { return $probe };
    local *main::_do_t1_login = sub { push @calls, 'T1'; die $t1 if defined $t1; 1 };
    local *main::_do_t2_login = sub { push @calls, 'T2'; die $t2 if defined $t2; 1 };
    local *main::_do_t3_login = sub { push @calls, 'T3'; die $t3 if defined $t3; 1 };
    my $run = sub {
        my ($scfg, %o) = @_;
        @calls = ();
        $probe = $o{probe} // { result => ["SCRAM","API_KEY_PLAIN"] };
        ($t1, $t2, $t3) = @o{qw(t1 t2 t3)};
        my $conn = { sock => undef, next_id => 1 };
        my $ok = eval { main::_authenticate($conn, { api_key => "1-k", api_username => "alice", %$scfg }); 1 };
        return ($ok, $@);
    };
    my $unsup = "[TrueNAS] SCRAM unsupported by server: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags\n";

    my ($ok, $err) = $run->({}, t1 => "[TrueNAS] SCRAM auth failed: AUTH_ERR\n");
    ok !$ok, "1: T1 hard failure dies"; like $err, qr/AUTH_ERR/;
    is_deeply \@calls, ['T1'], "1: no fallback";

    ($ok, $err) = $run->({}, t1 => $unsup);
    ok $ok, "2: T1 unsupported (auto) falls back to T2";
    is_deeply \@calls, ['T1','T2'], "2: T2 once, T3 not called";

    ($ok, $err) = $run->({ auth_mechanism => 'scram' }, t1 => $unsup);
    ok !$ok, "3: T1 unsupported in scram mode dies";
    is_deeply \@calls, ['T1'], "3: T2 not called";

    ($ok, $err) = $run->({}, t1 => "Method 'auth.login_ex' not found\n");
    ok $ok, "4: T1 method-not-found (auto) falls back to T2";
    is_deeply \@calls, ['T1','T2'], "4: T1 then T2";

    ($ok, $err) = $run->({ auth_mechanism => 'scram' }, t1 => "Method 'auth.login_ex' not found\n");
    ok !$ok, "4b: T1 method-not-found in scram mode dies";
    is_deeply \@calls, ['T1'];

    ($ok, $err) = $run->({}, t1 => $unsup, t2 => "[TrueNAS] API_KEY_PLAIN login rejected: AUTH_ERR\n");
    ok !$ok, "5: T2 AUTH_ERR dies"; like $err, qr/AUTH_ERR/;
    is_deeply \@calls, ['T1','T2'], "5: T3 not called";

    ($ok, $err) = $run->({}, t1 => $unsup, t2 => "Method 'auth.login_ex' not found\n");
    ok $ok, "6: T2 method-not-found falls back to T3";
    is_deeply \@calls, ['T1','T2','T3'], "6: T1,T2,T3";

    ($ok, $err) = $run->({ auth_mechanism => 'plain' }, probe => { result => ["API_KEY_PLAIN"] },
                         t2 => "Method 'auth.login_ex' not found\n");
    ok $ok, "6b: plain mode T2 method-not-found falls to T3";
    is_deeply \@calls, ['T2','T3'];

    ($ok, $err) = $run->({ auth_mechanism => 'scram' }, probe => { result => ["API_KEY_PLAIN"] });
    ok !$ok, "6c: scram on server without SCRAM dies before any login";
    is_deeply \@calls, [];

    ($ok, $err) = $run->({}, probe => { result => [] });
    ok $ok, "7: empty mechanism list -> T3";
    is_deeply \@calls, ['T3'];

    ($ok, $err) = $run->({ api_username => undef });
    ok $ok, "7b: no username -> T3";
    is_deeply \@calls, ['T3'];

    ($ok, $err) = $run->({}, probe => { error => { code => -32601, message => "Method not found" } });
    ok $ok, "7c: probe method-not-found -> T3";
    is_deeply \@calls, ['T3'];
};

subtest '_cb_digest_for_sig_alg' => sub {
    is main::_cb_digest_for_sig_alg('sha256WithRSAEncryption'), 'sha256';
    is main::_cb_digest_for_sig_alg('ecdsa-with-SHA256'),       'sha256';
    is main::_cb_digest_for_sig_alg('sha384WithRSAEncryption'), 'sha384';
    is main::_cb_digest_for_sig_alg('sha512WithRSAEncryption'), 'sha512';
    is main::_cb_digest_for_sig_alg('sha1WithRSAEncryption'),   'sha256', 'weak sig -> sha256 per RFC 5929 4.1';
    is main::_cb_digest_for_sig_alg('md5WithRSAEncryption'),    'sha256', 'md5 sig -> sha256';
    is main::_cb_digest_for_sig_alg('ed25519'),                 undef,    'ed25519 -> undef';
    is main::_cb_digest_for_sig_alg('rsassaPss'),               undef,    'rsassa-pss -> undef';
    is main::_cb_digest_for_sig_alg(''),                        undef,    'empty -> undef';
};

subtest '_sig_alg_name_from_der' => sub {
    open my $fh, '<:raw', 't/scram/certs/sha384.der' or die "fixture: $!";
    local $/; my $der = <$fh>; close $fh;
    is main::_sig_alg_name_from_der($der), 'sha384WithRSAEncryption';
    is main::_cb_digest_for_sig_alg(main::_sig_alg_name_from_der($der)), 'sha384';
    is main::_sig_alg_name_from_der('garbage'), undef;
    is main::_sig_alg_name_from_der(undef), undef;
};

subtest '_extract_tls_server_end_point' => sub {
    my $no_cert_sock = bless {}, 'main::StubSock';
    { no warnings "once"; *main::StubSock::peer_certificate = sub { undef }; }
    my ($raw, $err) = main::_extract_tls_server_end_point($no_cert_sock);
    is $raw, undef;
    like $err, qr/no peer certificate/i;

    # Real X509 handle from the SHA-384 fixture, stub fingerprint method.
    require Net::SSLeay;
    open my $fh, '<:raw', 't/scram/certs/sha384.der' or die "fixture: $!";
    local $/; my $der = <$fh>; close $fh;
    my $bio = Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
    Net::SSLeay::BIO_write($bio, $der);
    my $x509 = Net::SSLeay::d2i_X509_bio($bio);
    ok $x509, 'parsed fixture';
    my $asked;
    my $sock = bless {}, 'main::StubSock2';
    no warnings "once";
    *main::StubSock2::peer_certificate = sub { $x509 };
    *main::StubSock2::get_fingerprint_bin = sub { $asked = $_[1]; "RAWDIGEST" };
    ($raw, $err) = main::_extract_tls_server_end_point($sock);
    is $raw, "RAWDIGEST";
    is $err, undef;
    is $asked, 'sha384', 'digest chosen from cert signature alg';
    Net::SSLeay::BIO_free($bio);
};

subtest '_select_mechanism scram-plus' => sub {
    is main::_select_mechanism('alice', 'scram-plus', ['SCRAM','API_KEY_PLAIN'], undef, 1), 'T1-PLUS';
    is main::_select_mechanism('alice', 'scram-plus', ['SCRAM'],                 undef, 1), 'T1-PLUS';
    is main::_select_mechanism('alice', 'scram-plus', undef, 'Rate Limit Exceeded', 1), 'T1-PLUS',
        'rate-limited probe + username -> attempt T1-PLUS (mirrors scram)';

    eval { main::_select_mechanism(undef, 'scram-plus', ['SCRAM'], undef, 1) };
    like $@, qr/tn_auth_mechanism=scram-plus requires tn_api_username/;

    eval { main::_select_mechanism('alice', 'scram-plus', ['API_KEY_PLAIN'], undef, 1) };
    like $@, qr/scram-plus but server does not advertise SCRAM/;

    eval { main::_select_mechanism('alice', 'scram-plus', undef, 'Method not found', 1) };
    like $@, qr/scram-plus but server does not advertise SCRAM/;

    eval { main::_select_mechanism('alice', 'bogus', ['SCRAM'], undef, 1) };
    like $@, qr/unknown mechanism/;
    is $@, "tn_auth_mechanism=bogus: unknown mechanism\n", 'unknown mechanism die message is exact';
};

subtest '_select_mechanism: auto/scram/plain unaffected by cb arg' => sub {
    is main::_select_mechanism('alice', 'auto',  ['SCRAM'], undef, 1), 'T1';
    is main::_select_mechanism('alice', 'scram', ['SCRAM'], undef, 1), 'T1';
    is main::_select_mechanism('alice', 'plain', ['SCRAM'], undef, 1), 'T2';
};

subtest '_authenticate scram-plus guard' => sub {
    no warnings qw(redefine once);
    my @calls;
    local *main::linfo = sub { };
    local *main::lwarn = sub { };
    local *main::ws_rpc = sub { return { result => ['SCRAM','API_KEY_PLAIN'] } };
    local *main::_do_t1_login = sub { push @calls, 'T1'; 1 };
    local *main::_do_t2_login = sub { push @calls, 'T2'; 1 };
    local *main::_do_t3_login = sub { push @calls, 'T3'; die "T3 must not be called\n" };
    my $conn = { sock => undef, next_id => 1 };
    my $ok = eval { main::_authenticate($conn, { api_key => '1-k', api_username => 'alice', auth_mechanism => 'scram-plus' }); 1 };
    my $err = $@;
    ok !$ok, 'scram-plus on SCRAM-capable server dies instead of falling through';
    like $err, qr/T1-PLUS dispatch not yet implemented/, 'guard message';
    is_deeply \@calls, [], 'no T1, T2, or T3 login attempted';
};

done_testing;
