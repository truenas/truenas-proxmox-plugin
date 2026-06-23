# Broker hardening tests

Two regression tests added to `t/rate-limit/` to cover failure modes the
original D1/D2/D3/D4 tests didn't reach: broker restart in the middle of
a workload and concurrent in-process load against a single broker.

Companion change: `_broker_rpc` got a deadline-bounded round trip, so a
wedged broker no longer blocks PVE indefinitely.

## Why these tests exist

The first round of rate-limit tests (`00`–`05`, `99`) proved D1–D4 were
fixed. They drove the broker serially from a single process and assumed
the broker was always responsive. Two real-world scenarios fall outside
that envelope:

1. **Broker dies or gets restarted out from under PVE.** Common during
   plugin upgrades (postinst restarts the unit), middlewared restarts on
   the TN side that the broker reacts to, or operator intervention. If
   the plugin cached any state tied to the previous broker process —
   socket fd, pool entry, in-flight TLS handle — the next call after
   restart would fail in confusing ways.

2. **Multiple PVE workers hit the broker at the same instant.** A single
   PVE node easily produces 5+ concurrent storage calls during a backup
   window, multi-disk VM creation, or `pvesh` polling from a cluster
   peer. The broker's accept loop is single-threaded; if it accidentally
   opens an upstream WS per client connection (race in `get_or_open_ws`)
   the per-IP rate limiter would still trip.

Both scenarios are now under the `prove` umbrella.

## `_broker_rpc` deadline

Before this change, the broker client did `sysread` against the Unix
socket with no upper bound. A wedged broker (stuck upstream WS, lost
middlewared, hung systemd unit) caused the read to block forever, which
in turn blocked every PVE operation routed through the plugin.

The new shape:

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

Key points:

- The deadline applies to the **whole round trip**, not per `sysread`.
  A slow-but-progressing TN response won't trip it.
- Default 30 s matches the rest of the plugin's WS I/O envelope.
- Tunable via `tn_broker_timeout` in `scfg` if a deployment has unusual
  latency expectations.
- On timeout, dies with `"broker: read|write timeout after Ns"`. That
  string routes through `_is_connection_error` (which matches `timeout`)
  and triggers the existing retry-with-backoff path.

## `06-broker-restart.t`

Sequence:

1. Drive one successful call through the broker as a baseline.
2. `systemctl restart truenas-plugin-broker`. The broker's upstream WS
   drops, the socket file is recreated by the new process.
3. Poll for `/run/truenas-plugin/broker.sock` to be present and
   connectable, up to 10 s.
4. Drive another call. Plugin must connect to the new broker socket,
   broker must open a fresh upstream WS, call must succeed.

```text
ok 1 - baseline call via broker succeeded
ok 2 - systemctl restart truenas-plugin-broker exit=0
ok 3 - broker.sock back online within 10s of restart
ok 4 - post-restart call via broker succeeded
```

What this catches:

- **Stale fd caching.** If the plugin had reused an old fd or a cached
  `IO::Socket::UNIX` object across the restart, the post-restart call
  would fail. The plugin's design — one Unix-socket connection per RPC,
  closed immediately — already avoids this, but the test guards against
  regressions if someone "optimises" the path to reuse sockets.
- **Socket-replace race.** systemd recreates the socket file as the new
  process binds. A plugin call landing in that microsecond window must
  cleanly retry. The 10 s poll loop in the test exercises this.
- **Broker startup-to-socket-ready latency.** The unit file declares
  `Type=simple`; systemctl returns when the main process is spawned,
  not when the socket is listening. The poll loop bounds how long the
  test will wait; 10 s of headroom is much more than the broker actually
  needs (subsecond in practice).

Skips if not running as root or if `systemctl` is not on PATH. Both are
true on every supported deployment, so the skip is real-world a no-op.

## `07-concurrent-broker.t`

Sequence:

1. Parent drives one warm-up call so the broker's upstream WS is live
   before any child runs. Without this we'd be measuring broker-cold-
   start, not steady-state contention.
2. `fork()` 5 children. Each child issues 4 mixed read calls
   (`system.version`, `pool.dataset.query`, `iscsi.extent.query`,
   `iscsi.target.query`) through `_api_call`. Total: 20 concurrent
   calls hitting the broker via 20 separate Unix-socket connections.
3. Parent reaps all children with a 60 s deadline.
4. After everyone exits, count `auth.login_with_api_key` events in the
   audit window. Must be ≤ 1.

```text
ok 1 - all 5 children completed within 60s
ok 2 - all 5 x 4 concurrent calls succeeded
ok 3 - 5 x 4 concurrent broker calls share <= 1 auth.login_*
```

What this catches:

- **Accept-loop stall.** The broker's accept loop is single-threaded.
  If one client's request blocks the loop (slow upstream TN call,
  malformed JSON, you-name-it), the other 19 calls queue in the kernel
  listen backlog. The 60 s child-completion deadline bounds this; if
  the broker has a real deadlock, children won't reap, test fails.
- **Pool race in `get_or_open_ws`.** The broker maintains one upstream
  WS per `(host, sha1(api_key))`. If two clients arrive before the
  first auth completes, a naive implementation might open two upstream
  WS connections — one per client — producing 2 logins instead of 1.
  The `logins <= 1` assertion is sized to catch that.
- **Per-client FD leaks.** If the broker accepts a client and forgets
  to close on the response path, 5 × 4 = 20 leaked fds in this test
  alone. We don't check fd count here; this is a future addition.

Parameters (`$N_PROCS = 5`, `$M_CALLS = 4`) are picked to comfortably
exceed normal concurrency but stay well under the broker's accept
backlog (Linux default 128) and TN's per-IP rate limiter (20 / 60 s).
Raise both if you want to stress the broker harder; the assertions
should still hold.

## Test suite totals after these additions

| File | Tests | Purpose |
|---|--:|---|
| `00-prereqs.t` | 6 | Environment, TN reachability, audit window |
| `01-d1-single-write.t` | 3 | D1: single write costs ≤ 1 login |
| `02-d1-burst-deathspiral.t` | 4 | D1 + D3: 8-burst without amplification |
| `03-d2-per-process.t` | 2 | D2: 10 forked processes share ≤ 1 login |
| `04-d3-retry-amplification.t` | 4 | D3: tripped limiter doesn't amplify |
| `05-session-reuse.t` | 2 | Positive control: 100 in-process reads = ≤ 1 login |
| `06-broker-restart.t` | 4 | Plugin recovers across broker restart |
| `07-concurrent-broker.t` | 3 | Concurrent load yields ≤ 1 upstream login |
| `99-counter-probe.t` | 2 | Diagnostic: audit counter sanity |

Total: 9 files, 30 tests, ~15 min wall-clock with the default 90 s drain
between tests.

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

Tests 06 and 07 require `root` and `systemctl` available on the
machine running `prove`. On a Proxmox VE node both are present.

## Coverage still missing

These tests close the broker-restart and concurrent-load gaps. Things
still **not** covered:

- Daemon **crashes during** an in-flight RPC, not between RPCs.
- Broker's upstream WS dying mid-call (TN side dropping the TCP).
- Long-duration drift: FD leaks, memory growth, stale TLS sessions.
- Real PVE workloads like `vzdump` and cluster `qmclone`.
- Rotated / revoked API key mid-session.
- LXC paths via `pct`.

See `wiki/D2-per-process-reauth.md` for the design rationale of the
broker itself.
