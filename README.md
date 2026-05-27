# LineageOS 20 GSI Builder

Produces a signed LineageOS 20 (Android 13) Generic System Image for arm64 with
microG GmsCore, FakeStore, F-Droid, and Aurora Store pre-installed as privileged
apps. The entire build runs inside Docker.

The output is a `system.img` file suitable for flashing to the 
`system` partition of any Treble-compliant arm64 A/B device with an
unlocked bootloader, along with a `vbmeta.img` and/or optional patched `boot.img`
that disables verity checks that would prevent the modified system image from loading. 

This is roughly equivalent to AndyCGYan's `lineage_gsi_arm64_bvN` target on the
`lineage-20-td` branch, signed with self-generated release keys.

---

## Prerequisites

- **Host OS**: Theoretically works on any Docker-enabled computer, however it was tested primarily inside an Ubuntu 20.04 VM.
- **Docker**: Docker Engine 20.10+ or Docker Desktop
- **Disk**: ≥ 300 GB free (source tree ~250 GB, build output ~30 GB, ccache ~50 GB)
- **RAM**: ≥ 16 GB (32 GB strongly recommended; the linker will OOM with less)
- **Time**: 4–8 hours on first run (source sync + full build); subsequent runs are
  faster thanks to ccache and incremental sync

---

## Quick start

```bash
git clone https://github.com/willplayforfun/LineageOS_GSI_Builder.git
cd lineageos-gsi-builder
./build.sh
```

On the **first run** `build.sh` will:

1. Build the Docker image from `docker/Dockerfile`.
2. Create `src/`, `ccache/`, `keys/`, `intermediate/`, and `out/` on the host.
3. Inside the container, initialise the repo tree and sync ~250 GB of source.
4. Generate a full set of release-signing keys in `keys/` (first run only).
5. Build the GSI.
6. Sign the built image.
7. Write `system.img` and `vbmeta.img` to `out/`, plus public certs to `out/certs/`.

On **subsequent runs** the sync is incremental, keys are reused, and ccache cuts
compile time dramatically.

### Optional environment variables / flags

| Variable / flag | Default | Effect |
|---|---|---|
| `SKIP_SYNC=1` / `--skip-sync` | `0` | Local-only `repo sync` (no network; resets working trees to manifest revision but skips fetches — useful for iteration) |
| `SKIP_BUILD=1` / `--skip-build` | `0` | Useful if you have problems with post-build steps and need to iterate faster. |
| `SKIP_SIGNING=1` / `--skip-signing` | `0` | Useful if you have problems with post-signing steps and need to iterate faster. |
| `CLEAN=1` / `--clean` | `0` | Wipe `out/` and `intermediate/` before starting |
| `NPROC=N` / `--nproc=N` | all cores | Parallelism for sync and build |

```bash
# Example: re-run without syncing, using 8 cores
SKIP_SYNC=1 NPROC=8 ./build.sh

# Or via flags:
./build.sh --skip-sync --nproc=8
```

## Flashing the image

"Flashing" is the process of installing the built image onto the phone. While this deserves a more fleshed out guide, in summary:
 - Unlock the phone's bootloader
 - Boot into "fastboot" mode
 - Run the flash script (`flash.sh` or `flash.ps1`)

### Restoring the stock firmware

In case of an issue, you can restore your phone to factory condition. 
For a Unihertz device, follow this guide: `https://www.reddit.com/r/unihertz/comments/1dzb98g/jelly_star_how_to_reinstall_stock_firmware_after/`.
Roughly:
 - Install Mediatek USB VCOM drivers from `https://www.hovatek.com/forum/thread-16640.html`.
 - Download SP Flash Tool v6 from `https://spflashtools.com/`.
 - Download stock firmware. For Unihertz, it is hosted here: `https://drive.google.com/drive/folders/0By1nhWOmuw2KdDhTUlFOZHpXQjg?resourcekey=0-KHJPIYVPw2iHL--cceWyaw`
 - Unzip the archive, and load the flash.xml file in SPFT.
 - Hit "Download" and reboot the phone.

---

## Reusing signing keys

The `keys/` directory is preserved between runs. On the first run the pipeline
generates a full signing key set; on all subsequent runs those keys are reused
automatically.

If you plan to generate OTA (over-the-air) updates, you must back up `keys/`. 
Losing the keys means you cannot sign future OTA packages, preventing them from being
accepted by existing installations.

The `out/certs/` directory contains only the public `.x509.pem` certificates —
these are safe to distribute and are used to verify the signed image.

---

## Caveats

- The pipeline pins `lineage_build_unified` and `lineage_patches_unified` to specific commits on the `-td` branch for build stability; advance the pins in `config/pins.yaml` when patch compatibility allows.

---

## Patching a stock boot.img (devices without a `vbmeta` partition)

Some devices — notably MediaTek-based phones like the Unihertz Jelly Star —
don't expose a standalone `vbmeta` partition. On those, the dm-verity root
hash for `system` is chain-loaded from the **boot** image's AVB footer.
You cannot boot a flashed GSI without also disabling verity checks.

If you drop a stock `boot.img` and/or `vendor_boot.img` for your device 
into `boot_img/`, the pipeline runs an extra step that produces a
patched boot image equivalent to patching via Magisk.

Flash them alongside your `system.img`:

```bash
fastboot flash boot_a out/boot-patched.img
fastboot flash vendor_boot_a out/vendor_boot-patched.img
fastboot flash system_a out/system.img
fastboot -w
fastboot reboot
```

If flashing `vbmeta.img`:
```bash
fastboot --disable-verity --disable-verification flash vbmeta out/vbmeta.img
```

### Getting a stock boot.img

Two routes:

- **Dump from the device** (most reliable): boot a custom recovery
  (TWRP/OrangeFox) via `fastboot boot twrp.img`, then
  `dd if=/dev/block/by-name/boot_a of=/sdcard/boot.img bs=4M` and
  `adb pull /sdcard/boot.img`.
- **Extract from OEM firmware**: download the stock firmware package
  from your manufacturer. For MediaTek devices this is an SP Flash
  Tool package — `boot.img` is a top-level file inside.

---

## Customisation

### Changing microG / FLOSS app versions

Adding a new APK is a YAML-only edit; modify `config/microg-apks.yaml`. 
The `sha256` field defaults to `SKIP` to keep the build from breaking 
when upstream bumps versions; if you want, replace `SKIP` with the actual 64-char hex digest.


### Changing the X.509 certificate subject

Edit `config/cert-subject.txt`. This only affects newly generated keys. 
If `keys/` is already populated the subject line is ignored.

---

## Conceptual reference

There are several layers being combined here to produce a build:
 - AOSP: the "base version" of Android; open-source, and no Google-specific stuff.
 - LineageOS: a version of Android based off AOSP that adds some additional features and patches on top to create a fully-fledged OS experience.
 - Treble: name for Android architecture of versions 8+; it is separated into separate parts, allowing a generic "system image" to (theoretically) be combined with separate device-specific firmware.
 - TrebleDroid: a project that patches AOSP to work as a GSI on many different types of devices, as device manufacturers do not necessarily release fully Treble-compliant firmware/hardware.
 - phh: a developer (Pierre-Hugues Husson) who created and maintained a patch set that allows TrebleDroid to be used with non-AOSP Android versions, such as LineageOS.
 - AndyCGYan: a developer (Andy Yan) who created and maintained a patch set and build tools to specifically produce LineageOS GSIs.

However, AndyCGYan's build tools do not support integrating the following elements into a LineageOS GSI:
 - microG: an open-source implementation of "Google Play Services" library, which provides functionality like geolocation and push notifications to many apps.
 - F-Droid: an alternative "app store" that hosts free open-source apps.
 - Aurora Store: an app that allows access to the Google Play Store without logging in with a Google account.

Those three elements allow the majority of apps to be accessed and used without logging into a Google account on the phone, and without installing Google software which violates privacy.

### Pinning

Since so many layers of patches are combined, sometimes the layers conflict. This is because "upstream" layers like LineageOS may be updated, and AndyCGYan or phh may not maintain their patchset, especially for an older version like LineageOS 20. When a conflict emerges, the two options are: (A) resolve the conflict personally, or (B) do not accept the new changes which create the conflict. "Pinning" is the process of choosing which version of changes to use, in order to prevent future changes from introducing a conflict.

Fortunately, the Android codebase is split into many separate projects, and so only small parts of it need to be pinned as conflicts arise. See pins.yaml -- so far only 3 projects have been pinned due to introducing conflicts for the latest AndyCGYan patchset (which I've pinned simply for reproducibility). If new conflicts arise in the future (e.g. due to security updates), more pins can be introduced to keep this build functioning. The process is relatively simple: find the repo that introduces the change causing the conflict, find the SHA hash of the commit *before* that change is introduced, and pin the repo to that SHA.

## Pipeline script reference

| Script | Purpose |
|---|---|
| `00-prep-source.sh` | `repo init` + `repo sync` + local manifests |
| `10-fetch-microg.sh` | Download microG / FLOSS APKs into `intermediate/` |
| `20-stage-vendor-microg.sh` | Write `vendor/microg/` build rules and symlink into source tree |
| `40-generate-keys.sh` | Generate the standard 12-key LineageOS release-signing set (idempotent) |
| `45-stage-vendor-keys.sh` | Stage `vendor/lineage-priv/keys/` (writes `Android.mk`/`keys.mk`, symlinks key material) |
| `50-build.sh` | Apply `lineage_patches_unified` patches, `lunch` the microG wrapper product, then `make target-files-package otatools` |
| `55-generate-apex-keys.sh` | Discover APEX modules in the unsigned target files and mint 4096-bit APEX keys on demand |
| `60-sign.sh` | Sign target files (incl. discovered APEXes) and extract `system.img` |
| `62-extract-images.sh` | Extract `system.img` and `vbmeta.img` from the signed target-files zip and publish certs |
| `65-patch-boot.sh` | (Optional) Use `magiskboot` to patch a stock boot.img and/or vendor_boot.img dropped into `boot_img/` — strips verity from fstab and disables AVB flags |
| `99-report.sh` | Print build summary |

> **Current status**: All scripts above are implemented. The pipeline has not
> yet been end-to-end validated with a successful build — first runs may
> surface lunch-target or patch-application issues that require iteration.

---

## Acknowledgements

- [AndyCGYan](https://github.com/AndyCGYan) — `lineage_build_unified` and
  `lineage_patches_unified`, which make building LineageOS GSIs tractable
- [microG Project](https://microg.org) — free reimplementation of Google Mobile Services
- [F-Droid](https://f-droid.org) — free and open-source Android app repository
- [Aurora Store](https://auroraoss.com) — open-source Google Play client
- [LineageOS](https://lineageos.org) — the upstream Android distribution
- [phhusson / TrebleDroid](https://github.com/phhusson/treble_experimentations) —
  Project Treble GSI framework and patches
