# Alloc lock critical section

Analysis of what the plugin holds the PVE per-storage `cluster_lock` for
during a single `alloc_image` call, and where the wall-clock goes. The
broker eliminates upstream login latency, but it doesn't change how
long the lock is held; concurrent-alloc throughput is bounded by that
hold time times N.

## Why this matters

The N=25 concurrent-alloc test (`t/rate-limit/08-concurrent-alloc.t`,
ran with `RL_CONCURRENT_N=25`) failed with 5/25 children timing out on
`cfs lock 'storage-<id>'`. Diagnosis: PVE's `cluster_lock_storage`
serializes every `alloc_image` call per storage. Plugin already raises
PVE's default 10 s timeout to 120 s via the `tn_storage_lock_timeout`
config knob (`DEFAULT_LOCK_TIMEOUT = 120` constant, schema `minimum =>
10, maximum => 600`). At ~5–7 s lock-hold per call, the 17th and later
children at N=25 exceeded the 120 s window.

The broker held the line on the TN side — **0 upstream
`auth.login_with_api_key` calls** across the entire 25-concurrent burst
— so the bottleneck is structurally PVE-side serialization, not TN
rate-limiting.

## Locked code path: `alloc_image`

PVE wraps `alloc_image` in `$class->cluster_lock_storage(...)` from
above. Everything `alloc_image` does happens under that lock. Order of
operations:

| Step | Operation | TN round-trips | Typical cost |
|------|-----------|----------------|--------------|
| 1 | `_preflight_check_alloc` (pool health + free-space + sanity) | 1–3 (mostly cache hits via `_tn_pool_health`) | 50–200 ms |
| 2 | `_find_free_disk_name` if no name supplied (lists zvols, scans for free `vm-<vmid>-disk-N`) | 1 (`pool.dataset.query`) | 100–300 ms |
| 3 | `pool.dataset.create` for the zvol | 1 (sync or job-returning) | 500 ms – 2 s |
| 4 | `_wait_for_job_completion` if step 3 returned a job ID | poll loop, 1–5 polls | up to 5–10 s on slow TN |
| 5 | `_invalidate_status_capacity_cache` | 0 (local) | µs |
| 6 | `iscsi.extent.create` | 1 | 200–500 ms |
| 7 | `_clear_cache` | 0 (local) | µs |
| 8 | `_resolve_target_id` (cached after first call per process) | 0–1 | 10 ms or one query |
| 9 | `_tn_targetextent_create` (handles idempotency + "Extent in use" race) | 1, plus optional re-fetch for `lunid` | 200–500 ms |
| 10 | `_clear_cache` (again) | 0 (local) | µs |
| 11 | Schedule deferred work via `_defer_after_lock` | 0 (deferred) | µs |

**Net:** 4–6 TN round-trips under lock plus one optional job-wait. On
a healthy TN with the broker hot, total lock hold is typically
1.5–3 s. The N=10 test showed ~6.3 s median per child wall-clock and
~63 s batch elapsed for 10 sequential locked windows. On N=25 the
median jumped to ~91 s because each child waited longer in the lock
queue, but the lock-hold time per child likely didn't grow much.

## What runs OUTSIDE the lock

`_defer_after_lock` queues these to fire AFTER PVE releases the
storage lock. Lock holders never wait on them:

- iSCSI initiator login (`_iscsi_login_all`) if no session active.
- `iscsiadm -m session -R` rescan.
- `_iscsi_rescan_sd_capacity` (the LUN-recycle capacity refresh from
  commit `e9e8441`).
- `multipath -r` reload.
- `udevadm settle`.
- Best-effort `_device_for_lun` readiness poll with ~250 ms retries.

This is why the broker improvement and the rescan/multipath/udev work
are orthogonal: they cut total operation latency but the cfs-lock
window only contains the TN API calls.

## Why locks queue past the budget

Single-storage serialization is structural to PVE's storage plugin
contract. `cluster_lock_storage` is acquired before `alloc_image` (and
`free_image`, `clone_image`, `volume_resize`, etc.) for safety:
multiple concurrent allocs on the same storage need consistent views
of dataset names, LUN assignments, and the storage's free-space
accounting. PVE's default 10 s timeout assumes plugin work under lock
is sub-second. ZFS-backed plugins regularly exceed that, which is why
the override exists.

At observed 5–7 s lock-hold per alloc:

| Concurrency (N) | Worst-case wait | Fits in 120 s budget? |
|---|---|---|
| 1 | 0 s | trivially |
| 5 | 25–35 s | yes |
| 10 | 50–70 s | yes |
| 17 | 85–119 s | edge |
| 20 | 100–140 s | sometimes (N=25 saw 5/25 fail) |
| 25 | 125–175 s | no |
| 50 | 250–350 s | no (exceeds schema max of 600 even at the low end if hold time grows) |

`tn_storage_lock_timeout` schema maximum is 600 s. That permits roughly
N ≤ 85–120 before hitting the ceiling. Past that, only structural
changes (reduce lock-hold time, allow parallel allocs) help.

## Reducing lock-hold time

Cheapest wins first.

1. **Coalesce the three writes into one `core.bulk` call.** Steps 3
   (dataset.create), 6 (extent.create), and 9 (targetextent.create) are
   three sequential round-trips. The plugin already has
   `_api_bulk_call` — a single `core.bulk` round trip would replace
   three.

   Saves: ~1–1.5 s per alloc just on broker/WS-frame round-trip
   overhead. Bigger saving on cold WS (~3 s).

   Cost: `core.bulk` semantics require the three calls to succeed or
   fail together, and rollback on partial failure is more complex
   (current code does explicit cleanup of zvol if extent.create fails,
   and cleanup of extent + zvol if targetextent.create fails). Bulk
   makes rollback all-or-nothing from TN's side but moves error
   classification into post-hoc inspection.

2. **Verify `_resolve_target_id` cache hit rate.** Step 8 should be a
   no-op after the first alloc of a given process. If it's miss-prone,
   each alloc adds a query.

3. **Move local cache invalidations outside the lock.** `_clear_cache`
   in steps 7 and 10 mutates process-local cache state. No other
   process under the cluster lock cares. Releasing the lock first
   shaves microseconds; not a perf win, but tidier.

4. **Investigate `_preflight_check_alloc`.** Step 1 is documented as
   "cached pool health" via `_tn_pool_health` (commit `8f6d269`), but
   the free-space check might still issue a query. Worth profiling
   under contention to confirm.

5. **Slow `pool.dataset.create` is the largest single cost.** If TN
   returns a job ID, step 4 waits up to 10 s. Empirically this happens
   under load (lots of concurrent zvol creates). No client-side fix;
   would need TN middleware changes to make zvol-create synchronous
   when possible.

## Allowing parallel allocs

Structural change, larger risk. Would require:

- Replace per-storage cfs-lock with per-disk-name lock so only
  conflicting `vm-<vmid>-disk-N` names serialize.
- Make `_find_free_disk_name` race-tolerant. Current code already
  retries on "dataset already exists" up to 5 times; that hint that
  the lock isn't strictly required for naming exclusion.
- Audit free-space accounting paths to ensure no read-modify-write
  pattern relies on the storage-wide lock.

Not recommended unless N >> 25 concurrent is a real workload. Easier
to raise `tn_storage_lock_timeout` for now (it's a 1-line storage.cfg
edit) and accept the serialization.

## Tunable cheat-sheet

For N concurrent allocs on a single storage:

```ini
truenasplugin: truenas-storage
    tn_api_host 192.168.1.68
    tn_api_key ...
    tn_dataset tank/proxmox
    tn_storage_lock_timeout 300    # safe up to ~50 concurrent
```

Max usable today: `tn_storage_lock_timeout 600` → ~85–120 concurrent
allocs on the same storage before failures, depending on TN-side
latency. Past that, file an issue and we look at structural changes.

## See also

- `wiki/D2-per-process-reauth.md` — why the broker exists.
- `wiki/Broker-Tests.md` — `t/rate-limit/08-concurrent-alloc.t`
  exercises this code path; the N=25 failure is the prompt for this
  document.
- Commit `36f1eec` ("Extended concurant operations timeout") —
  introduced `tn_storage_lock_timeout` and the
  `DEFAULT_LOCK_TIMEOUT = 120` constant.
- Commit `f9b4b12` ("Prefix all storage.cfg keys with tn_ to avoid
  namespace collisions") — renamed `storage_lock_timeout` →
  `tn_storage_lock_timeout`.
