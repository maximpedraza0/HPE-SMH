#!/bin/bash
# Installs gnupg1 from the Slackware mirror and imports every pinned
# signing key we ship into a plugin-local keyring on the USB flash.
# The keyring lives on /boot so it survives reboots and is isolated
# from the host's /root/.gnupg.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/pkgs"
KEYRING_DIR="/boot/config/plugins/${PLUGIN_NAME}/gnupg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

SLACK_MIRROR="${SLACK_MIRROR:-https://slackware.uk/slackware}"
SLACK_BRANCH="${SLACK_BRANCH:-slackware64-current}"

GNUPG_PKG="gnupg-1.4.23-x86_64-6.txz"

# Pinned keys we trust.  Format: "<file under source/keys/>:<fingerprint>".
# Any deviation between the shipped file's fingerprint and the pin aborts
# the import — defence against a tampered repo or accidental swap.
TRUSTED_KEYS=(
    "hpe-signing.pub:57446EFDE098E5C934B69C7DC208ADDE26C2B797"
    "almalinux-signing.pub:BC5EDDCADF502C077F1582882AE81E8ACED7258B"
)

log()  { printf '[bootstrap-gpg] %s\n' "$*"; }
warn() { printf '[bootstrap-gpg] WARN: %s\n' "$*" >&2; }
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

# ---- 2. import each pinned key into plugin keyring -----------------------
import_key() {
    local entry="$1"
    local file="${entry%%:*}"
    local expected_fpr="${entry##*:}"
    local path="${PLUGIN_DIR}/source/keys/${file}"

    [[ -r "${path}" ]] || die "shipped key missing: ${path}"

    # AlmaLinux key file contains both an expired and a current key.  We
    # check *any* fingerprint in the file matches the pin; for files with
    # only one key this just matches that one.
    if ! gpg1 --with-fingerprint --with-colons "${path}" 2>/dev/null \
            | awk -F: '/^fpr:/ {print $10}' \
            | grep -Fxq "${expected_fpr}"; then
        local found
        found="$(gpg1 --with-fingerprint --with-colons "${path}" 2>/dev/null \
                 | awk -F: '/^fpr:/ {print $10}' | paste -sd, -)"
        die "pinned fingerprint ${expected_fpr} not present in ${file} (found: ${found})"
    fi
    log "key OK: ${file} (pinned ${expected_fpr:0:16}...)"

    if gpg1 --homedir "${KEYRING_DIR}" --list-keys "${expected_fpr}" \
            >/dev/null 2>&1; then
        log "  already in plugin keyring"
    else
        log "  importing"
        gpg1 --homedir "${KEYRING_DIR}" --import "${path}" 2>&1 \
            | sed 's/^/    /'
    fi
}

for entry in "${TRUSTED_KEYS[@]}"; do
    import_key "${entry}"
done

log "done (${#TRUSTED_KEYS[@]} keys imported)"
