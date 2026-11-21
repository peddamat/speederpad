#!/usr/bin/env bash
# Stage 1: extract the vendor boot chain, card head and device files from the
# stock FLSUN restore image. Output:
#   work/stock/card-head.bin   card bytes before the firmware (MBR/GPT, boot0,
#                              card U-Boot package, sunxi_mbr, FAT boot-resource)
#   work/stock/items/          every IMAGEWTY item except rootfs.fex
#   work/vendor/firmware/      Wi-Fi firmware (bcmdhd: fw_bcm43438a1.bin, nvram.txt)
#   work/vendor/xorg.conf.d/   stock X input config (touchscreen)
#   work/vendor/klipper_config/, work/vendor/home/   stock printer configs
. "$(dirname "$0")/lib.sh"
load_config
require_cmds python3 xz debugfs e2fsck

stamp="${STOCK_DIR}/.extract-done"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(stat -c '%n %s %Y' "$STOCK_IMAGE")" ]; then
    log "Vendor files already extracted from $(basename "$STOCK_IMAGE") (delete $stamp to redo)"
    exit 0
fi
[ -f "$STOCK_IMAGE" ] || die "stock image not found: $STOCK_IMAGE (set STOCK_IMAGE in build.conf)"

rm -rf "$STOCK_DIR" "$VENDOR_DIR"
mkdir -p "$STOCK_DIR" "$VENDOR_DIR"

card="$STOCK_IMAGE"
if [[ "$STOCK_IMAGE" == *.xz ]]; then
    card="${STOCK_DIR}/stock-card.img"
    log "Decompressing $(basename "$STOCK_IMAGE") (sparse, ~16 GB apparent size)"
    xz -dc "$STOCK_IMAGE" | cp --sparse=always /dev/stdin "$card"
fi

log "Verifying stock card layout and IMAGEWTY checksums"
python3 "$SUNXI_CARD" info "$card" --checksums | grep -E 'GPT|IMAGEWTY|checksum'

log "Unpacking firmware items and card head"
python3 "$SUNXI_CARD" unpack "$card" "${STOCK_DIR}/items" \
    --card-head "${STOCK_DIR}/card-head.bin" --skip rootfs.fex

stock_rootfs="${STOCK_DIR}/stock-rootfs.ext4"
python3 "$SUNXI_CARD" extract "$card" rootfs.fex "$stock_rootfs"
[ "$card" != "$STOCK_IMAGE" ] && rm -f "$card"
e2fsck -fn "$stock_rootfs" >/dev/null || die "stock rootfs.fex failed e2fsck"

dfs() { debugfs -R "$1" "$stock_rootfs" 2>/dev/null; }

log "Extracting vendor device files from the stock rootfs"
mkdir -p "${VENDOR_DIR}/firmware" "${VENDOR_DIR}/xorg.conf.d" "${VENDOR_DIR}/home"
# Top-level firmware files (ls -p rows: /inode/mode/uid/gid/name/size/).
# regulatory.db comes from Debian's wireless-regdb instead.
dfs "ls -p /usr/lib/firmware" | while IFS=/ read -r _ _ mode _ _ name _; do
    [[ "$mode" == 100* ]] || continue
    [[ "$name" == regulatory.db* ]] && continue
    dfs "dump /usr/lib/firmware/$name ${VENDOR_DIR}/firmware/$name" >/dev/null
    echo "  firmware: $name"
done
dfs "ls -p /etc/X11/xorg.conf.d" | while IFS=/ read -r _ _ mode _ _ name _; do
    [[ "$mode" == 100* ]] || continue
    dfs "dump /etc/X11/xorg.conf.d/$name ${VENDOR_DIR}/xorg.conf.d/$name" >/dev/null
    echo "  xorg.conf.d: $name"
done
dfs "rdump /home/pi/klipper_config ${VENDOR_DIR}" >/dev/null || true
dfs "ls -p /home/pi" | while IFS=/ read -r _ _ mode _ _ name _; do
    [[ "$mode" == 100* && "$name" == savedVariables*.cfg ]] || continue
    dfs "dump /home/pi/$name ${VENDOR_DIR}/home/$name" >/dev/null
    echo "  home: $name"
done
[ -s "${VENDOR_DIR}/firmware/nvram.txt" ] || die "Wi-Fi nvram.txt not found in the stock rootfs"
[ -d "${VENDOR_DIR}/klipper_config" ] && echo "  klipper_config: $(ls "${VENDOR_DIR}/klipper_config" | tr '\n' ' ')"

rm -f "$stock_rootfs"
stat -c '%n %s %Y' "$STOCK_IMAGE" > "$stamp"
log "Stage 1 done"
