#!/usr/bin/env bash
# Purpose: Initialise and sync the LineageOS repo source tree. Two-sync flow:
# first sync pulls the base tree + lineage_*_unified; we then extract the
# upstream treble manifest from lineage_build_unified at the pinned SHA via
# `git show`, generate zz-commit-pins.xml from config/pins.yaml, and second-sync
# to pull the treble-specific projects and apply the pins. Finally reports
# pin drift vs upstream.

set -euo pipefail
IFS=$'\n\t'

echo "==> [00] Preparing LineageOS source tree"

SRC_DIR="/srv/src"
MANIFESTS_SRC="/opt/pipeline/config/local_manifests"
MANIFESTS_DST="${SRC_DIR}/.repo/local_manifests"
# Bash array (not a string) — we run with `IFS=$'\n\t'` which excludes space,
# so word-splitting on a single-string command wouldn't produce separate argv
# elements. `"${PINS_TOOL[@]}"` always expands correctly regardless of IFS.
PINS_TOOL=(python3 /opt/pipeline/scripts/pins-tool.py)

LINEAGE_URL="https://github.com/LineageOS/android.git"
LINEAGE_BRANCH="lineage-20.0"
# Fallback: if the branch HEAD is broken, replace LINEAGE_BRANCH above with a
# known-good full commit SHA from https://github.com/LineageOS/android/commits/lineage-20.0

NPROC="${NPROC:-$(nproc)}"
SKIP_SYNC="${SKIP_SYNC:-0}"

cd "${SRC_DIR}"

# Shared sync invocation. With SKIP_SYNC=1 we drop to `repo sync -l` (local-
# only, no fetch) rather than skipping entirely — this still checks out each
# project at its manifest revision, which is what undoes the previous run's
# patch commits and gives apply_patches.sh a clean base to work from. A true
# skip would leave projects post-patch and break idempotency of step 50.
run_repo_sync() {
    if [[ "${SKIP_SYNC}" == "1" ]]; then
        repo sync -l --force-sync
    else
        repo sync \
            -j"${NPROC}" \
            --force-sync \
            --no-tags \
            --no-clone-bundle \
            --optimized-fetch \
            --retry-fetches=3
    fi
}

# ─── repo init ───────────────────────────────────────────────────────────────
if [[ ! -d "${SRC_DIR}/.repo" ]]; then
    echo "  -> Initialising repo (branch: ${LINEAGE_BRANCH}) ..."
    repo init \
        -u "${LINEAGE_URL}" \
        -b "${LINEAGE_BRANCH}" \
        --git-lfs \
        --no-repo-verify
    echo "  -> repo init complete."
else
    echo "  -> .repo already present — skipping init."
fi

mkdir -p "${MANIFESTS_DST}"

# ─── Local manifests: committed XMLs ─────────────────────────────────────────
# Copy every committed local manifest (today: andycgyan-unified.xml) from the
# pipeline config dir into .repo/local_manifests/. zz-commit-pins.xml and
# upstream-treble.xml are NOT committed — they're produced below after the
# first sync.
echo "  -> Installing committed local manifests ..."
shopt -s nullglob
xmls=("${MANIFESTS_SRC}"/*.xml)
shopt -u nullglob

if [[ ${#xmls[@]} -eq 0 ]]; then
    echo "  WARNING: no *.xml files found in ${MANIFESTS_SRC}" >&2
else
    for xml in "${xmls[@]}"; do
        dest="${MANIFESTS_DST}/$(basename "${xml}")"
        if [[ -f "${dest}" ]] && diff -q "${xml}" "${dest}" > /dev/null 2>&1; then
            echo "     Up-to-date: $(basename "${xml}")"
        else
            cp "${xml}" "${dest}"
            echo "     Installed:  $(basename "${xml}")"
        fi
    done
fi

# ─── First repo sync ─────────────────────────────────────────────────────────
# Pulls the default LineageOS tree plus the two projects declared by
# andycgyan-unified.xml (lineage_build_unified, lineage_patches_unified).
# Doesn't yet apply pins (zz-commit-pins.xml not generated) or pull
# treble-specific projects (upstream-treble.xml not installed) — both happen
# in the second sync below.
if [[ "${SKIP_SYNC}" == "1" ]]; then
    echo "  -> SKIP_SYNC=1: first sync is local-only (working-tree reset, no fetch)."
else
    echo "  -> First sync (base tree + lineage_*_unified) with ${NPROC} jobs ..."
    echo "     First run: expect several hours and ~250 GB of disk usage."
fi
run_repo_sync
echo "  -> First sync complete."

# ─── Extract upstream treble manifest at the pinned SHA ──────────────────
# After the first sync, lineage_build_unified is on disk with its full branch
# history. `git show <SHA>:path` extracts the file at the pinned commit —
# regardless of where the working-tree HEAD landed — so the manifest is
# deterministic against the pin and not against whatever default-branch tip
# the sync happened to fetch. Single transport (git), content-addressed by
# the pin SHA.
PIN_LBU=$("${PINS_TOOL[@]}" field "lineage_build_unified" revision)
UPSTREAM_TREBLE_FILE="${MANIFESTS_DST}/upstream-treble.xml"

LBU_DIR="${SRC_DIR}/lineage_build_unified"
if [[ ! -d "${LBU_DIR}/.git" && ! -f "${LBU_DIR}/.git" ]]; then
    echo "ERROR: ${LBU_DIR} is not a git working tree." >&2
    echo "       The first sync must complete before upstream-treble.xml can be extracted." >&2
    echo "       If you set SKIP_SYNC=1, run once without it first." >&2
    exit 1
fi

echo "  -> Extracting upstream-treble.xml from lineage_build_unified at ${PIN_LBU:0:7} ..."
if ! git -C "${LBU_DIR}" show "${PIN_LBU}:local_manifests_treble/manifest.xml" \
        > "${UPSTREAM_TREBLE_FILE}.tmp" 2>/dev/null; then
    echo "ERROR: git show ${PIN_LBU}:local_manifests_treble/manifest.xml failed." >&2
    echo "       The pinned SHA may not be reachable from the synced branch." >&2
    rm -f "${UPSTREAM_TREBLE_FILE}.tmp"
    exit 1
fi
mv "${UPSTREAM_TREBLE_FILE}.tmp" "${UPSTREAM_TREBLE_FILE}"

# ─── Generate zz-commit-pins.xml from pins.yaml ──────────────────────────────
# Single source of truth for pinned revisions; pins-tool.py emits the
# repo-manifest form. Regenerated every run so a pins.yaml edit takes effect
# on the next ./build.sh.
#
# The "zz-" prefix is load-bearing: repo processes .repo/local_manifests/*.xml
# in alphabetical order, and our <remove-project> entries require the target
# project to already be declared — which means this file MUST sort after both
# andycgyan-unified.xml (declares lineage_*_unified) AND upstream-treble.xml
# (declares TrebleDroid/vendor_hardware_overlay).
#
# One-time migration: clean up older filenames this manifest used to live at.
rm -f "${MANIFESTS_DST}/commit-pins.xml" "${MANIFESTS_DST}/zz-pins.xml"

echo "  -> Generating zz-commit-pins.xml from config/pins.yaml ..."
"${PINS_TOOL[@]}" generate-manifest > "${MANIFESTS_DST}/zz-commit-pins.xml"

# ─── Second repo sync ────────────────────────────────────────────────────────
# Now that both upstream-treble.xml and zz-commit-pins.xml are in place, this
# sync resets the pinned projects to their pinned SHAs and pulls the
# treble-specific projects declared by the upstream manifest (device/lineage/gsi,
# vendor/hardware_overlay, packages/apps/QcRilAm, vendor/gapps). Incremental
# for projects already cloned by the first sync — fast.
if [[ "${SKIP_SYNC}" == "1" ]]; then
    echo "  -> SKIP_SYNC=1: second sync is local-only (apply pins to working tree, no fetch)."
else
    echo "  -> Second sync (apply pins, pull treble-specific projects) ..."
fi
run_repo_sync
echo "  -> Second sync complete."

# ─── Pin drift check ─────────────────────────────────────────────────────────
# Iterates over every entry in pins.yaml — adding a pin is a config-only
# change. For each, query the upstream branch HEAD and compare to the pinned
# SHA. Purely an awareness signal; pins stay in effect until manually bumped.
check_pin_drift() {
    local project_subpath="$1"
    local pinned_sha="$2"
    local upstream_url="$3"
    local tracking_branch="$4"
    local label="$5"

    local remote_head
    remote_head=$(git ls-remote "${upstream_url}" "refs/heads/${tracking_branch}" 2>/dev/null | cut -f1)
    if [[ -z "${remote_head}" ]]; then
        echo "     ${project_subpath}: couldn't query upstream — network issue?"
        return 0
    fi
    if [[ "${pinned_sha}" == "${remote_head}" ]]; then
        echo "     ${project_subpath}: pinned at ${pinned_sha:0:7} (== upstream)"
    else
        local behind
        behind=$(curl -fsSL "https://api.github.com/repos/$(echo "${upstream_url}" \
            | sed 's|https://github.com/||')/compare/${pinned_sha}...${remote_head}" \
            2>/dev/null | grep -m1 '"ahead_by"' | grep -oE '[0-9]+' || true)
        echo "     ${project_subpath}: pinned ${pinned_sha:0:7}, upstream ${remote_head:0:7}${behind:+ (${behind} commits ahead)}"
        echo "          ${label}"
    fi
}

if [[ "${SKIP_SYNC}" == "1" ]]; then
    echo "  -> SKIP_SYNC=1: skipping pin drift check."
else
    echo "  -> Checking pin drift vs upstream ..."
    # `list` emits one TSV row per pin in field order; <(...) avoids the
    # pipeline-subshell trap and keeps `check_pin_drift`'s log output inline.
    while IFS=$'\t' read -r name path remote revision tracking_branch upstream_url category note; do
        check_pin_drift \
            "${path}" "${revision}" "${upstream_url}" "${tracking_branch}" \
            "${category} pin — ${note}"
    done < <("${PINS_TOOL[@]}" list)
fi

touch /srv/intermediate/.stage-00-done
echo "==> [00] Done."
