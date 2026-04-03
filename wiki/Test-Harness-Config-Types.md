# Test Harness `--config` Types

The `--config` flag maps to a hardware profile. It determines the minimum hardware required to run and which hard gates are enforced. It does not change which test functions run.

| Config | Required Tiers | Hard Gates | Meaning |
|--------|---------------|------------|---------|
| `A` | Tier 1 only | T1-01 | Single-node, basic iSCSI — the minimum setup |
| `D` | Tier 1 + 2 | T1-01, T2-03 | Single-node with multipath (`use_multipath 1` + `portals` in storage.cfg, `multipathd` running) |
| `F` | Tier 1 + 3 | T1-01, T3-04 | Single-node + 3-node cluster (no multipath required) |
| `H` | Tier 1 + 4 | T1-01, T4-04 | TrueNAS Enterprise HA — licensed HA pair reachable via VIP |
| `G` | Tier 1 + 5 | T1-01, T5-04 | ALUA + HA — HA pair with dual-portal multipath and IPMI access for crash failover |
| `all` | Tier 1 + 2 + 3 + 4 + 5 | T1-01, T2-03, T3-04, T4-04, T5-04 | Everything — multipath + cluster + HA + ALUA |

B, C, and E are not defined and fall through to the default (same as A: tier 1, T1-01 hard gate only).

## Hardware Detection

`detect_max_tier` inspects the live environment to determine what tier the hardware supports:

- **Tier 1**: `pvesh` is available and the named storage is active in `pvesm status`
- **Tier 2**: Tier 1 + `multipathd` is active + `use_multipath 1` and `portals` are present in `storage.cfg`
- **Tier 3**: Tier 1 + `pvecm` reports at least 3 cluster nodes, all SSH-reachable as root
- **Tier 4**: Tier 1 + `failover.licensed` returns `true` via the TrueNAS API (Enterprise HA pair)
- **Tier 5**: Tier 4 + `use_multipath 1` in `storage.cfg` + at least 2 portals configured + `ipmi.conf` present with BMC credentials for both controllers

If the detected hardware does not meet the tiers required by `--config`, the harness aborts with exit code 2.
