# Post-Install Checklist

After running `install.sh` to add a new TrueNAS system as Proxmox storage, the following manual steps are required. These address known issues in the installer that have not yet been fixed upstream.

## 1. Fix the iSCSI Target IQN (Double-Nested IQN Bug)

**Symptom:** Volume allocation fails with `Could not resolve iSCSI target ID for configured IQN`. The `pvesh create` output shows a target like:

```
iqn.2005-10.org.freenas.ctl:iqn.2026-03.org.freenas.ctl:truenas-main
```

**Cause:** The installer passes a full IQN string (e.g., `iqn.2026-03.org.freenas.ctl:truenas-main`) as the target *name* to `iscsi.target.create`. TrueNAS prepends its own base name (`iqn.2005-10.org.freenas.ctl`), creating a double-nested IQN.

**Fix:**

1. In the TrueNAS Web UI: **Shares > Block Shares (iSCSI) > Targets**
2. Edit the target and change the name from `iqn.2026-03.org.freenas.ctl:truenas-main` to just `truenas-main`
3. Save
4. Update `/etc/pve/storage.cfg` — change `target_iqn` to match the corrected full IQN:
   ```
   target_iqn iqn.2005-10.org.freenas.ctl:truenas-main
   ```
5. Restart pvedaemon: `systemctl restart pvedaemon`

## 2. Remove `api_insecure 1` and Trust the TrueNAS Certificate

**Symptom:** T1-01 hard gate fails: `api_insecure 1 found in storage.cfg`.

**Cause:** The installer adds `api_insecure 1` to bypass TLS verification when the TrueNAS certificate is not trusted. This should not ship to production.

**Fix (on every Proxmox node in the cluster):**

```bash
openssl s_client -connect <TRUENAS_IP>:443 </dev/null 2>/dev/null | \
  openssl x509 > /usr/local/share/ca-certificates/truenas.crt
update-ca-certificates
```

Then remove `api_insecure 1` from `/etc/pve/storage.cfg` and restart pvedaemon:

```bash
systemctl restart pvedaemon
```

## 3. Add `force_delete_on_inuse 1`

**Symptom:** Volume deletion fails with `Associated target is in use` when an iSCSI session is active (e.g., during pre-flight cleanup or after a failed test run).

**Cause:** The plugin calls `iscsi.targetextent.delete` without `force=true`. TrueNAS refuses when the target has active sessions.

**Fix:** Add to the storage block in `/etc/pve/storage.cfg`:

```
	force_delete_on_inuse 1
```

Then restart pvedaemon: `systemctl restart pvedaemon`

## 4. Verify the iSCSI Portal Listen Address

**Symptom:** Portal creation fails with `IP <address> not configured on this system`.

**Cause:** The portal listen address must be an IP that TrueNAS recognizes as configured on one of its network interfaces. DHCP-assigned addresses may not be registered in TrueNAS's interface database.

**Fix:**

1. In the TrueNAS Web UI: **Network > Interfaces**
2. Edit the interface and confirm/save the IP configuration (even if DHCP)
3. Re-run the installer or manually create the portal

## 5. Install the Plugin on All Cluster Nodes

**Symptom:** Storage operations fail on nodes other than the one where the installer ran.

**Cause:** The plugin `.pm` file is installed locally per node, not shared via pmxcfs. The `storage.cfg` configuration is shared automatically, but the plugin code is not.

**Fix:** Run the installer on every node in the cluster:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/<branch>/install.sh -o install.sh
bash install.sh
```

Or copy the plugin file directly and restart:

```bash
scp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm node2:/usr/share/perl5/PVE/Storage/Custom/
scp /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm node3:/usr/share/perl5/PVE/Storage/Custom/
ssh node2 systemctl restart pvedaemon
ssh node3 systemctl restart pvedaemon
```

## 6. Verify Storage is Active on All Nodes

After all fixes are applied, verify from each node:

```bash
pvesm status          # Storage should show as "active"
pvesm list <storage>  # Should return without error
```

## Quick Reference: Typical storage.cfg Block

```
truenasplugin: truenas-main
	api_host 192.168.100.10
	api_key <your-api-key>
	datastore tank/proxmox
	target_iqn iqn.2005-10.org.freenas.ctl:truenas-main
	discovery_portal 192.168.100.10:3260
	force_delete_on_inuse 1
```
