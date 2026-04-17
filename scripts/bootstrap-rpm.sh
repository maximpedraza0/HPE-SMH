#!/bin/bash
# Ensures rpm, rpm2cpio and rpm2tgz are available on the host.
# Slackware .txz for rpm + popt are downloaded once and cached on the USB flash.
# Safe to re-run: skips work if tools already present with expected binaries.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/pkgs"
# Resolve PLUGIN_DIR from the script location so this works both at runtime
# (/usr/local/emhttp/plugins/hpe-mgmt/scripts/bootstrap-rpm.sh) and during
# tests from an arbitrary checkout (/tmp/hpe-mgmt-test/scripts/...).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

SLACK_MIRROR="${SLACK_MIRROR:-https://slackware.uk/slackware}"
SLACK_BRANCH="${SLACK_BRANCH:-slackware64-current}"

RPM_PKG="rpm-6.0.1-x86_64-1.txz"
POPT_PKG="popt-1.19-x86_64-1.txz"
LUA_PKG="lua-5.4.8-x86_64-1.txz"    # rpm 6.x links against liblua.so.5

log() { printf '[bootstrap-rpm] %s\n' "$*"; }
die() { printf '[bootstrap-rpm] ERROR: %s\n' "$*" >&2; exit 1; }

have_rpm_tools() {
    # Must not only exist on PATH but actually run (catches missing libs).
    command -v rpm       >/dev/null 2>&1 \
        && command -v rpm2cpio >/dev/null 2>&1 \
        && command -v rpm2tgz  >/dev/null 2>&1 \
        && rpm --version       >/dev/null 2>&1
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
fetch_pkg "${LUA_PKG}"  "d"
fetch_pkg "${RPM_PKG}"  "ap"

if ! command -v rpm >/dev/null 2>&1; then
    log "installing popt"
    installpkg --terse "${CACHE_DIR}/${POPT_PKG}"
    log "installing lua"
    installpkg --terse "${CACHE_DIR}/${LUA_PKG}"
    log "installing rpm"
    installpkg --terse "${CACHE_DIR}/${RPM_PKG}"
fi

# rpm can link against liblua.so.5 even when lua got installed after: run
# ldconfig to ensure the new symlinks (liblua.so.5 -> liblua.so.5.4) are
# picked up before we invoke rpm.
ldconfig 2>/dev/null || true

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
