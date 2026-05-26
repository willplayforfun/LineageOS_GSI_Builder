#!/usr/bin/env python3
"""Set the HASHTREE_DISABLED and VERIFICATION_DISABLED flags in the AVB
vbmeta footer of an Android boot image, in place.

Invoked by 65-patch-boot.sh. Operates on a copy of the user's stock boot.img
so the input is never mutated.

Why this exists: avbtool can set these flags when *creating* a footer
(--flags arg to add_hash_footer / make_vbmeta_image) but has no command to
mutate them on an existing image. The fastboot CLI's --disable-verity
--disable-verification path does exactly this byte-edit at flash time;
we replicate it offline so the resulting file is bootable as-is on
devices where vbmeta is chain-loaded from boot (no separate vbmeta
partition).

The vbmeta signature becomes invalid as a side effect. That's fine on an
unlocked bootloader, where signature verification is downgraded to a
warning and the disabled-flag bits are still honored by the kernel.

Layout reference (AOSP libavb/avb_footer.h and libavb/avb_vbmeta_image.h):
  AVB Footer (last 64 bytes of image):
    0x00  magic[4] = "AVBf"
    0x04  version_major (u32 BE)
    0x08  version_minor (u32 BE)
    0x0C  original_image_size (u64 BE)
    0x14  vbmeta_offset (u64 BE)        <- points to VBMeta header
    0x1C  vbmeta_size (u64 BE)
    ...
  VBMeta header (at vbmeta_offset):
    0x00  magic[4] = "AVB0"
    ...   (offsets/sizes for auth + aux data blocks)
    0x78  flags (u32 BE)                <- bits we modify

Flag bits:
  bit 0 (0x01) = HASHTREE_DISABLED      -> kernel skips dm-verity
  bit 1 (0x02) = VERIFICATION_DISABLED  -> kernel skips AVB signature check
"""

import struct
import sys

HASHTREE_DISABLED     = 0x01
VERIFICATION_DISABLED = 0x02
FLAGS_TO_SET          = HASHTREE_DISABLED | VERIFICATION_DISABLED

FOOTER_SIZE              = 64
FOOTER_MAGIC             = b"AVBf"
FOOTER_VBMETA_OFFSET_OFF = 20   # u64 BE
FOOTER_VBMETA_SIZE_OFF   = 28   # u64 BE

VBMETA_MAGIC      = b"AVB0"
VBMETA_FLAGS_OFF  = 0x78        # u32 BE, offset within vbmeta header


def patch(path: str) -> int:
    with open(path, "r+b") as f:
        f.seek(0, 2)
        size = f.tell()
        if size < FOOTER_SIZE:
            sys.stderr.write(
                f"ERROR: {path} is {size} bytes; too small to contain an AVB footer.\n"
            )
            return 1

        # ─── AVB Footer ─────────────────────────────────────────────────────
        f.seek(size - FOOTER_SIZE)
        footer = f.read(FOOTER_SIZE)
        if footer[0:4] != FOOTER_MAGIC:
            sys.stderr.write(
                "ERROR: no AVB footer magic ('AVBf') at end of image.\n"
                "       This device may not chain-load vbmeta from boot — verity may\n"
                "       be enforced elsewhere (separate vbmeta partition, or built\n"
                "       into the vendor_boot image). Inspect with:\n"
                f"         avbtool info_image --image {path}\n"
                "       and adjust the patching target accordingly.\n"
            )
            return 2

        (vbmeta_offset,) = struct.unpack(
            ">Q", footer[FOOTER_VBMETA_OFFSET_OFF:FOOTER_VBMETA_OFFSET_OFF + 8]
        )
        (vbmeta_size,) = struct.unpack(
            ">Q", footer[FOOTER_VBMETA_SIZE_OFF:FOOTER_VBMETA_SIZE_OFF + 8]
        )
        print(f"       AVB footer found: vbmeta @ 0x{vbmeta_offset:x}, size={vbmeta_size}")

        # ─── VBMeta header ──────────────────────────────────────────────────
        f.seek(vbmeta_offset)
        magic = f.read(4)
        if magic != VBMETA_MAGIC:
            sys.stderr.write(
                f"ERROR: VBMeta header magic mismatch at offset 0x{vbmeta_offset:x} "
                f"(got {magic!r}, expected b'AVB0'). Image may be malformed.\n"
            )
            return 3

        flags_offset = vbmeta_offset + VBMETA_FLAGS_OFF
        f.seek(flags_offset)
        (current_flags,) = struct.unpack(">I", f.read(4))
        print(f"       Current flags: 0x{current_flags:08x}")

        new_flags = current_flags | FLAGS_TO_SET
        if new_flags == current_flags:
            print(
                "       Flags already include HASHTREE_DISABLED|VERIFICATION_DISABLED "
                "— no change."
            )
            return 0

        f.seek(flags_offset)
        f.write(struct.pack(">I", new_flags))
        print(
            f"       New flags:     0x{new_flags:08x}  "
            f"(HASHTREE_DISABLED | VERIFICATION_DISABLED)"
        )
        return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write(f"Usage: {argv[0]} <boot.img>\n")
        return 64  # EX_USAGE
    return patch(argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
