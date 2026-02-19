# Debian Packaging Guide

This guide covers building, testing, and distributing the TrueNAS Proxmox Plugin as a Debian package.

## Table of Contents

- [Overview](#overview)
- [Package Structure](#package-structure)
- [Building the Package](#building-the-package)
- [Testing the Package](#testing-the-package)
- [Distribution](#distribution)
- [Continuous Integration](#continuous-integration)
- [Release Process](#release-process)
- [APT Repository Setup](#apt-repository-setup)
- [Troubleshooting](#troubleshooting)

## Overview

The TrueNAS Proxmox Plugin is distributed as a Debian package for easy installation and management on Proxmox VE systems. The package provides:

- Automated installation to correct Perl module paths
- Service restart handling via maintainer scripts
- Proper dependency management
- Clean uninstallation with backup support
- Integration with APT package management

### Package Information

- **Package Name**: `truenas-proxmox-plugin`
- **Architecture**: `all` (architecture-independent Perl code)
- **Section**: `admin`
- **Priority**: `optional`

## Package Structure

The Debian packaging files are located in the `debian/` directory:

```
debian/
├── truenas-proxmox-plugin/          # Build staging directory
│   ├── DEBIAN/                      # Control files
│   │   ├── control                  # Package metadata
│   │   ├── postinst                 # Post-installation script
│   │   ├── prerm                    # Pre-removal script
│   │   └── postrm                   # Post-removal script
│   └── usr/
│       └── share/
│           ├── doc/truenas-proxmox-plugin/
│           │   ├── changelog.Debian.gz
│           │   └── copyright
│           └── perl5/PVE/Storage/Custom/
│               └── TrueNASPlugin.pm
├── changelog                        # Debian changelog
├── compat                          # Debhelper compatibility level
├── control                         # Source package control
├── copyright                       # Copyright and license info
├── postinst                        # Post-install script source
├── prerm                          # Pre-remove script source
├── postrm                         # Post-remove script source
├── rules                          # Build instructions
└── source/
    └── format                     # Source format version
```

## Building the Package

### Prerequisites

Install build dependencies:

```bash
apt-get update
apt-get install dpkg-dev lintian
```

### Quick Build

Use the convenience script:

```bash
# Simple build
./tools/build-deb.sh

# Clean build with tests
./tools/build-deb.sh --clean --test

# Build and install
sudo ./tools/build-deb.sh --install

# Verbose output
./tools/build-deb.sh --verbose
```

### Manual Build

Build the package manually:

```bash
# Build the package
dpkg-deb --build debian/truenas-proxmox-plugin

# The .deb file will be created as:
# debian/truenas-proxmox-plugin.deb
```

### Build Output

After building, you'll have:

```
truenas-proxmox-plugin_2.0.3_all.deb    # ~120KB package file
```

## Testing the Package

### Automated Testing

The build script includes testing options:

```bash
# Test package contents
./tools/build-deb.sh --test

# Test installation (requires root)
sudo ./tools/build-deb.sh --install
```

### Manual Testing

#### 1. Inspect Package Contents

```bash
# Show package information
dpkg-deb --info truenas-proxmox-plugin_2.0.3_all.deb

# List files in package
dpkg-deb --contents truenas-proxmox-plugin_2.0.3_all.deb

# Extract control files
dpkg-deb --control truenas-proxmox-plugin_2.0.3_all.deb /tmp/control-files
```

#### 2. Run Lintian Checks

```bash
# Check package quality
lintian truenas-proxmox-plugin_2.0.3_all.deb

# Show only errors and warnings
lintian truenas-proxmox-plugin_2.0.3_all.deb | grep -E "^[EW]:"

# Verbose output
lintian -v truenas-proxmox-plugin_2.0.3_all.deb
```

#### 3. Test Installation

```bash
# Install package
sudo dpkg -i truenas-proxmox-plugin_2.0.3_all.deb

# Verify installation
dpkg -l truenas-proxmox-plugin
dpkg -L truenas-proxmox-plugin

# Check plugin file
ls -l /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Check services (if on Proxmox)
systemctl status pvedaemon pveproxy
```

#### 4. Test Removal

```bash
# Remove package (keeps configuration)
sudo dpkg -r truenas-proxmox-plugin

# Verify removal
dpkg -l truenas-proxmox-plugin
ls /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Purge package (removes everything)
sudo dpkg -P truenas-proxmox-plugin
```

### Testing Checklist

- [ ] Package builds without errors
- [ ] Lintian shows no critical errors
- [ ] Package contains all required files
- [ ] Plugin file has correct permissions (644)
- [ ] Documentation is included
- [ ] Package installs cleanly
- [ ] Services restart successfully (on Proxmox)
- [ ] Package removes cleanly
- [ ] Backup is created on removal

## Distribution

### GitHub Releases

Packages are automatically built and published via GitHub Actions:

1. **On Push/PR**: Builds package and runs tests
2. **On Version Tags**: Creates GitHub release with .deb file

#### Downloading from Releases

```bash
# Download latest release
wget https://github.com/truenas/truenas-proxmox-plugin/releases/latest/download/truenas-proxmox-plugin_2.0.3_all.deb

# Download specific version
wget https://github.com/truenas/truenas-proxmox-plugin/releases/download/v2.0.3/truenas-proxmox-plugin_2.0.3_all.deb
```

### APT Repository (Future)

When the APT repository is set up:

```bash
# Add repository
curl -fsSL https://truenas.github.io/truenas-proxmox-plugin/setup.sh | sudo bash

# Install via apt
sudo apt-get update
sudo apt-get install truenas-proxmox-plugin
```

## Continuous Integration

### GitHub Actions Workflow

The `.github/workflows/build-package.yml` workflow:

- **Triggers**: Push to main/alpha, PRs, version tags
- **Jobs**:
  - `build`: Builds package, runs lintian, verifies contents
  - `test-install`: Tests installation and removal
- **Artifacts**: Uploads .deb files (30-day retention)
- **Releases**: Creates GitHub releases for version tags

### Workflow Features

- Builds on Ubuntu latest
- Runs lintian quality checks
- Verifies required files exist
- Tests package installation
- Tests package removal
- Generates checksums (SHA256, MD5)
- Uploads artifacts
- Creates GitHub releases

### Testing Locally Before Push

```bash
# Run the same checks as CI
./tools/build-deb.sh --clean --test --verbose

# Run lintian
lintian truenas-proxmox-plugin_*.deb
```

## Release Process

### Version Numbering

Follow semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR**: Incompatible API changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Creating a Release

1. **Update Version**:

   ```bash
   # Edit debian/changelog
   dch -v 2.0.4 "Description of changes"

   # Or manually edit debian/changelog
   ```

2. **Update README**:

   ```bash
   # Update version in README.md (line 278)
   sed -i 's/Version.*:.*/Version: 2.0.4/' README.md
   ```

3. **Commit Changes**:

   ```bash
   git add debian/changelog README.md
   git commit -m "Bump version to 2.0.4"
   ```

4. **Create Tag**:

   ```bash
   git tag -a v2.0.4 -m "Release version 2.0.4"
   git push origin main --tags
   ```

5. **GitHub Actions**: Automatically builds and creates release

6. **Verify Release**:
   - Check GitHub Actions workflow completed
   - Verify release created at https://github.com/truenas/truenas-proxmox-plugin/releases
   - Test download and installation

### Release Checklist

- [ ] Version updated in debian/changelog
- [ ] Version updated in README.md
- [ ] Changes documented in changelog
- [ ] All tests passing
- [ ] Tag created and pushed
- [ ] GitHub release created automatically
- [ ] Package downloadable from release
- [ ] Checksums generated
- [ ] Installation tested from release

## APT Repository Setup

### Repository Structure

For GitHub Pages hosting:

```
docs/
└── apt/
    ├── main/
    │   ├── Packages
    │   ├── Packages.gz
    │   ├── Release
    │   ├── Release.gpg
    │   └── truenas-proxmox-plugin_2.0.3_all.deb
    └── alpha/
        └── (same structure)
```

### Creating Repository Metadata

Using `dpkg-scanpackages`:

```bash
# Install tools
apt-get install dpkg-dev

# Create Packages file
cd docs/apt/main
dpkg-scanpackages . /dev/null > Packages
gzip -c Packages > Packages.gz

# Create Release file
cat > Release <<EOF
Origin: TrueNAS
Label: TrueNAS Proxmox Plugin
Suite: stable
Codename: main
Architectures: all
Components: main
Description: TrueNAS Proxmox Plugin APT Repository
EOF
```

### GPG Signing (Optional but Recommended)

```bash
# Generate GPG key
gpg --full-generate-key

# Sign Release file
gpg --default-key your@email.com -abs -o Release.gpg Release

# Export public key
gpg --armor --export your@email.com > gpg.key
```

### Publishing to GitHub Pages

```bash
# Commit repository files
git add docs/apt/
git commit -m "Update APT repository"
git push origin main

# Enable GitHub Pages for /docs folder
# Settings -> Pages -> Source: main branch, /docs folder
```

### User Setup Script

The `tools/setup-apt-repo.sh` script automates repository setup:

```bash
# Setup repository
sudo ./tools/setup-apt-repo.sh

# Install plugin
sudo apt-get update
sudo apt-get install truenas-proxmox-plugin
```

## Troubleshooting

### Build Issues

**Problem**: `dpkg-deb: error: control directory has bad permissions`

**Solution**: Set correct permissions:
```bash
chmod 755 debian/truenas-proxmox-plugin/DEBIAN
chmod 644 debian/truenas-proxmox-plugin/DEBIAN/*
chmod 755 debian/truenas-proxmox-plugin/DEBIAN/post*
chmod 755 debian/truenas-proxmox-plugin/DEBIAN/pre*
```

**Problem**: Package build fails with file not found

**Solution**: Ensure TrueNASPlugin.pm exists:
```bash
ls -l TrueNASPlugin.pm
# If missing, you're in wrong directory or file was moved
```

### Lintian Warnings

**Warning**: `package-contains-empty-directory`

This is expected for certain system directories and can be safely ignored.

**Warning**: `maintainer-script-should-not-use-service`

We use `systemctl` directly (not the `service` command) which is appropriate for Proxmox VE systems.

### Installation Issues

**Problem**: Package installation fails with dependency errors

**Solution**: Install dependencies first:
```bash
apt-get install -f
```

**Problem**: Services fail to restart

**Solution**: Check service status:
```bash
systemctl status pvedaemon pveproxy
journalctl -xe
```

### Verification Issues

**Problem**: Plugin not found after installation

**Solution**: Check installation path:
```bash
dpkg -L truenas-proxmox-plugin
ls -l /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm
```

**Problem**: Storage type not available in Proxmox

**Solution**: Restart Proxmox services:
```bash
systemctl restart pvedaemon pveproxy
```

## Additional Resources

- [Debian New Maintainers' Guide](https://www.debian.org/doc/manuals/maint-guide/)
- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
- [dpkg-deb Manual](https://man7.org/linux/man-pages/man1/dpkg-deb.1.html)
- [Lintian User Manual](https://lintian.debian.org/manual/index.html)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

## Contributing

When contributing packaging improvements:

1. Test changes locally with `./tools/build-deb.sh --clean --test`
2. Run lintian checks
3. Test installation on clean Proxmox system
4. Document any new requirements
5. Update this guide if needed

For questions or issues with packaging:
- Open an issue at https://github.com/truenas/truenas-proxmox-plugin/issues
- Tag with `packaging` label
