#!/usr/bin/env bash
# Purpose: Optionally patch a stock OEM boot.img to disable AVB hashtree
# verification and AVB verification, producing out/boot-patched.img.
#
# Context: Some devices (notably MediaTek-based ones like the Unihertz Jelly
# Star) have NO standalone vbmeta partition — the dm-verity root hash for the
# system partition is chain-loaded from the boot image's vbmeta footer. On
# those devices, flashing a GSI without also disabling verity causes
# "Can't load Android system. Your data may be corrupt." at boot.
#
# This step takes the user's dumped stock boot.img (from /srv/boot_img/boot.img),
# locates its AVB vbmeta footer, and sets the HASHTREE_DISABLED (bit 0) and
# VERIFICATION_DISABLED (bit 1) flags in the vbmeta header. The signature
# becomes invalid as a side effect, but on an UNLOCKED bootloader that is
# downgraded to a warning, and the kernel still honors the disabled flags
# — exactly what `fastboot --disable-verity --disable-verification flash`
# does internally.
#
# Skipped silently if /srv/boot_img/boot.img does not exist.

set -euo pipefail
IFS=$'\n\t'

BOOT_IN="/srv/boot_img/boot.img"
OUT_DIR="/srv/out"
BOOT_OUT="${OUT_DIR}/boot-patched.img"
SRC_DIR="/srv/src"
AVBTOOL="${SRC_DIR}/external/avb/avbtool"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAG_PATCHER="${SCRIPT_DIR}/65-patch-boot-flags.py"

echo "==> [65] Patching stock boot.img to disable AVB verity"

# ─── Optional step: bail cleanly if user hasn't supplied a boot.img ─────────
if [[ ! -f "${BOOT_IN}" ]]; then
    echo "  -> No /srv/boot_img/boot.img present — skipping."
    echo "     (Drop a stock boot.img into ./boot_img/ on the host to enable"
    echo "      this step. See README for instructions.)"
    exit 0
fi

mkdir -p "${OUT_DIR}"

# ─── Locate avbtool (optional, used for info display only) ──────────────────
# The flag-patch itself is done in Python below and doesn't need avbtool —
# but if avbtool is available, we use it to print a before/after summary.
HAS_AVBTOOL=0
if [[ -x "${AVBTOOL}" ]]; then
    HAS_AVBTOOL=1
elif command -v avbtool >/dev/null 2>&1; then
    AVBTOOL="$(command -v avbtool)"
    HAS_AVBTOOL=1
fi

# ─── Copy input to output (we never mutate the source) ──────────────────────
echo "  -> Copying ${BOOT_IN} -> ${BOOT_OUT}"
cp "${BOOT_IN}" "${BOOT_OUT}"

# ─── Show 'before' state if avbtool is available ────────────────────────────
if [[ "${HAS_AVBTOOL}" -eq 1 ]]; then
    echo ""
    echo "  -> avbtool info_image (before patching):"
    "${AVBTOOL}" info_image --image "${BOOT_OUT}" 2>&1 | sed 's/^/       /' || {
        echo "       (avbtool reports no AVB footer — see note below)"
    }
    echo ""
fi

# ─── Patch the vbmeta flags ──────────────────────────────────────────────────
# Byte-level vbmeta-flag editing — see 65-patch-boot-flags.py for the AVB
# footer / VBMeta header layout and the rationale for not using avbtool here.
if [[ ! -f "${FLAG_PATCHER}" ]]; then
    echo "ERROR: flag-patcher script not found at ${FLAG_PATCHER}" >&2
    exit 1
fi
python3 "${FLAG_PATCHER}" "${BOOT_OUT}"

# ─── Show 'after' state if avbtool is available ─────────────────────────────
if [[ "${HAS_AVBTOOL}" -eq 1 ]]; then
    echo ""
    echo "  -> avbtool info_image (after patching):"
    # info_image will warn that the signature no longer verifies — this is
    # expected and intentional. The flags line should now show
    # HASHTREE_DISABLED and VERIFICATION_DISABLED.
    "${AVBTOOL}" info_image --image "${BOOT_OUT}" 2>&1 | sed 's/^/       /' || true
fi

echo ""
echo "  -> Patched boot image written to: ${BOOT_OUT}"
echo "     Flash with:  fastboot flash boot_a boot-patched.img"
echo "     (Bootloader must be unlocked; signature no longer verifies but the"
echo "      disabled-flags are honored by the kernel regardless.)"
echo "==> [65] Done."
