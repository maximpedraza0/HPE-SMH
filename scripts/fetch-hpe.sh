#!/bin/bash
# Downloads HPE RPMs from the HPE SDR, converts them to Slackware .tgz
# via rpm2tgz, and installs with installpkg.
#
# Config keys consumed (from /boot/config/plugins/hpe-mgmt/hpe-mgmt.cfg):
#   STACK        modern | legacy | both
#   EXTRAS       space-separated list: ssaducli storcli hponcfg diag
#   MCP_DIST     CentOS | Alma | OracleLinux       (default CentOS)
#   MCP_VER      8 | 9 | current                   (default 8)
#   INSTALL_AMSD 0 | 1   install the amsd daemon family.  Default 0
#                because it links against libsystemd.so.0 / librpm.so.8,
#                which unRAID doesn't ship — turning this on requires
#                the compat-libs bundle (Tier 2, not yet implemented).
#   VERIFY_GPG   0 | 1   verify signatures.  Currently best-effort only:
#                the rpm shipped in Slackware -current is built without
#                OpenPGP support, so rpm --checksig cannot verify HPE's
#                signatures.  Proper verification (yum repomd.xml.asc +
#                sha256 against primary.xml) is tracked separately.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/packages"
STATE_DIR="/boot/config/plugins/${PLUGIN_NAME}/state"

# --- defaults, overridden by CFG ---
STACK="modern"
EXTRAS=""
MCP_DIST="CentOS"
MCP_VER="8"
INSTALL_AMSD="0"
VERIFY_GPG="1"

[[ -f "${CFG}" ]] && . "${CFG}"

mkdir -p "${CACHE_DIR}" "${STATE_DIR}"

log()  { printf '[fetch-hpe] %s\n' "$*"; }
warn() { printf '[fetch-hpe] WARN: %s\n' "$*" >&2; }
die()  { printf '[fetch-hpe] ERROR: %s\n' "$*" >&2; exit 1; }

HPE_SDR="https://downloads.linux.hpe.com/SDR/repo/mcp/${MCP_DIST}/${MCP_VER}/x86_64/current"

# ---------------------------------------------------------------------------
# Package resolution
# ---------------------------------------------------------------------------
# Tier 1 CLI tools: self-contained, link only against standard libraries
# available on unRAID (libstdc++, libpthread, libm, libdl).  Verified working
# on unRAID 7.2.3 / kernel 6.12.54.
TIER1_MODERN=(ssacli hponcfg)

# Tier 2 daemons (amsd family): need compat libs (librpm.so.8, libjson-c.so.4,
# libsystemd.so.0) that unRAID does not ship.  Currently opt-in via
# INSTALL_AMSD=1, and will only actually start if the compat-libs bundle
# is in place.  rc.hpe-mgmt reports missing libs per daemon.
TIER2_MODERN=(amsd)

resolve_packages() {
    local stack="$1" extras="$2"
    local -a pkgs=()

    case "${stack}" in
        modern|both)
            pkgs+=("${TIER1_MODERN[@]}")
            [[ "${INSTALL_AMSD}" == "1" ]] && pkgs+=("${TIER2_MODERN[@]}")
            ;;
    esac

    case "${stack}" in
        legacy|both)
            resolve_legacy_urls
            ;;
    esac

    for e in ${extras}; do
        case "${e}" in
            ssaducli|storcli|hponcfg) pkgs+=("${e}") ;;
            diag)    warn "HPE Offline Diagnostics is ISO-based; skipping" ;;
            *)       warn "unknown extra: ${e}" ;;
        esac
    done

    # Deduplicate in case hponcfg is listed both in Tier 1 and extras.
    local -A seen=()
    for p in "${pkgs[@]}"; do
        [[ -n "${seen[$p]:-}" ]] && continue
        seen[$p]=1
        resolve_latest_rpm "${HPE_SDR}/${p}"
    done
}

# Turn ".../current/<pkgname>" into the newest <pkgname>-*.rpm URL.
resolve_latest_rpm() {
    local prefix="$1"
    local dir pkgname latest
    dir="${prefix%/*}"
    pkgname="${prefix##*/}"
    latest="$(curl --fail --silent --location "${dir}/" \
        | grep -oE "href=\"${pkgname}-[0-9][^\"]+\\.rpm\"" \
        | sed -E 's/^href="//; s/"$//' \
        | sort -V | tail -1)"
    [[ -n "${latest}" ]] || { warn "no RPM found for ${pkgname}"; return; }
    echo "${dir}/${latest}"
}

resolve_legacy_urls() {
    # TODO: SMH 7.6.x lives on HPE's per-product download pages, not the SDR.
    # Will add a static URL map here once the exact files are validated.
    warn "legacy SMH URL map not yet implemented"
}

# ---------------------------------------------------------------------------
# Signature verification — currently a no-op (best effort only)
# ---------------------------------------------------------------------------
verify_rpm() {
    local rpm="$1"
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    # Our rpm-6.0.1 from Slackware -current is compiled without OpenPGP
    # support, so `rpm --checksig` always fails with "RPM was compiled
    # without OpenPGP support".  We detect that and emit a one-time
    # warning instead of refusing every install; proper verification
    # (yum repodata + sha256) is a separate work item.
    local out
    out="$(rpm --checksig "${rpm}" 2>&1 || true)"
    if grep -q "without OpenPGP support" <<<"${out}"; then
        [[ -z "${_GPG_WARNED:-}" ]] && {
            warn "rpm lacks OpenPGP support — signatures NOT being verified"
            warn "set VERIFY_GPG=0 to silence, or wait for repomd.xml-based verification"
            _GPG_WARNED=1
        }
        return 0
    fi
    if grep -qiE '(pgp|signatures).*OK' <<<"${out}"; then
        return 0
    fi
    warn "signature check failed for ${rpm##*/}: ${out}"
    return 1
}

# ---------------------------------------------------------------------------
# Per-RPM install pipeline
# ---------------------------------------------------------------------------
install_one_rpm() {
    local url="$1"
    local fn="${url##*/}"
    local cached="${CACHE_DIR}/${fn}"
    local txz="${CACHE_DIR}/${fn%.rpm}.tgz"

    if [[ ! -s "${cached}" ]]; then
        log "download ${fn}"
        curl --fail --silent --show-error --location \
            -o "${cached}.part" "${url}" \
            || { warn "download failed: ${fn}"; return 1; }
        mv "${cached}.part" "${cached}"
    else
        log "cached: ${fn}"
    fi

    if ! verify_rpm "${cached}"; then
        warn "refusing to install ${fn} (verification failed)"
        return 1
    fi

    if [[ ! -s "${txz}" ]]; then
        log "convert ${fn}"
        # rpm2tgz writes the output .tgz to whatever $(pwd) was when the
        # script was invoked, NOT next to the input file.  cd into the
        # cache dir so the output lands where install_one_rpm expects it.
        ( cd "${CACHE_DIR}" && rpm2tgz "${cached}" ) >/dev/null 2>&1 \
            || { warn "rpm2tgz failed for ${fn}"; return 1; }
    fi
    [[ -s "${txz}" ]] || { warn "expected ${txz##*/} missing"; return 1; }

    log "installpkg ${txz##*/}"
    installpkg --terse "${txz}"
    : > "${STATE_DIR}/${fn}.installed"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    log "stack=${STACK} extras=[${EXTRAS}] mcp=${MCP_DIST}/${MCP_VER} amsd=${INSTALL_AMSD}"

    mapfile -t URLS < <(resolve_packages "${STACK}" "${EXTRAS}")
    if [[ ${#URLS[@]} -eq 0 ]]; then
        warn "no packages resolved"
        return 0
    fi

    local failed=0
    for u in "${URLS[@]}"; do
        install_one_rpm "${u}" || failed=$((failed+1))
    done

    if (( failed > 0 )); then
        die "${failed} package(s) failed"
    fi
    log "done (${#URLS[@]} package(s))"
}

main "$@"
