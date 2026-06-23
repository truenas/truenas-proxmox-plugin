#!/usr/bin/perl
# Broker resilience: kill the broker mid-suite, verify plugin recovers.
#
# Sequence:
#   1. Drive a successful call through the broker; sanity it works.
#   2. systemctl restart truenas-plugin-broker (broker drops upstream WS,
#      socket file is recreated).
#   3. Drive another call. Plugin must connect to the new broker socket,
#      broker must open a fresh upstream WS, call must succeed.
#
# What this catches:
#   - Plugin caching a stale broker-side fd somewhere it shouldn't.
#   - Race between socket-replace and next client connect.
#   - Broker startup-to-socket-ready latency too long for plugin to wait.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Time::HiRes qw(sleep);
use RateLimit::Harness qw(env_require new_audit_conn test_scfg say_diag);

plan tests => 4;

# Need root + systemctl present to run this.
my $is_root  = ($> == 0);
my $has_sctl = (system("which systemctl >/dev/null 2>&1") == 0);
unless ($is_root && $has_sctl) {
    plan skip_all => "06-broker-restart needs root + systemctl";
}

new_audit_conn();
my $scfg = test_scfg();
require PVE::Storage::Custom::TrueNASPlugin;

# 1. Baseline: one call must work through the active broker.
my $r1 = eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'system.version', [],
    );
};
ok(!$@ && defined $r1,
    "baseline call via broker succeeded")
    or diag("error: $@");

# 2. Restart the broker. systemctl restart returns after the unit's
# main process is up but before our `Wants=` etc settle. Give the new
# broker a brief moment to bind its Unix socket.
say_diag("restarting truenas-plugin-broker");
my $rc = system("systemctl restart truenas-plugin-broker");
is($rc, 0, "systemctl restart truenas-plugin-broker exit=0");

# Poll for the socket to be present + connectable, up to 10s.
my $deadline = time() + 10;
my $ready = 0;
while (time() < $deadline) {
    if (-S '/run/truenas-plugin/broker.sock') {
        # Try a probe connect.
        require IO::Socket::UNIX;
        my $s = IO::Socket::UNIX->new(
            Peer => '/run/truenas-plugin/broker.sock', Type => 1,
        );
        if ($s) {
            $s->close;
            $ready = 1;
            last;
        }
    }
    sleep 0.2;
}
ok($ready, "broker.sock back online within 10s of restart");

# 3. Call again. Plugin should open a new broker client, broker should
# open a fresh upstream WS, call should succeed.
my $r2 = eval {
    PVE::Storage::Custom::TrueNASPlugin::_api_call(
        $scfg, 'system.version', [],
    );
};
ok(!$@ && defined $r2,
    "post-restart call via broker succeeded")
    or diag("error: $@");

done_testing();
