# Shared helpers for the Speeder Pad build scripts. Source, don't execute.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUNXI_CARD="${REPO_DIR}/scripts/sunxi_card.py"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "${REPO_DIR}/$1" ;;
    esac
}

load_config() {
    local conf="${BUILD_CONF:-${REPO_DIR}/build.conf}"
    [ -f "$conf" ] || die "config file not found: $conf"
    # shellcheck source=/dev/null
    . "$conf"
    STOCK_IMAGE="$(abspath "$STOCK_IMAGE")"
    WORK_DIR="$(abspath "$WORK_DIR")"
    OUT_DIR="$(abspath "$OUT_DIR")"
    STOCK_DIR="${WORK_DIR}/stock"
    VENDOR_DIR="${WORK_DIR}/vendor"
    ROOTFS_DIR="${WORK_DIR}/rootfs"
    case "$INSTANCES" in
        ''|*[!0-9]*|0) die "INSTANCES must be a positive integer" ;;
    esac
    [ -n "$PASSWORD" ] || die "PASSWORD must not be empty"
    mkdir -p "$WORK_DIR"
    case "$(stat -f -c %T "$WORK_DIR")" in
        v9fs|9p|drvfs|fuseblk|vfat|msdos|ntfs|smb2|cifs)
            die "WORK_DIR ($WORK_DIR) is on a Windows/network filesystem; set WORK_DIR to a Linux path (e.g. ~/speederpad-work under WSL)" ;;
    esac
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this step must run as root (try: sudo $0 $*)"
}

require_cmds() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]} (see README.md for packages)"
}

qemu_name() {
    case "$1" in
        arm64) echo aarch64 ;;
        armhf|armel) echo arm ;;
        *) die "unsupported ARCH $1" ;;
    esac
}

# Make sure foreign-arch binaries run through qemu-user. WSL masks
# systemd-binfmt and containers rarely run it, so register directly.
ensure_binfmt() {
    local q; q="$(qemu_name "$1")"
    local node="/proc/sys/fs/binfmt_misc/qemu-${q}"
    [ "$(dpkg --print-architecture 2>/dev/null)" = "$1" ] && return 0
    if [ ! -e /proc/sys/fs/binfmt_misc/register ]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
    fi
    if [ ! -e "$node" ]; then
        if command -v update-binfmts >/dev/null 2>&1; then
            update-binfmts --enable "qemu-${q}" >/dev/null 2>&1 || true
        fi
    fi
    if [ ! -e "$node" ]; then
        local conf
        for conf in /usr/lib/binfmt.d/qemu-${q}.conf /usr/lib/binfmt.d/qemu-${q}-static.conf; do
            [ -f "$conf" ] || continue
            if [ -x /usr/lib/systemd/systemd-binfmt ]; then
                /usr/lib/systemd/systemd-binfmt "$conf" || true
            else
                grep -v '^#' "$conf" > /proc/sys/fs/binfmt_misc/register || true
            fi
            break
        done
    fi
    [ -e "$node" ] || die "qemu-${q} binfmt handler is not registered; install qemu-user-static (and binfmt-support)"
    grep -q '^flags:.*F' "$node" || die "qemu-${q} binfmt handler lacks the F (fix-binary) flag needed for chroot"
}

# Print the path of a keyring that can verify the Debian archive.
debian_keyring() {
    if [ -n "${DEBIAN_KEYRING:-}" ]; then
        [ -f "$DEBIAN_KEYRING" ] || die "DEBIAN_KEYRING not found: $DEBIAN_KEYRING"
        echo "$DEBIAN_KEYRING"; return
    fi
    local host_kr=/usr/share/keyrings/debian-archive-keyring.gpg
    if [ -f "$host_kr" ] && grep -qx 'ID=debian' /etc/os-release 2>/dev/null; then
        echo "$host_kr"; return
    fi
    local dir="${WORK_DIR}/keyring" pool=https://deb.debian.org/debian/pool/main/d/debian-archive-keyring
    local kr="$dir/usr/share/keyrings/debian-archive-keyring.gpg"
    if [ ! -f "$kr" ]; then
        local deb
        deb="$(curl -fsSL "$pool/" | grep -o 'debian-archive-keyring_[0-9][^"<>]*_all\.deb' \
               | sort -u | sort -V | tail -n 1)"
        [ -n "$deb" ] || die "could not find debian-archive-keyring at $pool"
        mkdir -p "$dir"
        curl -fsSL -o "$dir/$deb" "$pool/$deb"
        dpkg-deb -x "$dir/$deb" "$dir"
        echo "  fetched $deb" >&2
    fi
    echo "$kr"
}

CHROOT_MOUNTS=()

chroot_mount() {
    local root="$1"
    mount -t proc proc "$root/proc"; CHROOT_MOUNTS+=("$root/proc")
    mount -t sysfs sysfs "$root/sys"; CHROOT_MOUNTS+=("$root/sys")
    mount --bind /dev "$root/dev"; CHROOT_MOUNTS+=("$root/dev")
    mount -t devpts devpts "$root/dev/pts" -o gid=5,mode=620,newinstance,ptmxmode=0666
    CHROOT_MOUNTS+=("$root/dev/pts")
    mount -t tmpfs tmpfs "$root/run"; CHROOT_MOUNTS+=("$root/run")
}

chroot_umount() {
    local i
    for ((i=${#CHROOT_MOUNTS[@]}-1; i>=0; i--)); do
        umount -l "${CHROOT_MOUNTS[$i]}" 2>/dev/null || true
    done
    CHROOT_MOUNTS=()
}
