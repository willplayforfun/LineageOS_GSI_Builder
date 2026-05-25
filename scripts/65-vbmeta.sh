#!/usr/bin/env bash
# Purpose: Generate a disabled vbmeta.img using avbtool from the synced AOSP
# source tree. The image has both AVB flags set (disable-verity +
# disable-verification) so the bootloader skips chain-of-trust checks when
# flashed alongside a third-party GSI.

set -euo pipefail
IFS=$'\n\t'

AVBTOOL="/srv/src/external/avb/avbtool.py"
OUT_DIR="/srv/out"

echo "==> [65] Generating disabled vbmeta.img"

if [[ ! -f "${AVBTOOL}" ]]; then
    echo "ERROR: avbtool not found at ${AVBTOOL}" >&2
    echo "       The source tree must be synced (step 00) before this step." >&2
    echo "       Run a full build first, or re-run without --vbmeta-only." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# flags=3 sets bit 0 (HASHTREE_DISABLED) and bit 1 (VERIFICATION_DISABLED),
# telling the bootloader to skip all AVB chain-of-trust checks.
# padding_size=4096 pads to a 4 KB boundary, which every vbmeta partition
# accommodates; avbtool will error if the partition is smaller.
python3 "${AVBTOOL}" make_vbmeta_image \
    --flags 3 \
    --padding_size 4096 \
    --output "${OUT_DIR}/vbmeta.img"

VBMETA_SIZE="$(du -sh "${OUT_DIR}/vbmeta.img" | cut -f1)"
VBMETA_SHA256="$(sha256sum "${OUT_DIR}/vbmeta.img" | awk '{print $1}')"
echo "  -> Written : ${OUT_DIR}/vbmeta.img  (${VBMETA_SIZE})"
echo "  -> SHA256  : ${VBMETA_SHA256}"
echo ""
echo "  Flash before the system image:"
echo "    fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img"

echo "==> [65] Done."
