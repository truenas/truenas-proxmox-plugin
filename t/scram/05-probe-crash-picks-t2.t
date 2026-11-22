#!/usr/bin/perl
# TrueNAS 25.10.4 answers an UNAUTHENTICATED auth.mechanism_choices with an
# EINVAL envelope (middlewared auth.py: AttributeError "'NoneType' object has
# no attribute 'may_create_auth_token'") instead of the mechanism list. The
# selector only knew "method missing" and "rate limited", so a storage WITH
# tn_api_username still logged in through the deprecated
# auth.login_with_api_key (T3) - the path TrueNAS will remove. Envelope
# captured from a TrueNAS 25.10.4 server.
#
# Counts the dangerous call (login_with_api_key), not internals.
# Run with:  prove -Ilib -v t/scram/05-probe-crash-picks-t2.t
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin;

my $BROKER = $ENV{TN_BROKER} // "$FindBin::Bin/../../tools/truenas-plugin-broker";
plan skip_all => "broker not found at $BROKER" unless -f $BROKER;
require $BROKER;    # main() is guarded by `unless caller`

my $CRASH = { code => -32001, message => 'Method call error', data => {
    error => 22, errname => 'EINVAL', extra => undef,
    reason => q{'NoneType' object has no attribute 'may_create_auth_token'} } };

my (@methods, %reply);
no warnings qw(redefine once);
local *main::linfo = sub { };
local *main::lwarn = sub { };
local *main::ws_rpc = sub {
    my $m = $_[1]{method};
    push @methods, $m;
    my $r = $reply{$m} // die "unexpected RPC $m\n";
    return ref $r eq 'CODE' ? $r->() : $r;
};
my $auth = sub {
    my (%scfg) = @_;
    @methods = ();
    my $ok = eval { main::_authenticate({ sock => undef, next_id => 1 },
        { api_key => '1-k', api_username => 'pve', %scfg }, time() + 30); 1 };
    return ($ok, $@);
};
my $legacy = sub { scalar grep { $_ eq 'auth.login_with_api_key' } @methods };
my $SUCCESS = { result => { response_type => 'SUCCESS' } };
my $NOMETHOD = { error => { code => -32601, message => 'Method not found' } };

subtest 'auto: crashed probe + username -> login_ex, never the legacy login' => sub {
    %reply = ('auth.mechanism_choices' => { error => $CRASH },
              'auth.login_ex'          => $SUCCESS,
              'auth.login_with_api_key'=> { result => JSON::PP::true });
    my ($ok, $err) = $auth->();
    ok $ok, 'authenticated' or diag $err;
    is $legacy->(), 0, 'auth.login_with_api_key not called';
    is_deeply \@methods, ['auth.mechanism_choices', 'auth.login_ex'];
};

subtest 'plain: same crash -> login_ex' => sub {
    my ($ok, $err) = $auth->(auth_mechanism => 'plain');
    ok $ok or diag $err;
    is $legacy->(), 0, 'auth.login_with_api_key not called';
};

subtest 'crashed probe on a server without login_ex still reaches T3' => sub {
    local $reply{'auth.login_ex'} = $NOMETHOD;
    my ($ok, $err) = $auth->();
    ok $ok or diag $err;
    is_deeply \@methods, ['auth.mechanism_choices', 'auth.login_ex', 'auth.login_with_api_key'];
};

subtest 'unchanged: probe method-not-found -> T3 directly' => sub {
    local $reply{'auth.mechanism_choices'} = $NOMETHOD;
    my ($ok) = $auth->();
    ok $ok;
    is_deeply \@methods, ['auth.mechanism_choices', 'auth.login_with_api_key'];
};

subtest 'unchanged: transport failure on the probe keeps the T3 floor' => sub {
    local $reply{'auth.mechanism_choices'} = sub { die "read timeout\n" };
    my ($ok) = $auth->();
    ok $ok;
    is_deeply \@methods, ['auth.mechanism_choices', 'auth.login_with_api_key'];
};

subtest 'unchanged: no username -> T3, no probe' => sub {
    my ($ok) = $auth->(api_username => undef);
    ok $ok;
    is_deeply \@methods, ['auth.login_with_api_key'];
};

subtest 'unchanged: AUTH_ERR from login_ex stays fatal (no silent T3)' => sub {
    local $reply{'auth.login_ex'} = { result => { response_type => 'AUTH_ERR' } };
    my ($ok, $err) = $auth->();
    ok !$ok; like $err, qr/AUTH_ERR/;
    is $legacy->(), 0;
};

done_testing;
