# Custom Speeder Pad image (current Klipper)

Scripts that build a flashable TF-card restore image for the FLSUN Speeder Pad
(Allwinner R818). The image runs a fresh Debian rootfs with current upstream
Klipper, Moonraker, Mainsail, KlipperScreen, crowsnest and moonraker-timelapse.

The vendor boot chain is reused unchanged from FLSUN's own restore image at
build time: boot0, U-Boot, ATF/SCP, device tree and the Linux 4.9.191 kernel,
plus the Wi-Fi firmware. No vendor binaries are stored in this repository. How
the stock image works is documented in
[SPEEDERPAD_IMAGE_ANALYSIS.md](SPEEDERPAD_IMAGE_ANALYSIS.md).

> **Status: experimental.** The image is built and verified offline (layout,
> checksums, filesystem), but it has not been confirmed on hardware with every
> combination of settings. Keep the stock restore image so you can always go
> back.

## What you need

- FLSUN's stock restore image, `SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz`
  (from [Flsun3d/Flsun_Speeder_Pad](https://github.com/Flsun3d/Flsun_Speeder_Pad)).
- One of these build hosts:
  - Debian/Ubuntu Linux or WSL2, with root, and:
    `sudo apt install mmdebstrap qemu-user-static binfmt-support e2fsprogs xz-utils python3 git curl ca-certificates`
  - Docker with `--privileged` support (`./docker-build.sh`).
- About 25 GB of free disk space, and Internet access.
- A TF card of 8 GB or larger.

## Build

1. Put the stock `.img.xz` in the repository root, or set `STOCK_IMAGE`.
2. Review [build.conf](build.conf). In particular, change `PASSWORD` before
   you share an image.
3. Run one of:

```bash
sudo ./build.sh                 # native Linux / WSL
./docker-build.sh               # Docker
```

Any `build.conf` value can be overridden from the environment, for example
`sudo INSTANCES=3 SUITE=bullseye ./build.sh`. Under WSL, put `WORK_DIR` and
`OUT_DIR` on the Linux filesystem rather than `/mnt/c`:

```bash
sudo WORK_DIR=$HOME/speederpad-work OUT_DIR=$HOME/speederpad-work/out ./build.sh
```

The result is `out/speederpad-klipper-<date>.img` plus a `.sha256` file. Set
`COMPRESS=1` to get a much smaller `.img.xz` for sharing instead.
The first build takes one to two hours, mostly running arm64 code under qemu.
The bootstrapped Debian base system is cached in `work/cache/`, so later
builds with the same suite, architecture, mirrors and package list skip that
step (about 20 minutes); pending updates are applied during provisioning.
Delete `work/cache/` to force a fresh bootstrap. Building on a native arm64
host avoids qemu entirely and is several times faster.

The build runs in three stages, which you can also run one at a time
(`sudo ./build.sh extract|rootfs|image`):

| Stage | Script | What it does |
|---|---|---|
| extract | [01-extract-vendor.sh](scripts/01-extract-vendor.sh) | Verifies the stock card's checksums. Saves the card head (boot0, card U-Boot, partition tables, FAT) and every firmware item except the rootfs. Copies the Wi-Fi firmware, touchscreen X config and stock printer configs. |
| rootfs | [02-build-rootfs.sh](scripts/02-build-rootfs.sh) | Runs `mmdebstrap` for Debian `SUITE`/`ARCH`, then [provision.sh](scripts/chroot/provision.sh) in a qemu chroot. That script runs the upstream Moonraker, KlipperScreen and crowsnest installers unattended and sets up the services. |
| image | [03-make-image.sh](scripts/03-make-image.sh) | Builds an ext4 `rootfs.fex` with the stock feature set (the 4.9 kernel can't mount newer ext4 features). Repacks the IMAGEWTY firmware with a regenerated `Vrootfs.fex` checksum, assembles the card image, verifies it and compresses it. |

[sunxi_card.py](scripts/sunxi_card.py) is the format tool behind stage 3, and
can be used on its own:

```bash
python3 scripts/sunxi_card.py info card.img --checksums   # layout + verify every V*.fex
python3 scripts/sunxi_card.py unpack card.img items/ --card-head head.bin
python3 scripts/sunxi_card.py repack items/ fw.img --replace rootfs.fex=my.ext4
python3 scripts/sunxi_card.py make-card --head head.bin --firmware fw.img --output card.img
```

Unpacking the stock card and repacking it with no changes reproduces the
stock card byte-for-byte, up to the end of the firmware and including the
backup GPT.

## Flash

This works like the stock restore. It **erases everything on the pad**.

1. Write the `.img` (or `.img.xz`) to a TF card with Rufus, Raspberry Pi
   Imager ("Use custom") or balenaEtcher.
2. Power off the pad, unplug all USB devices and insert the card.
3. Power on. A progress bar appears; wait until it is full and green (several
   minutes).
4. Power off, remove the card and power on again.

On the first boot the root filesystem grows to fill the eMMC and fresh SSH host
keys are generated.

To go back, flash the stock image the same way.

## After first boot

- KlipperScreen runs on the touchscreen. Its network panel (or `nmtui` over
  SSH) connects Wi-Fi, unless you set `WIFI_SSID`/`WIFI_PSK` in `build.conf`.
- Mainsail is at `http://speeder-pad.local/`. SSH as `pi` with the password
  from `build.conf` (default `flsun`).
- Data layout:
  - with `INSTANCES=1`: `~/printer_data/{config,logs,gcodes}`,
    `klipper.service`, `moonraker.service` (port 7125);
  - with `INSTANCES=N`: `~/printer_N_data`, `klipper-N`/`moonraker-N`, ports
    7125 and up.
- With `IMPORT_STOCK_CONFIG=1`, the stock `printer_N/*.cfg` files are copied
  in, with `~/gcode_files` and `~/savedVariablesN.cfg` paths rewritten.
  `max_accel_to_decel` (removed from Klipper) is converted to
  `minimum_cruise_ratio`, and `[mcu] serial` uses the board's USB id
  (`/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0`) so any pad USB socket
  works. Check `klippy.log` for other options current Klipper rejects.
- The V400 printer board must run firmware from the same Klipper version;
  otherwise Klipper refuses to connect with a version or command mismatch.
  Build it on a Linux PC from the same Klipper commit, or on the pad if the
  image was built with `INSTALL_MCU_TOOLCHAIN=1` (it is off by default to
  keep the build fast). Run `make menuconfig` (STM32F103, 28 KiB bootloader,
  8 MHz crystal, USART3 PB11/PB10). Then run
  `make && python3 scripts/update_mks_robin.py out/klipper.bin out/Robin_nano35.bin`
  and flash `Robin_nano35.bin` from the printer board's SD card.

## Known limitations

- The vendor kernel's arm64 vDSO `clock_getres()` reports a resolution of
  about 547 seconds. Python asyncio uses that as its timer granularity, so
  every timeout shorter than ~9 minutes fires immediately. Symptoms were
  KlipperScreen's "ping timed out" / "Broken pipe" loop, Moonraker's
  `machine` component failing, and touch appearing to work only on the left
  menu (the main screen was redrawn before taps registered). The image
  preloads a small library ([clock_getres_fix.c](overlay/src/clock_getres_fix.c),
  via `/etc/ld.so.preload`) that routes `clock_getres()` to the correct
  system call.
- The kernel is FLSUN's prebuilt 4.9.191, because no source is published. CAN
  bus is not enabled, and kernel modules cannot be added.
- Debian 12's systemd 252 is outside its recommended kernel range (4.15 and
  newer) on this 4.9 kernel. If the pad does not boot properly, rebuild with
  `SUITE=bullseye` (systemd 247; the Creality Sonic Pad port uses this).
- Bluetooth is not set up. The stock image used a 32-bit `brcm_patchram_plus1`
  binary.
- Only the IMAGEWTY v0x300 / sunxi_mbr v0x200 layout of this image is supported.
