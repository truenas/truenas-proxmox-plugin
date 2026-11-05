# D2 — per-process re-authentication

> **Status: shipped and required.** The session broker is `tools/truenas-plugin-broker` (`/usr/sbin/truenas-plugin-broker`, `truenas-plugin-broker.service`, `/run/truenas-plugin/broker.sock`, mode 0600). `TrueNASPlugin.pm` routes every call through it when the socket exists (`_broker_open_socket` / `_broker_try_open` / `_broker_rpc`). When the socket is missing, `_ws_get_persistent` dies instead of opening a direct WebSocket (`TrueNASPlugin.pm:1638-1654`). Direct WS mode is a developer escape hatch behind `TRUENAS_PLUGIN_ALLOW_DIRECT_WS=1`; it is not supported in production and uses only the legacy `auth.login_with_api_key` call. The broker is the only path that uses `auth.login_ex` (SCRAM or `API_KEY_PLAIN`).
>
> The defect description below is history. It documents the pre-broker behavior that motivated the fix and the alternatives that were rejected; it no longer describes the supported production path.

## Symptom (historical)

Before the broker shipped, every short-lived Proxmox process that talked to
TrueNAS did its own `auth.login_with_api_key` round trip. Ten concurrent
`pvesh status` calls produced ten logins to the TN middleware. A burst of
`qm create` calls produced one login per `qm` invocation. The TN
per-IP-per-method limiter is 20 calls / 60 s, so a busy node easily tripped it.

## What "session" means in direct-WS mode

The plugin keeps an in-memory hash, `%_ws_connections`, keyed by `host:api_key`.
A successful `_ws_open` puts the authenticated WebSocket there. Subsequent
`_api_call` invocations inside the same process call `_ws_get_persistent`, which
returns the cached entry. Broker connections are not stored in that hash: the
broker holds the upstream session and the plugin keeps only a short-lived
Unix-socket client per call.

## Why each forked process lost the session (historical)

The cache is a Perl lexical inside `TrueNASPlugin.pm`. After `fork()`, the
child inherits a copy of the parent's memory image. The plugin detects the
fork via a PID guard (`$_ws_creator_pid` vs `$$`), and on mismatch:

1. Reblesses any inherited socket objects into `NullDestructor` so the
   child's eventual exit doesn't run `IO::Socket::SSL` cleanup on a socket
   whose state is shared with the parent (a real bug if it runs — SSL_free
   corrupts the parent's TLS context).
2. Clears `%_ws_connections` in the child.
3. Resets `$_ws_creator_pid = $$`.

Step 2 was the bit that cost the login. Once the cache was empty, the next
`_api_call` called `_ws_open`, which called `auth.login_with_api_key`. The
child could not use the parent's authenticated socket: fork-shared TLS state
is unsafe, and there was no out-of-process place to look the session up. The
broker removes that cost: the child sends its request over the Unix socket and
the worker pool reuses the upstream session.

## Where this hit in practice (historical)

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
produced many short-lived processes, each costing one TN login. PVE workers
still fork under the broker, but they no longer authenticate.

## Why "just keep the socket alive in the parent" didn't help (historical)

`pvedaemon` is a long-running process and it does keep its session alive.
But the moment it forked a worker to run `alloc_image`, the worker couldn't
use that socket: the SSL_free fork-safety issue above. So even though the
parent had a perfectly good session, the worker re-authenticated anyway. That
is the gap the broker fills.

## What test `03-d2-per-process.t` does

`pvesh_status_async($sid, 10)` shells out 10
`pvesh get /storage/<id>/status` processes in parallel. Each one:

1. Imports `PVE::Storage`.
2. Calls into the storage plugin for status.
3. Opens a short-lived connection to `/run/truenas-plugin/broker.sock`.
4. Sends one JSON-RPC request and receives the response.
5. Returns the status and exits.

No plugin process authenticates directly: each forwards its request to the
broker, which reuses the upstream session already held by the worker that
accepts it. The harness then runs `count_logins` over the window and expects
`logins <= 1`. On the pre-broker direct-WS path the count was 10, which is the
regression the test was written to catch.

## The shipped D2 fix

The fix is an out-of-process session holder: a long-running root-owned broker
listening on `/run/truenas-plugin/broker.sock` (mode 0600). Every plugin
process forwards its JSON-RPC request over that socket; the broker owns the
upstream WebSockets and re-authenticates only when one drops.

The broker runs a prefork pool (`$PREFORK_N`, 4 workers by default). Each
worker holds its own upstream WebSocket per pool entry, keyed by `api_host`
plus `sha1(api_key|api_username|auth_mechanism)`. The pool is worker-local:
sibling workers do not share it, and entries with different credentials never
share an entry. A node can therefore hold up to one upstream session per
credential tuple per worker.

Two alternatives were considered and rejected:

- **Per-node credential cache + session-token reuse**: login once,
  persist the resulting `auth_token` to a root-readable file with strict
  perms, have each worker open a fresh WS and `auth.token` against the
  cached token instead of `auth.login_with_api_key`. TN treats token
  re-auth differently and (depending on TN version) doesn't count it
  against the same limiter. Cheaper than a broker but TN-side semantics
  are version-sensitive.
- **FD passing from `pvedaemon`**: `pvedaemon` holds the WS, workers ask
  their parent for a duplicated FD via `SCM_RIGHTS`. Fragile (TLS state
  still in `pvedaemon`'s process), and requires changes to how PVE forks
  workers. Not practical.

The broker won because it isolates TLS state to one process, works regardless
of which PVE service spawned the worker, and needs no PVE-side changes.
`t/rate-limit/03-d2-per-process.t` is the standing evidence: it asserts
`logins <= 1` across 10 parallel `pvesh` processes.
