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
SPP_LEGACY_VER="auto"
INSTALL_AMSD="0"
VERIFY_GPG="1"

[[ -f "${CFG}" ]] && . "${CFG}"

# Auto-pick SPP version from the detected ProLiant generation.  Gen8 sticks
# to 2020.09.0 (last drop with ssa 4.x that knows the P420 and kin); Gen9
# tracks 2021.10.0; Gen10/Gen10 Plus use 2022.03.0 (newest SPP with SMH).
# When dmidecode can't read a matching name we fall back to 2020.09.0
# — the broadest-compat drop.
resolve_spp_auto() {
    local prod
    prod="$(dmidecode -s system-product-name 2>/dev/null || true)"
    case "${prod}" in
        *Gen8*)  echo "2020.09.0" ;;
        *Gen9*)  echo "2021.10.0" ;;
        *Gen10*) echo "2022.03.0" ;;
        *)       echo "2020.09.0" ;;
    esac
}
if [[ -z "${SPP_LEGACY_VER}" || "${SPP_LEGACY_VER}" == "auto" ]]; then
    SPP_LEGACY_VER="$(resolve_spp_auto)"
fi

mkdir -p "${CACHE_DIR}" "${STATE_DIR}"

log()  { printf '[fetch-hpe] %s\n' "$*"; }
warn() { printf '[fetch-hpe] WARN: %s\n' "$*" >&2; }
die()  { printf '[fetch-hpe] ERROR: %s\n' "$*" >&2; exit 1; }

HPE_SDR_MCP="https://downloads.linux.hpe.com/SDR/repo/mcp/${MCP_DIST}/${MCP_VER}/x86_64/current"
HPE_SDR_SPP="https://downloads.linux.hpe.com/SDR/repo/spp/RedHat/8/x86_64/${SPP_LEGACY_VER}"
# hp-ocsbbd and hp-tg3sd are legacy SAS/NIC status daemons that HPE only
# ships in the RHEL 7 tree of the same SPP drop.  The binaries are static
# enough to run on EL8 userland (verified on unRAID 7.2.3).
HPE_SDR_SPP_RHEL7="https://downloads.linux.hpe.com/SDR/repo/spp/RedHat/7/x86_64/${SPP_LEGACY_VER}"
# Standalone HPE SDR trees for tools that don't live in MCP or SPP.
HPE_SDR_ILOREST="https://downloads.linux.hpe.com/SDR/repo/ilorest/RedHat/7/x86_64/current"
HPE_SDR_SUM="https://downloads.linux.hpe.com/SDR/repo/sum/RedHat/8/x86_64/current"

# AlmaLinux 8 serves as our compat-lib source.  HPE's EL8-built RPMs
# (hp-ams, hp-snmp-agents, hpsmhd, amsd...) link against libs that
# ship in AlmaLinux 8 and NOT in Slackware/unRAID (libsystemd.so.0,
# librpm.so.8, libidn.so.11, libnetsnmp.so.35, libcrypto.so.1.1,
# libjson-c.so.4).  Soname-isolated — they coexist with unRAID's
# native libs.  Same repomd+sha1 trust chain as for HPE.
ALMA_BASEOS="https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os"
ALMA_APPSTREAM="https://repo.almalinux.org/almalinux/8/AppStream/x86_64/os"

# ---------------------------------------------------------------------------
# Package resolution
# ---------------------------------------------------------------------------
# Tier 1 CLI tools: self-contained, standard libs only.  Verified on
# unRAID 7.2.3 / kernel 6.12.54.  ssacli is pulled from MCP when running
# pure modern, and from SPP when legacy/both is selected — SPP 2022.03.0
# ships the newer 5.30 versions while MCP "current" is pinned at 5.10-44.
TIER1_MODERN=(ssacli hponcfg)

# Tier 2 daemons (amsd family): need compat libs (librpm.so.8, libjson-c.so.4,
# libsystemd.so.0) that unRAID does not ship.  Opt-in via INSTALL_AMSD=1.
TIER2_MODERN=(amsd)

# Legacy SMH stack (SPP/RedHat/8/2022.03.0 is the last SPP that shipped SMH).
# These are known to work on EL8-based hosts; unRAID compat still TBD.
LEGACY_PKGS=(hpsmh hp-smh-templates hp-health hp-snmp-agents hp-ams)

# Compat libs from AlmaLinux 8.  Required whenever we install anything that
# wasn't built against Slackware — i.e. legacy SMH or the Tier 2 amsd family.
# Transitive deps are inherited: rpm-libs-4.14 pulls in libaudit/libdb/liblua
# from EL8 because those are what the EL8 rpm links against.
COMPAT_PKGS_BASEOS=(
    net-snmp-libs openssl-libs rpm-libs systemd-libs json-c
    audit-libs libdb lua-libs
    # cmanicd chains: lm_sensors-libs → libsensors.so.4, perl-libs → libperl.so.5.26
    lm_sensors-libs perl-libs
)
# net-snmp provides the snmpd daemon that SMH queries for every panel
# (hmanics, hmastor, hmaserv...) via HP enterprise OIDs; hp-snmp-agents'
# cma* sub-agents plug into it via AgentX.  Without snmpd SMH shows only
# SSA (which reads its own socket, not SNMP).
# net-snmp-agent-libs provides libnetsnmpmibs.so.35 for cmanicd.
COMPAT_PKGS_APPSTREAM=(libidn net-snmp-agent-libs net-snmp)

# resolve_packages emits one "<repo_base> <pkgname>" pair per line, to be
# resolved by resolve_latest_rpm into concrete <base>/<fn>.rpm URLs.
resolve_packages() {
    local stack="$1" extras="$2"

    # Each stack has ONE canonical source to keep transitive deps consistent:
    #   modern -> HPE SDR MCP "current" (older ssa 5.10, but matched toolchain)
    #   legacy -> HPE SDR SPP 2022.03.0 (newer ssa 5.30 paired with hpsmh 7.6.7)
    # amsd lives only in MCP so it always comes from there.
    local tier1_repo="${HPE_SDR_MCP}"
    [[ "${stack}" == "legacy" ]] && tier1_repo="${HPE_SDR_SPP}"

    case "${stack}" in
        modern)
            for p in "${TIER1_MODERN[@]}"; do echo "${tier1_repo} ${p}"; done
            if [[ "${INSTALL_AMSD}" == "1" ]]; then
                for p in "${TIER2_MODERN[@]}"; do echo "${HPE_SDR_MCP} ${p}"; done
            fi
            ;;
        legacy)
            for p in "${TIER1_MODERN[@]}"; do echo "${tier1_repo} ${p}"; done
            for p in "${LEGACY_PKGS[@]}"; do echo "${HPE_SDR_SPP} ${p}"; done
            ;;
    esac

    # Compat libs: needed if we install anything that expects EL8 userspace.
    if need_compat_libs; then
        for p in "${COMPAT_PKGS_BASEOS[@]}";    do echo "${ALMA_BASEOS} ${p}"; done
        for p in "${COMPAT_PKGS_APPSTREAM[@]}"; do echo "${ALMA_APPSTREAM} ${p}"; done
    fi

    for e in ${extras}; do
        case "${e}" in
            ssa|ssaducli|hponcfg|fibreutils|sut|amsd|mft) echo "${tier1_repo} ${e}" ;;
            hpe-emulex-smartsan-enablement-kit|hpe-qlogic-smartsan-enablement-kit)
                echo "${tier1_repo} ${e}" ;;
            storcli) echo "${HPE_SDR_MCP} ${e}" ;;            # MCP-only
            ilorest) echo "${HPE_SDR_ILOREST} ${e}" ;;
            sum)     echo "${HPE_SDR_SUM} ${e}" ;;
            hp-ocsbbd|hp-tg3sd)                               # RHEL 7 tree only
                     echo "${HPE_SDR_SPP_RHEL7} ${e}" ;;
            diag) warn "HPE Offline Diagnostics is ISO-based; skipping" ;;
            *)    warn "unknown extra: ${e}" ;;
        esac
    done
}

need_compat_libs() {
    case "${STACK}" in
        legacy|both) return 0 ;;
    esac
    [[ "${INSTALL_AMSD}" == "1" ]] && return 0
    return 1
}

# resolve_latest_rpm <base_url> <pkgname>
# Returns the newest <pkgname>-*.rpm URL that lives under <base_url>,
# using URL_MAP (populated from verify-repo.sh output).  No HTTP scrape:
# every RPM we'd consider installing is already in the trusted map.
resolve_latest_rpm() {
    local base="$1" pkgname="$2"
    local fn url
    local -a candidates=()
    for fn in "${!URL_MAP[@]}"; do
        url="${URL_MAP[$fn]}"
        [[ "${url}" == "${base}/"* ]] || continue
        [[ "${fn}" =~ ^${pkgname}-[0-9] ]] || continue
        [[ "${fn}" == *.rpm ]] || continue
        candidates+=("${fn}")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "no RPM found for ${pkgname} in ${base}"
        return
    fi
    local latest; latest="$(printf '%s\n' "${candidates[@]}" | sort -V | tail -1)"
    echo "${URL_MAP[$latest]}"
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
# verify-repo.sh emits "<full-url> <checksum-type> <checksum>" per line.
# We build two filename-keyed maps from it:
#   URL_MAP["<fn>"]      = full URL to the RPM
#   CHECKSUM_MAP["<fn>"] = "<type>:<hash>"
# PKGS_BY_BASE[<base>][<fn>] would be ideal for disambiguation, but bash
# does not support nested assoc arrays.  We store the URL in URL_MAP and
# rely on resolve_latest_rpm filtering by URL prefix (base).
declare -A CHECKSUM_MAP=()
declare -A URL_MAP=()

# Which repo(s) do we need to verify, given the current stack?  Keep the
# set minimal so we don't pay network cost for repos we aren't using.
repos_for_stack() {
    case "${STACK}" in
        modern) echo "${HPE_SDR_MCP}" ;;
        legacy) echo "${HPE_SDR_SPP}" ;;
    esac
    if need_compat_libs; then
        echo "${ALMA_BASEOS}"
        echo "${ALMA_APPSTREAM}"
    fi
    # Only verify the standalone trees when the user has actually asked
    # for one of their packages — keeps the metadata refresh minimal.
    for e in ${EXTRAS}; do
        case "${e}" in
            ilorest)           echo "${HPE_SDR_ILOREST}" ;;
            sum)               echo "${HPE_SDR_SUM}" ;;
            hp-ocsbbd|hp-tg3sd) echo "${HPE_SDR_SPP_RHEL7}" ;;
        esac
    done
}

# Wait for the network/DNS to settle before any HTTPS fetch.
#
# unRAID's plugin-manager runs install scripts very early in boot, and on
# a cold start DNS may not yet be resolving (the LAN router is still
# negotiating DHCP, or systemd-resolved-equivalent hasn't read
# /etc/resolv.conf).  A failing curl in verify-repo.sh / install_one_rpm
# would exit non-zero, the .plg INLINE script returns 1, and unRAID
# moves /boot/config/plugins/hpe-mgmt.plg into plugins-error/ — at which
# point the plugin silently disappears until the user notices.
#
# Probe a known-stable HPE host with `getent hosts` (which uses nsswitch
# and respects /etc/hosts caching) up to ~60s before giving up.  Don't
# die on timeout — refresh_checksum_map will do its own retries and may
# still succeed if connectivity comes up shortly after.
wait_for_dns() {
    local target="downloads.linux.hpe.com"
    local waited=0
    local interval=2
    local max_wait=60
    while (( waited < max_wait )); do
        if getent hosts "${target}" >/dev/null 2>&1; then
            (( waited > 0 )) && log "DNS for ${target} ready after ${waited}s"
            return 0
        fi
        sleep "${interval}"
        waited=$(( waited + interval ))
    done
    warn "DNS for ${target} not resolving after ${max_wait}s; proceeding with retries"
    return 1
}

refresh_checksum_map() {
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    log "refreshing repo metadata + signatures"
    local verifier="${SCRIPT_DIR}/verify-repo.sh"
    local tmp; tmp="$(mktemp)"

    # Retry the metadata fetch a few times.  On a cold boot the first
    # attempt can hit DNS that just barely came up, or a router that's
    # still issuing the DHCP lease, and verify-repo.sh exits non-zero.
    # A short retry loop covers both cases without prolonging successful
    # boots noticeably.
    local attempt=1
    local max_attempts=5
    local backoff=5
    while (( attempt <= max_attempts )); do
        if repos_for_stack | bash "${verifier}" > "${tmp}" 2>/dev/null; then
            break
        fi
        if (( attempt < max_attempts )); then
            warn "verify-repo failed (attempt ${attempt}/${max_attempts}); retrying in ${backoff}s"
            sleep "${backoff}"
        fi
        attempt=$(( attempt + 1 ))
    done
    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        die "verify-repo.sh failed after ${max_attempts} attempts; refusing to install anything"
    fi

    local url type hash fn
    while read -r url type hash; do
        [[ -n "${url}" && -n "${type}" && -n "${hash}" ]] || continue
        fn="${url##*/}"
        URL_MAP["${fn}"]="${url}"
        CHECKSUM_MAP["${fn}"]="${type}:${hash}"
    done < "${tmp}"
    rm -f "${tmp}"
    log "trusted checksum map: ${#CHECKSUM_MAP[@]} packages"
}

verify_rpm() {
    local rpm="$1"
    [[ "${VERIFY_GPG}" == "1" ]] || return 0
    local fn="${rpm##*/}"
    local entry="${CHECKSUM_MAP[${fn}]:-}"
    if [[ -z "${entry}" ]]; then
        warn "no checksum for ${fn} in repo metadata"
        return 1
    fi
    local type="${entry%%:*}"
    local expected="${entry#*:}"
    local tool
    case "${type}" in
        sha|sha1) tool=sha1sum ;;
        sha256)   tool=sha256sum ;;
        sha512)   tool=sha512sum ;;
        *) warn "unsupported checksum type for ${fn}: ${type}"; return 1 ;;
    esac
    local actual; actual="$(${tool} "${rpm}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        warn "${type} mismatch for ${fn}: got ${actual}, expected ${expected}"
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

    if [[ "${STACK}" == "disabled" ]]; then
        log "stack=disabled — not fetching anything"
        return 0
    fi

    wait_for_dns
    refresh_checksum_map

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

    # Refresh the shared-library cache so the newly-installed compat libs
    # (libidn, libsystemd, librpm, libnetsnmp, etc.) become discoverable
    # before we try to start any daemon.
    ldconfig 2>/dev/null || true

    log "done (${#URLS[@]} package(s))"
}

main "$@"
