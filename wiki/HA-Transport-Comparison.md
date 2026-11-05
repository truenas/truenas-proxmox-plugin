# HA transport comparison — NVMe/TCP (ANA) vs iSCSI (ALUA)

Context for why the plugin's NVMe/TCP HA path behaves differently from its
iSCSI HA path, and why observed failover windows are tighter and more
consistent on NVMe/TCP. This is a reference note, not a tuning guide.
Specific tuning parameters live in [`Configuration.md`](Configuration.md).

## Structural differences

| | NVMe-oF ANA | SCSI ALUA (iSCSI + dm-multipath) |
|---|---|---|
| Spec | NVMe 1.4 (2019) | SPC-3 (2008) |
| State transition signal | Async event (controller sends Changed ANA via AER) | Polling (`polling_interval` on multipathd, default ~5 s) plus a Unit Attention race on the first I/O after a change |
| Transition handling | Kernel reroutes on next request completion | dm-multipath detects state change, runs `hwhandler alua`, re-dispatches queued I/O |
| Multipath layer | Built into `nvme-core`; sysfs-driven; no daemon | `dm-multipath` kernel module + userspace `multipathd` |
| Sessions during normal operation | **Both controllers connected simultaneously**, each advertising its own ANA state (`optimized` / `non-optimized`) | One iSCSI session per path; each path has its own TCP + login state |
| Failover action | Mark dying path `inaccessible`; use the already-open session on the surviving controller | Drop the dead session, dm-multipath flips path priority, re-dispatch I/O; the surviving session may need a relogin |
| Granularity | Per-namespace via ANAGRPID | Per-LUN via target-port-group |
| Userspace daemons | None (nvme-core is in-kernel) | `multipathd` + `iscsid` |

## Why NVMe/TCP + ANA tends to be smoother

The biggest practical win is at the **session layer**:

- NVMe/TCP keeps both controllers' sessions open at all times. When
  controller A dies, nvme-core already has a live session to B — it just
  stops dispatching to A. There is no TCP handshake or NVMe login on the
  surviving path, and no new block device for udev to probe.
- The plugin has its own reconnect paths, and they are guarded.
  `_nvme_device_for_uuid` retries device discovery at `i==10`, `25`,
  `35`, `75`, `125`, and `150`. The `i==10/25/35/75` gates skip a
  disruptive reconnect when any device on the shared subsystem is held
  open by another process. `i==125` is the last resort and forces a
  reconnect when the target UUID is confirmed on TrueNAS but still not
  visible. `i==150` (emergency reconnect) runs only for a caller that
  opted in with `allow_reconnect=1` and refuses to run while the
  subsystem is in use (`TrueNASPlugin.pm:6455-6811`).
- iSCSI typically has one session per path, each independent. When A's
  portal dies, dm-multipath has to notice (polling delay), kill the
  session, and ship I/O to B's session — which may itself need a relogin
  if the initiator wasn't already logged in there.

Signalling is also faster:

- ANA state changes arrive as asynchronous events (NVMe AER with the
  "Changed ANA" attribute). The initiator reacts in milliseconds.
- ALUA state changes are discovered by polling `REPORT TARGET PORT
  GROUPS` on a timer, or by racing a Unit Attention onto the next
  command. Default polling intervals (~5 s) can dominate the overhead.

And there are fewer moving parts:

- No `multipathd`, no `/etc/multipath.conf`, no `hwhandler` config.
- No `iscsid` session book-keeping during a transition.

## What this means in numbers

Observed pause (fio active, direct I/O, randrw workload, forced
`ipmitool chassis power cycle` of the active controller):

| Transport | Measured window | Distribution |
|---|---|---|
| NVMe/TCP + ANA (this plugin, 2026-10-08, 50-iter run) | 19.5 – 25.5 s | avg ~20.7 s, tight |
| iSCSI tuned (`replacement_timeout=280`, `noop_out_interval=15`, `noop_out_timeout=30`) | ~20 – 60 s | wider, previously observed on earlier HA hardware |

The ~20 s floor on NVMe/TCP is **not** the ANA transition itself — that
is sub-second. It is dominated by the TrueNAS-side pool import on the
surviving controller (10–15 s), plus a small amount of in-flight-drain
and kernel path-select overhead. ANA just does not add appreciable time
on top of the unavoidable pool-import pause.

iSCSI hits the same pool-import floor and then layers additional time on
top for session detection and relogin. The result is that NVMe/TCP tends
to the low end of what the storage back-end can achieve, with very
little variance across runs.

## Caveats

- Numbers above are from a specific test rig: TrueNAS 25.10.4 HA pair,
  PVE 9.1 initiator, 10 GbE path, randrw workload at `iodepth=16` /
  `bs=16k`. Different workloads, controllers, and network paths will
  shift the floor; see [`HA-NVMe-TCP-Validation.md`](HA-NVMe-TCP-Validation.md)
  (when published) for the full test record.
- Both transports still depend on the storage back-end being able to
  import the pool quickly on the surviving node. NVMe/TCP is not a magic
  cure for a slow pool import.
- On an HA pair affected by the physical-IP `addr_traddr` middleware
  limitation, set `tn_nvme_manage_ports 0` and pre-provision a VIP-based
  `nvmet.port` + `nvmet.port_subsys` binding to `tn_subsystem_nqn`. The
  plugin then stops touching `nvmet.port.*` records but still manages
  the subsystem lookup, namespace lifecycle, and initiator-side connect
  (`TrueNASPlugin.pm:929-940`). See the
  [`tn_nvme_manage_ports`](Configuration.md#tn_nvme_manage_ports) field.
- Linux's dm-multipath / `multipathd` tuning for iSCSI can narrow the
  gap but will never eliminate the session-re-establishment overhead
  because iSCSI has no equivalent of "both sessions always open".
