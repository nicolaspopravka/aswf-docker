#!/usr/bin/env python3
"""Range-fetch a single entry out of a remote ZIP without downloading it whole.

Used to pull the ALab skydome EXR out of the 9.6 GB public techvars archive:
https://dpel-assets.aswf.io/usd-alab/alab-techvars.v2.2.0.zip

The server supports HTTP Range (verified Aug 11, 2026: 206). Strategy:
1. Fetch the last 64 KB -> EOCD -> central directory offset/size.
2. Fetch the central directory -> locate the target entry -> local header offset.
3. Fetch the local header -> data start; fetch the entry's compressed span.
4. Inflate (deflate) or copy (stored); verify CRC32; write the file.

RunPod is NOT required for the GH #13 Pixar-side probe; this enables a free
GitHub Actions run.

Usage:
  python3 gh13_zip_range_fetch.py --url <zip-url> --output <file> [--match <substr>]
  python3 gh13_zip_range_fetch.py --url <zip-url> --list [--match <substr>]
"""
import argparse
import io
import struct
import sys
import urllib.request
import zlib

EOCD_SIG = b"PK\x05\x06"
CDIR_SIG = b"PK\x01\x02"
LOCAL_SIG = b"PK\x03\x04"
Z64EOCD_SIG = b"PK\x06\x06"
Z64LOC_SIG = b"PK\x06\x07"
Z64_EXTRA_ID = 0x0001
MAX_EOCD = 65557
CHUNK = 1 << 20
ZIP64_SENT = 0xFFFFFFFF


def fetch_range(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def fetch(url, start, length):
    if length <= 0:
        return b""
    return fetch_range(url, start, start + length - 1)


def parse_eocd(url):
    req = urllib.request.Request(url, headers={"Range": f"bytes=-{MAX_EOCD}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    idx = data.rfind(EOCD_SIG)
    if idx < 0:
        sys.exit("EOCD not found in last 64 KB")
    eocd = data[idx:]
    (_, _, _, n_on_disk, total, cd_size, cd_off, _) = struct.unpack("<4s4H2LH", eocd[:22])
    if eocd[20:22] != b"\x00\x00":
        sys.exit("multi-disk zip not supported")

    if cd_off == ZIP64_SENT or cd_size == ZIP64_SENT or total == 0xFFFF:
        loc = data[idx - 20:idx]
        if loc[:4] != Z64LOC_SIG:
            sys.exit("ZIP64 sentinel found but no ZIP64 EOCD locator")
        (z64_off,) = struct.unpack("<Q", loc[8:16])
        rec = fetch(url, z64_off, 56)
        if rec[:4] != Z64EOCD_SIG:
            sys.exit("bad ZIP64 EOCD record")
        (_, _, _, _, _, _, entries64, total64, cd_size64, cd_off64) = struct.unpack(
            "<4sQ2H2L4Q", rec[:56])
        return total64, cd_size64, cd_off64
    return total, cd_size, cd_off


def zip64_values(lho, csize, usize, extra):
    if not (lho == ZIP64_SENT or csize == ZIP64_SENT or usize == ZIP64_SENT):
        return lho, csize, usize
    vals = []
    off = 0
    while off + 4 <= len(extra):
        eid, esize = struct.unpack("<HH", extra[off:off + 4])
        body = extra[off + 4:off + 4 + esize]
        if eid == Z64_EXTRA_ID:
            p = 0
            if usize == ZIP64_SENT:
                vals.append(struct.unpack("<Q", body[p:p + 8])[0]); p += 8
            if csize == ZIP64_SENT:
                vals.append(struct.unpack("<Q", body[p:p + 8])[0]); p += 8
            if lho == ZIP64_SENT:
                vals.append(struct.unpack("<Q", body[p:p + 8])[0]); p += 8
        off += 4 + esize
    it = iter(vals)
    return (next(it) if lho == ZIP64_SENT else lho,
            next(it) if csize == ZIP64_SENT else csize,
            next(it) if usize == ZIP64_SENT else usize)


def parse_central_dir(url, cd_off, cd_size):
    data = fetch(url, cd_off, cd_size)
    entries = []
    off = 0
    while off < len(data) - 4:
        if data[off:off + 4] != CDIR_SIG:
            break
        hdr = data[off:off + 46]
        (ver_made, ver_need, flags, method, mtime, mdate) = struct.unpack("<HHHHHH", hdr[4:16])
        (crc, csize, usize) = struct.unpack("<III", hdr[16:28])
        (nlen, elen, clen, disk, iattr) = struct.unpack("<HHHHH", hdr[28:38])
        (eattr, lho) = struct.unpack("<II", hdr[38:46])
        name = data[off + 46:off + 46 + nlen].decode("utf-8", "replace")
        extra = data[off + 46 + nlen:off + 46 + nlen + elen]
        lho, csize, usize = zip64_values(lho, csize, usize, extra)
        entries.append({"name": name, "method": method, "crc": crc,
                        "csize": csize, "usize": usize, "lho": lho})
        off += 46 + nlen + elen + clen
    return entries


def fetch_entry(url, entry, out_path):
    lhdr = fetch(url, entry["lho"], 30)
    if lhdr[:4] != LOCAL_SIG:
        sys.exit(f"bad local header at {entry['lho']}")
    (nlen, elen) = struct.unpack("<HH", lhdr[26:30])
    data_start = entry["lho"] + 30 + nlen + elen
    raw = fetch(url, data_start, entry["csize"])
    if entry["method"] == 0:
        body = raw
    elif entry["method"] == 8:
        body = zlib.decompressobj(-zlib.MAX_WBITS).decompress(raw)
    else:
        sys.exit(f"unsupported method {entry['method']}")
    if len(body) != entry["usize"]:
        sys.exit(f"size mismatch: got {len(body)} want {entry['usize']}")
    if zlib.crc32(body) != entry["crc"]:
        sys.exit("CRC32 mismatch")
    with open(out_path, "wb") as f:
        f.write(body)
    return len(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="https://dpel-assets.aswf.io/usd-alab/alab-techvars.v2.2.0.zip")
    ap.add_argument("--match", default="nuke_texture_export.exr")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--output")
    args = ap.parse_args()

    total, cd_size, cd_off = parse_eocd(args.url)
    print(f"zip: {total} entries, central dir {cd_size} bytes @ {cd_off}")
    entries = parse_central_dir(args.url, cd_off, cd_size)
    print(f"parsed {len(entries)} central-dir entries")

    hits = [e for e in entries if args.match in e["name"]]
    for e in hits:
        print(f"  {e['name']}  (method={e['method']} comp={e['csize']} "
              f"uncomp={e['usize']} crc={e['crc']:08x})")

    if args.list:
        return
    if not hits:
        sys.exit("no matching entry found")
    if args.output:
        n = fetch_entry(args.url, hits[0], args.output)
        print(f"wrote {args.output} ({n} bytes)")


if __name__ == "__main__":
    main()
