#!/usr/bin/env bash
# Purpose: Host-side entrypoint — builds the Docker image and runs the pipeline container.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="lineage20-gsi-microg:latest"

# ─── Defaults (all overridable via environment variables) ────────────────────
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
SKIP_SYNC="${SKIP_SYNC:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_SIGNING="${SKIP_SIGNING:-0}"
CLEAN="${CLEAN:-0}"
NPROC="${NPROC:-$(nproc)}"

# ─── CLI flags (override env vars) ───────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-sync)    SKIP_SYNC=1 ;;
        --skip-build)   SKIP_BUILD=1 ;;
        --skip-signing) SKIP_SIGNING=1 ;;
        --clean)        CLEAN=1 ;;
        --nproc=*)      NPROC="${1#--nproc=}" ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 [--skip-sync] [--skip-build] [--skip-signing] [--clean] [--nproc=N]" >&2
            echo ""
            echo "Environment variables (can be set in addition to or instead of flags):"
            echo "  SKIP_SYNC=1     Local-only repo sync (no network; faster iteration after first sync)"
            echo "  SKIP_BUILD=1    Skip steps 50 (make) and 55 (APEX key discovery)"
            echo "  SKIP_SIGNING=1  Skip step 60 (sign_target_files_apks); step 62 still extracts"
            echo "                  images from an existing signed zip in intermediate/"
            echo "  CLEAN=1         Wipe out/ and intermediate/ before starting"
            echo "  NPROC=N         Override parallelism (default: all cores)"
            exit 1
            ;;
    esac
    shift
done

if [[ "${HOST_UID}" == "0" ]]; then
    echo "WARNING: Running build.sh as root is not supported." >&2
    echo "         The container's builder user will have UID 0, which defeats the" >&2
    echo "         purpose of UID matching and may cause permission issues." >&2
fi

# ─── Build Docker image ───────────────────────────────────────────────────────
echo "==> Building Docker image ${IMAGE} ..."
echo "    HOST_UID=${HOST_UID}  HOST_GID=${HOST_GID}"
docker build \
    --build-arg "HOST_UID=${HOST_UID}" \
    --build-arg "HOST_GID=${HOST_GID}" \
    -t "${IMAGE}" \
    -f "${SCRIPT_DIR}/docker/Dockerfile" \
    "${SCRIPT_DIR}"

# ─── Create host directories if absent ───────────────────────────────────────
echo "==> Ensuring host directories exist ..."
for dir in src ccache keys intermediate out boot_img; do
    mkdir -p "${SCRIPT_DIR}/${dir}"
done

# ─── Optionally wipe output dirs ─────────────────────────────────────────────
if [[ "${CLEAN}" == "1" ]]; then
    echo "==> CLEAN=1: wiping out/ and intermediate/ ..."
    # Run cleanup inside the container as root so we can remove files regardless
    # of what UID created them (output files are owned by the container's builder user).
    docker run --rm \
        --entrypoint /bin/bash \
        -u root \
        -v "${SCRIPT_DIR}/out:/srv/out" \
        -v "${SCRIPT_DIR}/intermediate:/srv/intermediate" \
        "${IMAGE}" -c "find /srv/out /srv/intermediate -mindepth 1 -delete"
fi

# ─── Run container ───────────────────────────────────────────────────────────
echo "==> Starting build container ..."
echo "    NPROC=${NPROC}  SKIP_SYNC=${SKIP_SYNC}  SKIP_BUILD=${SKIP_BUILD}  SKIP_SIGNING=${SKIP_SIGNING}"

# Use -it when stdin is a terminal, -i only when piped/redirected (e.g. CI).
docker_flags=(--rm)
if [[ -t 0 ]]; then
    docker_flags+=(-it)
else
    docker_flags+=(-i)
fi

docker run "${docker_flags[@]}" \
    -v "${SCRIPT_DIR}/src:/srv/src" \
    -v "${SCRIPT_DIR}/ccache:/srv/ccache" \
    -v "${SCRIPT_DIR}/keys:/srv/keys" \
    -v "${SCRIPT_DIR}/intermediate:/srv/intermediate" \
    -v "${SCRIPT_DIR}/out:/srv/out" \
    -v "${SCRIPT_DIR}/boot_img:/srv/boot_img:ro" \
    -e "NPROC=${NPROC}" \
    -e "SKIP_SYNC=${SKIP_SYNC}" \
    -e "SKIP_BUILD=${SKIP_BUILD}" \
    -e "SKIP_SIGNING=${SKIP_SIGNING}" \
    "${IMAGE}"
