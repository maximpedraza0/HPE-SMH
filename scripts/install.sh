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

# Post-install fixups for things the vendor's %post would have done but
# rpm2tgz strips out.  Keep these idempotent.

# RHEL init scripts (hp-health, hp-snmp-agents.sh, hpsmhd.redhat) source
# /etc/init.d/functions, which Slackware/unRAID does not ship.  Drop our
# minimal shim implementing the handful of functions those scripts use.
if [[ ! -e /etc/init.d/functions ]]; then
    log "fixup: /etc/init.d/functions (RHEL compat shim)"
    mkdir -p /etc/init.d
    install -m 0644 "${PLUGIN_DIR}/source/compat/init-functions.sh" /etc/init.d/functions
fi
# hpsmh's init script uses the absolute-from-rc.d path.  Cover both conventions.
if [[ ! -e /etc/rc.d/init.d/functions ]]; then
    log "fixup: /etc/rc.d/init.d/functions (legacy path)"
    mkdir -p /etc/rc.d/init.d
    ln -sf /etc/init.d/functions /etc/rc.d/init.d/functions
fi

# The hpsmh RPM ships its init script at /opt/hp/hpsmh/support/hpsmhd.redhat;
# the vendor %post would have symlinked it to /etc/init.d/hpsmhd.
if [[ -x /opt/hp/hpsmh/support/hpsmhd.redhat && ! -e /etc/init.d/hpsmhd ]]; then
    log "fixup: /etc/init.d/hpsmhd -> /opt/hp/hpsmh/support/hpsmhd.redhat"
    mkdir -p /etc/init.d
    ln -sf /opt/hp/hpsmh/support/hpsmhd.redhat /etc/init.d/hpsmhd
fi

# hpsmh's init script sources /opt/hp/hpsmh/bin/fixperms, but the RPM ships
# the file at /opt/hp/hpsmh/support/fixperms — the %post would have placed
# or symlinked it.
if [[ -f /opt/hp/hpsmh/support/fixperms && ! -e /opt/hp/hpsmh/bin/fixperms ]]; then
    log "fixup: /opt/hp/hpsmh/bin/fixperms -> ../support/fixperms"
    mkdir -p /opt/hp/hpsmh/bin
    ln -sf ../support/fixperms /opt/hp/hpsmh/bin/fixperms
fi

# hpsmh daemons run as hpsmh:hpsmh; the vendor %pre would have created
# them via useradd/groupadd.
if ! getent group hpsmh >/dev/null 2>&1; then
    log "fixup: creating hpsmh group"
    groupadd -r hpsmh 2>/dev/null || true
fi
if ! getent passwd hpsmh >/dev/null 2>&1; then
    log "fixup: creating hpsmh user"
    useradd -r -g hpsmh -s /sbin/nologin -d /opt/hp/hpsmh hpsmh 2>/dev/null || true
fi

log "installing rc.hpe-mgmt"
install -m 0755 "${PLUGIN_DIR}/scripts/rc.hpe-mgmt" "/etc/rc.d/rc.${PLUGIN_NAME}"

log "starting services"
"/etc/rc.d/rc.${PLUGIN_NAME}" start || log "service start reported failure"

log "done"
