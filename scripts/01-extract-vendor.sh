#!/usr/bin/env bash
# Stage 1: extract the vendor boot chain, card head and device files from the
# stock FLSUN restore image (v1.2 or v1.4; their boot chains are identical).
# Output:
#   work/stock/card-head.bin   card bytes before the firmware (MBR/GPT, boot0,
#                              card U-Boot package, sunxi_mbr, FAT boot-resource)
#   work/stock/items/          every IMAGEWTY item except rootfs.fex
#   work/vendor/firmware/      Wi-Fi firmware (bcmdhd: fw_bcm43438a1.bin, nvram.txt)
#   work/vendor/xorg.conf.d/   stock X input config (touchscreen)
#   work/vendor/klipper_config/, work/vendor/home/   stock printer configs, from
#                              STOCK_CONFIG_IMAGE when set, else STOCK_IMAGE
. "$(dirname "$0")/lib.sh"
load_config
require_cmds python3 xz debugfs e2fsck

[ -f "$STOCK_IMAGE" ] || die "stock image not found: $STOCK_IMAGE (set STOCK_IMAGE in build.conf)"
[ -z "$STOCK_CONFIG_IMAGE" ] || [ -f "$STOCK_CONFIG_IMAGE" ] \
    || die "config image not found: $STOCK_CONFIG_IMAGE (set STOCK_CONFIG_IMAGE in build.conf)"

image_id() { stat -c '%n %s %Y' "$1"; }
stamp="${STOCK_DIR}/.extract-done"
stamp_value="$(image_id "$STOCK_IMAGE")"
[ -z "$STOCK_CONFIG_IMAGE" ] || stamp_value+=" | config: $(image_id "$STOCK_CONFIG_IMAGE")"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$stamp_value" ]; then
    log "Vendor files already extracted from $(basename "$STOCK_IMAGE") (delete $stamp to redo)"
    exit 0
fi

rm -rf "$STOCK_DIR" "$VENDOR_DIR"
mkdir -p "$STOCK_DIR" "$VENDOR_DIR"

# Sets CARD to a raw card image for $1, decompressing .xz into STOCK_DIR.
open_card() {
    CARD="$1"
    if [[ "$1" == *.xz ]]; then
        CARD="${STOCK_DIR}/$2.img"
        log "Decompressing $(basename "$1") (sparse; 8-16 GB apparent size)"
        xz -dc "$1" | cp --sparse=always /dev/stdin "$CARD"
    fi
}
close_card() {
    if [ "$CARD" != "$1" ]; then rm -f "$CARD"; fi
}
# Extracts rootfs.fex from CARD into $1 and checks it.
extract_rootfs() {
    python3 "$SUNXI_CARD" extract "$CARD" rootfs.fex "$1"
    e2fsck -fn "$1" >/dev/null || die "rootfs.fex in $(basename "$CARD") failed e2fsck"
    DFS_IMG="$1"
}
dfs() { debugfs -R "$1" "$DFS_IMG" 2>/dev/null; }

open_card "$STOCK_IMAGE" stock-card
log "Verifying stock card layout and IMAGEWTY checksums"
python3 "$SUNXI_CARD" info "$CARD" --checksums | grep -E 'GPT|IMAGEWTY|checksum'

log "Unpacking firmware items and card head"
python3 "$SUNXI_CARD" unpack "$CARD" "${STOCK_DIR}/items" \
    --card-head "${STOCK_DIR}/card-head.bin" --skip rootfs.fex

stock_rootfs="${STOCK_DIR}/stock-rootfs.ext4"
extract_rootfs "$stock_rootfs"
close_card "$STOCK_IMAGE"

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
[ -s "${VENDOR_DIR}/firmware/nvram.txt" ] || die "Wi-Fi nvram.txt not found in the stock rootfs"

if [ -n "$STOCK_CONFIG_IMAGE" ]; then
    rm -f "$stock_rootfs"
    log "Taking printer configs from $(basename "$STOCK_CONFIG_IMAGE")"
    open_card "$STOCK_CONFIG_IMAGE" config-card
    stock_rootfs="${STOCK_DIR}/config-rootfs.ext4"
    extract_rootfs "$stock_rootfs"
    close_card "$STOCK_CONFIG_IMAGE"
fi

log "Extracting stock printer configs"
dfs "rdump /home/pi/klipper_config ${VENDOR_DIR}" >/dev/null || true
dfs "ls -p /home/pi" | while IFS=/ read -r _ _ mode _ _ name _; do
    [[ "$mode" == 100* && "$name" == savedVariables*.cfg ]] || continue
    dfs "dump /home/pi/$name ${VENDOR_DIR}/home/$name" >/dev/null
    echo "  home: $name"
done
[ -d "${VENDOR_DIR}/klipper_config" ] && echo "  klipper_config: $(ls "${VENDOR_DIR}/klipper_config" | tr '\n' ' ')"

rm -f "$stock_rootfs"
echo "$stamp_value" > "$stamp"
log "Stage 1 done"
