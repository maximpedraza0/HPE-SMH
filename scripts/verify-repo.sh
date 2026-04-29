#!/bin/bash
# Refresh + GPG-verify one or more HPE yum repositories, then emit a
# combined "<rpm-filename> <sha1>" map to stdout.
#
# Chain of trust (per repo):
#   1. repomd.xml        — index of all other metadata files
#   2. repomd.xml.asc    — detached OpenPGP signature, verified against
#                          the HPE key imported by bootstrap-gpg.sh
#   3. primary.xml.gz    — per-package metadata; its sha1 is in repomd.xml
#   4. each RPM's sha1   — lives in primary.xml, trusted by induction
#
# Repos to process are passed as positional args, each one being the base
# URL of the repo (the parent of its repodata/ directory).  Alternatively,
# newline-separated URLs on stdin are accepted.  With no args and no
# stdin, falls back to the MCP mcp/<dist>/<ver>/x86_64/current tree
# inferred from the plugin config.
#
# Per-repo state (repomd, primary, sha1-map, stamp) is cached under
# ${CACHE_DIR}/<slug>/ where <slug> is a sha1 of the repo URL.  This lets
# us re-parse only the repo(s) whose repomd.xml actually changed.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/repodata"
KEYRING_DIR="/boot/config/plugins/${PLUGIN_NAME}/gnupg"

MCP_DIST="CentOS"
MCP_VER="8"
[[ -f "${CFG}" ]] && . "${CFG}"

log()  { printf '[verify-repo] %s\n' "$*" >&2; }
die()  { printf '[verify-repo] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "${CACHE_DIR}"

command -v gpg1    >/dev/null || die "gpg1 not installed (run bootstrap-gpg.sh)"
command -v sha1sum >/dev/null || die "sha1sum missing"
command -v xmllint >/dev/null || die "xmllint missing"
[[ -d "${KEYRING_DIR}" ]]     || die "keyring missing (run bootstrap-gpg.sh)"

# ---------------------------------------------------------------------------
# Process a single repo.  Leaves ${slug_dir}/sha1-map.txt populated and
# prints it to stdout.
# ---------------------------------------------------------------------------
process_repo() {
    local base_url="$1"
    local slug; slug="$(printf '%s' "${base_url}" | sha1sum | awk '{print $1}' | head -c 12)"
    local slug_dir="${CACHE_DIR}/${slug}"
    mkdir -p "${slug_dir}"

    # Remember the URL so operators can inspect the cache later.
    printf '%s\n' "${base_url}" > "${slug_dir}/url"

    local repomd="${slug_dir}/repomd.xml"
    local repomd_asc="${slug_dir}/repomd.xml.asc"
    local map_file="${slug_dir}/sha1-map.txt"

    log "[${slug}] fetching repomd.xml from ${base_url}"
    curl --fail --silent --show-error --location \
        -o "${repomd}.new"     "${base_url}/repodata/repomd.xml" \
        || die "repomd.xml download failed for ${base_url}"
    curl --fail --silent --show-error --location \
        -o "${repomd_asc}.new" "${base_url}/repodata/repomd.xml.asc" \
        || die "repomd.xml.asc download failed for ${base_url}"

    log "[${slug}] verifying signature"
    if ! gpg1 --homedir "${KEYRING_DIR}" --verify \
            "${repomd_asc}.new" "${repomd}.new" 2>&1 | grep -q "Good signature"; then
        rm -f "${repomd}.new" "${repomd_asc}.new"
        die "repomd.xml signature invalid for ${base_url}"
    fi
    mv "${repomd}.new"     "${repomd}"
    mv "${repomd_asc}.new" "${repomd_asc}"

    local repomd_sha1; repomd_sha1="$(sha1sum "${repomd}" | awk '{print $1}')"
    # v2: 4-column output (base url url type hash).  Old caches written by
    # the v1 stripe (3 columns) won't carry this stamp prefix, so they
    # transparently miss-and-rebuild on first run after upgrade.
    local stamp_file="${slug_dir}/.stamp.v2.${repomd_sha1}"

    if [[ -s "${map_file}" && -f "${stamp_file}" ]]; then
        log "[${slug}] checksum-map cached (${repomd_sha1:0:12}...)"
        cat "${map_file}"
        return 0
    fi

    # --- resolve primary.xml entry (any checksum type) ---
    local primary_href primary_ck_type primary_ck_value
    primary_href="$(xmllint --xpath 'string(//*[local-name()="data"][@type="primary"]/*[local-name()="location"]/@href)' "${repomd}")"
    primary_ck_type="$(xmllint --xpath 'string(//*[local-name()="data"][@type="primary"]/*[local-name()="checksum"]/@type)' "${repomd}")"
    primary_ck_value="$(xmllint --xpath 'string(//*[local-name()="data"][@type="primary"]/*[local-name()="checksum"])' "${repomd}")"
    [[ -n "${primary_href}" && -n "${primary_ck_value}" ]] \
        || die "[${slug}] could not extract primary.xml entry"

    # Map repomd checksum-type to a coreutils tool.  HPE uses "sha" (SHA-1),
    # AlmaLinux uses "sha256".  Any other type is unexpected.
    local hash_tool
    case "${primary_ck_type}" in
        sha|sha1)    hash_tool=sha1sum ;;
        sha256)      hash_tool=sha256sum ;;
        sha512)      hash_tool=sha512sum ;;
        *) die "[${slug}] unsupported checksum type: ${primary_ck_type}" ;;
    esac

    local primary_gz="${slug_dir}/$(basename "${primary_href}")"
    log "[${slug}] fetching $(basename "${primary_href}")"
    curl --fail --silent --show-error --location \
        -o "${primary_gz}" "${base_url}/${primary_href}" \
        || die "[${slug}] primary.xml.gz download failed"

    local actual; actual="$(${hash_tool} "${primary_gz}" | awk '{print $1}')"
    [[ "${actual}" == "${primary_ck_value}" ]] \
        || die "[${slug}] primary.xml.gz ${primary_ck_type} mismatch: got ${actual}, expected ${primary_ck_value}"
    log "[${slug}] primary.xml.gz OK (${primary_ck_type} ${actual:0:12}...)"

    local primary_xml="${primary_gz%.gz}"
    zcat "${primary_gz}" > "${primary_xml}"

    # Awk-parse primary.xml.  We output the full URL of each package (base
    # url + <location href>) so downstream doesn't need to know the
    # per-repo on-disk layout (HPE SDR is flat, AlmaLinux uses Packages/).
    # We also echo back the original base URL we were given, so fetch-hpe
    # can group entries by repo without having to guess the base from a
    # full URL (which is ambiguous when the layout includes a Packages/x/
    # subdirectory).
    # Output columns:
    #   <base-url>  <full-rpm-url>  <checksum-type>  <checksum-value>
    awk -v base="${base_url}" '
        /<package / { loc=""; ck=""; ck_type=""; inpkg=1 }
        inpkg && /<checksum [^>]*pkgid="YES"/ {
            if (match($0, /type="[^"]+"/)) ck_type = substr($0, RSTART+6, RLENGTH-7)
            if (match($0, />[a-f0-9]+</)) ck = substr($0, RSTART+1, RLENGTH-2)
        }
        inpkg && /<location href=/ {
            if (match($0, /href="[^"]+"/)) loc = substr($0, RSTART+6, RLENGTH-7)
        }
        /<\/package>/ && inpkg {
            if (loc && ck && ck_type) print base, base "/" loc, ck_type, ck
            inpkg=0
        }
    ' "${primary_xml}" > "${map_file}.new" \
        || die "[${slug}] awk parse of primary.xml failed"

    # Invalidate any older stamp from a previous repomd version.
    rm -f "${slug_dir}"/.stamp.*
    mv "${map_file}.new" "${map_file}"
    : > "${stamp_file}"

    log "[${slug}] checksum-map built: $(wc -l < "${map_file}") entries"
    cat "${map_file}"
}

# ---------------------------------------------------------------------------
# Collect the list of repo URLs.
# ---------------------------------------------------------------------------
declare -a URLS=()

if [[ $# -gt 0 ]]; then
    URLS=("$@")
elif ! [[ -t 0 ]]; then
    # stdin has content — read one URL per line, skipping blanks/comments.
    while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        [[ "${line}" == \#* ]] && continue
        URLS+=("${line}")
    done
fi

if [[ ${#URLS[@]} -eq 0 ]]; then
    URLS=("https://downloads.linux.hpe.com/SDR/repo/mcp/${MCP_DIST}/${MCP_VER}/x86_64/current")
fi

for u in "${URLS[@]}"; do
    process_repo "${u}"
done
