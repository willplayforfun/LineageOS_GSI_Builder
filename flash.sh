#!/usr/bin/env bash
# Flash a LineageOS GSI build to an A/B device via fastboot.
# Usage: ./flash.sh [--no-reboot] [OUT_DIR]
#   OUT_DIR defaults to ./out relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NO_REBOOT=false
for arg in "$@"; do
    case "$arg" in
        --no-reboot) NO_REBOOT=true ;;
        *) OUT="$arg" ;;
    esac
done
OUT="${OUT:-$SCRIPT_DIR/out}"
SYSTEM_IMG="$OUT/system.img"
BOOT_IMG="$OUT/boot-patched.img"
VENDOR_BOOT_IMG="$OUT/vendor_boot-patched.img"

die() { echo "ERROR: $*" >&2; exit 1; }

run_fastboot() {
    fastboot "$@" || die "fastboot $* failed"
}

[ -f "$SYSTEM_IMG" ] || die "$SYSTEM_IMG not found. Build first or pass OUT_DIR as argument."

echo "==> Deleting logical product partition (may fail on some devices — that is OK)..."
fastboot delete-logical-partition product || true

echo "==> Erasing system_a..."
run_fastboot erase system_a

echo "==> Flashing system_a (this takes a while)..."
run_fastboot flash system_a "$SYSTEM_IMG"

echo "==> Setting active slot to a..."
run_fastboot --set-active=a

if [ -f "$BOOT_IMG" ]; then
    echo "==> Flashing patched boot_a..."
    run_fastboot flash boot_a "$BOOT_IMG"
else
    echo "WARNING: $BOOT_IMG not found — skipping boot patch."
    echo "         On devices without a standalone vbmeta partition, dm-verity will"
    echo "         not be disabled and the system may fail to mount."
fi

if [ -f "$VENDOR_BOOT_IMG" ]; then
    echo "==> Flashing patched vendor_boot_a..."
    run_fastboot flash vendor_boot_a "$VENDOR_BOOT_IMG"
else
    echo "INFO: $VENDOR_BOOT_IMG not found — skipping vendor_boot flash (not all devices have this partition)."
fi

echo "==> Wiping userdata/cache/metadata (errors about missing partitions are normal)..."
fastboot -w || true

if [ "$NO_REBOOT" = true ]; then
    echo ""
    echo "Done. Device is still in fastboot mode (--no-reboot was passed)."
else
    echo "==> Rebooting..."
    run_fastboot reboot
    echo ""
    echo "Done. Your device is rebooting into the new system."
fi
