# Custom Speeder Pad image (current Klipper)

Scripts that build a flashable TF-card restore image for the FLSUN Speeder Pad
(Allwinner R818). The image runs a fresh Debian rootfs with current upstream
Klipper, Moonraker, Mainsail, KlipperScreen, crowsnest and moonraker-timelapse.

The vendor boot chain is reused unchanged from FLSUN's own restore image at
build time: boot0, U-Boot, ATF/SCP, device tree and the Linux 4.9.191 kernel,
plus the Wi-Fi firmware. No vendor binaries are stored in this repository.
CAN bus support, which the stock kernel lacks, is added as loadable modules
built for that same kernel. How the stock image works is documented in
[SPEEDERPAD_IMAGE_ANALYSIS.md](SPEEDERPAD_IMAGE_ANALYSIS.md).

> **Status: experimental.** The image is built and verified offline (layout,
> checksums, filesystem), but it has not been confirmed on hardware with every
> combination of settings. Keep the stock restore image so you can always go
> back.

## What you need

- FLSUN's stock restore image, `SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz` or
  `SPEEDERPADPADV1.4V2_TFCARD-230907.img.xz`
  (from [Flsun3d/Flsun_Speeder_Pad](https://github.com/Flsun3d/Flsun_Speeder_Pad)).
  Their boot chains and kernels are byte-identical, so either works; they
  differ only in the stock printer configs that get imported. See
  [SPEEDERPAD_V1.2_VS_V1.4.md](SPEEDERPAD_V1.2_VS_V1.4.md).
- One of these build hosts:
  - Debian/Ubuntu Linux or WSL2, with root, and:
    `sudo apt install mmdebstrap qemu-user-static binfmt-support e2fsprogs xz-utils python3 git curl ca-certificates`
  - For the CAN modules (`CAN_MODULES=1`, the default), also:
    `sudo apt install build-essential bc flex bison gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu`
    (on an arm64 host the native `gcc` is used instead).
  - Docker with `--privileged` support (`./docker-build.sh`).
- About 27 GB of free disk space, and Internet access.
- A TF card of 8 GB or larger.

## Build

1. Put the stock `.img.xz` in the repository root, or set `STOCK_IMAGE`. To
   keep v1.2 as the boot-chain source but import the v1.4 V400 `printer.cfg`
   (spreadCycle, higher speed limits, `[exclude_object]`), also set
   `STOCK_CONFIG_IMAGE=SPEEDERPADPADV1.4V2_TFCARD-230907.img.xz`. Setting
   `STOCK_IMAGE` to the v1.4 file gives the same result.
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

The build runs in four stages, which you can also run one at a time
(`sudo ./build.sh extract|modules|rootfs|image`):

| Stage | Script | What it does |
|---|---|---|
| extract | [01-extract-vendor.sh](scripts/01-extract-vendor.sh) | Verifies the stock card's checksums. Saves the card head (boot0, card U-Boot, partition tables, FAT) and every firmware item except the rootfs. Copies the Wi-Fi firmware and touchscreen X config, and the stock printer configs (from `STOCK_CONFIG_IMAGE` if set). Nothing else from the stock rootfs is used. |
| modules | [01b-build-modules.sh](scripts/01b-build-modules.sh) | With `CAN_MODULES=1`: reads the kernel, its embedded config and its exported-symbol CRCs out of the stock `boot.fex`, fetches the matching Allwinner linux-4.9 BSP source (about 1.1 GB, cached in `work/cache/kernel-src`), and builds `can`, `can-raw`, `can-bcm`, `can-dev` and `gs_usb`. It checks every imported symbol's CRC and the vermagic against the stock kernel and refuses modules that don't match. Takes a few minutes. |
| rootfs | [02-build-rootfs.sh](scripts/02-build-rootfs.sh) | Runs `mmdebstrap` for Debian `SUITE`/`ARCH`, then [provision.sh](scripts/chroot/provision.sh) in a qemu chroot. That script runs the upstream Moonraker, KlipperScreen and crowsnest installers unattended, sets up the services and installs the CAN modules. |
| image | [03-make-image.sh](scripts/03-make-image.sh) | Builds an ext4 `rootfs.fex` with the stock feature set (the 4.9 kernel can't mount newer ext4 features). Repacks the IMAGEWTY firmware with a regenerated `Vrootfs.fex` checksum, assembles the card image, verifies it and compresses it. |

[sunxi_card.py](scripts/sunxi_card.py) is the format tool behind stage 3, and
can be used on its own:

```bash
python3 scripts/sunxi_card.py info card.img --checksums   # layout + verify every V*.fex
python3 scripts/sunxi_card.py unpack card.img items/ --card-head head.bin
python3 scripts/sunxi_card.py repack items/ fw.img --replace rootfs.fex=my.ext4
python3 scripts/sunxi_card.py make-card --head head.bin --firmware fw.img --output card.img
```

`make-card` zeroes the unused sectors in front of the firmware. Stock cards
carry leftovers there from the card's previous contents. Everything the
loaders read (MBR/GPT, boot0, boot package, sunxi_mbr, card FAT) is copied
unchanged. With `--keep-gaps`, unpacking a stock card and repacking it with no
changes reproduces it byte-for-byte, up to the end of the firmware and
including the backup GPT. This was checked on both v1.2 and v1.4.

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
- With `IMPORT_STOCK_CONFIG=1`, the stock `printer_N/*.cfg` files (and
  `*.cfg` one directory down, such as v1.4's `adxl345/adxl345.cfg`) are copied
  in, with `~/gcode_files` and `~/savedVariablesN.cfg` paths rewritten.
  The v1.4 image has only `printer_1`.
  `max_accel_to_decel` (removed from Klipper) is converted to
  `minimum_cruise_ratio`, and `[mcu] serial` uses the board's USB id
  (`/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0`) so any pad USB socket
  works. A stray `|` after `{% endif %}` in FLSUN's `LOAD_GCODE_OFFSETS`
  macro is removed; Klipper otherwise logs `Unknown command:"|"` on every
  start. Check `klippy.log` for other options current Klipper rejects.
- With `STOCK_COMPAT_MACROS=1` (default), an imported config also gets
  [stock-compat.cfg](overlay/templates/stock-compat.cfg), included from the
  top of `printer.cfg`. It recreates FLSUN's Klipper fork behaviour:
  - `M109`/`M190` stop waiting once the heater is within 3 °C of the target
    (upstream: within 1 °C and stable). Adjust `variable_tolerance` in the file.
  - `M205 X<n>` (slicer jerk) sets `square_corner_velocity`.

  Delete the `[include stock-compat.cfg]` line for upstream behaviour.
- `DELTA_CALIBRATE` (and the stock `bed_level_1` macro) saves the calibrated
  `delta_radius` and tower angles on upstream Klipper. FLSUN's fork kept them
  at 161.75 and 210/330/90; restore those values if calibration gets worse.
- The V400 printer board must run firmware from the same Klipper version;
  otherwise Klipper refuses to connect with a version or command mismatch.
  Build it on a Linux PC from the same Klipper commit, or on the pad if the
  image was built with `INSTALL_MCU_TOOLCHAIN=1` (it is off by default to
  keep the build fast). Run `make menuconfig` (STM32F103, 28 KiB bootloader,
  8 MHz crystal, USART3 PB11/PB10). Then run
  `make && python3 scripts/update_mks_robin.py out/klipper.bin out/Robin_nano35.bin`
  and flash `Robin_nano35.bin` from the printer board's SD card.

## CAN bus (USB-to-CAN bridge boards)

With `CAN_MODULES=1` the image loads `can`/`can_raw` at boot, `gs_usb` binds
to any Klipper USB-to-CAN bridge (USB id `1d50:606f`), and a udev rule brings
each `can*` interface up at `CAN_BITRATE` (default 1000000) with
`txqueuelen 128`. Nothing else is needed on the pad. This was tested with a
Fly D5 (STM32F072) as the bridge.

Bridge board firmware (Fly D5 example; build it on the pad if it has
`arm-none-eabi-gcc`, or on a PC from the same Klipper commit):

- Katapult (optional): STM32F072, 8 MHz crystal, USB on PA11/PA12,
  application start offset 8KiB.
- Klipper: STM32F072, 8KiB bootloader (no bootloader: 0), 8 MHz crystal,
  communication interface "USB to CAN bus bridge (USB on PA11/PA12)",
  CAN bus on PB8/PB9, CAN bus speed equal to `CAN_BITRATE`.

The STM32 ROM DFU loader always works, whatever is in flash: hold BOOT, tap
RESET, and the board appears as `0483:df11`. Then:

```bash
dfu-util -a 0 -d 0483:df11 -s 0x08002000 -D klipper.bin                 # Klipper after Katapult
dfu-util -a 0 -d 0483:df11 -s 0x08000000:leave -D katapult.bin          # Katapult
# (without Katapult: flash klipper.bin to 0x08000000:leave instead)
```

Check that each board gets a bootloader built for its own MCU. A Katapult
built for the EBB42's STM32G0B1 flashed onto the D5's F072 crashes before USB
starts, so the board never shows up in `lsusb`, and Klipper only reports
"Unable to connect". `dfu-util -U` can read flash back for inspection: an
initial stack pointer beyond the MCU's RAM (the F072 has 16 KiB, ending at
`0x20004000`) means the wrong build.

Find the node ids and put them in `printer.cfg` instead of `serial:`:

```bash
ip -details link show can0                                              # state ERROR-ACTIVE, bitrate 1000000
~/klippy-env/bin/python ~/klipper/scripts/canbus_query.py can0          # canbus_uuid=..., Application: Klipper
```

```ini
[mcu]
canbus_uuid: <bridge uuid>
```

A toolhead board such as an EBB42 on the same bus gets its own `[mcu name]`
section with its own `canbus_uuid`. Every board must use the same CAN speed
and run firmware from the pad's Klipper version.

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
- The kernel is FLSUN's prebuilt 4.9.191, because no source is published.
  Extra modules can be built for it from the matching Allwinner BSP tree
  (see [SPEEDERPAD_IMAGE_ANALYSIS.md](SPEEDERPAD_IMAGE_ANALYSIS.md#kernel-modules));
  only the CAN modules are built. Built-in options can't be changed.
- Debian 12's systemd 252 is outside its recommended kernel range (4.15 and
  newer) on this 4.9 kernel. If the pad does not boot properly, rebuild with
  `SUITE=bullseye` (systemd 247; the Creality Sonic Pad port uses this).
- Bluetooth is not set up. The stock image used a 32-bit `brcm_patchram_plus1`
  binary.
- Only the IMAGEWTY v0x300 / sunxi_mbr v0x200 layout of this image is supported.
