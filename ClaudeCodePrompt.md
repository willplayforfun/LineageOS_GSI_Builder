# Task: Build a Dockerised pipeline for LineageOS 20 GSI with microG

Set this repository so that, when invoked with a single shell command, it produces a signed LineageOS 20 GSI (Generic System Image) for arm64 with microG and FLOSS app replacements pre-installed. The whole pipeline must run inside Docker so the host Ubuntu 20.04 VM stays clean. Do **not** start the build — only produce the repository and verify it's syntactically valid (shellcheck, hadolint, etc., where applicable).

## Target output

A sparse Android image suitable for flashing to the `system` partition of any Treble-compliant arm64 device with an unlocked bootloader. Build characteristics:

- **Base**: LineageOS 20 (Android 13)
- **Architecture**: arm64
- **Partition scheme**: AB / system-as-root
- **GAPPS**: none (`v` = vanilla)
- **Superuser**: none (`N`)
- **Equivalent to**: AndyCGYan's `64VN` target on the `lineage-20-td` branch, plus microG GmsCore, microG Companion (FakeStore), F-Droid, and Aurora Store as pre-installed privileged apps
- **Signed**: with self-generated release keys (or reused keys from a prior run)

## Inputs and outputs the pipeline must handle

The user will invoke the build with a command roughly like:

```
./build.sh
```

from the repository root. 

## `build.sh` (host entrypoint)

Responsibilities:

1. Resolve `HOST_UID=$(id -u)` and `HOST_GID=$(id -g)`. Pass them as `--build-arg`s when running `docker build`, so the container's `builder` user matches the host user.
2. `docker build` the image (tag: `lineage20-gsi-microg:latest`).
3. Create `src/`, `ccache/`, `keys/`, `intermediate/`, `out/` directories if absent.
4. `docker run --rm -it` the image, mounting all five dirs — `src` → `/srv/src`, `ccache` → `/srv/ccache`, `keys` → `/srv/keys`, `intermediate` → `/srv/intermediate`, `out` → `/srv/out` — then calling `/opt/pipeline/entrypoint.sh`.
5. Accept these optional environment variables / CLI flags, with sensible defaults:
   - `NPROC` (default: `$(nproc)`)
   - `SKIP_SYNC=1` to use local-only `repo sync` (`repo sync -l`, no network) — still resets working trees to manifest revision, which is essential for re-runnable patch application. A true "no sync at all" mode would leave projects post-patch and break step 50's idempotency.
   - `CLEAN=1` to wipe the `out/` and `intermediate/` dirs before running
   - `VARIANT` (default: `64VN` — keep it parameterised in case the user later wants `64GN` etc.)

## `docker/entrypoint.sh`

Runs as `builder`. Sources `/etc/profile`, then executes the numbered scripts in order:

```
exec /opt/pipeline/scripts/00-prep-source.sh
# ... and so on
```

Each script must be **idempotent** and **resumable**: if its output already exists and looks correct, it skips its work. Use sentinel files (e.g. `/srv/intermediate/.stage-00-done`) to mark completion.

## Style / quality notes

- Bash scripts use `set -euo pipefail` and `IFS=$'\n\t'`.
- Every script has a one-line `# Purpose:` comment at the top.
- Echo progress markers (e.g. `==> [00/07] Preparing source tree`) so the user can follow what's happening in real time.
- Where you make a non-obvious decision (e.g. "we use `LOCAL_CERTIFICATE := platform` for GmsCore because..."), leave a short comment explaining why.
- Don't introduce dependencies the prompt doesn't already require. No Python, no Node, no Ansible — Bash and standard Unix tools only.

### Comment style

- **Scope: describe what's in front of you, not what surrounds it.** Comments and error messages should describe the current script's behaviour or the broken pre-condition — not which step number is responsible, not what a downstream step will do with the output, not why a prior approach was abandoned.
- **Stop at the rule, not the mechanism.** State the consequence or invariant ("always expands correctly regardless of IFS"). Only go deeper if the mechanism itself is what's surprising (e.g. a tool that always exits 1 even on success, a bash function masquerading as a binary).
- **Keep comments that prevent "fixing" correct-but-odd code; cut comments that annotate obvious code.** If a reader would misread the code as broken and try to change it, the comment earns its place. If the comment just restates what the code already says or adds "nice to know" context, cut it.
- **Procedures belong in the README.** Inline comments are not the place for flash instructions, fallback recipes, or step-by-step escape hatches. A brief description of *what* something does is fine; a tutorial on *how to use it* is not.

Begin by reading the prompt fully, then sketching the directory structure and dependencies between scripts before writing any file. When you've created everything, run the verification checklist and report the results.