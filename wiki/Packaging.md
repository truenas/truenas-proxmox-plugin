# Packaging and Release Guide

This guide is for maintainers who build, validate, and publish Debian packages for the TrueNAS Proxmox plugin.

For end-user APT repository setup and install commands, use the [Installation Guide](Installation.md) at `wiki/Installation.md`. Do not copy end-user `.sources` snippets into this document.

## Scope and Outputs

- Package name: `truenas-proxmox-plugin`
- Debian version source of truth: `debian/changelog`
- Current mapping model: `2.0.3+deb1` in Debian packaging maps to Git tag `v2.0.3-deb1`
- APT publish target: GitHub Pages at `apt/` with suites `bookworm` and `trixie`

## Build the Package

Run from the repository root:

```bash
dpkg-buildpackage -us -uc
```

Expected artifacts are created in the parent directory, including `.deb`, `.changes`, and `.buildinfo`.

Useful checks:

```bash
dpkg-parsechangelog -S Version
dpkg-deb -I ../truenas-proxmox-plugin_*.deb
```

## Lintian Validation

Run lintian as part of every maintainer build and in CI:

```bash
lintian --fail-on error ../*.changes
```

Target state is zero lintian errors. If warnings remain, either fix them or document why they are acceptable.

## Version and Tag Mapping

Maintain a strict mapping between Debian package version and release tag:

- Debian changelog version: `2.0.3+deb1`
- Git tag used for release automation: `v2.0.3-deb1`
- Plugin runtime version (`TrueNASPlugin.pm`): `2.0.3`

Rules:

- Bump package release iteration with `+debN` when packaging changes without upstream plugin feature changes.
- Keep runtime plugin version in lockstep with upstream feature version, not the Debian packaging suffix.
- Ensure release workflow validates changelog version and tag mapping before publishing assets.

## Signing Key Handling

Use a dedicated APT repository signing key for CI publishing.

- Store private key only in GitHub Secrets as ASCII armored `APT_GPG_PRIVATE_KEY`
- Store key ID as `APT_GPG_KEY_ID`
- Optionally store fingerprint as `APT_GPG_FINGERPRINT`
- Import key into an ephemeral `GNUPGHOME` during workflow execution
- Never commit private key material or passphrases to the repository

The public key is published with the APT repo as `apt/pubkey.gpg`.

## GitHub Actions Flow

The packaging workflow should run two main paths:

1. Build path on push and pull request
2. Publish path on version tags

Build path responsibilities:

- Build package in a Debian environment
- Run `lintian --fail-on error`
- Upload build artifacts (`.deb`, `.changes`, `.buildinfo`, checksums)

Publish path responsibilities:

- Validate tag to changelog version mapping
- Create or update GitHub Release for the tag
- Attach package artifacts
- Update and sign APT metadata for GitHub Pages

## GitHub Pages APT Publishing (reprepro)

Repository metadata is managed with `reprepro`.

Configuration files live in:

- `tools/apt-repo/conf/distributions.tmpl`
- `tools/apt-repo/conf/options`

Required repository layout under `gh-pages`:

- `apt/dists/bookworm/main/binary-all/Packages.gz`
- `apt/dists/trixie/main/binary-all/Packages.gz`
- `apt/pool/main/t/truenas-proxmox-plugin/*.deb`
- `apt/dists/<suite>/InRelease`
- `apt/dists/<suite>/Release.gpg`
- `apt/pubkey.gpg`

Typical maintainer or CI publish sequence:

```bash
reprepro -Vb apt includedeb bookworm ../truenas-proxmox-plugin_*.deb
reprepro -Vb apt includedeb trixie ../truenas-proxmox-plugin_*.deb
```

After repository updates, commit the refreshed `apt/` content to `gh-pages`.

## CI and Release Checklist

Before tagging:

- `debian/changelog` version is correct
- Local build succeeds
- Lintian passes with zero errors
- Tag name matches changelog mapping

After tagging:

- GitHub Actions build job succeeds
- Publish job creates or updates release assets
- `gh-pages` contains updated signed APT metadata for both suites
- Public key file is present at `apt/pubkey.gpg`

## Proxmox Validation Checklist

Run manual installation checks on lab nodes after publish.

- PVE 8 host (bookworm): install, verify plugin file, run `perl -c`, remove, purge
- PVE 9 host (trixie): install, verify plugin file, run `perl -c`, remove, purge
- Optional cluster follow-up on additional PVE 9 nodes

Validation commands are maintained in plan and testing workflow docs. Keep this page focused on release readiness and package lifecycle checks.
