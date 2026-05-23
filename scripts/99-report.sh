#!/usr/bin/env bash
# Purpose: Print final build summary — image path, size, sha256, cert location, and key reminder.

set -euo pipefail
IFS=$'\n\t'

OUT_DIR="/srv/out"
IMG="${OUT_DIR}/system.img"
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
    echo "  Image path : ${IMG}"
    echo "  Image size : ${IMG_SIZE}"
    echo "  SHA256     : ${IMG_SHA256}"
else
    echo "  Image path : NOT FOUND at ${IMG}"
    echo "               (Expected when running only stage 00 for sync testing.)"
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

# ─── Treble compatibility ─────────────────────────────────────────────────────
echo "  Treble info:"
echo "    Architecture  : arm64"
echo "    Partition     : A/B, system-as-root"
echo "    VNDK          : 33"
echo "    Build variant : ${VARIANT:-64VN}"

echo ""
echo "  REMINDER: Back up ./keys/ if you plan to ship OTA updates to existing"
echo "            installs. Private keys in ./keys/ must NEVER be committed to git."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
