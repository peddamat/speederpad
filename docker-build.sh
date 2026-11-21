#!/usr/bin/env bash
# Run the build inside a Debian container. --privileged is required for the
# chroot mounts and to register the qemu binfmt handler on the host kernel.
#   ./docker-build.sh            # all stages
#   ./docker-build.sh image      # one stage
set -euo pipefail
cd "$(dirname "$0")"
docker build -t speederpad-builder .
env_args=()
for v in $(sed -n 's/^: "\${\([A-Z_]*\):=.*/\1/p' build.conf) BUILD_CONF; do
    [ -n "${!v+x}" ] && env_args+=(-e "$v=${!v}")
done
exec docker run --rm --privileged -v "$PWD":/build "${env_args[@]}" speederpad-builder "$@"
