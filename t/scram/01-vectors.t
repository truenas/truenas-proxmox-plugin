use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha512 hmac_sha512);
use Crypt::PBKDF2;
use Crypt::PBKDF2::Hash::HMACSHA2;

use TrueNAS::SCRAM qw(scram_split_api_key scram_client_first
    scram_process_server_first scram_client_final scram_verify_server_final);

sub b64 { encode_base64($_[0], '') }

# API key split
is_deeply [scram_split_api_key("17-abcdef1234567890xyz")], [17, "abcdef1234567890xyz"], "split api key";
eval { scram_split_api_key("17-abc-def-ghi") };
is $@, "", "a dash elsewhere is still valid (first-dash split)";
is_deeply [scram_split_api_key("17-abc-def")], [17, "abc-def"], "first-dash split keeps rest";
eval { scram_split_api_key("notanumber-xyz") };
like $@, qr/invalid API key/, "non-numeric id rejected";
eval { scram_split_api_key("nodash") };
like $@, qr/invalid API key format/, "missing separator rejected";

# Client-first shape: raw 32-byte nonce, base64, correct frame
my ($st, $wire) = scram_client_first("alice", 42);
like $wire, qr{^n,,n=alice:42,r=[A-Za-z0-9+/]+={0,2}$}, "client-first wire shape";
like $wire, qr{r=.{44}$}, "32-byte nonce -> 44-char base64";

# Boundary refusals: salt length, iteration bounds
eval { scram_process_server_first($st, "r=XXX,s=" . b64("short") . ",i=500000", "secret") };
like $@, qr/salt must be 16 bytes/, "short salt rejected";
eval { scram_process_server_first($st, "r=XXX,s=" . b64("x" x 16) . ",i=49999", "secret") };
like $@, qr/iteration count .* outside/, "iter floor-1 rejected";
eval { scram_process_server_first($st, "r=XXX,s=" . b64("x" x 16) . ",i=5000001", "secret") };
like $@, qr/iteration count .* outside/, "iter ceiling+1 rejected";

# Self round-trip with independent derivation
subtest 'self round-trip' => sub {
    my $iters  = 50000;
    my $salt   = join '', map { chr } 1 .. 16;
    my $secret = "s3cr3t-part";
    my ($s, $first) = scram_client_first("bob", 7);

    my ($bare) = $first =~ /^n,,(.*)$/;
    my ($cnonce_b64) = $bare =~ /,r=(.*)$/;
    my $cnonce = decode_base64($cnonce_b64);
    is length($cnonce), 32, "client nonce is 32 raw bytes";

    my $snonce_raw = join '', map { chr(255 - $_) } 1 .. 32;
    my $combined   = b64($cnonce . $snonce_raw);
    my $server_first = "r=$combined,s=" . b64($salt) . ",i=$iters";

    scram_process_server_first($s, $server_first, $secret);
    my $final = scram_client_final($s);

    # independent expectation
    my $salted = Crypt::PBKDF2->new(
        hasher     => Crypt::PBKDF2::Hash::HMACSHA2->new(sha_size => 512),
        iterations => $iters,
        output_len => 64,
    )->PBKDF2($salt, $secret);
    my $ckey   = hmac_sha512("Client Key", $salted);
    my $skey   = sha512($ckey);
    my $without = "c=biws,r=$combined";
    my $auth   = "$bare,$server_first,$without";
    my $csig   = hmac_sha512($auth, $skey);
    my $proof  = $ckey ^ $csig;
    is $final, "$without,p=" . b64($proof), "client-final wire matches independent derivation";

    my $server_key = hmac_sha512("Server Key", $salted);
    my $ssig       = hmac_sha512($auth, $server_key);
    ok scram_verify_server_final($s, "v=" . b64($ssig)), "valid server signature accepted";

    my $bad = $ssig;
    substr($bad, 10, 1) = chr(ord(substr($bad, 10, 1)) ^ 1);
    eval { scram_verify_server_final($s, "v=" . b64($bad)) };
    like $@, qr/server signature verification failed/, "flipped byte in v= rejected";

    eval { scram_verify_server_final($s, "x=" . b64($ssig)) };
    like $@, qr/malformed server-final/, "missing v= rejected";
    eval { scram_verify_server_final($s, "v=!!!notbase64") };
    like $@, qr/invalid server signature encoding/, "bad base64 rejected";

    # server nonce that does not extend client nonce
    my ($s2) = scram_client_first("bob", 7);
    eval { scram_process_server_first($s2, "r=" . b64("z" x 64) . ",s=" . b64($salt) . ",i=$iters", $secret) };
    like $@, qr/does not extend client nonce/, "foreign server nonce rejected";
};

subtest 'known-answer vector against Python stdlib' => sub {
    # Expected values were computed independently with Python hashlib/hmac/
    # pbkdf2_hmac (see .superpowers/sdd/2026-10-29-scram-auth/compute-vector.py).
    # Monkey-patch: SCRAM.pm imports urandom into its own namespace, so we
    # override TrueNAS::SCRAM::urandom to return a fixed 32-byte client nonce.
    no warnings 'redefine';
    local *TrueNAS::SCRAM::urandom = sub { return "A" x 32 };
    use warnings 'redefine';

    my $server_first = "r=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQg==,s=MDEyMzQ1Njc4OWFiY2RlZg==,i=50000";
    my $exp_final = "c=biws,r=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQg==,p=RajK7VTkIwW2jqC+BVVMmNSiw6h7boEx1SVd1HaFsW1doVh3vP1Yumdaht3Iq7fiv62e/0db/40VmRmpSmmQmw==";
    my $server_final = "v=100k8G7PP/AmrdBCfvOEgpU6vwmMpY3JpeN5eVtJMFi3iOC+qIBrwgfIoiBSTqU+vlwcH/Va3YprRcpwitFuoQ==";

    my ($state, $first) = scram_client_first("testuser", 1);
    is $first, "n,,n=testuser:1,r=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=", "client-first matches vector";

    scram_process_server_first($state, $server_first, "testsecret_for_vector_01");
    is scram_client_final($state), $exp_final, "client-final (c=, r=, p=) matches Python vector";

    my $ok = eval { scram_verify_server_final($state, $server_final) };
    is $@, "", "server-final verification does not die";
    ok $ok, "server signature v= matches Python vector";
};

subtest 'SCRAM-PLUS known-answer vector' => sub {
    # Expected values computed independently with Python stdlib (see
    # .superpowers/sdd/2026-10-29-scram-plus/compute-plus-vector.py).
    no warnings 'redefine';
    local *TrueNAS::SCRAM::urandom = sub { return "A" x 32 };
    use warnings 'redefine';

    my $cb_raw = "C" x 32;
    my $combined = "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQg==";
    my $server_first = "r=$combined,s=MDEyMzQ1Njc4OWFiY2RlZg==,i=50000";
    my $exp_cattr = "cD10bHMtc2VydmVyLWVuZC1wb2ludCwsQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M=";
    my $exp_p     = "jm6KoNj3mliOFSct6NXOHnSlAMS8wcY/FTC4IQAnMMLP781LVOzrLm/s02c3G+tEISfMVNFH/kuA9+z1CMi6ow==";
    my $exp_v     = "VEnNF6wqjX+M9w+iVSYJlTB8AgkSwZYM6Gb4u705ouOhH2wikou8D4fYSuPwbjHF0y1X6DYDVDnyqU92Tnv3HA==";

    my ($state, $first) = scram_client_first("testuser", 1, channel_binding => $cb_raw);
    is $first, "p=tls-server-end-point,,n=testuser:1,r=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=",
        "PLUS client-first uses p=tls-server-end-point GS2 header";
    is $state->{gs2_header}, "p=tls-server-end-point,,", "state records PLUS gs2_header";

    scram_process_server_first($state, $server_first, "testsecret_for_vector_01");
    my $final = scram_client_final($state);
    is $final, "c=$exp_cattr,r=$combined,p=$exp_p", "PLUS client-final (c=, r=, p=) matches Python vector";

    my $ok = eval { scram_verify_server_final($state, "v=$exp_v") };
    is $@, "", "PLUS server-final verification does not die";
    ok $ok, "PLUS server signature matches Python vector";

    # plain SCRAM state still records n,,
    my ($plain) = scram_client_first("testuser", 1);
    is $plain->{gs2_header}, "n,,", "plain SCRAM gs2_header is n,,";
};

done_testing;
