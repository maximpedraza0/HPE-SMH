#!/bin/bash
# hpilo-builder.sh -- the adapter that hpe-mgmt calls.
#
# Responsibilities:
#   1. Resolve the expected kernel vermagic ("kmagic") from the running kernel
#      (either passed in via --expected-kmagic or auto-detected from
#      /lib/modules/$(uname -r)/build).
#   2. If /lib/modules/<kver>/extra/hpilo.ko exists and its vermagic matches,
#      do nothing.  Fast path on every reboot.
#   3. Else look for a cached .ko at /boot/config/plugins/hpe-mgmt/hpilo/cache/
#      <kmagic>.ko and install that.  Fast path after first build.
#   4. Else invoke build-image.sh (Docker build, ~5 min), cache the result,
#      and install it.
#
# Any failure is non-fatal to the rest of the plugin — amsd/SMH will start
# without iLO features and complain in their own logs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="hpe-mgmt"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/hpilo/cache"
KVER="$(uname -r)"
MOD_DIR="/lib/modules/${KVER}/extra"
MOD_PATH="${MOD_DIR}/hpilo.ko"

EXPECTED_KMAGIC=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expected-kmagic)
            EXPECTED_KMAGIC="$2"; shift 2 ;;
        --force)
            FORCE=1; shift ;;
        *)
            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '[hpilo] %s\n' "$*"; }
warn() { printf '[hpilo] WARN: %s\n' "$*" >&2; }
die()  { printf '[hpilo] ERROR: %s\n' "$*" >&2; exit 1; }

# If caller didn't tell us, try to derive from the kernel build dir.
if [[ -z "${EXPECTED_KMAGIC}" ]]; then
    if [[ -r "/lib/modules/${KVER}/build/include/config/kernel.release" ]]; then
        EXPECTED_KMAGIC="$(cat "/lib/modules/${KVER}/build/include/config/kernel.release")"
    else
        EXPECTED_KMAGIC="${KVER}"
    fi
fi

# A module built against an unRAID kernel reports e.g. vermagic: 6.12.54-Unraid SMP preempt mod_unload
# We only compare the version token (first field).
mod_kmagic() {
    modinfo -F vermagic "$1" 2>/dev/null | awk '{print $1}'
}

log "kernel=${KVER} expected-kmagic=${EXPECTED_KMAGIC}"

# ---- 1. already-installed module matches?  ----
if [[ -z "${FORCE:-}" && -f "${MOD_PATH}" ]]; then
    have="$(mod_kmagic "${MOD_PATH}")"
    if [[ "${have}" == "${EXPECTED_KMAGIC}" ]]; then
        log "installed module already matches (${have})"
        exit 0
    fi
    log "installed module kmagic=${have}, rebuilding"
fi

# ---- 2. cached for this kmagic?  ----
cached="${CACHE_DIR}/${EXPECTED_KMAGIC}.ko"
mkdir -p "${CACHE_DIR}"
if [[ -z "${FORCE:-}" && -s "${cached}" ]]; then
    have="$(mod_kmagic "${cached}")"
    if [[ "${have}" == "${EXPECTED_KMAGIC}" ]]; then
        log "installing cached module"
        install -d -m 0755 "${MOD_DIR}"
        install -m 0644 "${cached}" "${MOD_PATH}"
        depmod -a "${KVER}" || warn "depmod failed"
        exit 0
    fi
    warn "cached module kmagic=${have} does not match ${EXPECTED_KMAGIC}, rebuilding"
fi

# ---- 3. build from scratch (Docker) ----
log "no usable module; invoking build-image.sh (this may take several minutes)"
OUTPUT_DIR="$(mktemp -d -t hpilo-build-XXXXXX)"
trap 'rm -rf "${OUTPUT_DIR}"' EXIT

if ! OUTPUT_DIR="${OUTPUT_DIR}" "${HERE}/build-image.sh"; then
    die "docker build failed"
fi

built="${OUTPUT_DIR}/hpilo.ko"
[[ -s "${built}" ]] || die "builder returned no hpilo.ko"

built_kmagic="$(mod_kmagic "${built}")"
if [[ "${built_kmagic}" != "${EXPECTED_KMAGIC}" ]]; then
    warn "built kmagic=${built_kmagic} != expected=${EXPECTED_KMAGIC}; installing anyway"
fi

log "caching module for kmagic=${built_kmagic}"
install -m 0644 "${built}" "${CACHE_DIR}/${built_kmagic}.ko"

log "installing module at ${MOD_PATH}"
install -d -m 0755 "${MOD_DIR}"
install -m 0644 "${built}" "${MOD_PATH}"
depmod -a "${KVER}" || warn "depmod failed"

log "done"
