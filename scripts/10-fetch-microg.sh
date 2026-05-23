#!/usr/bin/env bash
# Purpose: Download microG and FLOSS APKs into the intermediate staging area.

set -euo pipefail
IFS=$'\n\t'

SENTINEL="/srv/intermediate/.stage-10-done"
APK_LIST="/opt/pipeline/config/microg-apks.txt"
PREBUILTS_DIR="/srv/intermediate/vendor-microg/prebuilts"
STRICT="${STRICT:-0}"

# ─── CLI flags ────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "${arg}" in
        --strict) STRICT=1 ;;
        *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
    esac
done

echo "==> [10] Fetching microG / FLOSS APKs"

if [[ -f "${SENTINEL}" ]]; then
    echo "  -> Sentinel found — APKs already fetched. Skipping."
    echo "==> [10] Done (cached)."
    exit 0
fi

mkdir -p "${PREBUILTS_DIR}"

# ─── Parse and download ───────────────────────────────────────────────────────
while IFS= read -r line; do
    # Skip blank lines and comment lines
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

    IFS=$' \t' read -r filename url sha256 <<< "${line}"

    dest="${PREBUILTS_DIR}/${filename}"

    # ── SHA256 check for already-present files ────────────────────────────────
    if [[ -f "${dest}" ]]; then
        if [[ "${sha256}" == "SKIP" ]]; then
            echo "  -> ${filename}: already present (sha256 verification skipped)."
            continue
        fi
        actual=$(sha256sum "${dest}" | awk '{print $1}')
        if [[ "${actual}" == "${sha256}" ]]; then
            echo "  -> ${filename}: already present and sha256 matches."
            continue
        else
            echo "  -> ${filename}: sha256 mismatch — re-downloading."
        fi
    fi

    # ── STRICT mode: fail if sha256 is SKIP ───────────────────────────────────
    if [[ "${STRICT}" == "1" && "${sha256}" == "SKIP" ]]; then
        echo "ERROR: --strict mode enabled but sha256 for ${filename} is SKIP." >&2
        echo "       Pin a sha256 in config/microg-apks.txt for reproducible builds." >&2
        exit 1
    fi

    echo "  -> Downloading ${filename} from ${url} ..."
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "${dest}.tmp" "${url}"; then
        echo "ERROR: Failed to download ${filename} from ${url}." >&2
        echo "       Check config/microg-apks.txt for misconfiguration." >&2
        rm -f "${dest}.tmp"
        exit 1
    fi

    # ── Verify sha256 of freshly-downloaded file ──────────────────────────────
    if [[ "${sha256}" != "SKIP" ]]; then
        actual=$(sha256sum "${dest}.tmp" | awk '{print $1}')
        if [[ "${actual}" != "${sha256}" ]]; then
            echo "ERROR: sha256 mismatch for ${filename}." >&2
            echo "       Expected: ${sha256}" >&2
            echo "       Got:      ${actual}" >&2
            rm -f "${dest}.tmp"
            exit 1
        fi
        echo "     sha256 OK."
    else
        echo "     sha256 verification skipped (SKIP). Use --strict to enforce."
    fi

    mv "${dest}.tmp" "${dest}"
    echo "     Saved to ${dest}."

done < "${APK_LIST}"

touch "${SENTINEL}"
echo "==> [10] Done."
