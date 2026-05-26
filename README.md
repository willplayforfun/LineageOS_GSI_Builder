# LineageOS 20 GSI Builder

Produces a signed LineageOS 20 (Android 13) Generic System Image for arm64 with
microG GmsCore, FakeStore, F-Droid, and Aurora Store pre-installed as privileged
apps. The entire build runs inside Docker.

The output is a `system.img` file suitable for flashing to the 
`system` partition of any Treble-compliant arm64 A/B device with an
unlocked bootloader, along with a `vbmeta.img` and/or optional patched `boot.img`
that disables verity checks that would prevent the modified system image from loading. 

This is roughly equivalent to AndyCGYan's `lineage_gsi_arm64_vN` target on the
`lineage-20-light` branch, signed with self-generated release keys.

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
| `VARIANT=…` / `--variant=…` | `64VN` | Build flavour (see Customisation below) |

```bash
# Example: re-run without syncing, using 8 cores
SKIP_SYNC=1 NPROC=8 ./build.sh

# Or via flags:
./build.sh --skip-sync --nproc=8
```

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

- The AndyCGYan `lineage-20-light` branches are no longer maintained, meaning some aspects of the build are frozen to past commits and may miss out on future security updates from LineageOS.

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
