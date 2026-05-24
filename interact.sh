#!/usr/bin/env bash
# Purpose: Drop into an interactive shell inside the build container, with the
# same mounts/UID setup build.sh uses — for poking at the synced tree, running
# diagnostic greps, or hand-invoking individual pipeline scripts.
#
# Usage:
#   ./interact.sh                  # interactive bash as builder user
#   ./interact.sh -- ls /srv/src   # run a one-off command, then exit
#   ROOT=1 ./interact.sh           # interactive bash as root (skips chown step)
#
# Assumes the image already exists (built by build.sh). Won't rebuild it.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="lineage20-gsi-microg:latest"
ROOT="${ROOT:-0}"

# Args after `--` are passed through as the command runuser/bash will exec.
# With no args, default to an interactive login bash.
if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
fi
if [[ $# -eq 0 ]]; then
    cmd=(/bin/bash)
else
    cmd=("$@")
fi

# ─── Image sanity check ──────────────────────────────────────────────────────
# Avoid Docker's confusing "Unable to find image ... locally" auto-pull attempt
# against Docker Hub for a local-only tag — fail fast with a clear hint.
if ! docker image inspect "${IMAGE}" > /dev/null 2>&1; then
    echo "ERROR: image ${IMAGE} not found locally." >&2
    echo "       Run ./build.sh once to build it (the pipeline can fail later;" >&2
    echo "       the image will still be cached and usable here)." >&2
    exit 1
fi

# ─── Bind mounts mirror build.sh ─────────────────────────────────────────────
# Keep identical so anything you do here is visible to a subsequent ./build.sh
# run (and vice versa).
mounts=(
    -v "${SCRIPT_DIR}/src:/srv/src"
    -v "${SCRIPT_DIR}/ccache:/srv/ccache"
    -v "${SCRIPT_DIR}/keys:/srv/keys"
    -v "${SCRIPT_DIR}/intermediate:/srv/intermediate"
    -v "${SCRIPT_DIR}/out:/srv/out"
)

# Use -it when stdin is a terminal, -i otherwise (e.g. piped one-off commands).
docker_flags=(--rm)
if [[ -t 0 ]]; then
    docker_flags+=(-it)
else
    docker_flags+=(-i)
fi

if [[ "${ROOT}" == "1" ]]; then
    # Root shell — skips fix-perms-entrypoint.sh's chown step. Handy for quickly
    # inspecting things without waiting for chown -R /srv on a large tree.
    echo "==> Entering container as root (no chown) ..."
    exec docker run "${docker_flags[@]}" "${mounts[@]}" \
        --entrypoint /bin/bash \
        -u 0 \
        "${IMAGE}" \
        -c 'cd /srv/src 2>/dev/null || cd /; exec "$@"' -- "${cmd[@]}"
fi

# Default path: go through fix-perms-entrypoint.sh so /srv ownership is sane,
# then drop to the builder user. The entrypoint does
# `exec runuser -u builder -- "$@"` ([docker/fix-perms-entrypoint.sh:8]), so
# our cmd[@] becomes what builder runs.
echo "==> Entering container as builder (chowning /srv first — may take a moment) ..."
exec docker run "${docker_flags[@]}" "${mounts[@]}" \
    --entrypoint /usr/local/bin/fix-perms-entrypoint.sh \
    "${IMAGE}" \
    "${cmd[@]}"
