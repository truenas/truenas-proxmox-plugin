# Debian Package Design for TrueNAS Proxmox Plugin

**Date:** 2026-02-19
**Version:** 2.0.3
**Status:** Approved

## Overview

This design documents the debian packaging implementation for the TrueNAS Proxmox VE Storage Plugin, following the Proxmox Storage Plugin Development guidelines for proper integration with Proxmox's ecosystem.

## Goals

1. **Primary**: Build proper debian package following Proxmox standards
2. **Secondary**: Establish self-hosted apt repository (GitHub Pages + Releases)
3. **Long-term**: Demonstrate adoption and submit to official Proxmox repositories

## Project Context

**Current State:**
- Single Perl module (TrueNASPlugin.pm - 192KB)
- Bash installer with menu system, health checks, cluster support (install.sh - 374KB)
- Manual installation via curl/wget download + copy to `/usr/share/perl5/PVE/Storage/Custom/`

**Proxmox Requirements:**
- Plugins must be in `/usr/share/perl5/PVE/Storage/Custom/YourCustomPlugin.pm`
- Debian packages recommended for integration with Proxmox update system
- Must be AGPLv3+ compatible (✓ project has LICENSE)

## Design Decisions

### Approach: Single Package - Keep It Simple

**Rationale:** Start with minimal viable packaging to enable rapid iteration and adoption growth. Complexity can be added later before official Proxmox submission.

**Package Contents:**
- Main Perl plugin module (TrueNASPlugin.pm)
- Management script (install.sh) as companion tool
- Test utilities
- Documentation

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Distribution Goal** | Hybrid Path | Build proper package → self-host apt repo → grow adoption → submit to Proxmox with metrics |
| **Installer Strategy** | Keep as companion | Debian handles install/update, bash script provides advanced management features |
| **Dependencies** | Balanced | Hard depend on iSCSI (common), soft recommend NVMe tools (optional) |
| **Versioning** | Lockstep | Package version = plugin version for clarity |
| **Repository Hosting** | GitHub Pages + Releases | Free, reliable, integrates with existing workflow |

## Package Structure

### Directory Layout

```
truenas-proxmox-plugin/
├── debian/
│   ├── control              # Package metadata, dependencies, description
│   ├── changelog            # Version history (SOURCE OF TRUTH)
│   ├── install              # File installation mappings
│   ├── postinst             # Post-installation script
│   ├── prerm                # Pre-removal script
│   ├── postrm               # Post-removal script
│   ├── rules                # Build instructions
│   ├── compat               # Debhelper compatibility level
│   ├── copyright            # License information
│   └── source/
│       └── format           # Source package format
│
├── TrueNASPlugin.pm         # Main plugin
├── install.sh               # Management script
├── tools/                   # Utilities
│   └── dev-truenas-plugin-full-function-test.sh
├── LICENSE
└── README.md
```

### Installed File Locations

| File | Destination | Mode | Notes |
|------|-------------|------|-------|
| TrueNASPlugin.pm | `/usr/share/perl5/PVE/Storage/Custom/` | 644 | Proxmox required location |
| install.sh | `/usr/share/truenas-proxmox-plugin/` | 755 | Management script |
| Symlink | `/usr/local/bin/truenas-proxmox-manage` | 777 | Convenience access |
| Test tools | `/usr/share/truenas-proxmox-plugin/tools/` | 755 | Development utilities |
| Documentation | `/usr/share/doc/truenas-proxmox-plugin/` | 644 | README, LICENSE, examples |

**Package Name:** `truenas-proxmox-plugin_2.0.3_all.deb`
- Architecture: `all` (pure Perl, platform-independent)

## Build System

### Build Tools

- **dpkg-buildpackage**: Standard Debian builder
- **debhelper**: Automated debian packaging helpers
- **devscripts**: Development utilities (dpkg-parsechangelog, etc.)

### Build Process

```bash
# Install build dependencies (one-time)
apt-get install debhelper devscripts

# Build package
cd truenas-proxmox-plugin/
dpkg-buildpackage -us -uc -b

# Output
../truenas-proxmox-plugin_2.0.3_all.deb
```

### debian/rules

```makefile
#!/usr/bin/make -f

%:
	dh $@

override_dh_auto_build:
	# Extract version from changelog and inject into plugin
	$(eval PKG_VERSION := $(shell dpkg-parsechangelog -S Version))
	sed -i "s/^our \$$VERSION = '.*';/our \$$VERSION = '$(PKG_VERSION)';/" TrueNASPlugin.pm

override_dh_auto_install:
	# Install plugin to Proxmox location
	install -D -m 644 TrueNASPlugin.pm \
		debian/truenas-proxmox-plugin/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

	# Install management tools
	install -D -m 755 install.sh \
		debian/truenas-proxmox-plugin/usr/share/truenas-proxmox-plugin/install.sh

	# Install test utilities
	install -D -m 755 tools/dev-truenas-plugin-full-function-test.sh \
		debian/truenas-proxmox-plugin/usr/share/truenas-proxmox-plugin/tools/dev-test.sh
```

### Version Management (Lockstep)

**Source of Truth:** `debian/changelog`

**Version Flow:**
1. Update `debian/changelog` with new version
2. Build process extracts version via `dpkg-parsechangelog`
3. Sed command injects version into `TrueNASPlugin.pm` during build
4. Package version and plugin `$VERSION` stay synchronized

**Benefits:**
- Single place to update version
- No version drift between package and plugin
- Clear version for users (`apt list` shows same version as plugin reports)

## Dependencies

### debian/control

```
Package: truenas-proxmox-plugin
Architecture: all
Depends:
    pve-manager (>= 8.0.0),
    open-iscsi,
    perl (>= 5.32),
    libjson-pp-perl,
    libmime-base64-perl,
    libdigest-sha-perl,
    liburi-encode-perl,
    libio-socket-ssl-perl
Recommends:
    nvme-cli,
    multipath-tools
Suggests:
    fio
```

### Dependency Rationale

**Hard Dependencies (Depends):**
- **pve-manager >= 8.0.0**: Ensures Proxmox VE 8.x+ minimum
- **open-iscsi**: Default transport, most common use case
- **Perl modules**: Core functionality requirements

**Soft Dependencies (Recommends):**
- **nvme-cli**: For NVMe/TCP transport (optional)
- **multipath-tools**: For production iSCSI multipathing (optional)

**Optional (Suggests):**
- **fio**: For performance benchmarking

**Installation Behavior:**
- `apt install truenas-proxmox-plugin` → installs Depends + Recommends by default
- Users can skip recommends with `--no-install-recommends`
- Missing optional tools trigger clear runtime errors with instructions

## Installation Flow

### Install/Upgrade (debian/postinst)

```bash
#!/bin/sh
set -e

case "$1" in
    configure)
        # Validate plugin syntax
        perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm || {
            echo "ERROR: Plugin syntax validation failed"
            exit 1
        }

        # Restart Proxmox services to load plugin
        systemctl restart pvedaemon.service || true
        systemctl restart pveproxy.service || true

        echo "TrueNAS Proxmox Plugin installed successfully"
        echo "Run 'truenas-proxmox-manage' for configuration wizard"
        ;;
esac
```

### Remove (debian/prerm)

```bash
#!/bin/sh
set -e

case "$1" in
    remove)
        # Warn if storage configurations exist
        if grep -q "^truenasplugin:" /etc/pve/storage.cfg 2>/dev/null; then
            echo "WARNING: TrueNAS storage configurations still exist"
            echo "Remove them manually before uninstalling"
        fi
        ;;
esac
```

### Post-Remove (debian/postrm)

```bash
#!/bin/sh
set -e

case "$1" in
    remove)
        systemctl restart pvedaemon.service || true
        systemctl restart pveproxy.service || true
        ;;

    purge)
        rm -rf /usr/share/truenas-proxmox-plugin/ || true
        ;;
esac
```

### Lifecycle Summary

| Event | Actions |
|-------|---------|
| **Install** | Validate syntax → Install files → Restart services → Show usage hint |
| **Upgrade** | Same as install (seamless via `apt upgrade`) |
| **Remove** | Warn about configs → Remove files → Restart services |
| **Purge** | Remove + cleanup shared files |

**Important:** Package never modifies `/etc/pve/storage.cfg` - users manage storage configurations manually or via `truenas-proxmox-manage`.

## GitHub Integration (Apt Repository)

### Architecture

1. **GitHub Releases**: Store `.deb` files as release assets
2. **GitHub Pages**: Host apt repository metadata (gh-pages branch)
3. **GPG Signing**: Sign repository for security

### Repository Structure

```
https://truenas.github.io/truenas-proxmox-plugin/
├── dists/
│   └── stable/
│       └── main/
│           ├── binary-all/
│           │   └── Packages.gz       # Package index
│           ├── Release               # Suite metadata
│           └── InRelease             # Signed Release file
└── pool/
    └── main/
        └── t/
            └── truenas-proxmox-plugin/
                ├── truenas-proxmox-plugin_2.0.3_all.deb
                ├── truenas-proxmox-plugin_2.0.4_all.deb
                └── ...
```

### User Installation

```bash
# Add GPG key
curl -fsSL https://truenas.github.io/truenas-proxmox-plugin/gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/truenas-proxmox-plugin.gpg

# Add apt source
echo "deb [signed-by=/usr/share/keyrings/truenas-proxmox-plugin.gpg] \
    https://truenas.github.io/truenas-proxmox-plugin stable main" > \
    /etc/apt/sources.list.d/truenas-proxmox-plugin.list

# Install
apt update
apt install truenas-proxmox-plugin
```

### Automation (GitHub Actions)

```yaml
# .github/workflows/release.yml
name: Build and Publish Package

on:
  push:
    tags:
      - 'v*'

jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    steps:
      - Build .deb package
      - Upload to GitHub Release
      - Update apt repository metadata
      - Push to gh-pages branch
```

### Release Workflow

1. Update `debian/changelog` with new version
2. Commit changes
3. Create git tag: `git tag v2.0.4`
4. Push tag: `git push origin v2.0.4`
5. GitHub Actions automatically:
   - Builds `.deb` package
   - Uploads to GitHub Release
   - Updates apt repository metadata
   - Pushes to gh-pages branch
6. Users get updates via `apt upgrade`

### Maintenance

- Tag a release → automatic build and publish
- Old versions stay in `pool/` for rollback capability
- GPG key managed via GitHub Secrets
- Repository signing automatic

## Testing Strategy

### Level 1: Package Build Validation

```bash
# Build cleanly
dpkg-buildpackage -us -uc -b

# Check contents
dpkg-deb -c ../truenas-proxmox-plugin_2.0.3_all.deb

# Verify metadata
dpkg-deb -I ../truenas-proxmox-plugin_2.0.3_all.deb

# Quality assurance
lintian ../truenas-proxmox-plugin_2.0.3_all.deb
```

### Level 2: Installation Testing

```bash
# Fresh install
apt install ./truenas-proxmox-plugin_2.0.3_all.deb

# Verify plugin loads
pvesm status

# Check files
ls -la /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
ls -la /usr/share/truenas-proxmox-plugin/install.sh

# Test management script
truenas-proxmox-manage --help
```

### Level 3: Functional Testing

```bash
# Run test suite
/usr/share/truenas-proxmox-plugin/tools/dev-test.sh

# Health checks via management script
truenas-proxmox-manage  # Menu → Diagnostics → Health Checks
```

### Level 4: Upgrade Testing

```bash
# Install old, upgrade to new
apt install truenas-proxmox-plugin=2.0.2
apt install truenas-proxmox-plugin=2.0.3

# Verify
pvesm status
```

### Level 5: Multi-Version Testing

- Proxmox VE 8.x (minimum supported)
- Proxmox VE 9.x (latest)
- TrueNAS SCALE 25.10+ (minimum API version)

### Pre-Release Checklist

- [ ] Package builds without errors
- [ ] Lintian shows no critical issues
- [ ] Fresh install works on clean Proxmox
- [ ] Upgrade from previous version works
- [ ] Plugin loads and shows in `pvesm`
- [ ] Management script accessible via symlink
- [ ] Service restarts succeed
- [ ] Existing test suite passes
- [ ] Version numbers match (package == plugin)

## Implementation Plan

See separate implementation plan document (`2026-02-19-debian-packaging-plan.md`) for detailed step-by-step implementation tasks.

## Success Criteria

**Short-term (Weeks 1-4):**
- [ ] Debian package builds successfully
- [ ] Package installs on Proxmox VE 8.x and 9.x
- [ ] GitHub-based apt repository operational
- [ ] Documentation updated with apt installation instructions

**Medium-term (Months 1-6):**
- [ ] Users successfully install via apt repository
- [ ] Feedback collected and addressed
- [ ] Package tested across diverse Proxmox environments
- [ ] Adoption metrics collected (GitHub stars, downloads, issues)

**Long-term (Months 6-12):**
- [ ] Proven adoption (download metrics, active users)
- [ ] Mature package with few installation issues
- [ ] Ready for Proxmox developer mailing list submission
- [ ] Documentation polished for official review

## Future Enhancements

**Before Proxmox Submission:**
- Refactor `install.sh` into proper CLI tool with man pages
- Add bash completion
- Professional systemd integration if needed
- Comprehensive integration testing suite

**Post-Submission Considerations:**
- Official Proxmox repository inclusion
- Proxmox-managed updates
- Broader community adoption

## References

- [Proxmox Storage Plugin Development Wiki](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
- [Debian New Maintainers' Guide](https://www.debian.org/doc/manuals/maint-guide/)
- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
- [GitHub Pages Documentation](https://docs.github.com/en/pages)

## Approval

**Design Approved:** 2026-02-19
**Approved By:** Project Maintainer
**Next Step:** Create implementation plan via writing-plans skill
