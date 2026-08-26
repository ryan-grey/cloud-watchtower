#!/usr/bin/env python3
"""Shrink a flat-colour UI screenshot by converting it to an indexed PNG.

The panel renders as a handful of flat fills plus antialiased text: 927 distinct colours,
of which the top six cover 94% of pixels. That indexes almost losslessly, and 8 bits per
pixel instead of 32 cut the shipped file by ~61% (193 KB -> 77 KB at 2x).

Pure stdlib on purpose -- Pillow is not installed and this runs rarely.
Usage: optimise-png.py in.png out.png
"""
import collections
import struct
import sys
import zlib


def read_png(path):
    d = open(path, "rb").read()
    pos, idat, w, h, ct = 8, b"", None, None, None
    while pos < len(d):
        (ln,) = struct.unpack(">I", d[pos:pos + 4])
        typ, data = d[pos + 4:pos + 8], d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, _bd, ct = struct.unpack(">IIBB", data[:10])
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    stride = w * ch
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):                      # undo the per-row filter
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line)); prev = line
    return w, h, ch, rows


def main(src, dst):
    w, h, ch, rows = read_png(src)

    # Flatten semi-transparent edge pixels over white. The renderer's context is
    # premultiplied, so stored RGB is already scaled by alpha: composite is rgb + white*(1-a).
    flat = []
    for line in rows:
        out = bytearray()
        for x in range(0, len(line), ch):
            r, g, b = line[x], line[x + 1], line[x + 2]
            a = line[x + 3] if ch == 4 else 255
            if a != 255:
                inv = 255 - a
                r, g, b = min(255, r + inv), min(255, g + inv), min(255, b + inv)
            out += bytes((r, g, b))
        flat.append(bytes(out))

    counts = collections.Counter()
    for line in flat:
        for x in range(0, len(line), 3):
            counts[line[x:x + 3]] += 1

    palette = [c for c, _ in counts.most_common(256)]
    index = {c: i for i, c in enumerate(palette)}
    for c in counts:                                  # map the tail to its nearest kept colour
        if c in index:
            continue
        r, g, b = c
        index[c] = min(range(len(palette)),
                       key=lambda i: (r - palette[i][0]) ** 2
                                   + (g - palette[i][1]) ** 2
                                   + (b - palette[i][2]) ** 2)

    idat = bytearray()
    for line in flat:
        idat.append(0)                                # filter None; indexed data filters poorly
        idat += bytes(index[line[x:x + 3]] for x in range(0, len(line), 3))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 3, 0, 0, 0))
           + chunk(b"PLTE", b"".join(bytes(c) for c in palette))
           + chunk(b"IDAT", zlib.compress(bytes(idat), 9))
           + chunk(b"IEND", b""))
    open(dst, "wb").write(png)

    import os
    before = os.path.getsize(src)
    print(f"{src} {before} B -> {dst} {len(png)} B  ({100 - len(png) * 100 // before}% smaller, "
          f"{len(palette)} colours)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
