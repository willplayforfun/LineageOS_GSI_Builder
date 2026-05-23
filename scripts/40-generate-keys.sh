#!/usr/bin/env bash
# Purpose: Generate the LineageOS 20 release-signing key set into /srv/keys.

set -euo pipefail
IFS=$'\n\t'

KEYS_DIR="/srv/keys"
SRC_DIR="/srv/src"
SUBJECT_FILE="/opt/pipeline/config/cert-subject.txt"
MAKE_KEY="${SRC_DIR}/development/tools/make_key"

# Canonical LineageOS 20 cert set (per the wiki). Note: this v1 deliberately
# omits the SHA256_RSA4096 APEX-specific keys required by some LineageOS 19.1+
# configurations — if a build fails on missing APEX keys, follow the README
# "Known issues" entry to copy make_key, sed 2048→4096, and regenerate.
CERTS=(
    bluetooth
    cyngn-app
    media
    networkstack
    nfc
    platform
    releasekey
    sdk_sandbox
    shared
    testcert
    testkey
    verity
)

echo "==> [40] Generating LineageOS release-signing keys"

mkdir -p "${KEYS_DIR}"

# Idempotency: presence of releasekey.pk8 means "we've been here". Reuse the
# existing set rather than regenerating — fresh keys would break OTA updates
# for any existing installations of a previous build.
if [[ -f "${KEYS_DIR}/releasekey.pk8" ]]; then
    echo "  -> Reusing existing keys from ${KEYS_DIR} (releasekey.pk8 present)."
    echo "==> [40] Done (cached)."
    exit 0
fi

if [[ ! -f "${SUBJECT_FILE}" ]]; then
    echo "ERROR: cert subject file not found: ${SUBJECT_FILE}" >&2
    exit 1
fi
SUBJECT="$(< "${SUBJECT_FILE}")"
SUBJECT="${SUBJECT%$'\n'}"

if [[ ! -x "${MAKE_KEY}" ]]; then
    echo "ERROR: make_key not found or not executable at ${MAKE_KEY}" >&2
    echo "       This script must run after step 00 has synced the source tree." >&2
    exit 1
fi

echo "  -> Subject: ${SUBJECT}"
echo "  -> Generating ${#CERTS[@]} certs into ${KEYS_DIR}/ ..."

# make_key writes ${name}.pk8 + ${name}.x509.pem; it prompts once for a key
# passphrase. The LineageOS build tooling expects unprotected keys (a non-empty
# passphrase makes `sign_target_files_apks` hang), so we feed make_key EOF on
# stdin — the `read -p` returns empty, which triggers its -nocrypt branch.
# make_key also refuses to overwrite, so we skip any cert that already exists
# (e.g. partial run from a previous failed invocation).
#
# AOSP quirk: make_key sets `trap '... exit 1' EXIT INT QUIT`, so it ALWAYS
# exits 1 even after a fully successful run. We swallow that exit code and
# verify success by checking that the expected output files appeared — which
# is the real success criterion anyway.
cd "${SRC_DIR}"
for cert in "${CERTS[@]}"; do
    if [[ -f "${KEYS_DIR}/${cert}.pk8" ]]; then
        echo "     ${cert}: already present — skipping."
        continue
    fi
    echo "     ${cert} ..."
    "${MAKE_KEY}" "${KEYS_DIR}/${cert}" "${SUBJECT}" </dev/null || true
    if [[ ! -f "${KEYS_DIR}/${cert}.pk8" || ! -f "${KEYS_DIR}/${cert}.x509.pem" ]]; then
        echo "ERROR: make_key did not produce ${cert}.{pk8,x509.pem}" >&2
        exit 1
    fi
done

echo "==> [40] Done."
