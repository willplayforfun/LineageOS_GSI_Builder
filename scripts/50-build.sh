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
# AOSP's envsetup.sh assumes a relaxed shell: it references variables like TOP
# and ZSH_VERSION without guards (fatal under `set -u`), and it relies on
# default IFS to word-split space-joined variable lists into separate args for
# `unset` (with our `IFS=$'\n\t'`, the whole blob becomes one token and bash
# rejects it as "not a valid identifier"). Relax both for the source + lunch
# block, then restore the script's safety net.
echo "  -> Sourcing build/envsetup.sh ..."
_saved_ifs="$IFS"
set +u
IFS=$' \t\n'
# shellcheck disable=SC1091
source build/envsetup.sh

# ─── Invalidate Soong's module-path cache ───────────────────────────────────
# Lineage-20 (Android 13) doesn't run `find` for AndroidProducts.mk at lunch
# time — it reads a pre-generated list from out/.module_paths/, populated by
# Soong's finder on previous builds. If vendor/microg wasn't present (or was
# a symlinked directory the finder skipped) during that earlier scan, the
# cache won't include our wrapper and lunch will fail to locate the product.
# Nuking the cache forces a fresh scan on the next make invocation.
if [[ -d out/.module_paths ]]; then
    echo "  -> Clearing Soong module-path cache to force re-scan ..."
    rm -rf out/.module_paths
fi

# ─── Lunch the microG wrapper product ───────────────────────────────────────
# The wrapper inherits device/lineage/gsi/lineage_gsi_arm64_vN.mk (provided by
# AndyCGYan/android_device_lineage_gsi via the unified manifest) and layers
# vendor/microg/microg.mk on top. See scripts/20-stage-vendor-microg.sh.
echo "  -> Lunching ${LUNCH_TARGET} ..."
lunch "${LUNCH_TARGET}"

# ─── Build ──────────────────────────────────────────────────────────────────
# `target-files-package` produces the unsigned target-files zip (consumed by
# steps 55 and 60); `otatools` populates out/host/linux-x86/bin/ with
# sign_target_files_apks (used by step 60). `make` is incremental, so re-runs
# only rebuild what changed.
#
# Note: `make` here is the bash function defined by envsetup.sh, not /usr/bin/make.
# It internally word-splits `$(get_make_command)` into `build/soong/soong_ui.bash
# --make-mode`, so it needs default IFS too — keep the relaxed shell through this
# call. Restored at the end for hygiene; nothing in this script runs after.
echo "  -> make -j${NPROC} target-files-package otatools ..."
make -j"${NPROC}" target-files-package otatools

IFS="$_saved_ifs"
set -u  # restore nounset + IFS now that envsetup + lunch + make are done

echo "==> [50] Done."
