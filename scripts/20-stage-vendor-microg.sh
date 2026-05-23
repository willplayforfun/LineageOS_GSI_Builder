#!/usr/bin/env bash
# Purpose: Generate vendor/microg build files in the intermediate area and symlink into the source tree.

set -euo pipefail
IFS=$'\n\t'

SENTINEL="/srv/intermediate/.stage-20-done"
VENDOR_DIR="/srv/intermediate/vendor-microg"
SRC_LINK="/srv/src/vendor/microg"

echo "==> [20] Staging vendor/microg"

if [[ -f "${SENTINEL}" ]]; then
    echo "  -> Sentinel found — vendor/microg already staged."
    # Still (re)apply the symlink in case src/ was wiped but intermediate/ was not.
    ln -sfn "${VENDOR_DIR}" "${SRC_LINK}"
    echo "==> [20] Done (cached)."
    exit 0
fi

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

touch "${SENTINEL}"
echo "==> [20] Done."
