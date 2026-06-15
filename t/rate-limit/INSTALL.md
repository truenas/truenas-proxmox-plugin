# Installing the fix on a PVE node for tests

Run on the PVE test node as root.

## 1. Install the broker

```
install -m 755 tools/truenas-plugin-broker /usr/sbin/truenas-plugin-broker
install -m 644 debian/truenas-plugin-broker.service /etc/systemd/system/truenas-plugin-broker.service
systemctl daemon-reload
systemctl enable --now truenas-plugin-broker
systemctl status truenas-plugin-broker
```

Verify it's listening:

```
ls -l /run/truenas-plugin/broker.sock
journalctl -u truenas-plugin-broker -n 20 --no-pager
```

## 2. Install the patched plugin

```
install -m 644 TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
systemctl restart pvedaemon pveproxy pvestatd
```

## 3. Re-run the rate-limit suite

```
DRAIN_SECS=90 bash t/rate-limit/run.sh
```

## What to expect

| Test | Pre-fix | Post-fix |
|---|---|---|
| 00 prereqs | PASS | PASS |
| 01 D1 single write | FAIL (3 logins) | PASS (0–1 logins — write rides broker WS) |
| 02 D1 burst | FAIL (24 logins) | PASS (≤ 1 login — all 8 qm workers proxy through broker) |
| 03 D2 per-process | FAIL (10 logins) | PASS (≤ 1 login — all 10 forked pvesh proxy through broker) |
| 04 D3 retry | FAIL (3 amplified logins after trip) | PASS (unit + integration both ≤ 1) |
| 05 reuse | PASS | PASS |

## Rollback

If the broker misbehaves and you need to disable it:

```
systemctl stop truenas-plugin-broker
systemctl disable truenas-plugin-broker
rm -f /run/truenas-plugin/broker.sock
systemctl restart pvedaemon pveproxy pvestatd
```

Plugin then falls back to the legacy direct-WS path (with D1/D3/D4 fixes still
applied; D2 reverts to per-process re-auth).
