# Test Suite Architecture

## Entry Point: `tools/run-tests.sh`

The harness is invoked as:
```bash
run-tests.sh --storage <name> --config <A|B|C|D|E|F> [--tier <1|2|3|all>] [--yes]
```

**Startup sequence:**
1. Sources `tools/lib/common.sh` (shared utilities)
2. Sets a `trap 'iptables_cleanup_all' EXIT INT TERM` so any iptables DROP rules added during tests are always removed, even on Ctrl+C
3. Opens a timestamped log file in `/tmp/`
4. Calls `detect_max_tier` — inspects the hardware to determine whether this is a single-node (tier 1), multipath (tier 2), or cluster (tier 3) environment
5. Prompts for confirmation unless `--yes` is passed
6. Runs tiers in sequence: `run_tier1`, `run_tier2`, `run_tier3` (skipping tiers above what hardware supports)
7. Prints a summary of PASS/FAIL/SKIP counts and exits with code 0 (all pass), 1 (failures), or 2 (hard gate fired or pre-flight aborted)

---

## Shared Library: `tools/lib/common.sh`

Provides utilities used by all tiers:

- **`log_pass/fail/skip/warn/info`** — print prefixed messages to stdout and append timestamped lines to `$LOG_FILE`. `log_pass/fail/skip` also increment global counters (`PASS_COUNT`, `FAIL_COUNT`, `SKIP_COUNT`).
- **`read_storage_cfg_file <file> <storage_name> <key> [default]`** — parses Proxmox `storage.cfg` format with awk. The format is `<type>: <storage_name>` on the section header line followed by tab-indented `key value` pairs. Returns the value or the default.
- **`read_storage_cfg <storage_name> <key> [default]`** — calls the above against the live `/etc/pve/storage.cfg`.
- **`retry_window_seconds <max> <delay>`** — computes `(15 * max) + (delay * max) + 30`, the maximum time the plugin could take to exhaust retries. Used by T1-02 to set the recovery polling window.
- **`iptables_block/unblock/cleanup_all`** — manages DROP rules on the OUTPUT chain to simulate network failures. Tracks active rules in `_IPTABLES_BLOCKS[]` so they can all be removed on exit.
- **`ssh_run / ssh_reachable`** — runs commands on remote cluster nodes via SSH as root (used by tier 3).

---

## Tier 1: `tools/lib/tier1.sh` — Core Functional Tests

Requires only a single Proxmox node with an active TrueNAS storage.

**Pre-flight** (`tier1_preflight`): checks root, verifies the plugin file exists at `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm` and passes `perl -c`, confirms the storage is active in `pvesm status`. Aborts the tier on failure.

**Existing script wrapper** (`tier1_existing_script`): runs `tools/dev-truenas-plugin-full-function-test.sh` if present, translating its `[TEST]` tokens to `[INFO]` and accumulating its PASS/FAIL counts into the global totals.

**Individual tests:**

| ID | What it tests | How |
|----|--------------|-----|
| T1-01 | TLS config audit **(HARD GATE)** | Greps `storage.cfg` for `api_insecure 1`; blocks release if found |
| T1-02 | API retry under connection loss | Adds an iptables DROP for port 443, waits 5s, removes it, then polls `pvesm status` for up to `retry_window - 5` seconds to confirm recovery |
| T1-03 | Snapshot rollback data integrity | Creates a 1G volume, writes a marker, snapshots, overwrites, rolls back, verifies marker is restored |
| T1-04 | Orphan detection — clean path | Creates a VM with a disk, destroys with `--purge`, runs installer `--health-check`, expects zero orphans |
| T1-05 | Orphan detection — dirty path | Same but destroys *without* `--purge`, expects orphans to be detected |
| T1-06 | Debug logging | Temporarily enables `debug 1` in `storage.cfg`, restarts `pvedaemon`, triggers `pvesm status`, checks `journalctl` for `[TrueNAS]` entries |
| T1-07 | Volume naming uniqueness | Creates 5 disks in rapid succession for the same VMID, verifies 5 distinct names appear in `pvesm list`. Only fails on "Unable to find free disk name"; other pvesh errors (e.g. iSCSI device not accessible) are logged as warnings |

T1-04 and T1-05 skip automatically if the installer doesn't expose `--health-check` (detected via `--help` output).

---

## Tier 2: `tools/lib/tier2.sh` — Multipath / Resilience Tests

Only runs if `detect_max_tier` finds multipath hardware. Tests things like multipath failover, portal configuration, and ALUA handling. T2-03 is a hard gate (ALUA misconfiguration).

## Tier 3: `tools/lib/tier3.sh` — Cluster Tests

Only runs on a multi-node Proxmox cluster. Tests live migration, cross-node volume access, NVMe/TCP migration. T3-04 (NVMe/TCP migration) is a hard gate.

---

## Unit Tests: `tools/tests/`

Standalone scripts that run without any Proxmox infrastructure:

- **`test_common.sh`** — exercises `log_*` output format, `read_storage_cfg_file` parsing, and `retry_window_seconds` math against a tmpfile fixture
- **`test_arg_parsing.sh`** — verifies `run-tests.sh` CLI argument handling

These can be run anywhere with just bash. They use a `UNIT_TEST=1` guard in `run-tests.sh` to prevent it from actually executing the test harness when invoked by the arg-parsing tests.

---

## Hard Gates

Three tests return exit code 2 and set `HARD_GATE_FAILED=1`, which causes the summary to print `HARD GATE FAILED — release blocked`:

- **T1-01**: `api_insecure 1` present (TLS disabled)
- **T2-03**: ALUA misconfigured
- **T3-04**: NVMe/TCP migration unsupported

Any hard gate failure sets the final exit code to 2 regardless of other results.
