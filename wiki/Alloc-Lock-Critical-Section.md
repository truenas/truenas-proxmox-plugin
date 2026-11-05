# Alloc critical section and cluster lock

Analysis of what happens during a single `alloc_image` call, and where
the wall-clock goes. The plugin **bypasses** PVE's per-storage CFS
`cluster_lock` by default (`tn_use_cluster_lock` defaults to `0`,
`TrueNASPlugin.pm:873-897,11116-11159`). Concurrent allocs on the same
storage therefore run in parallel, and TrueNAS itself serializes
conflicting mutations.

Setting `tn_use_cluster_lock 1` opts back into PVE's classic
serialization. The lock-wait numbers in this document apply only in
that mode.

## Why this matters

The N=25 concurrent-alloc test (`t/rate-limit/08-concurrent-alloc.t`,
ran with `RL_CONCURRENT_N=25`) failed with 5/25 children timing out on
`cfs lock 'storage-<id>'`. That symptom is only possible when
`tn_use_cluster_lock 1` is set; with the default bypass there is no CFS
lock to time out on.

For the locked mode: PVE's `cluster_lock_storage` serializes every
`alloc_image` call per storage. The plugin already raises PVE's default
10 s timeout to 120 s via the `tn_storage_lock_timeout` config knob
(`DEFAULT_LOCK_TIMEOUT = 120`, schema `minimum => 10, maximum => 600`).
At ~5-7 s serialized work per call, the 17th and later children at N=25
exceeded the 120 s window.

The broker held the line on the TN side — **0 upstream
`auth.login_with_api_key` calls** across the entire 25-concurrent burst.
So the bottleneck in that run was PVE-side serialization, not TN
rate-limiting.

## Allocation path: `alloc_image`

With the default bypass, `cluster_lock_storage` runs the callback
directly. With `tn_use_cluster_lock 1`, it calls
`SUPER::cluster_lock_storage` and the same callback runs under the CFS
lock. Either way the order of operations is:

| Step | Operation | TN round-trips | Typical cost |
|------|-----------|----------------|--------------|
| 1 | `_preflight_check_alloc` (pool health + free-space + sanity) | 1-3 (mostly cache hits via `_tn_pool_health`) | 50-200 ms |
| 2 | `_find_free_disk_name` if no name supplied (lists zvols, scans for free `vm-<vmid>-disk-N`) | 1 (`pool.dataset.query`) | 100-300 ms |
| 3 | `pool.dataset.create` for the zvol | 1 (sync or job-returning) | 500 ms - 2 s |
| 4 | `_wait_for_job_completion` if step 3 returned a job ID | poll loop, 1-5 polls | up to 5-10 s on slow TN |
| 5 | `_invalidate_status_capacity_cache` | 0 (local) | µs |
| 6 | `iscsi.extent.create` | 1 | 200-500 ms |
| 7 | `_clear_cache` | 0 (local) | µs |
| 8 | `_resolve_target_id` (cached after first call per process) | 0-1 | 10 ms or one query |
| 9 | `_tn_targetextent_create` (handles idempotency + "Extent in use" race) | 1, plus optional re-fetch for `lunid` | 200-500 ms |
| 10 | `_clear_cache` (again) | 0 (local) | µs |
| 11 | Schedule deferred work via `_defer_after_lock` | 0 (deferred) | µs |

**Net:** 4-6 TN round-trips per allocation plus one optional job-wait.
On a healthy TN with the broker hot, the body takes typically 1.5-3 s.
With the CFS lock enabled, those seconds are serialized per storage:
the N=10 test showed ~6.3 s median per child wall-clock and ~63 s batch
elapsed for 10 sequential windows. At N=25 the median jumped to ~91 s
because each child waited longer in the CFS queue. With the default
bypass there is no queue, and those batch numbers do not apply.

### Reading `LOCKHOLD` lines

The plugin's `LOCKHOLD alloc_nvme_deferred`, `LOCKHOLD activate_volume`,
and `LOCKHOLD clone_nvme_deferred` log lines timestamp phases of work
that runs while PVE's **VM config lock** is held (`qm start`, clone
target, and similar operations). They are phase timings for that block,
not measurements of CFS storage-lock hold time. With the default bypass
there is no CFS lock in this path.

## Deferred work after the allocation

`_defer_after_lock` queues these to run after the allocation callback
returns, after PVE releases the storage lock when the lock is enabled,
or immediately after the callback with the default bypass:

- iSCSI initiator login (`_iscsi_login_all`) if no session active.
- `iscsiadm -m session -R` rescan.
- `_iscsi_rescan_sd_capacity` (the LUN-recycle capacity refresh from
  commit `e9e8441`).
- `multipath -r` reload.
- `udevadm settle`.
- Best-effort `_device_for_lun` readiness poll with ~250 ms retries.

This is why the broker improvement and the rescan/multipath/udev work
are orthogonal: they cut total operation latency but the CFS-lock
window, when enabled, only contains the TN API calls.

## What the lock does when enabled

In the classic PVE model that `tn_use_cluster_lock 1` restores,
`cluster_lock_storage` is acquired before `alloc_image` (and
`free_image`, `clone_image`, `volume_resize`, etc.) for safety:
multiple concurrent allocs on the same storage need
consistent views of dataset names, LUN assignments, and the storage's
free-space accounting. PVE's default 10 s timeout assumes plugin work
under lock is sub-second. ZFS-backed plugins regularly exceed that,
which is why the override exists.

The plugin bypasses that lock by default because TrueNAS's middleware
already serializes conflicting mutations (`iscsi.extent.create`
name-uniqueness, `iscsi.targetextent` LUN assignment, ZFS dataset name
uniqueness) and the plugin's Fix 1 (alloc-time extent reuse), Fix B
(post-hoc name-conflict recovery), and dataset-already-exists
auto-increment cover residual PVE-side races. A 2026-08-17 3-node run
measured >2 min queue wait for the CFS lock while other nodes' allocs
held it, pushing the test client's PUT past pveproxy's 60 s ceiling.

With `tn_use_cluster_lock 1` and observed 5-7 s serialized work per
alloc:

| Concurrency (N) | Worst-case wait | Fits in 120 s budget? |
|---|---|---|
| 1 | 0 s | trivially |
| 5 | 25-35 s | yes |
| 10 | 50-70 s | yes |
| 17 | 85-119 s | edge |
| 20 | 100-140 s | sometimes (N=25 saw 5/25 fail) |
| 25 | 125-175 s | no |
| 50 | 250-350 s | no (well past the 120 s default; needs the 600 s upper bound) |

`tn_storage_lock_timeout` schema maximum is 600 s. In locked mode that
permits roughly N ≤ 85-120 before queue waits hit the ceiling. Past
that, only reducing allocation time or removing the lock helps, and
removing the lock is the default.

## Reducing allocation time

Cheapest wins first. Each also reduces TN load in bypass mode.

1. **Coalesce the three writes into one `core.bulk` call.** Steps 3
   (dataset.create), 6 (extent.create), and 9 (targetextent.create) are
   three sequential round-trips. The plugin already has
   `_api_bulk_call` — a single `core.bulk` round trip would replace
   three.

   Saves: ~1-1.5 s per alloc just on broker/WS-frame round-trip
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

3. **Move local cache invalidations out of the critical path.**
   `_clear_cache` in steps 7 and 10 mutates process-local cache state.
   No other process cares. Skipping the work until after the callback
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

## When to enable the lock

Leave `tn_use_cluster_lock 0` unless you observe correctness issues on
a nonstandard TN configuration where the middleware's own
serialization cannot be trusted. Enabling the lock restores PVE-side
serialization but reintroduces the queue wait that the default
bypasses.

## Tunable cheat-sheet

```ini
truenasplugin: truenas-storage
    tn_api_host 192.168.1.68
    tn_api_key ...
    tn_dataset tank/proxmox
    tn_use_cluster_lock 0          # default: bypass, allocs run in parallel
    # tn_storage_lock_timeout 300  # only read when tn_use_cluster_lock 1
```

With the default bypass there is no lock timeout to tune; throughput is
bounded by TrueNAS-side serialization. If you opt into
`tn_use_cluster_lock 1`, `tn_storage_lock_timeout 600` permits roughly
~85-120 concurrent allocs on the same storage before queue waits exceed
the budget, depending on TN-side latency.

## See also

- `wiki/D2-per-process-reauth.md` — why the broker exists.
- `wiki/Broker-Tests.md` — `t/rate-limit/08-concurrent-alloc.t`
  exercises this code path; the N=25 failure on the locked path is the
  prompt for this document.
- Commit `36f1eec` ("Extended concurant operations timeout") —
  introduced `tn_storage_lock_timeout` and the
  `DEFAULT_LOCK_TIMEOUT = 120` constant.
- Commit `f9b4b12` ("Prefix all storage.cfg keys with tn_ to avoid
  namespace collisions") — renamed `storage_lock_timeout` →
  `tn_storage_lock_timeout`.
