#!/usr/bin/env bash
# Purpose: Generate vendor/microg build files (incl. an AndroidProducts.mk
# wrapper product `lineage_gsi_arm64_vN_microg`) in the intermediate area and
# symlink into the source tree.

set -euo pipefail
IFS=$'\n\t'

VENDOR_DIR="/srv/intermediate/vendor-microg"
SRC_LINK="/srv/src/vendor/microg"
# Array, not a string — we run with `IFS=$'\n\t'` (no space), so word-splitting
# on a string variable would not produce separate argv elements.
APKS_TOOL=(python3 /opt/pipeline/scripts/apks-tool.py)

echo "==> [20] Staging vendor/microg"

# All work below is cheap and idempotent (clobbering writes + ln -sfn), so we
# rerun it every invocation rather than gating on a sentinel — that keeps the
# staged content in lockstep with whatever this script currently emits, even
# if it has changed since a previous run.

# Ensure the prebuilts dir exists but never clobber APKs placed there by step 10.
mkdir -p "${VENDOR_DIR}/prebuilts"
mkdir -p "${VENDOR_DIR}/permissions"

# ─── Android.mk + microg.mk (generated from config/microg-apks.yaml) ─────────
# Both files are derived from the same YAML source; apks-tool emits the full
# contents to stdout, so step 20 just redirects into place. Adding/removing
# an APK is a YAML-only edit.
echo "  -> Generating Android.mk from microg-apks.yaml ..."
"${APKS_TOOL[@]}" generate-android-mk > "${VENDOR_DIR}/Android.mk"

echo "  -> Generating microg.mk from microg-apks.yaml ..."
"${APKS_TOOL[@]}" generate-microg-mk > "${VENDOR_DIR}/microg.mk"

# ─── AndroidProducts.mk ──────────────────────────────────────────────────────
# Auto-discovered by build/envsetup.sh under any vendor/*. Declaring the
# wrapper product here is what makes `lunch lineage_gsi_arm64_vN_microg-userdebug`
# resolvable without modifying any repo-managed file. Per AOSP convention this
# file must only reference $(LOCAL_DIR) (which the build system pre-sets to the
# containing directory) and must not use conditionals.
echo "  -> Writing AndroidProducts.mk ..."
cat > "${VENDOR_DIR}/AndroidProducts.mk" <<'ANDROID_PRODUCTS_MK'
PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lineage_gsi_arm64_vN_microg.mk

COMMON_LUNCH_CHOICES := \
    lineage_gsi_arm64_vN_microg-userdebug \
    lineage_gsi_arm64_vN_microg-user \
    lineage_gsi_arm64_vN_microg-eng
ANDROID_PRODUCTS_MK

# ─── lineage_gsi_arm64_vN_microg.mk (wrapper product) ────────────────────────
# Inherits AndyCGYan's per-variant lineage GSI product makefile and layers
# vendor/microg/microg.mk on top, so a single lunch target produces a microG
# GSI without touching any repo-managed file. The variant suffix is included
# because the upstream lineage_gsi_arm64_{vN,vS,gN}.mk files are statically
# variant-specific — to support a different variant (e.g. vS for superuser),
# add a second wrapper inheriting the corresponding base. The default 64VN
# = vanilla, no superuser, which is what microG users typically want.
echo "  -> Writing lineage_gsi_arm64_vN_microg.mk ..."
cat > "${VENDOR_DIR}/lineage_gsi_arm64_vN_microg.mk" <<'WRAPPER_MK'
$(call inherit-product, device/lineage/gsi/lineage_gsi_arm64_vN.mk)
$(call inherit-product, vendor/microg/microg.mk)

PRODUCT_NAME := lineage_gsi_arm64_vN_microg
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

# ─── Symlink into source tree ─────────────────────────────────────────────────
# ln -sfn overwrites an existing symlink without failing, making this idempotent.
echo "  -> Symlinking ${VENDOR_DIR} → ${SRC_LINK} ..."
ln -sfn "${VENDOR_DIR}" "${SRC_LINK}"

echo "==> [20] Done."
