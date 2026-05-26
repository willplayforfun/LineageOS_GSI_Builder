#!/usr/bin/env bash
# Purpose: Print final build summary — image path, size, sha256, cert location, and key reminder.

set -euo pipefail
IFS=$'\n\t'

OUT_DIR="/srv/out"
IMG="${OUT_DIR}/system.img"
VBMETA="${OUT_DIR}/vbmeta.img"
BOOT_PATCHED="${OUT_DIR}/boot-patched.img"
VENDOR_BOOT_PATCHED="${OUT_DIR}/vendor_boot-patched.img"
CERTS_DIR="${OUT_DIR}/certs"
START_FILE="/srv/intermediate/.build-start-time"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BUILD REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Timing ──────────────────────────────────────────────────────────────────
END_EPOCH="$(date +%s)"
if [[ -f "${START_FILE}" ]]; then
    START_EPOCH="$(cat "${START_FILE}")"
    ELAPSED=$(( END_EPOCH - START_EPOCH ))
    HOURS=$(( ELAPSED / 3600 ))
    MINUTES=$(( (ELAPSED % 3600) / 60 ))
    SECONDS=$(( ELAPSED % 60 ))
    printf "  Duration   : %dh %02dm %02ds\n" "${HOURS}" "${MINUTES}" "${SECONDS}"
else
    echo "  Duration   : (start time not recorded)"
fi

echo ""

# ─── system.img ──────────────────────────────────────────────────────────────
if [[ -f "${IMG}" ]]; then
    IMG_SIZE="$(du -sh "${IMG}" | cut -f1)"
    IMG_SHA256="$(sha256sum "${IMG}" | awk '{print $1}')"
    echo "  system image path : ${IMG}"
    echo "  system image size : ${IMG_SIZE}"
    echo "  SHA256     : ${IMG_SHA256}"
else
    echo "  system image : NOT FOUND at ${IMG}"
fi

echo ""

# ─── vbmeta.img ──────────────────────────────────────────────────────────────
if [[ -f "${VBMETA}" ]]; then
    VBMETA_SIZE="$(du -sh "${VBMETA}" | cut -f1)"
    VBMETA_SHA256="$(sha256sum "${VBMETA}" | awk '{print $1}')"
    echo "  vbmeta path: ${VBMETA}"
    echo "  vbmeta size: ${VBMETA_SIZE}"
    echo "  SHA256     : ${VBMETA_SHA256}"
else
    echo "  vbmeta : NOT FOUND at ${VBMETA}"
fi

echo ""

# ─── Patched boot.img (optional, only if user supplied one) ──────────────────
if [[ -f "${BOOT_PATCHED}" ]]; then
    BOOT_SIZE="$(du -sh "${BOOT_PATCHED}" | cut -f1)"
    BOOT_SHA256="$(sha256sum "${BOOT_PATCHED}" | awk '{print $1}')"
    echo "  boot path  : ${BOOT_PATCHED}"
    echo "  boot size  : ${BOOT_SIZE}"
    echo "  SHA256     : ${BOOT_SHA256}"
else
    echo "  boot-patched.img : not present"
    echo "                     (drop a stock boot.img into ./boot_img/ to enable)"
fi

# ─── Patched vendor_boot.img (optional, only if user supplied one) ──────────────────
if [[ -f "${VENDOR_BOOT_PATCHED}" ]]; then
    VENDOR_BOOT_SIZE="$(du -sh "${VENDOR_BOOT_PATCHED}" | cut -f1)"
    VENDOR_BOOT_SHA256="$(sha256sum "${VENDOR_BOOT_PATCHED}" | awk '{print $1}')"
    echo "  vendor boot path  : ${VENDOR_BOOT_PATCHED}"
    echo "  vendor boot size  : ${VENDOR_BOOT_SIZE}"
    echo "  SHA256     : ${VENDOR_BOOT_SHA256}"
else
    echo "  vendor_boot-patched.img : not present"
    echo "                     (drop a stock vendor_boot.img into ./boot_img/ to enable)"
fi


echo ""

# ─── Certs ───────────────────────────────────────────────────────────────────
if [[ -d "${CERTS_DIR}" ]]; then
    echo "  Certs dir  : ${CERTS_DIR}/"
    while IFS= read -r -d '' cert; do
        echo "               - $(basename "${cert}")"
    done < <(find "${CERTS_DIR}" -name '*.x509.pem' -print0 | sort -z)
else
    echo "  Certs dir  : (not yet generated — appears after a full signed build)"
fi

echo ""
echo "  REMINDER: Back up ./keys/ if you plan to ship OTA updates to existing installs."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
