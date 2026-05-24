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

# We bypass /usr/local/bin/fix-perms-entrypoint.sh because it hardcodes
# `exec runuser -u builder -- /opt/pipeline/entrypoint.sh "$@"`, which would
# just launch the build pipeline. Instead, run the container as root with bash
# as the entrypoint and do the chown + runuser inline, exec'ing our cmd[@] at
# the end.

if [[ "${ROOT}" == "1" ]]; then
    # Root shell — skip chown. Fast in, no ownership pass over /srv.
    echo "==> Entering container as root (no chown) ..."
    exec docker run "${docker_flags[@]}" "${mounts[@]}" \
        --entrypoint /bin/bash \
        -u 0 \
        -w /srv/src \
        "${IMAGE}" \
        -c 'exec "$@"' -- "${cmd[@]}"
fi

# Default path: enter as root, chown /srv (mirroring fix-perms-entrypoint.sh),
# then drop to builder via runuser and exec the requested command.
echo "==> Entering container as builder (chowning /srv first — may take a moment) ..."
exec docker run "${docker_flags[@]}" "${mounts[@]}" \
    --entrypoint /bin/bash \
    -u 0 \
    "${IMAGE}" \
    -c 'chown -R builder:builder /srv && cd /srv/src && exec runuser -u builder -- "$@"' \
    -- "${cmd[@]}"
