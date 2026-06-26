#!/usr/bin/perl
# Unit test for the plugin's error classifiers. No TN, no broker, no
# storage config required — just loads the plugin and exercises the
# regex-based predicates against representative error strings.
#
# This test exists because the integration suite did not catch the /x
# regex flag bug in _is_connection_error (fixed in v2.1.15+deb1). Under
# /x, literal whitespace is stripped from the pattern, so multi-word
# alternatives like "broken pipe" silently compile to "brokenpipe" and
# never match. Every framing/EPIPE failure was misclassified as
# non-recoverable, the retry-with-backoff loop never fired, and the
# stale persistent WS was never invalidated. The cascade is the
# preflight-failed-all-checks pattern in test_run3.
#
# A 5-line unit test would have caught it on day 1. This is that test.
#
# What we assert:
# - _is_connection_error returns true for every framing/network error
#   the plugin actually produces.
# - _is_connection_error returns false for plainly non-network errors.
# - _is_retryable_error returns true for the same connection errors
#   (proves the gate isn't broken either).
# - _is_retryable_error returns false for non-retryable classes
#   (auth, not-found, validation, rate-limit, FK constraints).
# - _is_not_found_error and _is_auth_error sanity-check their own
#   class so a future maintainer can't drop /x there too.
#
# No env vars, no TN. Skippable only if PVE::Storage::Plugin is not
# installed (i.e. you're running on a non-PVE host).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;

# Lazy-load plugin. On a non-PVE machine, skip.
my $plugin_loaded = eval {
    require PVE::Storage::Custom::TrueNASPlugin;
    1;
};
if (!$plugin_loaded) {
    plan skip_all => "PVE::Storage::Custom::TrueNASPlugin not loadable: $@";
}

# ============================================================
# _is_connection_error: must match every transient WS / network error
# ============================================================
my @connection_errors = (
    # Framing errors from _ws_recv_text / _ws_send_text:
    'WS read hdr failed at /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm line 890.',
    'WS read len failed',
    'WS read payload failed',
    'WS write failed: Broken pipe at /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm line 865.',
    'WS write failed: at /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm line 865.',
    'WS payload truncated',
    'WS len exceeded',
    'WebSocket closed unexpectedly',
    'WebSocket.*closed mid-frame',
    # POSIX socket errors:
    'Broken pipe',
    'broken pipe',
    'Connection reset by peer',
    'connection reset by peer',
    'Connection refused',
    'Network is unreachable',
    'No route to host (host is unreachable)',
    'Operation timed out',
    'Connection timed out',
    'Resource temporarily unavailable (temporary failure)',
    # HTTP-style 5xx that mean "try again":
    'GET /api/current returned 502 Bad Gateway',
    '503 Service Unavailable from middlewared',
    '504 Gateway Timeout',
    # TLS-level:
    'ssl error: handshake failed',
    'SSL.*error: tlsv1 alert',
    # Compound:
    'connection failed: tlsv1 alert internal error',
);

for my $err (@connection_errors) {
    ok(PVE::Storage::Custom::TrueNASPlugin::_is_connection_error($err),
        "is_connection_error: $err");
}

# ============================================================
# _is_connection_error: must NOT match plainly-not-network errors
# ============================================================
my @non_connection_errors = (
    'CallError: [EBUSY] Rate Limit Exceeded',
    'Method does not exist',
    'Invalid params',
    'EINVAL: validation error',
    'FOREIGN KEY constraint failed',
    'IntegrityError: dataset already exists',
    'authentication failed: invalid API key',
    'unauthorized',
    '401 Unauthorized',
    '403 Forbidden',
    '404 Not Found',
    'ENOENT: dataset does not exist',
    'Pool not found',
    '',
);

for my $err (@non_connection_errors) {
    ok(!PVE::Storage::Custom::TrueNASPlugin::_is_connection_error($err),
        "NOT is_connection_error: " . ($err eq '' ? '(empty)' : $err));
}

# ============================================================
# _is_retryable_error: connection errors should be retryable
# ============================================================
for my $err (@connection_errors) {
    ok(PVE::Storage::Custom::TrueNASPlugin::_is_retryable_error($err),
        "is_retryable_error: $err");
}

# ============================================================
# _is_retryable_error: non-retryable classes
# ============================================================
my @non_retryable = (
    # Rate limit must NOT retry (D3 fix; retrying feeds the limiter).
    'CallError: [EBUSY] Rate Limit Exceeded',
    "JSON-RPC error: {\"data\":{\"errname\":\"EBUSY\",\"reason\":\"[EBUSY] Rate Limit Exceeded\"}}",
    # FK constraint - retrying never helps.
    'FOREIGN KEY constraint failed: snapshot has clones',
    'IntegrityError: ZFS dependency',
    # Auth - bad credentials don't get fixed by retry.
    '401 Unauthorized',
    '403 Forbidden',
    'authentication failed: invalid API key',
    'invalid key',
    # Not-found - doesn't exist now, won't exist on retry.
    '404 Not Found',
    'ENOENT',
    'InstanceNotFound',
    'does not exist',
    # Validation - param is bad, retry won't fix.
    'Invalid params',
    'validation error: name must be lowercase',
    'EINVAL: invalid argument',
);

for my $err (@non_retryable) {
    ok(!PVE::Storage::Custom::TrueNASPlugin::_is_retryable_error($err),
        "NOT is_retryable_error: $err");
}

# ============================================================
# _is_not_found_error sanity
# ============================================================
my @not_found = (
    '404 Not Found',
    'ENOENT: no such file',
    'InstanceNotFound',
    'PoolDataset tank/proxmox/foo does not exist',
    'volume not found',
);
for my $err (@not_found) {
    ok(PVE::Storage::Custom::TrueNASPlugin::_is_not_found_error($err),
        "is_not_found_error: $err");
}

# ============================================================
# _is_auth_error sanity
# ============================================================
my @auth_errors = (
    '401 Unauthorized',
    '403 Forbidden',
    'authentication failed: invalid API key',
    'unauthorized: insufficient role',
    'forbidden: missing scope',
    'invalid key: token expired',
);
for my $err (@auth_errors) {
    ok(PVE::Storage::Custom::TrueNASPlugin::_is_auth_error($err),
        "is_auth_error: $err");
}

done_testing();
