# Broker rate-limit regression tests

Reference for everything under `t/rate-limit/`. Nine test files, 30
individual assertions, all real-TN (no mocks). The harness counts
upstream `auth.login_with_api_key` events through TN's own `audit.query`
endpoint, so every assertion in the suite is grounded in what TN saw,
not what the plugin claims to have done.

Companion to `wiki/D2-per-process-reauth.md`, which explains the
underlying problem the broker exists to solve.

## Background

Four defects (D1–D4) were identified in the original rate-limit
analysis:

| Code | Symptom |
|------|---------|
| **D1** | Every write op opens a fresh ephemeral WS and re-authenticates (one alloc → ~3 logins: dataset + extent + targetextent create). |
| **D2** | Every short-lived PVE process (qm, pvesh, forked pvedaemon worker) starts with an empty `%_ws_connections` cache and re-authenticates. |
| **D3** | `Rate Limit Exceeded` was inside the retryable error class, so a throttled write fired more logins inside the same lockout window — amplifying the failure instead of backing off. |
| **D4** | A 100 ms `usleep` before every login was cosmetic; against a 20 / 60 s per-IP limiter it does nothing useful. |

TN's `auth.login_with_api_key` is rate-limited at 20 calls per 60 s per
source IP. Under bursty workloads (multi-disk VM creation, vzdump, clone
storms) D1+D2+D3 combine into a death spiral: many short-lived processes
each emit several logins, the limiter trips, retries on the EBUSY
response fire even more logins inside the same window, the limiter
stays tripped longer.

The session broker daemon (`tools/truenas-plugin-broker`) is the fix:
one upstream authenticated WebSocket per (host, api_key) pair per node,
listening on `/run/truenas-plugin/broker.sock`, proxying JSON-RPC for
every plugin invocation. The plugin's `_broker_try_open` short-circuits
into the broker on every call when the socket is present.

The tests below verify that the broker is doing what it should.

## Harness shape

The harness (`t/rate-limit/lib/RateLimit/Harness.pm`) provides:

- `test_scfg()` — build a minimal `$scfg` from the PVE storage config
  via `pvesh get /storage/<id>`. Emits both legacy `api_*` and tn-
  prefixed `tn_api_*` keys so the same harness drives either plugin
  branch unchanged.
- `new_audit_conn()` — open one long-lived WS to TN dedicated to audit
  polling, prime it with `system.version` so the first audit query
  doesn't land inside a test window.
- `drain_limiter()` — sleep `DRAIN_SECS` (default 90) so the per-IP
  counter has rolled over before the next test.
- `count_logins($start_iso, $end_iso)` — query TN's `audit.query` for
  `AUTHENTICATION` events in the window, count rows whose
  `event_data.credentials` indicates an API_KEY login.
- `qm_create_with_disk($vmid, $sid, $gb)` — wraps `qm create … --scsi0
  $sid:$gb`. Canonical PVE alloc path.
- `qm_destroy($vmid)` — wraps `qm destroy --skiplock --purge`.
- `pvesh_status_async($sid, $n)` — fork-exec `n` parallel
  `pvesh get /storage/<id>/status` invocations and wait for all.
- `reap_orphans()` — pre-suite sweeper for VMIDs in the test range.

The audit-query path retries once on a stale persistent-WS failure (by
dropping the cached conn and reopening) before giving up. By default it
dies on second failure; set `TN_LOGIN_COUNT_FALLBACK_JOURNAL=1` to opt
into a journalctl-based fallback that needs `TN_SSH_HOST`.

## Required environment

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `TN_HOST` | yes | — | TrueNAS API host (IP or DNS name). |
| `TN_API_KEY` | yes | — | API key for the storage. |
| `STORAGE_ID` | yes | — | Proxmox storage ID of a configured TrueNAS-backed storage. |
| `TEST_VMID_BASE` | no | `99000` | First VMID in the test range. Suite claims `BASE..BASE+99`. |
| `DRAIN_SECS` | no | `90` | Sleep between tests so the 20/60 s limiter resets. |
| `KEEP_RESOURCES` | no | `0` | Skip cleanup-after-failure for triage. |
| `TN_LOGIN_COUNT_METHOD` | no | `audit` | `audit` (default) or `journal`. |
| `TN_LOGIN_COUNT_FALLBACK_JOURNAL` | no | `0` | If `1`, fall back to journal on twice-failed audit query. |
| `TN_SSH_HOST` | journal only | — | TN SSH host (only used by journal counter). |
| `TN_SSH_USER` | journal only | `root` | TN SSH user. |
| `TN_SSH_KEY` | journal only | — | TN SSH private key path. |

`run.sh` validates `TN_HOST`, `TN_API_KEY`, `STORAGE_ID` before
invoking `prove`.

## Tests

### `00-prereqs.t` — environment + plumbing

6 assertions, runs first by lexicographic ordering. Catches setup
mistakes before any expensive test runs.

Sequence:
1. Confirm `TN_HOST`, `TN_API_KEY`, `STORAGE_ID` are set in the
   environment.
2. Call `test_scfg()` — exercises `pvesh get /storage/<id>` and the
   JSON decode path.
3. Open the audit polling WS with `new_audit_conn()`. Implicitly tests
   plugin load, TLS handshake, WebSocket upgrade, JSON-RPC auth.
4. Run `count_logins($now, $now)` on an empty zero-width window and
   assert it returns `0`. Sanity for the counter; if this returns
   non-zero, the counter is fundamentally broken and every other test
   below is unreliable.

What it catches:
- Wrong / unset env vars (typo in `STORAGE_ID`, etc).
- Storage entry not configured for `truenasplugin`.
- TN not reachable / wrong port / wrong API key / wrong TLS settings.
- `audit.query` schema drift (newer TN moving fields around).

### `01-d1-single-write.t` — D1 single write

3 assertions. The minimal D1 repro: one VM-with-disk create, count
upstream logins. Pre-fix this emits ~3 (one per write op); post-fix
≤ 1 (everything rides one upstream WS).

Sequence:
1. Drain the limiter.
2. Record start ISO.
3. `qm create $vmid --scsi0 <storage>:1` — one VM, one 1G disk.
4. Sleep 2 s so audit events flush, record end ISO.
5. Count logins in the window.

Assertions:
- `qm create` exit 0.
- `logins <= 1`.
- `qm destroy` cleanup exit 0.

What it catches:
- Regression in `_api_call_mutate` if someone reintroduces an
  ephemeral-WS write path.
- Broker bypass — if the broker socket is gone but the plugin still
  tries to short-circuit to it, the post-fix expectation of 0 logins
  on a hot upstream WS would break.

### `02-d1-burst-deathspiral.t` — D1 + D3 under burst

4 assertions. Eight sequential VM-with-disk creates from one PVE
node. Pre-fix shape: ~24 logins inside one 60 s window, limiter trips
around create #7, D3 retry-on-EBUSY fires more logins inside the same
window, death spiral. Post-fix on this branch: 8 successful creates,
zero EBUSY, 0–8 total logins (broker pools all the calls into 1
upstream session).

Sequence:
1. Drain limiter.
2. Record start ISO.
3. Loop 8 times: `qm create $base+i`. Collect failures, EBUSY hits,
   and successful VMIDs into separate arrays.
4. Sleep 2 s, record end ISO, count logins.
5. Destroy every VM that was created.

Assertions:
- All 8 creates succeed (no lockout-induced failure).
- Zero EBUSY responses recorded across the burst.
- Total logins ≤ 8 (D1 budget). With the broker, observed in practice
  is 0.
- Cleanup destroys all 8.

What it catches:
- Reintroduction of D1 (per-write ephemeral logins) — would push the
  count past 8.
- Reintroduction of D3 (retrying on EBUSY) — would push it past 8 AND
  show EBUSY hits in the output array.
- Broker pool race that opens more than one upstream WS under
  concurrent client connections.

### `03-d2-per-process.t` — D2 cross-process re-auth

2 assertions. The canonical D2 test. Forks 10 `pvesh get
/storage/<id>/status` processes in parallel. Each is a fresh `perl`
interpreter with an empty `%_ws_connections` cache; without a session
broker, each opens its own upstream WS = 10 logins. With the broker,
all 10 funnel through the broker's single pooled upstream WS = ≤ 1
login.

Sequence:
1. Drain limiter.
2. Record start ISO.
3. `pvesh_status_async($sid, 10)` — shell-out fork-exec the 10 status
   queries, wait for all.
4. Sleep 2 s, record end ISO, count logins.

Assertions:
- All 10 pvesh calls exit 0.
- Total logins ≤ 1.

What it catches:
- Plugin reverting to per-process WS creation (would push to 10).
- Broker socket absent or unreachable (plugin falls through to direct
  WS path, also pushing to 10).
- Broker pool keyed on something process-specific by accident — would
  open one upstream WS per client connection.

### `04-d3-retry-amplification.t` — D3 retry storm

4 assertions. Destructive: it intentionally trips the per-IP limiter,
then runs one write under the tripped condition and verifies that
single write does not fire additional retry logins.

Sequence:
1. Unit assertion: `_is_retryable_error` returns false for a string
   containing `Rate Limit Exceeded`. No TN traffic.
2. Drain limiter, then ramp it back up: 25 fresh `_ws_open` calls in
   sequence. Each authenticates. The 20/60 s threshold trips
   somewhere in the run.
3. Record how many of those calls saw an EBUSY response — must be > 0
   or the test is misconfigured (TN version differs from documented
   threshold).
4. Record start ISO. Drive one `qm create` against the tripped
   limiter. Sleep 2 s, record end ISO, count logins in the window.
5. Cleanup destroys the created VM if alloc succeeded; otherwise
   passes the cleanup assertion with a no-op.
6. Sleep 90 s before exiting so the next test starts with a clean
   limiter window.

Assertions:
- `_is_retryable_error("...Rate Limit Exceeded...")` returns 0.
- Pre-trip saw ≥ 1 EBUSY (sanity).
- Logins during the single post-trip write ≤ 1.
- Cleanup of the created VM succeeded (or no-op if alloc failed).

What it catches:
- Reintroduction of `/rate limit/i` into `_is_connection_error` or
  `_is_retryable_error`.
- Retry path swallowing the EBUSY response and silently doing more
  upstream calls inside the same window.

This test is scheduled last among the D1–D3 tests because it
deliberately damages the limiter state; the 90 s post-trip sleep
ensures subsequent tests start clean.

### `05-session-reuse.t` — positive control

2 assertions. Proves the persistent-socket path works under normal
load. Drives 100 mixed read calls through `_api_call` in a single
process. Pre- and post-fix this should be ≤ 1 login because reads
have always ridden the persistent WS within one process.

If this test fails on a pre-fix build, the persistent-session machinery
is broken in some way that has nothing to do with D1/D2/D3 and needs
its own investigation. Acts as a sanity floor.

Sequence:
1. Drain limiter.
2. Record start ISO.
3. Loop 100 times. Cycle through four endpoints (`system.version`,
   `pool.dataset.query`, `iscsi.extent.query`, `iscsi.target.query`).
4. Sleep 2 s, record end ISO, count logins.

Assertions:
- All 100 calls succeed.
- Logins ≤ 1.

What it catches:
- Persistent-WS connection cache regression that silently re-auths on
  every call.
- `audit.query` filter wrong — if the harness's filter doesn't match
  TN's audit event shape, we'd see 0 here too (but other tests would
  also be ≤ N/2 so 99-counter-probe would flag the same issue).

### `06-broker-restart.t` — broker restart survival

4 assertions. Drive a baseline call, restart the broker out from
under the plugin via systemctl, wait for the socket to come back,
drive another call.

Sequence:
1. Drive one successful call (baseline).
2. `systemctl restart truenas-plugin-broker`. The broker's upstream
   WS drops; the socket file is recreated by the new process.
3. Poll `/run/truenas-plugin/broker.sock` for existence + connectable
   every 200 ms, up to 10 s.
4. Drive another call. Plugin must connect to the new broker socket,
   broker must open a fresh upstream WS, call must succeed.

Assertions:
- Baseline call OK.
- `systemctl restart` returned 0.
- Socket back online within 10 s.
- Post-restart call OK.

What it catches:
- Stale fd caching in the plugin — current design opens a new Unix
  socket per RPC so this is already safe, but the test guards against
  someone "optimising" the path to reuse sockets.
- Socket-replace race during the very small window between
  systemd-unlink and systemd-rebind.
- Broker startup-to-socket-ready latency larger than expected.

Skips if not running as root or `systemctl` is absent. Both are true
on every supported deployment, so the skip never fires in practice.

### `07-concurrent-broker.t` — concurrent contention

3 assertions. 5 forked children, each issues 4 mixed read calls
through the broker. Total: 20 concurrent calls hitting the broker via
20 separate Unix-socket connections.

Sequence:
1. Warm-up call from the parent so the broker has a hot upstream WS
   before any child runs (avoids measuring cold start).
2. Drain limiter, record start ISO.
3. Fork 5 children. Each:
   - Cycles through `system.version`, `pool.dataset.query`,
     `iscsi.extent.query`, `iscsi.target.query` × 4 calls.
   - Counts failures.
   - Exits 0 if all succeeded, 1 otherwise.
4. Parent waits up to 60 s for all children.
5. Sleep 2 s, record end ISO, count logins.
6. Kill and reap any straggler.

Assertions:
- All 5 children completed inside the 60 s deadline.
- All 20 individual calls succeeded.
- Total logins ≤ 1 (broker pooled across all 20).

What it catches:
- Accept-loop deadlock. The broker's accept loop is single-threaded;
  if one client request stalls the loop, the other 19 calls queue in
  the listen backlog. A real deadlock prevents children from reaping;
  the 60 s deadline bounds detection.
- Pool race in `get_or_open_ws`. If two clients arrive before the
  first auth completes, a naive implementation might open two upstream
  WS connections. The `logins ≤ 1` assertion catches that.
- Per-client FD leaks on the broker side. Not directly measured here;
  combine with `ss -xnp | grep broker.sock` for an explicit check.

Parameters (5 procs × 4 calls) are picked to comfortably exceed normal
concurrency on a busy PVE node but stay below the default listen
backlog (Linux 128) and the TN limiter (20 / 60 s). Raise both for a
stress run; the assertions still hold.

### `99-counter-probe.t` — audit sanity (diagnostic)

2 assertions. Not really a regression test for the plugin — it
verifies the **counter itself** isn't lying.

Sequence:
1. Drain limiter.
2. Record start ISO.
3. Drive 15 fresh `_ws_open` calls in sequence (each is a real login,
   but 15 is well under the 20/60 s threshold so the limiter doesn't
   trip).
4. Sleep 2 s, record end ISO, call `count_logins`.
5. Also dump a sample of the last 3 audit events for human inspection
   if something looks off.

Assertions:
- All 15 `_ws_open` calls succeeded.
- `count_logins` reported ≥ N/2 (i.e., ≥ 7) of the 15 known logins.

What it catches:
- TN audit schema drift that breaks the harness's event-shape parser
  in `_count_logins_audit`. Without this test, a counter that silently
  returns 0 would make every other test appear to pass trivially.
- `audit.query` filter syntax changing between TN versions.
- Local clock skew so large that the ISO window misses every event.

The 99- prefix runs it last so a counter regression is flagged
explicitly at end-of-suite rather than silently undermining earlier
results.

## `_broker_rpc` deadline (introduced with 06 + 07)

Before the broker hardening pass, `_broker_rpc` did `sysread` on the
Unix socket with no upper bound. A wedged broker — stuck upstream WS,
lost middlewared, hung systemd unit — caused the read to block forever,
blocking every PVE operation that routed through the plugin.

The deadline mechanism:

```perl
my $timeout = $scfg->{tn_broker_timeout} // 30;
my $deadline = time() + $timeout;
my $sel = IO::Select->new($sock);

# before each sysread / syswrite:
my $remaining = $deadline - time();
die "broker: read timeout after ${timeout}s" if $remaining <= 0;
my @ready = $sel->can_read($remaining);
die "broker: read timeout after ${timeout}s" unless @ready;
my $got = $sock->sysread(...);
```

Properties:

- Deadline applies to the **whole round trip**, not per `sysread`. A
  slow-but-progressing TN response won't trip it.
- Default 30 s matches the rest of the plugin's WS I/O envelope.
- Tunable via `tn_broker_timeout` in `scfg` for deployments with
  unusual latency.
- On timeout, dies with `"broker: read|write timeout after Ns"`.
  That string routes through `_is_connection_error` (which already
  matches `timeout`) and triggers the standard retry-with-backoff
  path.

## Running the suite

```sh
TN_HOST=192.168.1.68 \
TN_API_KEY="$(awk -v sid=truenas-storage \
    '/^truenasplugin:/{ in_st=($2==sid) } \
     in_st && /tn_api_key/ { print $2; exit }' \
    /etc/pve/storage.cfg)" \
STORAGE_ID=truenas-storage \
TEST_VMID_BASE=99000 \
DRAIN_SECS=90 \
bash /root/t/rate-limit/run.sh
```

`run.sh` validates the required env vars, runs a pre-suite orphan
reaper for VMIDs in the test range, then invokes `prove -rv` over the
`*.t` files in lexicographic order.

Expected wall-clock with `DRAIN_SECS=90`: ~15 minutes.

## Inventory after the hardening pass

| File | Tests | Purpose | Defect |
|---|--:|---|---|
| `00-prereqs.t` | 6 | Environment, TN reachability, audit window | — |
| `01-d1-single-write.t` | 3 | Single write ≤ 1 login | D1 |
| `02-d1-burst-deathspiral.t` | 4 | 8-burst without amplification | D1 + D3 |
| `03-d2-per-process.t` | 2 | 10 forked processes share ≤ 1 login | D2 |
| `04-d3-retry-amplification.t` | 4 | Tripped limiter doesn't amplify | D3 |
| `05-session-reuse.t` | 2 | Positive control: 100 in-process reads = ≤ 1 login | — |
| `06-broker-restart.t` | 4 | Plugin recovers across broker restart | broker resilience |
| `07-concurrent-broker.t` | 3 | Concurrent load yields ≤ 1 upstream login | broker resilience |
| `99-counter-probe.t` | 2 | Audit counter sanity | infra |

Total: 9 files, 30 tests, ~15 min wall-clock.

## Coverage still missing

These tests cover D1/D2/D3/D4 and the two broker resilience gaps
identified after the initial port. Things still **not** covered:

- Broker daemon **crashes during** an in-flight RPC, not between
  RPCs.
- Broker's upstream WS dying mid-call (TN side dropping the TCP
  connection inside `ws_recv_text`).
- Long-duration drift: FD leaks, memory growth, stale TLS sessions.
- Real PVE workloads like `vzdump` and cluster `qmclone` (these are
  covered by the larger functional suite in
  `tools/dev-truenas-plugin-full-function-test.sh`, just not under
  rate-limit accounting).
- Rotated / revoked API key mid-session.
- LXC paths via `pct`.
- Multi-node cluster operations where workers on different PVE nodes
  hit the same TN concurrently. The broker is per-node, so each node
  still opens its own upstream WS to TN; that's by design but means
  N PVE nodes still cost N logins per (host, key) pair at steady
  state. For a 3-node cluster with the test rig limiter, 3 logins are
  well below the 20/60 s threshold so this is fine in practice.
