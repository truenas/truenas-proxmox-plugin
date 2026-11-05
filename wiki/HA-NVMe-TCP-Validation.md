# NVMe/TCP HA failover validation — 2026-10-08

Validation record for the plugin's TrueNAS HA NVMe/TCP failover story,
including the environment, methodology, raw numbers, and reproduction
notes. Companion to [`HA-Transport-Comparison.md`](HA-Transport-Comparison.md)
and the `tn_nvme_manage_ports` option in
[`Configuration.md`](Configuration.md).

## Why this record exists

Before 2026-10-08, our documented HA failover story on this plugin
covered iSCSI only. NVMe/TCP against a real two-controller TrueNAS HA
pair was not tested at our end. This document closes that gap, with 50
forced controller power-cycles against a production-shape HA pair and
continuous fio I/O
running through them.

## Environment

**TrueNAS HA pair** (`h10-149a` / `h10-149b`):

- Model class: NVMe-oF capable, dual-controller
- TrueNAS SCALE: 25.10.4 (stable; pre-dates the NAS-140266 nvmet
  model-rewrite fix that lands in 26.0.0-BETA.3, and pre-dates the
  kernel nvmet-tcp `.get_mdts` fix needed for >1 MB transfers)
- Controller A regular IP: `10.220.16.189`, IPMI/BMC: `10.220.2.97`
- Controller B regular IP: `10.220.16.190`, IPMI/BMC: `10.220.2.98`
- Management + nvmet port label VIP: `10.220.16.188`
- Pool: `tank` (ONLINE, ~3.97 TiB, healthy)
- Test dataset: `tank/proxmox-ha-test` (FILESYSTEM; plugin provisions
  per-VM zvols under it)
- Subsystem NQN:
  `nqn.2011-06.com.truenas:uuid:10a3f89e-c1dc-4df6-95bb-d60caedb9976:proxmox-ha-test`
  (`allow_any_host: true` for test-rig convenience)

**TrueNAS nvmet pre-provisioning (admin-managed, kept constant across the
run):**

- `nvmet.global.update {ana: true}` — ANA state advertisement on
- One `nvmet.port` record (`id=1`) with `addr_traddr=10.220.16.188`
  (VIP), `addr_trtype=TCP`, `addr_trsvcid=4420`
- One `nvmet.port_subsys` binding this port to the subsystem

TrueNAS renders that single port on both controllers; each binds its own
physical IP (189 on A, 190 on B) and advertises its ANA state. The
initiator discovers via one physical and walks the `xport_referral`
list to pick up the other.

**Proxmox host (initiator):**

- PVE 9.1 on `pve` (`192.168.1.154`), part of a 3-node cluster
- Storage entry scoped to `nodes pve` only
- WireGuard tunnel `wg0_ix-TN` → routes `10.0.0.0/8` toward `10.150.16.239`
- `nvme-cli 2.13-2`
- Plugin: `truenas-proxmox-plugin 2.1.24~alpha1` from branch
  `fix/nvme-ha-manage-ports`, commit `daa8d1a` (md5 of installed
  `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`:
  `d7e4647b4b56436af0842c8ac45c9496`)

**Plugin configuration (storage.cfg stanza, redacted):**

```ini
truenasplugin: truenas-ha-nvme
    tn_api_host 10.220.16.188
    tn_api_key <...>
    tn_dataset tank/proxmox-ha-test
    tn_transport_mode nvme-tcp
    tn_discovery_portal 10.220.16.189:4420
    tn_subsystem_nqn nqn.2011-06.com.truenas:uuid:10a3f89e-c1dc-4df6-95bb-d60caedb9976:proxmox-ha-test
    content images,rootdir
    shared 1
    tn_zvol_blocksize 16K
    tn_nvme_manage_ports 0
    tn_api_insecure 1
    nodes pve
```

Notes on fields that matter for HA correctness:

- `tn_nvme_manage_ports 0` — required. The plugin's default (`=1`)
  tries to register one `nvmet.port` per configured portal with the
  physical IP; TN 25.10.x's `nvmet` middleware `map_attrs()` rejects
  non-VIP `addr_traddr` values with a `KeyError`, aborting
  `write_config()` and leaving namespaces unpublished in configfs.
- `tn_discovery_portal` points at a controller **physical IP** rather
  than the VIP. TN's nvmet-tcp socket binds to the local physical IP on
  each head, not the VIP; a TCP connect to the VIP:4420 is refused. The
  initiator must land on a physical, then walk referrals to pick up the
  other physical.
- `tn_api_host` points at the VIP (management plane).
- `tn_api_insecure 1` — the controllers use iX-internal certs that the
  PVE host does not trust.

**Initiator-side kernel tuning (manual, applied at setup):**

Each namespace device's `max_sectors_kb` set to `1024` before any I/O
starts, to protect against the TN 25.10.4 nvmet-tcp missing-`.get_mdts`
corruption window for >1 MiB transfers (fixed upstream in later
kernels; see memory `project_issue_96_nvmet_mdts`).

## What was tested

Scope: this run validates the plugin's data path on an HA pair across
forced controller power-cycles, with the recorded fio workload below.
It does not exercise the plugin's own reconnect gates
(`_nvme_device_for_uuid` at `i==10/25/35/75/125/150`); a controller
power-cycle is a kernel NVMe session event, not a plugin reconnect.

Exercised in each iteration:

- plugin `activate_storage` + `alloc_image` (namespace create via
  `nvmet.namespace.create` with `subsys_id` of the admin-provisioned
  subsystem) + `path` resolution + initiator connect
- kernel NVMe multipath (nvme-core, ANA)
- controller failover simulated by `ipmitool chassis power cycle` on
  the current MASTER controller's BMC
- post-recovery wait for both paths back `live` before next iteration

Nothing involving the plugin's broker, the TN API retry engine, nor
the subsystem/port management was modified during the run.

## Methodology

Driven by `tools/ha-testing/ha-nvme-test-50.sh` (contents preserved
in-tree). Each of 50 iterations does:

1. `pvesm alloc truenas-ha-nvme 9800 vm-9800-disk-0 10G` — plugin
   creates one 10 GiB zvol + one `nvmet.namespace` under the admin
   subsystem; namespace renders into configfs on both heads.
2. Pin `max_sectors_kb=1024` on the backing `nvmeNnM` device.
3. Start a background ANA-state logger
   (`nvme list-subsys -o json` every 500 ms) + `dmesg -w` tap.
4. Start fio with `direct=1 iodepth=16` and a per-iter workload (see
   workload table below), total runtime 300 s (60 s baseline + 240 s
   observation).
5. After 60 s baseline, query `failover.status` on both controllers via
   SSH-key-authenticated midclt; the one answering `MASTER` is the
   target. `ipmitool -I lanplus chassis power cycle` on that BMC.
6. Let fio run to completion; collect `fio-result.json` + per-500 ms
   bandwidth log (`fio-bw_bw.1.log`).
7. `pvesm free` the test volume.
8. Cool-down: poll `nvme list-subsys -o json`; wait for exactly two
   paths back `live` before starting the next iteration.

**Workload table (iter → fio arguments):**

| Iter range | `rw` | `bs` | `iodepth` | `rwmixread` | notes |
|---|---|---|---|---|---|
| 1–30, 39–50 | randrw | 16k | 16 | 70 | steady-state baseline |
| 31 | write | 1M | 4 | — | large seq-write |
| 32 | randread | 4k | 1 | — | small-block low-qd read |
| 33 | randwrite | 4k | 1 | — | small-block low-qd write |
| 34 | randread | 128k | 1 | — | medium-block low-qd read |
| 35 | randwrite | 128k | 1 | — | medium-block low-qd write |
| 36 | randrw | 16k | 32 | 50 | symmetric high-qd mix |
| 37 | randwrite | 4k | 16 | — | fsync=1 (sync-every-write) |
| 38 | randwrite | 64k | 16 | — | mid-block |
| 39 | randrw | 16k | 16 | 70 | 120 s baseline (longer warmup) |

Alternation between controllers A and B is driven by the real failover
state after each iteration: cycling the current master → MASTER
transfers to the other head → next iter targets the new master →
perfect A/B/A/B rotation across 50 iters (25 each).

## Results

**Headline: 50 / 50 PASS. Zero fio errors. Pause times 11.5 s – 25.5 s,
average 20.6 s, median 20.0 s, p95 25.0 s.**

Aggregate (from `AGGREGATE.txt`):

```
n=50  min=11500ms  max=25500ms  avg=20590ms  median=20000ms  p95=25000ms
total fio errors: 0
target split: 25× A, 25× B
```

Distribution notes:

- Most iters cluster in a tight 19.5 – 20.5 s band — the "clean" ANA
  transition + pool-import floor.
- A small group lands at 24.5 – 25.5 s — likely iterations where the
  pool import on the surviving controller took the full 15 s window
  rather than finishing early.
- Iter 37 (fsync-heavy randwrite 4k qd=16) is the outlier at the low
  end: **11.5 s**. With `fsync=1` every write is committed before the
  next is issued, so there are far fewer in-flight commands to resync
  across the ANA transition. The result is less "drain time" eaten by
  the kernel re-dispatching queued I/O.
- The large-block workloads (1 M seq-write, 128 k randwrite) sit
  near the mean, not the tail. Block size does not meaningfully push
  the failover window up at these depths.

**Observed kernel log patterns (benign, consistent across all 50 iters):**

- `nvme nvmeN: Failed reconnect attempt X/60 … Reconnecting in 10
  seconds` — the dying controller's session retries while the hardware
  is POSTing. Expected and does not affect fio.
- `nvme nvmeN: Successfully reconnected (attempt N/60)` — session back
  up after the controller boots (~140 s after the power cycle).
- `nvme2cCn1: I/O Cmd(0x2) … "Invalid Namespace or Format" MORE DNR` —
  async page-read / udev scan hitting the per-controller NS view
  during post-reconnect rescan. Not on the fio data path (fio opens
  the top-level multipath device `/dev/nvmeNnM`, which transparently
  reroutes to the surviving path). See
  [`HA-Transport-Comparison.md`](HA-Transport-Comparison.md) for why
  this does not surface as application-level errors.

These are kernel-side messages. A `Successfully reconnected` line means
the kernel NVMe controller re-established its session; it is not
evidence that the plugin's `_nvme_device_for_uuid` reconnect gates
fired. This run did not intentionally trigger those gates.

**Spot-checked fio-result.json for several iterations:**

```
iter-01  {"error":0, "read_ios":31170, "write_ios":13307}
iter-25  {"error":0, "read_ios":31031, "write_ios":13240}
iter-37  {"error":0, "read_ios":0,     "write_ios":4161}   # pure randwrite + fsync=1
iter-50  {"error":0, "read_ios":26082, "write_ios":11149}
```

`error`, `read.errors`, and `write.errors` are 0 / `null` on every
spot check. fio reports no I/O errors on any iteration.

## Caveats

Scope boundaries this run does not cover:

- **TrueNAS 26.0 / 27.0** — this run is on 25.10.4. **The
  `tn_nvme_manage_ports 0` requirement is NOT removed in 26.0.0 /
  27.0.0.** NAS-140266 (landed in 26.0.0-BETA.3+) fixed a different
  nvmet middleware bug — the `attr_model` trailing-space rewrite that
  broke namespace export on ARM. The bug driving the knob here lives
  in `nvmet/kernel.py` `map_attrs()` (now
  `utils/nvmet/render_common.py` `addr_traddr_to_address()` in 26.0+):
  the ANA-port branch does `choices[addr_traddr].split('/')` against a
  dict keyed by TN's registered managed addresses (the VIPs); a port
  whose `addr_traddr` is a physical controller IP trips a `KeyError`
  that aborts `write_config()` and leaves namespaces unpublished.
  Verified identical semantics in `release/26.0.0-BETA.3`,
  `release/26.0.0-RC.1`, and `release/27.0.0-RC.1`. A separate TN
  middleware change — accept physical-IP `addr_traddr` values, or
  switch the plugin's HA strategy to auto-detect — would be required
  to retire the knob. See
  [`HA-Transport-Comparison.md`](HA-Transport-Comparison.md) and the
  per-release scan recorded in-session on 2026-10-09.
- **FC and RDMA transports** — only TCP was exercised.
- **SPDK target mode** — kernel nvmet only.
- **Concurrent VMs and heavier I/O depths** — single fio, one storage,
  one namespace per iter. A busy cluster with many VMs doing
  concurrent I/O during failover may see different pause
  distributions.
- **Chaos overlay** — this run isolated the failover event. Our
  previous iSCSI validation ran chaos (broker kill, net-drop, iscsi
  logout/login) concurrently with fio. Combining chaos with HA
  failover for NVMe/TCP is a future test.
- **Longer soak** — 50 iters is about 4.5 wall-clock hours. A
  multi-day soak would hit edge cases this run cannot reach.
- **Non-root initiators / minimum-privilege API keys** — the plugin
  API key used here has broad access. Behavior with a locked-down
  key is not covered.

## Reproduction

Harness scripts preserved in the repo under `tools/ha-testing/`:

- `tn-ha-nvme-setup.sh` — one-shot TN pre-provisioning (enable ANA,
  create dataset, create subsystem, create one VIP-based port, bind
  them).
- `ha-nvme-test-50.sh` — the 50-iter harness used for this record.

To rerun:

1. Pre-provision TN once per HA pair:
   ```bash
   ssh truenas_admin@<MASTER> 'bash -s' <tools/ha-testing/tn-ha-nvme-setup.sh
   ```
   This writes the subsystem NQN + VIP + binding; the plugin takes it
   from there.
2. Push the PVE SSH pubkey to `truenas_admin` on both controllers so
   the harness's `failover.status` queries work.
3. Set `tn_nvme_manage_ports 0` in the storage.cfg entry (see
   `storage.cfg.example` for a full HA stanza).
4. Set `IPMI_PASS=<...>` in the environment and launch:
   ```bash
   ssh root@pve 'nohup /path/to/ha-nvme-test-50.sh </dev/null \
     >/tmp/ha-run.log 2>&1 & disown'
   ```
5. Results land under `/root/ha-nvme-tests/run50-<ts>/`:
   - `wrapper.log` — per-iter progress and verdicts
   - `AGGREGATE.txt` — pass/fail summary table
   - `iter-NN/` — per-iter fio output, bandwidth log, ANA state log,
     dmesg tap, failover timestamp

## Related artifacts

- Plugin patch: `tn_nvme_manage_ports` knob, shipping in
  `2.1.24~beta3`.
- Transport comparison background:
  [`HA-Transport-Comparison.md`](HA-Transport-Comparison.md).
