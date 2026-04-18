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
    install -m 0644 "${PLUGIN_DIR}/${PLUGIN_NAME}.cfg.default" \
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
# unRAID does not ship /etc/init.d/functions — the plugin owns it.
# Always refresh: our shim evolves with the plugin (pidof self-exclusion,
# etc.) and keeping an older copy causes spurious "already running"
# detections.  If a user has their own custom shim there we'll clobber
# it, but that is not a normal unRAID configuration.
log "fixup: /etc/init.d/functions (RHEL compat shim, refreshed)"
mkdir -p /etc/init.d
install -m 0644 "${PLUGIN_DIR}/source/compat/init-functions.sh" /etc/init.d/functions
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

# hp-health / hp-snmp-agents ship their start scripts under
# /usr/lib/systemd/scripts/ and have a vendor %post that symlinks them
# into /etc/init.d.  rpm2tgz drops that; recreate idempotently.
for svc in hp-health hp-snmp-agents; do
    src="/usr/lib/systemd/scripts/${svc}.sh"
    dst="/etc/init.d/${svc}"
    if [[ -x "${src}" && ! -e "${dst}" ]]; then
        log "fixup: ${dst} -> ${src}"
        mkdir -p /etc/init.d
        ln -sf "${src}" "${dst}"
    fi
done

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
#
# We pick a fixed uid/gid (881) rather than letting `useradd -r` allocate
# one from the default system range.  unRAID's Slackware useradd picks
# from the top of the <1000 range, which lands on 999 — and uid 999 is
# very commonly used by Docker containers on unRAID (Immich, etc.), so
# host-side `ps` ends up labelling those containers' processes "hpsmh"
# through reverse uid lookup.  That's confusing but harmless; 881 is
# chosen to be well clear of the common Docker default.
HPSMH_UID=881
HPSMH_GID=881

if ! getent group hpsmh >/dev/null 2>&1; then
    log "fixup: creating hpsmh group (gid ${HPSMH_GID})"
    groupadd -r -g "${HPSMH_GID}" hpsmh 2>/dev/null \
        || groupadd -r hpsmh 2>/dev/null \
        || true
fi
if ! getent passwd hpsmh >/dev/null 2>&1; then
    log "fixup: creating hpsmh user (uid ${HPSMH_UID})"
    useradd -r -u "${HPSMH_UID}" -g hpsmh -s /sbin/nologin \
        -d /opt/hp/hpsmh hpsmh 2>/dev/null \
        || useradd -r -g hpsmh -s /sbin/nologin \
            -d /opt/hp/hpsmh hpsmh 2>/dev/null \
        || true
fi

# Seed /opt/hp/hpsmh/conf/smhpd.xml with the same defaults the vendor %post
# would have written.  Without this file hpsmhd refuses to start.
if [[ -d /opt/hp/hpsmh/conf && ! -f /opt/hp/hpsmh/conf/smhpd.xml ]]; then
    log "fixup: seeding /opt/hp/hpsmh/conf/smhpd.xml with defaults"
    cat > /opt/hp/hpsmh/conf/smhpd.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<system-management-homepage>
  <admin-group></admin-group>
  <operator-group></operator-group>
  <user-group></user-group>
  <allow-default-os-admin>true</allow-default-os-admin>
  <anonymous-access>false</anonymous-access>
  <localaccess-enabled>false</localaccess-enabled>
  <localaccess-type>Anonymous</localaccess-type>
  <trustmode>TrustByCert</trustmode>
  <xenamelist></xenamelist>
  <ip-binding>false</ip-binding>
  <ip-binding-list></ip-binding-list>
  <ip-restricted-logins>false</ip-restricted-logins>
  <ip-restricted-include></ip-restricted-include>
  <ip-restricted-exclude></ip-restricted-exclude>
  <autostart>false</autostart>
  <timeoutsmh>30</timeoutsmh>
  <port2301>true</port2301>
  <iconview>false</iconview>
  <box-order>status</box-order>
  <box-item-order>status</box-item-order>
  <session-timeout>15</session-timeout>
  <ui-timeout>120</ui-timeout>
  <httpd-error-log>false</httpd-error-log>
  <multihomed></multihomed>
  <rotate-logs-size>5</rotate-logs-size>
</system-management-homepage>
XML
    chown hpsmh:hpsmh /opt/hp/hpsmh/conf/smhpd.xml 2>/dev/null || true
    chmod 660      /opt/hp/hpsmh/conf/smhpd.xml 2>/dev/null || true
fi

# hpsmhd logs under /var/spool/opt/hp/hpsmh (vendor %post creates the tree).
if [[ -d /opt/hp/hpsmh && ! -d /var/spool/opt/hp/hpsmh/logs ]]; then
    log "fixup: creating /var/spool/opt/hp/hpsmh/{logs,run}"
    mkdir -p /var/spool/opt/hp/hpsmh/logs /var/spool/opt/hp/hpsmh/run
    chown -R root:hpsmh /var/spool/opt 2>/dev/null || true
    chmod -R 750        /var/spool/opt 2>/dev/null || true
fi

# PAM stack the init script loads for web authentication.
if [[ -f /opt/hp/hpsmh/support/sysmgthp.redhat && ! -f /etc/pam.d/sysmgthp ]]; then
    log "fixup: /etc/pam.d/sysmgthp"
    mkdir -p /etc/pam.d
    install -m 0644 /opt/hp/hpsmh/support/sysmgthp.redhat /etc/pam.d/sysmgthp
fi

# The hpsmhd init script trusts its own pid file over process liveness —
# a stale httpd.pid (e.g. from a crashed prior attempt) makes it report
# "already running" and skip start.  Clean stale PIDs idempotently.
for pidfile in /opt/hp/hpsmh/logs/httpd.pid /var/run/hp-ams.pid; do
    [[ -f "${pidfile}" ]] || continue
    pid="$(cat "${pidfile}" 2>/dev/null)"
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
        log "fixup: removing stale ${pidfile}"
        rm -f "${pidfile}"
    fi
done

log "installing rc.hpe-mgmt"
install -m 0755 "${PLUGIN_DIR}/scripts/rc.hpe-mgmt" "/etc/rc.d/rc.${PLUGIN_NAME}"

# Event hooks live at ${PLUGIN_DIR}/event/<event_name> and are auto-picked
# by unRAID when the corresponding event fires (disks_mounted,
# unmounting_disks).  Defensive chmod — tar should preserve +x but we
# don't want a permission miss to leave services unmanaged.
if [[ -d "${PLUGIN_DIR}/event" ]]; then
    chmod +x "${PLUGIN_DIR}/event/"* 2>/dev/null || true
    log "event hooks registered: $(ls "${PLUGIN_DIR}/event/" | paste -sd, -)"
fi

log "starting services"
"/etc/rc.d/rc.${PLUGIN_NAME}" start || log "service start reported failure"

log "done"
