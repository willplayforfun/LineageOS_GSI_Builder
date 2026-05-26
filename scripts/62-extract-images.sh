#!/usr/bin/env bash
# Purpose: Extract system.img and vbmeta.img from the signed target-files zip
# and publish public certs into /srv/out.

set -euo pipefail
IFS=$'\n\t'

SRC_DIR="/srv/src"
KEYS_DIR="/srv/keys"
APEX_KEYS_DIR="${KEYS_DIR}/apex"
SIGNED_TF="/srv/intermediate/signed-target-files.zip"
OUT_DIR="/srv/out"
OUT_CERTS_DIR="${OUT_DIR}/certs"
OUT_APEX_CERTS_DIR="${OUT_CERTS_DIR}/apex"
HOST_BIN="${SRC_DIR}/out/host/linux-x86/bin"

echo "==> [62] Extracting images and publishing certs"

if [[ ! -f "${SIGNED_TF}" ]]; then
    echo "ERROR: signed target-files zip not found at ${SIGNED_TF}" >&2
    echo "       Step 60 must produce it before step 62 runs." >&2
    exit 1
fi

# ─── Extract images ──────────────────────────────────────────────────────────
# img2simg takes a file path and seeks within it; unzip -p can't feed it
# directly, so we unzip system.img to a temp file, convert, then delete it.
mkdir -p "${OUT_DIR}"
echo "  -> Extracting IMAGES/system.img → ${OUT_DIR}/system.img (sparse) ..."
IMG2SIMG="${HOST_BIN}/img2simg"
if [[ ! -x "${IMG2SIMG}" ]]; then
    echo "ERROR: ${IMG2SIMG} not found." >&2
    exit 1
fi
TMPIMG=$(mktemp)
trap 'rm -f "${TMPIMG}"' EXIT
unzip -p "${SIGNED_TF}" IMAGES/system.img > "${TMPIMG}"
"${IMG2SIMG}" "${TMPIMG}" "${OUT_DIR}/system.img"
trap - EXIT
rm -f "${TMPIMG}"

# vbmeta.img is produced by sign_target_files_apks: it contains the AVB digest
# of the signed system partition. It is flashed with `--disable-verity --disable-verification`,
# which set the HASHTREE_DISABLED + VERIFICATION_DISABLED bits to disable AVB 
# without discarding the correct structure.
echo "  -> Extracting IMAGES/vbmeta.img → ${OUT_DIR}/vbmeta.img ..."
unzip -p "${SIGNED_TF}" IMAGES/vbmeta.img > "${OUT_DIR}/vbmeta.img"

# ─── Publish public certs ────────────────────────────────────────────────────
# Public .x509.pem only — private .pk8 files stay in /srv/keys/ exclusively so
# the published certs directory is safe to share alongside system.img.
mkdir -p "${OUT_CERTS_DIR}"
shopt -s nullglob
release_certs=("${KEYS_DIR}"/*.x509.pem)
shopt -u nullglob
if [[ ${#release_certs[@]} -gt 0 ]]; then
    echo "  -> Copying release cert public keys to ${OUT_CERTS_DIR}/ ..."
    cp "${release_certs[@]}" "${OUT_CERTS_DIR}/"
fi

shopt -s nullglob
apex_certs=("${APEX_KEYS_DIR}"/*.x509.pem)
shopt -u nullglob
if [[ ${#apex_certs[@]} -gt 0 ]]; then
    mkdir -p "${OUT_APEX_CERTS_DIR}"
    echo "  -> Copying ${#apex_certs[@]} APEX cert public key(s) to ${OUT_APEX_CERTS_DIR}/ ..."
    cp "${apex_certs[@]}" "${OUT_APEX_CERTS_DIR}/"
fi

echo "==> [62] Done."
