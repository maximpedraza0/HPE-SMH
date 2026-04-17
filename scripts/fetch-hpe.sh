#!/bin/bash
# Downloads HPE RPMs from HPE SDR (and SMH legacy URL) according to the plugin
# config, verifies GPG signature when possible, converts to .txz via rpm2tgz
# and installs with installpkg.
#
# Config keys consumed (from /boot/config/plugins/hpe-mgmt/hpe-mgmt.cfg):
#   STACK    = modern | legacy | both
#   EXTRAS   = space-separated list: ssaducli storcli hponcfg diag
#   MCP_DIST = CentOS|Alma|OracleLinux  (default CentOS)
#   MCP_VER  = 8|9|current              (default 8)

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/packages"
STATE_DIR="/boot/config/plugins/${PLUGIN_NAME}/state"
WORK_DIR="$(mktemp -d -t hpe-mgmt-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# --- defaults, overridden by CFG ---
STACK="modern"
EXTRAS=""
MCP_DIST="CentOS"
MCP_VER="8"
VERIFY_GPG="1"

[[ -f "${CFG}" ]] && . "${CFG}"

mkdir -p "${CACHE_DIR}" "${STATE_DIR}"

log()  { printf '[fetch-hpe] %s\n' "$*"; }
warn() { printf '[fetch-hpe] WARN: %s\n' "$*" >&2; }
die()  { printf '[fetch-hpe] ERROR: %s\n' "$*" >&2; exit 1; }

HPE_SDR="https://downloads.linux.hpe.com/SDR/repo/mcp/${MCP_DIST}/${MCP_VER}/x86_64/current"
HPE_GPG_URLS=(
    "https://downloads.linux.hpe.com/SDR/hpPublicKey2048.pub"
    "https://downloads.linux.hpe.com/SDR/hpPublicKey2048_key1.pub"
    "https://downloads.linux.hpe.com/SDR/hpePublicKey2048_key1.pub"
)

# Resolve the list of RPMs to fetch from stack+extras.
# Returns absolute URLs on stdout, one per line.
resolve_packages() {
    local stack="$1" extras="$2"
    local -a pkgs=()

    case "${stack}" in
        modern|both)
            pkgs+=("${HPE_SDR}/amsd")
            pkgs+=("${HPE_SDR}/ssacli")
            pkgs+=("${HPE_SDR}/hponcfg")
            ;;
    esac

    case "${stack}" in
        legacy|both)
            # SMH and its CMA stack: last published versions live outside
            # the MCP "current" tree. URLs resolved in resolve_legacy_urls.
            resolve_legacy_urls
            ;;
    esac

    for e in ${extras}; do
        case "${e}" in
            ssaducli) pkgs+=("${HPE_SDR}/ssaducli") ;;
            storcli)  pkgs+=("${HPE_SDR}/storcli")  ;;
            hponcfg)  pkgs+=("${HPE_SDR}/hponcfg")  ;;
            diag)     warn "HPE Offline Diagnostics is ISO-based; skipping here" ;;
            *)        warn "unknown extra: ${e}" ;;
        esac
    done

    # For MCP entries the URL above is a directory prefix name without .rpm;
    # real filename is resolved against the directory listing.
    for base in "${pkgs[@]}"; do
        resolve_latest_rpm "${base}"
    done
}

# Given e.g. ".../current/amsd" return the newest amsd-*.rpm URL.
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
    # Placeholder — SMH 7.6.x was distributed on HPE support site per-product,
    # not in the SDR. We will fill a static map here after validating exact
    # URLs (hpsmh, hp-ams legacy, hp-snmp-agents, cpqacuxe...).
    warn "legacy SMH URL map not yet implemented — see docs/LEGACY_URLS.md"
}

import_gpg_keys() {
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    for url in "${HPE_GPG_URLS[@]}"; do
        log "importing HPE key: ${url##*/}"
        curl --fail --silent --location "${url}" \
            | rpm --import /dev/stdin \
            || warn "could not import ${url##*/}"
    done
}

verify_rpm() {
    local rpm="$1"
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    if rpm --checksig "${rpm}" | grep -qiE '(pgp|signatures).*OK'; then
        return 0
    fi
    warn "GPG signature check FAILED for ${rpm##*/}"
    return 1
}

install_one_rpm() {
    local url="$1"
    local fn="${url##*/}"
    local cached="${CACHE_DIR}/${fn}"
    local txz

    if [[ ! -s "${cached}" ]]; then
        log "download ${fn}"
        curl --fail --silent --show-error --location \
            -o "${cached}.part" "${url}" \
            || { warn "download failed: ${fn}"; return 1; }
        mv "${cached}.part" "${cached}"
    fi

    if ! verify_rpm "${cached}"; then
        die "refusing to install unverified package: ${fn}"
    fi

    log "convert ${fn} to .txz"
    ( cd "${WORK_DIR}" && rpm2tgz -r "${cached}" >/dev/null )
    txz="$(ls -1 "${WORK_DIR}"/*.t[gx]z 2>/dev/null | head -1)"
    [[ -s "${txz}" ]] || { warn "rpm2tgz produced nothing for ${fn}"; return 1; }

    log "installpkg ${txz##*/}"
    installpkg --terse "${txz}"
    mv -f "${txz}" "${CACHE_DIR}/" || true
    : > "${STATE_DIR}/${fn}.installed"
}

main() {
    log "stack=${STACK} extras=[${EXTRAS}] mcp=${MCP_DIST}/${MCP_VER}"
    import_gpg_keys

    mapfile -t URLS < <(resolve_packages "${STACK}" "${EXTRAS}")
    if [[ ${#URLS[@]} -eq 0 ]]; then
        warn "no packages to install"
        return 0
    fi

    local failed=0
    for u in "${URLS[@]}"; do
        install_one_rpm "${u}" || failed=$((failed+1))
    done

    if (( failed > 0 )); then
        die "${failed} package(s) failed to install"
    fi
    log "all selected packages installed"
}

main "$@"
