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

# Replace the GitHub-facing README with a compact unRAID-facing one.
# /Plugins renders README.md as the plugin's inline description (see
# dynamix.plugin.manager/include/ShowPlugins.php):
#   file_exists → Markdown(contents)  else  Markdown("**{$name}**")
# The full repo README has a markdown H1 that renders as oversized
# heading on that row; every other plugin (gpustat, compose.manager,
# NerdTools…) follows the `**Name**\n\nShort sentence` convention.
cat > "${PLUGIN_DIR}/README.md" <<'UNRAID_README'
**HPE Management**

Plugin for HPE ProLiant servers on unRAID. See [GitHub](https://github.com/maximpedraza0/HPE-SMH) for documentation.
UNRAID_README

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

# hpsmh daemons run as hpsmh:hpsmh; the vendor %pre would have created
# them via useradd/groupadd.  We must do this BEFORE rpm2tgz/installpkg
# run, so the tarballs' owner-by-name entries resolve to our uid/gid
# instead of leaving numeric 999 (uid used on the RHEL build host).
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

log "running fetch-hpe"
bash "${PLUGIN_DIR}/scripts/fetch-hpe.sh"

# Re-own anything rpm2tgz unpacked with the RHEL build host's numeric
# uid/gid 999 (which is what HPE's tarballs bake in).  If the hpsmh
# user didn't exist at unpack time — or if installpkg used numeric mode
# — those files stay uid 999, and hpsmhd (running as our 881) can't
# read its own tree so SMH shows only the plugins owned by root.
for tree in /opt/hp/hpsmh /opt/hp/hp-snmp-agents /opt/hp/hp-smh-templates /var/spool/compaq; do
    [[ -d "${tree}" ]] || continue
    # -uid/-gid 999 matches both "raw numeric 999" and previously misowned
    # content; harmless if there's nothing to change.
    if find "${tree}" \( -uid 999 -o -gid 999 \) -print -quit 2>/dev/null | grep -q .; then
        log "fixup: reclaiming uid/gid 999 under ${tree} -> hpsmh:hpsmh"
        find "${tree}" -uid 999 -exec chown "${HPSMH_UID}" {} + 2>/dev/null || true
        find "${tree}" -gid 999 -exec chgrp "${HPSMH_GID}" {} + 2>/dev/null || true
    fi
done

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

# Smart Storage Administrator: the `ssa` RPM drops its SMH plugin files
# under /opt/smartstorageadmin/ssa/{SMH,HTML/SSA1,init.d} and expects the
# administrator to wire them up manually — there is no %post for it.
# We reproduce the expected layout:
#   - /opt/hp/hpsmh/webapp/hpssa.xml       (plugin registration)
#   - /opt/hp/hpsmh/data/htdocs/HPSSA/     (htdocs tree combining SMH/ + HTML/SSA1/)
#   - /etc/init.d/hpessad                  (daemon started by rc.hpe-mgmt)
SSA_ROOT=/opt/smartstorageadmin/ssa
if [[ -s "${SSA_ROOT}/SMH/hpssa.xml" && -d /opt/hp/hpsmh/webapp ]]; then
    # Copy (not symlink) — something in hpsmhd's startup can open this
    # path for write under certain conditions, and following a symlink
    # would truncate the vendor-owned source file to zero bytes.  Always
    # refresh the copy so a re-run picks up vendor updates.
    log "fixup: /opt/hp/hpsmh/webapp/hpssa.xml (copy from ${SSA_ROOT}/SMH)"
    install -m 0644 "${SSA_ROOT}/SMH/hpssa.xml" /opt/hp/hpsmh/webapp/hpssa.xml
fi
if [[ -d "${SSA_ROOT}/SMH" ]]; then
    htdocs_hpssa=/opt/hp/hpsmh/data/htdocs/HPSSA
    if [[ ! -d "${htdocs_hpssa}" ]]; then
        log "fixup: populating ${htdocs_hpssa} from ssa/HTML/SSA1 + ssa/SMH"
        mkdir -p "${htdocs_hpssa}"
        # Main UI tree (hpessa.htm entryurl + css/images/js)
        for f in "${SSA_ROOT}/HTML/SSA1/"*; do
            [[ -e "${f}" ]] || continue
            ln -sf "${f}" "${htdocs_hpssa}/$(basename "${f}")"
        done
        # chp.htm (chpurl) + ipcelmclient.php (ajax backend)
        ln -sf "${SSA_ROOT}/SMH/chp.htm"         "${htdocs_hpssa}/chp.htm"
        ln -sf "${SSA_ROOT}/SMH/ipcelmclient.php" "${htdocs_hpssa}/ipcelmclient.php"
    fi
fi
if [[ -f "${SSA_ROOT}/init.d/hpessad" && ! -e /etc/init.d/hpessad ]]; then
    log "fixup: /etc/init.d/hpessad -> ${SSA_ROOT}/init.d/hpessad"
    mkdir -p /etc/init.d
    # README says copy (not symlink) — the init script chdirs based on its
    # own location to find $SSA_ROOT; symlink resolution confuses it on some
    # paths.  Copy with exec bits.
    install -m 0755 "${SSA_ROOT}/init.d/hpessad" /etc/init.d/hpessad
fi

# hpsmh >= 7.6.7 ships /opt/hp/sslshare/{file,cert}.pem and its %post seeds
# the host-level /etc/opt/hp/sslshare/ that other HP agents read.  Older
# hpsmh (7.6.5) doesn't ship the source files, so gate on presence rather
# than version — harmless skip on 7.6.5.
if [[ -f /opt/hp/sslshare/file.pem && ! -e /etc/opt/hp/sslshare/file.pem ]]; then
    log "fixup: seeding /etc/opt/hp/sslshare from /opt/hp/sslshare"
    mkdir -p /etc/opt/hp/sslshare
    install -m 0640 -o root -g hpsmh /opt/hp/sslshare/file.pem /etc/opt/hp/sslshare/file.pem 2>/dev/null || true
    install -m 0640 -o root -g hpsmh /opt/hp/sslshare/cert.pem /etc/opt/hp/sslshare/cert.pem 2>/dev/null || true
fi

# ilorest's %post symlinks /usr/sbin/ilorest -> /usr/sbin/hprest for
# back-compat with legacy scripts that still invoke "hprest".
if [[ -x /usr/sbin/ilorest && ! -e /usr/sbin/hprest ]]; then
    log "fixup: /usr/sbin/hprest -> /usr/sbin/ilorest"
    ln -sf /usr/sbin/ilorest /usr/sbin/hprest
fi

# sut's %post wires three things that rpm2tgz drops:
#   - /usr/sbin/sut    (PATH alias to /opt/sut/bin/sut)
#   - /usr/bin/hpsut   (alias used by older HPE tooling)
#   - /usr/local/sut/sut_recovery.dat (expected by sutd on first start)
if [[ -x /opt/sut/bin/sut ]]; then
    [[ -e /usr/sbin/sut ]]  || { log "fixup: /usr/sbin/sut -> /opt/sut/bin/sut"; ln -sf /opt/sut/bin/sut /usr/sbin/sut; }
    if [[ -x /opt/sut/bin/hpsut && ! -e /usr/bin/hpsut ]]; then
        log "fixup: /usr/bin/hpsut -> /opt/sut/bin/hpsut"
        ln -sf /opt/sut/bin/hpsut /usr/bin/hpsut
    fi
    if [[ ! -f /usr/local/sut/sut_recovery.dat ]]; then
        log "fixup: seeding /usr/local/sut/sut_recovery.dat"
        mkdir -p /usr/local/sut && touch /usr/local/sut/sut_recovery.dat
    fi
fi

# hp-snmp-agents needs the "dlmod cmaX" line and a rocommunity entry in
# snmpd.conf to let SMH query the HP OIDs.  hpsnmpconfig writes those.
# Run it once (idempotent — it skips if cmaX is already there) when
# snmpd's config file is present but unconfigured.
if [[ -x /sbin/hpsnmpconfig && -f /etc/snmp/snmpd.conf ]] \
        && ! grep -q "^dlmod cmaX" /etc/snmp/snmpd.conf; then
    log "fixup: seeding snmpd.conf with dlmod cmaX + public rocommunity"
    /sbin/hpsnmpconfig --a --rws public --ros public >/dev/null 2>&1 || true
fi

# Snapshot the plugin-generated snmpd.conf as the "base" for the drop-in
# system.  At boot, rc.hpe-mgmt concatenates base + /boot/config/plugins/
# hpe-mgmt/snmpd.d/*.conf into /etc/snmp/snmpd.conf, so user site config
# survives plugin reinstalls and unRAID reboots (which wipe /etc).
# Only snapshot once; a subsequent install must not clobber a working base
# if the user has customized it through the plugin's own mechanisms.
if [[ -f /etc/snmp/snmpd.conf && ! -f "${CFG_DIR}/snmpd.conf.base" ]]; then
    install -m 0644 /etc/snmp/snmpd.conf "${CFG_DIR}/snmpd.conf.base"
    log "snapshot: ${CFG_DIR}/snmpd.conf.base"
fi
mkdir -p "${CFG_DIR}/snmpd.d"

# hpsmh's init script sources /opt/hp/hpsmh/bin/fixperms, but the RPM ships
# the file at /opt/hp/hpsmh/support/fixperms — the %post would have placed
# or symlinked it.
if [[ -f /opt/hp/hpsmh/support/fixperms && ! -e /opt/hp/hpsmh/bin/fixperms ]]; then
    log "fixup: /opt/hp/hpsmh/bin/fixperms -> ../support/fixperms"
    mkdir -p /opt/hp/hpsmh/bin
    ln -sf ../support/fixperms /opt/hp/hpsmh/bin/fixperms
fi

# csginkgo is shipped under /opt/hp/hp-snmp-agents/webagent/ and the
# %post of hp-smh-templates copies it into the webapp-data tree where
# SMH's "Set Threshold" action expects to exec it.  Copy idempotently.
if [[ -f /opt/hp/hp-snmp-agents/webagent/csginkgo \
        && -d /opt/hp/hpsmh/data/webapp-data/webagent ]]; then
    dst=/opt/hp/hpsmh/data/webapp-data/webagent/csginkgo
    if [[ ! -x "${dst}" ]]; then
        log "fixup: installing csginkgo into webapp-data/webagent/"
        install -m 0755 /opt/hp/hp-snmp-agents/webagent/csginkgo "${dst}"
        chown hpsmh:hpsmh "${dst}" 2>/dev/null || true
    fi
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
