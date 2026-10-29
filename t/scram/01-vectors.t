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

done_testing;
