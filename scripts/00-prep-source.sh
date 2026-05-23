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

# ─── Bootstrap upstream treble manifest ──────────────────────────────────────
# After the first sync, lineage_build_unified is on disk and ships its own
# local_manifests_treble/manifest.xml declaring the treble-specific projects
# (device/lineage/gsi, vendor/hardware_overlay, packages/apps/QcRilAm,
# vendor/gapps). Mirror that file into .repo/local_manifests/ so a follow-up
# sync pulls everything. Tracks upstream automatically — no manifest copy to
# maintain in our repo.
#
# Skipped under SKIP_SYNC=1 since we'd have nothing fresh to sync against
# anyway; the mirror gets refreshed on the next non-SKIP run.
UPSTREAM_TREBLE_MANIFEST="${SRC_DIR}/lineage_build_unified/local_manifests_treble/manifest.xml"
MIRRORED_TREBLE_MANIFEST="${MANIFESTS_DST}/upstream-treble.xml"

if [[ "${SKIP_SYNC}" == "1" ]]; then
    echo "  -> SKIP_SYNC=1: skipping upstream treble manifest bootstrap."
elif [[ ! -f "${UPSTREAM_TREBLE_MANIFEST}" ]]; then
    echo "  WARNING: ${UPSTREAM_TREBLE_MANIFEST} not found." >&2
    echo "           First sync should have pulled lineage_build_unified — investigate before step 50." >&2
elif diff -q "${UPSTREAM_TREBLE_MANIFEST}" "${MIRRORED_TREBLE_MANIFEST}" > /dev/null 2>&1; then
    echo "  -> Upstream treble manifest already mirrored — no resync needed."
else
    echo "  -> Mirroring upstream treble manifest from lineage_build_unified ..."
    cp "${UPSTREAM_TREBLE_MANIFEST}" "${MIRRORED_TREBLE_MANIFEST}"
    echo "  -> Re-syncing to pull treble-specific projects ..."
    repo sync \
        -j"${NPROC}" \
        --force-sync \
        --no-tags \
        --no-clone-bundle \
        --optimized-fetch \
        --retry-fetches=3
    echo "  -> Second sync complete."
fi

touch /srv/intermediate/.stage-00-done
echo "==> [00] Done."
