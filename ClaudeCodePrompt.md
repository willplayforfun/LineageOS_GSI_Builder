# Task: Build a Dockerised pipeline for LineageOS 20 GSI with microG

Set this repository so that, when invoked with a single shell command, it produces a signed LineageOS 20 GSI (Generic System Image) for arm64 with microG and FLOSS app replacements pre-installed. The whole pipeline must run inside Docker so the host Ubuntu 20.04 VM stays clean. Do **not** start the build — only produce the repository and verify it's syntactically valid (shellcheck, hadolint, etc., where applicable).

## Target output

A single `system.img` file (sparse Android image) suitable for flashing to the `system` partition of any Treble-compliant arm64 device with an unlocked bootloader. Build characteristics:

- **Base**: LineageOS 20 (Android 13)
- **Architecture**: arm64
- **Partition scheme**: AB / system-as-root (the `b` in the variant name)
- **GAPPS**: none (`v` = vanilla)
- **Superuser**: none (`N`)
- **Equivalent to**: AndyCGYan's `lineage_gsi_arm64_vN` target on the `lineage-20-light` branch, plus microG GmsCore, microG Companion (FakeStore), F-Droid, and Aurora Store as pre-installed privileged apps
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
│   ├── 20-stage-vendor-microg.sh      # Write vendor/microg/{Android.mk,microg.mk,AndroidProducts.mk,lineage_gsi_arm64_vN_microg.mk}
│   ├── 40-generate-keys.sh            # AOSP key generation into /srv/keys (idempotent)
│   ├── 45-stage-vendor-keys.sh        # Build intermediate/lineage-priv, symlink into src
│   ├── 50-build.sh                    # Apply patches, lunch the microG wrapper, make target-files-package + otatools
│   ├── 55-generate-apex-keys.sh       # Discover APEXes in target files; mint 4096-bit keys on demand
│   ├── 60-sign.sh                     # Sign target files (incl. APEXes), extract system.img
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
- After the first sync, **bootstrap the upstream treble manifest**: `lineage_build_unified/local_manifests_treble/manifest.xml` declares the treble-specific projects (`device/lineage/gsi`, `vendor/hardware_overlay`, `packages/apps/QcRilAm`, `vendor/gapps`). Mirror that file into `.repo/local_manifests/upstream-treble.xml` (only if it differs from what's already there), then run a second `repo sync` to pull those new projects. Subsequent runs skip the resync because the mirror already matches. This tracks upstream automatically — we don't commit a copy of AndyCGYan's manifest into our own repo. Same skip semantics as the first sync under `SKIP_SYNC=1`.

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

### Revision pinning (`config/local_manifests/zz-pins.xml`)

Three projects are pinned to specific SHAs rather than tracking their default branches. The pin file is named `zz-*` so it loads alphabetically last in `.repo/local_manifests/`, after `andycgyan-unified.xml` and the bootstrapped `upstream-treble.xml` — meaning its `<project>` entries override theirs.

Pin tiers:

1. **Archival** — `lineage_patches_unified` and `lineage_build_unified`. AndyCGYan's `lineage-20-light` branch has had no commits since Nov 2023; the pins record current HEAD. Won't drift in practice but pinning is explicit.
2. **Frozen** — `TrebleDroid/vendor_hardware_overlay` at `1bbceba` (Nov 17 2023). Upstream is still active, but every commit since this SHA is device-specific runtime resource overlays we don't use. Freezing keeps AndyCGYan's bridge patches applicable without ongoing maintenance — specifically, it stops the "Exclude-TrebleApp" patch's trailing context from drifting.

LineageOS-side projects are *not* pinned by default. They receive monthly security updates, and AndyCGYan's bridge patches generally survive LineageOS churn via `apply_patches.sh`'s fuzz fallback. Add a pin in `zz-pins.xml` only if a specific project's patches start failing in step 50.

The pin drift check at the end of step 00 queries upstream HEAD for each pinned project via `git ls-remote` and prints whether each pin is up-to-date or behind. The SHAs in step 00's drift check must stay in sync with `zz-pins.xml` — bump both when advancing a pin.

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
- `AndroidProducts.mk` — auto-discovered by `build/envsetup.sh` under `vendor/*`, this registers the wrapper product (`lineage_gsi_arm64_vN_microg`) and its lunch combos. Per AOSP convention it may only reference `$(LOCAL_DIR)` and must not use conditionals.
- `lineage_gsi_arm64_vN_microg.mk` — the wrapper product itself. `inherit-product`s `device/lineage/gsi/lineage_gsi_arm64_vN.mk` (AndyCGYan's per-variant lineage GSI base product, brought in by the unified manifest), then `inherit-product`s `vendor/microg/microg.mk`, then sets `PRODUCT_NAME := lineage_gsi_arm64_vN_microg`. This is the linchpin that lets us combine the upstream lineage GSI product with our microG package set without touching any repo-managed file. The variant suffix is part of the name because the upstream `lineage_gsi_arm64_{vN,vS,gN}.mk` files are statically variant-specific — to support a different variant later, add a second wrapper inheriting the corresponding base. See section 30 below for the design rationale.
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
> - **Naïve `sed` patch into a repo-managed product makefile** (e.g. `device/lineage/gsi/lineage_gsi_arm64_vN.mk`) — works on first run but re-applying after every `repo sync` / patch refresh is fragile, and any conflict with upstream changes silently breaks the microG injection.
> - **Option B (`PRODUCT_PACKAGES+=` on the make command line)** — Kati's handling of command-line product-config variables is less reliable than makefile inheritance, and `microg.mk` does more than just `PRODUCT_PACKAGES` (it also has `PRODUCT_COPY_FILES` for the privapp-permissions XML), so the override would have to be repeated for each variable.
> - **Option C (patch a repo-managed file via `lineage_patches_unified`)** — still modifies a repo-managed file (one level removed), and adds yet another patch to the `lineage_patches_unified` pile that step 50 already calls out as a known source of intermittent failures.
>
> **How Option A works in practice:**
>
> 1. Step 20 writes `vendor/microg/AndroidProducts.mk`, which is auto-discovered by `source build/envsetup.sh` under any `vendor/*`. It declares the wrapper lunch combos.
> 2. Step 20 also writes `vendor/microg/lineage_gsi_arm64_vN_microg.mk`, which `inherit-product`s `device/lineage/gsi/lineage_gsi_arm64_vN.mk` (AndyCGYan's lineage GSI vanilla/no-su variant, pulled in by the unified manifest) and `vendor/microg/microg.mk`, then sets `PRODUCT_NAME := lineage_gsi_arm64_vN_microg`.
> 3. Step 50 applies the `lineage_patches_unified` patches, then `lunch lineage_gsi_arm64_vN_microg-userdebug`, then `make target-files-package otatools`. The wrapper resolves cleanly because the upstream lineage GSI product makefile is on disk by then.
>
> No repo-managed file is ever modified. The variant suffix is in the wrapper name because the upstream lineage GSI product files are statically per-variant — supporting `vS` or `gN` is a matter of writing a second wrapper that inherits the corresponding base; `gN` (GAPPS) is intentionally excluded because GAPPS conflicts with microG.

### `40-generate-keys.sh`

Idempotent. If `/srv/keys/releasekey.pk8` exists, skip and announce "reusing existing keys from /srv/keys" — do nothing else. Key material is the only concern of this script; staging into the source tree is handled by step 45.

Otherwise generate the full LineageOS 20 key set. From the LineageOS wiki — the canonical list of certs needed for a lineage-20 build is:

```
bluetooth cyngn-app media networkstack nfc platform releasekey sdk_sandbox shared testcert testkey verity
```

For each, run `./development/tools/make_key /srv/keys/<cert> "$SUBJECT"` from `/srv/src/`, where `$SUBJECT` comes from `/opt/pipeline/config/cert-subject.txt`. Press Enter twice (empty passphrase) for each — implement this via `expect`, or by piping `"\n\n"`, or by running `make_key` with `</dev/null` after editing it to default to no password. (`make_key` reads the password interactively; the standard workaround is `( \n\n ) | ./development/tools/make_key ...`.)

LineageOS 19.1+ also requires per-APEX keys at SHA256_RSA4096 rather than the default 2048-bit. This script intentionally only handles the standard 12-key set — APEX keys are discovered and generated at build time by [`55-generate-apex-keys.sh`](#55-generate-apex-keyssh) from the unsigned target-files zip's `META/apexkeys.txt`, which lists exactly the APEX modules the current build actually pulls in. That keeps step 40 cheap, stable, and free of any hardcoded APEX list that would rot against upstream churn.

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

Because the integration uses an `AndroidProducts.mk` wrapper (see step 30 above), this script owns the `apply-patches → lunch → make` sequence explicitly rather than delegating wholesale to `buildbot_unified.sh`. The flow is:

1. Apply the `lineage_patches_unified` patches by calling `lineage_build_unified/apply_patches.sh` with the `patches_platform` and `patches_treble` groups. That `apply_patches.sh` runs `git clean -fdx && git reset --hard` on each project before re-applying, so it's safe to invoke on every run — no sentinel needed. This is the same flow `buildbot_unified.sh` uses; we deliberately skip its `repo sync` block (step 00 owns sync) and its `repopick` block (those cherry-picks are not currently required for this build). If patches fail to apply (a known intermittent issue documented on XDA), `apply_patches.sh` exits non-zero and `set -e` propagates the failure — surface it to the user with the path to the failing patch.
2. `cd /srv/src && source build/envsetup.sh`. Sourced after patches in case any patch touches envsetup itself.
3. `lunch lineage_gsi_arm64_vN_microg-userdebug` (the wrapper combo declared by `vendor/microg/AndroidProducts.mk`). The wrapper inherits `device/lineage/gsi/lineage_gsi_arm64_vN.mk` (provided by `AndyCGYan/android_device_lineage_gsi` via the unified manifest) and layers `vendor/microg/microg.mk` on top.
4. `make -j${NPROC} target-files-package otatools`. This produces both the **unsigned** target-files zip under `out/target/product/*/obj/PACKAGING/target_files_intermediates/` (with the `META/apexkeys.txt` manifest step 55 reads) and the `otatools` package containing `sign_target_files_apks` that step 60 calls. Do **not** use `make systemimage` here — we want the target-files form so signing can happen as a separate stage.

Output of the build will be under `/srv/src/out/target/product/lineage_gsi_arm64_vN_microg/` (the wrapper's `PRODUCT_NAME` becomes the output directory). The unsigned `system.img` is also present here, but step 60 produces the signed image we actually ship.

### `55-generate-apex-keys.sh`

The bridge between "build" (step 50) and "sign" (step 60). LineageOS 19.1+ requires every APEX module in the system image to be re-signed with a per-APEX 4096-bit SHA256_RSA key pair (`.pk8` + `.x509.pem` for the container, plus an unwrapped `.pem` for payload signing). The set of APEX modules is build-specific — Android 13's stock set is large, but the PHH treble GSI only ships a subset, and that subset can drift across LineageOS versions. Rather than maintain a static APEX list, this script discovers them dynamically.

Flow:

1. Locate the unsigned target-files zip from step 50's output. Prefer the newest if multiple are present.
2. `unzip -p <zip> META/apexkeys.txt` and parse `name="<module>.apex"` entries. If absent or empty, write an empty `/srv/intermediate/apex-modules.txt` and exit — there are no APEXes to sign.
3. Lazily stage `/srv/intermediate/make_key_4096` if missing: `cp` the in-tree `development/tools/make_key`, then `sed -i 's|2048|4096|g'`. This lives under intermediate (regenerable, not key material) so `CLEAN=1` simply re-creates it.
4. For each APEX module not already present under `/srv/keys/apex/`:
   - Substitute the `/CN=` field of the subject template with the module name (matching the wiki recipe).
   - Run `make_key_4096 /srv/keys/apex/<module> "<subject>" </dev/null` to mint the `.pk8` + `.x509.pem` pair.
   - `openssl pkcs8 -in <module>.pk8 -inform DER -nocrypt -out <module>.pem` to produce the payload-signing key.
5. Write the discovered module list to `/srv/intermediate/apex-modules.txt` so step 60 builds its `sign_target_files_apks` flag set from the same enumeration without re-parsing the zip.

Idempotent: any module whose `.pk8` + `.x509.pem` + `.pem` already exist is skipped, so re-runs reuse keys (essential for OTA stability — fresh APEX keys would orphan existing installs the same way fresh `releasekey` would).

### `60-sign.sh`

Step 50 has already produced the unsigned target-files zip and otatools, and step 55 has minted any APEX keys the build calls for. This script signs the target files, extracts the signed `system.img`, and publishes public certs. Flow:

1. Locate the unsigned target-files zip — same glob step 55 uses, prefer newest.
2. Read `/srv/intermediate/apex-modules.txt` (written by step 55). For each module name, append two flags to the `sign_target_files_apks` invocation:
   ```
   --extra_apks <module>.apex=/srv/keys/apex/<module>
   --extra_apex_payload_key <module>.apex=/srv/keys/apex/<module>.pem
   ```
   Empty file → no flags appended, which is the correct no-APEX behaviour.
3. Per the LineageOS wiki, a handful of APKs (`AdServicesApk`, `FederatedCompute`, `HalfSheetUX`, `HealthConnectBackupRestore`, `HealthConnectController`, `OsuLogin`, `SafetyCenterResources`, `ServiceConnectivityResources`, `ServiceUwbResources`, `ServiceWifiResources`, `WifiDialog`) ship *inside* APEX containers and want their own `--extra_apks <NAME>.apk=/srv/keys/releasekey` flag. These are regular APKs (not APEXes), so they reuse the standard releasekey — they do not need 4096-bit keys.
4. Invoke `sign_target_files_apks -o -d /srv/keys <flags...> <unsigned.zip> /srv/intermediate/signed-target-files.zip`.
5. Extract the signed `system.img` (under `IMAGES/system.img` in the signed zip) to `/srv/out/system.img`.

For a GSI specifically, `bacon`-style OTA packaging isn't applicable — the deliverable is just the signed `system.img`. (This is the core thing the lineageos4microg docker container got wrong, and is why we're not using it.)

Also copy `/srv/keys/*.x509.pem` (public certs only — DO NOT copy `.pk8` files) into `/srv/out/certs/` so the user can verify the signed image without exposing the private keys. The per-APEX public certs in `/srv/keys/apex/*.x509.pem` should also be copied into `/srv/out/certs/apex/` for the same reason.

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
6. **Known issues / caveats** — patch application can fail when upstream changes; microG signature spoofing requires LineageOS's framework patch which the `lineage-20-light` source tree should already have but is worth verifying; the unified build branch may be unmaintained relative to current security patches. (APEX keys are handled automatically by step 55 — no manual intervention needed.)
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