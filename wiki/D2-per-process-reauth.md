# D2 — per-process re-authentication

> **Status: fixed.** The session broker described in option 1 below (`## What a real D2 fix looks like`) has since been merged directly into `TrueNASPlugin.pm` (`_broker_open_socket`/`_broker_try_open`/`_broker_rpc`, commit `b9c47d3`), not just the standalone `broker-service` branch this doc originally referenced. When `/run/truenas-plugin/broker.sock` is present, `_ws_get_persistent` routes through it automatically. The rest of this document is kept as-written for the problem analysis and rejected alternatives (options 2 and 3); treat any present-tense description of the broker as "implemented in mainline," not "proposed."

## Symptom

Every short-lived Proxmox process that talks to TrueNAS does its own
`auth.login_with_api_key` round trip. Ten concurrent `pvesh status` calls
produce ten logins to the TN middleware. A burst of `qm create` calls
produces one login per `qm` invocation. The TN per-IP-per-method limiter is
20 calls / 60 s, so a busy node easily trips it.

## What "session" means in the plugin

The plugin keeps an in-memory hash, `%_ws_connections`, keyed by
`(host, sha1(api_key), pid)`. A successful `_ws_open` puts the authenticated
WebSocket there. Subsequent `_api_call` invocations inside the same process
call `_ws_get_persistent`, which returns the cached entry. No re-auth.
That's what makes test `05-session-reuse.t` pass — 100 in-process reads
share one login.

## Why each forked process loses the session

The cache is a Perl lexical inside `TrueNASPlugin.pm`. After `fork()`, the
child inherits a copy of the parent's memory image. The plugin detects the
fork via a PID guard (`$_ws_creator_pid` vs `$$`), and on mismatch:

1. Reblesses any inherited socket objects into `NullDestructor` so the
   child's eventual exit doesn't run `IO::Socket::SSL` cleanup on a socket
   whose state is shared with the parent (a real bug if it runs — SSL_free
   corrupts the parent's TLS context).
2. Clears `%_ws_connections` in the child.
3. Resets `$_ws_creator_pid = $$`.

Step 2 is the bit that costs the login. Once the cache is empty, the next
`_api_call` calls `_ws_open` which calls `auth.login_with_api_key`. The
child can't use the parent's authenticated socket — fork-shared TLS state
is unsafe — and there's no out-of-process place to look the session up.

## Where this hits in practice

Proxmox has multiple fork sources:

- `pvedaemon` accepts an API request and forks a worker for the task
  (`qm create`, `qm destroy`, snapshot, clone, vzdump). The worker imports
  `TrueNASPlugin`, hits `alloc_image`, finds empty cache, logs in.
- `pveproxy` forks per HTTPS request, same pattern for any storage-status
  pull from the web UI.
- `pvestatd` runs as its own process and refreshes storage status on a
  timer.
- `qm` invoked from a shell or another script is a fresh process every
  time.
- Cluster commands fan out across nodes; each remote PVE node has its own
  per-process cache.

So in a normal day, a cluster doing a backup window or a multi-VM migration
produces many short-lived processes, each costing one TN login.

## Why "just keep the socket alive in the parent" doesn't help

`pvedaemon` is a long-running process and it does keep its session alive.
But the moment it forks a worker to run `alloc_image`, the worker can't use
that socket — the SSL_free fork-safety issue above. So even though the
parent has a perfectly good session, the worker re-authenticates anyway.

## What test `03-d2-per-process.t` does

`pvesh_status_async($sid, 10)` shells out 10
`pvesh get /storage/<id>/status` processes in parallel. Each one:

1. Imports `PVE::Storage`.
2. Calls into the storage plugin for status.
3. Hits an empty `%_ws_connections`.
4. Does one `auth.login_with_api_key`.
5. Returns the status and exits.

The harness then runs `count_logins` over the window. On a fix that doesn't
address D2, the count is 10. On a fix that does, the expectation is
`logins <= 1`.

## What a real D2 fix looks like

Some kind of out-of-process session holder so that no matter how many
short-lived PVE workers fire up, they all funnel their JSON-RPC through one
upstream authenticated WebSocket. Three shapes you would see in the wild:

1. **Session broker daemon** — long-running root-owned service listening on
   a Unix socket (mode 0600). Workers connect to that socket, hand it a
   request, the daemon proxies it through its single upstream WS, returns
   the response. The `broker-service` branch implements exactly this
   (`/usr/sbin/truenas-plugin-broker`, `/run/truenas-plugin/broker.sock`,
   systemd unit). One login per (host, api_key) per node.

2. **Per-node credential cache + session-token reuse** — login once,
   persist the resulting `auth_token` to a root-readable file with strict
   perms, have each worker open a fresh WS and `auth.token` against the
   cached token instead of `auth.login_with_api_key`. TN treats token
   re-auth differently and (depending on TN version) doesn't count it
   against the same limiter. Cheaper than a broker but TN-side semantics
   are version-sensitive.

3. **FD passing from `pvedaemon`** — `pvedaemon` holds the WS, workers ask
   their parent for a duplicated FD via `SCM_RIGHTS`. Fragile (TLS state
   still in `pvedaemon`'s process), and requires changes to how PVE forks
   workers. Not practical.

The broker is the canonical answer because it's simple, isolates TLS state
to one process, and works regardless of which PVE service spawned the
worker. That's why the `broker-service` branch went that route. The
`fix/rate-limit-connection-reuse` branch chose not to ship a broker;
`t/rate-limit/03-d2-per-process.t` is the standing evidence that the choice
leaves the actual symptom (login storms on bursty workloads) unaddressed.
