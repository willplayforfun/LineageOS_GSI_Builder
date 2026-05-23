# Task: Build a Dockerised pipeline for LineageOS 20 GSI with microG

Set this repository so that, when invoked with a single shell command, it produces a signed LineageOS 20 GSI (Generic System Image) for arm64 with microG and FLOSS app replacements pre-installed. The whole pipeline must run inside Docker so the host Ubuntu 20.04 VM stays clean. Do **not** start the build — only produce the repository and verify it's syntactically valid (shellcheck, hadolint, etc., where applicable).

## Target output

A single `system.img` file (sparse Android image) suitable for flashing to the `system` partition of any Treble-compliant arm64 device with an unlocked bootloader. Build characteristics:

- **Base**: LineageOS 20 (Android 13)
- **Architecture**: arm64
- **Partition scheme**: AB / system-as-root (the `b` in the variant name)
- **GAPPS**: none (`v` = vanilla)
- **Superuser**: none (`N`)
- **Equivalent to**: AndyCGYan's `treble_arm64_bvN` target on the `lineage-20-light` branch, plus microG GmsCore, microG Companion (FakeStore), F-Droid, and Aurora Store as pre-installed privileged apps
- **Signed**: with self-generated release keys (or reused keys from a prior run)

## Inputs and outputs the pipeline must handle

The user will invoke the build with a command roughly like:

```
./build.sh
```

from the repository root. The script must:

1. Mount four host directories into the build container as volumes:
   - `./src` → LineageOS source tree (~250 GB after sync — persists between runs)
   - `./ccache` → ccache directory (~50 GB — persists between runs)
   - `./keys` → signing keys (~few KB — **reused if present**, generated if empty)
   - `./intermediate` → intermediate build files like sentinel files
   - `./out` → final output artefacts (the signed `system.img`, build manifest, and a copy of the public certs)

2. On first run, generate a full set of LineageOS release-signing keys in `./keys` using the standard AOSP procedure (see "Signing" section below). On subsequent runs, detect that `./keys` is already populated and skip generation, reusing the existing keys. Keys are generated **without passphrases** (per LineageOS wiki: the build tooling expects unprotected keys; passphrase-protected keys cause `sign_target_files_apks` to hang).

3. Build the image, sign it with those keys, and copy the resulting `system.img` plus all `.x509.pem` public certs (NOT the `.pk8` private keys) into `./out/`. The private keys stay in `./keys/` only.

4. Print a final summary showing: build duration, image path, image size, image SHA256, and the path to the public certs.

## Repository layout to create

```
.
├── README.md                          # User-facing instructions
├── build.sh                           # Host-side entrypoint — wraps `docker run`
├── docker/
│   ├── Dockerfile                     # Ubuntu 20.04-based build image
│   └── entrypoint.sh                  # In-container orchestrator
├── scripts/
│   ├── 00-prep-source.sh              # repo init + sync + local manifest setup
│   ├── 10-fetch-microg.sh             # Download microG / FLOSS APKs
│   ├── 20-stage-vendor-microg.sh      # Write vendor/microg/{Android.mk,microg.mk,AndroidProducts.mk,treble_arm64_microg.mk}
│   ├── 40-generate-keys.sh            # AOSP key generation into /srv/keys (idempotent)
│   ├── 45-stage-vendor-keys.sh        # Build intermediate/lineage-priv, symlink into src
│   ├── 50-build.sh                    # Drives the unified build script
│   ├── 60-sign.sh                     # Sign target files, extract system.img
│   └── 99-report.sh                   # Print final summary
├── config/
│   ├── microg-apks.txt                # URL + sha256 list of APKs to fetch
│   ├── cert-subject.txt               # X.509 subject line for key generation
│   └── local_manifests/               # .xml files copied into .repo/local_manifests/ before sync
│       └── andycgyan-unified.xml      # Declares lineage_build_unified + lineage_patches_unified
└── .gitignore                         # Ignore src/, ccache/, out/, keys/
```

## Docker image specification

**Base image**: `ubuntu:20.04` (NOT a newer Ubuntu — LineageOS 20's `repo` / Java / Python toolchain has known friction with 22.04+ for this build year).

Install:
- All packages from the LineageOS 20 build prerequisites list (the canonical list is in the LineageOS wiki under "Prepare the build environment"). Key items: `bc`, `bison`, `build-essential`, `ccache`, `curl`, `flex`, `g++-multilib`, `gcc-multilib`, `git`, `git-lfs`, `gnupg`, `gperf`, `imagemagick`, `lib32readline-dev`, `lib32z1-dev`, `libelf-dev`, `liblz4-tool`, `libsdl1.2-dev`, `libssl-dev`, `libxml2`, `libxml2-utils`, `lzop`, `pngcrush`, `rsync`, `schedtool`, `squashfs-tools`, `xsltproc`, `zip`, `zlib1g-dev`, `python-is-python3`, `python3`, `openjdk-11-jdk`.
- Google's `repo` tool, installed to `/usr/local/bin/repo` (fetch from `https://storage.googleapis.com/git-repo-downloads/repo`).
- A non-root build user `builder` (UID/GID configurable at build time via `--build-arg` so volume-mounted files don't end up root-owned).

Set `JAVA_HOME` to `/usr/lib/jvm/java-11-openjdk-amd64`. Set `USE_CCACHE=1`, `CCACHE_DIR=/srv/ccache`, `CCACHE_EXEC=/usr/bin/ccache`.

The Dockerfile must produce a small, layered, cacheable image. Use multi-stage only if it actually helps; otherwise a single stage is fine.

## `build.sh` (host entrypoint)

Responsibilities:

1. Resolve `HOST_UID=$(id -u)` and `HOST_GID=$(id -g)`. Pass them as `--build-arg`s when running `docker build`, so the container's `builder` user matches the host user.
2. `docker build` the image (tag: `lineage20-gsi-microg:latest`).
3. Create `src/`, `ccache/`, `keys/`, `intermediate/`, `out/` directories if absent.
4. `docker run --rm -it` the image, mounting all five dirs — `src` → `/srv/src`, `ccache` → `/srv/ccache`, `keys` → `/srv/keys`, `intermediate` → `/srv/intermediate`, `out` → `/srv/out` — then calling `/opt/pipeline/entrypoint.sh`.
5. Accept these optional environment variables / CLI flags, with sensible defaults:
   - `NPROC` (default: `$(nproc)`)
   - `SKIP_SYNC=1` to skip `repo sync` (useful for iterating after the first sync)
   - `CLEAN=1` to wipe the `out/` and `intermediate/` dirs before running
   - `VARIANT` (default: `64VN` — keep it parameterised in case the user later wants `64GN` etc.)

## `docker/entrypoint.sh`

Runs as `builder`. Sources `/etc/profile`, then executes the numbered scripts in order:

```
exec /opt/pipeline/scripts/00-prep-source.sh
# ... and so on
```

Each script must be **idempotent** and **resumable**: if its output already exists and looks correct, it skips its work. Use sentinel files (e.g. `/srv/intermediate/.stage-00-done`) to mark completion.

## Per-script details

### `00-prep-source.sh`

- If `/srv/src/.repo` doesn't exist: `repo init -u https://github.com/LineageOS/android.git -b lineage-20.0 --git-lfs` in `/srv/src`.
- Create `/srv/src/.repo/local_manifests/` if absent.
- Copy every `*.xml` from `/opt/pipeline/config/local_manifests/` into `/srv/src/.repo/local_manifests/`. This includes the pre-committed `andycgyan-unified.xml` (see below), so `repo sync` handles `lineage_build_unified` and `lineage_patches_unified` as proper repo projects rather than ad-hoc git clones.
- Unless `SKIP_SYNC=1`: `repo sync -j${NPROC} --force-sync --no-tags --no-clone-bundle --optimized-fetch`.

`config/local_manifests/andycgyan-unified.xml` must be committed to the pipeline repo with the following contents (or equivalent):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="andycgyan" fetch="https://github.com/AndyCGYan" />
  <project path="lineage_build_unified"   name="lineage_build_unified"
           remote="andycgyan" revision="lineage-20-light" />
  <project path="lineage_patches_unified" name="lineage_patches_unified"
           remote="andycgyan" revision="lineage-20-light" />
</manifest>
```

This is the correct way to include extra repos in a `repo`-managed tree. `repo sync --force-sync` will keep them up to date alongside the rest of the source; `repo status` will include them; and there is no need for separate `git clone` / `git pull` logic in the script.

### `10-fetch-microg.sh`

Reads `/opt/pipeline/config/microg-apks.txt`. Each line is `<filename> <url> <sha256>`. For each entry, if `/srv/intermediate/vendor-microg/prebuilts/<filename>` is absent or has wrong sha256, download and verify into that path. Do **not** write directly into `/srv/src/` — step 20 creates the source-tree symlink.

Create `/srv/intermediate/vendor-microg/prebuilts/` if absent before downloading.

Initial contents of `microg-apks.txt` (verify URLs against the current state of the upstream repos before writing — the microG GmsCore project on GitHub publishes signed APKs on its Releases page, and F-Droid + Aurora publish through their own channels):

```
# format: <local filename>  <url>  <sha256, or 'SKIP' to skip verification>
GmsCore.apk     https://github.com/microg/GmsCore/releases/download/v0.3.15.250932/com.google.android.gms-250932030.apk     SKIP
Companion.apk   https://github.com/microg/GmsCore/releases/download/v0.3.15.250932/com.android.vending-84022630.apk         SKIP
FDroid.apk      https://f-droid.org/F-Droid.apk                                                                              SKIP
AuroraStore.apk https://auroraoss.com/downloads/AuroraStore/Stable/AuroraStore-4.7.1.apk                                     SKIP
```

The default `SKIP` is so the build doesn't break when versions get bumped upstream. Add a `--strict` mode to the script that fails on `SKIP`. Document in the README that users wanting reproducibility should pin sha256s themselves.

If any download URL is no longer valid at script-creation time, fall back to documenting the issue in `README.md` under "Known issues" rather than crashing.

### `20-stage-vendor-microg.sh`

Writes all generated `vendor/microg` content into `/srv/intermediate/vendor-microg/`, then exposes it to the source tree via a single symlink. Nothing is written directly into `/srv/src/vendor/microg/`.

Specifically, the script generates these files under `/srv/intermediate/vendor-microg/`:

- `Android.mk` — declares four `BUILD_PREBUILT` modules: `GmsCore`, `Companion`, `FDroid`, `AuroraStore`. For `GmsCore` and `Companion`, use `LOCAL_CERTIFICATE := platform` (this is what makes microG's signature spoofing work cleanly — they get signed with the build's platform key, and LineageOS's framework grants spoof permission to platform-signed apps). For `FDroid` and `AuroraStore`, use `LOCAL_CERTIFICATE := PRESIGNED` (keep the upstream developer signatures intact). All four are `LOCAL_PRIVILEGED_MODULE := true` and `LOCAL_PRODUCT_MODULE := true`. Each module's `LOCAL_SRC_FILES` points to `prebuilts/<filename>`, which is populated by step 10.
- `microg.mk` — adds those four modules to `PRODUCT_PACKAGES` and grants the `FAKE_PACKAGE_SIGNATURE` permission to `com.google.android.gms` via `PRODUCT_COPY_FILES` of a privapp-permissions XML.
- `AndroidProducts.mk` — auto-discovered by `build/envsetup.sh` under `vendor/*`, this registers the wrapper product (`treble_arm64_microg`) and its lunch combos. Per AOSP convention it may only reference `$(LOCAL_DIR)` and must not use conditionals.
- `treble_arm64_microg.mk` — the wrapper product itself. `inherit-product`s `device/phh/treble/lineage.mk` (the per-variant Treble product makefile produced by `generate.sh`), then `inherit-product`s `vendor/microg/microg.mk`, then sets `PRODUCT_NAME := treble_arm64_microg`. This is the linchpin that lets us combine the upstream Treble product with our microG package set without touching any repo-managed file. The wrapper name deliberately omits the variant suffix (`bvN` / `bgN` / …) because only `arm64` is genuinely fixed for this pipeline — the inherited `lineage.mk` reflects whatever `generate.sh` emitted for the current `VARIANT`. See section 30 below for the design rationale.
- `permissions/privapp-permissions-com.google.android.gms.xml` — created inline in the script.
- `prebuilts/` — this subdirectory is already populated by step 10; the script must not clobber it, only ensure it exists.

After writing those files, the script creates the source-tree symlink idempotently:

```bash
ln -sfn /srv/intermediate/vendor-microg /srv/src/vendor/microg
```

Use `ln -sfn` so re-runs don't fail if the symlink already exists.

Because every file written here is small and produced via clobbering `cat > …`, the script intentionally **does not use a sentinel** — it just rewrites everything every run. That keeps the staged content in lockstep with whatever the current script emits, even after the script itself is updated.

### `30-patch-treble-product.sh` *(eliminated — see step 20)*

> **Decision recorded:** Option A from the original design note was chosen. There is no `30-patch-treble-product.sh` script; the integration is achieved declaratively by the `AndroidProducts.mk` wrapper written in step 20.
>
> **Why not the alternatives:**
>
> - **Naïve `sed` patch into `device/phh/treble/lineage.mk`** — that file is regenerated by `generate.sh` (a repo-managed script) on every build, so the patch would have to be re-applied after step 50 generates the source tree. Fragile, and a known anti-pattern for this kind of injection.
> - **Option B (`PRODUCT_PACKAGES+=` on the make command line)** — Kati's handling of command-line product-config variables is less reliable than makefile inheritance, and `microg.mk` does more than just `PRODUCT_PACKAGES` (it also has `PRODUCT_COPY_FILES` for the privapp-permissions XML), so the override would have to be repeated for each variable.
> - **Option C (patch `generate.sh` via `lineage_patches_unified`)** — still modifies a repo-managed file (one level removed), and adds yet another patch to the `lineage_patches_unified` pile that step 50 already calls out as a known source of intermittent failures.
>
> **How Option A works in practice:**
>
> 1. Step 20 writes `vendor/microg/AndroidProducts.mk`, which is auto-discovered by `source build/envsetup.sh` under any `vendor/*`. It declares the wrapper lunch combos.
> 2. Step 20 also writes `vendor/microg/treble_arm64_microg.mk`, which `inherit-product`s `device/phh/treble/lineage.mk` and `vendor/microg/microg.mk`, then sets `PRODUCT_NAME := treble_arm64_microg`.
> 3. Step 50 runs `device/phh/treble/generate.sh lineage` (so `lineage.mk` exists), then `lunch treble_arm64_microg-userdebug`, then `make`. The wrapper picks up whatever `lineage.mk` `generate.sh` produced for the current variant.
>
> No repo-managed file is ever modified. The wrapper name omits the variant suffix (`bvN` / `bgN` / …) on purpose — `arm64` is the only part genuinely fixed for this pipeline, and the inherited `lineage.mk` floats with `VARIANT`.

### `40-generate-keys.sh`

Idempotent. If `/srv/keys/releasekey.pk8` exists, skip and announce "reusing existing keys from /srv/keys" — do nothing else. Key material is the only concern of this script; staging into the source tree is handled by step 45.

Otherwise generate the full LineageOS 20 key set. From the LineageOS wiki — the canonical list of certs needed for a lineage-20 build is:

```
bluetooth cyngn-app media networkstack nfc platform releasekey sdk_sandbox shared testcert testkey verity
```

For each, run `./development/tools/make_key /srv/keys/<cert> "$SUBJECT"` from `/srv/src/`, where `$SUBJECT` comes from `/opt/pipeline/config/cert-subject.txt`. Press Enter twice (empty passphrase) for each — implement this via `expect`, or by piping `"\n\n"`, or by running `make_key` with `</dev/null` after editing it to default to no password. (`make_key` reads the password interactively; the standard workaround is `( \n\n ) | ./development/tools/make_key ...`.)

LineageOS 19.1+ also requires APEX keys to be 4096-bit instead of the default 2048-bit. After generating the standard set, create a copy of `make_key` with `sed -i 's|2048|4096|g'` and use it to generate APEX-specific keys if the unified build calls for them. Check the build output — if it fails on missing APEX keys, the user can re-run with a flag to regenerate. For a first version, generate the standard 11 keys above; flag APEX as a known follow-up in README.

### `45-stage-vendor-keys.sh`

Sets up the `vendor/lineage-priv/keys/` path that the build system expects, using `/srv/intermediate/lineage-priv/` as the staging area. This script always runs in full (no early-exit sentinel), because the intermediate directory may have been wiped by `CLEAN=1` even when `/srv/keys/` still contains valid keys.

Steps:

1. Create `/srv/intermediate/lineage-priv/` if absent.
2. Write `Android.mk` and `keys.mk` into `/srv/intermediate/lineage-priv/` if they don't already exist. The LineageOS wiki and the canonical gist show their contents; these files declare the key set for the build system.
3. For each `*.pk8` and `*.x509.pem` in `/srv/keys/`, create a symlink `ln -sf /srv/keys/<file> /srv/intermediate/lineage-priv/<file>` if it doesn't already exist. This keeps private key material exclusively in the host-mounted `/srv/keys/` volume.
4. Symlink the staging directory into the source tree idempotently:
   ```bash
   mkdir -p /srv/src/vendor/lineage-priv
   ln -sfn /srv/intermediate/lineage-priv /srv/src/vendor/lineage-priv/keys
   ```

The result: `/srv/src/vendor/lineage-priv/keys/` resolves to `/srv/intermediate/lineage-priv/`, which contains the generated `Android.mk`/`keys.mk` plus per-file symlinks back into `/srv/keys/`. Private key material never leaves `/srv/keys/`.

### `50-build.sh`

Because the integration uses an `AndroidProducts.mk` wrapper (see step 30 above), this script owns the `generate → lunch → make` sequence explicitly rather than delegating wholesale to `buildbot_unified.sh`. The flow is:

1. `cd /srv/src && source build/envsetup.sh`.
2. Apply the patches under `lineage_patches_unified/` (the part of `buildbot_unified.sh` we still want). The cleanest path is to inspect `buildbot_unified.sh` and lift its patch-application loop into this script verbatim; a stop-gap is to call `buildbot_unified.sh` itself with an early-exit env var or in a mode that only patches, if one exists. If patches fail to apply (a known intermittent issue documented on XDA), log the failing patch path and continue if it's non-critical, or abort if it's critical — capture the exit code, dump the last 200 lines of output on failure, and exit pointing to the log file.
3. `bash device/phh/treble/generate.sh lineage`. This regenerates `device/phh/treble/lineage.mk` for the variant. The wrapper makefile written by step 20 inherits this file by path, so whatever variant `generate.sh` emits is what the wrapper picks up.
4. `lunch treble_arm64_microg-userdebug` (the wrapper combo declared by `vendor/microg/AndroidProducts.mk`).
5. `make -j${NPROC} systemimage` (or the equivalent target — match whatever `buildbot_unified.sh` invokes for a GSI build).

Output of the build will be in `/srv/src/out/target/product/tdgsi_arm64_ab/` (the device name comes from the inherited `device/phh/treble/lineage.mk`, so the wrapper does not change the output directory).

### `60-sign.sh`

After the build produces `system.img`, sign the target files following the LineageOS wiki "Signing builds" page:

1. `make target-files-package otatools` (the unified script may already do this — check).
2. `sign_target_files_apks -o -d /srv/keys out/dist/*-target_files-*.zip /srv/out/signed-target-files.zip`
3. Extract the signed `system.img` from the signed target files zip into `/srv/out/system.img`.

For a GSI specifically, `bacon`-style OTA packaging isn't applicable — the deliverable is just the signed `system.img`. (This is the core thing the lineageos4microg docker container got wrong, and is why we're not using it.)

Also copy `/srv/keys/*.x509.pem` (public certs only — DO NOT copy `.pk8` files) into `/srv/out/certs/` so the user can verify the signed image without exposing the private keys.

### `99-report.sh`

Pretty-print:

- Build start/end time and total duration
- `system.img` absolute path, size, sha256
- Path to `out/certs/`
- Reminder: "private keys are in ./keys/ — back them up if you want to ship OTAs to existing installations"
- Treble Info compatibility note: arm64, A/B, system-as-root, vndk 33

## README.md content

The README should cover, in this order:

1. **What this builds** — one-paragraph summary matching the target output above.
2. **Prerequisites** — Ubuntu 20.04 VM (or compatible), Docker, ≥300 GB free disk, ≥16 GB RAM (32 GB strongly recommended), several hours of build time on first run.
3. **Quick start** — `./build.sh` and what to expect.
4. **Flashing** — sample `fastboot flash system out/system.img` invocation, with a warning about unlocked bootloader requirement and a pointer to the Treble Info app for compatibility checking.
5. **Reusing signing keys** — explain that `./keys/` is preserved between runs and that users who plan to ship signed updates to existing installs MUST back up `./keys/` privately (and never commit it).
6. **Known issues / caveats** — patch application can fail when upstream changes; APEX keys may be needed for some configurations; microG signature spoofing requires LineageOS's framework patch which the `lineage-20-light` source tree should already have but is worth verifying; the unified build branch may be unmaintained relative to current security patches.
7. **Customisation** — pointers to `config/microg-apks.txt` (change versions), `config/cert-subject.txt` (change subject line), and the `VARIANT` env var (change build flavour, e.g. `64GN` for "with GAPPS, no superuser" — but note that bringing back GAPPS defeats the microG purpose).
8. **Acknowledgements** — credit AndyCGYan, microG project, F-Droid, Aurora Store, LineageOS, phhusson/TrebleDroid.

## Things to be careful about

- **Don't commit `keys/`, `src/`, `ccache/`, or `out/` to git.** `.gitignore` must list all four.
- **Don't let the build run as root inside the container.** All work happens as `builder`. The Dockerfile must `chown` `/srv/*` to `builder` at runtime (via the entrypoint, before dropping privileges) since the host mount might come in root-owned on first run.

## Style / quality notes

- Bash scripts use `set -euo pipefail` and `IFS=$'\n\t'`.
- Every script has a one-line `# Purpose:` comment at the top.
- Echo progress markers (e.g. `==> [00/07] Preparing source tree`) so the user can follow what's happening in real time.
- Where you make a non-obvious decision (e.g. "we use `LOCAL_CERTIFICATE := platform` for GmsCore because..."), leave a short comment explaining why.
- Don't introduce dependencies the prompt doesn't already require. No Python, no Node, no Ansible — Bash and standard Unix tools only.

Begin by reading the prompt fully, then sketching the directory structure and dependencies between scripts before writing any file. When you've created everything, run the verification checklist and report the results.