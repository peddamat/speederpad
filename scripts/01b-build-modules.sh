#!/usr/bin/env bash
# Stage 1b: build CAN bus kernel modules (can, can-raw, can-bcm, can-dev,
# gs_usb) that load into the stock vendor kernel, so a Klipper USB-to-CAN
# bridge board shows up as can0.
#
# FLSUN publishes no kernel source. Creality's Sonic Pad OS contains the same
# Allwinner/Android-common linux-4.9 (4.9.191) BSP tree, and with the stock
# kernel's own embedded config it reproduces the stock kernel's symbol CRCs.
# Module.symvers is read back out of the stock kernel Image, and every symbol
# the modules import is CRC-checked against a rebuild of the exporting source
# before the modules are accepted.
# Output: work/modules/lib/modules/<release>/kernel/...
. "$(dirname "$0")/lib.sh"
load_config

if [ "$CAN_MODULES" != 1 ]; then
    rm -rf "$MODULES_DIR"
    log "CAN_MODULES=${CAN_MODULES}: not building kernel modules"
    exit 0
fi
[ -f "${STOCK_DIR}/.extract-done" ] || die "run stage 1 (extract) first"

cross=aarch64-linux-gnu-
[ "$(uname -m)" = aarch64 ] && cross=
require_cmds python3 git make gcc bc flex bison "${cross}gcc" "${cross}objcopy" "${cross}nm" "${cross}strip"

KTOOLS="${REPO_DIR}/scripts/kernel_tools.py"
kdir="${WORK_DIR}/kernel"
mkdir -p "$kdir"
boot="$(ls "${STOCK_DIR}"/items/*_boot.fex 2>/dev/null | head -n 1)"
[ -n "$boot" ] || die "boot.fex not found in ${STOCK_DIR}/items"

log "Reading the stock kernel from $(basename "$boot")"
python3 "$KTOOLS" image "$boot" "$kdir/Image"
python3 "$KTOOLS" config "$kdir/Image" "$kdir/config"
python3 "$KTOOLS" symvers "$kdir/Image" "$kdir/config" "$kdir/Module.symvers"
krel="$(grep -aom1 'Linux version [^ ]*' "$kdir/Image" | cut -d' ' -f3)"
echo "  kernel release: $krel"

stamp="${MODULES_DIR}/.build-done"
stamp_value="$(sha256sum "$kdir/Image" | cut -c1-64) ${KERNEL_SRC_REPO} ${KERNEL_SRC_REF} $(cat "$0" "$KTOOLS" | sha256sum | cut -c1-16)"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$stamp_value" ]; then
    log "Kernel modules already built (delete $stamp to redo)"
    exit 0
fi

# Sparse, blob-less checkout of just the kernel directory (~1.1 GB), kept in
# the cache so later builds don't download it again.
src="${CACHE_DIR}/kernel-src"
tree="${src}/${KERNEL_SRC_PATH}"
log "Kernel source: ${KERNEL_SRC_REPO} @ ${KERNEL_SRC_REF} (${KERNEL_SRC_PATH})"
if [ ! -d "$src/.git" ]; then
    rm -rf "$src"
    git init -q "$src"
    git -C "$src" remote add origin "$KERNEL_SRC_REPO"
    git -C "$src" sparse-checkout set "$KERNEL_SRC_PATH"
fi
if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null)" != "$KERNEL_SRC_REF" ]; then
    git -C "$src" fetch -q --depth 1 --filter=blob:none origin "$KERNEL_SRC_REF"
    git -C "$src" checkout -q --force FETCH_HEAD
fi
git -C "$src" clean -fdxq
[ -f "$tree/Makefile" ] || die "no kernel tree at $tree"

make_args=(ARCH=arm64 "CROSS_COMPILE=${cross}" HOSTCFLAGS=-fcommon KCFLAGS=-Wno-error)
kmake() { make -C "$tree" -j"$(nproc)" "${make_args[@]}" "$@"; }

log "Configuring with the stock kernel's config plus CAN modules"
cp "$kdir/config" "$tree/.config"
"$tree/scripts/config" --file "$tree/.config" \
    --module CAN --module CAN_RAW --module CAN_BCM --disable CAN_GW \
    --module CAN_DEV --enable CAN_CALC_BITTIMING --module CAN_GS_USB
kmake olddefconfig >/dev/null
lost="$(comm -23 <(grep '^CONFIG_' "$kdir/config" | sort) <(grep '^CONFIG_' "$tree/.config" | sort))"
[ -z "$lost" ] || die "the source tree does not support these stock options: $lost"
added="$(comm -13 <(grep '^CONFIG_' "$kdir/config" | sort) <(grep '^CONFIG_' "$tree/.config" | sort) | grep -v '^CONFIG_CAN' || true)"
[ -z "$added" ] || echo "  note: options the stock config lacks, now at their defaults: $(echo $added)"
cp "$kdir/Module.symvers" "$tree/Module.symvers"

log "Building modules"
kmake modules_prepare >/dev/null
kmake M=net/can modules >/dev/null
kmake M=drivers/net/can KBUILD_EXTRA_SYMBOLS="$tree/net/can/Module.symvers" modules >/dev/null
mods=(net/can/can.ko net/can/can-raw.ko net/can/can-bcm.ko
      drivers/net/can/can-dev.ko drivers/net/can/usb/gs_usb.ko)
for m in "${mods[@]}"; do
    [ -f "$tree/$m" ] || die "module not built: $m"
    vermagic="$("${cross}objcopy" -O binary --only-section=.modinfo "$tree/$m" /dev/stdout \
        | tr '\0' '\n' | sed -n 's/^vermagic=//p')"
    [ "${vermagic%% *}" = "$krel" ] || die "$m vermagic '$vermagic' does not match kernel $krel"
done

log "Checking symbol CRCs against the stock kernel"
verify_args=()
for a in "${make_args[@]}"; do verify_args+=(--make-arg "$a"); done
OBJCOPY="${cross}objcopy" NM="${cross}nm" python3 "$KTOOLS" verify "$tree" "$kdir/Module.symvers" \
    "${mods[@]/#/$tree/}" --own "$tree/net/can/Module.symvers" \
    --own "$tree/drivers/net/can/Module.symvers" "${verify_args[@]}"

rm -rf "$MODULES_DIR"
for m in "${mods[@]}"; do
    dest="${MODULES_DIR}/lib/modules/${krel}/kernel/$(dirname "$m")"
    mkdir -p "$dest"
    "${cross}strip" --strip-debug -o "$dest/$(basename "$m")" "$tree/$m"
    echo "  $m"
done
echo "$krel" > "${MODULES_DIR}/kernel-release"
echo "$stamp_value" > "$stamp"
log "Stage 1b done"
