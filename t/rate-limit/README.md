# Rate-limit regression tests

Targets four defects identified in `wiki/Test-Plan-Detail.md` §5.1:

- **D1** — every write opens a fresh WS and re-authenticates.
- **D2** — every forked PVE process re-authenticates.
- **D3** — `Rate Limit Exceeded` is in the retryable error class, so a throttled write fires more logins inside the same lockout window.
- **D4** — `DEVICE_READY_TIMEOUT_US = 100 ms` pre-login sleep is cosmetic.

Tests run against a real TrueNAS. No mock.

## Prerequisites

Runner must be a real Proxmox VE node with the plugin installed and a working storage entry pointing at the TrueNAS under test.

Required environment variables:

| Variable | Meaning |
|---|---|
| `TN_HOST` | TrueNAS management hostname or IP |
| `TN_API_KEY` | API key with read access + write access for audit.query |
| `STORAGE_ID` | PVE storage ID configured for this TrueNAS (e.g. `truenas-main`) |
| `TEST_VMID_BASE` | starting VMID (default `99000`) — keep high to avoid collision |

Optional:

| Variable | Meaning |
|---|---|
| `TN_LOGIN_COUNT_METHOD` | `audit` (default) — count via `audit.query`. Falls back to `journal` if API absent. |
| `TN_SSH_HOST` | TrueNAS SSH host (required only if `TN_LOGIN_COUNT_METHOD=journal`) |
| `TN_SSH_USER` | TrueNAS SSH user (default `root`) |
| `TN_SSH_KEY` | path to SSH private key |
| `DRAIN_SECS` | seconds to wait between tests for limiter to reset (default `90`) |
| `KEEP_RESOURCES` | `1` = skip cleanup on failure (for triage). Default `0`. |

## Run

```
cd /path/to/truenas-proxmox-plugin
sudo -E env TN_HOST=... TN_API_KEY=... STORAGE_ID=truenas-main t/rate-limit/run.sh
```

Or source an env file:

```
cat > /root/rltest.env <<EOF
export TN_HOST=10.220.13.138
export TN_API_KEY=1-xxxxx
export STORAGE_ID=truenas-main
export TEST_VMID_BASE=99000
EOF

source /root/rltest.env
sudo -E t/rate-limit/run.sh
```

`sudo` needed because `pvesm` and `pvesh` require root to invoke the plugin's writer paths.

## What each test asserts

| Test | Defect | Assertion | Current behavior |
|---|---|---|---|
| `01-d1-single-write.t` | D1 | One `alloc_image` triggers ≤ 1 `auth.login_*` | fails — emits ~3 logins |
| `02-d1-burst-deathspiral.t` | D1 + D3 | 8 sequential allocs trigger ≤ 1 login total, zero EBUSY | fails — ~24 logins, EBUSY mid-burst |
| `03-d2-per-process.t` | D2 | 10 parallel `pvesh status` calls trigger ≤ 1 login total | fails — each child re-auths |
| `04-d3-retry-amplification.t` | D3 | After pre-tripping limiter, one `pvesm alloc` does NOT emit additional logins | fails — plugin retries `Rate Limit Exceeded` |
| `05-session-reuse.t` | positive control | 100 mixed plugin ops in one process = exactly 1 login | confirms baseline reuse where it does work |

After fixing D1–D4, every test in this suite goes green without changing the test files.

## Resource hygiene

- Tests allocate at VMIDs `TEST_VMID_BASE..TEST_VMID_BASE+99`.
- Each test cleans up its own volumes.
- Suite runs an orphan reaper before starting that deletes any volume on `$STORAGE_ID` whose VMID falls in the test range. Survives prior-run crashes.
- If `KEEP_RESOURCES=1`, cleanup is skipped after the first failure so the orphan state can be inspected.

## Why these tests live in `t/`

Perl convention: `prove -rv t/rate-limit/` runs every `*.t` in deterministic order (sorted by filename). `lib/` next to the tests is auto-added to `@INC` by `prove`.
