#!/bin/bash
# Drives the bundled hpilo builder and loads the resulting module.
# Called from install.sh on plugin install and on every unRAID boot.
#
# Env:
#   HPILO_SKIP=1   skip entirely (useful on non-HPE hardware for testing)

set -euo pipefail

PLUGIN_DIR="/usr/local/emhttp/plugins/hpe-mgmt"
BUILDER="${PLUGIN_DIR}/source/hpilo-builder/hpilo-builder.sh"

log()  { printf '[hpilo-hook] %s\n' "$*"; }
warn() { printf '[hpilo-hook] WARN: %s\n' "$*" >&2; }

if [[ "${HPILO_SKIP:-0}" == "1" ]]; then
    log "HPILO_SKIP=1, not touching the module"
    exit 0
fi

if [[ ! -x "${BUILDER}" ]]; then
    warn "builder missing at ${BUILDER}"
    exit 0
fi

KVER="$(uname -r)"
KMAGIC="$(cat "/lib/modules/${KVER}/build/include/config/kernel.release" 2>/dev/null || echo "${KVER}")"

log "kernel=${KVER} expected-kmagic=${KMAGIC}"

if ! "${BUILDER}" --expected-kmagic "${KMAGIC}"; then
    warn "builder reported failure — iLO features may be unavailable"
    exit 0     # non-fatal
fi

log "loading hpilo module"
modprobe hpilo || warn "modprobe hpilo failed"
