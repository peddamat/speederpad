#!/bin/bash
# Runs inside the target chroot (as root) to configure the OS and install the
# Klipper stack. Inputs are staged in /var/tmp/speederpad-build by stage 2.
set -euo pipefail
trap 'echo "provision.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR

BUILD=/var/tmp/speederpad-build
# shellcheck source=/dev/null
. "$BUILD/build.env"
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

HOMEDIR="/home/${USERNAME}"
STOCK_HOME=/home/pi

log() { printf '\n--> %s\n' "$*"; }

as_user() {
    runuser -u "$USERNAME" -- env HOME="$HOMEDIR" USER="$USERNAME" LOGNAME="$USERNAME" \
        PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin \
        LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"
}

clone() {  # repo ref dest
    as_user git clone --quiet "$1" "$3"
    as_user git -C "$3" checkout --quiet "$2"
    echo "  $(basename "$3"): $(as_user git -C "$3" describe --always --tags) ($1 @ $2)"
}

# setuid sudo cannot elevate under qemu-user unless the host's binfmt handler
# has the C flag, which most hosts (Ubuntu, WSL, Docker) lack. So upstream
# installers that refuse root and call sudo run as root, with USER/HOME set to
# the target user, a pass-through sudo, and their root check disabled in a
# temporary copy kept next to the original so relative paths still resolve.
SHIM_DIR=/var/tmp/speederpad-shim
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/sudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -u|-g|-C|-h|-p) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
chmod 755 "$SHIM_DIR/sudo"

run_installer() {  # script [args...]
    local script="$1"; shift
    local copy; copy="$(dirname "$script")/.speederpad-$(basename "$script")"
    sed -e 's/"\$EUID" -eq 0/"$EUID" -eq -1/g' -e 's/"\$EUID" == 0/"$EUID" == -1/g' "$script" > "$copy"
    env HOME="$HOMEDIR" USER="$USERNAME" LOGNAME="$USERNAME" SUDO_USER="$USERNAME" \
        PATH="$SHIM_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "${INSTALLER_ENV[@]}" bash "$copy" "$@"
    rm -f "$copy"
}
git config --system safe.directory '*'

instance_suffix() { [ "$INSTANCES" -eq 1 ] && echo "" || echo "-$1"; }
instance_data() { [ "$INSTANCES" -eq 1 ] && echo "$HOMEDIR/printer_data" || echo "$HOMEDIR/printer_$1_data"; }
instance_port() { echo $((7124 + $1)); }

render() {  # template dest: substitute @VAR@ placeholders
    sed -e "s|@HOME@|$HOMEDIR|g" -e "s|@USER@|$USERNAME|g" "$1" > "$2"
}

# Keep package maintainer scripts from starting services in the chroot.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

# The base system may come from the build cache; bring it up to date.
log "Applying pending Debian updates"
apt-get update -qq
apt-get -y -qq full-upgrade >/dev/null

# ---------------------------------------------------------------- base system
log "Base system: hostname, locale, timezone, user"
echo "$HOSTNAME_PAD" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${HOSTNAME_PAD}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
sed -i "s/^# *\(${LOCALE//./\\.} \)/\1/" /etc/locale.gen
grep -q "^${LOCALE} " /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen >/dev/null
update-locale LANG="$LOCALE"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

useradd -m -s /bin/bash "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | chpasswd
for g in sudo adm dialout tty video input render audio plugdev netdev systemd-journal; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$USERNAME"
done
chmod 755 "$HOMEDIR"

cat > /etc/fstab <<'EOF'
# The vendor kernel mounts the root filesystem from /dev/mmcblk0p5 (eMMC
# partition "rootfs"), read-write, before userspace starts.
LABEL=rootfs  /  ext4  defaults,noatime  0  0
EOF

log "Device support from the stock image"
install -m 644 "$BUILD"/vendor/firmware/* /usr/lib/firmware/
mkdir -p /etc/X11/xorg.conf.d
if compgen -G "$BUILD/vendor/xorg.conf.d/*" >/dev/null; then
    install -m 644 "$BUILD"/vendor/xorg.conf.d/* /etc/X11/xorg.conf.d/
fi

# The vendor kernel's vDSO clock_getres() reports ~547 s resolution, which
# makes every asyncio timeout fire immediately; see overlay/src.
log "Kernel clock_getres workaround"
gcc -O2 -shared -fPIC -o /usr/local/lib/libclock_getres_fix.so "$BUILD/overlay/src/clock_getres_fix.c"
echo /usr/local/lib/libclock_getres_fix.so > /etc/ld.so.preload

if [ "$CAN_MODULES" = 1 ]; then
    krel="$(cat "$BUILD/modules/kernel-release")"
    log "CAN bus kernel modules for ${krel}"
    cp -rT --no-preserve=ownership "$BUILD/modules/lib/modules" /lib/modules
    # Only these modules exist outside the kernel image; empty indexes keep depmod quiet.
    touch "/lib/modules/$krel/modules.order" "/lib/modules/$krel/modules.builtin" \
          "/lib/modules/$krel/modules.builtin.modinfo"
    depmod -a "$krel"
    # gs_usb loads from its USB alias; the protocol modules are loaded up front.
    printf 'can\ncan_raw\n' > /etc/modules-load.d/can.conf
    cat > /etc/udev/rules.d/80-can.rules <<EOF
# Bring CAN interfaces (e.g. a Klipper USB-to-CAN bridge) up at ${CAN_BITRATE} bit/s.
SUBSYSTEM=="net", ACTION=="add", KERNEL=="can*", RUN+="/usr/sbin/ip link set %k type can bitrate ${CAN_BITRATE}", RUN+="/usr/sbin/ip link set %k txqueuelen 128", RUN+="/usr/sbin/ip link set %k up"
EOF
fi

log "Overlay files"
cp -rT --no-preserve=mode,ownership "$BUILD/overlay/rootfs" /
chmod 755 /usr/local/sbin/speederpad-firstboot
systemctl enable speederpad-firstboot.service NetworkManager.service ssh.service avahi-daemon.service >/dev/null

if [ -n "$WIFI_SSID" ]; then
    log "Wi-Fi profile for ${WIFI_SSID}"
    f="/etc/NetworkManager/system-connections/${WIFI_SSID//\//_}.nmconnection"
    {
        printf '[connection]\nid=%s\ntype=wifi\nautoconnect=true\n\n' "$WIFI_SSID"
        printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$WIFI_SSID"
        if [ -n "$WIFI_PSK" ]; then
            printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$WIFI_PSK"
        fi
        printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } > "$f"
    chmod 600 "$f"
fi

# --------------------------------------------------------------------- Klipper
log "Klipper"
clone "$KLIPPER_REPO" "$KLIPPER_REF" "$HOMEDIR/klipper"
as_user python3 -m venv "$HOMEDIR/klippy-env"
as_user "$HOMEDIR/klippy-env/bin/pip" install --quiet --upgrade pip
as_user "$HOMEDIR/klippy-env/bin/pip" install --quiet -r "$HOMEDIR/klipper/scripts/klippy-requirements.txt"
# Build the C helper now so the first start on the pad doesn't need to.
as_user "$HOMEDIR/klippy-env/bin/python" -c \
    "import sys; sys.path.insert(0, '$HOMEDIR/klipper/klippy'); import chelper; chelper.get_ffi()"

for i in $(seq 1 "$INSTANCES"); do
    sfx="$(instance_suffix "$i")"; data="$(instance_data "$i")"
    as_user mkdir -p "$data"/{config,logs,gcodes,systemd,comms,database}
    as_user tee "$data/systemd/klipper.env" >/dev/null <<EOF
KLIPPER_ARGS="$HOMEDIR/klipper/klippy/klippy.py $data/config/printer.cfg -I $data/comms/klippy.serial -l $data/logs/klippy.log -a $data/comms/klippy.sock"
EOF
    cat > "/etc/systemd/system/klipper${sfx}.service" <<EOF
[Unit]
Description=Klipper 3D Printer Firmware SV1${sfx:+ (instance ${i})}
Documentation=https://www.klipper3d.org/
After=network-online.target
Wants=udev.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
User=$USERNAME
RemainAfterExit=yes
WorkingDirectory=$HOMEDIR/klipper
EnvironmentFile=$data/systemd/klipper.env
ExecStart=$HOMEDIR/klippy-env/bin/python \$KLIPPER_ARGS
Restart=always
RestartSec=10
EOF
    systemctl enable "klipper${sfx}.service" >/dev/null
done

# ------------------------------------------------------------- printer config
# Adapt a stock FLSUN printer.cfg (written for their 2022 Klipper fork) to
# current Klipper:
#  * max_accel_to_decel was removed; minimum_cruise_ratio = 1 - a2d/max_accel
#  * the main MCU (MKS Robin Nano CH340) is addressed by its USB id instead of
#    the fixed pad port, so it works from any of the pad's USB sockets
upgrade_printer_cfg() {
    local cfg="$1"
    python3 - "$cfg" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
m_acc = re.search(r'^max_accel\s*[:=]\s*([0-9.]+)', text, re.M)
m_a2d = re.search(r'^max_accel_to_decel\s*[:=]\s*([0-9.]+).*$', text, re.M)
if m_a2d:
    ratio = 0.5
    if m_acc and float(m_acc.group(1)) > 0:
        ratio = max(0.0, min(1.0, 1 - float(m_a2d.group(1)) / float(m_acc.group(1))))
    text = text.replace(m_a2d.group(0),
        "minimum_cruise_ratio: %.3f  # converted from %s" % (ratio, m_a2d.group(0).strip()))
text = re.sub(r'(?m)^(\[mcu\]\s*\n(?:[^\[\n].*\n)*?)serial:\s*/dev/serial/by-path/\S*ehci1-controller-usb-0:1\.4:1\.0-port0.*$',
              r'\1serial: /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0  # stock: fixed pad port 1.4', text)
open(path, "w").write(text)
PY
}

import_config() {  # instance data_dir
    local src="$BUILD/vendor/klipper_config/printer_$1" data="$2" f base
    [ "$IMPORT_STOCK_CONFIG" = 1 ] && [ -f "$src/printer.cfg" ] || return 1
    for f in "$src"/*.cfg "$src"/*/*.cfg; do
        [ -f "$f" ] || continue
        base="${f#"$src"/}"
        [ "$base" = timelapse.cfg ] && [ "$INSTALL_TIMELAPSE" = 1 ] && continue
        as_user mkdir -p "$data/config/$(dirname "$base")"
        sed -E \
            -e "s#(~|$STOCK_HOME)/gcode_files#$data/gcodes#g" \
            -e "s#(~|$STOCK_HOME)/(savedVariables[0-9]*\.cfg)#$data/config/\2#g" \
            -e "s#(~|$STOCK_HOME)/klipper_config(/printer_[0-9]+)?#$data/config#g" \
            "$f" | as_user tee "$data/config/$base" >/dev/null
    done
    upgrade_printer_cfg "$data/config/printer.cfg"
    if [ "${STOCK_COMPAT_MACROS:-1}" = 1 ]; then
        as_user cp "$BUILD/overlay/templates/stock-compat.cfg" "$data/config/stock-compat.cfg"
        grep -q '^\[include stock-compat\.cfg\]' "$data/config/printer.cfg" ||
            sed -i '1i [include stock-compat.cfg]  # FLSUN-style M109/M190/M205; remove for upstream behaviour' \
                "$data/config/printer.cfg"
    fi
    for f in "$BUILD"/vendor/home/savedVariables*.cfg; do
        [ -f "$f" ] || continue
        grep -q "$(basename "$f")" "$data/config/printer.cfg" && as_user cp "$f" "$data/config/"
    done
    echo "  instance $1: imported stock printer_$1 ($(ls "$src" | tr '\n' ' '))"
}

log "Printer configuration"
for i in $(seq 1 "$INSTANCES"); do
    data="$(instance_data "$i")"
    if ! import_config "$i" "$data"; then
        render "$BUILD/overlay/templates/printer.cfg" "$data/config/printer.cfg"
        chown "$USERNAME:$USERNAME" "$data/config/printer.cfg"
        echo "  instance $i: placeholder printer.cfg (upload your own via Mainsail)"
    fi
done

# ------------------------------------------------------------------- Moonraker
log "Moonraker"
clone "$MOONRAKER_REPO" "$MOONRAKER_REF" "$HOMEDIR/moonraker"
apt-get update -qq
for i in $(seq 1 "$INSTANCES"); do
    sfx="$(instance_suffix "$i")"; data="$(instance_data "$i")"
    INSTALLER_ENV=(MOONRAKER_DISABLE_SYSTEMCTL=y)
    run_installer "$HOMEDIR/moonraker/scripts/install-moonraker.sh" -z -a "moonraker${sfx}" -d "$data"
    chown -R "$USERNAME:$USERNAME" "$HOMEDIR"
    {
        cat <<EOF
# Generated by the Speeder Pad image build. Reference:
# https://moonraker.readthedocs.io/en/latest/configuration/
[server]
host: 0.0.0.0
port: $(instance_port "$i")
klippy_uds_address: $data/comms/klippy.sock

EOF
        cat "$BUILD/overlay/templates/moonraker-common.conf"
        if [ "$INSTALL_TIMELAPSE" = 1 ]; then
            printf '\n[timelapse]\noutput_path: %s/timelapse/\nframe_path: /tmp/timelapse/printer%s\n' "$data" "$sfx"
        fi
        if [ "$i" -eq 1 ]; then
            render "$BUILD/overlay/templates/moonraker-update-manager.conf" /dev/stdout
            [ "$INSTALL_CROWSNEST" = 1 ] && render "$BUILD/overlay/templates/moonraker-crowsnest.conf" /dev/stdout
            [ "$INSTALL_TIMELAPSE" = 1 ] && render "$BUILD/overlay/templates/moonraker-timelapse.conf" /dev/stdout
        fi
        true
    } | as_user tee "$data/config/moonraker.conf" >/dev/null
    systemctl enable "moonraker${sfx}.service" >/dev/null
done
# The installer's own polkit step calls set-policykit-rules.sh, which refuses
# to run as root and so silently installs nothing in the chroot.
INSTALLER_ENV=()
run_installer "$HOMEDIR/moonraker/scripts/set-policykit-rules.sh" -z
ls /usr/share/polkit-1/rules.d/moonraker.rules /etc/polkit-1/rules.d/moonraker.rules 2>/dev/null | grep -q . ||
    { echo "Moonraker polkit rules were not installed" >&2; exit 1; }

# --------------------------------------------------------------- KlipperScreen
log "KlipperScreen"
clone "$KLIPPERSCREEN_REPO" "$KLIPPERSCREEN_REF" "$HOMEDIR/KlipperScreen"
INSTALLER_ENV=(SERVICE=Y BACKEND=X START=0 NETWORK=Y)
run_installer "$HOMEDIR/KlipperScreen/scripts/KlipperScreen-install.sh"
chown -R "$USERNAME:$USERNAME" "$HOMEDIR"
systemctl enable KlipperScreen.service >/dev/null
if [ "$INSTANCES" -eq 1 ]; then
    ks_conf="$(instance_data 1)/config/KlipperScreen.conf"
else
    ks_conf="$HOMEDIR/.config/KlipperScreen/KlipperScreen.conf"
    as_user mkdir -p "$(dirname "$ks_conf")"
fi
{
    printf '# Generated by the Speeder Pad image build.\n[main]\n'
    for i in $(seq 1 "$INSTANCES"); do
        name="Speeder Pad"; [ "$INSTANCES" -gt 1 ] && name="Printer $i"
        printf '\n[printer %s]\nmoonraker_host: 127.0.0.1\nmoonraker_port: %s\n' "$name" "$(instance_port "$i")"
    done
} | as_user tee "$ks_conf" >/dev/null

# -------------------------------------------------------------------- Mainsail
log "Mainsail ${MAINSAIL_VERSION}"
if [ "$MAINSAIL_VERSION" = latest ]; then
    url=https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip
else
    url="https://github.com/mainsail-crew/mainsail/releases/download/${MAINSAIL_VERSION}/mainsail.zip"
fi
curl -fsSL --retry 5 -o /var/tmp/mainsail.zip "$url"
as_user mkdir -p "$HOMEDIR/mainsail"
as_user unzip -q -o /var/tmp/mainsail.zip -d "$HOMEDIR/mainsail"
rm -f /var/tmp/mainsail.zip
rm -f /etc/nginx/sites-enabled/default
for f in upstreams.conf common_vars.conf; do
    render "$BUILD/overlay/templates/nginx-$f" "/etc/nginx/conf.d/$f"
done
render "$BUILD/overlay/templates/nginx-mainsail" /etc/nginx/sites-available/mainsail
ln -sf /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
systemctl enable nginx.service >/dev/null

# ------------------------------------------------------------------- Crowsnest
if [ "$INSTALL_CROWSNEST" = 1 ]; then
    log "Crowsnest"
    clone "$CROWSNEST_REPO" "$CROWSNEST_REF" "$HOMEDIR/crowsnest"
    data="$(instance_data 1)"
    as_user tee "$HOMEDIR/crowsnest/tools/.config" >/dev/null <<EOF
BASE_USER="$USERNAME"
CROWSNEST_CONFIG_PATH="$data/config"
CROWSNEST_LOG_PATH="$data/logs"
CROWSNEST_ENV_PATH="$data/systemd"
CROWSNEST_VENV_PATH="$HOMEDIR/crowsnest-env"
CROWSNEST_MOONRAKER_CONF_PATH="$data/config/moonraker.conf"
CROWSNEST_USTREAMER_REPO_SHIP="https://github.com/pikvm/ustreamer.git"
CROWSNEST_USTREAMER_REPO_BRANCH="master"
CROWSNEST_ADD_CROWSNEST_MOONRAKER="0"
EOF
    (cd "$HOMEDIR/crowsnest" && CROWSNEST_UNATTENDED=1 BASE_USER="$USERNAME" bash tools/install.sh)
    chown -R "$USERNAME:$USERNAME" "$HOMEDIR/crowsnest"
fi

# ------------------------------------------------------------------- Timelapse
if [ "$INSTALL_TIMELAPSE" = 1 ]; then
    log "Moonraker timelapse"
    apt-get install -y -qq ffmpeg >/dev/null
    clone "$TIMELAPSE_REPO" "$TIMELAPSE_REF" "$HOMEDIR/moonraker-timelapse"
    as_user ln -sf "$HOMEDIR/moonraker-timelapse/component/timelapse.py" \
        "$HOMEDIR/moonraker/moonraker/components/timelapse.py"
    # Keep Moonraker's git status clean despite the linked component.
    grep -qs 'components/timelapse.py' "$HOMEDIR/moonraker/.git/info/exclude" ||
        echo "moonraker/components/timelapse.py" | as_user tee -a "$HOMEDIR/moonraker/.git/info/exclude" >/dev/null
    for i in $(seq 1 "$INSTANCES"); do
        data="$(instance_data "$i")"
        as_user ln -sf "$HOMEDIR/moonraker-timelapse/klipper_macro/timelapse.cfg" "$data/config/timelapse.cfg"
        as_user mkdir -p "$data/timelapse"
    done
fi

# --------------------------------------------------------------------- cleanup
log "Cleanup"
rm -f /usr/sbin/policy-rc.d
rm -rf "$SHIM_DIR"
git config --system --unset-all safe.directory || true
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin "$HOMEDIR/.cache" /root/.cache /tmp/* /var/tmp/*.zip
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
find /var/log -type f -exec truncate -s 0 {} +
rm -f "$HOMEDIR/.bash_history" /root/.bash_history
chown -R "$USERNAME:$USERNAME" "$HOMEDIR"
log "Provisioning complete"
