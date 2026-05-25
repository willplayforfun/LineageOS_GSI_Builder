#!/usr/bin/env bash
# Purpose: Sign the unsigned target-files zip with our releasekey (incl. all
# APEX modules discovered by step 55), extract system.img, and publish the
# public certs into /srv/out.

set -euo pipefail
IFS=$'\n\t'

SRC_DIR="/srv/src"
KEYS_DIR="/srv/keys"
APEX_KEYS_DIR="${KEYS_DIR}/apex"
OUT_DIR="/srv/out"
OUT_CERTS_DIR="${OUT_DIR}/certs"
OUT_APEX_CERTS_DIR="${OUT_CERTS_DIR}/apex"
SIGNED_TF="/srv/intermediate/signed-target-files.zip"
APEX_MODULES_LIST="/srv/intermediate/apex-modules.txt"
HOST_BIN="${SRC_DIR}/out/host/linux-x86/bin"

# APKs that ship inside APEX containers but are regular APKs (not APEXes
# themselves). Per the LineageOS wiki signing recipe, these are signed with
# our standard releasekey — they do not need 4096-bit per-APEX keys.
APEX_APKS=(
    AdServicesApk
    FederatedCompute
    HalfSheetUX
    HealthConnectBackupRestore
    HealthConnectController
    OsuLogin
    SafetyCenterResources
    ServiceConnectivityResources
    ServiceUwbResources
    ServiceWifiResources
    WifiDialog
)

echo "==> [60] Signing target files and extracting system.img"

# ─── Locate the unsigned target-files zip ───────────────────────────────────
shopt -s nullglob
TF_ZIPS=("${SRC_DIR}"/out/target/product/*/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip)
shopt -u nullglob

if [[ ${#TF_ZIPS[@]} -eq 0 ]]; then
    echo "ERROR: no unsigned target-files zip under ${SRC_DIR}/out/." >&2
    echo "       Step 50 must produce one before step 60 runs." >&2
    exit 1
fi
# Newest wins if more than one is present (incremental builds may leave the
# previous run's zip alongside the current one).
TF_ZIP=""
for zip in "${TF_ZIPS[@]}"; do
    if [[ -z "${TF_ZIP}" || "${zip}" -nt "${TF_ZIP}" ]]; then
        TF_ZIP="${zip}"
    fi
done
echo "  -> Source target files: ${TF_ZIP}"

# ─── Locate sign_target_files_apks ──────────────────────────────────────────
SIGN_TOOL="${HOST_BIN}/sign_target_files_apks"
if [[ ! -x "${SIGN_TOOL}" ]]; then
    echo "ERROR: ${SIGN_TOOL} not found." >&2
    echo "       Step 50 must include 'otatools' in its make target." >&2
    exit 1
fi
# sign_target_files_apks shells out to aapt2 / zipalign / etc. which it
# expects to find via PATH. Prepend the otatools host-bin dir so those resolve.
export PATH="${HOST_BIN}:${PATH}"

# ─── Build sign_target_files_apks flag list ─────────────────────────────────
FLAGS=()

# APEX containers + payload keys (one pair per module discovered by step 55).
if [[ -s "${APEX_MODULES_LIST}" ]]; then
    APEX_COUNT=0
    while IFS= read -r module; do
        [[ -z "${module}" ]] && continue
        FLAGS+=(--extra_apks "${module}.apex=${APEX_KEYS_DIR}/${module}")
        FLAGS+=(--extra_apex_payload_key "${module}.apex=${APEX_KEYS_DIR}/${module}.pem")
        APEX_COUNT=$((APEX_COUNT + 1))
    done < "${APEX_MODULES_LIST}"
    echo "  -> APEX flags built for ${APEX_COUNT} module(s)."
else
    echo "  -> No APEX modules (apex-modules.txt absent or empty)."
fi

# APKs that ship inside APEX containers — sign with our releasekey.
for apk in "${APEX_APKS[@]}"; do
    FLAGS+=(--extra_apks "${apk}.apk=${KEYS_DIR}/releasekey")
done
echo "  -> APEX-APK flags built for ${#APEX_APKS[@]} APK(s)."

# ─── Sign ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${SIGNED_TF}")"
echo "  -> Signing target files → ${SIGNED_TF} ..."
# --allow_gsi_debug_sepolicy: the upstream GSI product makefile
# (device/lineage/gsi/lineage_gsi_arm64_vN.mk) sets SELINUX_IGNORE_NEVERALLOWS
# and PRODUCT_INSTALL_DEBUG_POLICY_TO_SYSTEM_EXT unconditionally — both are
# required for a GSI that must run on arbitrary vendor implementations and are
# incompatible with the -user build variant. The GSI is therefore built as
# -userdebug, which produces userdebug_plat_sepolicy.cil. This flag tells the
# signing tool to accept that file rather than hard-erroring on it.
"${SIGN_TOOL}" \
    --allow_gsi_debug_sepolicy \
    -o -d "${KEYS_DIR}" \
    "${FLAGS[@]}" \
    "${TF_ZIP}" "${SIGNED_TF}"

# ─── Extract images ──────────────────────────────────────────────────────────
# Pipe straight from the signed zip to the output volume so we don't
# materialise intermediate copies.
mkdir -p "${OUT_DIR}"
echo "  -> Extracting IMAGES/system.img → ${OUT_DIR}/system.img ..."
unzip -p "${SIGNED_TF}" IMAGES/system.img > "${OUT_DIR}/system.img"

# vbmeta.img is produced by sign_target_files_apks: it contains the AVB digest
# of the signed system partition and is the correct image to flash alongside
# system.img. Flash it with:
#   fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
# The fastboot flags set the HASHTREE_DISABLED + VERIFICATION_DISABLED bits in
# the image at flash time, disabling AVB without discarding the correct structure.
echo "  -> Extracting IMAGES/vbmeta.img → ${OUT_DIR}/vbmeta.img ..."
unzip -p "${SIGNED_TF}" IMAGES/vbmeta.img > "${OUT_DIR}/vbmeta.img"

# ─── Publish public certs ───────────────────────────────────────────────────
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

echo "==> [60] Done."
