# Speeder Pad image investigation

Status: in progress. Scope is to investigate both host Klipper and V400 printer-MCU updates. This note records verified observations and keeps open questions separate from conclusions. Items marked *(inference)* are not directly verified.

## Summary

[SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz](./SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz) is not a bootable OS disk. It is an Allwinner **PhoenixCard "product" (card-burn) TF card**. The card boots a card-mode Allwinner `boot0` and U-Boot. That U-Boot reads an embedded **IMAGEWTY** firmware package (the standard Allwinner PhoenixSuite/LiveSuit `.img` format) and flashes its partitions to the Speeder Pad's internal eMMC while showing a progress bar.

The firmware package is the output of Allwinner's **longan/Tina Linux BSP `pack` step** for an `r818-evb2`-derived board (Allwinner R818 / `sun50iw10p1`). It contains:

- boot0
- U-Boot, ATF, SCP and DTB
- an Android-format `boot.fex` holding a Linux 4.9.191 arm64 kernel
- an Ubuntu 20.04 ext4 `rootfs.fex` with **32-bit armhf userspace**. The rootfs appears to come from a Rockchip-style Ubuntu rootfs.

To build a custom image, change `rootfs.fex` (and optionally `boot.fex`), regenerate its `V*.fex` additive checksum, and repack or patch the IMAGEWTY. The vendor bootloaders, kernel and card layout can be kept unchanged.

FLSUN's later v1.4 image (`SPEEDERPADPADV1.4V2_TFCARD-230907`) has a byte-identical boot chain and kernel; only the rootfs changed. Its rootfs also adds a remotely triggerable `rm -rf /` helper. See [SPEEDERPAD_V1.2_VS_V1.4.md](./SPEEDERPAD_V1.2_VS_V1.4.md).

## Input and raw image

- Input: [SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz](./SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz), 1,447,861,192 bytes, SHA-256 `9fc2bd41e8bd81166ed7e83fca1b5aae13ea216fc35ba53061e7ef132179860b` (re-verified).
- Decompressed: 16,046,882,816 bytes (31,341,568 × 512-byte sectors), SHA-256 `fe6dbba17640a6c74103e80a1ecdda56cc3bf9859fda32207221d8ad912ab66d` (re-verified). The card image needs a card of at least about 16 GB; FLSUN's README asks for 32 GB.
- Working copies (WSL): `~/speederpad/disk.img`, extracted firmware items in `~/speederpad/fw/`, kernel config in `~/speederpad/kernel.config`, rootfs tree in `~/speederpad/rootfs/`.

## TF card layout (what PhoenixCard wrote)

| Card location | Content | Verification |
|---|---|---|
| Sector 0–1 + last sector | Protective MBR plus a small GPT (4 entry slots, entries at LBA 41,983). Header and entry CRCs are valid. | `sgdisk`, CRC check |
| Sector 16 (8 KiB) | `boot0` (`eGON.BT0`), 64 KiB | Byte-identical to firmware item `boot0_sdcard.fex` |
| Sector 32,800 (16,400 KiB) | `sunxi-package` boot package: `u-boot`, `monitor` (ATF), `scp` (ARISC), `dtb` | Same as `boot_package.fex` except 3 bytes: U-Boot work mode set to **0x11** (`WORK_MODE_CARD_PRODUCT`) at package offset 0x8E0, plus the two checksums |
| Sector 40,960 (20 MiB) | 4 copies of `sunxi_mbr` (`softw411`, version 0x200, 9 partitions, CRCs valid) | Byte-identical to `sunxi_mbr.fex` |
| Sector 41,984 (`boot-resource`, 4 MiB) | FAT16 labeled `FLSUN`. PhoenixCard's `bootlogo.bmp` and `magic.bin` are deleted entries. FLSUN added `README.md`, `Product Instrotion.pdf`, and `SSH Connection.txt` (`pi` / `flsun`), plus Windows `System Volume Information`. | FAT directory parse |
| Sector 50,176 (24.5 MiB, sunxi `env` partition start) | **IMAGEWTY firmware package**, header version 0x300, 37 items. True size about 5.30 GiB; it ends near sector 11,155,934. | Header parse; item checksums below |
| GPT p2 "`env`", sectors 11,156,960–31,339,519 | Not referenced by the burn flow. It holds residual data, including three ext4 superblocks with UUIDs unrelated to the rootfs, 4-KiB blocks, and no valid layout. | Superblock scan |

Corrections to earlier notes:

- The GPT is a card-level table only. The authoritative partition table is the `sunxi_mbr`.
- The ext4 at byte 42,593,280 is **not** "outside the partitions". It is `rootfs.fex` inside the IMAGEWTY, at package offset 0x0101EC00 (0x1880000 + 0x101EC00 = 0x289EC00).
- The "ext4 candidate in `env`" is residual card data, not a payload.
- The kernel is not lost: it is in `boot.fex`. It is not in `/boot`, because the Allwinner U-Boot loads it from the raw `boot` partition.

The card U-Boot strings include `IMAGEWTY`, `run card sprite`, `sprite cartoon ui: create progressbar failed`, `sprite success`, and `root_partition is %s`. These match the vendor README's "loading bar … wait until fully green" restore flow. *(inference)* In Allwinner's sprite code the card firmware is read from the start of `sunxi_mbr` partition index 1. That matches where the IMAGEWTY was found.

## Firmware package (IMAGEWTY) contents

Header: `ram_base=0x04D00000`, `version=0x100234`, PID/VID `0x1234/0x8743`, 37 files. The header `image_size` and every item's data length, file length and offset are **64-bit (lo/hi word pairs)**. An earlier note here claimed a "32-bit overflow"; that was a parsing mistake (the hi words were ignored). For example, `rootfs.fex` has `filelen_lo=1,374,275,584`, `filelen_hi=1`, so its length is 5,669,242,880 bytes.

Layout rules, confirmed by a byte-exact repack of the stock package with [sunxi_card.py](scripts/sunxi_card.py):

- The 1 KiB header is followed by one 1 KiB item header per file.
- Item data starts on 1 KiB boundaries.
- `datalen` is `filelen` rounded up to 16 bytes, zero padded.
- The gap up to the next 1 KiB boundary (and the tail up to `image_size`) is filled with `0xCD`.
- There is no checksum over the header; integrity comes from the `V*.fex` items.

Main items (offsets are relative to the IMAGEWTY start):

| Item | Size | Notes |
|---|---|---|
| `sys_config.fex` / `config.fex` / `board.fex` | 12,633 / 11,264 / 1,024 | BSP board config (text and compiled) |
| `sys_partition.fex` | 3,758 | eMMC partition plan (below) |
| `sunxi.fex` | 136,704 | DTB, `model=sun50iw10`, `compatible="allwinner,r818","arm,sun50iw10p1"`; identical to the `dtb` in `boot_package.fex` |
| `boot0_nand.fex`, `boot0_sdcard.fex` | 65,536 each | eGON boot0 |
| `u-boot.fex` | 704,512 | U-Boot `2018.05-g9b56363` (Feb 19 2021) |
| `boot_package.fex` | 999,424 | u-boot + monitor + scp + dtb |
| `fes1.fex`, `usbtool*.fex`, `aultools.fex`, `aultls32.fex`, `cardtool.fex`, `cardscript.fex` | — | PhoenixSuite USB/FEL and PhoenixCard tooling |
| `sunxi_gpt.fex`, `sunxi_mbr.fex`, `dlinfo.fex` | — | Partition tables / download map generated from `sys_partition.fex` |
| `boot-resource.fex` | 1,887,232 | FAT: `bootlogo.bmp`, `magic.bin` |
| `env.fex` (×2) | 131,072 | U-Boot environment for `env` and `env-redund` |
| `boot.fex` | 11,370,496 | Android boot image (see below) |
| `rootfs.fex` | 5,669,242,880 | ext4 root filesystem |
| `recovery.fex` | 24 | Placeholder text: `recovery part no t used!` |

Every downloadable partition image has a `V<name>.fex` 32-bit additive checksum (sum of little-endian u32 words). All six verified:

| Item | Checksum |
|---|---|
| `boot-resource` | 0xB02FF078 |
| `env` | 0xCC6BA392 |
| `boot` | 0xCC53FECD |
| `rootfs` | 0x600CE2BB |
| `recovery` | 0x483BE055 |

`cardscript.fex`: `mode=product`; boot0 at sector 16; boot package at sector 32,800; `card_boot start=40960`.

### eMMC partition plan (`sys_partition.fex` → `sunxi_mbr`)

Sector numbers are relative to the 20 MiB logical start.

| # | Name | Size (sectors) | Download file |
|---|---|---|---|
| 1 | boot-resource | 8,192 | boot-resource.fex |
| 2 | env | 1,024 | env.fex |
| 3 | env-redund | 1,024 | env.fex |
| 4 | boot | 30,720 (15 MiB) | boot.fex |
| 5 | rootfs | 30,409,695 (about 14.5 GiB) | rootfs.fex |
| 6 | rootfs_data | 8,192 | — |
| 7 | private | 1,024 | — |
| 8 | recovery | 32,768 | recovery.fex |
| 9 | UDISK | remainder | — |

The rootfs partition (about 14.5 GiB) is much larger than the 5.28 GiB ext4 inside it. The filesystem is grown on first boot by `rootfs/etc/init.d/rockchip.sh`; see the Root filesystem section.

### Boot chain and kernel

- `env.fex`:
  - `bootcmd=run setargs_nand boot_normal`
  - `boot_normal=sunxi_flash read 45000000 ${boot_partition};bootm 45000000`
  - `root_partition=rootfs`, `mmc_root=/dev/mmcblk0p7`, `cma=32M`, `console=ttyS0,115200`
- `boot.fex`: Android boot header v0, name `r818-evb2`, page size 2,048, kernel at 0x40080000, empty cmdline. The "ramdisk" is a 12-byte placeholder, so there is no initramfs.
- Kernel: raw arm64 `Image`, 11,364,360 bytes, SHA-256 `a63b84da99be1cf3401fe0af8ac865210f08b81247b492b378c38961b404bcbf`, banner `Linux version 4.9.191 (zzcat@ubuntu) (gcc version 6.4.1 (OpenWrt/Linaro GCC 6.4-2017.11 2017-11)) #97 SMP PREEMPT Sat Dec 3 02:45:41 UTC 2022`. The OpenWrt/Linaro toolchain is the one shipped with Allwinner's Tina/longan SDK.
- Embedded kernel config (`IKCONFIG`, `/proc/config.gz`): 3,227 options, SHA-256 `e791932b8da2fea81e1ec34af689b2d228111bab14a6425a414da88a49e6b0ca`. Recovered by REA `inspect-kernel-build-config` (Evidence `ev_ce61afb04cfb85b04d348488c7ed7f9c05bad227da46ab4e8f17ee207e4fcdd1`).
  - `CONFIG_ARCH_SUN50IW10P1=y`, `CONFIG_PREEMPT=y`, `HZ=250`, `CONFIG_LOCALVERSION=""`.
  - `CONFIG_COMPAT=y`: this is what lets the 32-bit armhf userspace run on the arm64 kernel.
  - `CONFIG_MODULES=y` and `CONFIG_MODVERSIONS=y`: out-of-tree modules need this exact tree and `Module.symvers`.
  - `CONFIG_CMDLINE="root=/dev/mmcblk0p5 rootwait rw"` with `CONFIG_CMDLINE_EXTEND=y`. The built-in `root=` is appended after U-Boot's arguments, so it points the kernel at GPT p5 = `rootfs`.
  - Built in: `USB_ACM`, `USB_SERIAL_CH341`, `CP210X`, `FTDI_SIO`, `EXT4_FS`, `OVERLAY_FS`, `SQUASHFS`, `EFI_PARTITION`. **`CONFIG_CAN` is not set**, so CAN-bus toolheads would need a kernel rebuild.

## Root filesystem (`rootfs.fex`)

- ext4, label `rootfs`, UUID `a35ef3ab-9572-4f75-acb1-1cc15e2f4e3d`, 1-KiB blocks, 5,536,370 blocks, 173,056 inodes.
- 4,618,473 blocks used and 917,897 free (about 0.9 GiB free).
- Created 2023-03-02 17:05:58; last mounted 2023-03-02 18:46:44.
- Features include `metadata_csum` and `64bit`.
- `e2fsck -fn` is clean.
- `/boot` is empty (the kernel lives in `boot.fex`), and `/etc/fstab` is the unconfigured base-system file.
- OS: `Ubuntu 20.04.5 LTS` (from `/usr/lib/os-release`).
- **Userspace ABI is armhf (32-bit ARM EABI5), not arm64.** `/var/lib/dpkg/status` lists 800 `armhf` packages and 0 `arm64`. `libc6` is `2.31-0ubuntu9.9 armhf`. `/bin/bash` and `klippy-env/bin/python2.7` are 32-bit ARM ELF. Any offline chroot needs `qemu-arm-static`, not `qemu-aarch64-static`, and any rebuilt native code (Python wheels, mjpg-streamer and so on) must target armhf.
- **Rockchip-derived rootfs:** `rockchip.service` (enabled oneshot, "Setup rockchip platform environment") runs `/etc/init.d/rockchip.sh` and then disables itself. If `/usr/local/first_boot_flag` is absent (it is absent in this image), the script runs `resize2fs /dev/mmcblk0p5` and creates the flag. This is how the 5.28 GiB ext4 grows to fill the eMMC rootfs partition. *(inference)* FLSUN reused a Rockchip Ubuntu 20.04 armhf rootfs (the kind shipped with Rockchip Linux SDKs) on the Allwinner kernel. That would explain the "Rockchip" lead in earlier notes.
- Python environments: `klippy-env` is Python 2.7; `moonraker-env/pyvenv.cfg` has `version_info = 3.8.10.final.0` (re-verified).
- Services in `/etc/systemd/system` (all enabled in `multi-user.target.wants`, except that `bt-attach` was not seen there):
  - `klipper-{1,2,3}`, `moonraker-{1,2,3}`
  - `KlipperScreen`, `timelapse`, `webcamd`
  - `nginx`, `ssh`, `wpa_supplicant`, `avahi-daemon`, `ondemand`, `rockchip`
- `klipper-1.service` runs as `pi`: `/home/pi/klippy-env/bin/python /home/pi/klipper/klippy/klippy.py ${KLIPPER_CONFIG} -I /tmp/printer-1 -l ${KLIPPER_LOG} -a /tmp/klippy_uds-1`, with config `/home/pi/klipper_config/printer_1/printer.cfg`.
- `/home/pi` contains:
  - `klipper`, `klippy-env`
  - `moonraker`, `moonraker-env`, `.moonraker_database_{1,2,3}`
  - `mainsail`
  - `KlipperScreen`, `.KlipperScreen-env`
  - `mjpg-streamer`, `moonraker-timelapse`, `timelapse`
  - `klipper_config`, `klipper_logs`, `gcode_files`
  - `savedVariables{1,2,3}.cfg`
- Klipper checkout: branch `master`, commit `e002f0cfa9358c4a9abb66ab43bc018fc8f86981`, remote `https://gitee.com/leexxiangyang/klipper.git` (re-verified).
- **That commit is in FLSUN's [klipper_fs](https://github.com/Flsun3d/klipper_fs)** (2022-06-09, "update klippy/extras/virtual_sdcard.py"). It is **not** in upstream `Klipper3d/klipper`. The Gitee repository is therefore the same FLSUN fork lineage. `klipper_fs` is not a GitHub fork (`fork=false`). Its upstream base is `ada571ecb` (v0.10.0-451, 2022-06-06), with 4 FLSUN commits on top (see below).
- Carried over from the previous pass, not yet re-checked: the Gitee `master` matching the checkout.
- Identity baked into the image: three fixed SSH host key pairs in `/etc/ssh`, machine-id `2dc89acf…`, and hostname `speeder-pad`. Every pad restored from this card therefore shares them. The `pi` password is `flsun` (checked against the hash).
- `/root/crc.raw` is not an image. It is a ZIP (2022-08-22) of the developer's `工作笔记.txt` ("work notes"), covering the BSP path `linux_R818-v18/out/r818-evb2`, the Wi-Fi setup, and how images were captured and locked down. It also contains third-party Wi-Fi passwords (not reproduced).

## FLSUN's modifications to the printer software

Checked 2026-11-21. Each pad checkout (including uncommitted edits) was compared with upstream `Klipper3d/klipper`, `Arksine/moonraker` and `KlipperScreen/KlipperScreen`, and with the official Mainsail release zips. Both v1.2 and v1.4 were checked; v1.4 uses the same commits with more local edits (see [SPEEDERPAD_V1.2_VS_V1.4.md](./SPEEDERPAD_V1.2_VS_V1.4.md)).

| Component | Fork point | FLSUN changes |
|---|---|---|
| Klipper (`klipper_fs`, `e002f0cf`) | upstream `ada571ecb` (v0.10.0-451, 2022-06-06) | 4 commits, 40 lines; see below |
| Moonraker (`moonraker_fs`, `bb526e0`) | upstream `d53cf27` (v0.7.1-572, 2022-05-22) | 12 lines: `/machine/shutdown` runs `shutdown -H now` (halt) instead of the systemd D-Bus power-off; the update manager points Klipper/Moonraker at FLSUN's Gitee mirrors; the install script symlinks the timelapse component. v1.4 also removes Moonraker from the update manager (`del self.updaters['moonraker']`). |
| Mainsail v2.2.1 (v1.2) / v2.4.0 (v1.4) | official release zip | one edit in each: the **DELTA CALIBRATE** button is replaced by **G28** |
| KlipperScreen (`leexxiangyang/KlipperScreen`) | snapshot of upstream v0.2.2-4 (2022-05-04); no shared Git history | heavy UI fork (about 3,500 changed lines) |
| moonraker-timelapse | upstream `47e27bd` | v1.4 deletes `LICENSE` (GPL-3.0) and the DCO; `install.sh` is edited |

Klipper changes:

- `heaters.py`: `PID_SETTLE_DELTA` changed from 1 to 3 °C, and the temperature-slope check was removed. `M109`/`M190` therefore return as soon as the heater is within ±3 °C, rather than within 1 °C and stable. Upstream still uses 1 °C plus the slope check.
- `delta_calibrate` (`delta.py`): `SAVE_CONFIG` stores only `position_endstop` and `arm_length`. Upstream also stores the calibrated `delta_radius` and tower `angle`s. FLSUN also removed the result printout. The stock `SAVE_CONFIG` block therefore keeps the nominal `delta_radius = 161.75` and angles 210/330/90.
- New `M665 A/B/C` command adds offsets to the arm lengths. New `M205 X` command sets `square_corner_velocity`. Neither the stock configs nor KlipperScreen use them. Upstream has `SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=` instead.
- `virtual_sdcard.py`: a Python 2 `sys.setdefaultencoding('utf8')` hack for Chinese file names. It isn't needed on Python 3.

KlipperScreen changes:

- FLSUN branding, styles and icons.
- A printer-model chooser (`guide`, `confie_printer`) that copies per-model `printer.cfg`/`defaults.conf` files and sed-patches `config.py`.
- Three-port printer switching (`switch_printer`, `usb.sh`, `printer.sh`) that rewrites `/dev/serial/by-path` names.
- An input shaper panel, an on-screen keyboard, filament-runout popups, and 20–200 % flow / 20–500 % speed limits.
- The Z calibrate panel is replaced by a Z-offset babystep panel, removing upstream's endstop/probe/delta calibration modes.
- Shell calls to `xset`, `shutdown -H now` and time-zone files.
- v1.4 adds a `zoffset` panel and ships `ks_includes/screen_panel.py` only as a Cython-compiled `screen_panel.so`. KlipperScreen is AGPL-3.0, and no source for that module is in the image.
- `warning.txt` holds UI state only: first-run guide, language, port, and auto-level/ADXL progress flags.

**Useful for our build:** very little. Current upstream KlipperScreen already has input shaper, delta calibration, Z babystepping, an on-screen keyboard and object exclusion. Upstream Moonraker and Mainsail are unmodified in our image. The changes with an effect worth knowing about:

1. **Heater settle tolerance.** If a faster print start is wanted, it can be reproduced without patching Klipper. Use an `M109` macro that sets the target and then calls `TEMPERATURE_WAIT SENSOR=extruder MINIMUM={T-3} MAXIMUM={T+3}`.
2. **`DELTA_CALIBRATE` now saves radius and angles.** With upstream Klipper (our image), `bed_level_1`/`DELTA_CALIBRATE` also save the calibrated `delta_radius` and tower angles. That is the normal Klipper behavior and generally more accurate. It differs from the stock pad, which locked them at nominal values. If results get worse, restore `delta_radius = 161.75` and the angles 210/330/90 in the `SAVE_CONFIG` block.
3. **`M205 X` (optional).** A small `M205` macro mapping X to `SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY` would silence "Unknown command" messages from slicers that emit jerk settings.
4. **Shutdown (to test).** FLSUN switched both Moonraker and KlipperScreen to `shutdown -H now` (halt). *(inference)* This was probably a workaround; the reason is unknown. The Shutdown buttons haven't been tested on our image yet.

## Public sources

- [Flsun3d/Flsun_Speeder_Pad](https://github.com/Flsun3d/Flsun_Speeder_Pad) documents the TF-card restore and provides printer-MCU firmware/configs. It has no Linux image build recipe. The card README links FLSUN's [klipper_fs](https://github.com/Flsun3d/klipper_fs), [moonraker_fs](https://github.com/Flsun3d/moonraker_fs) and [mainsail_fs](https://github.com/Flsun3d/mainsail_fs). The restore is written with Raspberry Pi Imager.
- Upstream Klipper `master` is `b670adc92bf92b304e76c3c2f36f5d8f98a4e2f1` (2026-11-19). `klippy/klippy.py` still has `#!/usr/bin/env python2`, and `scripts/install-debian.sh` still runs `virtualenv -p python2` (re-verified). The Python 2.7 environment does not by itself block an upstream update. Current dependencies still need testing.
- [Issue #8](https://github.com/Flsun3d/Flsun_Speeder_Pad/issues/8) asks for the 4.9.191 kernel source and remains unanswered. No public source for this BSP kernel or U-Boot has been found. The embedded `.config` above helps, but a matching Allwinner R818 longan 4.9 tree is still needed for a rebuild.

## V400 printer-MCU path

Carried over; not affected by the findings above.

- FLSUN's [V400 printer.cfg](https://github.com/Flsun3d/Flsun_Speeder_Pad/blob/main/firmware/V400/printer.cfg) identifies an MKS Robin Nano V2 / STM32F103 with these Klipper build settings: 28-KiB bootloader, 8-MHz crystal, USART3 on PB11/PB10.
- The [V400 firmware readme](https://github.com/Flsun3d/Flsun_Speeder_Pad/blob/main/firmware/V400/readme.txt) names the output `Robin_nano35.bin`, which is flashed from the printer board's SD card.
- Build outline (no firmware has been built or flashed yet):
  1. `make menuconfig` with those settings.
  2. `make`.
  3. `python3 scripts/update_mks_robin.py out/klipper.bin out/Robin_nano35.bin`.
- Host and MCU must run the same Klipper revision, but they are separate outputs and separate flashing operations.

## How the image was built (reconstructed)

1. **Allwinner longan/Tina BSP** for R818 (`sun50iw10p1`), board based on `r818-evb2`. It builds boot0, U-Boot 2018.05 (Feb 2021 binary), ATF/SCP, the DTB, and Linux 4.9.191 (built Dec 2022). The kernel is packed into an Android-format `boot.fex`.
2. **Rootfs**: Ubuntu 20.04 **armhf**, apparently a Rockchip-style base (`rockchip.service` first-boot resize), with Klipper (FLSUN fork), Moonraker, Mainsail, KlipperScreen and three printer instances. It was made into a 5.28 GiB ext4 `rootfs.fex` on 2023-03-02. It was captured from a working pad, not built from a recipe. The developer notes in `/root/crc.raw` describe the process:
   - image a pad's TF card with `dc3dd` and shrink it with PiShrink, or `rsync -avx --delete / rootfs/` into a loop-mounted image
   - compile Python modules to `.so` with Cython
   - remove `pi` from `sudo` and `chmod 700` `rc.local`, `usbmount.sh` and `cfgguard.sh`

   No build recipe is published.
3. **BSP `pack`** combines `sys_config.fex`, `sys_partition.fex` and the binaries into an IMAGEWTY `.img` with `V*.fex` checksums.
4. **PhoenixCard (product mode)** writes card-mode boot0/U-Boot (work mode 0x11), the `sunxi_mbr`, a card GPT and the boot-resource FAT to a TF card, then copies the IMAGEWTY starting at the second sunxi partition.
5. FLSUN edited the card's FAT on Windows (removed logo/magic files, added README/PDF/SSH note). The whole card was then imaged to `.img` and xz-compressed.

## Is the format proprietary? Can the image be built from source?

### Format and signing

- IMAGEWTY, `sunxi_mbr`, `boot_package`, eGON `boot0` and the `V*.fex` checksums are Allwinner-defined formats, but they are not encrypted or signed. All of them were parsed and verified above with short scripts.
- Allwinner's own packer (the BSP `pack` script plus closed `dragon`/`update_*` host binaries) is not needed. [OpenixCard](https://github.com/YuzukiTsuru/OpenixCard) is an open-source PhoenixCard replacement that unpacks IMAGEWTY images and writes card images on Linux.
- **No secure boot is in use.** `toc0.fex` and `toc1.fex` are 8-byte placeholders that just contain their own file names. The card boots a plain `eGON.BT0` boot0 (version string `4.0`, simple additive checksum), which a secure-mode BROM would reject. `[secure]` in `sys_config.fex` reserves no secure DRAM. *(inference)* The SoC's secure-boot fuse is not blown, so unsigned, self-built bootloaders should run. This can only be fully proven by booting one.

### Hardware facts a from-source build needs (from `sys_config.fex` and the DTB)

- DRAM: `dram_type = 4` (DDR4 in Allwinner numbering), `dram_clk = 792`, with the full MR/TPR parameter set in `[dram_para]`.
- Panel: `lcd0` `default_lcd`, `lcd_if = 0` (parallel RGB), 1024×600, 66 MHz pixel clock.
- Touch: `ctp_name = gt9xxf_ts`, a Goodix GT9xx controller.
- GPU: `img,gpu` (`CONFIG_SUNXI_GPU_TYPE="ge8300"`, PowerVR GE8300).
- Console: UART0 at 115200 baud.

### Open-source support for each part (checked against current upstream trees)

| Component | Vendor image | Open, buildable replacement |
|---|---|---|
| Image/card packing | `pack` + PhoenixCard | Our own scripts, or OpenixCard |
| boot0 + DRAM init | Closed boot0 blob | **Mainline U-Boot SPL**: `arch/arm/mach-sunxi/dram_sun50i_a133.c` exists. Its header says only DDR4 has been tested, which matches this board. |
| U-Boot | Allwinner 2018.05 fork | Mainline U-Boot (`liontron-h-a133l_defconfig` is a starting point); a Speeder Pad defconfig/DTS must be written |
| ATF (`monitor`) | Allwinner build | Mainline TF-A `plat/allwinner/sun50i_a133` |
| SCP (`scp`, ARISC) | Closed blob | Optional for boot; it mainly affects power management/suspend |
| Linux kernel | Allwinner 4.9.191 BSP, source unpublished | Mainline Linux has `sun50i-a100.dtsi` and A133 boards (`liontron-h-a133l`, `helperboard`, `teclast-p80`). A Speeder Pad DTS must be written. |
| Display (DE/TCON) | BSP `sunxi-disp` | **Not in mainline**: the `sun4i` DRM driver has no A100/A133 compatibles, and `sun50i-a100.dtsi` has no display nodes |
| Touch (GT9xx) | BSP `gt9xxf_ts` | Mainline `goodix` driver |
| GPU (GE8300) | BSP PowerVR blob | No mainline driver; software rendering only |
| Rootfs | Ubuntu 20.04 armhf | Any Debian/Ubuntu arm64 or armhf rootfs built with debootstrap/mmdebstrap |

### Conclusion

- **The packaging is not a barrier.** A new boot0/U-Boot/kernel/rootfs set can be packed into a card image, or written straight to eMMC, with open tools.
- **A fully from-source, mainline build can boot the board, but will have no screen today.** Mainline A133 has no display driver, so the screen (and KlipperScreen) would not work. Klipper, Moonraker and Mainsail over the network would. Display support would mean porting the BSP display driver or waiting for upstream.
- **A middle route** keeps the vendor boot0/U-Boot/ATF/SCP and the 4.9 kernel (so the display, touch and GPU keep working) and replaces only the rootfs with a freshly built Debian/Ubuntu image (`debootstrap` + current Klipper/Moonraker/KlipperScreen). That rootfs can be arm64 instead of armhf, because the kernel is arm64 with `CONFIG_COMPAT=y`. This needs an `/etc/fstab`, a first-boot resize and the BSP firmware and udev bits copied over from the stock rootfs.

## Custom-image build (implemented: option 2)

The chosen route keeps the vendor boot chain and replaces the rootfs with a freshly built Debian image. It is automated in this repository; usage is in [README.md](README.md).

- Stage 1, [01-extract-vendor.sh](scripts/01-extract-vendor.sh):
  - verifies the stock card;
  - saves the card head (sectors 0–50,175) and all IMAGEWTY items except `rootfs.fex`;
  - copies the Wi-Fi firmware (`fw_bcm43438a1.bin`, `nvram.txt` for the built-in `bcmdhd` driver), the touchscreen X config, and the stock printer configs.
- Stage 2, [02-build-rootfs.sh](scripts/02-build-rootfs.sh):
  - `mmdebstrap` builds Debian bookworm arm64 by default;
  - [provision.sh](scripts/chroot/provision.sh) runs in a qemu chroot. It installs Klipper (Python 3 venv, prebuilt C helper), Moonraker, KlipperScreen and crowsnest through their own unattended installers, plus Mainsail, moonraker-timelapse and nginx.
  - It also adds a first-boot service that runs `resize2fs` and generates SSH host keys.
- Stage 3, [03-make-image.sh](scripts/03-make-image.sh):
  - creates an ext4 `rootfs.fex` with exactly the stock feature list. Default `mke2fs` features such as `orphan_file` are unknown to the 4.9 kernel.
  - repacks the IMAGEWTY with a regenerated `Vrootfs.fex`;
  - writes the card head plus the new firmware;
  - rewrites the card GPT (p2 starts 1,024 sectors after the firmware, unaligned, as on the v1.2 and v1.4 cards; it ends 2,048 sectors before the end), zeroes unused card-head sectors, then verifies and compresses the image.
- Validation of [sunxi_card.py](scripts/sunxi_card.py): unpacking and repacking the stock card reproduces it byte-for-byte for the entire IMAGEWTY, every byte before the end of the firmware, and the backup GPT. The only difference is the unused trailing card partition, which holds residual data on the stock card and zeros in ours.
- Build-host findings:
  - WSL masks `systemd-binfmt`, so the scripts register the qemu handler themselves.
  - Ubuntu 24.04's `debian-archive-keyring` (2023.4) lacks Debian's current signing keys, so non-Debian hosts fetch the current keyring package over HTTPS.
  - The WSL virtual disk lives on C:. When the host disk filled up during decompression, the Linux filesystem was remounted read-only.

Superseded alternatives: patching the stock armhf rootfs in place (Route A), or updating over SSH after restoring the stock image (Route C). Both are still valid but produce no reproducible image.

## Open questions / next investigation

1. **Hardware test (done, 2026-11-20).** The repacked card flashes with sprite, and Debian 12 (systemd 252) boots on the 4.9 kernel. Problems found on hardware, all now fixed in the build scripts:
   - **Kernel `clock_getres` bug:** the vendor 4.9.191 arm64 vDSO returns `tv_nsec = 547619211008` (about 547 s) for `CLOCK_REALTIME`/`CLOCK_MONOTONIC`. `CLOCK_BOOTTIME`, which uses the system call, correctly returns 1 ns. Python sets `asyncio`'s `_clock_resolution` from this value, so `wait_for()` and every timer due within ~9 minutes fires at once. That broke KlipperScreen's websocket pings, Moonraker's D-Bus and `git` calls, and made touch look broken. The stock armhf userspace used the 32-bit compat vDSO and was not affected. Fix: an `LD_PRELOAD` shim in `/etc/ld.so.preload` that forwards `clock_getres()` to the system call.
   - **Moonraker polkit rules:** `install-moonraker.sh` calls `set-policykit-rules.sh`, which refuses to run as root, so no rules were installed. The provision script now runs it explicitly.
   - **Stock config:** `max_accel_to_decel` became `minimum_cruise_ratio`. The printer board's CH340 (`1a86:7523`) is now referenced by USB id; on this pad it enumerated on port `1.2`, not the stock `1.4`.
   - **MCU firmware:** the V400 board ran FLSUN's Klipper `v0.10.0-439-gdfa5afdf` (`stm32f103xe`, USART3, 250000 baud). It was rebuilt from the host's v0.14.0 commit (28 KiB bootloader offset, 8 MHz crystal, USART3), converted with `update_mks_robin.py`, and flashed from a plain MBR/FAT32 SD card. The PhoenixCard TF card is GPT-partitioned and is not read by the board's bootloader. Klipper then loaded the MCU at v0.14.0 (143 commands).
   - **Extruder −70 °C (hardware, not software):** with both the old and the new MCU firmware, `heater_bed` read about 17.5 °C but `extruder` (EPCOS 100K on PC1/TH0, unchanged from stock) read −70 to −76 °C, then shut down with "ADC out of range". That is an open-circuit thermistor reading: check the hotend connector at the effector and TH0, or the thermistor itself.
2. Read the rest of `rockchip.sh` and the `printer_{1,2,3}` configs to see which instance is the V400, and how the MCU serial port and the KlipperScreen/display are wired.
3. ~~Check whether SSH host keys and machine IDs are baked into the stock image.~~ Answered: yes, in both v1.2 and v1.4 (see Root filesystem and [SPEEDERPAD_V1.2_VS_V1.4.md](./SPEEDERPAD_V1.2_VS_V1.4.md)). The custom image ships neither and generates them on first boot.
4. ~~Find the upstream Klipper base of `klipper_fs` at `e002f0cf` and list FLSUN's changes.~~ Answered: upstream `ada571ecb` plus 4 small commits; see [FLSUN's modifications to the printer software](#flsuns-modifications-to-the-printer-software). The imported configs don't depend on any of them.
5. Bluetooth: replace the stock 32-bit `brcm_patchram_plus1` with an arm64 build or `hciattach`.
