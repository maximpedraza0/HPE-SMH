#!/bin/bash
# Plugin remove entrypoint. Invoked by hpe-mgmt.plg on uninstall.
# Stops services, removes installed HPE packages, leaves /boot cache intact
# unless PURGE_CACHE=1 is set.

set -u

PLUGIN_NAME="hpe-mgmt"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
CFG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
STATE_DIR="${CFG_DIR}/state"

log() { printf '[remove] %s\n' "$*"; }

if [[ -x "/etc/rc.d/rc.${PLUGIN_NAME}" ]]; then
    log "stopping services"
    "/etc/rc.d/rc.${PLUGIN_NAME}" stop || true
    rm -f "/etc/rc.d/rc.${PLUGIN_NAME}"
fi

if [[ -d "${STATE_DIR}" ]]; then
    log "removing HPE packages"
    for marker in "${STATE_DIR}"/*.installed; do
        [[ -e "${marker}" ]] || continue
        rpm_fn="$(basename "${marker}" .installed)"
        # package name without version suffix (first dash-separated token)
        pkg_name="${rpm_fn%%-*}"
        if ls /var/log/packages/ | grep -qE "^${pkg_name}-"; then
            log "  removepkg ${pkg_name}"
            removepkg "${pkg_name}" >/dev/null 2>&1 || true
        fi
        rm -f "${marker}"
    done
fi

if [[ "${PURGE_CACHE:-0}" == "1" ]]; then
    log "purging cache in ${CFG_DIR}"
    rm -rf "${CFG_DIR}"
fi

log "done (bootstrap packages popt/rpm left installed)"
