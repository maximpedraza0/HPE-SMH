#!/bin/bash
# Plugin install entrypoint. Invoked by hpe-mgmt.plg on plugin install and
# on every unRAID boot (via plugin re-apply).
#
# Order matters:
#   1. hpilo-hook   -- make sure /dev/hpilo is present before daemons start
#   2. bootstrap-rpm-- ensure rpm / rpm2cpio / rpm2tgz available
#   3. fetch-hpe    -- download + convert + install selected HPE RPMs
#   4. rc.hpe-mgmt  -- start services

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
# Derive PLUGIN_DIR from the script's own location so this works both at
# runtime (/usr/local/emhttp/plugins/hpe-mgmt/scripts/install.sh) and when
# run from an arbitrary checkout during tests.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
CFG_DIR="/boot/config/plugins/${PLUGIN_NAME}"

log() { printf '[install] %s\n' "$*"; }

[[ -d "${PLUGIN_DIR}/scripts" ]] || { echo "plugin tree missing at ${PLUGIN_DIR}"; exit 1; }
[[ -d "${CFG_DIR}" ]] || mkdir -p "${CFG_DIR}"

# Stamp default config if absent.
if [[ ! -f "${CFG_DIR}/${PLUGIN_NAME}.cfg" ]]; then
    install -m 0644 "${PLUGIN_DIR}/plugin/${PLUGIN_NAME}.cfg.default" \
                     "${CFG_DIR}/${PLUGIN_NAME}.cfg"
    log "wrote default config"
fi

log "running hpilo-hook"
bash "${PLUGIN_DIR}/scripts/hpilo-hook.sh" || log "hpilo-hook non-fatal failure"

log "running bootstrap-rpm"
bash "${PLUGIN_DIR}/scripts/bootstrap-rpm.sh"

log "running bootstrap-gpg"
bash "${PLUGIN_DIR}/scripts/bootstrap-gpg.sh"

log "running fetch-hpe"
bash "${PLUGIN_DIR}/scripts/fetch-hpe.sh"

log "installing rc.hpe-mgmt"
install -m 0755 "${PLUGIN_DIR}/scripts/rc.hpe-mgmt" "/etc/rc.d/rc.${PLUGIN_NAME}"

log "starting services"
"/etc/rc.d/rc.${PLUGIN_NAME}" start || log "service start reported failure"

log "done"
