#!/usr/bin/env bash
# Runs as root. Fixes bind-mount ownership (host dirs may be root-owned if the
# build was previously invoked with sudo), then drops to the builder user.
set -euo pipefail

# Chown every top-level entry under /srv EXCEPT any that live on a read-only
# filesystem (e.g. /srv/boot_img mounted with :ro). chown on a read-only mount
# would error out and abort the container under `set -e`; we want those mounts
# left exactly as-is since the pipeline reads from them but never writes.
for entry in /srv/*; do
    [[ -e "${entry}" ]] || continue
    # `findmnt -no OPTIONS` returns the mount options if entry is a mountpoint,
    # empty otherwise. Skip the chown when 'ro' is in the options.
    opts="$(findmnt -no OPTIONS --target "${entry}" 2>/dev/null || true)"
    if [[ ",${opts}," == *,ro,* ]]; then
        echo "fix-perms: skipping ${entry} (read-only mount)"
        continue
    fi
    chown -R builder:builder "${entry}"
done

exec runuser -u builder -- /opt/pipeline/entrypoint.sh "$@"
