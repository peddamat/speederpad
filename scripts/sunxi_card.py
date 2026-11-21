#!/usr/bin/env python3
"""Inspect, unpack and repack Allwinner PhoenixCard "product" TF-card images.

A PhoenixCard card image (such as FLSUN's Speeder Pad restore image) contains:

* a protective MBR + small GPT (entries at a non-standard LBA),
* card-mode boot0 at sector 16 and a boot package at sector 32800,
* four copies of the ``sunxi_mbr`` partition table at sector 40960,
* a FAT ``boot-resource`` partition, and
* an IMAGEWTY firmware package starting at sunxi_mbr partition index 1.

The card U-Boot (work mode 0x11) reads the IMAGEWTY package and flashes it to
the internal eMMC. This tool keeps every vendor byte intact and only rewrites
what changes: IMAGEWTY item lengths/offsets, the ``V<name>`` additive checksum
items, and the card GPT so that it describes the new size.

Only the formats observed on the Speeder Pad image are supported (IMAGEWTY
header version 0x300, unencrypted; sunxi_mbr version 0x200).
"""

import argparse
import array
import json
import os
import struct
import sys
import zlib

SECTOR = 512
CHUNK = 64 << 20

SUNXI_MBR_SECTOR = 40960
SUNXI_MBR_SIZE = 16 * 1024
SUNXI_MBR_MAGIC = b"softw411"

IMAGEWTY_MAGIC = b"IMAGEWTY"
IMAGEWTY_HDR_VERSION = 0x300
HDR_LEN = 1024
ITEM_LEN = 1024
ITEM_DATA_ALIGN = 1024
ITEM_LEN_ALIGN = 16
# PhoenixSuite fills the gap between an item's data and the next 1 KiB
# boundary with 0xCD; the filelen->datalen padding is zero.
GAP_FILL = b"\xcd"

# Offsets inside an IMAGEWTY v3 item header.
IT_MAINTYPE = 8
IT_SUBTYPE = 16
IT_FILENAME = 36
IT_LENS = 292  # datalen_lo, datalen_hi, filelen_lo, filelen_hi, offset_lo, offset_hi

GPT_SIG = b"EFI PART"


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)


def align_up(v, a):
    return (v + a - 1) // a * a


def u64(lo, hi):
    return (hi << 32) | lo


def split64(v):
    return v & 0xFFFFFFFF, v >> 32


def cstr(b):
    return b.split(b"\0", 1)[0].decode("latin1")


def addsum_stream(read, length):
    """Allwinner V*.fex checksum: sum of little-endian u32 words, zero padded."""
    total = 0
    remaining = length
    while remaining:
        chunk = read(min(remaining, CHUNK))
        if not chunk:
            die("unexpected end of data while checksumming")
        remaining -= len(chunk)
        if len(chunk) % 4:
            chunk += b"\0" * (4 - len(chunk) % 4)
        words = array.array("I")
        if words.itemsize != 4:
            words = array.array("L")
        words.frombytes(chunk)
        if sys.byteorder == "big":
            words.byteswap()
        total = (total + sum(words)) & 0xFFFFFFFF
    return total


def addsum_file(path):
    with open(path, "rb") as f:
        return addsum_stream(f.read, os.path.getsize(path))


def copy_stream(src, dst, length):
    remaining = length
    while remaining:
        chunk = src.read(min(remaining, CHUNK))
        if not chunk:
            die("unexpected end of data while copying")
        dst.write(chunk)
        remaining -= len(chunk)


# --------------------------------------------------------------------------
# sunxi_mbr


def parse_sunxi_mbr(f, sector=SUNXI_MBR_SECTOR):
    f.seek(sector * SECTOR)
    raw = f.read(SUNXI_MBR_SIZE)
    if raw[8:16] != SUNXI_MBR_MAGIC:
        die("no sunxi_mbr (softw411) at sector %d" % sector)
    crc = struct.unpack_from("<I", raw, 0)[0]
    if zlib.crc32(raw[4:]) & 0xFFFFFFFF != crc:
        die("sunxi_mbr CRC mismatch at sector %d" % sector)
    count = struct.unpack_from("<I", raw, 24)[0]
    parts = []
    for i in range(count):
        p = raw[32 + i * 128:32 + (i + 1) * 128]
        ah, al, lh, ll = struct.unpack_from("<IIII", p, 0)
        parts.append({
            "index": i,
            "name": cstr(p[32:48]),
            "start": sector + u64(al, ah),
            "sectors": u64(ll, lh),
            "user_type": struct.unpack_from("<I", p, 48)[0],
        })
    return parts


# --------------------------------------------------------------------------
# IMAGEWTY


class Item:
    def __init__(self, index, hdr):
        self.index = index
        self.hdr = bytearray(hdr)
        self.maintype = cstr(hdr[IT_MAINTYPE:IT_MAINTYPE + 8])
        self.subtype = cstr(hdr[IT_SUBTYPE:IT_SUBTYPE + 16])
        self.filename = cstr(hdr[IT_FILENAME:IT_FILENAME + 256])
        dl, dh, fl, fh, ol, oh = struct.unpack_from("<6I", hdr, IT_LENS)
        self.datalen = u64(dl, dh)
        self.filelen = u64(fl, fh)
        self.offset = u64(ol, oh)

    def set_layout(self, filelen, offset):
        self.filelen = filelen
        self.datalen = align_up(filelen, ITEM_LEN_ALIGN)
        self.offset = offset
        struct.pack_into("<6I", self.hdr, IT_LENS,
                         *(split64(self.datalen) + split64(self.filelen) + split64(self.offset)))


def parse_imagewty(f, base):
    f.seek(base)
    hdr = bytearray(f.read(HDR_LEN))
    if hdr[:8] != IMAGEWTY_MAGIC:
        die("no IMAGEWTY magic at byte offset %d (encrypted or unsupported image?)" % base)
    ver = struct.unpack_from("<I", hdr, 8)[0]
    if ver != IMAGEWTY_HDR_VERSION:
        die("unsupported IMAGEWTY header version 0x%x" % ver)
    size = u64(*struct.unpack_from("<II", hdr, 24))
    count = struct.unpack_from("<I", hdr, 60)[0]
    items = []
    for i in range(count):
        f.seek(base + HDR_LEN + i * ITEM_LEN)
        items.append(Item(i, f.read(ITEM_LEN)))
    return hdr, size, items


def open_firmware(path):
    """Return (file, base_offset, sunxi_parts). Accepts a card image or a bare IMAGEWTY."""
    f = open(path, "rb")
    if f.read(8) == IMAGEWTY_MAGIC:
        return f, 0, None
    parts = parse_sunxi_mbr(f)
    if len(parts) < 2:
        die("sunxi_mbr has fewer than 2 partitions")
    return f, parts[1]["start"] * SECTOR, parts


def verify_items(f, base, items):
    by_name = {it.filename: it for it in items}
    results = []
    for it in items:
        if not it.filename.startswith("V") or it.filelen != 4:
            continue
        target = by_name.get(it.filename[1:])
        if target is None:
            continue
        f.seek(base + it.offset)
        want = struct.unpack("<I", f.read(4))[0]
        f.seek(base + target.offset)
        got = addsum_stream(f.read, target.filelen)
        results.append((target.filename, want, got))
    return results


# --------------------------------------------------------------------------
# GPT


def read_gpt(f, lba):
    f.seek(lba * SECTOR)
    h = bytearray(f.read(SECTOR))
    if h[:8] != GPT_SIG:
        return None
    g = {"raw": h}
    g["header_size"] = struct.unpack_from("<I", h, 12)[0]
    g["my_lba"], g["alt_lba"], g["first_usable"], g["last_usable"] = struct.unpack_from("<QQQQ", h, 24)
    g["entries_lba"], g["num_entries"], g["entry_size"], g["entries_crc"] = struct.unpack_from("<QIII", h, 72)
    f.seek(g["entries_lba"] * SECTOR)
    g["entries"] = bytearray(f.read(g["num_entries"] * g["entry_size"]))
    hc = bytearray(h[:g["header_size"]])
    stored = struct.unpack_from("<I", hc, 16)[0]
    hc[16:20] = b"\0\0\0\0"
    g["header_ok"] = zlib.crc32(hc) & 0xFFFFFFFF == stored
    g["entries_ok"] = zlib.crc32(g["entries"]) & 0xFFFFFFFF == g["entries_crc"]
    return g


def build_gpt_header(template, my_lba, alt_lba, last_usable, entries_lba, entries):
    h = bytearray(template)
    struct.pack_into("<QQ", h, 24, my_lba, alt_lba)
    struct.pack_into("<Q", h, 48, last_usable)
    struct.pack_into("<Q", h, 72, entries_lba)
    struct.pack_into("<I", h, 88, zlib.crc32(entries) & 0xFFFFFFFF)
    hsize = struct.unpack_from("<I", h, 12)[0]
    h[16:20] = b"\0\0\0\0"
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h[:hsize])) & 0xFFFFFFFF)
    return h


# --------------------------------------------------------------------------
# commands


def cmd_info(args):
    f, base, parts = open_firmware(args.image)
    if parts is not None:
        for name, lba in (("primary", 1), ("backup", os.path.getsize(args.image) // SECTOR - 1)):
            g = read_gpt(f, lba)
            if g is None:
                print("card GPT %s: missing" % name)
                continue
            print("card GPT %s: header_crc=%s entries_crc=%s entries_lba=%d last_usable=%d" % (
                name, "ok" if g["header_ok"] else "BAD", "ok" if g["entries_ok"] else "BAD",
                g["entries_lba"], g["last_usable"]))
        print("sunxi_mbr partitions (absolute sectors):")
        for p in parts:
            print("  %d %-14s start=%-9d sectors=%d" % (p["index"], p["name"], p["start"], p["sectors"]))
        print("IMAGEWTY at byte offset %d (sector %d)" % (base, base // SECTOR))
    _, size, items = parse_imagewty(f, base)
    print("IMAGEWTY size=%d items=%d" % (size, len(items)))
    for it in items:
        print("  %2d %-8s %-16s %-24s off=0x%09x len=%d" % (
            it.index, it.maintype, it.subtype, it.filename, it.offset, it.filelen))
    if args.checksums:
        bad = 0
        for name, want, got in verify_items(f, base, items):
            ok = want == got
            bad += not ok
            print("  checksum %-22s stored=0x%08x computed=0x%08x %s" % (
                name, want, got, "OK" if ok else "MISMATCH"))
        if bad:
            die("%d checksum mismatch(es)" % bad)


def cmd_unpack(args):
    f, base, parts = open_firmware(args.image)
    hdr, _, items = parse_imagewty(f, base)
    os.makedirs(args.outdir, exist_ok=True)
    skip = set(args.skip or [])
    manifest = {"header": "imagewty-header.bin", "items": []}
    with open(os.path.join(args.outdir, manifest["header"]), "wb") as o:
        o.write(hdr)
    for it in items:
        stem = "%02d_%s" % (it.index, it.filename)
        entry = {"index": it.index, "filename": it.filename, "maintype": it.maintype,
                 "subtype": it.subtype, "header": stem + ".hdr", "filelen": it.filelen}
        with open(os.path.join(args.outdir, entry["header"]), "wb") as o:
            o.write(it.hdr)
        if it.filename in skip:
            entry["data"] = None
        else:
            entry["data"] = stem
            f.seek(base + it.offset)
            with open(os.path.join(args.outdir, stem), "wb") as o:
                copy_stream(f, o, it.filelen)
        manifest["items"].append(entry)
    if args.card_head:
        if parts is None:
            die("--card-head needs a card image, not a bare IMAGEWTY")
        f.seek(0)
        with open(args.card_head, "wb") as o:
            copy_stream(f, o, base)
    with open(os.path.join(args.outdir, "manifest.json"), "w") as o:
        json.dump(manifest, o, indent=2)
    print("unpacked %d items to %s" % (len(items), args.outdir))


def cmd_repack(args):
    with open(os.path.join(args.itemsdir, "manifest.json")) as m:
        manifest = json.load(m)
    replace = {}
    for spec in args.replace or []:
        name, _, path = spec.partition("=")
        if not path or not os.path.isfile(path):
            die("bad --replace %r (expected NAME=existing_file)" % spec)
        replace[name] = path
    with open(os.path.join(args.itemsdir, manifest["header"]), "rb") as h:
        hdr = bytearray(h.read())

    entries = manifest["items"]
    names = {e["filename"] for e in entries}
    for name in replace:
        if name not in names:
            die("--replace %s: no such item in manifest" % name)

    sources = {}
    for e in entries:
        name = e["filename"]
        if name in replace:
            sources[name] = ("file", replace[name])
        elif e["data"] is None:
            sources[name] = None
        else:
            sources[name] = ("file", os.path.join(args.itemsdir, e["data"]))
    # Regenerate the V<name> checksum item of every replaced payload.
    for name, path in replace.items():
        vname = "V" + name
        if vname in names and vname not in replace:
            value = addsum_file(path)
            sources[vname] = ("bytes", struct.pack("<I", value))
            print("checksum %-22s -> 0x%08x" % (name, value))
    missing = [n for n, s in sources.items() if s is None]
    if missing:
        die("items skipped at unpack time must be replaced: %s" % ", ".join(missing))

    items = []
    for e in entries:
        with open(os.path.join(args.itemsdir, e["header"]), "rb") as h:
            it = Item(e["index"], h.read())
        kind, val = sources[e["filename"]]
        it.src = (kind, val)
        it.newlen = len(val) if kind == "bytes" else os.path.getsize(val)
        items.append(it)

    cur = HDR_LEN + len(items) * ITEM_LEN
    for it in items:
        cur = align_up(cur, ITEM_DATA_ALIGN)
        it.set_layout(it.newlen, cur)
        cur += it.datalen
    total = align_up(cur, ITEM_DATA_ALIGN)
    struct.pack_into("<II", hdr, 24, *split64(total))
    struct.pack_into("<I", hdr, 60, len(items))

    with open(args.output, "wb") as o:
        o.write(hdr)
        for it in items:
            o.write(it.hdr)
        for it in items:
            o.write(GAP_FILL * (it.offset - o.tell()))
            kind, val = it.src
            if kind == "bytes":
                o.write(val)
            else:
                with open(val, "rb") as s:
                    copy_stream(s, o, it.newlen)
            o.write(b"\0" * (it.datalen - it.filelen))
        o.write(GAP_FILL * (total - o.tell()))
    print("wrote %s (%d bytes, %d items)" % (args.output, total, len(items)))


def cmd_make_card(args):
    head_size = os.path.getsize(args.head)
    if head_size % SECTOR:
        die("card head is not sector aligned")
    with open(args.head, "rb") as h:
        parts = parse_sunxi_mbr(h)
        base = parts[1]["start"] * SECTOR
        if base != head_size:
            die("card head ends at %d but sunxi_mbr puts the firmware at %d" % (head_size, base))
        gpt = read_gpt(h, 1)
        if gpt is None or not gpt["header_ok"] or not gpt["entries_ok"]:
            die("card head has no valid primary GPT")
    fw_size = os.path.getsize(args.firmware)
    with open(args.firmware, "rb") as fw:
        if fw.read(8) != IMAGEWTY_MAGIC:
            die("%s is not an IMAGEWTY firmware" % args.firmware)

    esz = gpt["entry_size"]
    if gpt["num_entries"] * esz > SECTOR:
        die("card GPT entry array larger than one sector is not supported")
    entries = bytearray(gpt["entries"])
    if len(entries) < 2 * esz or entries[esz:esz + 16] == bytes(16):
        die("card GPT has no second partition entry to relocate")

    fw_end = (base + fw_size + SECTOR - 1) // SECTOR
    # Layout observed on the stock card: the card's second GPT partition
    # starts 1024 sectors after the firmware (32-sector aligned) and ends
    # 2048 sectors (1 MiB) before the end of the card.
    p2_start = align_up(fw_end + 1024, 32)
    min_total = p2_start + args.min_p2_sectors + 2049
    total = args.total_sectors or align_up(min_total, 2048)
    if total < min_total:
        die("--total-sectors %d is too small; need at least %d" % (total, min_total))
    p2_last = total - 2049
    last_usable = total - 3
    struct.pack_into("<QQ", entries, esz + 32, p2_start, p2_last)

    primary = build_gpt_header(gpt["raw"], 1, total - 1, last_usable, gpt["entries_lba"], entries)
    backup = build_gpt_header(gpt["raw"], total - 1, 1, last_usable, total - 2, entries)

    with open(args.output, "wb") as o, open(args.head, "rb") as h, open(args.firmware, "rb") as fw:
        copy_stream(h, o, head_size)
        copy_stream(fw, o, fw_size)
        o.truncate(total * SECTOR)
        o.seek(SECTOR)
        o.write(primary)
        o.seek(gpt["entries_lba"] * SECTOR)
        o.write(entries.ljust(SECTOR, b"\0"))
        o.seek((total - 2) * SECTOR)
        o.write(entries.ljust(SECTOR, b"\0"))
        o.write(backup)
    print("wrote %s: %d sectors (%.2f GiB); firmware ends at sector %d; card p2 %d-%d" % (
        args.output, total, total * SECTOR / 2**30, fw_end, p2_start, p2_last))


def cmd_extract(args):
    f, base, _ = open_firmware(args.image)
    _, _, items = parse_imagewty(f, base)
    for it in items:
        if it.filename == args.name:
            f.seek(base + it.offset)
            with open(args.output, "wb") as o:
                copy_stream(f, o, it.filelen)
            print("extracted %s (%d bytes)" % (args.name, it.filelen))
            return
    die("no item named %s" % args.name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="show card layout and IMAGEWTY items")
    p.add_argument("image", help="card image or bare IMAGEWTY firmware")
    p.add_argument("--checksums", action="store_true", help="verify every V<name> checksum item")
    p.set_defaults(fn=cmd_info)

    p = sub.add_parser("unpack", help="unpack IMAGEWTY items (and optionally the card head)")
    p.add_argument("image")
    p.add_argument("outdir")
    p.add_argument("--card-head", help="also save the card bytes in front of the firmware")
    p.add_argument("--skip", action="append", help="item filename to leave out (repeatable)")
    p.set_defaults(fn=cmd_unpack)

    p = sub.add_parser("repack", help="rebuild an IMAGEWTY from an unpacked directory")
    p.add_argument("itemsdir")
    p.add_argument("output")
    p.add_argument("--replace", action="append",
                   help="NAME=FILE, e.g. rootfs.fex=rootfs.ext4 (repeatable); V<NAME> is regenerated")
    p.set_defaults(fn=cmd_repack)

    p = sub.add_parser("make-card", help="combine a card head and an IMAGEWTY into a card image")
    p.add_argument("--head", required=True)
    p.add_argument("--firmware", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--total-sectors", type=int, help="card image size in sectors (default: minimal)")
    p.add_argument("--min-p2-sectors", type=int, default=32768,
                   help="minimum size of the trailing card partition (default 16 MiB)")
    p.set_defaults(fn=cmd_make_card)

    p = sub.add_parser("extract", help="extract one IMAGEWTY item")
    p.add_argument("image")
    p.add_argument("name")
    p.add_argument("output")
    p.set_defaults(fn=cmd_extract)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
