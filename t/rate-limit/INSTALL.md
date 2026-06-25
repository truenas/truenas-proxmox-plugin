# Installing the fix on a PVE node for tests

Run on the PVE test node as root.

This branch (`fix/rate-limit-connection-reuse`) addresses D1, D3, and D4 by
routing every plugin call through `_ws_get_persistent` and reclassifying
`Rate Limit Exceeded` as non-retryable. D2 (cross-process re-auth) is NOT
addressed here — for that, use the `broker-service` branch which ships a
session-broker daemon.

## 1. Install the patched plugin

```
install -m 644 TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
systemctl restart pvedaemon pveproxy pvestatd
```

## 2. Install the test suite

```
mkdir -p /root/t
cp -r t/rate-limit /root/t/
```

## 3. Configure environment

The plugin on this branch uses `tn_*`-prefixed storage.cfg keys (`tn_api_host`,
`tn_api_key`, `tn_api_scheme`, `tn_api_port`, `tn_api_insecure`,
`tn_prefer_ipv4`, etc). The harness reads the actual key names via
`pvesh get /storage/<id>` and emits both old and new aliases into the
in-process `$scfg`, so no manual translation is needed.

```
export TN_HOST=192.168.1.68
export TN_API_KEY=1-...
export STORAGE_ID=truenas-storage
export TEST_VMID_BASE=99000
```

## 4. Run the rate-limit suite

```
DRAIN_SECS=90 bash /root/t/rate-limit/run.sh
```

## What to expect

| Test | Pre-fix | This branch |
|---|---|---|
| 00 prereqs | PASS | PASS |
| 01 D1 single write | FAIL (~3 logins) | PASS (1 login — write rides persistent socket) |
| 02 D1 burst (8 qm) | FAIL (~24 logins + EBUSY) | PASS (≤ 8 logins — 1 per qm process; pre-fix was 3+× per process plus retries) |
| 03 D2 per-process | FAIL (10 logins) | FAIL (still 10 — plugin needs cross-process session sharing) |
| 04 D3 retry | FAIL (3 amplified logins) | PASS (no retry on EBUSY) |
| 05 reuse | PASS | PASS |
| 99 counter probe | PASS | PASS |

## Differences from broker-service branch

| Mechanism | broker-service | fix/rate-limit-connection-reuse |
|---|---|---|
| Per-process session | persistent WS per process + session-broker proxies all to one upstream | persistent WS per process; each process re-auths |
| Write op routing | rides persistent or broker | rides persistent (`_api_call_mutate`) |
| Rate-limit classifier | dedicated `_is_rate_limit_error` | dropped from `_is_connection_error`; non-retryable via default |
| Ephemeral connections | none | none (`_ws_open_ephemeral` removed) |
| 100 ms pre-login sleep | removed | removed from login path; retained in device-discovery paths |

## Rollback

```
apt install --reinstall truenas-proxmox-plugin
systemctl restart pvedaemon pveproxy pvestatd
```
