#!/usr/bin/perl
# Verify env, TN reachability, audit.query path, storage config.
# Always runs first (lexicographic prove ordering).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use RateLimit::Harness qw(env_require env_get test_scfg new_audit_conn count_logins now_iso);

plan tests => 6;

# 1. required env
ok(defined $ENV{TN_HOST} && length $ENV{TN_HOST}, 'TN_HOST set');
ok(defined $ENV{TN_API_KEY} && length $ENV{TN_API_KEY}, 'TN_API_KEY set');
ok(defined $ENV{STORAGE_ID} && length $ENV{STORAGE_ID}, 'STORAGE_ID set');

# 2. storage config loadable
my $scfg = eval { test_scfg() };
ok(defined $scfg && !$@, 'storage config readable via pvesh')
    or diag("error: $@");

# 3. audit/counter path works
my $conn = eval { new_audit_conn() };
ok(defined $conn && !$@, 'TN reachable; audit conn primed')
    or diag("error: $@");

# 4. zero-window count returns 0 (sanity)
my $t = now_iso();
my $n = eval { count_logins($t, $t) };
ok(defined $n && $n == 0, 'empty time window returns zero logins')
    or diag("got: ".($n // 'undef').", err: $@");

done_testing();
