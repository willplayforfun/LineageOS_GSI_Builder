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
│   ├── 20-stage-vendor-microg.sh      # Write vendor/microg/{Android.mk,microg.mk}
│   ├── 30-patch-treble-product.sh     # Hook microg.mk into device/phh/treble/lineage.mk
│   ├── 40-generate-keys.sh            # AOSP key generation (idempotent)
│   ├── 50-build.sh                    # Drives the unified build script
│   ├── 60-sign.sh                     # Sign target files, extract system.img
│   └── 99-report.sh                   # Print final summary
├── config/
│   ├── microg-apks.txt                # URL + sha256 list of APKs to fetch
│   ├── cert-subject.txt               # X.509 subject line for key generation
│   └── local_manifests/               # Any extra .xml local_manifests (initially empty)
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
3. Create `src/`, `ccache/`, `keys/`, `out/` directories if absent.
4. `docker run --rm -it` the image, mounting those four dirs to `/srv/src`, `/srv/ccache`, `/srv/keys`, `/srv/out` respectively, calling `/opt/pipeline/entrypoint.sh`.
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
- Clone (or `git pull`) into `/srv/src/lineage_build_unified` from `https://github.com/AndyCGYan/lineage_build_unified` branch `lineage-20-light`.
- Clone (or `git pull`) into `/srv/src/lineage_patches_unified` from `https://github.com/AndyCGYan/lineage_patches_unified` branch `lineage-20-light`.
- Copy any `*.xml` files from `/opt/pipeline/config/local_manifests/` into `/srv/src/.repo/local_manifests/` (the dir must exist; create if missing).
- Unless `SKIP_SYNC=1`: `repo sync -j${NPROC} --force-sync --no-tags --no-clone-bundle --optimized-fetch`.

### `10-fetch-microg.sh`

Reads `/opt/pipeline/config/microg-apks.txt`. Each line is `<filename> <url> <sha256>`. For each entry, if `/srv/src/vendor/microg/prebuilts/<filename>` is absent or has wrong sha256, download and verify.

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

Creates `/srv/src/vendor/microg/Android.mk` and `/srv/src/vendor/microg/microg.mk`.

`Android.mk` declares four `BUILD_PREBUILT` modules: `GmsCore`, `Companion`, `FDroid`, `AuroraStore`. For `GmsCore` and `Companion`, use `LOCAL_CERTIFICATE := platform` (this is what makes microG's signature spoofing work cleanly — they get signed with the build's platform key, and LineageOS's framework grants spoof permission to platform-signed apps). For `FDroid` and `AuroraStore`, use `LOCAL_CERTIFICATE := PRESIGNED` (keep the upstream developer signatures intact). All four are `LOCAL_PRIVILEGED_MODULE := true` and `LOCAL_PRODUCT_MODULE := true`.

`microg.mk` adds those four modules to `PRODUCT_PACKAGES` and grants the `FAKE_PACKAGE_SIGNATURE` permission to `com.google.android.gms` via `PRODUCT_COPY_FILES` of a privapp-permissions XML. Create that XML inline in the script and ship it under `/srv/src/vendor/microg/permissions/privapp-permissions-com.google.android.gms.xml`.

### `30-patch-treble-product.sh`

This runs **after** the unified build script's `generate.sh` (so the file exists), but **before** the actual `make` invocation. Easiest implementation: don't try to interleave — instead, prepend an `$(call inherit-product, vendor/microg/microg.mk)` line to `/srv/src/device/phh/treble/lineage.mk` using `grep -q` to check for an existing line and `sed -i` to add it idempotently.

Since `device/phh/treble/lineage.mk` is generated by the unified build's `generate.sh`, this script needs to run `generate.sh` itself first (it's in `device/phh/treble/`, takes `lineage` as its argument) **before** patching. The unified buildbot script will regenerate it during step 50, so add the inherit line a second time after that, or — cleaner — replace step 50's call to `buildbot_unified.sh` with a manual sequence that splits "patch + generate" from "lunch + make".

Document the chosen approach in a comment at the top of the file.

### `40-generate-keys.sh`

Idempotent. If `/srv/keys/releasekey.pk8` exists, skip and announce "reusing existing keys from /srv/keys".

Otherwise generate the full LineageOS 20 key set. From the LineageOS wiki — the canonical list of certs needed for a lineage-20 build is:

```
bluetooth cyngn-app media networkstack nfc platform releasekey sdk_sandbox shared testcert testkey verity
```

For each, run `./development/tools/make_key /srv/keys/<cert> "$SUBJECT"` from `/srv/src/`, where `$SUBJECT` comes from `/opt/pipeline/config/cert-subject.txt`. Press Enter twice (empty passphrase) for each — implement this via `expect`, or by piping `"\n\n"`, or by running `make_key` with `</dev/null` after editing it to default to no password. (`make_key` reads the password interactively; the standard workaround is `( \\n\\n ) | ./development/tools/make_key ...`.)

LineageOS 19.1+ also requires APEX keys to be 4096-bit instead of the default 2048-bit. After generating the standard set, create a copy of `make_key` with `sed -i 's|2048|4096|g'` and use it to generate APEX-specific keys if the unified build calls for them. Check the build output — if it fails on missing APEX keys, the user can re-run with a flag to regenerate. For a first version, generate the standard 11 keys above; flag APEX as a known follow-up in README.

After generation, symlink (or copy) `/srv/keys` into `/srv/src/vendor/lineage-priv/keys/` so the build system finds them. (`vendor/lineage-priv/keys/` is the LineageOS-conventional location.)

Also create `/srv/src/vendor/lineage-priv/keys/Android.mk` and `keys.mk` declaring the keys — the LineageOS wiki and the gist linked in research show the canonical contents. Generate these files if missing.

### `50-build.sh`

`cd /srv/src && source build/envsetup.sh`. Then invoke the unified build with the chosen variant — equivalent to:

```
bash lineage_build_unified/buildbot_unified.sh treble ${VARIANT} nosync
```

(Pass `nosync` since sync already happened in step 00.)

If patches in `lineage_patches_unified` fail to apply (a known intermittent issue documented on XDA), log the failing patch path and continue if it's non-critical, or abort if it's critical. A simple approach: capture exit code, and if non-zero, dump the last 200 lines of build output and exit with an error message pointing to the log file.

Output of the build will be in `/srv/src/out/target/product/tdgsi_arm64_ab/`.

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

- **Don't commit `keys/`, `src/`, `ccache/`, or `out/` to git.** `.gitignore` must list all four. The user's signing keys live in `keys/` and must never leak.
- **`make_key` is interactive.** It WILL hang waiting for input if you don't pipe empty passphrases to it. Test this in `40-generate-keys.sh`.
- **The `lineage-20-light` branch may not exist forever.** Hard-code a known-good commit SHA as a fallback in `00-prep-source.sh`, with a comment explaining where it came from.
- **Don't let the build run as root inside the container.** All work happens as `builder`. The Dockerfile must `chown` `/srv/*` to `builder` at runtime (via the entrypoint, before dropping privileges) since the host mount might come in root-owned on first run.
- **Use shellcheck on every shell script** before declaring the repo finished. Fix all warnings.
- **Don't try to actually run the build.** It would take 4–8 hours minimum and >250 GB disk. Just verify the repo's logic is sound by lint and static checks.

## Verification you must do before declaring done

1. `shellcheck -x build.sh docker/entrypoint.sh scripts/*.sh` — must pass with no errors.
2. `docker build -t lineage20-gsi-microg:latest -f docker/Dockerfile docker/` — must succeed.
3. `hadolint docker/Dockerfile` if available — should pass with no errors above `info` level.
4. Confirm `.gitignore` covers `src/`, `ccache/`, `out/`, `keys/`, and any `.swp`/`.DS_Store` cruft.
5. Run `git init && git add -A && git status` — confirm only the intended files are staged. No APKs, no keys, no source tree.

## Style / quality notes

- Bash scripts use `set -euo pipefail` and `IFS=$'\n\t'`.
- Every script has a one-line `# Purpose:` comment at the top.
- Echo progress markers (e.g. `==> [00/07] Preparing source tree`) so the user can follow what's happening in real time.
- Where you make a non-obvious decision (e.g. "we use `LOCAL_CERTIFICATE := platform` for GmsCore because..."), leave a short comment explaining why.
- Don't introduce dependencies the prompt doesn't already require. No Python, no Node, no Ansible — Bash and standard Unix tools only.

Begin by reading the prompt fully, then sketching the directory structure and dependencies between scripts before writing any file. When you've created everything, run the verification checklist and report the results.