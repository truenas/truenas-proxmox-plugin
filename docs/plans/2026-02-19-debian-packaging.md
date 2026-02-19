# Debian Packaging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert TrueNAS Proxmox plugin to proper Debian package with GitHub-hosted apt repository

**Architecture:** Single debian package containing plugin + management script, lockstep versioning via debian/changelog, automated GitHub Actions build/publish pipeline

**Tech Stack:** Debian packaging (debhelper, dpkg-buildpackage), GitHub Actions, GitHub Pages, GPG signing

---

## Task 1: Create Debian Directory Structure

**Files:**
- Create: `debian/` (directory)
- Create: `debian/source/` (directory)

**Step 1: Create debian directories**

```bash
mkdir -p debian/source
```

**Step 2: Verify structure**

Run: `ls -la debian/`
Expected: `debian/` and `debian/source/` directories exist

**Step 3: Commit**

```bash
git add debian/
git commit -m "chore: initialize debian packaging directory structure"
```

---

## Task 2: Create debian/compat

**Files:**
- Create: `debian/compat`

**Step 1: Write debian/compat**

This file specifies the debhelper compatibility level (13 is current stable):

```
13
```

**Step 2: Verify file**

Run: `cat debian/compat`
Expected: Shows "13"

**Step 3: Commit**

```bash
git add debian/compat
git commit -m "chore: add debhelper compatibility level"
```

---

## Task 3: Create debian/source/format

**Files:**
- Create: `debian/source/format`

**Step 1: Write debian/source/format**

Specifies source package format (native format since we're not packaging external software):

```
3.0 (native)
```

**Step 2: Verify file**

Run: `cat debian/source/format`
Expected: Shows "3.0 (native)"

**Step 3: Commit**

```bash
git add debian/source/format
git commit -m "chore: set debian source package format"
```

---

## Task 4: Create debian/copyright

**Files:**
- Create: `debian/copyright`
- Reference: `LICENSE` (existing file)

**Step 1: Write debian/copyright**

Machine-readable copyright file following DEP-5 format:

```
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: truenas-proxmox-plugin
Upstream-Contact: TrueNAS <https://github.com/truenas/truenas-proxmox-plugin>
Source: https://github.com/truenas/truenas-proxmox-plugin

Files: *
Copyright: 2025-2026 TrueNAS Contributors
License: AGPL-3.0-or-later

Files: debian/*
Copyright: 2026 TrueNAS Contributors
License: AGPL-3.0-or-later

License: AGPL-3.0-or-later
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 .
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.
 .
 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 .
 On Debian systems, the complete text of the GNU Affero General Public
 License version 3 can be found in "/usr/share/common-licenses/AGPL-3".
```

**Step 2: Verify file**

Run: `head -20 debian/copyright`
Expected: Shows copyright header with AGPL-3.0-or-later license

**Step 3: Commit**

```bash
git add debian/copyright
git commit -m "chore: add debian copyright file with AGPL-3.0 license"
```

---

## Task 5: Create debian/control

**Files:**
- Create: `debian/control`

**Step 1: Write debian/control**

Package metadata and dependencies:

```
Source: truenas-proxmox-plugin
Section: admin
Priority: optional
Maintainer: TrueNAS Contributors <noreply@truenas.com>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.6.2
Homepage: https://github.com/truenas/truenas-proxmox-plugin
Vcs-Browser: https://github.com/truenas/truenas-proxmox-plugin
Vcs-Git: https://github.com/truenas/truenas-proxmox-plugin.git
Rules-Requires-Root: no

Package: truenas-proxmox-plugin
Architecture: all
Depends: ${misc:Depends},
         pve-manager (>= 8.0.0),
         open-iscsi,
         perl (>= 5.32),
         libjson-pp-perl,
         liburi-perl,
         libio-socket-ssl-perl
Recommends: nvme-cli,
            multipath-tools
Suggests: fio
Description: TrueNAS SCALE storage plugin for Proxmox VE
 High-performance storage plugin for Proxmox VE that integrates TrueNAS SCALE
 via iSCSI or NVMe/TCP, featuring live snapshots, ZFS integration, and cluster
 compatibility.
 .
 Features:
  * Dual transport support (iSCSI and NVMe/TCP)
  * ZFS snapshots and clones
  * Live VM snapshots with RAM state (vmstate)
  * Cluster-compatible shared storage
  * Automatic volume management via TrueNAS API
  * Thin provisioning and ZFS compression
  * Multi-path I/O support
  * CHAP authentication for iSCSI
 .
 This package includes the Proxmox storage plugin and management utilities.
```

**Step 2: Verify dependencies format**

Run: `grep -A 10 "^Depends:" debian/control`
Expected: Shows properly formatted dependency list

**Step 3: Commit**

```bash
git add debian/control
git commit -m "chore: add debian control file with package metadata and dependencies"
```

---

## Task 6: Create debian/changelog

**Files:**
- Create: `debian/changelog`

**Step 1: Write debian/changelog**

Initial changelog entry (VERSION SOURCE OF TRUTH):

```
truenas-proxmox-plugin (2.0.3) stable; urgency=medium

  * Initial debian package release
  * Convert from bash installer to proper debian package
  * Add lockstep versioning (package version = plugin version)
  * Include management script as companion tool
  * Support for Proxmox VE 8.x and 9.x
  * Support for TrueNAS SCALE 25.10+

 -- TrueNAS Contributors <noreply@truenas.com>  Wed, 19 Feb 2026 12:00:00 -0600
```

**Step 2: Verify changelog format**

Run: `dpkg-parsechangelog`
Expected: Parses successfully and shows version "2.0.3"

**Step 3: Test version extraction**

Run: `dpkg-parsechangelog -S Version`
Expected: Outputs "2.0.3"

**Step 4: Commit**

```bash
git add debian/changelog
git commit -m "chore: add debian changelog with initial 2.0.3 release"
```

---

## Task 7: Create debian/rules

**Files:**
- Create: `debian/rules`

**Step 1: Write debian/rules**

Build rules with version injection and file installation:

```makefile
#!/usr/bin/make -f

export DH_VERBOSE = 1

%:
	dh $@

override_dh_auto_build:
	# Extract version from changelog and inject into plugin
	$(eval PKG_VERSION := $(shell dpkg-parsechangelog -S Version))
	sed -i.bak "s/^our \$$VERSION = '.*';/our \$$VERSION = '$(PKG_VERSION)';/" TrueNASPlugin.pm
	@echo "Injected version $(PKG_VERSION) into TrueNASPlugin.pm"

override_dh_auto_install:
	# Install plugin to Proxmox location
	install -D -m 644 TrueNASPlugin.pm \
		debian/truenas-proxmox-plugin/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

	# Install management script
	install -D -m 755 install.sh \
		debian/truenas-proxmox-plugin/usr/share/truenas-proxmox-plugin/install.sh

	# Install test utilities
	install -D -m 755 tools/dev-truenas-plugin-full-function-test.sh \
		debian/truenas-proxmox-plugin/usr/share/truenas-proxmox-plugin/tools/dev-test.sh

	# Create convenience symlink
	mkdir -p debian/truenas-proxmox-plugin/usr/local/bin
	ln -s ../../share/truenas-proxmox-plugin/install.sh \
		debian/truenas-proxmox-plugin/usr/local/bin/truenas-proxmox-manage

override_dh_auto_clean:
	dh_auto_clean
	# Restore original plugin file if backup exists
	[ -f TrueNASPlugin.pm.bak ] && mv TrueNASPlugin.pm.bak TrueNASPlugin.pm || true
```

**Step 2: Make rules executable**

Run: `chmod +x debian/rules`

**Step 3: Verify rules are executable**

Run: `ls -l debian/rules`
Expected: Shows `-rwxr-xr-x` permissions

**Step 4: Commit**

```bash
git add debian/rules
git commit -m "chore: add debian rules with version injection and installation logic"
```

---

## Task 8: Create debian/postinst

**Files:**
- Create: `debian/postinst`

**Step 1: Write debian/postinst**

Post-installation script (validates plugin and restarts services):

```bash
#!/bin/sh
set -e

case "$1" in
    configure)
        # Validate plugin syntax
        if ! perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm >/dev/null 2>&1; then
            echo "ERROR: Plugin syntax validation failed" >&2
            exit 1
        fi

        # Restart Proxmox services to load plugin
        if systemctl is-active --quiet pvedaemon.service; then
            systemctl restart pvedaemon.service || true
        fi

        if systemctl is-active --quiet pveproxy.service; then
            systemctl restart pveproxy.service || true
        fi

        echo ""
        echo "TrueNAS Proxmox Plugin installed successfully (version $(dpkg-query -W -f='${Version}' truenas-proxmox-plugin))"
        echo ""
        echo "Configuration options:"
        echo "  1. Run 'truenas-proxmox-manage' for interactive configuration wizard"
        echo "  2. Manually edit /etc/pve/storage.cfg"
        echo ""
        echo "Documentation: https://github.com/truenas/truenas-proxmox-plugin/wiki"
        echo ""
        ;;

    abort-upgrade|abort-remove|abort-deconfigure)
        # Nothing to do
        ;;

    *)
        echo "postinst called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac

#DEBHELPER#

exit 0
```

**Step 2: Make postinst executable**

Run: `chmod +x debian/postinst`

**Step 3: Verify postinst syntax**

Run: `sh -n debian/postinst`
Expected: No syntax errors

**Step 4: Commit**

```bash
git add debian/postinst
git commit -m "chore: add postinst script for plugin validation and service restart"
```

---

## Task 9: Create debian/prerm

**Files:**
- Create: `debian/prerm`

**Step 1: Write debian/prerm**

Pre-removal script (warns about existing configurations):

```bash
#!/bin/sh
set -e

case "$1" in
    remove|deconfigure)
        # Check if storage configurations exist
        if [ -f /etc/pve/storage.cfg ] && grep -q "^truenasplugin:" /etc/pve/storage.cfg 2>/dev/null; then
            echo ""
            echo "========================================" >&2
            echo "WARNING: TrueNAS storage configurations still exist in /etc/pve/storage.cfg" >&2
            echo ""
            echo "The plugin will be removed, but your storage configurations will remain." >&2
            echo "To completely remove TrueNAS storage:" >&2
            echo "  1. Remove storage entries from Proxmox GUI or CLI" >&2
            echo "  2. Run 'truenas-proxmox-manage' and use orphan cleanup (if needed)" >&2
            echo "  3. Then purge the package: apt purge truenas-proxmox-plugin" >&2
            echo "========================================" >&2
            echo ""
        fi
        ;;

    upgrade|failed-upgrade)
        # Nothing to do on upgrade
        ;;

    *)
        echo "prerm called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac

#DEBHELPER#

exit 0
```

**Step 2: Make prerm executable**

Run: `chmod +x debian/prerm`

**Step 3: Verify prerm syntax**

Run: `sh -n debian/prerm`
Expected: No syntax errors

**Step 4: Commit**

```bash
git add debian/prerm
git commit -m "chore: add prerm script to warn about existing storage configs"
```

---

## Task 10: Create debian/postrm

**Files:**
- Create: `debian/postrm`

**Step 1: Write debian/postrm**

Post-removal script (cleans up and restarts services):

```bash
#!/bin/sh
set -e

case "$1" in
    remove)
        # Restart Proxmox services to unload plugin
        if systemctl is-active --quiet pvedaemon.service; then
            systemctl restart pvedaemon.service || true
        fi

        if systemctl is-active --quiet pveproxy.service; then
            systemctl restart pveproxy.service || true
        fi

        echo "TrueNAS Proxmox Plugin removed"
        ;;

    purge)
        # On purge, remove any leftover files
        rm -rf /usr/share/truenas-proxmox-plugin/ 2>/dev/null || true

        # Restart services
        if systemctl is-active --quiet pvedaemon.service; then
            systemctl restart pvedaemon.service || true
        fi

        if systemctl is-active --quiet pveproxy.service; then
            systemctl restart pveproxy.service || true
        fi

        echo "TrueNAS Proxmox Plugin purged"
        ;;

    upgrade|failed-upgrade|abort-install|abort-upgrade|disappear)
        # Nothing to do
        ;;

    *)
        echo "postrm called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac

#DEBHELPER#

exit 0
```

**Step 2: Make postrm executable**

Run: `chmod +x debian/postrm`

**Step 3: Verify postrm syntax**

Run: `sh -n debian/postrm`
Expected: No syntax errors

**Step 4: Commit**

```bash
git add debian/postrm
git commit -m "chore: add postrm script for cleanup and service restart"
```

---

## Task 11: Test Local Package Build

**Files:**
- Test: All debian/* files
- Output: `../truenas-proxmox-plugin_2.0.3_all.deb` (generated)

**Step 1: Install build dependencies**

Run: `sudo apt-get install -y debhelper devscripts`
Expected: Build tools installed

**Step 2: Build the package (unsigned, binary-only)**

Run: `dpkg-buildpackage -us -uc -b`
Expected: Build completes successfully

**Step 3: Verify package was created**

Run: `ls -lh ../truenas-proxmox-plugin_2.0.3_all.deb`
Expected: Shows .deb file (approximately 200-300KB)

**Step 4: Check package contents**

Run: `dpkg-deb -c ../truenas-proxmox-plugin_2.0.3_all.deb`
Expected: Shows files in correct locations:
- `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`
- `/usr/share/truenas-proxmox-plugin/install.sh`
- `/usr/share/truenas-proxmox-plugin/tools/dev-test.sh`
- `/usr/local/bin/truenas-proxmox-manage` (symlink)

**Step 5: Check package metadata**

Run: `dpkg-deb -I ../truenas-proxmox-plugin_2.0.3_all.deb`
Expected: Shows version 2.0.3, dependencies, description

**Step 6: Run lintian quality checks**

Run: `lintian ../truenas-proxmox-plugin_2.0.3_all.deb`
Expected: No errors (warnings acceptable)

**Step 7: Verify version injection worked**

Run: `dpkg-deb -x ../truenas-proxmox-plugin_2.0.3_all.deb /tmp/test-extract && grep "^our \$VERSION" /tmp/test-extract/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm && rm -rf /tmp/test-extract`
Expected: Shows `our $VERSION = '2.0.3';`

**Step 8: Create .gitignore for build artifacts**

```bash
echo "# Debian build artifacts" >> .gitignore
echo "debian/truenas-proxmox-plugin/" >> .gitignore
echo "debian/.debhelper/" >> .gitignore
echo "debian/files" >> .gitignore
echo "debian/*.substvars" >> .gitignore
echo "debian/*.log" >> .gitignore
echo "TrueNASPlugin.pm.bak" >> .gitignore
```

**Step 9: Commit gitignore**

```bash
git add .gitignore
git commit -m "chore: ignore debian build artifacts"
```

---

## Task 12: Create Build Test Script

**Files:**
- Create: `tools/build-deb.sh`

**Step 1: Write build script**

Convenience script for building and testing the package:

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=========================================="
echo "Building TrueNAS Proxmox Plugin Package"
echo "=========================================="
echo ""

# Check for build dependencies
if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
    echo "ERROR: dpkg-buildpackage not found"
    echo "Install: sudo apt-get install -y debhelper devscripts"
    exit 1
fi

# Extract version from changelog
VERSION=$(dpkg-parsechangelog -S Version)
echo "Package version: $VERSION"
echo ""

# Clean previous builds
echo "Cleaning previous build artifacts..."
rm -f ../truenas-proxmox-plugin_*.deb
rm -f ../truenas-proxmox-plugin_*.buildinfo
rm -f ../truenas-proxmox-plugin_*.changes
rm -f TrueNASPlugin.pm.bak
debian/rules clean >/dev/null 2>&1 || true
echo ""

# Build package
echo "Building package..."
dpkg-buildpackage -us -uc -b
echo ""

# Show result
echo "=========================================="
echo "Build Complete!"
echo "=========================================="
echo ""
ls -lh ../truenas-proxmox-plugin_${VERSION}_all.deb
echo ""

# Run lintian
echo "Running lintian quality checks..."
lintian ../truenas-proxmox-plugin_${VERSION}_all.deb || true
echo ""

# Show contents
echo "Package contents:"
dpkg-deb -c ../truenas-proxmox-plugin_${VERSION}_all.deb
echo ""

echo "=========================================="
echo "Package ready: ../truenas-proxmox-plugin_${VERSION}_all.deb"
echo "=========================================="
```

**Step 2: Make script executable**

Run: `chmod +x tools/build-deb.sh`

**Step 3: Test build script**

Run: `./tools/build-deb.sh`
Expected: Builds package successfully and shows summary

**Step 4: Commit**

```bash
git add tools/build-deb.sh
git commit -m "chore: add convenience script for building debian package"
```

---

## Task 13: Create GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/build-package.yml`

**Step 1: Create workflows directory**

```bash
mkdir -p .github/workflows
```

**Step 2: Write GitHub Actions workflow**

```yaml
name: Build Debian Package

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to build (e.g., 2.0.3)'
        required: false

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y debhelper devscripts lintian

      - name: Extract version
        id: version
        run: |
          if [ -n "${{ github.event.inputs.version }}" ]; then
            VERSION="${{ github.event.inputs.version }}"
          elif [[ "${{ github.ref }}" == refs/tags/v* ]]; then
            VERSION="${{ github.ref_name }}"
            VERSION="${VERSION#v}"
          else
            VERSION=$(dpkg-parsechangelog -S Version)
          fi
          echo "version=$VERSION" >> $GITHUB_OUTPUT
          echo "Building version: $VERSION"

      - name: Build debian package
        run: |
          dpkg-buildpackage -us -uc -b

      - name: Run lintian checks
        run: |
          lintian ../truenas-proxmox-plugin_${{ steps.version.outputs.version }}_all.deb || true

      - name: List package contents
        run: |
          dpkg-deb -c ../truenas-proxmox-plugin_${{ steps.version.outputs.version }}_all.deb
          dpkg-deb -I ../truenas-proxmox-plugin_${{ steps.version.outputs.version }}_all.deb

      - name: Upload package artifact
        uses: actions/upload-artifact@v4
        with:
          name: truenas-proxmox-plugin_${{ steps.version.outputs.version }}_all
          path: ../truenas-proxmox-plugin_${{ steps.version.outputs.version }}_all.deb
          retention-days: 90

      - name: Create GitHub Release
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v1
        with:
          files: ../truenas-proxmox-plugin_${{ steps.version.outputs.version }}_all.deb
          generate_release_notes: true
          draft: false
          prerelease: false
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Step 3: Verify workflow syntax**

Run: `cat .github/workflows/build-package.yml | head -20`
Expected: Shows valid YAML

**Step 4: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "ci: add GitHub Actions workflow for building debian package"
```

---

## Task 14: Create APT Repository Setup Script

**Files:**
- Create: `tools/setup-apt-repo.sh`

**Step 1: Write repository setup script**

Script to initialize GitHub Pages-based apt repository:

```bash
#!/bin/bash
set -e

echo "=========================================="
echo "TrueNAS Proxmox Plugin - APT Repository Setup"
echo "=========================================="
echo ""
echo "This script helps set up a GitHub Pages-based APT repository."
echo ""
echo "Prerequisites:"
echo "  1. GPG key for signing (gpg --gen-key)"
echo "  2. GitHub repository with Pages enabled"
echo "  3. gh-pages branch created"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Check for GPG key
echo ""
echo "Checking for GPG keys..."
if ! gpg --list-secret-keys >/dev/null 2>&1; then
    echo "ERROR: No GPG keys found"
    echo "Generate one with: gpg --gen-key"
    exit 1
fi

echo ""
echo "Available GPG keys:"
gpg --list-secret-keys --keyid-format LONG
echo ""
read -p "Enter GPG key ID to use: " GPG_KEY_ID

# Export public key
echo ""
echo "Exporting public key..."
gpg --armor --export "$GPG_KEY_ID" > truenas-proxmox-plugin.gpg.asc
echo "Public key exported to: truenas-proxmox-plugin.gpg.asc"

echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo ""
echo "1. Create gh-pages branch:"
echo "   git checkout --orphan gh-pages"
echo "   git rm -rf ."
echo "   mkdir -p dists/stable/main/binary-all"
echo "   mkdir -p pool/main/t/truenas-proxmox-plugin"
echo ""
echo "2. Copy public key to gh-pages:"
echo "   cp truenas-proxmox-plugin.gpg.asc gpg.key"
echo "   git add gpg.key"
echo ""
echo "3. Add built .deb files to pool/:"
echo "   cp ../truenas-proxmox-plugin_*.deb pool/main/t/truenas-proxmox-plugin/"
echo ""
echo "4. Generate repository metadata:"
echo "   cd dists/stable/main/binary-all"
echo "   dpkg-scanpackages -m ../../../../pool > Packages"
echo "   gzip -k Packages"
echo "   cd ../.."
echo "   apt-ftparchive release . > Release"
echo "   gpg --default-key $GPG_KEY_ID -abs -o Release.gpg Release"
echo "   gpg --default-key $GPG_KEY_ID --clearsign -o InRelease Release"
echo ""
echo "5. Commit and push to gh-pages"
echo ""
echo "=========================================="
echo "User Installation Instructions:"
echo "=========================================="
echo ""
echo "# Add GPG key"
echo "curl -fsSL https://YOURUSERNAME.github.io/truenas-proxmox-plugin/gpg.key | \\"
echo "  gpg --dearmor -o /usr/share/keyrings/truenas-proxmox-plugin.gpg"
echo ""
echo "# Add apt source"
echo "echo \"deb [signed-by=/usr/share/keyrings/truenas-proxmox-plugin.gpg] \\"
echo "  https://YOURUSERNAME.github.io/truenas-proxmox-plugin stable main\" > \\"
echo "  /etc/apt/sources.list.d/truenas-proxmox-plugin.list"
echo ""
echo "# Install"
echo "apt update"
echo "apt install truenas-proxmox-plugin"
echo ""
```

**Step 2: Make script executable**

Run: `chmod +x tools/setup-apt-repo.sh`

**Step 3: Commit**

```bash
git add tools/setup-apt-repo.sh
git commit -m "chore: add APT repository setup helper script"
```

---

## Task 15: Update README with Debian Installation

**Files:**
- Modify: `README.md:52-100`

**Step 1: Add debian installation section to README**

Find the "Installation" section and add before the current bash installer method:

```markdown
### Installation via APT Repository (Recommended)

For the easiest installation and automatic updates:

```bash
# Add GPG key
curl -fsSL https://truenas.github.io/truenas-proxmox-plugin/gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/truenas-proxmox-plugin.gpg

# Add apt source
echo "deb [signed-by=/usr/share/keyrings/truenas-proxmox-plugin.gpg] \
    https://truenas.github.io/truenas-proxmox-plugin stable main" | \
    sudo tee /etc/apt/sources.list.d/truenas-proxmox-plugin.list

# Install
sudo apt update
sudo apt install truenas-proxmox-plugin

# Run configuration wizard
truenas-proxmox-manage
```

**Updates:** Automatic via `apt upgrade`

### Installation via Debian Package

Download the latest .deb package from [GitHub Releases](https://github.com/truenas/truenas-proxmox-plugin/releases):

```bash
# Download latest release
wget https://github.com/truenas/truenas-proxmox-plugin/releases/download/v2.0.3/truenas-proxmox-plugin_2.0.3_all.deb

# Install
sudo apt install ./truenas-proxmox-plugin_2.0.3_all.deb

# Run configuration wizard
truenas-proxmox-manage
```
```

**Step 2: Verify README formatting**

Run: `head -80 README.md`
Expected: Shows new installation methods prominently

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add debian package installation methods to README"
```

---

## Task 16: Create Packaging Documentation

**Files:**
- Create: `docs/PACKAGING.md`

**Step 1: Write packaging documentation**

```markdown
# Debian Packaging Guide

This document describes how to build, test, and publish the TrueNAS Proxmox Plugin debian package.

## Quick Build

```bash
# Install dependencies
sudo apt-get install -y debhelper devscripts lintian

# Build package
./tools/build-deb.sh

# Output: ../truenas-proxmox-plugin_VERSION_all.deb
```

## Package Structure

The debian package includes:
- **Plugin**: `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm`
- **Management Script**: `/usr/share/truenas-proxmox-plugin/install.sh`
- **Test Utilities**: `/usr/share/truenas-proxmox-plugin/tools/`
- **Symlink**: `/usr/local/bin/truenas-proxmox-manage` → install.sh

## Version Management

**Source of Truth:** `debian/changelog`

The build process automatically:
1. Extracts version from `debian/changelog` via `dpkg-parsechangelog`
2. Injects version into `TrueNASPlugin.pm` during build
3. Ensures package version and plugin version match (lockstep)

### Updating Version

```bash
# Edit debian/changelog (add new entry at top)
dch -v 2.0.4 "New release with features X, Y, Z"

# Or manually:
cat > debian/changelog << 'EOF'
truenas-proxmox-plugin (2.0.4) stable; urgency=medium

  * Feature X
  * Bug fix Y
  * Enhancement Z

 -- TrueNAS Contributors <noreply@truenas.com>  $(date -R)

$(cat debian/changelog)
EOF

# Build with new version
./tools/build-deb.sh
```

## Testing

### Local Testing

```bash
# Build
./tools/build-deb.sh

# Install locally
sudo apt install ../truenas-proxmox-plugin_VERSION_all.deb

# Verify plugin loads
pvesm status | grep truenasplugin

# Test management script
truenas-proxmox-manage

# Remove
sudo apt remove truenas-proxmox-plugin

# Or purge (removes shared files too)
sudo apt purge truenas-proxmox-plugin
```

### Quality Checks

```bash
# Lintian (Debian quality assurance)
lintian ../truenas-proxmox-plugin_VERSION_all.deb

# Check package contents
dpkg-deb -c ../truenas-proxmox-plugin_VERSION_all.deb

# Check metadata
dpkg-deb -I ../truenas-proxmox-plugin_VERSION_all.deb

# Verify version injection
dpkg-deb -x ../truenas-proxmox-plugin_VERSION_all.deb /tmp/test
grep "VERSION" /tmp/test/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
rm -rf /tmp/test
```

## Publishing to GitHub

### Automated (via GitHub Actions)

```bash
# Update version in debian/changelog
dch -v 2.0.4 "Release notes"

# Commit
git add debian/changelog
git commit -m "chore: bump version to 2.0.4"

# Tag and push
git tag v2.0.4
git push origin main v2.0.4

# GitHub Actions automatically:
# - Builds package
# - Runs lintian checks
# - Creates GitHub Release with .deb file
```

### Manual Release

```bash
# Build package
./tools/build-deb.sh

# Create GitHub release manually
gh release create v2.0.4 \
    ../truenas-proxmox-plugin_2.0.4_all.deb \
    --title "v2.0.4" \
    --notes "Release notes here"
```

## APT Repository Setup

See `tools/setup-apt-repo.sh` for setting up a GitHub Pages-based APT repository.

### Quick Setup

```bash
# Run setup helper
./tools/setup-apt-repo.sh

# Follow instructions to:
# 1. Generate/select GPG key
# 2. Create gh-pages branch
# 3. Build repository structure
# 4. Sign and publish
```

### Manual Repository Maintenance

```bash
# Switch to gh-pages branch
git checkout gh-pages

# Add new .deb file
cp ../truenas-proxmox-plugin_2.0.4_all.deb pool/main/t/truenas-proxmox-plugin/

# Regenerate package index
cd dists/stable/main/binary-all
dpkg-scanpackages -m ../../../../pool > Packages
gzip -k -f Packages

# Sign release
cd ../..
apt-ftparchive release . > Release
gpg --default-key YOUR_KEY_ID -abs -o Release.gpg Release
gpg --default-key YOUR_KEY_ID --clearsign -o InRelease Release

# Commit and push
git add pool/ dists/
git commit -m "Add truenas-proxmox-plugin 2.0.4"
git push origin gh-pages
```

## Troubleshooting

### Build Failures

**Problem:** `dpkg-buildpackage: error: cannot read debian/changelog`
**Solution:** Ensure changelog is properly formatted with `dch` or manual edit

**Problem:** `dh_auto_install: error: missing debian/tmp directory`
**Solution:** Check `debian/rules` override_dh_auto_install is creating directories

**Problem:** Version injection failed
**Solution:** Check `debian/rules` override_dh_auto_build sed command

### Installation Issues

**Problem:** `Depends: pve-manager (>= 8.0.0) but it is not installable`
**Solution:** Package can only install on Proxmox VE 8.x+

**Problem:** Plugin doesn't load after install
**Solution:** Check `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm` exists and services restarted

## References

- [Debian New Maintainers' Guide](https://www.debian.org/doc/manuals/maint-guide/)
- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
- [Debhelper Documentation](https://manpages.debian.org/testing/debhelper/debhelper.7.en.html)
- [Proxmox Storage Plugin Development](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
```

**Step 2: Commit**

```bash
git add docs/PACKAGING.md
git commit -m "docs: add comprehensive debian packaging guide"
```

---

## Task 17: Final Integration Test

**Files:**
- Test: All components together

**Step 1: Clean build test**

Run: `git clean -fdx debian/ && ./tools/build-deb.sh`
Expected: Builds successfully from clean state

**Step 2: Verify all debian files exist**

Run: `ls -la debian/`
Expected: Shows all files: control, changelog, rules, postinst, prerm, postrm, compat, copyright, source/format

**Step 3: Test version extraction**

Run: `dpkg-parsechangelog -S Version`
Expected: Shows current version (2.0.3)

**Step 4: Verify package quality**

Run: `lintian --pedantic ../truenas-proxmox-plugin_2.0.3_all.deb 2>&1 | tee lintian-report.txt`
Expected: No errors (warnings/info acceptable)

**Step 5: Create tag for current version**

```bash
git tag v2.0.3-deb1 -m "First debian package release for 2.0.3"
```

**Step 6: Document completion**

```bash
cat >> docs/plans/2026-02-19-debian-packaging.md << 'EOF'

---

## Implementation Status

- [x] Task 1: Create Debian Directory Structure
- [x] Task 2: Create debian/compat
- [x] Task 3: Create debian/source/format
- [x] Task 4: Create debian/copyright
- [x] Task 5: Create debian/control
- [x] Task 6: Create debian/changelog
- [x] Task 7: Create debian/rules
- [x] Task 8: Create debian/postinst
- [x] Task 9: Create debian/prerm
- [x] Task 10: Create debian/postrm
- [x] Task 11: Test Local Package Build
- [x] Task 12: Create Build Test Script
- [x] Task 13: Create GitHub Actions Workflow
- [x] Task 14: Create APT Repository Setup Script
- [x] Task 15: Update README with Debian Installation
- [x] Task 16: Create Packaging Documentation
- [x] Task 17: Final Integration Test

**Completed:** 2026-02-19
**Package Version:** 2.0.3
**Status:** Ready for testing and release

EOF
```

**Step 7: Final commit**

```bash
git add docs/plans/2026-02-19-debian-packaging.md
git commit -m "docs: mark debian packaging implementation complete

All debian packaging infrastructure in place:
- Debian package builds successfully
- Version injection working (lockstep versioning)
- GitHub Actions workflow ready
- Documentation complete
- Ready for APT repository setup and release"
```

---

## Post-Implementation Tasks

### APT Repository Setup (Manual)

1. Run `./tools/setup-apt-repo.sh` to generate GPG key and instructions
2. Create `gh-pages` branch for repository
3. Build repository structure and add initial package
4. Test installation from repository
5. Document repository URL in README

### Release Process

1. Update `debian/changelog` with new version and changes
2. Commit changelog
3. Create git tag: `git tag v2.0.X`
4. Push tag: `git push origin v2.0.X`
5. GitHub Actions builds and publishes automatically
6. Update APT repository on gh-pages branch
7. Announce release

### Testing Checklist

- [ ] Build package on clean system
- [ ] Install on Proxmox VE 8.x
- [ ] Install on Proxmox VE 9.x
- [ ] Verify plugin loads (`pvesm status`)
- [ ] Test management script (`truenas-proxmox-manage`)
- [ ] Test upgrade path (install old, upgrade to new)
- [ ] Test removal (`apt remove`)
- [ ] Test purge (`apt purge`)
- [ ] Verify no leftover files after purge

## Success Criteria

- [x] Debian package builds without errors
- [x] Lintian shows no critical issues
- [x] Version injection works (lockstep versioning)
- [x] All maintainer scripts have proper error handling
- [x] GitHub Actions workflow configured
- [ ] APT repository operational (manual setup required)
- [ ] Documentation complete and accurate
- [ ] Package tested on Proxmox VE 8.x and 9.x

## Notes

- Initial package builds successfully
- Lockstep versioning implemented via `debian/rules`
- Management script preserved as companion tool
- APT repository requires manual GitHub Pages setup (one-time)
- Ready for community testing and feedback

---

## Implementation Status

- [x] Task 1: Create Debian Directory Structure
- [x] Task 2: Create debian/compat (removed - modern approach uses debhelper-compat)
- [x] Task 3: Create debian/source/format
- [x] Task 4: Create debian/copyright
- [x] Task 5: Create debian/control
- [x] Task 6: Create debian/changelog
- [x] Task 7: Create debian/rules
- [x] Task 8: Create debian/postinst
- [x] Task 9: Create debian/prerm
- [x] Task 10: Create debian/postrm
- [x] Task 11: Test Local Package Build
- [x] Task 12: Create Build Test Script
- [x] Task 13: Create GitHub Actions Workflow
- [x] Task 14: Create APT Repository Setup Script
- [x] Task 15: Update README with Debian Installation
- [x] Task 16: Create Packaging Documentation
- [x] Task 17: Final Integration Test

**Completed:** 2026-02-19
**Package Version:** 2.0.3
**Status:** Ready for testing and release

