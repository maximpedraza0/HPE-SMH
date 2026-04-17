#!/bin/bash
# Installs gnupg1 from the Slackware mirror and imports the pinned HPE
# public signing key into a plugin-local keyring on the USB flash.
# The keyring lives on /boot so it survives reboots and we do not trust
# the host's /root/.gnupg (which may be shared with other users).

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/pkgs"
KEYRING_DIR="/boot/config/plugins/${PLUGIN_NAME}/gnupg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

SLACK_MIRROR="${SLACK_MIRROR:-https://slackware.uk/slackware}"
SLACK_BRANCH="${SLACK_BRANCH:-slackware64-current}"

GNUPG_PKG="gnupg-1.4.23-x86_64-6.txz"
HPE_KEY="${PLUGIN_DIR}/source/hpe-keys/hpe-signing.pub"
# Pinned fingerprint of the key we ship.  Any deviation aborts the import
# — defence against a tampered repo or accidental swap with a different key.
HPE_KEY_FPR="57446EFDE098E5C934B69C7DC208ADDE26C2B797"

log()  { printf '[bootstrap-gpg] %s\n' "$*"; }
die()  { printf '[bootstrap-gpg] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "${CACHE_DIR}" "${KEYRING_DIR}"
chmod 700 "${KEYRING_DIR}"

# ---- 1. install gnupg1 if absent ------------------------------------------
if ! command -v gpg1 >/dev/null 2>&1; then
    local_pkg="${CACHE_DIR}/${GNUPG_PKG}"
    if [[ ! -s "${local_pkg}" ]]; then
        log "downloading ${GNUPG_PKG}"
        curl --fail --silent --show-error --location \
            -o "${local_pkg}.part" \
            "${SLACK_MIRROR}/${SLACK_BRANCH}/slackware64/n/${GNUPG_PKG}" \
            || die "gnupg download failed"
        mv "${local_pkg}.part" "${local_pkg}"
    fi
    log "installing gnupg"
    installpkg --terse "${local_pkg}"
fi

command -v gpg1 >/dev/null 2>&1 || die "gpg1 still not on PATH after install"

# ---- 2. import pinned HPE signing key into plugin keyring -----------------
[[ -r "${HPE_KEY}" ]] || die "shipped HPE key missing at ${HPE_KEY}"

# --with-fingerprint on the file itself (no keyring touched) for pin check.
actual_fpr="$(gpg1 --with-fingerprint --with-colons "${HPE_KEY}" 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}')"
[[ -n "${actual_fpr}" ]] || die "could not read fingerprint from ${HPE_KEY}"
if [[ "${actual_fpr}" != "${HPE_KEY_FPR}" ]]; then
    die "shipped key fingerprint ${actual_fpr} != pinned ${HPE_KEY_FPR}"
fi
log "key fingerprint OK: ${actual_fpr}"

# Idempotent import: check if already in the keyring.
if gpg1 --homedir "${KEYRING_DIR}" --list-keys "${HPE_KEY_FPR}" \
        >/dev/null 2>&1; then
    log "key already in plugin keyring"
else
    log "importing key into ${KEYRING_DIR}"
    gpg1 --homedir "${KEYRING_DIR}" --import "${HPE_KEY}" 2>&1 \
        | sed 's/^/  /'
fi

log "done"
