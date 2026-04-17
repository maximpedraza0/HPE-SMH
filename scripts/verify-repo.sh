#!/bin/bash
# Refresh + verify HPE SDR repository metadata, then emit a
# "<filename> <sha1>" map of every RPM in the repo to stdout.
#
# Chain of trust:
#   1. repomd.xml        — index of all other metadata files
#   2. repomd.xml.asc    — detached OpenPGP signature, verified against
#                           the HPE key imported by bootstrap-gpg.sh
#   3. primary.xml.gz    — per-package metadata; its sha1 is in repomd.xml
#   4. each RPM's sha1   — lives in primary.xml, trusted by induction
#
# We cache the parsed map at ${CACHE_DIR}/sha1-map.txt so the parse only
# happens when repomd.xml actually changed.  Cache key: sha1 of repomd.xml.

set -euo pipefail

PLUGIN_NAME="hpe-mgmt"
CFG="/boot/config/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.cfg"
CACHE_DIR="/boot/config/plugins/${PLUGIN_NAME}/repodata"
KEYRING_DIR="/boot/config/plugins/${PLUGIN_NAME}/gnupg"

MCP_DIST="CentOS"
MCP_VER="8"
[[ -f "${CFG}" ]] && . "${CFG}"

BASE_URL="https://downloads.linux.hpe.com/SDR/repo/mcp/${MCP_DIST}/${MCP_VER}/x86_64/current"
REPOMD_URL="${BASE_URL}/repodata/repomd.xml"

log()  { printf '[verify-repo] %s\n' "$*" >&2; }
die()  { printf '[verify-repo] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "${CACHE_DIR}"

command -v gpg1       >/dev/null || die "gpg1 not installed (run bootstrap-gpg.sh)"
command -v sha1sum    >/dev/null || die "sha1sum missing"
command -v xmllint    >/dev/null || die "xmllint missing"
[[ -d "${KEYRING_DIR}" ]]        || die "keyring missing (run bootstrap-gpg.sh)"

# ---- 1. fetch repomd.xml + repomd.xml.asc ---------------------------------
repomd="${CACHE_DIR}/repomd.xml"
repomd_asc="${CACHE_DIR}/repomd.xml.asc"

log "fetching repomd.xml"
curl --fail --silent --show-error --location -o "${repomd}.new"     "${REPOMD_URL}"     || die "repomd.xml download failed"
curl --fail --silent --show-error --location -o "${repomd_asc}.new" "${REPOMD_URL}.asc" || die "repomd.xml.asc download failed"

# ---- 2. verify signature --------------------------------------------------
log "verifying signature"
if ! gpg1 --homedir "${KEYRING_DIR}" --verify \
        "${repomd_asc}.new" "${repomd}.new" 2>&1 | grep -q "Good signature"; then
    rm -f "${repomd}.new" "${repomd_asc}.new"
    die "repomd.xml GPG signature invalid — refusing to trust repo"
fi

mv "${repomd}.new"     "${repomd}"
mv "${repomd_asc}.new" "${repomd_asc}"
log "repomd.xml OK"

# ---- 3. if our cached sha1-map matches this repomd, done ------------------
map_file="${CACHE_DIR}/sha1-map.txt"
repomd_sha1="$(sha1sum "${repomd}" | awk '{print $1}')"
stamp_file="${CACHE_DIR}/.stamp.${repomd_sha1}"

if [[ -s "${map_file}" && -f "${stamp_file}" ]]; then
    log "cached sha1-map current (${repomd_sha1:0:12}...)"
    cat "${map_file}"
    exit 0
fi

# ---- 4. resolve primary.xml.gz location + sha1 ----------------------------
# repomd.xml is small; parse with xmllint.  We want the <data type="primary">
# entry's <location href> and <checksum type="sha">.
primary_href="$(xmllint --xpath 'string(//*[local-name()="data"][@type="primary"]/*[local-name()="location"]/@href)' "${repomd}")"
primary_sha1="$(xmllint --xpath 'string(//*[local-name()="data"][@type="primary"]/*[local-name()="checksum"][@type="sha"])' "${repomd}")"
[[ -n "${primary_href}" && -n "${primary_sha1}" ]] \
    || die "could not extract primary.xml entry from repomd.xml"

primary_gz="${CACHE_DIR}/$(basename "${primary_href}")"
log "fetching ${primary_href}"
curl --fail --silent --show-error --location -o "${primary_gz}" \
    "${BASE_URL}/${primary_href}" \
    || die "primary.xml.gz download failed"

actual_sha1="$(sha1sum "${primary_gz}" | awk '{print $1}')"
[[ "${actual_sha1}" == "${primary_sha1}" ]] \
    || die "primary.xml.gz sha1 mismatch: got ${actual_sha1}, expected ${primary_sha1}"
log "primary.xml.gz OK (${actual_sha1:0:12}...)"

# ---- 5. build the filename → sha1 map ------------------------------------
primary_xml="${primary_gz%.gz}"
zcat "${primary_gz}" > "${primary_xml}"

# Each <package> element has:
#   <checksum type="sha" pkgid="YES">SHA1</checksum>
#   <location href="name-ver-rel.arch.rpm"/>
# unRAID ships no python, and a full XML parser would be overkill for what
# is in practice a line-oriented document.  Awk tracks the current package
# and emits (location, sha) when both have been seen inside it.
awk '
    /<package / { loc=""; sha=""; inpkg=1 }
    inpkg && /<checksum type="sha" pkgid="YES">/ {
        if (match($0, />[a-f0-9]+</)) sha = substr($0, RSTART+1, RLENGTH-2)
    }
    inpkg && /<location href=/ {
        if (match($0, /href="[^"]+"/)) loc = substr($0, RSTART+6, RLENGTH-7)
    }
    /<\/package>/ && inpkg {
        if (loc && sha) print loc, sha
        inpkg=0
    }
' "${primary_xml}" > "${map_file}.new" \
    || die "awk parse of primary.xml failed"

mv "${map_file}.new" "${map_file}"
: > "${stamp_file}"

log "sha1-map built: $(wc -l < "${map_file}") entries"
cat "${map_file}"
