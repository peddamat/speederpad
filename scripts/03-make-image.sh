#!/usr/bin/env bash
# Stage 3: turn the rootfs directory into rootfs.fex, repack the vendor
# IMAGEWTY with it, and assemble a flashable PhoenixCard TF-card image.
# Needs root (mke2fs -d must read every file with its real ownership).
. "$(dirname "$0")/lib.sh"
load_config
require_root
require_cmds mke2fs e2fsck dumpe2fs python3 xz sha256sum
[ -d "${ROOTFS_DIR}/home/${USERNAME}/klipper" ] || die "run stage 2 (rootfs) first"
[ -f "${STOCK_DIR}/.extract-done" ] || die "run stage 1 (extract) first"

mkdir -p "$OUT_DIR"
ext4="${WORK_DIR}/rootfs.ext4"
firmware="${WORK_DIR}/firmware.img"
card="${OUT_DIR}/${IMAGE_NAME}.img"

# Exactly the feature set of the stock rootfs. Newer e2fsprogs defaults
# (orphan_file, metadata_csum_seed) are unknown to the 4.9 vendor kernel,
# which would refuse to mount the root filesystem.
features=none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,64bit,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,metadata_csum

used_kb=$(du -s -k -x "$ROOTFS_DIR" | cut -f1)
files=$(find "$ROOTFS_DIR" -xdev | wc -l)
size_mb=$(( (used_kb * 115 / 100) / 1024 + ROOTFS_EXTRA_MB ))
size_mb=$(( (size_mb + 3) / 4 * 4 ))
inodes=$(( files * 2 + 65536 ))
log "Creating ${size_mb} MiB ext4 rootfs (${used_kb} KiB used, ${files} files)"
rm -f "$ext4"
mke2fs -q -F -t ext4 -b 4096 -L rootfs -O "$features" -N "$inodes" -m 1 \
    -E root_owner=0:0 -d "$ROOTFS_DIR" "$ext4" "${size_mb}M"
e2fsck -fn "$ext4" >/dev/null || die "new rootfs failed e2fsck"
dumpe2fs -h "$ext4" 2>/dev/null | grep -E '^(Filesystem features|Block count|Free blocks)'

log "Repacking IMAGEWTY with the new rootfs.fex"
python3 "$SUNXI_CARD" repack "${STOCK_DIR}/items" "$firmware" --replace "rootfs.fex=${ext4}"

log "Assembling TF-card image"
python3 "$SUNXI_CARD" make-card --head "${STOCK_DIR}/card-head.bin" --firmware "$firmware" \
    --output "$card" ${CARD_TOTAL_SECTORS:+--total-sectors "$CARD_TOTAL_SECTORS"}
rm -f "$firmware"
python3 "$SUNXI_CARD" info "$card" --checksums | grep -E 'GPT|IMAGEWTY|checksum'

# The sprite flasher writes rootfs.fex into the eMMC "rootfs" partition.
part_sectors=$(python3 "$SUNXI_CARD" info "$card" | awk '$2=="rootfs" {sub("sectors=","",$4); print $4}')
[ -n "$part_sectors" ] && [ $(( $(stat -c %s "$ext4") / 512 )) -le "$part_sectors" ] ||
    die "rootfs.fex does not fit the eMMC rootfs partition (${part_sectors:-?} sectors)"
rm -f "$ext4"

if [ "$COMPRESS" = 1 ]; then
    log "Compressing ${card}.xz"
    rm -f "${card}.xz"
    xz -T0 -6 "$card"
    card="${card}.xz"
fi
(cd "$OUT_DIR" && sha256sum "$(basename "$card")" > "$(basename "$card").sha256")
[ -n "${SUDO_UID:-}" ] && chown "${SUDO_UID}:${SUDO_GID}" "$card" "${card}.sha256"
log "Done: ${card} ($(du -h "$card" | cut -f1))"
