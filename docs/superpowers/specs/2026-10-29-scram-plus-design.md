# SCRAM-PLUS (channel binding to `tls-server-end-point`) design

**Status:** draft, approved for planning (approved verbally during brainstorming).
**Author:** Bill O'Hanlon <bill.ohanlon@truenas.com>
**Supersedes nothing.** Builds on `docs/superpowers/specs/2026-10-29-scram-auth-design.md` and the SCRAM landing at HEAD `bd1a83c`.

## Intent

Extend the plugin's SCRAM authentication path to perform SCRAM-SHA-512 **with channel binding** to the TLS server endpoint (RFC 5929 `tls-server-end-point`, GS2 header `p=tls-server-end-point,,`). The server (TrueNAS 26.0 BETA.3 and later) accepts channel binding on its single `SCRAM` mechanism — the mechanism list does not grow a separate `SCRAM-PLUS` value, and the server distinguishes the two sub-modes by the GS2 header the client sends. Plain SCRAM (`n,,`) stays available for callers that cannot or should not bind.

## Why

- **Defense in depth against TLS-stripping / man-in-the-middle proxies.** Plain SCRAM proves "the client knows the key"; SCRAM-PLUS additionally proves "the server I am exchanging keys with is the same server whose cert my TLS stack already validated." A MITM that terminates TLS and re-encrypts can forward every SCRAM frame unchanged but cannot forge the server cert, so its `tls-server-end-point` hash will not match the one the real server computed, and SCRAM-PLUS fails on the server's `verify-key` step.
- **Server policy foresight.** The TrueNAS client (`midclt`) already defaults to channel binding and treats disabling it as the special case (`--no-channel-binding`). Policy pressure to require it server-side is foreseeable; the plugin should be ready to honor that when it arrives.
- **Strategic positioning ahead of TrueNAS 27.** `auth.login_with_api_key` is already scheduled for removal; shipping SCRAM-PLUS alongside the base SCRAM landing keeps the plugin aligned with the server's hardening roadmap rather than chasing it.

## Goals

1. **New mechanism value**: `tn_auth_mechanism=scram-plus`. Strict CB. Dies hard if the server does not advertise SCRAM or if the TLS cert hash cannot be computed or if the server rejects the `c=` attribute. No fallback to plain SCRAM, ever.
2. **`auto` is unchanged.** Explicitly: `tn_auth_mechanism=auto` on an existing storage does NOT silently upgrade to CB after this change ships. CB is opt-in per storage via `tn_auth_mechanism=scram-plus`. `auto` continues to pick plain T1 (SCRAM, GS2 header `n,,`) when the server advertises SCRAM and `tn_api_username` is set, exactly as it does at HEAD `bd1a83c`. — Decided this way during brainstorming after the builder-check flagged that an `auto`-upgrade would silently change behavior for every TN-26.0+ storage on upgrade; backward compat (Goal 5) wins.
3. **Per-storage flag.** Same shape as the other `tn_*` knobs. One storage may be `scram-plus`, another `scram`, another `plain`, all in the same cluster.
4. **Pool-key separation.** A storage with `scram-plus` and a storage with `scram` on the same host+key+username must get separate broker pools. The pool-key hash already includes the normalized mechanism string, so `scram-plus` vs `scram` naturally yields distinct hashes — no code change to the pool key.
5. **Backward compatibility.** `tn_auth_mechanism=auto` / `scram` / `plain` behave exactly as they do today (HEAD `bd1a83c`). The only new behavior is the one new enum value and its code path. No existing storage behavior changes without a config edit.
6. **Fail-closed error reporting.** When strict CB fails, the die message names the specific failure (`server does not advertise SCRAM`, `TLS handle has no peer certificate`, `peer certificate digest failed`, or the server-side rejection text) — never a generic "SCRAM auth failed."
7. **`tn_api_insecure=1` is allowed with `scram-plus`.** CB mechanically ties the SCRAM exchange to whichever cert the client saw, so it still defeats a relaying MITM even when `SSL_verify_mode=0`. The Why section's "already validated" wording is scoped to the CA-validated path; the Allowed-with-caveat wording is in the wiki + schema description.

## Non-goals

- A separate `tn_scram_channel_binding = none|tls-server-end-point` scfg field. Decided against — one knob (`tn_auth_mechanism`) is enough.
- An auto-upgrade path in `auto`. See Goal 2.
- Support for other channel-binding types (`tls-unique`, `tls-exporter`). RFC 5929 §4 defines `tls-server-end-point` as the only CB type TLS 1.2+ servers can reliably implement without library-level hooks; TrueNAS uses only this one.
- Direct-WS path migration. The direct-WS escape hatch (`TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1`) is dev-only, already deferred for the base SCRAM work. It stays on legacy T3 here too and is called out in the user-facing warning.
- Making CB mandatory anywhere, cluster-wide or per-host. The admin opts in per storage.
- Refusing `tn_api_insecure=1 + tn_auth_mechanism=scram-plus`. See Goal 7.

## Anti-goals (would make this a failure even if it technically works)

- **Silent fallback from strict `scram-plus` to plain SCRAM.** If an admin set `scram-plus`, a silent downgrade is a security bug. Dies hard — no exceptions.
- **CB-bound and non-CB sessions sharing a broker worker.** The broker's WS pool key already hashes the mechanism string, so `scram-plus` and `scram` naturally yield distinct pool keys and never share a worker. The pool-key test pins this.
- **CB cert hash computed with a weak digest.** TLS cert signature-algorithm steering (RFC 5929 §4.1) says: use SHA-256 when the cert's signature algorithm is MD5 or SHA-1, else use the cert signature's own hash. We follow this rule rather than hard-coding SHA-256; a mismatch between client and server digest choice would silently reject every CB login against certs signed with SHA-384 or SHA-512.
- **Plain SCRAM broken as collateral.** The crypto module gets one new optional named arg (`channel_binding`), everything else stays. Existing SCRAM callers (base-branch tests, live traffic on current storages) are untouched.
- **Existing `auto` storages silently binding to CB after upgrade.** Covered by Goal 2.

## Constraints

- **Pure Perl, no new C libs.** `IO::Socket::SSL` and its `peer_certificate('x509')` are already pulled in by the broker. `Net::SSLeay::i2d_X509()` extracts the DER encoding. `Net::SSLeay::OBJ_obj2txt()` reads the cert's signature-algorithm OID so we pick the right digest. `Digest::SHA` (core) provides SHA-256/384/512 for the digest step.
- **No new Debian deps.** All of the above are already in the Depends line of the current branch.
- **Must work on PVE 8 and 9.** Both bookworm's `libio-socket-ssl-perl` and `libnet-ssleay-perl` export the needed functions.
- **Backward compat with HEAD `bd1a83c`.** This design builds on top of the just-finished SCRAM branch; it is not a rewrite.
- **The broker file stays `package main;`** (ruling from the base-SCRAM ledger). All new tests use `main::` or bareword, same as the base branch's tests.

## Decided design

### `tn_auth_mechanism` grows one value

The `properties` hash entry gains `scram-plus`:

```perl
tn_auth_mechanism => {
    description => "API-key authentication mechanism. 'auto' (default) prefers SCRAM when the server advertises it and tn_api_username is set, then API_KEY_PLAIN, then legacy. 'scram-plus' is strict SCRAM-SHA-512 with TLS channel binding (tls-server-end-point); fails hard if the server does not advertise SCRAM, if the TLS peer certificate cannot be read, or if the server rejects the channel-binding data. 'scram' is plain SCRAM, no channel binding. 'plain' never attempts SCRAM.",
    type => 'string', optional => 1,
    enum => ['auto','scram','scram-plus','plain'],
    default => 'auto',
},
```

The enum stays small on purpose. The schema's `enum` validator refuses any other value at `pvesm add` / `pvesm set` time. The broker's `_select_mechanism` also treats any unknown mechanism string as a hard error (not a clamp to `auto`), so an older plugin's unknown value sent on the wire to a newer broker dies rather than silently downgrading.

### `check_config` additions

The create-time check at `TrueNASPlugin.pm:1170` currently refuses `tn_auth_mechanism=scram` without `tn_api_username`. Extend it to also refuse `scram-plus` without `tn_api_username`. The `':'` refusal at `TrueNASPlugin.pm:1155-1157` stays as-is (always on, create and edit).

### Broker tier selection: one new terminal value, not one new tier

The broker's tier helpers (`_do_t1_login`, `_do_t2_login`, `_do_t3_login`) stay the same shape. `_do_t1_login` gains **one optional named argument** (`channel_binding => $cb_raw`) that, when truthy, flips the GS2 header produced by the SCRAM crypto from `n,,` to `p=tls-server-end-point,,` and feeds the raw cert-digest bytes into the `c=` attribute computation. The crypto module `lib/TrueNAS/SCRAM.pm` gets its existing entry points extended with the same optional named argument — `scram_client_first($user, $kid, channel_binding => $cb_raw)` stores the bytes in `$state`, and `scram_client_final` reads them from there when building the `c=` attribute and the AuthMessage. `scram_process_server_first` and `scram_verify_server_final` are unchanged — the server's side-channel inputs don't differ between SCRAM and SCRAM-PLUS, only the client's GS2 header and `c=` attribute do.

`_select_mechanism` grows one new return value, `T1-PLUS`, that signals T1 with CB on. The caller (`_authenticate`) dispatches T1-PLUS to `_do_t1_login(... channel_binding => $cb_raw)`. The CB data itself is passed in alongside the dispatch, not computed inside `_do_t1_login`, so the selector logic stays pure. The CB-data extraction happens in `_authenticate` only when `mech eq 'scram-plus'` — a plain-mode or `auto` call pays no cert-digest cost.

### `_authenticate` grows one branch

Before calling `_select_mechanism`, `_authenticate` extracts the peer cert digest from the TLS handle ONLY when `tn_auth_mechanism eq 'scram-plus'`. If extraction fails under `scram-plus`, dies with the specific reason. Pseudocode:

```perl
my ($cb_raw, $cb_err);
if ( ($scfg->{auth_mechanism} // 'auto') eq 'scram-plus') {
    ($cb_raw, $cb_err) = _extract_tls_server_end_point($conn->{sock});
    die "[TrueNAS] tn_auth_mechanism=scram-plus: TLS peer certificate not available for channel binding: $cb_err\n"
        unless defined $cb_raw;
}
my $tier = _select_mechanism($user, $mech, $probe_result, $probe_err, defined $cb_raw);

if ($tier eq 'T1-PLUS') {
    _do_t1_login($conn, $user, $key, channel_binding => $cb_raw);
} elsif ($tier eq 'T1') {
    _do_t1_login($conn, $user, $key);
}  # etc.
```

`_select_mechanism`'s rules (the fifth arg is now `$cb_available`, a boolean, not raw bytes):

- `mech=scram-plus` → `T1-PLUS` if the server advertises `SCRAM`. Dies hard otherwise with "tn_auth_mechanism=scram-plus but server does not advertise SCRAM". Does not fall through to T2/T3 under any circumstance.
- `mech=auto` → unchanged from HEAD `bd1a83c`. Never returns `T1-PLUS`.
- `mech=scram` → unchanged.
- `mech=plain` → unchanged.
- Any other mech string → `die "tn_auth_mechanism=$mech: unknown mechanism"`.

If `_do_t1_login` with CB on fails because the server rejects the `c=` attribute, the SCRAM crypto's server-signature-verification die bubbles up through `_scram_step` with the server's own `AUTH_ERR` text; `_authenticate` does not catch it and does not fall back.

### TLS peer-cert digest selection (RFC 5929 §4.1)

The `tls-server-end-point` CB data is the hash of the server's X.509 cert.

**Implementation shape (verified on bookworm against .70):**

- Use `$sock->get_fingerprint_bin($hash_name)` from `IO::Socket::SSL`. This returns the raw-bytes digest of the DER-encoded peer cert in one call, no manual DER encoding or digest invocation needed.
- Pick `$hash_name` per the cert's signature algorithm, per RFC 5929 §4.1:
  - MD5-based or SHA-1-based signature → `sha256`.
  - SHA-224 → `sha224`.
  - SHA-256 or ECDSA-with-SHA-256 → `sha256`.
  - SHA-384 → `sha384`.
  - SHA-512 → `sha512`.
  - Any other (Ed25519, RSASSA-PSS, unknown) → under `scram-plus`, die with "unsupported certificate signature algorithm: $alg"; under `auto`, N/A (auto doesn't do CB).
- The signature-algorithm name is read via `Net::SSLeay::X509_get_signature_nid` + `Net::SSLeay::OBJ_nid2ln` on the X509 handle returned by `$sock->peer_certificate`. **These symbols may be missing on older `libnet-ssleay-perl` (confirmed missing on the dev host's bookworm build).** The builder picks between:
  1. Trixie's `libnet-ssleay-perl` ≥ 1.94 exports both — require trixie-or-newer in Depends.
  2. Fall back to reading the signature OID via a tiny DER parse of the cert (3-4 lines of Perl: strip outer SEQUENCE, locate the signatureAlgorithm block, read the OID). Takes a one-shot utility sub.
  3. Hard-code `sha256` with a WARN log for any cert where sig-alg detection fails, acknowledging RFC 5929 non-compliance for sha384-/sha512-signed certs.

  Call: Choice (2) if the DER parse is tiny (≤10 lines); choice (1) only if we're OK bumping Depends. Not (3) — a silently-wrong digest produces undiagnosable auth failures.
- The GS2 header fed to the SCRAM crypto is the literal string `"p=tls-server-end-point,,"`. The `c=` attribute's value is `base64(gs2_header_octets . cb_raw_bytes)`.

**Empirical verification against .70 (spike at `.superpowers/sdd/2026-10-29-scram-plus/spike-70.pl`):**

- Positive case: SHA-256 of DER cert via `get_fingerprint_bin("sha256")` + GS2 header `p=tls-server-end-point,,` + correctly-computed `c=` → server returned `SERVER_FINAL_RESPONSE` with `account_attributes: ["LOCAL","API_KEY","SYS_ADMIN","API_KEY","SCRAM"]`, and the client verified the server's `v=` signature byte-for-byte.
- Negative case: first byte of CB flipped → server returned `response_type: AUTH_ERR` and no session was established.

The spike confirms the design mechanics work against a real TN 28.0 MASTER server with its default self-signed cert (sha256WithRSAEncryption).

### Broker wire envelope

**No change.** The plugin already sends `auth_mechanism` on the wire; its value just grows a new accepted string. The broker side's unmarshalling clamps unknown values to `'auto'` (same as it does today for missing / empty).

### Pool key extension

The broker's `scfg_key` currently hashes `host : sha1_hex(key . "|" . user . "|" . mech)`. The `mech` component today is the normalized `tn_auth_mechanism`, which already distinguishes `scram-plus` from `scram` as separate strings — so **no code change is needed to the pool key**. The pool-key test in `t/scram/03-pool-key.t` gets one new assertion: `scram vs scram-plus => distinct hashes`.

### Error semantics

| Scenario | Die message (`$@` text) |
|---|---|
| `scram-plus` + server does not advertise SCRAM | `[TrueNAS] tn_auth_mechanism=scram-plus but server does not advertise SCRAM` |
| `scram-plus` + WSS handle has no peer cert | `[TrueNAS] tn_auth_mechanism=scram-plus but TLS peer certificate not available for channel binding: <reason>` |
| `scram-plus` + server rejects our `c=` | `[TrueNAS] SCRAM-PLUS auth failed: server rejected channel-binding data (c= attribute mismatch)` |
| `scram-plus` without `tn_api_username` | `[TrueNAS] tn_auth_mechanism=scram-plus requires tn_api_username` |

All messages begin with `[TrueNAS]` matching the existing error-prefix style. No message leaks the raw cert bytes or the base64'd CB data.

### Live-test evidence

The server does not surface SCRAM vs SCRAM-PLUS in `account_attributes` (confirmed on .70; both show the same `[LOCAL, API_KEY, SYS_ADMIN, API_KEY, SCRAM]`). The negative test is the mechanical proof. The spike at `.superpowers/sdd/2026-10-29-scram-plus/spike-70.pl` already executed both cases successfully:

1. **Positive test.** `tn_auth_mechanism=scram-plus` against a known-good TN with a valid cert → auth.me succeeds. Broker INFO log stamps `auth: using tier T1-PLUS (mechanism=scram-plus)`.
2. **Negative test (CB mismatch).** Spike-only, not landed as a test: patch the client to send a deliberately wrong `c=` value (one byte flipped). Server returns `response_type: AUTH_ERR` and the SCRAM continuation fails. Confirmed empirically on .70.
3. **Negative test (unsupported server).** Point `scram-plus` at a TN 25.10 or earlier server (no SCRAM in `auth.mechanism_choices`) → broker dies with the specific `tn_auth_mechanism=scram-plus but server does not advertise SCRAM` message.

The positive-test marker that will appear in the normal validation:
- Broker log line: `auth: using tier T1-PLUS (mechanism=scram-plus)`.

### Debian packaging

**No change.** All libraries used (`Net::SSLeay`, `Digest::SHA`, `IO::Socket::SSL`) are either Perl core or already pulled in by the current branch's Depends.

### Backward-compat matrix

| TN version | `tn_auth_mechanism` | `tn_api_username` | Expected tier |
|---|---|---|---|
| 24.10 / 25.04 | any | any | T3 (legacy) |
| 25.10 (API_KEY_PLAIN, no SCRAM) | `scram` or `scram-plus` | set | die |
| 25.10 | `auto` | set | T2 |
| 25.10 | `auto` | unset | T3 |
| 26.0+ | `scram-plus` | set | T1-PLUS |
| 26.0+ | `scram-plus` | unset | die |
| 26.0+ | `auto` | set | T1 (unchanged from HEAD `bd1a83c` — no auto-upgrade) |
| 26.0+ | `scram` | set | T1 (no CB) |
| 26.0+ | `plain` | set | T2 |
| 26.0+ | any | unset | T3 |

Compared to the pre-SCRAM-PLUS matrix: the only new rows are the two `scram-plus` entries. The `auto` and `scram` rows are unchanged. The `plain` and no-username rows are unchanged. No existing storage changes behavior on upgrade.

## What's left to the builder

- **DER-parse fallback for signature-algorithm detection.** The dev host's bookworm `libnet-ssleay-perl` doesn't export `X509_get_signature_nid` / `OBJ_nid2ln`. Options are in the "TLS peer-cert digest selection" section; the builder picks between a tiny DER-parse utility (preferred) or a Depends bump to trixie-or-newer. The spike used a hard-coded `sha256` default, which works against TN's self-signed cert but isn't RFC-compliant for sha384-/sha512-signed certs.
- **CB-digest known-answer vector.** Compute a Python-stdlib oracle for the CB-aware SCRAM path (same pattern as the base SCRAM vector in `t/scram/01-vectors.t`), with a hardcoded DER-encoded test cert, SHA-256 digest, and the resulting `c=` base64. Pin the expected `p=` (client proof) and `v=` (server signature) values. The builder picks the test cert bytes.
- **Pool-key test.** One new assertion in `t/scram/03-pool-key.t`: `scram vs scram-plus => distinct hashes`.
- **`_authenticate` subtest.** Two new cases: `scram-plus` with CB available (stubbed) → T1-PLUS dispatched with `channel_binding` arg set; `scram-plus` without CB (stubbed) → dies with the exact message.
- **`_select_mechanism` subtest.** One new case: `scram-plus` + server advertises SCRAM + `$cb_available=1` → `T1-PLUS`; `scram-plus` + server missing SCRAM → dies.
- **Plugin wire test.** One new subtest in `t/scram/04-plugin-wire.t`: `tn_auth_mechanism=scram-plus` round-trips through the envelope unchanged, and the schema's `enum` validator accepts the new value and refuses a bogus one.
- **`check_config` test.** One new subtest: `tn_auth_mechanism=scram-plus` without `tn_api_username` on create → refused.
- **Live validation plan.** Reuse the spike's shape: build the broker with CB on, create a user-scoped API key on .70, add a storage.cfg entry at .70 with `tn_auth_mechanism=scram-plus`, run `pvesm status` + a short slice of the dev full-function test. Verify the broker INFO log stamps `auth: using tier T1-PLUS (mechanism=scram-plus)`.
- **Wiki update.** Append the two new `scram-plus` rows to `wiki/Configuration.md`'s version matrix. Document `scram-plus` as the strict option. Note the no-fallback behavior. Mention the `tn_api_insecure=1` + `scram-plus` combination is allowed and what it protects against. Reference the spike's negative-test result in the design doc.

## Future work (NOT in this spec)

- **Direct-WS path migration.** Still deferred. The direct-WS escape hatch needs its own branch; SCRAM-PLUS doesn't touch it.
- **Per-cert pinning.** Admin pre-registers a cert hash in storage.cfg (`tn_scram_cb_pin`) and the plugin refuses to connect to a server whose cert doesn't match. This is paranoid-mode channel binding (defense-in-depth on top of CA validation + CB), useful only for air-gapped deployments. Outside this spec.
- **CB with reconnect-token.** Server-side feature; nothing to design on the plugin side until the server implements it.
