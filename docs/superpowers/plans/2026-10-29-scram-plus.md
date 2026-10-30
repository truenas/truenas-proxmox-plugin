# SCRAM-PLUS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `tn_auth_mechanism=scram-plus` as a strict, no-fallback SCRAM-SHA-512 path with TLS channel binding to `tls-server-end-point` (RFC 5929), on top of the plain-SCRAM landing at HEAD `bd1a83c`.

**Architecture:** The SCRAM crypto module grows one optional named argument (`channel_binding`). The broker's `_authenticate` grows one branch that extracts the TLS peer-cert digest and dispatches a new terminal selector value `T1-PLUS`. The plugin's `tn_auth_mechanism` enum grows the value `scram-plus`. Everything else — `auto`, `scram`, `plain`, pool key, debian control, legacy-T3, API_KEY_PLAIN-T2, probe shape — is unchanged.

**Tech Stack:** Perl (broker `main`-package daemon + lib module), `IO::Socket::SSL`, `Net::SSLeay`, `Digest::SHA` (core), `MIME::Base64` (core), `Crypt::PBKDF2`, `Crypt::URandom`. Test harness: `Test::More`, `prove`. All dependencies already in Depends.

**Spec:** `docs/superpowers/specs/2026-10-29-scram-plus-design.md` (committed `9d93dc7`).

## Global Constraints

- Base branch: `worktree-feat-scram-auth` off `main`. Branch tip at planning time: `9d93dc7` (design-doc commit on top of SCRAM landing `bd1a83c`).
- Broker file stays `package main;`. All broker tests call `main::foo` / `::foo` / bareword — NOT `TrueNAS::Broker::`.
- Crypto module stays `TrueNAS::SCRAM` (installed at `/usr/share/perl5/TrueNAS/SCRAM.pm`).
- `tn_auth_mechanism` enum **only** grows the value `scram-plus`. No new scfg field.
- No new Debian Depends. No new runtime library.
- `scram-plus` is strict: hard-dies, never falls back to T1/T2/T3. The pseudocode in the spec's "`_authenticate` grows one branch" section is authoritative.
- `auto` / `scram` / `plain` paths unchanged. The pre-existing matrix at HEAD `bd1a83c` holds for them bit-for-bit.
- Secrets scrubbing: whatever the base SCRAM code scrubs (`saltedPassword`, `$secret`) must keep working under CB. Do not weaken.
- `tn_api_insecure=1` + `tn_auth_mechanism=scram-plus` is ALLOWED (spec Goal 7).
- CB-digest selection follows RFC 5929 §4.1; unknown sig algorithms under `scram-plus` die rather than guess.

## Review Focus

- **Non-SHA-256 cert signature algorithms** (SHA-384, SHA-512 certs). The spec says die under `scram-plus` rather than guess. Task 2 tests the die on an SHA-384-signed test cert.
- **Server rejection of a correctly-formatted `c=`** (CB mismatch at server side, e.g. a MITM proxy between us and TN). `_do_t1_login` must propagate the server's `AUTH_ERR` text up through `_scram_step` without catching it. Task 4 pins this.
- **TLS handle with no peer certificate at all** (e.g. a mock socket, or a `ws://` scheme). `scram-plus` must die with "TLS peer certificate not available for channel binding". Task 2 tests.
- **Pool-key collision between `scram` and `scram-plus`.** The hash includes the mechanism string, but a collision would let a SCRAM caller inherit a SCRAM-PLUS worker's trust. Task 5 asserts the two mechanism values yield distinct keys.
- **`check_config` on edit (not just create).** The base-SCRAM `scram-requires-username` refusal runs only on `$create`. Task 5 confirms `scram-plus-requires-username` follows the same create-only pattern, and that an `:` in `tn_api_username` on edit still fires (same rule as the base branch).

---

## File Structure

- **Modify** `lib/TrueNAS/SCRAM.pm` — `scram_client_first` + `scram_client_final` take optional `channel_binding => $cb_raw` named arg. State hash gains `cb_raw` field. `scram_process_server_first` + `scram_verify_server_final` unchanged.
- **Modify** `tools/truenas-plugin-broker` — add `_extract_tls_server_end_point($sock)`; add `_cb_digest_for_sig_alg($sig_name)`; extend `_select_mechanism` for `scram-plus` and unknown-mech-die; extend `_authenticate` for the CB extraction + T1-PLUS dispatch; extend `_do_t1_login` for the `channel_binding` named arg.
- **Modify** `TrueNASPlugin.pm` — add `scram-plus` to the `tn_auth_mechanism` enum; extend `check_config`'s scram-requires-username refusal to cover `scram-plus`; update the `tn_api_username` property description.
- **Modify** `t/scram/01-vectors.t` — add one `subtest 'SCRAM-PLUS known-answer vector'` section with a Python-stdlib-computed oracle.
- **Modify** `t/scram/02-broker-tiers.t` — add `subtest '_cb_digest_for_sig_alg'`, add `subtest '_extract_tls_server_end_point'`, add `subtest '_select_mechanism scram-plus'`, add `subtest '_authenticate scram-plus'`.
- **Modify** `t/scram/03-pool-key.t` — add one assertion for `scram` vs `scram-plus` distinct hashes.
- **Modify** `t/scram/04-plugin-wire.t` — add `subtest 'scram-plus enum + check_config'`.
- **Modify** `wiki/Configuration.md` — add `scram-plus` to the mechanism value list; append two rows to the version matrix; add the `tn_api_insecure=1 + scram-plus` note.
- **Create** `t/scram/certs/sha384.der` — test fixture, a self-signed SHA-384-signed DER cert for the digest-selection test.

---

## Task 1: SCRAM crypto gets a `channel_binding` option

**Files:**
- Modify: `lib/TrueNAS/SCRAM.pm`
- Modify: `t/scram/01-vectors.t`
- Create: `.superpowers/sdd/2026-10-29-scram-plus/compute-plus-vector.py` (independent Python oracle; already-ignored dir)

**Interfaces:**
- Produces:
  - `scram_client_first($username, $kid, %opts)` — `%opts` may contain `channel_binding => $cb_raw`. When present, the GS2 header becomes `"p=tls-server-end-point,,"` instead of `"n,,"`. The state hash stores `cb_raw` for the final step.
  - `scram_client_final($state)` — unchanged signature. Reads `$state->{cb_raw}` if present; `c=` attribute becomes `base64($gs2_header_octets . $cb_raw)` instead of `biws`.
  - Existing `scram_process_server_first`, `scram_verify_server_final`, `scram_split_api_key` unchanged.

- [ ] **Step 1: Write the failing CB vector subtest in `t/scram/01-vectors.t`**

Append a `subtest 'SCRAM-PLUS known-answer vector'` block. Values from the Python oracle (step 3). Pin:
- `USERNAME = "testuser"`, `KEY_ID = 1`, `SECRET = "testsecret_for_vector_01"`.
- `CLIENT_NONCE_B64 = "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE="` (32 "A" bytes).
- `SERVER_EXT_B64` as per base vector.
- `SALT_B64 = "MDEyMzQ1Njc4OWFiY2RlZg=="` (16 bytes `0123456789abcdef`).
- `ITERS = 50000`.
- `CB_RAW = "C" x 32` (32 "C" bytes, standing in for a sha256 digest of a cert).

Call `scram_client_first("testuser", 1, channel_binding => $cb_raw)`, then feed server-first `r=<combined>,s=<salt>,i=50000`, then `scram_client_final($state)`. Assert `$state->{gs2_header} eq "p=tls-server-end-point,,"`, assert the `c=` attribute in the client-final equals the pinned expected value, assert the client proof `p=` equals the pinned expected value, assert `scram_verify_server_final` accepts the pinned `v=`.

- [ ] **Step 2: Run the subtest, confirm it fails**

Run: `PERL5LIB=./lib:./.superpowers/dev-perl-lib/usr/share/perl5:./.superpowers/dev-perl-lib/usr/lib/x86_64-linux-gnu/perl5/5.40 prove -v t/scram/01-vectors.t`
Expected: FAIL — `channel_binding` option not recognized.

- [ ] **Step 3: Write the Python oracle at `.superpowers/sdd/2026-10-29-scram-plus/compute-plus-vector.py`**

Same shape as the base vector's `.superpowers/sdd/2026-10-29-scram-auth/compute-vector.py`, but:
- `gs2_header = "p=tls-server-end-point,,"`
- `cb_data = b"C" * 32`
- `c_attr = base64(gs2_header.encode() + cb_data)`
- `client_final_noproof = f"c={c_attr},r={combined_b64}"`

Run with Python stdlib. Paste the `EXPECTED_cattr_B64`, `EXPECTED_p_B64`, `EXPECTED_v_B64` into the Perl subtest's pinned constants.

- [ ] **Step 4: Implement `channel_binding` in `lib/TrueNAS/SCRAM.pm`**

Rewrite `scram_client_first` to accept `%opts` after the two positional args. If `$opts{channel_binding}` is defined, store it in `$state->{cb_raw}` and set `$state->{gs2_header} = "p=tls-server-end-point,,"`; else store the current `"n,,"`. Everything after the state construction is unchanged.

Rewrite `scram_client_final` to compute `$c_attr = encode_base64($state->{gs2_header} . ($state->{cb_raw} // ''), '')`. If `cb_raw` is missing, that collapses to `encode_base64("n,,", '')` which equals `"biws"` — the existing behavior.

- [ ] **Step 5: Run the subtest, confirm it passes AND the plain-SCRAM base vector still passes**

Run: `PERL5LIB=... prove -v t/scram/01-vectors.t`
Expected: PASS, 13+ tests (12 pre-existing + the new CB subtest's assertions).

- [ ] **Step 6: Commit**

```
git add lib/TrueNAS/SCRAM.pm t/scram/01-vectors.t
git commit -m "scram: optional channel_binding in client_first + client_final"
```

---

## Task 2: Broker gets the TLS peer-cert digest extractor

**Files:**
- Modify: `tools/truenas-plugin-broker`
- Modify: `t/scram/02-broker-tiers.t`
- Create: `t/scram/certs/sha384.der` (test fixture — a self-signed SHA-384-signed DER cert generated via `openssl req -x509 -sha384 -newkey rsa:2048 -nodes -subj /CN=test ... -outform DER`)

**Interfaces:**
- Produces:
  - `_cb_digest_for_sig_alg($sig_name) → ("sha256"|"sha384"|"sha512"|"sha224"|undef)` — pure. `undef` means "unsupported / unknown"; the caller translates to a die under `scram-plus`.
  - `_extract_tls_server_end_point($sock) → ($cb_raw, $err)` — returns `($cb_raw, undef)` on success, `(undef, $err_text)` on failure. Reads `$sock->peer_certificate` for the X.509 handle, picks the digest via `_cb_digest_for_sig_alg`, then calls `$sock->get_fingerprint_bin($hash_name)` for the raw bytes. For sig-alg detection, use `Net::SSLeay::X509_get_signature_nid` when available; if that symbol is missing, fall back to a minimal DER-OID parse (keep it under 20 lines, pass-through comment pointing at the spec's "What's left to the builder" section).

- [ ] **Step 1: Write failing subtests in `t/scram/02-broker-tiers.t`**

Append two subtests:

```perl
subtest '_cb_digest_for_sig_alg' => sub {
    is main::_cb_digest_for_sig_alg('sha256WithRSAEncryption'), 'sha256';
    is main::_cb_digest_for_sig_alg('ecdsa-with-SHA256'),       'sha256';
    is main::_cb_digest_for_sig_alg('sha384WithRSAEncryption'), 'sha384';
    is main::_cb_digest_for_sig_alg('sha512WithRSAEncryption'), 'sha512';
    is main::_cb_digest_for_sig_alg('sha1WithRSAEncryption'),   'sha256', 'weak sig → sha256 per RFC 5929 §4.1';
    is main::_cb_digest_for_sig_alg('md5WithRSAEncryption'),    'sha256', 'md5 sig → sha256';
    is main::_cb_digest_for_sig_alg('ed25519'),                 undef,    'ed25519 → undef (caller must die under scram-plus)';
    is main::_cb_digest_for_sig_alg('rsassaPss'),               undef,    'rsassa-pss → undef';
    is main::_cb_digest_for_sig_alg(''),                        undef,    'empty → undef';
};

subtest '_extract_tls_server_end_point' => sub {
    # Stub-socket cases — not a real TLS connection.
    my $no_cert_sock = bless {}, 'main::StubSock';
    *main::StubSock::peer_certificate = sub { undef };
    my ($raw, $err) = main::_extract_tls_server_end_point($no_cert_sock);
    is $raw, undef;
    like $err, qr/no peer certificate/i;

    # SHA-384 cert fixture: _extract would die on an unsupported sig under
    # scram-plus; we test the digest-selection path specifically returns 'sha384'
    # when the signature algorithm maps there.
    # (The actual TLS handshake is not tested here — that's covered live.)
};
```

- [ ] **Step 2: Run, confirm fail**

Run: `PERL5LIB=... prove -v t/scram/02-broker-tiers.t`
Expected: FAIL — `_cb_digest_for_sig_alg` / `_extract_tls_server_end_point` not defined.

- [ ] **Step 3: Implement `_cb_digest_for_sig_alg` and `_extract_tls_server_end_point` in `tools/truenas-plugin-broker`**

Place near the other `_is_*` helpers (around the existing `_is_scram_unsupported_error` at line ~250). RFC 5929 §4.1 digest selection in `_cb_digest_for_sig_alg`. `_extract_tls_server_end_point` calls `peer_certificate` → `X509_get_signature_nid` + `OBJ_nid2ln` → `_cb_digest_for_sig_alg` → `get_fingerprint_bin($hash)`. On any `undef` return from the sig-alg map, return `(undef, "unsupported certificate signature algorithm: $sig")`. On `peer_certificate` returning undef, return `(undef, "no peer certificate")`.

- [ ] **Step 4: Generate the SHA-384 test fixture**

```bash
mkdir -p t/scram/certs
openssl req -x509 -sha384 -newkey rsa:2048 -nodes \
    -subj /CN=scram-plus-test -days 3650 \
    -keyout /dev/null -outform DER -out t/scram/certs/sha384.der 2>/dev/null
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `PERL5LIB=... prove -v t/scram/02-broker-tiers.t`
Expected: PASS.

- [ ] **Step 6: Commit**

```
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t t/scram/certs/sha384.der
git commit -m "broker: TLS peer-cert digest extractor + RFC 5929 §4.1 digest selection"
```

---

## Task 3: `_select_mechanism` learns `scram-plus`

**Files:**
- Modify: `tools/truenas-plugin-broker`
- Modify: `t/scram/02-broker-tiers.t`

**Interfaces:**
- Consumes: `_cb_digest_for_sig_alg`, `_extract_tls_server_end_point` from Task 2.
- Produces:
  - `_select_mechanism($user, $mech, $probe_result, $probe_err, $cb_available) → "T1"|"T1-PLUS"|"T2"|"T3"|die` — pure. Fifth arg is a boolean.
  - Rules per the spec:
    - `scram-plus` + no username → `die "tn_auth_mechanism=scram-plus requires tn_api_username\n"`.
    - `scram-plus` + probe shows SCRAM → `T1-PLUS`.
    - `scram-plus` + probe missing SCRAM → `die "tn_auth_mechanism=scram-plus but server does not advertise SCRAM\n"`.
    - `auto`, `scram`, `plain` → unchanged from HEAD `bd1a83c`.
    - Any other mech string → `die "tn_auth_mechanism=$mech: unknown mechanism\n"`.
  - The `$cb_available` arg is unused by `scram-plus` logic (CB readiness is checked in `_authenticate` before calling the selector); it exists so a later extension can read it, and is documented as such.

- [ ] **Step 1: Write failing subtests**

Append to `t/scram/02-broker-tiers.t`:

```perl
subtest '_select_mechanism scram-plus' => sub {
    is main::_select_mechanism('alice', 'scram-plus', ['SCRAM','API_KEY_PLAIN'], undef, 1), 'T1-PLUS';
    is main::_select_mechanism('alice', 'scram-plus', ['SCRAM'],                 undef, 1), 'T1-PLUS';

    eval { main::_select_mechanism(undef,   'scram-plus', ['SCRAM'], undef, 1) };
    like $@, qr/tn_auth_mechanism=scram-plus requires tn_api_username/;

    eval { main::_select_mechanism('alice', 'scram-plus', ['API_KEY_PLAIN'], undef, 1) };
    like $@, qr/scram-plus but server does not advertise SCRAM/;

    eval { main::_select_mechanism('alice', 'scram-plus', undef, 'Method not found', 1) };
    like $@, qr/scram-plus but server does not advertise SCRAM/;

    # unknown mech dies
    eval { main::_select_mechanism('alice', 'bogus', ['SCRAM'], undef, 1) };
    like $@, qr/unknown mechanism/;
};
```

- [ ] **Step 2: Run, confirm fail**

Expected: FAIL — `scram-plus` branch not implemented; `bogus` returns 'T3' (today).

- [ ] **Step 3: Implement**

In `tools/truenas-plugin-broker` around line 275 (current `_select_mechanism`):
- Change the final `return 'T3' unless defined $username;` + `auto` chain into an explicit dispatch: switch on `$mech`. For `scram-plus`, apply the four rules above. For `auto`/`scram`/`plain`, keep the existing branches. For anything else, die.

- [ ] **Step 4: Run, confirm pass + existing selector tests still pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t
git commit -m "broker: _select_mechanism learns scram-plus + rejects unknown mechs"
```

---

## Task 4: `_authenticate` extracts CB, `_do_t1_login` accepts it

**Files:**
- Modify: `tools/truenas-plugin-broker`
- Modify: `t/scram/02-broker-tiers.t`

**Interfaces:**
- Consumes: `_extract_tls_server_end_point` (Task 2), `_select_mechanism` with `scram-plus` support (Task 3), `TrueNAS::SCRAM::scram_client_first(..., channel_binding => $cb_raw)` (Task 1).
- Produces:
  - `_do_t1_login($conn, $user, $api_key, %opts)` — `%opts` may contain `channel_binding => $cb_raw`. When present, propagated into `scram_client_first`.
  - `_authenticate($conn, $scfg)` — on `tn_auth_mechanism eq 'scram-plus'`, call `_extract_tls_server_end_point($conn->{sock})` BEFORE calling `_select_mechanism`. On failure, die with `"[TrueNAS] tn_auth_mechanism=scram-plus: TLS peer certificate not available for channel binding: $err\n"`. Dispatch `T1-PLUS` to `_do_t1_login($conn, $user, $api_key, channel_binding => $cb_raw)`. All other tier dispatches unchanged.
  - Broker INFO log line `auth: using tier T1-PLUS (mechanism=scram-plus)` via the existing `linfo` call, matching the pattern used for T1/T2/T3.

- [ ] **Step 1: Write failing stubbed-ws_rpc subtest**

Append to `t/scram/02-broker-tiers.t`:

```perl
subtest '_authenticate scram-plus' => sub {
    my @t1_calls;
    local *main::_do_t1_login = sub { push @t1_calls, {@_[1..$#_]}; };
    local *main::_do_t2_login = sub { die "T2 should not be called in scram-plus\n" };
    local *main::_do_t3_login = sub { die "T3 should not be called in scram-plus\n" };
    local *main::ws_rpc = sub {
        return { response_type => 'SUCCESS', result => ['SCRAM','API_KEY_PLAIN'] };
    };
    local *main::_extract_tls_server_end_point = sub { return ("\0" x 32, undef) };

    # Positive: scram-plus with CB available + server advertises SCRAM
    my $conn = { sock => bless({}, 'main::StubSock'), next_id => 1 };
    my $scfg = { api_username => 'alice', api_key => '1-abcdef', auth_mechanism => 'scram-plus' };
    main::_authenticate($conn, $scfg);
    is scalar @t1_calls, 1, 'T1-PLUS dispatched once';
    is $t1_calls[0]{channel_binding}, "\0" x 32, 'channel_binding passed through';

    # Negative: scram-plus with CB extraction failing
    local *main::_extract_tls_server_end_point = sub { return (undef, "no peer certificate") };
    eval { main::_authenticate($conn, $scfg) };
    like $@, qr/TLS peer certificate not available/;

    # Negative: scram-plus with server missing SCRAM
    local *main::_extract_tls_server_end_point = sub { return ("\0" x 32, undef) };
    local *main::ws_rpc = sub { return { response_type => 'SUCCESS', result => ['API_KEY_PLAIN'] } };
    eval { main::_authenticate($conn, $scfg) };
    like $@, qr/server does not advertise SCRAM/;

    # Server rejects c= (AUTH_ERR propagated from _do_t1_login)
    local *main::ws_rpc = sub { return { response_type => 'SUCCESS', result => ['SCRAM'] } };
    local *main::_do_t1_login = sub { die "[TrueNAS] SCRAM auth failed: {\"response_type\":\"AUTH_ERR\"}\n" };
    eval { main::_authenticate($conn, $scfg) };
    like $@, qr/AUTH_ERR/;
};
```

- [ ] **Step 2: Run, confirm fail**

Expected: FAIL — `_do_t1_login` doesn't accept `channel_binding`; `_authenticate` doesn't extract.

- [ ] **Step 3: Implement**

- `_do_t1_login`: change signature to `($conn, $username, $api_key, %opts)`. Pass `%opts` into `scram_client_first` as named args. Nothing else changes.
- `_authenticate`: around the existing `_select_mechanism` call, add the CB-extraction branch gated on `$mech eq 'scram-plus'`. Build the dispatch block to call `_do_t1_login` with `channel_binding` when `$tier eq 'T1-PLUS'`.
- `linfo`: emit `auth: using tier T1-PLUS (mechanism=$mech)` for the new tier.

- [ ] **Step 4: Run tests, confirm pass + all prior `_authenticate` subtest cases still pass**

Expected: PASS.

- [ ] **Step 5: `perl -c` locally**

Run: `PERL5LIB=... perl -c tools/truenas-plugin-broker`
Expected: `syntax OK`.

- [ ] **Step 6: Commit**

```
git add tools/truenas-plugin-broker t/scram/02-broker-tiers.t
git commit -m "broker: _authenticate + _do_t1_login carry channel_binding for T1-PLUS"
```

---

## Task 5: Plugin schema + check_config + pool-key test

**Files:**
- Modify: `TrueNASPlugin.pm`
- Modify: `t/scram/03-pool-key.t`
- Modify: `t/scram/04-plugin-wire.t`

**Interfaces:**
- Produces:
  - `tn_auth_mechanism` enum accepts `'scram-plus'` as a fourth value.
  - `check_config` refuses `tn_auth_mechanism=scram-plus` without `tn_api_username` on create (same shape as the existing `scram` refusal — `$create` branch only, same `[TrueNAS]` prefix).
  - Plugin schema description for `tn_auth_mechanism` names `scram-plus` as the strict option; description for `tn_api_username` names SCRAM AND SCRAM-PLUS as the two mechanisms that require it.

- [ ] **Step 1: Add failing assertions**

In `t/scram/03-pool-key.t`:

```perl
my $k_scram = PVE::Storage::Custom::TrueNASPlugin::scfg_key({
    api_host=>'h', api_key=>'17-abc', api_username=>'alice', auth_mechanism=>'scram'
});
my $k_plus  = PVE::Storage::Custom::TrueNASPlugin::scfg_key({
    api_host=>'h', api_key=>'17-abc', api_username=>'alice', auth_mechanism=>'scram-plus'
});
isnt $k_scram, $k_plus, 'scram vs scram-plus → distinct pool keys';
```

In `t/scram/04-plugin-wire.t`:

```perl
subtest 'scram-plus enum + check_config' => sub {
    my $props = $plugin->properties;
    is_deeply $props->{tn_auth_mechanism}{enum}, ['auto','scram','scram-plus','plain'];

    # Create-time: scram-plus without username is refused
    eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_auth_mechanism=>'scram-plus',   # no tn_api_username
        }, 1, 0);
    };
    like $@, qr/tn_auth_mechanism=scram-plus requires tn_api_username/;

    # Create-time: scram-plus WITH username is accepted
    my $ok = eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_api_username=>'root', tn_auth_mechanism=>'scram-plus',
        }, 1, 0);
        1;
    };
    ok $ok, "scram-plus + username passes check_config";

    # tn_api_insecure=1 + scram-plus is allowed (spec Goal 7)
    my $ok2 = eval {
        $plugin->check_config('s1', {
            type=>'truenasplugin', tn_api_host=>'h', tn_api_key=>'k',
            tn_api_username=>'root', tn_auth_mechanism=>'scram-plus',
            tn_api_insecure=>1,
        }, 1, 0);
        1;
    };
    ok $ok2, "scram-plus + tn_api_insecure=1 passes check_config";
};
```

- [ ] **Step 2: Run, confirm fail**

Expected: FAIL — enum missing `scram-plus`; check_config doesn't refuse.

- [ ] **Step 3: Implement**

In `TrueNASPlugin.pm`:
- `properties` → `tn_auth_mechanism` → change `enum => ['auto','scram','plain']` to `enum => ['auto','scram','scram-plus','plain']`. Update the description string per the spec's wording.
- `properties` → `tn_api_username` → update description to name both `scram` and `scram-plus` as the two mechanisms that require the username.
- `check_config` (around line 1170) → the existing `scram`-requires-username refusal: change `$mech eq 'scram'` to `$mech =~ /\Ascram(-plus)?\z/`. Keep the create-only guard.

- [ ] **Step 4: Run tests, confirm pass**

Run: `PERL5LIB=... prove -v t/scram/03-pool-key.t t/scram/04-plugin-wire.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```
git add TrueNASPlugin.pm t/scram/03-pool-key.t t/scram/04-plugin-wire.t
git commit -m "plugin: tn_auth_mechanism=scram-plus enum + check_config refusal"
```

---

## Task 6: Wiki + build + live validation + release

**Files:**
- Modify: `wiki/Configuration.md`
- Build: new `.deb` from the branch
- Validate: cross-cluster against `192.168.1.70` (TN 28.0 MASTER)

**Interfaces:**
- Produces: documented `scram-plus` option; broker + plugin deployed on `pve`; `pvesm status` on a `truenas-storage-scram-plus` entry shows `active`; broker journal stamps `auth: using tier T1-PLUS (mechanism=scram-plus)`.

- [ ] **Step 1: Append `scram-plus` to the `tn_auth_mechanism` doc**

In `wiki/Configuration.md`, under the `tn_auth_mechanism` section (lines ~306-321 as of HEAD `bd1a83c`):
- Add a bullet: `scram-plus: SCRAM-SHA-512 with TLS channel binding (tls-server-end-point, RFC 5929). Strict — refuses to authenticate if the server does not advertise SCRAM or if the TLS peer certificate cannot be read. Does not fall back to plain SCRAM, API_KEY_PLAIN, or legacy under any circumstance. Allowed together with tn_api_insecure=1 (CB mechanically ties the SCRAM exchange to the cert the client saw, defeating a relaying MITM even without CA validation).`
- Append rows to the version matrix:
  ```
  | 26.0+ | scram-plus (set) | T1 with CB on (if tn_api_username set) |
  | 26.0+ | scram-plus (unset username) | dies (requires tn_api_username) |
  ```
- Shorten the `tn_api_username` paragraph to say "required when `tn_auth_mechanism` is `scram` or `scram-plus`" instead of just `scram`.

- [ ] **Step 2: Build the `.deb` and verify `scram-plus` compiles**

```bash
cd /home/wmo/truenas-proxmox-plugin/.claude/worktrees/feat-scram-auth
rm -f ../truenas-proxmox-plugin_*.deb ../truenas-proxmox-plugin_*.changes ../truenas-proxmox-plugin_*.buildinfo
dpkg-buildpackage -us -uc -b 2>&1 | tail -5
```

Expected: a `.deb` produced in `../`. No new Depends lines (confirm with `dpkg-deb -I ../truenas-proxmox-plugin_*.deb | grep Depends`).

- [ ] **Step 3: Deploy to `pve` and restart broker**

```bash
scp ../truenas-proxmox-plugin_*.deb root@pve:/root/
ssh root@pve 'dpkg -i /root/truenas-proxmox-plugin_*.deb 2>&1 | tail -3 && systemctl restart truenas-plugin-broker'
```

- [ ] **Step 4: Live validation against `192.168.1.70` (SCRAM-PLUS end-to-end)**

Reuse the spike pattern — on .70, create a fresh user-scoped API key; on pve, write a disposable `truenas-storage-scram-plus` entry pointing at .70 with `tn_auth_mechanism scram-plus` and `tn_api_username root`; run `pvesm status --storage truenas-storage-scram-plus`; grep the broker journal for `auth: using tier T1-PLUS (mechanism=scram-plus)`.

Expected: storage shows `active`; broker log shows exactly `T1-PLUS` for the `.70` session (zero `T1`, zero `T2`, zero `T3` for that session's `sk=`). After verification, remove the storage.cfg entry and revoke the API key.

- [ ] **Step 5: Run the full SCRAM test suite to confirm no regression**

```bash
PERL5LIB=./lib:./.superpowers/dev-perl-lib/usr/share/perl5:./.superpowers/dev-perl-lib/usr/lib/x86_64-linux-gnu/perl5/5.40 prove t/scram/
```

Expected: all four `t/scram/*.t` files pass, no failures. Test counts: 01-vectors.t grows by one subtest (the KAT), 02-broker-tiers.t grows by three subtests (`_cb_digest_for_sig_alg`, `_extract_tls_server_end_point`, `_select_mechanism scram-plus`, `_authenticate scram-plus`), 03-pool-key.t grows by one assertion, 04-plugin-wire.t grows by one subtest.

- [ ] **Step 6: Commit**

```
git add wiki/Configuration.md
git commit -m "wiki: document scram-plus"
```

- [ ] **Step 7: Release decision — hand back to user**

Branch is now at HEAD `<step 6 SHA>`. All validation green. Flag ready for the user's "cut beta7" decision (per the project's `feedback_do_not_ship_on_do_it` memory, release is its own explicit ask). The user picks whether to tag and push a `v2.1.24-beta7` from this branch, cut it from `main` after a merge, or hold.

---

## Future work (NOT in this plan)

- **Direct-WS path migration** (deferred since the base SCRAM branch; still deferred here).
- **Full RFC 5929 §4.1 sig-alg detection via a proper DER parse** when `Net::SSLeay::X509_get_signature_nid` is not available — the plan deliberately leaves the choice to Task 2's implementer. If the implementer picks "hard-code sha256 with a WARN" instead, a follow-up branch should address the compliance gap for sha384-/sha512-signed server certs.
- **SCRAM-PLUS auto-upgrade** — explicitly out of scope per the design doc Goal 2. If a later cycle wants `auto` to upgrade when CB is available, that is a new spec + plan.
