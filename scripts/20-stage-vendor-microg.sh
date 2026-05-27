#!/usr/bin/env bash
# Purpose: Generate vendor/microg build files DIRECTLY in the source tree as
# real files (Soong's module finder skips symlinked directories, so a
# "symlink vendor/microg → intermediate" approach makes AndroidProducts.mk
# invisible to product discovery). Only prebuilts/ remains a symlink, because
# its contents are looked up by make's file resolver — not Soong's finder —
# and that does follow symlinks.

set -euo pipefail
IFS=$'\n\t'

INTERMEDIATE_DIR="/srv/intermediate/vendor-microg"
VENDOR_DIR="/srv/src/vendor/microg"
APKS_TOOL=(python3 /opt/pipeline/scripts/apks-tool.py)

echo "==> [20] Staging vendor/microg"

# All work below is cheap and idempotent (clobbering writes + ln -sfn), so we
# rerun it every invocation rather than gating on a sentinel — keeps the
# staged content in lockstep with what this script currently emits.

mkdir -p "${INTERMEDIATE_DIR}/prebuilts"
mkdir -p "${VENDOR_DIR}" "${VENDOR_DIR}/permissions"

# ─── prebuilts symlink ───────────────────────────────────────────────────────
# vendor/microg/prebuilts/<file>.apk is referenced by Android.mk's
# BUILD_PREBUILT LOCAL_SRC_FILES — a path lookup that follows symlinks
# transparently. Linking the directory (rather than copying) keeps step 10's
# downloads under /srv/intermediate. 
# ln -sfn replaces any existing link without failing.
ln -sfn "${INTERMEDIATE_DIR}/prebuilts" "${VENDOR_DIR}/prebuilts"

# ─── Generate Android.mk + microg.mk (from config/microg-apks.yaml) ─────────
# Both files are derived from the same YAML source; apks-tool emits the full
# contents to stdout, so step 20 just redirects into place. Adding/removing
# an APK is a YAML-only edit.
echo "  -> Generating Android.mk from microg-apks.yaml ..."
"${APKS_TOOL[@]}" generate-android-mk > "${VENDOR_DIR}/Android.mk"

echo "  -> Generating microg.mk from microg-apks.yaml ..."
"${APKS_TOOL[@]}" generate-microg-mk > "${VENDOR_DIR}/microg.mk"

# ─── Generate AndroidProducts.mk ──────────────────────────────────────────────────────
# Discovered by Soong's module finder under any vendor/*. Declaring the
# wrapper product here is what makes our custom lunch target 
# resolvable without modifying any repo-managed file. 
# Per AOSP convention this file must only reference $(LOCAL_DIR) 
# (which the build system pre-sets to the containing directory) and must not use conditionals.
echo "  -> Writing AndroidProducts.mk ..."
cat > "${VENDOR_DIR}/AndroidProducts.mk" <<'ANDROID_PRODUCTS_MK'
PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lineage_gsi_target.mk

COMMON_LUNCH_CHOICES := \
    lineage_gsi_target-userdebug \
    lineage_gsi_target-user \
    lineage_gsi_target-eng
ANDROID_PRODUCTS_MK

# ─── lineage_gsi_target.mk (wrapper product) ───────────────────────
# Inherits AndyCGYan's lineage GSI product makefile for our specific variant
# and layers vendor/microg/microg.mk on top.
echo "  -> Writing lineage_gsi_target.mk ..."
cat > "${VENDOR_DIR}/lineage_gsi_target.mk" <<'WRAPPER_MK'
$(call inherit-product, device/phh/treble/lineage_arm64_bvN.mk)
$(call inherit-product, vendor/microg/microg.mk)

PRODUCT_NAME := lineage_gsi_target
WRAPPER_MK

# ─── privapp-permissions XML ──────────────────────────────────────────────────
echo "  -> Writing permissions/privapp-permissions-com.google.android.gms.xml ..."
cat > "${VENDOR_DIR}/permissions/privapp-permissions-com.google.android.gms.xml" <<'PERMS_XML'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <!-- Allows microG GmsCore to spoof Google Play signatures for apps that
         perform signature verification against com.android.vending or
         com.google.android.gms. Granted only because GmsCore is signed with
         the build's platform key (see Android.mk). -->
    <privapp-permissions package="com.google.android.gms">
        <permission name="android.permission.FAKE_PACKAGE_SIGNATURE"/>
    </privapp-permissions>
</permissions>
PERMS_XML

echo "==> [20] Done."
