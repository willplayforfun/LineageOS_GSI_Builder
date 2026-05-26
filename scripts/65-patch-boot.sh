#!/usr/bin/env bash
# Purpose: Optionally produce a patched boot.img and/or vendor_boot.img for
# devices where dm-verity enforcement lives in one or both images.
#
# On Android 12+ devices the device-specific fstab (which carries the verify/
# avb mount options that engage dm-verity) lives in the vendor ramdisk inside
# vendor_boot, not in boot's ramdisk. Both images should be patched.
#
# Implementation: run magiskboot on each supplied stock image. The "cpio patch"
# command strips verify/avb/forceencrypt from fstab entries in the ramdisk, and
# "repack" sets HASHTREE_DISABLED | VERIFICATION_DISABLED in the vbmeta footer.
# magiskboot auto-detects the image type (BOOT vs VENDOR_BOOT) so the same
# command sequence works for both.
#
# Each image is skipped silently if the corresponding file is absent from
# /srv/boot_img/.

set -euo pipefail
IFS=$'\n\t'

BOOT_IN="/srv/boot_img/boot.img"
VENDOR_BOOT_IN="/srv/boot_img/vendor_boot.img"
OUT_DIR="/srv/out"
BOOT_OUT="${OUT_DIR}/boot-patched.img"
VENDOR_BOOT_OUT="${OUT_DIR}/vendor_boot-patched.img"
WORK_DIR="/srv/intermediate/boot-patch"
VENDOR_WORK_DIR="/srv/intermediate/vendor-boot-patch"
MAGISKBOOT="$(command -v magiskboot || true)"
SRC_DIR="/srv/src"
AVBTOOL="${SRC_DIR}/external/avb/avbtool"

echo "==> [65] Patching stock boot images with magiskboot"

# ─── Optional step: bail cleanly if neither image was supplied ───────────────
if [[ ! -f "${BOOT_IN}" && ! -f "${VENDOR_BOOT_IN}" ]]; then
    echo "  -> No boot images present in /srv/boot_img/ — skipping."
    echo "     (Drop stock boot.img and/or vendor_boot.img into ./boot_img/ on"
    echo "      the host to enable this step. See README for details.)"
    exit 0
fi

if [[ -z "${MAGISKBOOT}" ]]; then
    echo "ERROR: magiskboot not found on PATH." >&2
    echo "       The Docker image should install it; rebuild the image with:" >&2
    echo "         docker build --no-cache -t lineage20-gsi-microg:latest -f docker/Dockerfile ." >&2
    exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
# PART 1 — boot.img
# ════════════════════════════════════════════════════════════════════════════
if [[ ! -f "${BOOT_IN}" ]]; then
    echo "  -> No /srv/boot_img/boot.img present — skipping boot patch."
else

# ─── Fresh working directory ─────────────────────────────────────────────────
# magiskboot dumps kernel/ramdisk.cpio/dtb alongside the input; isolate them
# in a per-run scratch dir so successive runs start clean and don't trip over
# leftover files (split_init_boot, kernel_dtb, etc.).
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${OUT_DIR}"
cp "${BOOT_IN}" "${WORK_DIR}/boot.img"

# ─── 'before' info (best-effort; avbtool is part of the synced AOSP tree) ────
if [[ -x "${AVBTOOL}" ]]; then
    echo ""
    echo "  -> avbtool info_image (before patching):"
    "${AVBTOOL}" info_image --image "${WORK_DIR}/boot.img" 2>&1 | sed 's/^/       /' || true
    echo ""
fi

# ─── Unpack ──────────────────────────────────────────────────────────────────
echo "  -> magiskboot unpack ..."
( cd "${WORK_DIR}" && "${MAGISKBOOT}" unpack boot.img )

if [[ ! -f "${WORK_DIR}/ramdisk.cpio" ]]; then
    echo "ERROR: magiskboot did not produce a ramdisk.cpio." >&2
    echo "       This boot image may be ramdisk-less or use an unusual layout." >&2
    exit 1
fi

# ─── Patch ramdisk (fstab edits + remove forceencrypt + etc.) ────────────────
# The 'patch' cpio subcommand is magiskboot's built-in fstab/init patcher.
# It strips: verify, verifyatboot, avb, avb_keys, support_scfs, forceencrypt,
# forcefdeorfbe, fileencryption — every mount-option that would re-engage
# dm-verity or block a wiped /data from initialising on first boot.
echo ""
echo "  -> magiskboot cpio ramdisk.cpio patch ..."
( cd "${WORK_DIR}" && "${MAGISKBOOT}" cpio ramdisk.cpio "patch" )

# ─── Repack ──────────────────────────────────────────────────────────────────
# 'repack' rebuilds the boot image, recomputes section sizes, and sets the
# vbmeta footer flags to HASHTREE_DISABLED | VERIFICATION_DISABLED (0x3).
# The vbmeta signature won't re-verify, but on an unlocked bootloader the
# kernel still honors the disabled flags.
echo ""
echo "  -> magiskboot repack boot.img ..."
( cd "${WORK_DIR}" && "${MAGISKBOOT}" repack boot.img new-boot.img )

if [[ ! -f "${WORK_DIR}/new-boot.img" ]]; then
    echo "ERROR: magiskboot repack did not produce new-boot.img." >&2
    exit 1
fi

cp "${WORK_DIR}/new-boot.img" "${BOOT_OUT}"

# ─── 'after' info ────────────────────────────────────────────────────────────
if [[ -x "${AVBTOOL}" ]]; then
    echo ""
    echo "  -> avbtool info_image (after patching):"
    "${AVBTOOL}" info_image --image "${BOOT_OUT}" 2>&1 | sed 's/^/       /' || true
fi

echo ""
echo "  -> Patched boot image written to: ${BOOT_OUT}"
echo "     Flash with:  fastboot flash boot_a boot-patched.img"
echo "     (Bootloader must be unlocked. The vbmeta signature is intentionally"
echo "      invalidated by the flag-bit changes; the kernel honors the disabled"
echo "      flags regardless.)"

fi  # end boot.img block

# ════════════════════════════════════════════════════════════════════════════
# PART 2 — vendor_boot.img
# On Android 12+ the device-specific fstab (carrying verify/avb mount options)
# lives in the vendor ramdisk here, not in boot. Patching this image strips
# those options so fs_mgr won't try to set up dm-verity for the GSI system.
# magiskboot auto-detects the VENDOR_BOOT image type.
# ════════════════════════════════════════════════════════════════════════════
if [[ ! -f "${VENDOR_BOOT_IN}" ]]; then
    echo "  -> No /srv/boot_img/vendor_boot.img present — skipping vendor_boot patch."
else

echo ""
echo "==> [65] Patching stock vendor_boot.img with magiskboot"

if [[ -x "${AVBTOOL}" ]]; then
    echo ""
    echo "  -> avbtool info_image (before patching):"
    "${AVBTOOL}" info_image --image "${VENDOR_BOOT_IN}" 2>&1 | sed 's/^/       /' || true
    echo ""
fi

rm -rf "${VENDOR_WORK_DIR}"
mkdir -p "${VENDOR_WORK_DIR}" "${OUT_DIR}"
cp "${VENDOR_BOOT_IN}" "${VENDOR_WORK_DIR}/vendor_boot.img"

echo "  -> magiskboot unpack ..."
( cd "${VENDOR_WORK_DIR}" && "${MAGISKBOOT}" unpack vendor_boot.img ) || true
echo "  -> unpack exit code: $?"
echo "  -> work dir contents after unpack:"
find "${VENDOR_WORK_DIR}" -not -name 'vendor_boot.img' | sort | sed 's/^/       /'

# v3 extracts ramdisk.cpio at the top level; v4 extracts into vendor_ramdisk/
# (possibly with multiple cpio files inside). Search the whole work tree.
mapfile -t VENDOR_RAMDISKS < <(
    find "${VENDOR_WORK_DIR}" -name 'ramdisk.cpio*' | sort
)

if [[ ${#VENDOR_RAMDISKS[@]} -eq 0 ]]; then
    echo "ERROR: magiskboot did not produce a ramdisk.cpio from vendor_boot.img." >&2
    echo "       Files found in work dir listed above." >&2
    exit 1
fi

for ramdisk in "${VENDOR_RAMDISKS[@]}"; do
    relpath="${ramdisk#${VENDOR_WORK_DIR}/}"
    echo ""
    echo "  -> magiskboot cpio ${relpath} patch ..."
    ( cd "${VENDOR_WORK_DIR}" && "${MAGISKBOOT}" cpio "${relpath}" "patch" )
done

echo ""
echo "  -> magiskboot repack vendor_boot.img ..."
( cd "${VENDOR_WORK_DIR}" && "${MAGISKBOOT}" repack vendor_boot.img new-vendor_boot.img )

if [[ ! -f "${VENDOR_WORK_DIR}/new-vendor_boot.img" ]]; then
    echo "ERROR: magiskboot repack did not produce new-vendor_boot.img." >&2
    exit 1
fi

cp "${VENDOR_WORK_DIR}/new-vendor_boot.img" "${VENDOR_BOOT_OUT}"

if [[ -x "${AVBTOOL}" ]]; then
    echo ""
    echo "  -> avbtool info_image (after patching):"
    "${AVBTOOL}" info_image --image "${VENDOR_BOOT_OUT}" 2>&1 | sed 's/^/       /' || true
fi

echo ""
echo "  -> Patched vendor_boot image written to: ${VENDOR_BOOT_OUT}"
echo "     Flash with:  fastboot flash vendor_boot_a vendor_boot-patched.img"

fi  # end vendor_boot.img block

echo ""
echo "==> [65] Done."
