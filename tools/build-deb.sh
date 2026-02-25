#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd "${REPO_ROOT}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TMP_DIR=""

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}

trap cleanup EXIT

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_cmd() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

clean_packaging_artifacts() {
    local package_name="$1"

    shopt -s nullglob
    local stale=(
        "${ARTIFACT_DIR}/${package_name}_"*.deb
        "${ARTIFACT_DIR}/${package_name}_"*.changes
        "${ARTIFACT_DIR}/${package_name}_"*.buildinfo
        "${ARTIFACT_DIR}/${package_name}_"*.dsc
        "${ARTIFACT_DIR}/${package_name}_"*.tar.*
    )
    shopt -u nullglob

    if (( ${#stale[@]} > 0 )); then
        log_info "Removing stale packaging artifacts from ${ARTIFACT_DIR}"
        rm -f "${stale[@]}"
    fi
}

main() {
    require_cmd dpkg-parsechangelog
    require_cmd dpkg-buildpackage
    require_cmd lintian
    require_cmd dpkg-deb
    require_cmd sha256sum
    require_cmd grep

    cd "${REPO_ROOT}"

    local package_name
    package_name="$(dpkg-parsechangelog -S Source)"
    local deb_version
    deb_version="$(dpkg-parsechangelog -S Version)"
    local plugin_version
    plugin_version="${deb_version%%+*}"

    [[ -n "${package_name}" ]] || die "Unable to read package name from debian/changelog"
    [[ -n "${deb_version}" ]] || die "Unable to read version from debian/changelog"

    log_info "Preparing clean build for ${package_name} ${deb_version}"
    clean_packaging_artifacts "${package_name}"

    log_info "Building package with dpkg-buildpackage"
    dpkg-buildpackage -us -uc -tc

    shopt -s nullglob
    local deb_candidates=("${ARTIFACT_DIR}/${package_name}_${deb_version}"*.deb)
    local changes_candidates=("${ARTIFACT_DIR}/${package_name}_${deb_version}"*.changes)
    shopt -u nullglob

    (( ${#deb_candidates[@]} > 0 )) || die "No .deb artifact found for ${package_name} ${deb_version}"
    (( ${#changes_candidates[@]} > 0 )) || die "No .changes artifact found for ${package_name} ${deb_version}"

    local deb_file="${deb_candidates[0]}"
    local changes_file="${changes_candidates[0]}"

    log_info "Running lintian (fail on errors)"
    lintian --fail-on error "${changes_file}"

    local deb_package
    deb_package="$(dpkg-deb -f "${deb_file}" Package)"
    local deb_metadata_version
    deb_metadata_version="$(dpkg-deb -f "${deb_file}" Version)"

    [[ "${deb_package}" == "${package_name}" ]] || die "Debian package metadata mismatch: expected package ${package_name}, got ${deb_package}"
    [[ "${deb_metadata_version}" == "${deb_version}" ]] || die "Debian package metadata mismatch: expected version ${deb_version}, got ${deb_metadata_version}"

    if ! grep -q "^Version: ${deb_version}$" "${changes_file}"; then
        die "Changes file does not contain expected version ${deb_version}: ${changes_file}"
    fi

    TMP_DIR="$(mktemp -d)"
    dpkg-deb -x "${deb_file}" "${TMP_DIR}"

    local plugin_file="${TMP_DIR}/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
    [[ -f "${plugin_file}" ]] || die "Plugin file missing in extracted package: ${plugin_file}"

    if ! grep -Eq "^our \\\$VERSION = '${plugin_version}';$" "${plugin_file}"; then
        die "Version injection verification failed: expected \"our \\\$VERSION = '${plugin_version}';\""
    fi

    local sums_file="${ARTIFACT_DIR}/SHA256SUMS"
    ( cd "${ARTIFACT_DIR}" && sha256sum "$(basename "${deb_file}")" "$(basename "${changes_file}")" > "${sums_file}" )

    log_success "Build complete"
    log_success "Deb: ${deb_file}"
    log_success "Changes: ${changes_file}"
    log_success "SHA256SUMS: ${sums_file}"
}

main "$@"
