#!/usr/bin/env python3
"""Generate VoiceDrop's app icon: a diagonal coral->indigo gradient with a
soft radial highlight. Pure stdlib (zlib + struct) — no PIL dependency, fully
deterministic, re-runnable. Writes a 1024x1024 PNG.

Usage: python3 scripts/make_icon.py [out.png]
"""
import sys
import math
import struct
import zlib

SIZE = 1024
# Top-left -> bottom-right gradient endpoints.
C0 = (0xFF, 0x6B, 0x5C)   # coral
C1 = (0x2A, 0x1A, 0x5E)   # deep indigo
# Highlight (warm) centered upper-left.
HL = (0xFF, 0xD4, 0x7E)


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c0, c1, t):
    return tuple(int(round(lerp(c0[i], c1[i], t))) for i in range(3))


def build_rows():
    cx, cy = SIZE * 0.32, SIZE * 0.30          # highlight center
    hl_r = SIZE * 0.55                          # highlight radius
    diag = (SIZE - 1) * 2.0
    rows = []
    for y in range(SIZE):
        row = bytearray()
        row.append(0)  # PNG filter type 0 for this scanline
        for x in range(SIZE):
            t = (x + y) / diag                  # diagonal position 0..1
            r, g, b = mix(C0, C1, t)
            # radial highlight, soft falloff
            d = math.hypot(x - cx, y - cy) / hl_r
            h = max(0.0, 1.0 - d)
            h = h * h * 0.45
            r = min(255, int(r + (HL[0] - r) * h))
            g = min(255, int(g + (HL[1] - g) * h))
            b = min(255, int(b + (HL[2] - b) * h))
            row += bytes((r, g, b))
        rows.append(bytes(row))
    return b"".join(rows)


def png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png"
    raw = build_rows()
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = (b"\x89PNG\r\n\x1a\n"
           + png_chunk(b"IHDR", ihdr)
           + png_chunk(b"IDAT", zlib.compress(raw, 9))
           + png_chunk(b"IEND", b""))
    with open(out, "wb") as f:
        f.write(png)
    print(f"wrote {out} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
