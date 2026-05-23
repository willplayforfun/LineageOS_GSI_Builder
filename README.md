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
| `SKIP_SYNC=1` / `--skip-sync` | `0` | Skip `repo sync` (useful after first sync) |
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
- **AuroraStore URL**: The AuroraStore download URL in `config/microg-apks.txt` may
  become stale when new versions are released. Update it to the latest stable
  release from the AuroraOSS website.

---

## Customisation

### Changing microG / FLOSS app versions

Edit `config/microg-apks.txt`. Each line is:

```
<local filename>  <url>  <sha256 or SKIP>
```

Replace the URL and optionally pin the sha256 for reproducibility. The `SKIP`
default disables verification so the build doesn't break when upstream bumps
versions — for production use, replace `SKIP` with the actual sha256 hash.

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
