#!/usr/bin/env bash
# Purpose: Initialise and sync the LineageOS repo source tree, then install local manifests.

set -euo pipefail
IFS=$'\n\t'

echo "==> [00] Preparing LineageOS source tree"

SRC_DIR="/srv/src"
MANIFESTS_SRC="/opt/pipeline/config/local_manifests"
MANIFESTS_DST="${SRC_DIR}/.repo/local_manifests"

LINEAGE_URL="https://github.com/LineageOS/android.git"
LINEAGE_BRANCH="lineage-20.0"
# Fallback: if the branch HEAD is broken, replace LINEAGE_BRANCH above with a
# known-good full commit SHA from https://github.com/LineageOS/android/commits/lineage-20.0

NPROC="${NPROC:-$(nproc)}"
SKIP_SYNC="${SKIP_SYNC:-0}"

# All repo commands must run from inside the source tree directory.
cd "${SRC_DIR}"

# ─── repo init ───────────────────────────────────────────────────────────────
if [[ ! -d "${SRC_DIR}/.repo" ]]; then
    echo "  -> Initialising repo (branch: ${LINEAGE_BRANCH}) ..."
    repo init \
        -u "${LINEAGE_URL}" \
        -b "${LINEAGE_BRANCH}" \
        --git-lfs \
        --no-repo-verify
    echo "  -> repo init complete."
else
    echo "  -> .repo already present — skipping init."
fi

# ─── Local manifests ─────────────────────────────────────────────────────────
echo "  -> Installing local manifests ..."
mkdir -p "${MANIFESTS_DST}"

shopt -s nullglob
xmls=("${MANIFESTS_SRC}"/*.xml)
shopt -u nullglob

if [[ ${#xmls[@]} -eq 0 ]]; then
    echo "  WARNING: no *.xml files found in ${MANIFESTS_SRC}" >&2
else
    for xml in "${xmls[@]}"; do
        dest="${MANIFESTS_DST}/$(basename "${xml}")"
        if [[ -f "${dest}" ]] && diff -q "${xml}" "${dest}" > /dev/null 2>&1; then
            echo "     Up-to-date: $(basename "${xml}")"
        else
            cp "${xml}" "${dest}"
            echo "     Installed:  $(basename "${xml}")"
        fi
    done
fi

# ─── repo sync ───────────────────────────────────────────────────────────────
if [[ "${SKIP_SYNC}" == "1" ]]; then
    echo "  -> SKIP_SYNC=1: skipping repo sync."
else
    echo "  -> Syncing source tree with ${NPROC} jobs ..."
    echo "     First run: expect several hours and ~250 GB of disk usage."
    repo sync \
        -j"${NPROC}" \
        --force-sync \
        --no-tags \
        --no-clone-bundle \
        --optimized-fetch \
        --retry-fetches=3
    echo "  -> repo sync complete."
fi

touch /srv/intermediate/.stage-00-done
echo "==> [00] Done."
