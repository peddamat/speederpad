#!/usr/bin/env bash
# Stage 2: build a fresh Debian rootfs for the Speeder Pad and install the
# Klipper stack into it (runs the target arch under qemu-user). Needs root.
. "$(dirname "$0")/lib.sh"
load_config
require_root
require_cmds mmdebstrap python3 git curl dpkg-deb
ensure_binfmt "$ARCH"
[ -f "${STOCK_DIR}/.extract-done" ] || die "run stage 1 (extract) first"
[ "$CAN_MODULES" != 1 ] || [ -f "${MODULES_DIR}/.build-done" ] \
    || die "run stage 1b (modules) first, or set CAN_MODULES=0"

components="main contrib non-free"
[ "$SUITE" != bullseye ] && components="$components non-free-firmware"
polkit_pkg=polkitd
[ "$SUITE" = bullseye ] && polkit_pkg=policykit-1

packages=(
    systemd-sysv udev dbus "$polkit_pkg" sudo locales tzdata ca-certificates
    openssh-server avahi-daemon libnss-mdns
    network-manager wpasupplicant iw wireless-regdb rfkill
    nginx git curl wget unzip xz-utils less nano usbutils iproute2 iputils-ping
    e2fsprogs systemd-timesyncd kmod
    python3 python3-venv python3-virtualenv python3-dev virtualenv
    build-essential libffi-dev libncurses-dev libusb-dev libusb-1.0-0 pkg-config
)
if [ "$INSTALL_MCU_TOOLCHAIN" = 1 ]; then
    packages+=(stm32flash dfu-util gcc-arm-none-eabi binutils-arm-none-eabi
               libnewlib-arm-none-eabi avrdude gcc-avr binutils-avr avr-libc)
fi

log "Preparing Debian ${SUITE} ${ARCH} base system in ${ROOTFS_DIR}"
keyring="$(debian_keyring)"
echo "  archive keyring: $keyring"
src_opts="[signed-by=${keyring}]"
cache_key="$(printf '%s\n' "$SUITE" "$ARCH" "$MIRROR" "$SECURITY_MIRROR" "$components" "${packages[@]}" \
    | sha256sum | cut -c1-16)"
cache_tar="${CACHE_DIR}/base-${SUITE}-${ARCH}-${cache_key}.tar"
tar_opts=(--numeric-owner --xattrs --xattrs-include='*' --acls)
rm -rf "$ROOTFS_DIR"
if [ "$CACHE_BASE" = 1 ] && [ -f "$cache_tar" ]; then
    echo "  restoring cached base system $(basename "$cache_tar")"
    mkdir -p "$ROOTFS_DIR"
    tar -xpf "$cache_tar" "${tar_opts[@]}" -C "$ROOTFS_DIR"
else
    mmdebstrap --mode=root --format=directory --variant=minbase \
        --architectures="$ARCH" \
        --keyring="$keyring" \
        --include="$(IFS=,; echo "${packages[*]}")" \
        --aptopt='Acquire::Retries "5"' \
        --aptopt='APT::Install-Recommends "false"' \
        "$SUITE" "$ROOTFS_DIR" \
        "deb ${src_opts} ${MIRROR} ${SUITE} ${components}" \
        "deb ${src_opts} ${MIRROR} ${SUITE}-updates ${components}" \
        "deb ${src_opts} ${SECURITY_MIRROR} ${SUITE}-security ${components}"
    # The build-host keyring path is meaningless on the pad; use the target's own.
    for f in "${ROOTFS_DIR}/etc/apt/sources.list" "${ROOTFS_DIR}"/etc/apt/sources.list.d/*.list; do
        if [ -f "$f" ]; then sed -i 's#\[signed-by=[^]]*\] ##' "$f"; fi
    done
    if [ "$CACHE_BASE" = 1 ]; then
        echo "  caching base system as $(basename "$cache_tar")"
        mkdir -p "$CACHE_DIR"
        rm -f "${CACHE_DIR}"/base-"${SUITE}-${ARCH}"-*.tar
        tar -cpf "${cache_tar}.partial" "${tar_opts[@]}" -C "$ROOTFS_DIR" .
        mv "${cache_tar}.partial" "$cache_tar"
    fi
fi

log "Staging build inputs"
stage="${ROOTFS_DIR}/var/tmp/speederpad-build"
mkdir -p "$stage"
cp -a "${REPO_DIR}/scripts/chroot/provision.sh" "$stage/"
cp -a "${REPO_DIR}/overlay" "$stage/overlay"
cp -a "$VENDOR_DIR" "$stage/vendor"
if [ "$CAN_MODULES" = 1 ]; then cp -a "$MODULES_DIR" "$stage/modules"; fi
{
    for v in SUITE HOSTNAME_PAD USERNAME PASSWORD TIMEZONE LOCALE WIFI_SSID WIFI_PSK \
             INSTANCES IMPORT_STOCK_CONFIG STOCK_COMPAT_MACROS KLIPPER_REPO KLIPPER_REF MOONRAKER_REPO \
             MOONRAKER_REF KLIPPERSCREEN_REPO KLIPPERSCREEN_REF MAINSAIL_VERSION \
             INSTALL_CROWSNEST CROWSNEST_REPO CROWSNEST_REF INSTALL_TIMELAPSE \
             TIMELAPSE_REPO TIMELAPSE_REF CAN_MODULES CAN_BITRATE; do
        printf '%s=%q\n' "$v" "${!v}"
    done
} > "$stage/build.env"
chmod 600 "$stage/build.env"

# Use the host resolver while building; NetworkManager owns it on the pad.
mv "${ROOTFS_DIR}/etc/resolv.conf" "${ROOTFS_DIR}/etc/resolv.conf.speederpad" 2>/dev/null || true
cp -L /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

trap chroot_umount EXIT
chroot_mount "$ROOTFS_DIR"
log "Provisioning inside the ${ARCH} chroot (slow under qemu)"
chroot "$ROOTFS_DIR" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /var/tmp/speederpad-build/provision.sh
chroot_umount
trap - EXIT

rm -f "${ROOTFS_DIR}/etc/resolv.conf"
if [ -e "${ROOTFS_DIR}/etc/resolv.conf.speederpad" ] || [ -L "${ROOTFS_DIR}/etc/resolv.conf.speederpad" ]; then
    mv "${ROOTFS_DIR}/etc/resolv.conf.speederpad" "${ROOTFS_DIR}/etc/resolv.conf"
fi
rm -rf "$stage"
log "Stage 2 done: $(du -sh "$ROOTFS_DIR" | cut -f1) rootfs in ${ROOTFS_DIR}"
