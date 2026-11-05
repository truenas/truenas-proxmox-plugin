# Packaging and Release Guide

This guide is for maintainers who build, validate, and publish the Debian package for the TrueNAS Proxmox plugin.

For end-user APT repository setup and install commands, use the [Installation Guide](Installation.md). Do not copy end-user `.sources` snippets into this document.

## Package Overview

| Item | Value |
|---|---|
| Source / binary package | `truenas-proxmox-plugin` |
| Architecture | `all` |
| Section / priority | `admin` / `optional` |
| Version source of truth | `debian/changelog` |
| Build system | debhelper 13 (`dh_install`, `dh_perl`) |
| APT publish location | GitHub Pages, `apt/` directory |
| APT suites | `bookworm` and `trixie` |

The most recent changelog entry is `2.1.24~beta8`. The `~betaN` suffix is part of the upstream version, not packaging iteration.

## Installed Files

`debian/truenas-proxmox-plugin.install` (installed with `dh_install --sourcedir=.`):

| Source | Installed path |
|---|---|
| `TrueNASPlugin.pm` | `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm` |
| `lib/TrueNAS/SCRAM.pm` | `/usr/share/perl5/TrueNAS/SCRAM.pm` |
| `install.sh` | `/usr/share/truenas-proxmox-plugin/install.sh` |
| `tools/truenas-plugin-broker` | `/usr/sbin/truenas-plugin-broker` |
| `tools/truenas-plugin-lvm-filter` | `/usr/sbin/truenas-plugin-lvm-filter` |
| `debian/truenas-plugin-broker.service` | `/usr/lib/systemd/system/truenas-plugin-broker.service` |

`debian/truenas-proxmox-plugin.links` creates the operator entry point:

| Link | Target |
|---|---|
| `/usr/bin/truenas-proxmox-manage` | `/usr/share/truenas-proxmox-plugin/install.sh` |

## Runtime Dependencies

`debian/control` declares:

| Field | Value |
|---|---|
| `Depends` | `pve-manager (>= 8.0.0)`, `open-iscsi`, `multipath-tools`, `perl`, `libio-socket-ssl-perl`, `libcrypt-pbkdf2-perl`, `libcrypt-urandom-perl`, `liburi-perl`, `${misc:Depends}`, `${perl:Depends}` |
| `Recommends` | `nvme-cli` |
| `Build-Depends` | `debhelper-compat (= 13)`, `dh-make-perl`, `perl` |

`nvme-cli` is only needed for NVMe/TCP storages, which is why it is a Recommends rather than a Depends.

## Version Mapping

`debian/rules` takes the version from `dpkg-parsechangelog` and stamps it into the staged plugin file before `dh_perl`:

```make
DEB_VERSION="$(dpkg-parsechangelog -S Version)"
PLUGIN_VERSION="${DEB_VERSION%%+*}"
# our $VERSION = '<PLUGIN_VERSION>' in the staged TrueNASPlugin.pm
```

So the runtime `$VERSION` is the Debian version with everything from the first `+` removed:

| `debian/changelog` | Runtime `$VERSION` |
|---|---|
| `2.1.24~beta8+deb1` | `2.1.24~beta8` |
| `2.1.24+deb1` | `2.1.24` |
| `2.0.3+deb1` | `2.0.3` |

Rules:

- Strip `+debN`: it is packaging iteration, not plugin version.
- Keep the pre-release suffix (`~alphaN`, `~betaN`, `~rcN`): it is part of the plugin version.
- Bump `+debN` when packaging changes without an upstream feature change.
- `tools/build-deb.sh` verifies the stamped value: it extracts the built `.deb` and fails unless the file contains `our $VERSION = '<PLUGIN_VERSION>';`.

### Release tag mapping

The publish workflow validates the tag against the changelog with `expected_tag="v${deb_version/+/-}"`; only the first `+` becomes `-`:

| `debian/changelog` | Expected stable tag |
|---|---|
| `2.0.3+deb1` | `v2.0.3-deb1` |
| `2.1.24~beta8` | n/a (pre-release; see below) |

Git forbids `~` in ref names, so pre-release changelog versions (`~alphaN`, `~betaN`, `~rcN`) are tagged as `-alphaN`, `-betaN`, `-rcN`. The publish job skips any tag containing `-alpha`, `-beta` or `-rc`, so the tag/changelog equality check is not applied to pre-releases. The release job still attaches artifacts to a GitHub release for those tags, with `prerelease: true`.

## Build the Package

Run from the repository root:

```bash
tools/build-deb.sh
```

`build-deb.sh` requires `dpkg-parsechangelog`, `dpkg-buildpackage`, `lintian`, `dpkg-deb`, `sha256sum` and `grep`. It:

1. Removes stale `truenas-proxmox-plugin_*` artifacts from the parent directory.
2. Runs `dpkg-buildpackage -us -uc -tc`.
3. Runs `lintian --fail-on error` on the `.changes` file.
4. Verifies the `.deb` package name and version match the changelog.
5. Extracts the `.deb` and checks the injected `our $VERSION`.
6. Writes `SHA256SUMS` next to the artifacts.

Artifacts (`.deb`, `.changes`, `.buildinfo`) are created in the parent directory of the repository.

Manual build and checks:

```bash
dpkg-buildpackage -us -uc
dpkg-parsechangelog -S Version
dpkg-deb -I ../truenas-proxmox-plugin_*.deb
```

## Maintainer Scripts

### `postinst configure`

1. Fails if `/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm` or `/usr/sbin/truenas-plugin-broker` is missing, then runs `perl -c` on both.
2. On upgrade from a version below `2.1.0`, rewrites old bare keys to the `tn_*` names inside `truenasplugin:` stanzas of `/etc/pve/storage.cfg`. A timestamped backup (`storage.cfg.bak.YYYYMMDDHHMMSS`) is created first; the migration always runs unattended, because maintainer scripts must not prompt.
3. Enables and starts the broker (see below).
4. Restarts the PVE services that load the plugin.

### Broker handling

`enable_broker()` runs `systemctl daemon-reload`, enables `truenas-plugin-broker.service`, then `try-restart` when it is already active or `start` when it is not. It waits up to 5 seconds for `/run/truenas-plugin/broker.sock` and prints a warning with troubleshooting commands if the socket does not appear.

### PVE service restarts

- `TRUENAS_PLUGIN_NO_RESTART=1` skips the PVE-side restarts and prints the command to run later. The broker restart still happens.
- `pvedaemon pvestatd pvescheduler pve-ha-crm pve-ha-lrm` are `try-restart`ed immediately.
- `pveproxy` is deferred by about 10 seconds using `systemd-run --on-active=10s --unit=truenas-pveproxy-restart`, so an `apt upgrade` running in the web UI terminal is not killed mid-transaction. A pending timer is detected and not re-scheduled; if `systemd-run` is unavailable the restart is immediate.

### `prerm remove`

Stops and disables the broker unit, and warns if `truenasplugin:` entries remain in `/etc/pve/storage.cfg` (they are never modified on removal).

### `postrm purge`

Removes `/var/lib/truenas-plugin-backups`, `/run/truenas-plugin`, `/var/log/truenas-installer.log` and `/var/log/truenas-plugin-broker.log`, then reloads systemd.

## Broker Service Unit

`debian/truenas-plugin-broker.service`:

- `Type=notify`: the broker sends `READY=1` only after the listen socket is bound.
- `ExecStart=/usr/sbin/truenas-plugin-broker --foreground`.
- `After=network-online.target`, `Wants=network-online.target`.
- `Before=pvestatd.service pvedaemon.service pveproxy.service` so the socket exists before any plugin caller starts.
- `Restart=on-failure`, `RestartSec=2`.
- `RuntimeDirectory=truenas-plugin` with mode `0700`; `RuntimeDirectoryPreserve=yes` keeps cached state across broker restarts (tmpfs still clears it on reboot).
- Hardening: `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `NoNewPrivileges=true`.

## Signing Key Handling

Use a dedicated APT repository signing key for CI publishing.

- Store the private key in GitHub Secrets as ASCII armored `APT_GPG_PRIVATE_KEY`
- Store the key ID as `APT_GPG_KEY_ID`
- Import the key into an ephemeral `GNUPGHOME` during workflow execution
- Never commit private key material or passphrases to the repository

The public key is exported to the repository as `apt/pubkey.gpg` (binary) and `apt/pubkey.asc` (armored).

## GitHub Actions Flow

`.github/workflows/build-package.yml` runs in a `debian:bookworm` container and installs `build-essential`, `dpkg-dev`, `debhelper`, `dh-make-perl` and `lintian`.

1. **Build job**: runs on every branch push, pull request, `v*` tag and manual dispatch. It runs `tools/build-deb.sh` and uploads `dist/` (`.deb`, `.changes`, `.buildinfo`, `SHA256SUMS`).
2. **Release job**: for any `v*` tag it creates or updates a GitHub release and attaches the `.deb` and `SHA256SUMS`. Pre-release tags get `prerelease: true`.
3. **Publish job**: for stable `v*` tags only (skipped when the tag contains `-alpha`, `-beta` or `-rc`), it validates the tag, requires both signing secrets, builds and signs the APT metadata, and publishes to `gh-pages`.

## GitHub Pages APT Publishing (reprepro)

Repository metadata is managed with `reprepro`.

Configuration files live in:

- `tools/apt-repo/conf/distributions.tmpl` (suites `bookworm` and `trixie`, component `main`, architecture `amd64`, `SignWith: @APT_GPG_KEY_ID@`)
- `tools/apt-repo/conf/options`

The publish job:

1. Restores the existing `gh-pages` content, then overlays it into `apt/`.
2. Substitutes the key ID into `distributions.tmpl` and copies `options`.
3. Runs `reprepro -Vb apt includedeb <suite>` for both suites.
4. Copies `binary-amd64` metadata into `dists/<suite>/main/binary-all` (the package is `Architecture: all`).
5. Adds a `Changelogs:` field, regenerates `Release.gpg` and `InRelease`.
6. Exports `pubkey.gpg` and `pubkey.asc`.
7. Copies `debian/changelog` to `apt/changelogs/main/t/truenas-proxmox-plugin/`.

Required layout under `gh-pages`:

- `apt/dists/bookworm/main/binary-all/Packages.gz`
- `apt/dists/trixie/main/binary-all/Packages.gz`
- `apt/pool/main/t/truenas-proxmox-plugin/*.deb`
- `apt/dists/<suite>/InRelease`
- `apt/dists/<suite>/Release.gpg`
- `apt/changelogs/main/t/truenas-proxmox-plugin/`
- `apt/pubkey.gpg` and `apt/pubkey.asc`

Typical maintainer publish sequence (after a local `tools/build-deb.sh`):

```bash
reprepro -Vb apt includedeb bookworm ../truenas-proxmox-plugin_*.deb
reprepro -Vb apt includedeb trixie ../truenas-proxmox-plugin_*.deb
```

Commit the refreshed `apt/` content to `gh-pages` only for stable versions.

## CI and Release Checklist

Before tagging:

- `debian/changelog` version is correct and `wiki/README.md` / `README.md` / `wiki/Changelog.md` are updated
- `tools/build-deb.sh` succeeds (build, lintian, version verification)
- Tag name matches the changelog mapping; pre-release tags use `-betaN` style, stable tags use `-debN`

After tagging:

- Build job succeeds and artifacts are attached to the release
- For stable tags, the publish job updates `gh-pages` with signed metadata for both suites
- Public key files are present at `apt/pubkey.gpg` and `apt/pubkey.asc`

## Proxmox Validation Checklist

Run manual installation checks on lab nodes after publish.

- PVE 8 host (bookworm): install, verify plugin file, run `perl -c`, remove, purge
- PVE 9 host (trixie): install, verify plugin file, run `perl -c`, remove, purge
- Confirm `systemctl is-active truenas-plugin-broker` is `active` and `/run/truenas-plugin/broker.sock` exists after install
- Optional cluster follow-up on additional PVE 9 nodes

Validation commands are maintained in plan and testing workflow docs. Keep this page focused on release readiness and package lifecycle checks.
