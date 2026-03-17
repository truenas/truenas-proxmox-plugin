# Getting Listed on the Proxmox Partner Ecosystem

There is no formal "certification" program — Proxmox reviews third-party storage plugins and lists them on their website if they meet quality standards.

## Process

1. Contact `partner@proxmox.com` with subject: `New Solution Partner Request [TrueNAS Proxmox Plugin]`
2. Proxmox will review the integration and discuss further steps

For technical questions during development, use the `pve-devel` mailing list. For less public discussions, contact `partner@proxmox.com` directly.

## Requirements

### Licensing

The plugin code is loaded by the AGPLv3+ licensed Proxmox VE system and must be licensed to allow this. GPL v3 (this project's license) is compatible.

### Distribution

Proxmox recommends releasing as a Debian package — this project already does this.

### Testing Checklist

Before submitting, Proxmox recommends end-to-end testing covering:

- [ ] Add a storage entry for the plugin via the Proxmox web UI
- [ ] Create at least one VM and one CT using the default wizard configuration
- [ ] Add an additional disk volume to a guest using the plugin
- [ ] Run an I/O benchmark (e.g. `fio`) inside a virtual guest and verify adequate performance

## Current Status

| Requirement | Status |
|-------------|--------|
| GPL v3 license (AGPLv3+ compatible) | Done |
| Debian package distribution | Done |
| Dual transport support (iSCSI + NVMe/TCP) | Done |
| End-to-end testing | Pending |
| Clear license statement in README | Pending |

## References

- [Storage Plugin Development](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
- [Third Party Integration Options](https://pve.proxmox.com/wiki/Third_Party_Integration_Options)
- [Partner Ecosystem](https://www.proxmox.com/en/partners/find-partner/explore)
