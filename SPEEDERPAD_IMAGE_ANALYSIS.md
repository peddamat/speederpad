# Speeder Pad image investigation

Status: in progress. Scope is to investigate both host Klipper and V400 printer-MCU updates. This note records verified observations and keeps open questions separate from conclusions.

## Input and image format

- Input: [SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz](./SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz)
- Compressed size: 1,447,861,192 bytes.
- SHA-256 of compressed file: `9fc2bd41e8bd81166ed7e83fca1b5aae13ea216fc35ba53061e7ef132179860b`.
- Streaming decompression produced a 16,046,882,816-byte raw disk image with SHA-256 `fe6dbba17640a6c74103e80a1ecdda56cc3bf9859fda32207221d8ad912ab66d`.
- The image has a protective MBR and GPT. The GPT uses 512-byte sectors and has four entry slots, two populated:
  - `boot-resource`: LBA 41,984–50,175 (4 MiB).
  - `env`: LBA 11,156,960–31,339,519 (about 9.62 GiB).
- An ext4 filesystem labeled `rootfs` begins at byte offset 42,593,280 (LBA 83,190), outside those two GPT entries. It has 5,536,370 1-KiB blocks (about 5.28 GiB). Its end is roughly 0.5 MiB before the `env` GPT partition begins.
- The rootfs image has no files in `/boot`; boot/kernel content is elsewhere in the raw image. Preserve the whole disk layout rather than treating this as a standalone rootfs image.
- Boot-region strings identify an Allwinner `r818` device tree, U-Boot `2018.05-g9b56363` (built 2021-02-19), and Linux `4.9.191` (GCC 6.4.1, build #97, 2022-12-03). This is an Allwinner R818 image, not a Rockchip image.
- An ext4-looking superblock was also found inside the `env` GPT range, but an extracted candidate could not enumerate its root directory (`debugfs` reports missing inode tables). It is not yet confirmed as a usable filesystem or as the purpose of that partition.

## Root filesystem

- `/etc/os-release` identifies Ubuntu 20.04.5 LTS (Focal).
- The rootfs ext4 volume is labeled `rootfs`, was created on 2023-03-02, and was clean when inspected.
- Klipper is checked out at `/home/pi/klipper`, branch `master`, commit `e002f0cfa9358c4a9abb66ab43bc018fc8f86981`. Its Git remote is `https://gitee.com/leexxiangyang/klipper.git`.
- The Gitee remote's current `master` ref resolves to that same commit, so it has not advanced beyond the image's checkout.
- The host Klipper environment is a Python 2.7 virtualenv. Moonraker has a separate Python 3.8.10 virtualenv.
- Klipper and Moonraker are configured as three separate systemd instances (`*-1`, `*-2`, `*-3`), with per-instance configs/logs. For example, `klipper-1.service` runs `/home/pi/klipper/klippy/klippy.py` using `/home/pi/klippy-env/bin/python`.
- `/etc/fstab` is the unconfigured base-system file. `/boot` is empty in this filesystem.

## Public sources checked

- The [FLSUN Speeder Pad repository](https://github.com/Flsun3d/Flsun_Speeder_Pad) documents TF-card restore/update procedures and provides printer-MCU firmware/configuration files. Its repository root has `README.md`, `firmware/`, and `image/`; no Linux image build recipe was found there.
- FLSUN's README points to its [Klipper fork](https://github.com/Flsun3d/klipper_fs), but the Klipper checkout embedded in this image points at a different Gitee remote. The image checkout and FLSUN's public fork should not be assumed interchangeable without comparing their changes.
- The vendor's documented restore flow writes the full image from a TF card and warns that restoring resets settings/data on the pad.
- Current upstream Klipper `master` was at `b670adc92bf92b304e76c3c2f36f5d8f98a4e2f1` (2026-11-19) when checked. Its host entrypoint still uses a Python 2 shebang and its Debian installer still creates a Python 2 environment, so the existing Python 2.7 host environment is not by itself proof that an upstream update is impossible. The exact current dependency set and three-instance service integration still need testing.
- A [public FLSUN issue](https://github.com/Flsun3d/Flsun_Speeder_Pad/issues/8) reports a 4.9.191 aarch64 Speeder Pad kernel and remains open without a source response. This is a useful lead, not yet a direct identification of this image's embedded kernel.

## V400 printer-MCU path

- FLSUN's [V400 printer configuration](https://github.com/Flsun3d/Flsun_Speeder_Pad/blob/main/firmware/V400/printer.cfg) identifies an MKS Robin Nano V2 / STM32F103 and gives the Klipper build settings: 28-KiB bootloader, 8-MHz crystal, and USART3 on PB11/PB10.
- The [V400 firmware instructions](https://github.com/Flsun3d/Flsun_Speeder_Pad/blob/main/firmware/V400/readme.txt) name the output `Robin_nano35.bin` and flash it from a printer-board SD card.
- Current upstream still contains the matching [generic Robin Nano V2 config](https://github.com/Klipper3d/klipper/blob/master/config/generic-mks-robin-nano-v2.cfg) and [MKS Robin conversion script](https://github.com/Klipper3d/klipper/blob/master/scripts/update_mks_robin.py). The script converts `out/klipper.bin` to the bootloader-specific image; it is a separate step from building the host Klipper service and uses Python 3.
- Therefore the host update and V400 MCU update can be built from one chosen Klipper revision, but they are separate outputs and separate flashing operations. The MCU `.bin` is flashed to the printer board, not by writing the Speeder Pad restore image.

## Working conclusions

- This is a whole-device restore image, not a conventional partitioned OS image that can be rebuilt from a published vendor image-builder repository.
- A practical first custom-image route is likely to preserve the vendor's boot/raw layout and update the host Klipper checkout and its dependencies in the existing rootfs, keeping the vendor's three-instance systemd wiring and printer configuration. A generic upstream installer may replace that multi-instance setup, so it should not be run unchanged.
- Klipper host software and the printer MCU firmware are separate deliverables. Updating the host checkout does not automatically rebuild or flash the printer controller firmware.
- The public material found so far is insufficient to claim a reproducible from-source build of the original bootloader/kernel/image. In particular, the vendor repository has no image builder, and the public kernel-source request remains unanswered; preserve the existing Allwinner boot chain for the first custom image.

## Open questions / next investigation

1. Identify the boot/update payloads in the raw regions and the role of the `env` GPT partition; the ext4-looking candidate there is not yet verified as mountable.
2. Verify the rootfs CPU ABI and how the Allwinner boot/update chain consumes the raw regions.
3. Determine whether the Gitee Klipper commit is upstream-compatible or contains required device-specific changes; compare it with current Klipper and FLSUN's public fork.
4. Inspect the active V400 instance config and all three service files, then compare the embedded Gitee checkout with current upstream and FLSUN's fork.
5. Test current Klipper host dependencies on the image's Python 2.7 environment and build the V400 STM32F103 image with the vendor's exact settings.
6. Design image-level validation (GPT/raw layout, filesystem integrity, service startup, network/UI readiness) before producing any flashable image.

