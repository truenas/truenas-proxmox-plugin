package TrueNAS::SCRAM;

use strict;
use warnings;
use feature 'bitwise';
no warnings 'experimental::bitwise';

use Exporter 'import';
use Digest::SHA qw(sha512 hmac_sha512);
use MIME::Base64 qw(encode_base64 decode_base64);
use Crypt::PBKDF2;
use Crypt::PBKDF2::Hash::HMACSHA2;
use Crypt::URandom qw(urandom);

our @EXPORT_OK = qw(
    scram_split_api_key
    scram_client_first
    scram_process_server_first
    scram_client_final
    scram_verify_server_final
);

use constant {
    SALT_LEN  => 16,
    NONCE_LEN => 32,
    MIN_ITERS => 50000,
    MAX_ITERS => 5000000,
};

=head1 NAME

TrueNAS::SCRAM - client side of SCRAM-SHA-512 (RFC 5802) for TrueNAS API keys

=head1 DESCRIPTION

Unbound (GS2 header C<n,,>) SCRAM-SHA-512 as required by TrueNAS 26+ on
C<auth.login_ex>. The state hashref returned by C<scram_client_first> is
threaded through the remaining calls.

=cut

sub _b64 { return encode_base64($_[0], '') }

# Strict base64 decode: returns undef when the input is not canonical base64.
sub _b64_strict {
    my ($s) = @_;
    return undef if !defined $s || $s !~ m{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z};
    return decode_base64($s);
}

=head2 scram_split_api_key($api_key)

Splits C<< <id>-<secret> >> at the first dash. Returns C<($key_id, $secret)>;
dies on a missing separator or non-numeric id.

=cut

sub scram_split_api_key {
    my ($api_key) = @_;
    die "invalid API key format (want <id>-<secret>)\n"
        if !defined $api_key || $api_key !~ /-/;
    my ($id, $secret) = split /-/, $api_key, 2;
    die "invalid API key ID '$id'\n" if $id !~ /\A[0-9]+\z/;
    return (int($id), $secret);
}

=head2 scram_client_first($username, $key_id, %opts)

Generates a 32-byte nonce and returns C<($state, $wire)> where C<$wire> is
C<n,,n=E<lt>userE<gt>:E<lt>kidE<gt>,r=E<lt>base64E<gt>>. With
C<< channel_binding => $cb_raw >> the GS2 header is
C<p=tls-server-end-point,,> and C<$cb_raw> is kept in the state for the
C<c=> attribute of client-final.

=cut

sub scram_client_first {
    my ($username, $key_id, %opts) = @_;
    my $nonce = urandom(NONCE_LEN);
    my $bare  = "n=$username:$key_id,r=" . _b64($nonce);
    my $gs2   = defined $opts{channel_binding} ? 'p=tls-server-end-point,,' : 'n,,';
    my $state = {
        clientFirstBare => $bare,
        clientNonceRaw  => $nonce,
        gs2_header      => $gs2,
    };
    $state->{cb_raw} = $opts{channel_binding} if defined $opts{channel_binding};
    return ($state, "$gs2$bare");
}

=head2 scram_process_server_first($state, $server_first, $secret)

Parses C<r=,s=,i=>, enforces a 16-byte salt and 50000..5000000 iterations,
checks the server nonce extends ours (on decoded bytes), and derives
SaltedPassword via PBKDF2-HMAC-SHA512. Mutates C<$state>; dies on any problem.

=cut

sub scram_process_server_first {
    my ($state, $server_first, $secret) = @_;
    $state->{serverFirstStr} = $server_first;

    my ($nonce_b64, $salt, $iters);
    for my $part (split /,/, $server_first) {
        my ($k, $v) = split /=/, $part, 2;
        next if !defined $v;
        if ($k eq 'r') {
            $nonce_b64 = $v;
        } elsif ($k eq 's') {
            $salt = _b64_strict($v);
            die "scram: invalid salt encoding\n" if !defined $salt;
        } elsif ($k eq 'i') {
            die "scram: invalid iteration count '$v'\n" if $v !~ /\A[0-9]+\z/;
            $iters = int($v);
        }
    }
    die "scram: malformed server-first message\n"
        if !defined $nonce_b64 || !defined $salt || !defined $iters;

    die "scram: salt must be 16 bytes, got " . length($salt) . "\n"
        if length($salt) != SALT_LEN;
    die "scram: iteration count $iters outside " . MIN_ITERS . ".." . MAX_ITERS . "\n"
        if $iters < MIN_ITERS || $iters > MAX_ITERS;

    # The server decodes our nonce, appends its own bytes and re-encodes, so
    # the prefix check must be on decoded bytes, not base64 text.
    my $combined = _b64_strict($nonce_b64);
    die "scram: invalid server nonce encoding\n" if !defined $combined;
    my $cn = $state->{clientNonceRaw};
    die "scram: server nonce does not extend client nonce\n"
        if length($combined) <= length($cn) || substr($combined, 0, length($cn)) ne $cn;

    my $pbkdf2 = Crypt::PBKDF2->new(
        hasher     => Crypt::PBKDF2::Hash::HMACSHA2->new(sha_size => 512),
        iterations => $iters,
        output_len => 64,
    );
    $state->{saltedPassword}  = $pbkdf2->PBKDF2($salt, $secret);
    $state->{serverNonceB64}  = $nonce_b64;
    return 1;
}

sub _client_final_without_proof {
    my ($state) = @_;
    my $gs2 = $state->{gs2_header} // 'n,,';
    return 'c=' . _b64($gs2 . ($state->{cb_raw} // '')) . ',r=' . $state->{serverNonceB64};
}

sub _auth_message {
    my ($state) = @_;
    return join ',', $state->{clientFirstBare}, $state->{serverFirstStr},
        _client_final_without_proof($state);
}

=head2 scram_client_final($state)

Returns C<c=biws,r=E<lt>combinedE<gt>,p=E<lt>proofE<gt>> and records
C<authMessage> in C<$state>.

=cut

sub scram_client_final {
    my ($state) = @_;
    die "scram: server-first not processed\n" if !defined $state->{saltedPassword};
    my $auth       = _auth_message($state);
    $state->{authMessage} = $auth;
    my $client_key = hmac_sha512("Client Key", $state->{saltedPassword});
    my $stored_key = sha512($client_key);
    my $client_sig = hmac_sha512($auth, $stored_key);
    my $proof      = $client_key ^. $client_sig;
    return _client_final_without_proof($state) . ',p=' . _b64($proof);
}

# Constant-time equality for equal-length strings: no early exit on mismatch.
sub _ct_equal {
    my ($x, $y) = @_;
    return 0 if length($x) != length($y);
    my $acc = 0;
    my @a = unpack 'C*', $x;
    my @b = unpack 'C*', $y;
    $acc |= $a[$_] ^ $b[$_] for 0 .. $#a;
    return $acc == 0 ? 1 : 0;
}

=head2 scram_verify_server_final($state, $server_final)

Verifies C<v=E<lt>ServerSignatureE<gt>> (mutual authentication) with a
constant-time compare. Returns true; dies on malformed input, bad base64, or
signature mismatch.

=cut

sub scram_verify_server_final {
    my ($state, $server_final) = @_;
    die "scram: malformed server-final message\n"
        if !defined $server_final || $server_final !~ /\Av=/;
    my $got = _b64_strict(substr($server_final, 2));
    die "scram: invalid server signature encoding\n" if !defined $got;
    die "scram: server signature verification failed (no key material)\n"
        if !defined $state->{saltedPassword};

    my $auth       = $state->{authMessage} // _auth_message($state);
    my $server_key = hmac_sha512("Server Key", $state->{saltedPassword});
    my $want       = hmac_sha512($auth, $server_key);
    die "scram: server signature verification failed\n" if !_ct_equal($got, $want);
    return 1;
}

1;
