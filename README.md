# LineageOS 20 GSI Builder (arm64, microG)

Produces a signed LineageOS 20 (Android 13) Generic System Image for arm64 with
microG GmsCore, FakeStore, F-Droid, and Aurora Store pre-installed as privileged
apps. The entire build runs inside Docker so the host stays clean.

The output is a single `system.img` (sparse Android image) suitable for flashing
to the `system` partition of any Treble-compliant arm64 A/B device with an
unlocked bootloader — equivalent to AndyCGYan's `lineage_gsi_arm64_vN` target on the
`lineage-20-light` branch, signed with self-generated release keys.

---

## Prerequisites

- **Host OS**: Ubuntu 20.04 VM (or WSL2 with Docker Desktop on Windows)
- **Docker**: Docker Engine 20.10+ or Docker Desktop
- **Disk**: ≥ 300 GB free (source tree ~250 GB, build output ~30 GB, ccache ~50 GB)
- **RAM**: ≥ 16 GB (32 GB strongly recommended; the linker will OOM with less)
- **Time**: 4–8 hours on first run (source sync + full build); subsequent runs are
  faster thanks to ccache and incremental sync

---

## Quick start

```bash
git clone https://github.com/your-org/lineageos-gsi-builder
cd lineageos-gsi-builder
./build.sh
```

On the **first run** `build.sh` will:

1. Build the Docker image (`lineage20-gsi-microg:latest`) from `docker/Dockerfile`.
2. Create `src/`, `ccache/`, `keys/`, `intermediate/`, and `out/` on the host.
3. Inside the container, initialise the repo tree and sync ~250 GB of source.
4. Generate a full set of LineageOS release-signing keys in `./keys/` (first run only).
5. Build the GSI, sign it, and write `out/system.img` plus public certs to `out/certs/`.

On **subsequent runs** the sync is incremental, keys are reused, and ccache cuts
compile time dramatically.

### Optional environment variables / flags

| Variable / flag | Default | Effect |
|---|---|---|
| `SKIP_SYNC=1` / `--skip-sync` | `0` | Local-only `repo sync` (no network; resets working trees to manifest revision but skips fetches — useful for iteration) |
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

The `./keys/` directory is preserved between runs. On the first run the pipeline
generates a full LineageOS key set; on all subsequent runs those keys are reused
automatically.

**If you plan to ship OTA updates to devices already running this build, you MUST
back up `./keys/` privately and securely.** Losing the keys means you cannot sign
future OTA packages that will be accepted by existing installations.

- **Never commit `./keys/` to git** — it is listed in `.gitignore`.
- Store the backup somewhere off the build machine (encrypted storage,
  password manager with file attachment, etc.).
- The `out/certs/` directory contains only the public `.x509.pem` certificates —
  these are safe to distribute and are used to verify the signed image.

---

## Caveats

- **Branch maintenance**: The `lineage-20-light` branch may not receive security
  patches indefinitely. Check the AndyCGYan repository for branch status before
  relying on this for production use.
- **AuroraStore URL**: The AuroraStore download URL in `config/microg-apks.yaml` may
  become stale when new versions are released. Update it to the latest stable
  release from the AuroraOSS website.

---

## Patching a stock boot.img (devices without a `vbmeta` partition)

Some devices — notably MediaTek-based phones like the Unihertz Jelly Star —
don't expose a standalone `vbmeta` partition. On those, the dm-verity root
hash for `system` is chain-loaded from the **boot** image's AVB footer.
Flashing a GSI without also disabling verity there gets you stuck at
"Can't load Android system. Your data may be corrupt." in recovery.

If you drop a stock `boot.img` for your device into `./boot_img/boot.img`,
the pipeline runs an extra step (`65-patch-boot.sh`) that produces a
patched boot image equivalent to what Magisk's "Select and Patch a File"
app workflow generates — but headlessly, inside the container.

Under the hood the step calls `magiskboot` (the same native binary the
Magisk app uses) and runs three commands:

1. **`magiskboot unpack boot.img`** — splits the image into `kernel`,
   `ramdisk.cpio`, and (if present) `dtb`.
2. **`magiskboot cpio ramdisk.cpio "patch"`** — strips `verify`, `avb`,
   `verifyatboot`, `forceencrypt`, and related options from `fstab.*`
   inside the ramdisk, so `fs_mgr` does not try to engage dm-verity on
   `system` at mount time.
3. **`magiskboot repack boot.img new-boot.img`** — rebuilds the image
   and sets `HASHTREE_DISABLED | VERIFICATION_DISABLED` (0x3) in the
   vbmeta footer flags. The same bits `fastboot --disable-verity
   --disable-verification flash` writes at flash time.

The result is written to `out/boot-patched.img`. The vbmeta signature
inside the patched image no longer verifies — that's expected. On an
unlocked bootloader (which you already need for any of this) the
signature mismatch is downgraded to a warning, and the kernel still
honors the disabled-flag bits and the cleaned fstab.

Flash it alongside your `system.img`:

```bash
fastboot flash boot_a out/boot-patched.img
fastboot flash system_a out/system.img
fastboot -w
fastboot reboot
```

The `magiskboot` binary is installed into the Docker image at build
time, extracted from the official Magisk APK release on GitHub. To pin
a different Magisk version (default is `v30.7`), pass `MAGISK_VERSION`
as a Docker build arg.

### Getting a stock boot.img

Two routes:

- **Dump from the device** (most reliable): boot a custom recovery
  (TWRP/OrangeFox) via `fastboot boot twrp.img`, then
  `dd if=/dev/block/by-name/boot_a of=/sdcard/boot.img bs=4M` and
  `adb pull /sdcard/boot.img`.
- **Extract from OEM firmware**: download the stock firmware package
  from your manufacturer. For Unihertz/MTK devices this is an SP Flash
  Tool package — `boot.img` is a top-level file inside.

If `magiskboot unpack` reports no `ramdisk.cpio`, your device may use
an `init_boot` partition instead (Android 13+ split-boot layout). In
that case dump `init_boot_a` rather than `boot_a` and place it as
`./boot_img/boot.img`. Inspect with `avbtool info_image --image
boot.img` if you want to see the AVB descriptors before patching.

The `./boot_img/` directory is gitignored — OEM firmware should never
be committed.

---

## Customisation

### Changing microG / FLOSS app versions

Edit `config/microg-apks.yaml`. Each entry under `apks:` carries `module`,
`filename`, `url`, `sha256`, `certificate` (`platform` or `PRESIGNED`),
`privileged`, and a free-text `note`. The `sha256` field defaults to `SKIP`
to keep the build from breaking when upstream bumps versions; for production
use, replace `SKIP` with the actual 64-char hex digest.

Adding a new APK is a YAML-only edit — `scripts/apks-tool.py` regenerates the
downloads list and the `vendor/microg/{Android.mk,microg.mk}` files
automatically on the next build.

### Changing the X.509 certificate subject

Edit `config/cert-subject.txt`. The default is:

```
/C=US/ST=California/L=Mountain View/O=LineageOS GSI Builder/OU=Android/CN=LineageOS
```

This only affects newly generated keys. If `./keys/` is already populated the
subject line is ignored.

### Changing the build variant

Set `VARIANT` when invoking `build.sh`:

```bash
VARIANT=64VS ./build.sh   # arm64, vanilla, with su (superuser)
```

> **Note**: `GAPPS` variants (`G`) include Google Play Services, which conflicts
> with microG. Use vanilla variants (`V`) for this pipeline.

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
| `65-patch-boot.sh` | (Optional) Patch a stock boot.img dropped into `./boot_img/` via `magiskboot` — strips verity from fstab and disables AVB flags |
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
