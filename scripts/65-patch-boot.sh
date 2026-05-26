#!/usr/bin/env bash
# Purpose: Optionally produce a patched boot.img for devices where dm-verity
# for the system partition is chain-loaded from the boot image (no standalone
# vbmeta partition — e.g. MediaTek-based phones like the Unihertz Jelly Star).
#
# Implementation: run magiskboot — the same binary the Magisk app uses
# internally — on a user-supplied stock boot.img. The "cpio patch" command
# strips verify/avb/forceencrypt from fstab in the ramdisk, and "repack" sets
# HASHTREE_DISABLED | VERIFICATION_DISABLED in the vbmeta footer flags. The
# resulting image is equivalent to what Magisk's "Select and Patch a File"
# would produce, but generated headlessly inside the container.
#
# Skipped silently if /srv/boot_img/boot.img does not exist.

set -euo pipefail
IFS=$'\n\t'

BOOT_IN="/srv/boot_img/boot.img"
OUT_DIR="/srv/out"
BOOT_OUT="${OUT_DIR}/boot-patched.img"
WORK_DIR="/srv/intermediate/boot-patch"
MAGISKBOOT="$(command -v magiskboot || true)"
SRC_DIR="/srv/src"
AVBTOOL="${SRC_DIR}/external/avb/avbtool"

echo "==> [65] Patching stock boot.img with magiskboot"

# ─── Optional step: bail cleanly if no boot.img supplied ────────────────────
if [[ ! -f "${BOOT_IN}" ]]; then
    echo "  -> No /srv/boot_img/boot.img present — skipping."
    echo "     (Drop a stock boot.img into ./boot_img/ on the host to enable"
    echo "      this step. See README for details.)"
    exit 0
fi

if [[ -z "${MAGISKBOOT}" ]]; then
    echo "ERROR: magiskboot not found on PATH." >&2
    echo "       The Docker image should install it; rebuild the image with:" >&2
    echo "         docker build --no-cache -t lineage20-gsi-microg:latest -f docker/Dockerfile ." >&2
    exit 1
fi

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
echo "==> [65] Done."
