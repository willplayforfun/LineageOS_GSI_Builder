#!/usr/bin/env bash
# Purpose: Discover APEX modules in the unsigned target-files zip produced by
# step 50 and generate 4096-bit SHA256_RSA keys for any not already present in
# /srv/keys/apex/. Also writes the module list to /srv/intermediate/ so step 60
# can build sign_target_files_apks flags from the same enumeration.

set -euo pipefail
IFS=$'\n\t'

KEYS_DIR="/srv/keys"
APEX_KEYS_DIR="${KEYS_DIR}/apex"
SRC_DIR="/srv/src"
SUBJECT_FILE="/opt/pipeline/config/cert-subject.txt"
MAKE_KEY_4096="/srv/intermediate/make_key_4096"
STOCK_MAKE_KEY="${SRC_DIR}/development/tools/make_key"
APEX_MODULES_LIST="/srv/intermediate/apex-modules.txt"

echo "==> [55] Generating APEX signing keys"

# ─── Locate the unsigned target-files zip from step 50 ───────────────────────
shopt -s nullglob
TF_ZIPS=("${SRC_DIR}"/out/target/product/*/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip)
shopt -u nullglob

if [[ ${#TF_ZIPS[@]} -eq 0 ]]; then
    echo "ERROR: no unsigned target-files zip found under ${SRC_DIR}/out/." >&2
    echo "       Step 50 must produce target-files-package before step 55 runs." >&2
    exit 1
fi
# Pick the most recently modified one.
TF_ZIP=""
for zip in "${TF_ZIPS[@]}"; do
    if [[ -z "${TF_ZIP}" || "${zip}" -nt "${TF_ZIP}" ]]; then
        TF_ZIP="${zip}"
    fi
done
echo "  -> Inspecting ${TF_ZIP}"

# ─── Parse module names from META/apexkeys.txt ───────────────────────────────
# Each line declares one APEX, e.g.:
#   name="com.android.runtime.apex" public_key="..." private_key="..." ...
# We strip the .apex suffix to get the module-name stem used as the key prefix.
APEXKEYS_TXT="$(mktemp)"
trap 'rm -f "${APEXKEYS_TXT}"' EXIT INT QUIT

if ! unzip -p "${TF_ZIP}" META/apexkeys.txt > "${APEXKEYS_TXT}" 2>/dev/null; then
    echo "  -> No META/apexkeys.txt in target files — build has no APEX modules."
    : > "${APEX_MODULES_LIST}"
    echo "==> [55] Done (no APEX keys needed)."
    exit 0
fi

mapfile -t APEX_MODULES < <(
    grep -oE 'name="[^"]+\.apex"' "${APEXKEYS_TXT}" \
        | sed -E 's/name="(.+)\.apex"/\1/' \
        | sort -u
)

if [[ ${#APEX_MODULES[@]} -eq 0 ]]; then
    echo "  -> META/apexkeys.txt is empty — no APEX modules to sign."
    : > "${APEX_MODULES_LIST}"
    echo "==> [55] Done (no APEX keys needed)."
    exit 0
fi
echo "  -> ${#APEX_MODULES[@]} APEX module(s) declared by the build."

# Persist the list so step 60 builds its sign_target_files_apks flag set from
# exactly the same enumeration (and doesn't have to re-parse the zip).
printf '%s\n' "${APEX_MODULES[@]}" > "${APEX_MODULES_LIST}"

# ─── Subject template ────────────────────────────────────────────────────────
if [[ ! -f "${SUBJECT_FILE}" ]]; then
    echo "ERROR: cert subject file not found: ${SUBJECT_FILE}" >&2
    exit 1
fi
SUBJECT_TEMPLATE="$(< "${SUBJECT_FILE}")"
SUBJECT_TEMPLATE="${SUBJECT_TEMPLATE%$'\n'}"

# ─── Lazily stage a 4096-bit make_key ────────────────────────────────────────
# Per the LineageOS wiki, APEX keys must be SHA256_RSA4096 rather than the
# stock 2048-bit. Copy + sed once; stored under /srv/intermediate (regenerable
# tooling, not key material).
if [[ ! -x "${MAKE_KEY_4096}" ]]; then
    if [[ ! -x "${STOCK_MAKE_KEY}" ]]; then
        echo "ERROR: stock make_key not found at ${STOCK_MAKE_KEY}" >&2
        exit 1
    fi
    echo "  -> Staging 4096-bit make_key at ${MAKE_KEY_4096} ..."
    mkdir -p "$(dirname "${MAKE_KEY_4096}")"
    cp "${STOCK_MAKE_KEY}" "${MAKE_KEY_4096}"
    sed -i 's|2048|4096|g' "${MAKE_KEY_4096}"
    chmod +x "${MAKE_KEY_4096}"
fi

# ─── Generate APEX keys ──────────────────────────────────────────────────────
mkdir -p "${APEX_KEYS_DIR}"
cd "${SRC_DIR}"

GENERATED=0
SKIPPED=0
for module in "${APEX_MODULES[@]}"; do
    pk8="${APEX_KEYS_DIR}/${module}.pk8"
    pem_cert="${APEX_KEYS_DIR}/${module}.x509.pem"
    pem_priv="${APEX_KEYS_DIR}/${module}.pem"

    if [[ -f "${pk8}" && -f "${pem_cert}" && -f "${pem_priv}" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Per-APEX subject: substitute the CN= field with the module name, matching
    # the LineageOS wiki recipe. Replaces everything between /CN= and the next
    # slash.
    apex_subject=$(echo "${SUBJECT_TEMPLATE}" | sed -E "s|/CN=[^/]*|/CN=${module}|")

    echo "     ${module} ..."
    # make_key refuses to overwrite, so clear any half-written leftovers.
    rm -f "${pk8}" "${pem_cert}"
    # AOSP make_key always exits 1 via its EXIT trap even on success; swallow
    # the bogus exit and verify success by checking that the output files
    # appeared. Same pattern as step 40.
    "${MAKE_KEY_4096}" "${APEX_KEYS_DIR}/${module}" "${apex_subject}" </dev/null || true
    if [[ ! -f "${pk8}" || ! -f "${pem_cert}" ]]; then
        echo "ERROR: make_key did not produce ${module}.{pk8,x509.pem}" >&2
        exit 1
    fi

    # Unwrap the private key to a .pem — sign_target_files_apks expects the
    # APEX payload key in this form (PKCS#8 PEM, no encryption).
    openssl pkcs8 -in "${pk8}" -inform DER -nocrypt -out "${pem_priv}"

    GENERATED=$((GENERATED + 1))
done

echo "  -> Generated ${GENERATED} key(s); reused ${SKIPPED} from previous runs."
echo "==> [55] Done."
