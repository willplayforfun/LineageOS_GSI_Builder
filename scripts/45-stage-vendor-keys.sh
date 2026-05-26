#!/usr/bin/env bash
# Purpose: Stage vendor/lineage-priv/keys/ — write Android.mk + keys.mk, symlink
# the .pk8/.x509.pem files from /srv/keys/, then symlink the staging dir into
# the source tree. Private key material stays exclusively under /srv/keys/.

set -euo pipefail
IFS=$'\n\t'

KEYS_DIR="/srv/keys"
STAGE_DIR="/srv/intermediate/lineage-priv"
SRC_LINK_PARENT="/srv/src/vendor/lineage-priv"
SRC_LINK="${SRC_LINK_PARENT}/keys"

echo "==> [45] Staging vendor/lineage-priv/keys"

# No sentinel: CLEAN=1 may have wiped /srv/intermediate/ even when /srv/keys/
# still has valid keys, so we always re-stage. All work below is cheap and
# idempotent.

mkdir -p "${STAGE_DIR}"

# ─── Android.mk ──────────────────────────────────────────────────────────────
# Declares LOCAL_PATH so this directory participates in any all-subdir-makefiles walk.
# Written only if absent so a user-customised file is preserved across re-runs.
if [[ ! -f "${STAGE_DIR}/Android.mk" ]]; then
    echo "  -> Writing Android.mk ..."
    cat > "${STAGE_DIR}/Android.mk" <<'ANDROID_MK'
LOCAL_PATH := $(call my-dir)
ANDROID_MK
else
    echo "  -> Android.mk already present — leaving as-is."
fi

# ─── keys.mk ─────────────────────────────────────────────────────────────────
# Tells the product build to sign with our releasekey, and (since LineageOS 16
# QPR2) routes the mainline bluetooth sepolicy dev cert to the same dir — both
# are required for a Lineage 20 / Android 13 signed build.
# Written only if absent so a user-customised file is preserved across re-runs.
if [[ ! -f "${STAGE_DIR}/keys.mk" ]]; then
    echo "  -> Writing keys.mk ..."
    cat > "${STAGE_DIR}/keys.mk" <<'KEYS_MK'
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey
PRODUCT_MAINLINE_BLUETOOTH_SEPOLICY_DEV_CERTIFICATES := $(dir $(PRODUCT_DEFAULT_DEV_CERTIFICATE))
KEYS_MK
else
    echo "  -> keys.mk already present — leaving as-is."
fi

# ─── Symlink each key file into the staging dir ──────────────────────────────
# Symlink (not copy) so private key material lives only in /srv/keys/. 
# ln -sf overwrites any stale link/file at the destination, keeping the link target in sync.
echo "  -> Symlinking *.pk8 / *.x509.pem from ${KEYS_DIR}/ ..."
shopt -s nullglob
keyfiles=("${KEYS_DIR}"/*.pk8 "${KEYS_DIR}"/*.x509.pem)
shopt -u nullglob

if [[ ${#keyfiles[@]} -eq 0 ]]; then
    echo "ERROR: no *.pk8 or *.x509.pem in ${KEYS_DIR}." >&2
    exit 1
fi

for src in "${keyfiles[@]}"; do
    ln -sf "${src}" "${STAGE_DIR}/$(basename "${src}")"
done

# ─── Symlink staging dir into the source tree ────────────────────────────────
# /srv/src/vendor/lineage-priv/keys → /srv/intermediate/lineage-priv. Build system 
# then sees vendor/lineage-priv/keys/{Android.mk,keys.mk,releasekey.*} transparently.
echo "  -> Symlinking ${STAGE_DIR} → ${SRC_LINK} ..."
mkdir -p "${SRC_LINK_PARENT}"
ln -sfn "${STAGE_DIR}" "${SRC_LINK}"

echo "==> [45] Done."
