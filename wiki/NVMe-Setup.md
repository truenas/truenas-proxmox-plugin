# NVMe/TCP Setup Guide

This guide covers setting up NVMe over TCP (NVMe/TCP) storage with the TrueNAS Proxmox plugin. NVMe/TCP provides lower latency and reduced CPU overhead compared to traditional iSCSI.

## Table of Contents

- [Prerequisites](#prerequisites)
- [TrueNAS Configuration](#truenas-configuration)
  - [Enable NVMe-oF Target Service](#enable-nvme-of-target-service)
  - [Create NVMe Subsystem](#create-nvme-subsystem)
  - [Configure DH-CHAP Authentication (Optional)](#configure-dh-chap-authentication-optional)
  - [HA Pair (Dual Controller) Deployment](#ha-pair-dual-controller-deployment)
- [Proxmox Configuration](#proxmox-configuration)
  - [Install nvme-cli](#install-nvme-cli)
  - [Configure Storage](#configure-storage)
  - [Verify Connection](#verify-connection)
- [Multipath Configuration](#multipath-configuration)
- [DH-CHAP Authentication Setup](#dh-chap-authentication-setup)
  - [Generate Secrets](#generate-secrets)
  - [Configure on TrueNAS](#configure-on-truenas)
  - [Configure on Proxmox](#configure-on-proxmox)
- [Migration from iSCSI](#migration-from-iscsi)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)

## Prerequisites

**TrueNAS Requirements:**
- TrueNAS SCALE 25.10.0 or later
- ZFS pool and dataset configured
- Network connectivity between TrueNAS and Proxmox hosts
- NVMe-oF Target service available

**Proxmox Requirements:**
- Proxmox VE 9.x or later
- `nvme-cli` package installed (version 2.0+)
- Host NQN configured (auto-generated or custom)
- TrueNAS Proxmox plugin installed

**Network Requirements:**
- TCP port 4420 accessible on TrueNAS (default NVMe/TCP port)
- Low-latency network recommended (1GbE minimum, 10GbE+ preferred)
- For multipath: Multiple network interfaces configured

**Note**: TrueNAS SCALE 25.10+ automatically defaults to port 4420 for NVMe/TCP. Manual port specification is optional unless using a non-standard port.

## TrueNAS Configuration

### Enable NVMe-oF Target Service

1. **Via TrueNAS Web GUI:**
   - Navigate to **System Settings → Services**
   - Locate **NVMe-oF Target** service
   - Click the toggle to **Start** the service
   - (Optional) Check **Start Automatically** to enable on boot

2. **Via TrueNAS API (plugin call):**
   ```bash
   ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate($scfg, \"service.update\", [\"nvmet\", { enable => 1 }]); print \"ok\\n\";'"

   ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate($scfg, \"service.start\", [\"nvmet\"]); print \"ok\\n\";'"
   ```

3. **Verify service is running:**
   ```bash
   ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"service.query\", [[[\"service\",\"=\",\"nvmet\"]]]); print \"ok\\n\";'"
   ```

   Expected output should show `"state": "RUNNING"`.

### Create NVMe Subsystem

The plugin automatically creates subsystems when needed, but you can create them manually:

1. **Via TrueNAS Web GUI:**
   - Navigate to **Shares → NVMe-oF**
   - Click **Add Subsystem**
   - Configure:
     - **Name**: Short identifier (e.g., `proxmox-nvme`)
     - **Subsystem NQN**: Full NQN (e.g., `nqn.2005-10.org.freenas.ctl:proxmox-nvme`)
     - **Allow Any Host**: Leave enabled unless an allow-list is configured (see below)
   - Click **Save**

   **`allow_any_host`:** the plugin writes `tn_nvme_allow_any_host`
   (default `1`, i.e. TRUE) to the subsystem on create and on every
   configfs resync, so the default lets any host NQN connect. Two TrueNAS
   caveats decide when to set it to `0`:

   - **TrueNAS 26.0.0-BETA.2 (and possibly other 26.x betas)** does not
     render a freshly created subsystem at all when `allow_any_host` is
     false and `allowed_hosts` is empty: the port gets no listener and no
     host can connect. Populate `allowed_hosts` first, then set
     `tn_nvme_allow_any_host 0`.
   - **TrueNAS 25.10.x** aborts the configfs render when `allow_any_host`
     is true and `allowed_hosts` is populated (issue #90): namespaces stay
     unpublished and `nvme list` shows nothing. Set
     `tn_nvme_allow_any_host 0` in storage.cfg in that case.

   How to choose: keep the default while there is no host allow-list; set
   `0` once `allowed_hosts` is populated on 25.10.x. DH-CHAP (below)
   authenticates hosts independently of this setting.

2. **Via TrueNAS API (plugin call):**
   ```bash
   ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate($scfg, \"nvmet.subsys.create\", [{ name => \"proxmox-nvme\", subnqn => \"nqn.2005-10.org.freenas.ctl:proxmox-nvme\", allow_any_host => 1 }]); print \"ok\\n\";'"
   ```

**Important Notes:**
- The subsystem NQN must follow the format: `nqn.YYYY-MM.domain:identifier`
- The plugin automatically creates subsystems if they don't exist
- Once set in storage.cfg, the subsystem NQN cannot be changed (marked as `fixed`)

### Configure DH-CHAP Authentication (Optional)

See the [DH-CHAP Authentication Setup](#dh-chap-authentication-setup) section for detailed authentication configuration.

### HA Pair (Dual Controller) Deployment

TrueNAS HA pairs on 25.10.x require two deviations from the
single-head setup above. Without them, the plugin's default
port-management creates `nvmet.port` records whose `addr_traddr` is a
physical controller IP; TrueNAS's HA middleware then trips a
`KeyError` in `map_attrs()` that aborts the configfs render and
leaves every namespace unpublished (controller appears connected,
but `nvme list` sees nothing).

**1. Pre-provision one VIP-based port record on TrueNAS.** Run once
per subsystem from either controller:

```bash
# Replace <VIP> and <SUBSYS_NAME>. If the subsystem already exists,
# skip the first call and reuse its id as subsys_id below.
midclt call nvmet.subsys.create       '{"name":"<SUBSYS_NAME>","allow_any_host":true}'
# -> returns {"id": M, ...}

midclt call nvmet.port.create         '{"addr_trtype":"TCP","addr_traddr":"<VIP>","addr_trsvcid":4420}'
# -> returns {"id": N, ...}

midclt call nvmet.port_subsys.create  '{"port_id":N,"subsys_id":M}'
```

Only the VIP is accepted as `addr_traddr`. TrueNAS renders this one
logical port record on both controllers; each binds its own physical
IP and advertises its own ANA state.

**2. Set `tn_nvme_manage_ports 0` on the storage.** The plugin then
skips every `nvmet.port.*` mutation and leaves the port record you
pre-provisioned alone. `tn_api_host` points at the VIP (management
plane); `tn_discovery_portal` points at a physical controller IP
(data plane) so `nvme-cli` has a real target for discovery and can
walk the subsystem's `xport_referral` list to reach the second
controller.

See the HA stanza in [`storage.cfg.example`](../storage.cfg.example)
and the [NVMe/TCP HA failover](Best-Practices.md#nvmetcp-ha-failover)
section of Best-Practices for the full failover-tuning context.

If the subsystem named by `tn_subsystem_nqn` does not exist and
`tn_nvme_manage_ports` is `0`, the plugin refuses to auto-create it
and prints the three `midclt` calls above.

## Proxmox Configuration

### Install nvme-cli

The `nvme-cli` package provides the tools needed to connect to NVMe/TCP targets:

```bash
apt-get update
apt-get install nvme-cli
```

**Verify installation:**
```bash
nvme version
# Expected output: nvme version 2.x or later
```

**Check host NQN:**
```bash
cat /etc/nvme/hostnqn
# Example output: nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400
```

If no hostnqn file exists, generate one:
```bash
nvme gen-hostnqn > /etc/nvme/hostnqn
```

### Configure Storage

**Option 1: Using Interactive Installer (Recommended)**

The installer includes a built-in configuration wizard that simplifies NVMe/TCP setup. Download and run it in one line:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh)
# Choose "Configure storage" from main menu
# Select "2) NVMe/TCP (modern, lower latency)" when prompted for transport mode
```

Or download first and run locally:

```bash
wget https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh
chmod +x install.sh
./install.sh
```

**The installer will automatically:**
- Check for nvme-cli package (offers to install if missing)
- Auto-populate host NQN from `/etc/nvme/hostnqn` (or generate one)
- Prompt for subsystem NQN with format validation
- Default to port 4420 for NVMe/TCP discovery portal
- Detect native NVMe multipath status
- Discover available portals from TrueNAS automatically
- Generate complete storage configuration
- Validate all settings before applying

This is the easiest method for first-time NVMe/TCP setup.

**Option 2: Manual Configuration**

Edit `/etc/pve/storage.cfg` to add NVMe/TCP storage:

**Minimal Configuration:**
```ini
truenasplugin: truenas-nvme
    tn_api_host 10.15.14.172
    tn_api_key 2-YourAPIKeyHere
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    tn_dataset tank/proxmox
    tn_discovery_portal 10.15.14.172:4420
    tn_api_insecure 1
    content images,rootdir
    shared 1
```

> **About `tn_api_insecure 1`:** TrueNAS SCALE ships with a self-signed
> HTTPS certificate out of the box, and the plugin's default
> transport (`tn_api_scheme = wss`) verifies the server certificate.
> With the default cert the WebSocket handshake fails on cert
> verification and the storage never activates. `tn_api_insecure 1`
> tells the plugin to skip verification. If you have replaced the
> TrueNAS cert with one from your own CA (or a public CA), omit this
> parameter so verification stays on.
>
> **About `content`:** `images,rootdir` lets both VM disks and LXC
> container rootfs live on this storage. If you only ever run VMs
> here, `content images` is fine; it does not stop VMs from working,
> it just hides the storage from the LXC create UI.

**With Optional Parameters:**
```ini
truenasplugin: truenas-nvme
    tn_api_host 10.15.14.172
    tn_api_key 2-YourAPIKeyHere
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    tn_hostnqn nqn.2014-08.org.nvmexpress:uuid:custom-uuid
    tn_dataset tank/proxmox
    tn_discovery_portal 10.15.14.172:4420
    tn_api_scheme wss
    tn_api_port 443
    tn_api_insecure 1
    tn_zvol_blocksize 64K
    content images,rootdir
    shared 1
```

**Parameter Explanations:**

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `tn_transport_mode` | Yes | Must be `nvme-tcp` for NVMe/TCP | `iscsi` |
| `tn_subsystem_nqn` | Yes | NVMe subsystem NQN (format: `nqn.YYYY-MM.domain:name`) | None |
| `tn_hostnqn` | No | Override host NQN (if not using `/etc/nvme/hostnqn`) | Auto-detected |
| `tn_nvme_allow_any_host` | No | Value the plugin writes to the subsystem's `allow_any_host` on create and configfs resync. Leave at the default; set `0` only after populating `allowed_hosts` (see [Create NVMe Subsystem](#create-nvme-subsystem)). | `1` |
| `tn_discovery_portal` | Yes | Primary portal IP:port | None |
| `tn_nvme_manage_ports` | No | Create the `nvmet.port` and `port_subsys` records that match `tn_discovery_portal`/`tn_portals`. Set `0` on a TrueNAS HA pair with pre-provisioned VIP ports; the plugin then makes no `nvmet.port.*` calls. | `1` |
| `tn_nvme_dhchap_secret` | No | Host authentication secret | None |
| `tn_nvme_dhchap_ctrl_secret` | No | Controller authentication secret | None |
| `tn_nr_io_queues` | No | Pin NVMe/TCP I/O queue count per controller (1–256). Auto-detected when unset: uses online CPU count normally, or `floor(possible/2)` when any CPU is offline. Set manually if TrueNAS reports queue limit errors. | Auto-detected |
| `tn_nvme_ctrl_loss_tmo` | No | Seconds the kernel retries a lost controller before removing it (`-1` = forever). Strongly recommended with multiple portals — see [Multipath Configuration](#multipath-configuration). | Kernel default (600) |
| `tn_nvme_reconnect_delay` | No | Seconds between kernel reconnect attempts. | Kernel default (10) |
| `tn_nvme_keep_alive_tmo` | No | Keep-alive timeout. Lower detects a dead path sooner. | Kernel default |

**Important Notes:**
- TrueNAS 25.10+ is required for NVMe-oF operations
- The default port for NVMe/TCP is `4420` (different from iSCSI's `3260`)
- TrueNAS SCALE 25.10+ automatically uses port 4420; manual specification is optional
- `tn_subsystem_nqn` cannot be changed after creation (prevents orphaned volumes)

**Portal scope:** the plugin logs in only to the portals listed in
`tn_discovery_portal` and `tn_portals`. A portal that TrueNAS advertises on
the subsystem but that is absent from both keys is skipped: no `nvme
connect` is issued for it. On a multipath storage, list every path you want
the plugin to establish in `tn_portals`. iSCSI follows the same rule since
2.1.24~beta8, where addresses seen only through SendTargets discovery
stopped being logged into.

### Verify Connection

After configuring storage, verify the NVMe connection:

```bash
# List connected subsystems
nvme list-subsys

# Expected output includes:
# nvme-subsysX - NQN=nqn.2005-10.org.freenas.ctl:proxmox-nvme
#                hostnqn=nqn.2014-08.org.nvmexpress:uuid:...
# \
#  +- nvmeX tcp traddr=10.15.14.172,trsvcid=4420,src_addr=10.15.14.195 live
```

```bash
# List NVMe devices
nvme list

# Should show TrueNAS devices with Model containing "TrueNAS"
```

```bash
# Check device UUID mapping
ls -la /dev/disk/by-id/nvme-uuid.*

# Example output:
# lrwxrwxrwx ... nvme-uuid.6b165acc-1bdd-4ee6-9f19-fa5dab818c50 -> ../../nvme3n2
```

## Multipath Configuration

NVMe/TCP supports native multipath for high availability and increased bandwidth.

> **Set `tn_nvme_ctrl_loss_tmo -1` when you configure more than one portal.**
> Path maintenance is the kernel's job once a controller exists: it reconnects on
> its own, and a path restored this way comes back with the same I/O queue count it
> had before. At the kernel default of 600 seconds, however, a fabric that stays
> down for over ten minutes has its controller removed, and the kernel will not
> recreate it. The plugin re-adds such a portal from `status()`, on pvestatd's
> timer, so the node runs on a single path until the next poll rather than
> indefinitely — but with `-1` the kernel keeps retrying on its own, so the path
> returns within one reconnect interval (`tn_nvme_reconnect_delay`, kernel default
> 10) of the fabric coming back, with no plugin-side re-add needed at all.
>
> Note that a controller reports `state=live` whenever the kernel holds it, which
> is not the same as the path being usable for I/O: a path can be `live` and at the
> same time `inaccessible` via ANA. Path selection is the kernel's decision; the
> plugin's portal count reports controllers, not ANA-accessible paths.

### TrueNAS Multipath Setup

1. **Configure multiple network interfaces** on TrueNAS with different IPs
   - Example: `10.15.14.172` (primary), `10.15.14.173` (secondary)

2. **Ensure NVMe-oF port listens on all interfaces:**
   - Default configuration uses `0.0.0.0:4420` (all IPv4 interfaces)
- Verify with:
  `ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.port.query\", [[]]); print \"ok\\n\";'"`

### Proxmox Multipath Storage Configuration

Add additional portals using the `tn_portals` parameter:

```ini
truenasplugin: truenas-nvme-multipath
    tn_api_host 10.15.14.172
    tn_api_key 2-YourAPIKeyHere
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-ha
    tn_dataset tank/proxmox
    tn_discovery_portal 10.15.14.172:4420
    tn_portals 10.15.14.173:4420,10.15.14.174:4420
    content images
    shared 1
```

### Verify Multipath

```bash
nvme list-subsys | grep -A 10 "proxmox-ha"

# Expected output shows multiple paths:
# nvme-subsysX - NQN=nqn.2005-10.org.freenas.ctl:proxmox-ha
# \
#  +- nvmeX tcp traddr=10.15.14.172,trsvcid=4420 live
#  +- nvmeX tcp traddr=10.15.14.173,trsvcid=4420 live
#  +- nvmeX tcp traddr=10.15.14.174,trsvcid=4420 live
```

**Multipath Behavior:**
- Plugin connects to all configured portals during subsystem connection
- At least ONE portal must succeed for the connection to be established
- Individual portal failures are logged but don't fail the operation (resilience)
- NVMe native multipath handles path failover automatically

## DH-CHAP Authentication Setup

DH-HMAC-CHAP provides secure authentication between Proxmox hosts and TrueNAS:
- **Unidirectional**: Proxmox authenticates to TrueNAS (host secret only)
- **Bidirectional**: Mutual authentication (host + controller secrets)

### Generate Secrets

On the Proxmox host, generate authentication secrets:

**Generate host secret (256-bit with SHA-256):**
```bash
nvme gen-dhchap-key --key-length 32 --hmac 1
# Output: DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
```

**Generate controller secret (for bidirectional auth):**
```bash
nvme gen-dhchap-key --key-length 32 --hmac 1
# Output: DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
```

**Note**: When using HMAC functions (1, 2, or 3), you may need to specify the host NQN:
```bash
nvme gen-dhchap-key --key-length 32 --hmac 1 --nqn $(cat /etc/nvme/hostnqn)
```

**Secret Format:**
- `DHHC-1`: Protocol version
- `01`: Hash algorithm (01 = SHA-256)
- Base64-encoded secret data

**Key Length Options:**
- `32` bytes (256-bit) - Recommended
- `48` bytes (384-bit)
- `64` bytes (512-bit)

### Configure on TrueNAS

Configure host authentication on TrueNAS:

**Via TrueNAS API (plugin call):**
```bash
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate($scfg, \"nvmet.host.create\", [{ hostnqn => \"nqn.2014-08.org.nvmexpress:uuid:81d0b800-0d47-11ea-a719-d0fedbf91400\", dhchap_key => \"DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:\", dhchap_ctrl_key => \"DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:\", dhchap_hash => \"SHA-256\" }]); print \"ok\\n\";'"
```

**Parameters:**
- `tn_hostnqn`: The Proxmox host's NQN (from `/etc/nvme/hostnqn`)
- `dhchap_key`: Host secret (Proxmox authenticates to TrueNAS)
- `dhchap_ctrl_key`: Controller secret (TrueNAS authenticates to Proxmox) - optional
- `dhchap_hash`: Hash algorithm (`SHA-256`, `SHA-384`, or `SHA-512`)

**Link Host to Subsystem:**

To restrict access to specific hosts, disable `allow_any_host` and create host-subsystem associations:

```bash
# Step 1: Disable allow_any_host on the subsystem
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate($scfg, \"nvmet.subsys.update\", [\"SUBSYS_ID\", { allow_any_host => 0 }]); print \"ok\\n\";'"

# Step 2: Get the host ID (query existing hosts)
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.host.query\", [[]]); print \"ok\\n\";'"
# Returns: [{"id": 1, "hostnqn": "nqn.2014-08.org.nvmexpress:uuid:...", ...}]

# Step 3: Get the subsystem ID (query existing subsystems)
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.subsys.query\", [[]]); print \"ok\\n\";'"
# Returns: [{"id": 1, "name": "proxmox-nvme", "subnqn": "nqn.2005-10.org.freenas.ctl:proxmox-nvme", ...}]

# Step 4: Link the host to the subsystem
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate($scfg, \"nvmet.host_subsys.create\", [{ host_id => 1, subsys_id => 1 }]); print \"ok\\n\";'"
```

**Important**: When `allow_any_host: false`, ONLY explicitly linked hosts can connect to the subsystem. DH-CHAP authentication is an optional additional security layer.

Changing the attribute on TrueNAS alone is not durable: the plugin writes
`tn_nvme_allow_any_host` back on subsystem create and on every
namespace-create resync. Set `tn_nvme_allow_any_host 0` in storage.cfg as
well (see the caveats under [Create NVMe Subsystem](#create-nvme-subsystem)).

### Configure on Proxmox

Add the secrets to Proxmox storage.cfg:

**Unidirectional Authentication (Host Only):**
```ini
truenasplugin: truenas-nvme-secure
    tn_api_host 10.15.14.172
    tn_api_key 2-YourAPIKeyHere
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-secure
    tn_dataset tank/proxmox
    tn_discovery_portal 10.15.14.172:4420
    tn_nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
    content images
    shared 1
```

**Bidirectional Authentication (Host + Controller):**
```ini
truenasplugin: truenas-nvme-mutual
    tn_api_host 10.15.14.172
    tn_api_key 2-YourAPIKeyHere
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-mutual
    tn_dataset tank/proxmox
    tn_discovery_portal 10.15.14.172:4420
    tn_nvme_dhchap_secret DHHC-1:01:l29rbM7waP9bX4gjmx0e6S6eK5sDb7a5c0jZJG2XxcwvDbY0:
    tn_nvme_dhchap_ctrl_secret DHHC-1:01:6Fk0dLGH1uPYPVKlyTNOWf4dk8FNOs9abL1p4cT0Qq2yEXLq:
    content images
    shared 1
```

**Verify Authentication:**

Connection attempts without correct secrets will fail:
```bash
nvme list-subsys
# Should show successful connection with authentication

# Check kernel logs for auth messages
dmesg | grep -i nvme | grep -i auth
```

## Migration from iSCSI

Migrating from iSCSI to NVMe/TCP requires creating new storage and moving VM disks.

### Why In-Place Migration Isn't Possible

- `tn_transport_mode` is marked as `fixed` (cannot be changed after creation)
- Volume naming formats are incompatible:
  - iSCSI: `vol-<zname>-lun<LUN>`
  - NVMe: `vol-<zname>-ns<UUID>`
- Device paths are different:
  - iSCSI: `/dev/disk/by-path/ip-...-lun-X` or `/dev/mapper/mpath*`
  - NVMe: `/dev/disk/by-id/nvme-uuid.*`

### Migration Steps

1. **Create new NVMe/TCP storage** with a different storage ID:
   ```ini
   # Existing iSCSI storage
   truenasplugin: truenas-iscsi
       tn_transport_mode iscsi
       ...

   # New NVMe/TCP storage
   truenasplugin: truenas-nvme
       tn_transport_mode nvme-tcp
       ...
   ```

2. **For running VMs - Live migration:**
   ```bash
   # Migrate disk while VM is running
   qm move-disk <VMID> scsi0 truenas-nvme --delete
   ```

3. **For stopped VMs - Offline migration:**
   ```bash
   # Stop the VM
   qm stop <VMID>

   # Move each disk
   qm move-disk <VMID> scsi0 truenas-nvme --delete
   qm move-disk <VMID> scsi1 truenas-nvme --delete

   # Start the VM
   qm start <VMID>
   ```

4. **For cluster-wide migration:**
   - Stop all VMs using the iSCSI storage
   - Migrate all disks to NVMe storage
   - Verify all VMs start correctly
   - Remove old iSCSI storage configuration

5. **Verify performance improvements:**
   ```bash
   # Test disk latency
   fio --name=randread --ioengine=libaio --direct=1 --bs=4k --iodepth=64 \
       --rw=randread --runtime=60 --filename=/dev/disk/by-id/nvme-uuid.*
   ```

6. **Decommission old iSCSI storage** after confirming stability:
   - Remove from `/etc/pve/storage.cfg`
   - Delete iSCSI targets/extents from TrueNAS
   - Clean up ZFS datasets if desired

## Performance Tuning

### Expected Performance Characteristics

**NVMe/TCP vs iSCSI:**
- **Latency**: NVMe/TCP 50-150μs vs iSCSI 200-500μs
- **CPU Overhead**: NVMe lower (no SCSI emulation layer)
- **Queue Depth**: NVMe native queuing (64K+ commands) vs iSCSI single queue
- **Bandwidth**: Similar on same network, but NVMe scales better with multipath

### Optimal Configuration

**ZFS Block Size:**

The plugin does not set a default block size; if `tn_zvol_blocksize` is
omitted, the zvol inherits TrueNAS's `pool.dataset.create` default
(16K on TrueNAS SCALE 25.10.x). Tuning suggestions for NVMe/TCP
workloads:

```ini
tn_zvol_blocksize 64K  # Recommended for general NVMe/TCP workloads
tn_zvol_blocksize 16K  # TrueNAS default; better for database workloads (small random I/O)
tn_zvol_blocksize 128K # Better for sequential I/O (media, backups)
```

**Network Tuning:**
- Use dedicated network interfaces for storage traffic
- Enable jumbo frames (MTU 9000) on both TrueNAS and Proxmox
- Use 10GbE or faster for best performance
- Consider separate VLANs for storage network

**Proxmox Settings:**
- Use VirtIO SCSI controller for VMs (best NVMe performance)
- Enable `iothread` for disk devices
- Set `cache=none` or `cache=writeback` depending on workload

**TrueNAS Settings:**
- Disable sync writes for better performance (at risk of data loss):
  ```bash
  zfs set sync=disabled tank/proxmox
  # WARNING: Only use for non-critical data
  ```
- Use fast SSDs for special vdevs (metadata, L2ARC)
- Ensure adequate RAM for ARC caching

### When to Use NVMe/TCP vs iSCSI

**Use NVMe/TCP when:**
- You have modern infrastructure (TrueNAS 25.10+, Proxmox 9.x+)
- You need lower latency (databases, high-IOPS workloads)
- You want better queue depth and parallelism
- You have CPU constraints (NVMe has less overhead)

**Use iSCSI when:**
- You have older infrastructure (compatibility)
- You need proven stability (iSCSI more mature in plugin)
- You require specific legacy CHAP implementations
- You have existing iSCSI infrastructure to maintain

## Troubleshooting

### Connection Issues

**Error: "nvme-cli is not installed"**
```bash
apt-get install nvme-cli
```

**Error: "Could not determine host NQN"**
```bash
# Generate a host NQN
nvme gen-hostnqn > /etc/nvme/hostnqn

# Verify
cat /etc/nvme/hostnqn
```

**Error: "No portals configured for NVMe/TCP storage"**
- Check storage.cfg for `tn_discovery_portal` parameter
- Verify format: `IP:PORT` (e.g., `10.15.14.172:4420`)

**Error: "Failed to connect to any NVMe/TCP portal"**

Check network connectivity:
```bash
ping 10.15.14.172
telnet 10.15.14.172 4420
```

Check TrueNAS service:
```bash
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"service.query\", [[[\"service\",\"=\",\"nvmet\"]]]); print \"ok\\n\";'"
# Should show "state": "RUNNING"
```

Check TrueNAS NVMe port:
```bash
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.port.query\", [[]]); print \"ok\\n\";'"
# Should show port 4420 with addr_traddr listening
```

### Authentication Issues

**Error: Authentication failed during connection**

Verify secrets match:
```bash
# On TrueNAS - check configured host
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.host.query\", [[]]); print \"ok\\n\";'"

# Compare hostnqn and dhchap_key with Proxmox configuration
cat /etc/nvme/hostnqn
grep nvme_dhchap_secret /etc/pve/storage.cfg
```

Regenerate secrets if needed and update both sides.

### Device Discovery Issues

**Error: "Could not locate NVMe device for UUID"**

**How Device Matching Works**:

The plugin uses a three-tier strategy to locate NVMe namespace devices:

1. **Tier 1: NGUID Matching (Primary)**
   - Queries TrueNAS API for `device_nguid` field in namespace object
   - Matches against `/sys/block/nvmeXnY/nguid` sysfs attribute
   - Most reliable - NGUID is globally unique and consistent across controllers

2. **Tier 2: NSID Matching (Fallback)**
   - Uses namespace ID from TrueNAS API
   - Reads NSID from `/sys/block/nvmeXnY/nsid` sysfs file (NOT from device name)
   - Fallback for older TrueNAS versions or if API fails

3. **Tier 3: Single Device (Safe Fallback)**
   - If only one namespace exists on subsystem, returns it safely
   - Avoids ambiguity when no matching metadata available

**Note**: Device names like `nvme3n5` do NOT reliably indicate NSID. The plugin reads NSID from sysfs instead.

**Diagnosis**:

Check if subsystem is connected:
```bash
nvme list-subsys | grep -i <subsystem_nqn>
```

Check if namespace exists:
```bash
nvme list | grep TrueNAS
```

Verify NGUID matching (requires debug logging):
```bash
# Enable debug logging in /etc/pve/storage.cfg:
tn_debug 2

# Watch device matching process
journalctl -f | grep '\[TrueNAS\].*nvme_find_device'

# You should see NGUID matching attempts and results
```

Trigger udev rescan:
```bash
udevadm settle
sleep 1
ls -la /dev/disk/by-id/nvme-uuid.*
```

Check kernel logs:
```bash
dmesg | grep -i nvme | tail -20
```

### Large-transfer I/O errors (vzdump, `qemu-img convert`)

**Symptom:** backups, disk moves, or imports over NVMe/TCP fail
partway through with `err -5 - Input/output error`. PVE logs show
`I/O Error (sct 0x0 / sc 0x6)` on commands of around 16 MB (32768
blocks). TrueNAS `dmesg` shows `nvmet_tcp: queue N: failed to map
data`.

**Cause:** The TrueNAS kernel `nvmet-tcp` module is missing the
`.get_mdts` callback, so clients request transfers larger than the
target can map. Tracked as GitHub #45 and #96; kernel patch
pending in a TrueNAS point release.

**Workaround — cap `max_sectors_kb` on every PVE node, scoped to
TrueNAS subsystems only:**

```bash
cat > /etc/udev/rules.d/60-nvme-tcp-max-sectors.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*n*", ENV{DEVTYPE}=="disk", \
  ATTRS{subsysnqn}=="nqn.*truenas*", ATTR{queue/max_sectors_kb}="1024"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=block --action=change
```

Verify: `cat /sys/block/<nvmeNnM>/queue/max_sectors_kb` should
print `1024`. See
[Known-Limitations.md#nvmet-tcp-missing-get_mdts--large-transfer-io-errors](Known-Limitations.md#nvmet-tcp-missing-get_mdts--large-transfer-io-errors)
for the full writeup. Remove the rule when the kernel fix lands in
your TrueNAS version.

### Namespace Issues

**Namespace creation fails**

Verify NVMe-oF service is running on TrueNAS.

Check dataset exists and has space:
```bash
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"pool.dataset.get_instance\", [\"tank/proxmox\"]); print \"ok\\n\";'"
```

### Validation Commands

```bash
# 1. Check nvme-cli version
nvme version

# 2. View host NQN
cat /etc/nvme/hostnqn

# 3. List connected subsystems
nvme list-subsys

# 4. List NVMe devices
nvme list

# 5. Check device UUID mapping
ls -la /dev/disk/by-id/nvme-uuid.*

# 6. Test specific namespace read
dd if=/dev/disk/by-id/nvme-uuid.XXXX of=/dev/null bs=4M count=10 iflag=direct

# 7. Check kernel logs
dmesg | grep -i nvme | tail -50

# 8. Verify TrueNAS service
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"service.query\", [[[\"service\",\"=\",\"nvmet\"]]]); print \"ok\\n\";'"

# 9. List TrueNAS subsystems
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.subsys.query\", [[]]); print \"ok\\n\";'"

# 10. List TrueNAS namespaces
ssh root@PROXMOX_NODE "perl -e 'use lib \"/usr/share/perl5\"; use PVE::Storage; use PVE::Storage::Custom::TrueNASPlugin; my $scfg=PVE::Storage::config()->{ids}{\"STORAGE_ID\"} or die \"storage STORAGE_ID not found\\n\"; my $res=PVE::Storage::Custom::TrueNASPlugin::_api_call($scfg, \"nvmet.namespace.query\", [[]]); print \"ok\\n\";'"
```

## See Also

- [Configuration Reference](Configuration.md) - Detailed parameter documentation
- [Troubleshooting Guide](Troubleshooting.md) - Additional troubleshooting scenarios
- [Advanced Features](Advanced-Features.md) - Performance tuning and optimization
- [Installation Guide](Installation.md) - Plugin installation instructions
