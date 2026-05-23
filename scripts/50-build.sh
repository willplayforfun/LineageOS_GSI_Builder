#!/usr/bin/env bash
# Purpose: Apply lineage_patches_unified patches, lunch the microG wrapper
# product, and build the unsigned target-files-package + otatools. Signing
# happens in step 60; APEX key discovery happens in step 55.

set -euo pipefail
IFS=$'\n\t'

SRC_DIR="/srv/src"
PATCHES_SCRIPT="${SRC_DIR}/lineage_build_unified/apply_patches.sh"
PATCHES_DIR="${SRC_DIR}/lineage_patches_unified"
LUNCH_TARGET="lineage_gsi_arm64_vN_microg-userdebug"
NPROC="${NPROC:-$(nproc)}"

echo "==> [50] Building target-files-package + otatools"

cd "${SRC_DIR}"

# ─── Sanity checks ──────────────────────────────────────────────────────────
for path in \
    "${SRC_DIR}/build/envsetup.sh" \
    "${PATCHES_SCRIPT}" \
    "${PATCHES_DIR}/patches_platform" \
    "${PATCHES_DIR}/patches_treble"
do
    if [[ ! -e "${path}" ]]; then
        echo "ERROR: required path missing: ${path}" >&2
        echo "       Did step 00 (repo sync) complete?" >&2
        exit 1
    fi
done

# ─── Apply patches ──────────────────────────────────────────────────────────
# apply_patches.sh from lineage_build_unified runs `git clean -fdx && git reset
# --hard` on each project before re-applying its patch set, so it's safe to
# re-run on every build. This is the same flow buildbot_unified.sh uses; we
# lift the two patch groups (platform + treble) and skip its repo-sync block
# since step 00 already handled sync.
echo "  -> Applying patches_platform ..."
bash "${PATCHES_SCRIPT}" "${PATCHES_DIR}/patches_platform"

echo "  -> Applying patches_treble ..."
bash "${PATCHES_SCRIPT}" "${PATCHES_DIR}/patches_treble"

# ─── Source envsetup ────────────────────────────────────────────────────────
# Sourced after patches in case any patch modifies envsetup itself.
#
# AOSP's envsetup.sh references variables like TOP and ZSH_VERSION without
# guards, on the assumption it's sourced in a relaxed shell. Our `set -u`
# (nounset) treats those as fatal errors, so disable nounset for the duration
# of the source — and lunch, which also reads back into envsetup's helpers.
# Restore it afterwards so the rest of the script keeps its safety net.
echo "  -> Sourcing build/envsetup.sh ..."
set +u
# shellcheck disable=SC1091
source build/envsetup.sh

# ─── Pre-lunch diagnostic ───────────────────────────────────────────────────
# If lunch later fails with "Can not locate config makefile for product",
# the usual cause is that our vendor/microg AndroidProducts.mk isn't visible
# to the build system's product-discovery glob. Print the relevant
# filesystem state so we can see what's actually on disk and what find
# resolves through the symlink. Safe to remove once the build is stable.
echo "  -> Diagnostic: vendor/microg directory entry ..."
ls -la vendor/microg 2>&1 | sed 's/^/       /'
echo "  -> Diagnostic: AndroidProducts.mk files visible to product discovery ..."
find -L vendor -maxdepth 6 -name AndroidProducts.mk 2>&1 | sed 's/^/       /'
if [[ -f vendor/microg/AndroidProducts.mk ]]; then
    echo "  -> Diagnostic: vendor/microg/AndroidProducts.mk content ..."
    sed 's/^/       /' vendor/microg/AndroidProducts.mk
else
    echo "  -> Diagnostic: vendor/microg/AndroidProducts.mk NOT REACHABLE"
fi
if [[ -f vendor/microg/lineage_gsi_arm64_vN_microg.mk ]]; then
    echo "  -> Diagnostic: lineage_gsi_arm64_vN_microg.mk content ..."
    sed 's/^/       /' vendor/microg/lineage_gsi_arm64_vN_microg.mk
else
    echo "  -> Diagnostic: lineage_gsi_arm64_vN_microg.mk NOT REACHABLE"
fi

# ─── Lunch the microG wrapper product ───────────────────────────────────────
# The wrapper inherits device/lineage/gsi/lineage_gsi_arm64_vN.mk (provided by
# AndyCGYan/android_device_lineage_gsi via the unified manifest) and layers
# vendor/microg/microg.mk on top. See scripts/20-stage-vendor-microg.sh.
echo "  -> Lunching ${LUNCH_TARGET} ..."
lunch "${LUNCH_TARGET}"
set -u  # restore nounset now that envsetup + lunch are done

# ─── Build ──────────────────────────────────────────────────────────────────
# `target-files-package` produces the unsigned target-files zip (consumed by
# steps 55 and 60); `otatools` populates out/host/linux-x86/bin/ with
# sign_target_files_apks (used by step 60). `make` is incremental, so re-runs
# only rebuild what changed.
echo "  -> make -j${NPROC} target-files-package otatools ..."
make -j"${NPROC}" target-files-package otatools

echo "==> [50] Done."
