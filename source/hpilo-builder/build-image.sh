#!/bin/bash
# build-image.sh -- builds the Debian image that compiles hpilo.ko against
# the current unRAID kernel.  Derived from the user's original build_hpilo.sh.
#
# Inputs (env):
#   UNRAID_SRC   override for kernel sources dir (default: auto-detect)
#   OUTPUT_DIR   where to drop hpilo.ko (default: <this-dir>/output)
#   DOCKER_TAG   image tag (default: hpilo-builder:<kernel>)
#
# Exit 0 on success; hpilo.ko lives at ${OUTPUT_DIR}/hpilo.ko.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNRAID_SRC="${UNRAID_SRC:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${HERE}/output}"

if [[ -z "${UNRAID_SRC}" ]]; then
    UNRAID_SRC="$(ls -d /usr/src/linux-*-Unraid 2>/dev/null | head -1 || true)"
fi
[[ -n "${UNRAID_SRC}" && -d "${UNRAID_SRC}" ]] \
    || { echo "ERROR: no /usr/src/linux-*-Unraid found (set UNRAID_SRC)"; exit 1; }

KERNEL_FULL="$(basename "${UNRAID_SRC}")"    # linux-6.12.54-Unraid
KERNEL_VERSION="${KERNEL_FULL#linux-}"        # 6.12.54-Unraid
KERNEL_VERSION="${KERNEL_VERSION%-Unraid}"    # 6.12.54
DOCKER_TAG="${DOCKER_TAG:-hpilo-builder:${KERNEL_VERSION}}"

echo "[build-image] kernel: ${KERNEL_VERSION}"
echo "[build-image] sources: ${UNRAID_SRC}"
echo "[build-image] output:  ${OUTPUT_DIR}"
echo "[build-image] tag:     ${DOCKER_TAG}"

command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
docker info >/dev/null 2>&1  || { echo "ERROR: docker daemon not running"; exit 1; }

# Stage kernel sources into build context (Docker can't COPY from outside context).
rm -rf "${HERE}/unraid-src"
cp -r "${UNRAID_SRC}" "${HERE}/unraid-src"

docker build \
    --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
    -t "${DOCKER_TAG}" \
    "${HERE}"

mkdir -p "${OUTPUT_DIR}"
docker run --rm \
    -v "${OUTPUT_DIR}:/out" \
    "${DOCKER_TAG}" \
    cp /output/hpilo.ko /out/

rm -rf "${HERE}/unraid-src"

echo "[build-image] produced: ${OUTPUT_DIR}/hpilo.ko"
modinfo "${OUTPUT_DIR}/hpilo.ko" | grep -E '^(vermagic|filename):' || true
