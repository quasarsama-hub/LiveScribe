#!/usr/bin/env python3
"""Draws the 1024x1024 LiveScribe app icon with only the standard library (no Pillow)."""
import math
import struct
import sys
import zlib

SIZE = 1024
TOP_LEFT = (255, 112, 96)      # coral
BOTTOM_RIGHT = (110, 72, 240)  # violet
INK = (255, 255, 255)

# Capsules: (x1, y1, x2, y2, radius) — sound bars on the left, text lines on the right.
SHAPES = [
    (236, 412, 236, 612, 34),
    (330, 300, 330, 724, 34),
    (424, 372, 424, 652, 34),
    (548, 392, 792, 392, 34),
    (548, 512, 744, 512, 34),
    (548, 632, 672, 632, 34),
]


def background(x, y):
    t = (x + y) / (2 * (SIZE - 1))
    return [a + (b - a) * t for a, b in zip(TOP_LEFT, BOTTOM_RIGHT)]


def coverage(px, py, shape):
    x1, y1, x2, y2, r = shape
    dx, dy = x2 - x1, y2 - y1
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / length_sq))
    cx, cy = x1 + t * dx, y1 + t * dy
    d = math.hypot(px - cx, py - cy) - r
    return max(0.0, min(1.0, 0.5 - d))


def main(path):
    rows = []
    for y in range(SIZE):
        row = bytearray([0])  # PNG filter type: none
        py = y + 0.5
        for x in range(SIZE):
            r, g, b = background(x, y)
            px = x + 0.5
            alpha = 0.0
            for shape in SHAPES:
                x1, y1, x2, y2, rad = shape
                if min(x1, x2) - rad - 2 <= px <= max(x1, x2) + rad + 2 and \
                   min(y1, y2) - rad - 2 <= py <= max(y1, y2) + rad + 2:
                    alpha = max(alpha, coverage(px, py, shape))
            if alpha > 0:
                r = r + (INK[0] - r) * alpha
                g = g + (INK[1] - g) * alpha
                b = b + (INK[2] - b) * alpha
            row += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5)))
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
