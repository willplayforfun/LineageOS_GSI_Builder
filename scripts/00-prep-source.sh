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

# ─── Pin drift check ─────────────────────────────────────────────────────────
# For each pinned project (see config/local_manifests/zz-pins.xml), query the
# upstream tracking branch HEAD and compare against the pinned SHA. The pins
# remain in effect until manually bumped; this is purely an awareness signal.
#
# The SHAs below MUST match the ones in zz-pins.xml — bump in both places when
# advancing a pin.
check_pin_drift() {
    local project_subpath="$1"
    local pinned_sha="$2"
    local upstream_url="$3"
    local tracking_branch="$4"
    local note="$5"

    local remote_head
    remote_head=$(git ls-remote "${upstream_url}" "refs/heads/${tracking_branch}" 2>/dev/null | cut -f1)
    if [[ -z "${remote_head}" ]]; then
        echo "     ${project_subpath}: couldn't query upstream — network issue?"
        return 0
    fi
    if [[ "${pinned_sha}" == "${remote_head}" ]]; then
        echo "     ${project_subpath}: pinned at ${pinned_sha:0:7} (== upstream)"
    else
        local behind
        behind=$(curl -fsSL "https://api.github.com/repos/$(echo "${upstream_url}" \
            | sed 's|https://github.com/||')/compare/${pinned_sha}...${remote_head}" \
            2>/dev/null | grep -m1 '"ahead_by"' | grep -oE '[0-9]+' || true)
        echo "     ${project_subpath}: pinned ${pinned_sha:0:7}, upstream ${remote_head:0:7}${behind:+ (${behind} commits ahead)}"
        echo "          ${note}"
    fi
}

if [[ "${SKIP_SYNC}" == "1" ]]; then
    echo "  -> SKIP_SYNC=1: skipping pin drift check."
else
    echo "  -> Checking pin drift vs upstream ..."
    check_pin_drift \
        "lineage_patches_unified" \
        "1865fc784bc72a2d82fb938f18edb66af90ba306" \
        "https://github.com/AndyCGYan/lineage_patches_unified" \
        "lineage-20-light" \
        "archival pin — branch effectively dead since Nov 2023, drift is informational only"

    check_pin_drift \
        "lineage_build_unified" \
        "ba21a0d381b988cef51387896a603cc2871045b8" \
        "https://github.com/AndyCGYan/lineage_build_unified" \
        "lineage-20-light" \
        "archival pin — branch effectively dead since Nov 2023, drift is informational only"

    check_pin_drift \
        "vendor/hardware_overlay" \
        "1bbceba47362299ae60cb96c08303fb5f930e853" \
        "https://github.com/TrebleDroid/vendor_hardware_overlay" \
        "pie" \
        "frozen pin — newer commits add device overlays only; advance only if you need them"
fi

touch /srv/intermediate/.stage-00-done
echo "==> [00] Done."
