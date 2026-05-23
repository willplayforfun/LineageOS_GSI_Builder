#!/usr/bin/env bash
# Purpose: Generate vendor/microg build files (incl. an AndroidProducts.mk
# wrapper product `lineage_gsi_arm64_vN_microg`) in the intermediate area and
# symlink into the source tree.

set -euo pipefail
IFS=$'\n\t'

VENDOR_DIR="/srv/intermediate/vendor-microg"
SRC_LINK="/srv/src/vendor/microg"

echo "==> [20] Staging vendor/microg"

# All work below is cheap and idempotent (clobbering writes + ln -sfn), so we
# rerun it every invocation rather than gating on a sentinel — that keeps the
# staged content in lockstep with whatever this script currently emits, even
# if it has changed since a previous run.

# Ensure the prebuilts dir exists but never clobber APKs placed there by step 10.
mkdir -p "${VENDOR_DIR}/prebuilts"
mkdir -p "${VENDOR_DIR}/permissions"

# ─── Android.mk ───────────────────────────────────────────────────────────────
echo "  -> Writing Android.mk ..."
cat > "${VENDOR_DIR}/Android.mk" <<'ANDROID_MK'
LOCAL_PATH := $(call my-dir)

# GmsCore: signed with the platform key so the LineageOS framework grants the
# FAKE_PACKAGE_SIGNATURE permission, which is what makes signature spoofing work.
include $(CLEAR_VARS)
LOCAL_MODULE             := GmsCore
LOCAL_MODULE_CLASS       := APPS
LOCAL_MODULE_TAGS        := optional
LOCAL_SRC_FILES          := prebuilts/GmsCore.apk
LOCAL_CERTIFICATE        := platform
LOCAL_PRIVILEGED_MODULE  := true
LOCAL_PRODUCT_MODULE     := true
include $(BUILD_PREBUILT)

# Companion (microG FakeStore): also needs platform cert for the same reason.
include $(CLEAR_VARS)
LOCAL_MODULE             := Companion
LOCAL_MODULE_CLASS       := APPS
LOCAL_MODULE_TAGS        := optional
LOCAL_SRC_FILES          := prebuilts/Companion.apk
LOCAL_CERTIFICATE        := platform
LOCAL_PRIVILEGED_MODULE  := true
LOCAL_PRODUCT_MODULE     := true
include $(BUILD_PREBUILT)

# F-Droid: keep the upstream developer signature so the app can self-update and
# verify repos signed against that key.
include $(CLEAR_VARS)
LOCAL_MODULE             := FDroid
LOCAL_MODULE_CLASS       := APPS
LOCAL_MODULE_TAGS        := optional
LOCAL_SRC_FILES          := prebuilts/FDroid.apk
LOCAL_CERTIFICATE        := PRESIGNED
LOCAL_PRIVILEGED_MODULE  := true
LOCAL_PRODUCT_MODULE     := true
include $(BUILD_PREBUILT)

# Aurora Store: same reasoning as F-Droid.
include $(CLEAR_VARS)
LOCAL_MODULE             := AuroraStore
LOCAL_MODULE_CLASS       := APPS
LOCAL_MODULE_TAGS        := optional
LOCAL_SRC_FILES          := prebuilts/AuroraStore.apk
LOCAL_CERTIFICATE        := PRESIGNED
LOCAL_PRIVILEGED_MODULE  := true
LOCAL_PRODUCT_MODULE     := true
include $(BUILD_PREBUILT)
ANDROID_MK

# ─── microg.mk ────────────────────────────────────────────────────────────────
echo "  -> Writing microg.mk ..."
cat > "${VENDOR_DIR}/microg.mk" <<'MICROG_MK'
# Add microG and FLOSS apps to the product image.
PRODUCT_PACKAGES += \
    GmsCore \
    Companion \
    FDroid \
    AuroraStore

# Install the privapp-permissions file that grants FAKE_PACKAGE_SIGNATURE to
# com.google.android.gms (i.e. GmsCore). Without this the framework will not
# honour the permission even though the APK declares it.
PRODUCT_COPY_FILES += \
    vendor/microg/permissions/privapp-permissions-com.google.android.gms.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/privapp-permissions-com.google.android.gms.xml
MICROG_MK

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
