#!/usr/bin/env bash
# Purpose: In-container orchestrator — exports env vars and runs numbered pipeline scripts.

set -euo pipefail
IFS=$'\n\t'

PIPELINE_DIR="/opt/pipeline"

# Export with two-step assignment to avoid SC2155 (masked return value).
NPROC="${NPROC:-}"
NPROC="${NPROC:-$(nproc)}"
export NPROC

SKIP_SYNC="${SKIP_SYNC:-0}"
export SKIP_SYNC

VARIANT="${VARIANT:-64VN}"
export VARIANT

echo "==> Pipeline starting as $(whoami) (uid=$(id -u), gid=$(id -g))"
echo "    NPROC=${NPROC}  SKIP_SYNC=${SKIP_SYNC}  VARIANT=${VARIANT}"

# Record the build start time so 99-report.sh can compute total duration.
mkdir -p /srv/intermediate
date +%s > /srv/intermediate/.build-start-time

# Run each numbered script in lexicographic (numeric) order.
# Scripts not present in the image are silently skipped — this lets you test
# a subset of the pipeline (e.g. only 00 + 99) without stub scripts.
shopt -s nullglob
scripts=("${PIPELINE_DIR}/scripts"/[0-9][0-9]-*.sh)
shopt -u nullglob

if [[ ${#scripts[@]} -eq 0 ]]; then
    echo "ERROR: no pipeline scripts found in ${PIPELINE_DIR}/scripts/" >&2
    exit 1
fi

for script in "${scripts[@]}"; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running: $(basename "${script}")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bash "${script}"
done

echo ""
echo "==> Pipeline complete."
