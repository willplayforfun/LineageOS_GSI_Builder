#!/usr/bin/env bash
# Runs as root. Fixes bind-mount ownership (host dirs may be root-owned if the
# build was previously invoked with sudo), then drops to the builder user.
set -euo pipefail

chown -R builder:builder /srv

exec runuser -u builder -- /opt/pipeline/entrypoint.sh "$@"
