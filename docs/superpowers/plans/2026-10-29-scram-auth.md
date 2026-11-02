# SCRAM Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broker's single `auth.login_with_api_key` call with a three-tier auth path (SCRAM → `auth.login_ex` plain → legacy), landing SCRAM-SHA-512 support ahead of TrueNAS 27's removal of the legacy method.

**Architecture:** Pure-Perl SCRAM-SHA-512 primitives in a new `lib/TrueNAS/SCRAM.pm`, three per-tier login helpers inside the broker daemon, a selection function that reads `auth.mechanism_choices` and dispatches, and a widened plugin→broker wire envelope so storages carry the new `tn_api_username` and `tn_auth_mechanism` scfg fields.

**Tech Stack:** Perl 5.40 (trixie) / 5.36 (bookworm), `Digest::SHA` (core), `MIME::Base64` (core), `Crypt::PBKDF2`, `Crypt::URandom`, existing `IO::Socket::SSL` for TLS, existing `PVE::JSONSchema` for storage.cfg schema.

**Spec:** `docs/superpowers/specs/2026-10-29-scram-auth-design.md`

## Global Constraints

- Minimum supported PVE: `pve-manager (>= 8.0.0)` — do not raise.
- Minimum supported TrueNAS: 24.10 (no `auth.login_ex`) — the T3 legacy fallback must stay working.
- SCRAM nonce: exactly 32 raw bytes, base64-encoded on the wire. Any other size → server rejects.
- SCRAM salt: exactly 16 bytes. Client refuses other sizes.
- SCRAM iteration count: `[50000, 5000000]`. Client refuses outside.
- SCRAM hash: SHA-512 (never SHA-1 / SHA-256).
- Broker worker count: default 4; four prefork logins at startup must stay inside TrueNAS's smallest auth rate-limit bucket (20 / 60 s / IP).
- Dependencies added: only `libcrypt-pbkdf2-perl` and `libcrypt-urandom-perl` — both must remain in the main component of Debian bookworm and trixie.
- Raw API key secret must not persist past `SaltedPassword` derivation inside the SCRAM path.
- No fail-open fallbacks: a SCRAM `verifyServerFinal` failure never retries at a lower tier; a plain `AUTH_ERR` / `DENIED` / `EXPIRED` never retries at legacy; a probe returning "rate limited" never falls back from SCRAM to plain.

## Review Focus

- **Malformed `tn_api_key` without the `<id>-<secret>` separator** — SCRAM's `splitAPIKey` must emit a clear "invalid API key format" error at the start of T1 instead of a cryptic PBKDF2 crash deep in the exchange. Pinned by Task 1's vector tests.
- **`tn_api_username` containing a `:` character** — breaks the SCRAM `n=<user>:<keyID>` field and surfaces as AUTH_ERR with no explanation. The schema validator in Task 6 refuses `:` in `tn_api_username`.
- **`tn_auth_mechanism=scram` on a TN 25.10 server** (no SCRAM capability) — must die with a specific "server does not support SCRAM" message, not silently fall back to plain. Pinned by Task 5's selection tests.
- **`auth.login_ex` returning `OTP_REQUIRED` / `REDIRECT` / `DENIED` to a plain-key login** — these aren't `SUCCESS` and must be treated as auth failure, not as silent authenticated. Pinned by Task 3's T2 tests.
- **Pre-auth probe returning "method not found" vs rate-limited** — misclassifying rate-limit as method-not-found causes a key leak (T3 sends raw key to a SCRAM-capable server); misclassifying method-not-found as rate-limit causes false SCRAM attempts against TN 24.10 that fail. Pinned by Task 2's `_is_rate_limited` tests and Task 5's selection tests.

---

## File Structure

- **New files:**
  - `lib/TrueNAS/SCRAM.pm` — pure crypto primitives (4 exported subs).
  - `t/scram/01-vectors.t` — SCRAM crypto round-trip + boundary tests.
  - `t/scram/02-broker-tiers.t` — unit tests for the three broker login helpers + `_is_rate_limited` + `_select_mechanism` with mocked `ws_rpc`.
  - `t/scram/03-pool-key.t` — pool-key extension tests.
  - `t/scram/04-plugin-wire.t` — plugin schema + `_broker_rpc` envelope tests.
  - `t/scram/05-live.t` — live-cluster integration test (env-gated).
- **Modified files:**
  - `tools/truenas-plugin-broker` — tier helpers, selection, ws_open rewrite, pool-key change.
  - `TrueNASPlugin.pm` — scfg schema additions, validator, `_broker_rpc` envelope widening.
  - `debian/control` — two runtime depends.
  - `wiki/Configuration.md` or module POD — docs for the two new scfg fields.

Tasks map 1:1 to the file-structure boundaries above; each produces independently reviewable, testable changes.

---

### Task 1: SCRAM crypto module

**Files:**
- Create: `lib/TrueNAS/SCRAM.pm`
- Create: `t/scram/01-vectors.t`

**Interfaces:**
- Consumes: `Digest::SHA` (`sha512`, `hmac_sha512`), `Crypt::PBKDF2`, `Crypt::URandom::urandom`, `MIME::Base64` (`encode_base64`, `decode_base64`).
- Produces (all exported from `TrueNAS::SCRAM`):
  - `scram_split_api_key($api_key) → ($key_id:int, $secret:str)` — dies on malformed key.
  - `scram_client_first($username:str, $key_id:int) → ($state:HashRef, $wire:str)` — generates 32-byte nonce, builds `n,,n=<user>:<kid>,r=<b64>`.
  - `scram_process_server_first($state, $server_first:str, $secret:str)` — mutates `$state` with `saltedPassword`, `serverFirstStr`, `serverNonceB64`; dies on malformed input, bad salt length, or iteration-count out of range.
  - `scram_client_final($state) → $wire:str` — returns `c=biws,r=<combined>,p=<b64>`; mutates `$state` with `authMessage`.
  - `scram_verify_server_final($state, $server_final:str)` — dies on missing `v=`, bad base64, or signature mismatch; returns true on success.

- [ ] **Step 1: Write failing vector tests**

```perl
# t/scram/01-vectors.t
use Test::More;
use TrueNAS::SCRAM qw(scram_split_api_key scram_client_first
    scram_process_server_first scram_client_final scram_verify_server_final);

# API key split
is_deeply [scram_split_api_key("17-abcdef1234567890xyz")], [17, "abcdef1234567890xyz"], "split api key";
eval { scram_split_api_key("no-dash-but-dashes-in-secret") };
is $@, "", "a dash elsewhere is still valid (first-dash split)";
eval { scram_split_api_key("notanumber-xyz") };
like $@, qr/invalid API key/, "non-numeric id rejected";
eval { scram_split_api_key("nodash") };
like $@, qr/invalid API key format/, "missing separator rejected";

# Client-first shape: raw 32-byte nonce, base64, correct frame
my ($st, $wire) = scram_client_first("alice", 42);
like $wire, qr{^n,,n=alice:42,r=[A-Za-z0-9+/]+={0,2}$}, "client-first wire shape";
like $wire, qr{r=.{44}$}, "32-byte nonce → 44-char base64";

# Boundary refusals: salt length, iteration bounds
eval { scram_process_server_first($st, "r=XXX,s=".MIME::Base64::encode_base64("short","").",i=500000", "secret") };
like $@, qr/salt must be 16 bytes/, "short salt rejected";
eval { scram_process_server_first($st, "r=XXX,s=".MIME::Base64::encode_base64("x" x 16,"").",i=1", "secret") };
like $@, qr/iteration count .* outside/, "iter below floor rejected";
eval { scram_process_server_first($st, "r=XXX,s=".MIME::Base64::encode_base64("x" x 16,"").",i=10000000", "secret") };
like $@, qr/iteration count .* outside/, "iter above ceiling rejected";

# Round-trip against Terraform fixtures: known server-first + secret → known client-final (p=)
# Fixtures copied from ~/terraform/internal/client/scram_internal_test.go
# (expected proof_b64 computed with the terraform scram.go round-tripper against
# the same client-first and server-first).
subtest 'terraform round-trip' => sub { ... };

# Mutual auth: a server-final whose v= doesn't verify must die.
eval { scram_verify_server_final($st, "v=".MIME::Base64::encode_base64("x" x 64, "")) };
like $@, qr/server signature verification failed/, "bad v= rejected";

done_testing;
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `prove -v t/scram/01-vectors.t`
Expected: FAIL with "Can't locate TrueNAS/SCRAM.pm".

- [ ] **Step 3: Implement the module**

Create `lib/TrueNAS/SCRAM.pm`. Follow the design doc section "SCRAM crypto, pure Perl" (lines 264–294). PBKDF2 via `Crypt::PBKDF2->new(hasher => Crypt::PBKDF2::Hash::HMACSHA2->new(sha_size => 512), iterations => ..., output_len => 64)`. Compare `v=` with a constant-time compare (bitwise XOR all bytes, OR the results, return boolean on the OR being 0; `Digest::SHA` ships no constant-time compare).

The exported functions' signatures are the only prose contract; everything else is RFC 5802 translated to the design's Perl helpers.

- [ ] **Step 4: Run tests to verify they pass**

Run: `prove -v t/scram/01-vectors.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/TrueNAS/SCRAM.pm t/scram/01-vectors.t
git commit -m "scram: add SCRAM-SHA-512 crypto primitives

Pure-Perl implementation of RFC 5802 client-side SCRAM-SHA-512, matching
the wire format TrueNAS 26+ requires on auth.login_ex. Four exported
functions covering nonce generation, server-first parsing + validation,
client-proof derivation, and mutual-auth server-signature verification.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Broker rate-limit discriminator + legacy T3 factored

**Files:**
- Modify: `tools/truenas-plugin-broker` — around `ws_open` auth call (currently line ~201).
- Create: `t/scram/02-broker-tiers.t`

**Interfaces:**
- Consumes: `ws_rpc($conn, $json)` from broker; `JSON::PP`.
- Produces (new sub names, in-broker lexical scope):
  - `_is_rate_limited($err:str) → bool` — matches `APIError.code ∈ {0, 16, 22, -32000}` or lowercased message containing `"rate limit"` / `"concurrent calls"`. The `$err` is the die-string from `ws_rpc`.
  - `_do_t3_login($conn, $api_key:str)` — issues one `auth.login_with_api_key` call; dies on non-boolean or `false`.

- [ ] **Step 1: Write failing tests**

```perl
# t/scram/02-broker-tiers.t (first subset)
use Test::More;
# Load the broker as a library — the script has a BEGIN guard; wrap in a do-block.
require "./tools/truenas-plugin-broker";  # loads subs, does not run main()

subtest '_is_rate_limited' => sub {
    ok TrueNAS::Broker::_is_rate_limited(q{truenas API error (code 16): [EBUSY] Rate Limit Exceeded});
    ok TrueNAS::Broker::_is_rate_limited(q{code 22: Rate limit exceeded, try again});
    ok TrueNAS::Broker::_is_rate_limited(q{code 0: concurrent calls limit});
    ok TrueNAS::Broker::_is_rate_limited(q{code -32000: rate limit});
    ok !TrueNAS::Broker::_is_rate_limited(q{Method 'auth.mechanism_choices' not found});
    ok !TrueNAS::Broker::_is_rate_limited(q{EINVAL: login_data: Input tag 'SCRAM'});
    ok !TrueNAS::Broker::_is_rate_limited(undef);
    ok !TrueNAS::Broker::_is_rate_limited("");
};

subtest '_do_t3_login' => sub {
    my @calls;
    local *TrueNAS::Broker::ws_rpc = sub {
        push @calls, $_[1];
        return JSON::PP::true;
    };
    my $conn = { sock => undef };
    TrueNAS::Broker::_do_t3_login($conn, "17-abc");
    is $calls[0]->{method}, "auth.login_with_api_key";
    is_deeply $calls[0]->{params}, ["17-abc"];

    local *TrueNAS::Broker::ws_rpc = sub { return JSON::PP::false };
    eval { TrueNAS::Broker::_do_t3_login($conn, "17-abc") };
    like $@, qr/legacy API-key login rejected/, "false → die";

    local *TrueNAS::Broker::ws_rpc = sub { die "concurrent calls limit\n" };
    eval { TrueNAS::Broker::_do_t3_login($conn, "17-abc") };
    like $@, qr/concurrent calls limit/, "ws_rpc errors propagate";
};
done_testing;
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `prove -v t/scram/02-broker-tiers.t`
Expected: FAIL — `_is_rate_limited` / `_do_t3_login` undefined.

- [ ] **Step 3: Factor the legacy auth call out of `ws_open` and add `_is_rate_limited`**

In `tools/truenas-plugin-broker`:
- Add a `TrueNAS::Broker` package (`package TrueNAS::Broker;` early in the file; existing `main` code becomes `TrueNAS::Broker::main()` or stays unqualified under `package main;` after the require-time guard). Alternative: leave as `package main;` and name tests to call `::_is_rate_limited` instead of `TrueNAS::Broker::...`. Choose whichever matches the file's current single-package shape.
- Extract the `method => "auth.login_with_api_key", params => [...]` call site into `_do_t3_login($conn, $api_key)`.
- Add `_is_rate_limited` next to it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `prove -v t/scram/02-broker-tiers.t`
Expected: PASS. Also run `perl -c tools/truenas-plugin-broker` and `scp` to pve to confirm it still loads under the real daemon context.

- [ ] **Step 5: Commit**

```bash
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t
git commit -m "broker: factor legacy login, add rate-limit helper

Extracts the current auth.login_with_api_key call into _do_t3_login, and
adds _is_rate_limited (matching the terraform provider's heuristic:
APIError code 0/16/22/-32000, or 'rate limit'/'concurrent calls' in the
message). No behavior change on the current call path; prepares for the
tier-selection logic that follows.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Broker T2 — `auth.login_ex mechanism=API_KEY_PLAIN`

**Files:**
- Modify: `tools/truenas-plugin-broker`
- Modify: `t/scram/02-broker-tiers.t` (add subtest)

**Interfaces:**
- Consumes: `ws_rpc`, `_is_rate_limited` from Task 2.
- Produces:
  - `_do_t2_login($conn, $username:str, $api_key:str)` — issues one `auth.login_ex` call with `mechanism=API_KEY_PLAIN`; dies on anything except a `response_type == "SUCCESS"` reply.

- [ ] **Step 1: Add failing subtest**

```perl
# append to t/scram/02-broker-tiers.t
subtest '_do_t2_login success' => sub {
    local *TrueNAS::Broker::ws_rpc = sub {
        is $_[1]->{method}, "auth.login_ex";
        is_deeply $_[1]->{params}, [{
            mechanism     => "API_KEY_PLAIN",
            username      => "alice",
            api_key       => "17-abc",
            login_options => {},
        }];
        return {
            response_type   => "SUCCESS",
            user_info       => { ... },
            authenticator   => "LEVEL_1",
            reconnect_token => undef,
        };
    };
    ok lives_ok { TrueNAS::Broker::_do_t2_login({}, "alice", "17-abc") };
};

subtest '_do_t2_login refuses non-SUCCESS' => sub {
    for my $rt (qw(AUTH_ERR DENIED EXPIRED OTP_REQUIRED REDIRECT)) {
        local *TrueNAS::Broker::ws_rpc = sub { return { response_type => $rt } };
        eval { TrueNAS::Broker::_do_t2_login({}, "alice", "17-abc") };
        like $@, qr/API_KEY_PLAIN login rejected.*$rt/, "$rt rejected";
    }
};

subtest '_do_t2_login propagates ws_rpc die' => sub {
    local *TrueNAS::Broker::ws_rpc = sub { die "Method 'auth.login_ex' not found\n" };
    eval { TrueNAS::Broker::_do_t2_login({}, "alice", "17-abc") };
    like $@, qr/not found/;
};
```

- [ ] **Step 2: Run to confirm new subtests fail**

Run: `prove -v t/scram/02-broker-tiers.t`
Expected: FAIL — `_do_t2_login` undefined.

- [ ] **Step 3: Implement `_do_t2_login($conn, $username, $api_key)` in the broker**

Builds the single-call envelope per spec lines 181–201. Parse the result hash; any `response_type` other than `SUCCESS` dies with a message that includes the server's `response_type` string.

- [ ] **Step 4: Run subtests, confirm pass**

Run: `prove -v t/scram/02-broker-tiers.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t
git commit -m "broker: add T2 login (auth.login_ex API_KEY_PLAIN)

Implements the TN 25.10+ plain-API-key login via auth.login_ex. Treats
only response_type=SUCCESS as authenticated; AUTH_ERR / DENIED / EXPIRED
/ OTP_REQUIRED / REDIRECT all die with a message naming the response
type. No fail-open to T3.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Broker T1 — SCRAM via `auth.login_ex`

**Files:**
- Modify: `tools/truenas-plugin-broker`
- Modify: `t/scram/02-broker-tiers.t`

**Interfaces:**
- Consumes: `TrueNAS::SCRAM` (Task 1); `ws_rpc`.
- Produces:
  - `_do_t1_login($conn, $username:str, $api_key:str)` — splits the key, drives the three-step SCRAM exchange over `ws_rpc`, verifies the server signature, dies with distinct messages for malformed server-first, bad server signature, SCRAM-unsupported server, or any `ws_rpc` failure.
  - `_is_scram_unsupported_error($err:str) → bool` — matches the known TN 25.10 rejection: `/Input tag 'SCRAM'.*does not match/`.

- [ ] **Step 1: Add failing subtest**

```perl
# append to t/scram/02-broker-tiers.t
subtest '_is_scram_unsupported_error' => sub {
    ok TrueNAS::Broker::_is_scram_unsupported_error(
        q{EINVAL: login_data: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags});
    ok !TrueNAS::Broker::_is_scram_unsupported_error(q{Rate Limit Exceeded});
    ok !TrueNAS::Broker::_is_scram_unsupported_error(q{server signature verification failed});
};

subtest '_do_t1_login happy path' => sub {
    my @seen;
    local *TrueNAS::Broker::ws_rpc = sub {
        my ($conn, $req) = @_;
        push @seen, $req;
        is $req->{method}, "auth.login_ex";
        if ($req->{params}[0]{scram_type} eq "CLIENT_FIRST_MESSAGE") {
            # canned server-first that round-trips against the Terraform fixtures
            return {
                response_type => "SCRAM_RESPONSE",
                scram_type    => "SERVER_FIRST_RESPONSE",
                rfc_str       => "<canned-first-matching-request-nonce>",
                user_info     => undef,
            };
        } else {
            return {
                response_type => "SCRAM_RESPONSE",
                scram_type    => "SERVER_FINAL_RESPONSE",
                rfc_str       => "v=<canned-verifier-base64>",
                user_info     => { ... },
            };
        }
    };
    # Use a deterministic nonce via a monkey-patched Crypt::URandom::urandom.
    lives_ok { TrueNAS::Broker::_do_t1_login({}, "alice", "17-abcdef...") };
    is scalar(@seen), 2, "two scram steps";
};

subtest '_do_t1_login server-signature mismatch' => sub {
    local *TrueNAS::Broker::ws_rpc = sub {
        return $_[1]{params}[0]{scram_type} eq "CLIENT_FIRST_MESSAGE"
            ? { response_type => "SCRAM_RESPONSE", scram_type => "SERVER_FIRST_RESPONSE", rfc_str => "<canned-first>" }
            : { response_type => "SCRAM_RESPONSE", scram_type => "SERVER_FINAL_RESPONSE", rfc_str => "v=".MIME::Base64::encode_base64("x" x 64, "") };
    };
    eval { TrueNAS::Broker::_do_t1_login({}, "alice", "17-abcdef...") };
    like $@, qr/SCRAM auth failed: server signature verification/, "bad v= dies";
};

subtest '_do_t1_login SCRAM-unsupported' => sub {
    local *TrueNAS::Broker::ws_rpc = sub { die "EINVAL: login_data: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags\n" };
    eval { TrueNAS::Broker::_do_t1_login({}, "alice", "17-abc") };
    like $@, qr/SCRAM unsupported by server/, "classifies as unsupported";
};
```

- [ ] **Step 2: Run, confirm fail**

Expected: `_do_t1_login` undefined.

- [ ] **Step 3: Implement `_do_t1_login` and `_is_scram_unsupported_error`**

Pipeline:
1. `scram_split_api_key($api_key)` → `($key_id, $secret)`.
2. `scram_client_first($username, $key_id)` → `($state, $wire)`.
3. `ws_rpc(scram_type => "CLIENT_FIRST_MESSAGE", rfc_str => $wire)`; on die → classify via `_is_scram_unsupported_error`, die with a tagged message.
4. Validate server response envelope (`response_type == "SCRAM_RESPONSE"`, `scram_type == "SERVER_FIRST_RESPONSE"`).
5. `scram_process_server_first($state, $resp->{rfc_str}, $secret)`.
6. `scram_client_final($state)` → wire.
7. `ws_rpc(scram_type => "CLIENT_FINAL_MESSAGE", rfc_str => $wire)`; validate `scram_type == "SERVER_FINAL_RESPONSE"`.
8. `scram_verify_server_final($state, $resp->{rfc_str})`.

Scrub `$secret` and `$state->{saltedPassword}` after step 8 (`$secret = "x" x length($secret)`).

- [ ] **Step 4: Run, confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t
git commit -m "broker: add T1 login (SCRAM-SHA-512 via auth.login_ex)

Drives the three-step SCRAM exchange, verifies the server signature
locally (mutual auth), and surfaces hard errors with distinct messages:
MITM/signature mismatch, malformed server-first, SCRAM-unsupported
(TN 25.10 rejection text). Scrubs the API key secret and SaltedPassword
after derivation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Mechanism selection + ws_open wiring + pool-key extension

**Files:**
- Modify: `tools/truenas-plugin-broker`
- Create: `t/scram/03-pool-key.t`
- Modify: `t/scram/02-broker-tiers.t`

**Interfaces:**
- Consumes: `_do_t1_login`, `_do_t2_login`, `_do_t3_login`, `_is_rate_limited`, `_is_scram_unsupported_error` from prior tasks.
- Produces:
  - `_select_mechanism($username:str|undef, $mech:str, $probe_result:ArrayRef|undef, $probe_err:str|undef) → "T1"|"T2"|"T3"|die` — pure function.
  - `scfg_key($scfg)` rewritten per design lines 338–343: `host + sha1(api_key . "|" . username . "|" . mechanism)`.
  - `ws_open($scfg)` updated to call `_select_mechanism` and dispatch to the chosen tier helper.

- [ ] **Step 1: Add failing tests — pool key**

```perl
# t/scram/03-pool-key.t
use Test::More;
require "./tools/truenas-plugin-broker";

my $k1 = TrueNAS::Broker::scfg_key({ api_host=>"h", api_key=>"17-abc" });
my $k2 = TrueNAS::Broker::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice" });
my $k3 = TrueNAS::Broker::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice", auth_mechanism=>"scram" });
my $k4 = TrueNAS::Broker::scfg_key({ api_host=>"h", api_key=>"17-abc", api_username=>"alice", auth_mechanism=>"auto" });

isnt $k1, $k2, "unset vs set username → distinct";
isnt $k2, $k3, "auto vs scram → distinct";
is   $k2, $k4, "missing auth_mechanism defaults to auto";

done_testing;
```

- [ ] **Step 2: Add failing selection tests**

```perl
# append to t/scram/02-broker-tiers.t
subtest '_select_mechanism' => sub {
    is TrueNAS::Broker::_select_mechanism("alice", "auto", ["SCRAM","API_KEY_PLAIN"], undef), "T1";
    is TrueNAS::Broker::_select_mechanism("alice", "auto", ["API_KEY_PLAIN"], undef), "T2";
    is TrueNAS::Broker::_select_mechanism(undef,   "auto", ["API_KEY_PLAIN"], undef), "T3", "no username → T3 even on new TN";
    is TrueNAS::Broker::_select_mechanism("alice", "auto", undef, "Method 'auth.mechanism_choices' not found"), "T3";
    is TrueNAS::Broker::_select_mechanism("alice", "auto", undef, "Rate Limit Exceeded"), "T1", "rate-limited probe + username → attempt T1";
    is TrueNAS::Broker::_select_mechanism(undef,   "auto", undef, "Rate Limit Exceeded"), "T3", "rate-limited probe, no user → T3 (floor)";
    is TrueNAS::Broker::_select_mechanism("alice", "plain", ["SCRAM"], undef), "T2", "plain never picks SCRAM";
    is TrueNAS::Broker::_select_mechanism("alice", "plain", undef, "method not found"), "T3";

    eval { TrueNAS::Broker::_select_mechanism(undef, "scram", ["SCRAM"], undef) };
    like $@, qr/tn_auth_mechanism=scram requires tn_api_username/, "scram without username → die";
    eval { TrueNAS::Broker::_select_mechanism("alice", "scram", ["API_KEY_PLAIN"], undef) };
    like $@, qr/server does not support SCRAM/, "scram-forced on no-SCRAM server → die";
    eval { TrueNAS::Broker::_select_mechanism("alice", "scram", undef, "method not found") };
    like $@, qr/server does not support SCRAM/, "scram-forced on pre-login_ex → die";
};
```

- [ ] **Step 3: Run, confirm fail**

Expected: FAIL — `_select_mechanism` / updated `scfg_key` undefined.

- [ ] **Step 4: Implement `_select_mechanism`, rewrite `scfg_key`, rewrite `ws_open`'s auth block**

`_select_mechanism` is a pure dispatcher — no `ws_rpc` calls inside; it only reads the probe outcome. `ws_open` now:
1. Opens the WS (unchanged).
2. Calls `ws_rpc` for `auth.mechanism_choices` wrapped in `eval`.
3. Classifies the probe outcome (list / error-type-via-`_is_rate_limited`).
4. Calls `_select_mechanism` to get tier.
5. Dispatches to `_do_t1_login` / `_do_t2_login` / `_do_t3_login`.
6. On a SCRAM-unsupported fallback inside `auto` (T1 died with `_is_scram_unsupported_error($@)` true), re-dispatch to T2 (if `tn_api_username` set) or T3 (if not); on any other T1 failure die.
7. Logs the chosen tier via `linfo` and any fallback via `lwarn` using the broker's existing pattern.

- [ ] **Step 5: Run tests, confirm pass**

Run: `prove -v t/scram/02-broker-tiers.t t/scram/03-pool-key.t`
Expected: PASS.

- [ ] **Step 6: Perl -c + deploy-smoke on pve**

```bash
scp tools/truenas-plugin-broker root@pve:/tmp/broker.check
ssh root@pve 'perl -c /tmp/broker.check'
```

Expected: syntax OK.

- [ ] **Step 7: Commit**

```bash
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t t/scram/03-pool-key.t
git commit -m "broker: tier selection + ws_open rewrite + pool-key extension

Replaces the single auth.login_with_api_key call in ws_open with a probe
(auth.mechanism_choices) + _select_mechanism + dispatch to one of
_do_t1_login / _do_t2_login / _do_t3_login. Pool key now hashes
(api_key, username, mechanism) so two storages that share host+key but
differ on username or mechanism get distinct connections. No fail-open
across tiers.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: Plugin wire extension + storage.cfg schema

**Files:**
- Modify: `TrueNASPlugin.pm` — `properties` hash (~line 700s), `check_config` validator (~line 1157), `_broker_rpc` scfg block (~line 1512).
- Create: `t/scram/04-plugin-wire.t`

**Interfaces:**
- Produces:
  - Two new scfg schema entries: `tn_api_username` (string, optional), `tn_auth_mechanism` (string, optional, enum `['auto','scram','plain']`, default `'auto'`).
  - `_broker_rpc` envelope widened with `api_username` + `auth_mechanism` keys.
  - `check_config` refuses `tn_auth_mechanism=scram` without `tn_api_username`; refuses `tn_api_username` containing `:`.

- [ ] **Step 1: Write failing tests**

```perl
# t/scram/04-plugin-wire.t
use Test::More;
use PVE::Storage::Custom::TrueNASPlugin;
my $plugin = 'PVE::Storage::Custom::TrueNASPlugin';

subtest 'schema accepts new fields' => sub {
    my $props = $plugin->properties;
    ok exists $props->{tn_api_username};
    ok exists $props->{tn_auth_mechanism};
    is_deeply $props->{tn_auth_mechanism}{enum}, ['auto','scram','plain'];
    is $props->{tn_auth_mechanism}{default}, 'auto';
};

subtest 'check_config refuses invalid combos' => sub {
    eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_auth_mechanism=>'scram',  # no tn_api_username
        }, 1, 0);
    };
    like $@, qr/tn_auth_mechanism=scram requires tn_api_username/;

    eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_api_username=>'alice:bad',
        }, 1, 0);
    };
    like $@, qr/tn_api_username must not contain ':'/;
};

subtest '_broker_rpc envelope carries new fields' => sub {
    # Monkey-patch the socket write to capture the envelope JSON.
    my $captured;
    no warnings 'redefine';
    local *PVE::Storage::Custom::TrueNASPlugin::_broker_write_payload = sub { $captured = $_[1]; die "mocked\n" };
    eval {
        PVE::Storage::Custom::TrueNASPlugin::_broker_rpc(
            { scfg => { tn_api_host=>'h', tn_api_key=>'17-abc', tn_api_username=>'alice', tn_auth_mechanism=>'scram' } },
            { method => 'core.ping', params => [] },
        );
    };
    my $json = JSON::PP::decode_json($captured);
    is $json->{scfg}{api_username},   'alice';
    is $json->{scfg}{auth_mechanism}, 'scram';
};

done_testing;
```

(The `_broker_write_payload` helper doesn't exist today; the current `_broker_rpc` serializes inline. To make the envelope testable, Task 6 also extracts the single `encode_json($req) . "\n"` + socket write into a one-line helper. If a different test seam suits the implementer better, use it — the point is that the envelope's `api_username` and `auth_mechanism` keys are checked.)

- [ ] **Step 2: Run, confirm fail**

Expected: FAIL — unknown property / missing validator / missing envelope keys.

- [ ] **Step 3: Implement schema + validator + envelope extension**

Add to `properties`:

```perl
tn_api_username => {
    description => "TrueNAS account that owns the API key. Required to enable SCRAM-SHA-512 authentication; the plugin falls back to legacy plain login when absent.",
    type => 'string', optional => 1,
    format_description => 'account',
},
tn_auth_mechanism => {
    description => "API-key authentication mechanism. 'auto' (default) prefers SCRAM when the server offers it, falling back to plain. 'scram' refuses to connect to servers that cannot do SCRAM-SHA-512. 'plain' never attempts SCRAM.",
    type => 'string', optional => 1,
    enum => ['auto','scram','plain'],
    default => 'auto',
},
```

In `check_config` (same spot where other cross-field warnings live, ~line 1187), add the two refusals.

In `_broker_rpc` (line 1512 area), add the two keys to the `scfg =>` hash.

- [ ] **Step 4: Run tests, confirm pass**

Run: `prove -v t/scram/04-plugin-wire.t`
Expected: PASS.

- [ ] **Step 5: `perl -c` on pve node**

```bash
scp TrueNASPlugin.pm root@pve:/tmp/TrueNASPlugin.pm.check
ssh root@pve 'perl -c /tmp/TrueNASPlugin.pm.check'
```

Expected: syntax OK.

- [ ] **Step 6: Commit**

```bash
git add TrueNASPlugin.pm t/scram/04-plugin-wire.t
git commit -m "plugin: add tn_api_username + tn_auth_mechanism, widen broker wire

Two new optional storage.cfg fields that drive the broker's SCRAM path:
tn_api_username (required for SCRAM, falls back to legacy plain when
absent) and tn_auth_mechanism (auto|scram|plain, default auto). The
plugin-to-broker envelope now carries both. check_config refuses
tn_auth_mechanism=scram without tn_api_username, and tn_api_username
containing ':' (which would corrupt the SCRAM username field).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Debian packaging, docs, live integration, cluster validation

**Files:**
- Modify: `debian/control`
- Modify: `wiki/Configuration.md` (or the plugin's existing POD if the configuration knobs are documented inline — follow the repo's current pattern)
- Create: `t/scram/05-live.t`

**Interfaces:**
- Consumes: everything from Tasks 1–6 integrated.
- Produces: a shippable `.deb` whose `Depends` carries the new runtime packages; documentation that names the two new scfg fields and the three mechanism values; a live integration test gated on `SCRAM_TEST_*` env vars.

- [ ] **Step 1: Extend `debian/control` Depends**

Add `libcrypt-pbkdf2-perl`, `libcrypt-urandom-perl` to the `Depends` line. Verify neither package pulls transitive deps that violate PVE 8 / bookworm support.

- [ ] **Step 2: Document the new fields**

Write a short section (under 300 words) covering: when to set `tn_api_username`; what each `tn_auth_mechanism` value does; the TN version matrix (24.10, 25.04, 25.10, 26.0+); the one-shot config example for a SCRAM-first storage entry. Match the existing wiki tone.

- [ ] **Step 3: Build the .deb and verify Depends resolves**

```bash
dpkg-buildpackage -us -uc -b
dpkg-deb -I ../truenas-proxmox-plugin_*.deb | grep -E '^ Depends:'
```

Expected: output includes `libcrypt-pbkdf2-perl` and `libcrypt-urandom-perl`.

- [ ] **Step 4: Install on pve and run the full cluster test cycle**

```bash
scp ../truenas-proxmox-plugin_*.deb root@pve:/root/
ssh root@pve 'dpkg -i /root/truenas-proxmox-plugin_*.deb && systemctl restart pvedaemon pvestatd pvescheduler truenas-plugin-broker && dpkg -s truenas-proxmox-plugin | awk "/^Version:/"'
```

Expected: broker restarts cleanly; version matches the just-built package.

- [ ] **Step 5: Write the live integration test**

```perl
# t/scram/05-live.t
use Test::More;
plan skip_all => "set SCRAM_TEST_HOST / SCRAM_TEST_USER / SCRAM_TEST_KEY to run"
    unless $ENV{SCRAM_TEST_HOST} && $ENV{SCRAM_TEST_USER} && $ENV{SCRAM_TEST_KEY};

# Three scenarios, selected by SCRAM_TEST_MODE:
#   T1 — expect SCRAM success against a TN 26+ host; verifies auth.me works post-auth.
#   T2 — set tn_auth_mechanism=plain; expect API_KEY_PLAIN via auth.login_ex.
#   T3 — point at a TN 24.10/25.04 host; expect auth.login_with_api_key.
# For each: open a direct WS using TRUENAS_PLUGIN_ALLOW_DIRECT_WS, drive
# the plugin's authentication path, and call auth.me.
...
done_testing;
```

Run against our cluster targets:
- `.68` (25.10, no SCRAM) with `tn_api_username=root` → expect T2.
- `.70` (26.0 MASTER, SCRAM-capable) with `tn_api_username=root` → expect T1.
- `.68` with no `tn_api_username` → expect T3.

```bash
SCRAM_TEST_HOST=192.168.1.70 SCRAM_TEST_USER=root SCRAM_TEST_KEY=... SCRAM_TEST_MODE=T1 prove -v t/scram/05-live.t
SCRAM_TEST_HOST=192.168.1.68 SCRAM_TEST_USER=root SCRAM_TEST_KEY=... SCRAM_TEST_MODE=T2 prove -v t/scram/05-live.t
SCRAM_TEST_HOST=192.168.1.68                       SCRAM_TEST_KEY=... SCRAM_TEST_MODE=T3 prove -v t/scram/05-live.t
```

Expected: PASS on each.

- [ ] **Step 6: Run the dev full-function test with `tn_auth_mechanism=scram`**

Edit `/etc/pve/storage.cfg` on pve to add `tn_api_username root` and `tn_auth_mechanism scram` to the `truenas-storage` entry targeting `.70` (requires standing up a .70-backed storage if we don't already have one). Then:

```bash
ssh root@pve 'bash /root/dev-truenas-plugin-full-function-test.sh truenas-storage-scram 20300'
```

Expected: all 45 phases PASS. If any phase fails, that's the regression surface — fix forward or roll the SCRAM path back on that entry.

- [ ] **Step 7: Run lifecycle-tests run-all against `.183` (pvevm1)**

```bash
ssh root@pve 'bash /root/lifecycle-tests/run-all.sh --node 192.168.1.183 --storage truenas-storage --vmid-start 10100 --deb-path /root/truenas-proxmox-plugin_*.deb'
```

Expected: 7 PASS + 1 SKIP (TN controller restart, as before — environmental).

- [ ] **Step 8: Rate-limit stress**

```bash
# Simultaneously restart the broker on all 4 nodes to force 16 near-synchronous auths
for ip in 192.168.1.154 192.168.1.140 192.168.1.73 192.168.1.183; do
    ssh root@$ip 'systemctl restart truenas-plugin-broker' &
done
wait
# Immediately check each broker log for 'rate limited' errors
for ip in 192.168.1.154 192.168.1.140 192.168.1.73 192.168.1.183; do
    ssh root@$ip 'journalctl -u truenas-plugin-broker --since "-2 min" | grep -c "rate limit"'
done
```

Expected: zero per node. 16 parallel auths cross four workers × four nodes, each hitting a different (host, key) tuple — well under TN's 20/60 bucket.

- [ ] **Step 9: Commit**

```bash
git add debian/control wiki/Configuration.md t/scram/05-live.t
git commit -m "scram: debian deps, docs, live integration test

Adds libcrypt-pbkdf2-perl and libcrypt-urandom-perl to Depends (both
present in bookworm and trixie, so PVE 8 support stays intact).
Documents tn_api_username and tn_auth_mechanism. Live integration test
is env-gated via SCRAM_TEST_HOST/USER/KEY so CI skips when no live
target is reachable.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 10: Tag + release**

Follow the project's existing release pattern (bump `$VERSION`, write a changelog entry, tag, push). This is a `~beta7` candidate since the SCRAM landing is a user-visible auth-path change.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task:

- Goals, Non-goals, Anti-goals → Global Constraints + Review Focus.
- New scfg fields (lines 112–138) → Task 6.
- Three auth tiers (lines 140–209) → Tasks 2 (T3), 3 (T2), 4 (T1).
- Mechanism-selection logic (211–249) → Task 5.
- Rate-limit discriminator (251–262) → Task 2.
- SCRAM crypto, pure Perl (264–294) → Task 1.
- Error semantics (296–313) → Task 1 (vector tests) + Task 4 (classification).
- Broker wire extension (315–334) → Task 6.
- Broker pool key (336–350) → Task 5.
- Debian packaging (352–362) → Task 7.
- Backward compat matrix (364–386) → Task 5 (selection) + Task 7 (live tests cover each row).
- "What's left to the builder" (388–410) → the lib/TrueNAS/SCRAM.pm choice is settled (Task 1 goes with the factored module); log-line format is called out in Task 5's step 4; unit vs live test placement is settled across Tasks 1 and 7.
- Validation plan (412–429) → Task 7 steps 5–8.

**Review Focus:** five rows, each tied to a task's tests.

**Type consistency.** `_do_t1_login` / `_do_t2_login` / `_do_t3_login` share the `($conn, ...)` signature. `_select_mechanism` returns the exact strings `"T1"` / `"T2"` / `"T3"` that `ws_open` dispatches on. `scfg_key` reads `api_username` + `auth_mechanism` out of the plugin-sent envelope — same keys the plugin's `_broker_rpc` writes in Task 6.

**Proportion.** Spec is ~440 lines; plan is ~500 lines of unique content (ignoring code blocks that fix the test values). Right range.

---

## Future work (NOT in this plan)

- **SCRAM-PLUS / channel binding (`tls-server-end-point`)** — explicitly a non-goal of the spec. Deployments that need to bind the SCRAM exchange to the TLS server cert (e.g. TN hardened with `channel_binding=require`) will require: (a) a new scfg knob to opt in (`tn_scram_channel_binding = tls-server-end-point|none`), (b) a GS2 header switch from `n,,` to `p=tls-server-end-point,,` + its base64 in the `c=` attribute, (c) peer-cert hash extraction from the IO::Socket::SSL handle, and (d) extended tests. Lands as its own spec + plan once the server-side policy is in use somewhere we're asked to support.
- **Derive username from the API key owner** — if TrueNAS adds a pre-auth method that returns the owner of an API key by its id, we could drop the `tn_api_username` requirement for T1/T2 and let `auto` upgrade untouched storage entries automatically. Depends on upstream capability.
- **Reconnect-token flow** — `AuthRespSuccess.reconnect_token` is currently ignored. A later change could use it to shortcut the 30-day re-auth with a single-use token instead of a full SCRAM re-handshake, lowering the PBKDF2 cost of liveness-triggered reconnects.
