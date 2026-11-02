# SCRAM-SHA-512 authentication for truenas-proxmox-plugin

## Intent

TrueNAS 27 removes the `auth.login_with_api_key` JSON-RPC method the
plugin's broker currently uses to open its upstream WebSocket. The
replacement is `auth.login_ex`, which supports two mechanisms for
API-key authentication:

- `mechanism="API_KEY_PLAIN"` — the full API key is sent across the WS as
  a plain string; TrueNAS validates it server-side. Same security model
  as today.
- `mechanism="SCRAM"` — RFC 5802 SCRAM-SHA-512, where the client proves
  possession of the key without sending it, and the server proves
  possession of the key's stored verifier back to the client (mutual
  auth).

Public TrueNAS 26 documentation calls SCRAM "recommended" and lists TN 27
as the removal milestone for `auth.login_with_api_key`. Internal
positioning (per the project owner, who works at TrueNAS) is that SCRAM
is the strategic path and the plugin should land it ahead of TN 27 rather
than in response to it.

The plugin's authentication path lives in the broker daemon
(`tools/truenas-plugin-broker`), with a secondary direct-WS path kept
only for `TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1` developer use. Both must
migrate.

## Goals

- Preserve compatibility with every TrueNAS version the plugin currently
  works against (24.10, 25.04, 25.10, 26.0, future). SCRAM is used where
  the server advertises it; older servers fall back to a mechanism they
  support.
- Default to the strongest supported API-key mechanism on every connect:
  SCRAM-SHA-512 when the server offers it, legacy plain otherwise.
- Keep the raw API key out of the wire on servers that can do SCRAM,
  even when the pre-login probe is rate-limited and we can't
  authoritatively tell what the server supports.
- Let administrators force SCRAM at the plugin level for hardened
  deployments, independent of any server-side `channel_binding=require`
  policy.
- Fit cleanly inside the broker's existing pool / liveness-probe design:
  SCRAM runs at WS open, not on every call; the 60-second `auth.me`
  liveness probe keeps working unchanged.
- Keep the implementation in pure Perl using packages already in
  Debian trixie: `Digest::SHA` (core, HMAC-SHA-512 + SHA-512),
  `MIME::Base64` (core), `Crypt::PBKDF2` (`libcrypt-pbkdf2-perl`), and
  `Crypt::URandom` (`libcrypt-urandom-perl`). No non-core dependencies
  not already in the plugin's `Depends`.

## Non-goals

- SCRAM-PLUS / channel binding (`tls-server-end-point`). The reference
  implementation in `~/terraform/internal/client/scram.go` uses the
  unbound GS2 header `n,,`; TrueNAS accepts unbound clients and
  negotiates channel binding per exchange. First cut matches that. A
  separate design can add SCRAM-PLUS later if any deployment requires it.
- SASL framework abstraction. The plugin needs exactly one mechanism
  (SCRAM-SHA-512); carrying a general SASL library pays for nothing.
- Changing the API key itself or how it is stored in `/etc/pve/storage.cfg`.
  The existing `tn_api_key` field already carries the full `<id>-<secret>`
  format SCRAM needs.
- Replacing or restructuring the broker's connection pool, prefork
  worker model, or liveness-probe cache. SCRAM slots into the existing
  WS-open path; nothing else changes shape.

## Anti-goals (would make this a failure even if it technically works)

- A design where "unknown mechanism support" silently falls back to
  plain. The raw API key would then leak to a SCRAM-capable server
  whose pre-login probe happened to be rate-limited. Fail-open is
  wrong here.
- A design that adds a required `storage.cfg` field for every existing
  install. Adoption friction kills the migration; keep it opt-in with
  sensible defaults for untouched configs.
- A design that re-authenticates on every RPC. The broker's whole point
  is to amortize auth across many callers; SCRAM must respect that.

## Constraints

- The broker is a prefork daemon with N (default 4) worker processes,
  each holding one upstream WS. SCRAM runs once per WS open, per worker.
- `auth.login_ex` is multi-step: the client sends `CLIENT_FIRST_MESSAGE`,
  reads a server-first, sends `CLIENT_FINAL_MESSAGE`, reads a
  server-final. All three request/response pairs share the one WS; TN
  tracks conversation state against that WS connection. The broker must
  therefore run all three steps on the same socket before any other RPC
  flows across it.
- TrueNAS's SCRAM nonce rule: the client's `r=` value must be exactly 32
  random bytes, base64-encoded; the server base64-decodes it and
  rejects any other size.
- Salt must be 16 bytes; iteration count must be in `[50000, 5000000]`.
  The client validates these bounds and refuses a server-first that
  violates them (hostile or buggy middlebox defence).
- The SCRAM username wire-format is `<account>:<keyID>`, where keyID is
  the integer prefix of `<id>-<secret>` in the API key string. The
  broker splits the existing `tn_api_key` on the first `-` to get id
  and secret; neither value is retained after SaltedPassword is derived.
- TN 25.10's `auth.login_ex` returns a specific error when sent
  `mechanism="SCRAM"`:
  `[EINVAL] login_data: Input tag 'SCRAM' found using 'mechanism' does not match any of the expected tags`.
  The fallback code must match on that text to distinguish "server
  doesn't support SCRAM" from "server rejected these credentials."
- TrueNAS rate-limits `auth.login_with_api_key` at 20 calls / 60 s / IP
  / account. `auth.mechanism_choices` and `auth.login_ex` have their
  own buckets. The broker's prefork startup burst (4 workers = 4
  auths) must stay inside TN's smallest ceiling.

## Decided design

### New `storage.cfg` fields

Two new optional keys, both schema-validated in the plugin's `properties`
hash:

```
tn_api_username = <account_name>
```

The TrueNAS account that owns the API key. Required to attempt SCRAM;
plugin falls back to legacy plain login when absent. Not populated by
default — explicit opt-in — so existing storage entries keep working
unchanged.

```
tn_auth_mechanism = auto|scram|plain    (default: auto)
```

- `auto` — probe `auth.mechanism_choices`; prefer SCRAM when it's offered
  and `tn_api_username` is set; fall back to the mechanism available on
  older servers (`auth.login_ex mechanism=API_KEY_PLAIN` on 26+;
  `auth.login_with_api_key` on <26).
- `scram` — fail hard if the server rejects SCRAM or `tn_api_username`
  is missing. For admins enforcing SCRAM-only locally.
- `plain` — never attempt SCRAM. Use the newest plain-API-key method the
  server supports (`auth.login_ex mechanism=API_KEY_PLAIN` or
  `auth.login_with_api_key`). Explicit escape hatch for troubleshooting.

### Three auth tiers

The design covers three methods, one at each level of server age:

| Tier | Method | Server requirement | Trigger |
|---|---|---|---|
| T1 | `auth.login_ex` with `mechanism=SCRAM` | TN 26.0+ advertising `SCRAM` in `auth.mechanism_choices` | `tn_api_username` set AND `tn_auth_mechanism` ∈ {`auto`, `scram`} |
| T2 | `auth.login_ex` with `mechanism=API_KEY_PLAIN` | TN 25.10+ (any server where `auth.mechanism_choices` is a known method) | `tn_api_username` set AND SCRAM unavailable/forbidden |
| T3 | `auth.login_with_api_key` (legacy) | Every supported TN down to 24.10 | Server lacks `auth.login_ex`, OR `tn_api_username` unset for T2 |

Each tier is strictly stronger than the next; a lower tier only runs
after the higher tier is proven unavailable, never as a fail-open from
an auth error.

### Wire shapes

**T1 — SCRAM (three JSON-RPC calls on the same WS):**

```json
auth.login_ex({
  "mechanism": "SCRAM",
  "scram_type": "CLIENT_FIRST_MESSAGE" | "CLIENT_FINAL_MESSAGE",
  "rfc_str": "n,,n=<user>:<keyID>,r=<b64-nonce>" | "c=biws,r=...,p=<b64-proof>"
})
```

Response envelope (`AuthRespScram`):

```json
{
  "response_type": "SCRAM_RESPONSE",
  "scram_type":    "SERVER_FIRST_RESPONSE" | "SERVER_FINAL_RESPONSE",
  "rfc_str":       "r=...,s=...,i=..." | "v=<b64-signature>",
  "user_info":     null | { ... }         // null on first, user on final
}
```

Success = `v=` on the final response verifies against the locally
computed `ServerSignature`. The server also returns `user_info` here
when `SERVER_FINAL_RESPONSE`.

**T2 — `auth.login_ex mechanism=API_KEY_PLAIN` (one JSON-RPC call):**

```json
auth.login_ex({
  "mechanism":     "API_KEY_PLAIN",
  "username":      "<account>",
  "api_key":       "<full key, incl. 'id-' prefix>",
  "login_options": {}
})
```

Response (`AuthLoginExResult.result`, discriminated by `response_type`):

- `{"response_type":"SUCCESS", "user_info": ..., "authenticator": "LEVEL_1"|"LEVEL_2", "reconnect_token": null|str}` — authenticated
- `{"response_type":"AUTH_ERR"}` — rejected
- `{"response_type":"DENIED"}` — credential lacks API role
- `{"response_type":"EXPIRED"}` — key or session expired
- `{"response_type":"OTP_REQUIRED", "username": ...}` — out of scope here
- `{"response_type":"REDIRECT", "urls":[...]}` — out of scope here

Success = `response_type == "SUCCESS"`. Anything else = auth failure.

**T3 — `auth.login_with_api_key` (legacy, one call):**

```json
auth.login_with_api_key("<full key>")
```

Returns a bare JSON boolean. `true` = authenticated.

### Mechanism-selection logic (per WS open)

Flow lives in `tools/truenas-plugin-broker`, inside `ws_open()`, after
the WebSocket upgrade completes and before the pool entry is cached.
A single pre-auth call to `auth.mechanism_choices` serves as the age
probe:

- **Probe returns a list containing `"SCRAM"`:** T1-capable server. If
  `tn_auth_mechanism ∈ {auto, scram}` AND `tn_api_username` is set →
  run **T1**. Else → run **T2** (same call; the server definitely has
  `login_ex`).
- **Probe returns a list that does not contain `"SCRAM"`:** T2-capable
  server, no SCRAM. If `tn_auth_mechanism == scram` → fail hard. Else
  → run **T2** (if `tn_api_username` is set) or **T3** (if not).
- **Probe raises a rate-limit error (`IsRateLimited` recognises):**
  bucket is noisy but says nothing about support. If `tn_api_username`
  is set, attempt T1 directly (safer than T2: proof-of-possession, not
  key-in-cleartext). On T1 returning the specific
  `[EINVAL] login_data: Input tag 'SCRAM' ... does not match` message
  (TN 25.10's known SCRAM-rejection text), fall back to T2. On T2
  returning the equivalent "no login_ex" error, fall back to T3.
- **Probe raises any other error (method not found, server too old
  to know `auth.mechanism_choices`):** no `login_ex`. If
  `tn_auth_mechanism == scram` → fail hard. Else → run **T3**.

`tn_auth_mechanism == plain` short-circuits SCRAM entirely but still
prefers T2 over T3 when `login_ex` is available.

**Explicit no-fallback edges** (the "fail-open leaks the key" scenarios
the anti-goals call out):

- A SCRAM `verifyServerFinal` failure MUST NOT fall back to T2 or T3.
  The server failed to prove possession of the key — assume MITM, abort.
- A T2 `AUTH_ERR` / `DENIED` / `EXPIRED` MUST NOT fall back to T3.
  The credential was rejected, not the mechanism.

Every path logs the mechanism it chose (level 1 info), the fallback
reason if any (level 1 warning), and auth success/failure
(existing broker log pattern).

### Rate-limit discriminator

Matches the terraform provider's heuristic in
`~/terraform/internal/client/callread.go:52-60`:

- `APIError.code ∈ {0, 16, 22, -32000}`, OR
- `APIError.message` (lowercased) contains `"rate limit"` or
  `"concurrent calls"`.

In Perl, surfaces from `_ws_rpc` as a `die` with an error string we
pattern-match on. Factor into a small helper `_is_rate_limited($err)`
local to the broker.

### SCRAM crypto, pure Perl

A new module `tools/truenas-plugin-broker` or a factored
`lib/TrueNAS/SCRAM.pm` (builder decides) implements the four pure
functions:

- `scram_client_first($username, $key_id)` → returns `($client_first_bare,
  $client_first_wire, $nonce_raw)`. Internally generates 32 random bytes
  via `Crypt::URandom::urandom(32)`, builds `n=$username:$keyID,r=<b64>`,
  prepends `n,,`.
- `scram_process_server_first($server_first_str, $secret, $client_nonce_raw)`
  → parses `r=,s=,i=`, verifies the server nonce extends the client
  nonce (binary-prefix check on the base64-decoded bytes), validates
  salt length == 16 and iterations ∈ [50000, 5000000], derives
  `SaltedPassword = Crypt::PBKDF2(SHA-512, 64-byte).PBKDF2($secret, $salt, $iter)`.
  Returns the saved conversation state (hashref).
- `scram_client_final($state)` → computes `ClientKey = HMAC-SHA-512(SaltedPassword, "Client Key")`,
  `StoredKey = SHA-512(ClientKey)`,
  `AuthMessage = client-first-bare + "," + server-first + "," + client-final-without-proof`,
  `ClientSignature = HMAC-SHA-512(StoredKey, AuthMessage)`,
  `ClientProof = ClientKey XOR ClientSignature`.
  Returns `"c=biws,r=<combined-nonce>,p=<b64(proof)>"`.
- `scram_verify_server_final($state, $server_final_str)` →
  parses `v=<b64>`, computes
  `ServerKey = HMAC-SHA-512(SaltedPassword, "Server Key")`,
  `ServerSignature = HMAC-SHA-512(ServerKey, AuthMessage)`,
  constant-time compares (`Digest::SHA` doesn't expose one;
  implement a short XOR-sum compare so timing doesn't leak).

RNG: `Crypt::URandom::urandom(32)`. Package already in Debian trixie
as `libcrypt-urandom-perl`.

### Error semantics on hard failures

The broker's existing `ws_open` returns a `die` on any auth error.
SCRAM failures surface the same way, with distinct messages so the
operator can tell apart:

- `"[TrueNAS] SCRAM auth failed: server signature verification failed"` —
  the server didn't prove possession of the key's verifier. Likely a
  wrong key or a MitM. **Never retry; the server is not who we think
  it is.**
- `"[TrueNAS] SCRAM auth failed: server-first message malformed: <detail>"` —
  stale server or tampered response. No retry.
- `"[TrueNAS] SCRAM auth failed: iteration count N outside allowed range"` —
  defence against a middlebox or server returning a trivially cheap
  PBKDF2 target. No retry.
- `"[TrueNAS] auth.login_ex rejected SCRAM: <server message>"` with the
  Terraform-provider-matching heuristic `isSCRAMUnsupported` → fall
  back to plain inside `auto`; abort in `scram`.

### Broker wire extension

The plugin → broker JSON-RPC envelope (`_broker_rpc` in
TrueNASPlugin.pm) ships six scfg fields today:
`api_host`, `api_key`, `api_scheme`, `api_port`, `api_insecure`,
`prefer_ipv4`. Add two more, additive (missing fields default to
empty / `auto`):

```perl
scfg => {
    ...  # existing six
    api_username    => $scfg->{tn_api_username},     # optional
    auth_mechanism  => $scfg->{tn_auth_mechanism} // 'auto',
}
```

The broker treats a missing `api_username` as unset (gates T1/T2
accordingly). Missing `auth_mechanism` defaults to `auto`. Old senders
(e.g. a plugin build before this change, or a different branch pointed
at the same broker) continue to work unchanged — they get T3.

### Broker connection pool key

Current key (broker.pl around line 306): `host + sha1(api_key)`.
Extend to include `api_username` and the effective `auth_mechanism`:

```
sk = host + sha1(api_key + "|" + (api_username // "") + "|" + (auth_mechanism // "auto"))
```

Two storages that share host+key but differ on username or mechanism
now map to distinct pool entries. Prevents silent demotion (a
plain-mechanism entry sharing a pool with a scram-mechanism entry) or
cross-user auth confusion. Session-key cardinality grows at most by
the number of distinct (user, mechanism) tuples per host — in practice
one.

### Debian packaging

Add two runtime depends to `debian/control`:

```
Depends: ..., libcrypt-pbkdf2-perl, libcrypt-urandom-perl, ...
```

Both are in Debian bookworm (PVE 8) and trixie (PVE 9); no change to
the plugin's existing `pve-manager (>= 8.0.0)` support floor.
`Digest::SHA` and `MIME::Base64` are perl core on both.

### Backward compat matrix

| TN version      | `tn_api_username` set? | `auth.mechanism_choices`     | Result (tier)                                           |
|-----------------|-------------------------|------------------------------|---------------------------------------------------------|
| 26.0+           | yes                     | lists `SCRAM`                | SCRAM via `auth.login_ex` (**T1**)                      |
| 26.0+           | yes                     | rate-limited probe           | T1 attempted directly; T2 only on explicit SCRAM reject |
| 26.0+           | no                      | lists `SCRAM`                | `auth.login_ex mechanism=API_KEY_PLAIN` (**T2**)*       |
| 25.10           | yes                     | returns list, no `SCRAM`     | T2                                                      |
| 25.10           | no                      | returns list                 | T2                                                      |
| 25.04 / 24.10   | any                     | method not found / errors    | `auth.login_with_api_key` (**T3**)                      |
| 27.x            | yes                     | lists `SCRAM`                | T1 (legacy T3 is gone upstream; our T3 code never runs) |
| 27.x            | no                      | lists `SCRAM`                | T2                                                      |

`*`: on TN 26.0+ with `tn_api_username` unset, T2 is still reachable
(API_KEY_PLAIN requires `username`, which can come from the plugin
schema or — a future design — be derived from the key's owner via a
pre-auth probe). First cut: if `tn_api_username` is unset we also fall
back to T3 (legacy), to keep the "zero config churn for existing
installs" promise intact. Admins who want T2 or T1 add
`tn_api_username` to their storage.cfg.

The legacy T3 path stays in the code until our minimum supported TN
crosses 25.10. Deprecated-but-present behaviour.

## What's left to the builder

- Choose between inlining the four SCRAM helpers in
  `tools/truenas-plugin-broker` vs. factoring them into
  `lib/TrueNAS/SCRAM.pm`. Either is fine; the plugin repo already has
  some utility code factored into `lib/`.
- Write unit tests at `t/scram/01-vectors.t` covering (a) RFC 5802's
  worked SCRAM-SHA-1 vectors adapted to SHA-512 if any public SHA-512
  vectors exist, otherwise self-check round-trip against the Terraform
  provider's test fixtures in `~/terraform/internal/client/scram_internal_test.go`,
  and (b) the salt-length and iteration-range refusals.
- Write a live-ish integration test that opens a WS against our test
  cluster's TrueNAS at `192.168.1.68` (or `.70` once SCRAM is on-wire
  there) and exercises both the SCRAM path and the plain fallback,
  under `t/scram/02-live.t` with an environment-gated skip when the
  live target is absent (same pattern as the existing `t/rate-limit/`
  tests).
- Decide the exact log line format for mechanism selection (`[info]
  broker: using SCRAM for pool entry <sk>` vs structured JSON);
  consistent with the broker's existing `linfo`/`lwarn` pattern.
- Decide whether a mechanism switch between pool entries counts as
  a reconnect event the retry policy should wait on. First cut: no —
  mechanism is decided once per WS open and never changes mid-flight.

## Validation plan

1. **Vector tests** against known SCRAM-SHA-512 answers (either RFC
   fixtures or round-tripped Terraform provider test fixtures).
2. **Live tests** against our 192.168.1.68 cluster (currently 25.10,
   advertises `API_KEY_PLAIN` only) and 192.168.1.70 (currently 26.0
   MASTER; advertises SCRAM). Both must authenticate cleanly through
   `auto` mode without any `storage.cfg` change beyond `tn_api_username`.
3. **lifecycle-tests run-all** on the upgraded cluster post-change,
   asserting the broker still answers under load and the 30-day
   liveness-probe path still re-establishes a session via SCRAM when
   `auth.me` fails post-expiry.
4. **proxmox-test-runner storage-plugin-validation** two iterations
   against truenas-storage, with the broker configured to force
   `tn_auth_mechanism=scram` so a regression anywhere in the SCRAM
   path shows as a test failure rather than a silent fallback.
5. **Rate-limit stress** test: 10 concurrent broker starts against a
   single TN, verifying none exceed TN's 20/60s auth bucket.

## Open questions for the builder (none that change the design)

All design-level decisions are settled. The two implementation choices
listed in "What's left to the builder" are stylistic and don't change
behaviour.
