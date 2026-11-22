#!/usr/bin/env python3
"""Helpers for building kernel modules that load into the stock Speeder Pad
kernel (Allwinner/Android-common Linux 4.9.191, arm64, CONFIG_MODVERSIONS=y).

FLSUN ships no Module.symvers, so the export table and symbol CRCs are read
back out of the kernel Image in boot.fex.

  kernel_tools.py image   boot.fex Image        # Android boot image -> Image
  kernel_tools.py config  Image .config         # embedded IKCONFIG
  kernel_tools.py symvers Image .config Module.symvers
  kernel_tools.py verify  TREE Module.symvers a.ko [b.ko ...] [--own M.symvers]
"""
import argparse
import gzip
import os
import re
import struct
import subprocess
import sys
import zlib


def die(msg):
    sys.exit(f"error: {msg}")


def cmd_image(args):
    b = open(args.boot, "rb").read()
    if b[:8] != b"ANDROID!":
        die(f"{args.boot} is not an Android boot image")
    kernel_size = struct.unpack_from("<I", b, 8)[0]
    page_size = struct.unpack_from("<I", b, 36)[0]
    k = b[page_size:page_size + kernel_size]
    if k[:2] == b"\x1f\x8b":
        k = gzip.decompress(k)
    if k[56:60] != b"ARM\x64":
        die("kernel in boot image is not a raw arm64 Image")
    open(args.out, "wb").write(k)
    print(f"  kernel Image: {len(k)} bytes")


def cmd_config(args):
    k = open(args.image, "rb").read()
    i = k.find(b"IKCFG_ST")
    if i < 0:
        die("kernel has no embedded config (CONFIG_IKCONFIG)")
    cfg = zlib.decompressobj(wbits=31).decompress(k[i + 8:])
    open(args.out, "wb").write(cfg)
    print(f"  kernel config: {cfg.count(b'CONFIG_')} option lines")


def read_config(path):
    cfg = {}
    for line in open(path):
        m = re.match(r"(CONFIG_\w+)=(.*)", line)
        if m:
            cfg[m.group(1)] = m.group(2)
    return cfg


def cmd_symvers(args):
    k = open(args.image, "rb").read()
    cfg = read_config(args.config)
    for opt in ("CONFIG_KASAN", "CONFIG_RELOCATABLE", "CONFIG_RANDOMIZE_BASE"):
        if cfg.get(opt) == "y":
            die(f"{opt}=y is not supported by this extractor")
    va_bits = int(cfg["CONFIG_ARM64_VA_BITS"])
    # arm64 4.9: KIMAGE_VADDR = VA_START + 128 MiB (modules area), no KASAN.
    va_start = (1 << 64) - (1 << va_bits)
    base = va_start + (128 << 20) + struct.unpack_from("<Q", k, 8)[0]

    def name_at(ptr):
        off = ptr - base
        if not 0 <= off < len(k):
            return None
        end = k.find(b"\0", off)
        s = k[off:end]
        if 0 < len(s) < 128 and all(32 < c < 127 for c in s):
            return s.decode()
        return None

    def is_entry(off):
        value, name = struct.unpack_from("<QQ", k, off)
        return (value == 0 or base <= value < base + (1 << 30)) and name_at(name) is not None

    # A struct kernel_symbol {value, name} whose name is "module_layout".
    anchor = None
    s = k.find(b"\0module_layout\0")
    while s >= 0 and anchor is None:
        ptr = struct.pack("<Q", base + s + 1)
        h = k.find(ptr)
        while h >= 0:
            if h % 8 == 0 and is_entry(h - 8):
                anchor = h - 8
                break
            h = k.find(ptr, h + 1)
        s = k.find(b"\0module_layout\0", s + 1)
    if anchor is None:
        die("could not locate __ksymtab in the kernel Image")

    start = anchor
    while is_entry(start - 16):
        start -= 16
    end = anchor
    while is_entry(end):
        end += 16
    count = (end - start) // 16
    # __kcrctab and __kcrctab_gpl follow __ksymtab(_gpl), in the same order,
    # as one unsigned long per symbol.
    crcs = struct.unpack_from(f"<{count}Q", k, end)
    if any(c >> 32 for c in crcs):
        die("__kcrctab does not directly follow __ksymtab")
    with open(args.out, "w", newline="\n") as f:
        for i in range(count):
            name = name_at(struct.unpack_from("<Q", k, start + 16 * i + 8)[0])
            f.write(f"0x{crcs[i]:08x}\t{name}\tvmlinux\tEXPORT_SYMBOL\n")
    print(f"  Module.symvers: {count} exported symbols")


def ko_imports(path):
    """(name, crc) pairs from a module's __versions section."""
    out = subprocess.run(
        [os.environ.get("OBJCOPY", "objcopy"), "-O", "binary",
         "--only-section=__versions", path, "/dev/stdout"],
        check=True, capture_output=True).stdout
    for i in range(0, len(out), 64):
        crc = struct.unpack_from("<Q", out, i)[0]
        yield out[i + 8:i + 64].split(b"\0")[0].decode(), crc


# Exported through wrapper macros that a plain EXPORT_SYMBOL grep misses.
MACRO_EXPORTS = {
    "drivers/base/core.c": r"(_?dev_(emerg|alert|crit|err|warn|notice|info))",
    "net/core/dev.c": r"(netdev_(emerg|alert|crit|err|warn|notice|info))",
    "kernel/params.c": r"(param_(ops|get|set)_\w+)",
    "kernel/rcu/tree.c": r"(call_rcu|synchronize_rcu|rcu_barrier)",
}
SEARCH_DIRS = ["kernel", "mm", "fs", "net", "lib", "block", "init", "ipc",
               "arch/arm64", "drivers/base", "drivers/usb/core"]


def cmd_verify(args):
    """Rebuild the vmlinux objects that export every symbol the modules
    import, and check that genksyms gives the same CRC as the running kernel.
    A match means the source tree's types agree with the vendor kernel's."""
    pad = {}
    for line in open(args.symvers):
        crc, name = line.split("\t")[:2]
        pad[name] = int(crc, 16)
    own = set()
    for sv in args.own:
        own.update(l.split("\t")[1] for l in open(sv))
    imports = {}
    for ko in args.modules:
        for name, crc in ko_imports(ko):
            if name in own:
                continue
            if pad.get(name) != crc:
                die(f"{os.path.basename(ko)}: {name} CRC 0x{crc:08x} is not the kernel's")
            imports[name] = crc

    objs = set()
    for path, pat in MACRO_EXPORTS.items():
        if any(re.fullmatch(pat, n) for n in imports):
            objs.add(path[:-2] + ".o")
    names = "|".join(re.escape(n) for n in imports)
    grep = subprocess.run(
        ["grep", "-rlE", rf"EXPORT_SYMBOL(_GPL)?\(({names})\);",
         "--include=*.c", "--include=*.S"] + SEARCH_DIRS,
        cwd=args.tree, capture_output=True, text=True)
    objs.update(p[:-2] + ".o" for p in grep.stdout.split())
    # Alternatives that are not configured (e.g. mm/slab.c under SLUB) simply
    # fail to build and are ignored; -k keeps going.
    subprocess.run(["make", "-k", f"-j{os.cpu_count()}"] + args.make_args + sorted(objs),
                   cwd=args.tree, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    built = {}
    nm = os.environ.get("NM", "nm")
    for o in sorted(objs):
        p = os.path.join(args.tree, o)
        if not os.path.exists(p):
            continue
        for line in subprocess.run([nm, p], capture_output=True, text=True).stdout.splitlines():
            f = line.split()
            if len(f) == 3 and f[2].startswith("__crc_"):
                built.setdefault(f[2][6:], set()).add(int(f[0], 16))
    bad = [n for n in sorted(imports) if imports[n] not in built.get(n, ())]
    print(f"  CRC check: {len(imports) - len(bad)}/{len(imports)} imported symbols match the kernel")
    if bad:
        die("source tree does not match the vendor kernel for: " + " ".join(bad))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("image"); s.add_argument("boot"); s.add_argument("out")
    s.set_defaults(func=cmd_image)
    s = sub.add_parser("config"); s.add_argument("image"); s.add_argument("out")
    s.set_defaults(func=cmd_config)
    s = sub.add_parser("symvers"); s.add_argument("image"); s.add_argument("config")
    s.add_argument("out"); s.set_defaults(func=cmd_symvers)
    s = sub.add_parser("verify"); s.add_argument("tree"); s.add_argument("symvers")
    s.add_argument("modules", nargs="+")
    s.add_argument("--own", action="append", default=[],
                   help="Module.symvers of the module build (its exports are skipped)")
    s.add_argument("--make-arg", dest="make_args", action="append", default=[])
    s.set_defaults(func=cmd_verify)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
