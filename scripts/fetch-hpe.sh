#!/bin/bash
# Downloads HPE RPMs from the HPE SDR (MCP + SPP legacy), converts them to
# Slackware .tgz via rpm2tgz, and installs with installpkg.
#
# Config keys consumed (from /boot/config/plugins/hpe-mgmt/hpe-mgmt.cfg):
#   STACK        modern | legacy | both
#   EXTRAS       space-separated list: ssaducli storcli hponcfg diag
#   MCP_DIST     CentOS | Alma | OracleLinux       (default CentOS)
#   MCP_VER      8 | 9 | current                   (default 8)
#   SPP_LEGACY_VER  last SPP that still shipped SMH — default 2022.03.0
#                   (2022.08+ dropped SMH entirely)
#   INSTALL_AMSD 0 | 1   install the amsd daemon family.  Default 0.
#   VERIFY_GPG   0 | 1   verify metadata signature + per-RPM sha1.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/packages"
STATE_DIR="/boot/config/plugins/${PLUGIN_NAME}/state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- defaults, overridden by CFG ---
STACK="modern"
EXTRAS=""
MCP_DIST="CentOS"
MCP_VER="8"
SPP_LEGACY_VER="2022.03.0"
INSTALL_AMSD="0"
VERIFY_GPG="1"

[[ -f "${CFG}" ]] && . "${CFG}"

mkdir -p "${CACHE_DIR}" "${STATE_DIR}"

log()  { printf '[fetch-hpe] %s\n' "$*"; }
warn() { printf '[fetch-hpe] WARN: %s\n' "$*" >&2; }
die()  { printf '[fetch-hpe] ERROR: %s\n' "$*" >&2; exit 1; }

HPE_SDR_MCP="https://downloads.linux.hpe.com/SDR/repo/mcp/${MCP_DIST}/${MCP_VER}/x86_64/current"
HPE_SDR_SPP="https://downloads.linux.hpe.com/SDR/repo/spp/RedHat/8/x86_64/${SPP_LEGACY_VER}"

# ---------------------------------------------------------------------------
# Package resolution
# ---------------------------------------------------------------------------
# Tier 1 CLI tools: self-contained, standard libs only.  Verified on
# unRAID 7.2.3 / kernel 6.12.54.
TIER1_MODERN=(ssacli hponcfg)

# Tier 2 daemons (amsd family): need compat libs (librpm.so.8, libjson-c.so.4,
# libsystemd.so.0) that unRAID does not ship.  Opt-in via INSTALL_AMSD=1.
TIER2_MODERN=(amsd)

# Legacy SMH stack (SPP/RedHat/8/2022.03.0 is the last SPP that shipped SMH).
# These are known to work on EL8-based hosts; unRAID compat still TBD.
LEGACY_PKGS=(hpsmh hp-smh-templates hp-health hp-snmp-agents hp-ams)

# resolve_packages emits one "<repo_base> <pkgname>" pair per line, to be
# resolved by resolve_latest_rpm into concrete <base>/<fn>.rpm URLs.
resolve_packages() {
    local stack="$1" extras="$2"

    case "${stack}" in
        modern|both)
            for p in "${TIER1_MODERN[@]}"; do echo "${HPE_SDR_MCP} ${p}"; done
            if [[ "${INSTALL_AMSD}" == "1" ]]; then
                for p in "${TIER2_MODERN[@]}"; do echo "${HPE_SDR_MCP} ${p}"; done
            fi
            ;;
    esac

    case "${stack}" in
        legacy|both)
            for p in "${LEGACY_PKGS[@]}"; do echo "${HPE_SDR_SPP} ${p}"; done
            ;;
    esac

    for e in ${extras}; do
        case "${e}" in
            ssaducli|storcli|hponcfg) echo "${HPE_SDR_MCP} ${e}" ;;
            diag) warn "HPE Offline Diagnostics is ISO-based; skipping" ;;
            *)    warn "unknown extra: ${e}" ;;
        esac
    done
}

# resolve_latest_rpm <base_url> <pkgname>
# Returns the newest <pkgname>-*.rpm URL under <base_url>.
resolve_latest_rpm() {
    local base="$1" pkgname="$2"
    local latest
    latest="$(curl --fail --silent --location "${base}/" \
        | grep -oE "href=\"${pkgname}-[0-9][^\"]+\\.rpm\"" \
        | sed -E 's/^href="//; s/"$//' \
        | sort -V | tail -1)"
    [[ -n "${latest}" ]] || { warn "no RPM found for ${pkgname} in ${base}"; return; }
    echo "${base}/${latest}"
}

# Dedup + resolve.  Emits one RPM URL per line.
resolve_urls() {
    local stack="$1" extras="$2"
    local -A seen=()
    while read -r base pkg; do
        [[ -z "${base:-}" || -z "${pkg:-}" ]] && continue
        local key="${base}|${pkg}"
        [[ -n "${seen[$key]:-}" ]] && continue
        seen[$key]=1
        resolve_latest_rpm "${base}" "${pkg}"
    done < <(resolve_packages "${stack}" "${extras}")
}

# ---------------------------------------------------------------------------
# Signature verification — yum-style trust chain via repomd.xml
# ---------------------------------------------------------------------------
declare -A SHA1_MAP=()

# Which repo(s) do we need to verify, given the current stack?  Keep the
# set minimal so we don't pay network cost for repos we aren't using.
repos_for_stack() {
    case "${STACK}" in
        modern) echo "${HPE_SDR_MCP}" ;;
        legacy) echo "${HPE_SDR_SPP}" ;;
        both)   echo "${HPE_SDR_MCP}"; echo "${HPE_SDR_SPP}" ;;
    esac
}

refresh_repo_sha1_map() {
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    log "refreshing repo metadata + signatures"
    local verifier="${SCRIPT_DIR}/verify-repo.sh"
    local tmp; tmp="$(mktemp)"
    if ! repos_for_stack | bash "${verifier}" > "${tmp}"; then
        rm -f "${tmp}"
        die "verify-repo.sh failed; refusing to install anything"
    fi
    local fn sha
    while read -r fn sha; do
        [[ -n "${fn}" && -n "${sha}" ]] && SHA1_MAP["${fn}"]="${sha}"
    done < "${tmp}"
    rm -f "${tmp}"
    log "trusted sha1 map: ${#SHA1_MAP[@]} packages"
}

verify_rpm() {
    local rpm="$1"
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    local fn="${rpm##*/}"
    local expected="${SHA1_MAP[${fn}]:-}"
    if [[ -z "${expected}" ]]; then
        warn "no sha1 for ${fn} in repo metadata"
        return 1
    fi
    local actual; actual="$(sha1sum "${rpm}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        warn "sha1 mismatch for ${fn}: got ${actual}, expected ${expected}"
        return 1
    fi
    return 0
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
    log "stack=${STACK} extras=[${EXTRAS}] mcp=${MCP_DIST}/${MCP_VER} spp=${SPP_LEGACY_VER} amsd=${INSTALL_AMSD}"

    refresh_repo_sha1_map

    mapfile -t URLS < <(resolve_urls "${STACK}" "${EXTRAS}")
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
