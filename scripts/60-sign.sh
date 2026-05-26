#!/usr/bin/env bash
# Purpose: Sign the unsigned target-files zip with our releasekey

set -euo pipefail
IFS=$'\n\t'

SRC_DIR="/srv/src"
KEYS_DIR="/srv/keys"
APEX_KEYS_DIR="${KEYS_DIR}/apex"
SIGNED_TF="/srv/intermediate/signed-target-files.zip"
APEX_MODULES_LIST="/srv/intermediate/apex-modules.txt"
HOST_BIN="${SRC_DIR}/out/host/linux-x86/bin"

# APKs that ship inside APEX containers but are regular APKs (not APEXes
# themselves). sign_target_files_apks re-signs APKs via the target-files cert
# mappings, but APKs embedded inside APEX containers are unreachable through
# that path and must be listed explicitly with --extra_apks. These still use
# our standard releasekey, not the 4096-bit per-APEX keys.
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

echo "==> [60] Signing target files"

if [[ "${SKIP_SIGNING:-0}" == "1" ]]; then
    echo "  -> SKIP_SIGNING=1: skipping."
    exit 0
fi

# ─── Locate the unsigned target-files zip ───────────────────────────────────
shopt -s nullglob
TF_ZIPS=("${SRC_DIR}"/out/target/product/*/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip)
shopt -u nullglob

if [[ ${#TF_ZIPS[@]} -eq 0 ]]; then
    echo "ERROR: no unsigned target-files zip under ${SRC_DIR}/out/." >&2
    echo "       A build must complete successfully before signing can occur." >&2
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
    exit 1
fi
# sign_target_files_apks shells out to aapt2 / zipalign / etc. which it
# expects to find via PATH. Prepend the otatools host-bin dir so those resolve.
export PATH="${HOST_BIN}:${PATH}"

# ─── Build sign_target_files_apks flag list ─────────────────────────────────
FLAGS=()

# APEX containers + payload keys (one pair per module).
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
# --allow_gsi_debug_sepolicy:
# the upstream GSI product makefile sets SELINUX_IGNORE_NEVERALLOWS
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

echo "==> [60] Done."
