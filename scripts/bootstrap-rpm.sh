#!/bin/bash
# Ensures rpm, rpm2cpio and rpm2tgz are available on the host.
# Slackware .txz for rpm + popt are downloaded once and cached on the USB flash.
# Safe to re-run: skips work if tools already present with expected binaries.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/pkgs"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"

SLACK_MIRROR="${SLACK_MIRROR:-https://slackware.uk/slackware}"
SLACK_BRANCH="${SLACK_BRANCH:-slackware64-current}"

RPM_PKG="rpm-6.0.1-x86_64-1.txz"
POPT_PKG="popt-1.19-x86_64-1.txz"

log() { printf '[bootstrap-rpm] %s\n' "$*"; }
die() { printf '[bootstrap-rpm] ERROR: %s\n' "$*" >&2; exit 1; }

have_rpm_tools() {
    command -v rpm >/dev/null 2>&1 \
        && command -v rpm2cpio >/dev/null 2>&1 \
        && command -v rpm2tgz >/dev/null 2>&1
}

if have_rpm_tools; then
    log "rpm tooling already installed, nothing to do"
    exit 0
fi

mkdir -p "${CACHE_DIR}"

fetch_pkg() {
    local pkg="$1" cat="$2" dest="${CACHE_DIR}/${1}"
    if [[ -s "${dest}" ]]; then
        log "cached: ${pkg}"
        return 0
    fi
    log "downloading ${pkg}"
    curl --fail --silent --show-error --location \
        -o "${dest}.part" \
        "${SLACK_MIRROR}/${SLACK_BRANCH}/slackware64/${cat}/${pkg}" \
        || die "download failed: ${pkg}"
    mv "${dest}.part" "${dest}"
}

fetch_pkg "${POPT_PKG}" "l"
fetch_pkg "${RPM_PKG}"  "ap"

if ! command -v rpm >/dev/null 2>&1; then
    log "installing popt"
    installpkg --terse "${CACHE_DIR}/${POPT_PKG}"
    log "installing rpm"
    installpkg --terse "${CACHE_DIR}/${RPM_PKG}"
fi

# rpm2targz ships with the plugin. Install as /usr/sbin/rpm2targz
# and expose rpm2tgz / rpm2txz symlinks (what Slackware normally does).
if [[ -x "${PLUGIN_DIR}/source/rpm2targz" ]] && ! command -v rpm2tgz >/dev/null 2>&1; then
    log "installing rpm2targz"
    install -m 0755 "${PLUGIN_DIR}/source/rpm2targz" /usr/sbin/rpm2targz
    ln -sf rpm2targz /usr/sbin/rpm2tgz
    ln -sf rpm2targz /usr/sbin/rpm2txz
fi

have_rpm_tools || die "bootstrap completed but rpm tools still missing"
log "rpm tooling ready: $(rpm --version | head -1)"
