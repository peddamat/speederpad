#!/usr/bin/env bash
# Build a custom FLSUN Speeder Pad TF-card image with current Klipper.
#
#   sudo ./build.sh            # all stages
#   sudo ./build.sh rootfs     # one stage: extract | modules | rootfs | image
#   BUILD_CONF=my.conf sudo -E ./build.sh
#
# See README.md for requirements and flashing instructions.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

stages=("$@")
[ ${#stages[@]} -eq 0 ] && stages=(extract modules rootfs image)

for s in "${stages[@]}"; do
    case "$s" in
        extract) "$here/scripts/01-extract-vendor.sh" ;;
        modules) "$here/scripts/01b-build-modules.sh" ;;
        rootfs)  "$here/scripts/02-build-rootfs.sh" ;;
        image)   "$here/scripts/03-make-image.sh" ;;
        *) echo "unknown stage '$s' (expected: extract, modules, rootfs, image)" >&2; exit 2 ;;
    esac
done
