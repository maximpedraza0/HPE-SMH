#!/usr/bin/env python3
"""
Render the HPE-SMH plugin icon to PNG using only the Python stdlib.
Mirrors source/branding/hpe-mgmt.svg so we don't need a rasteriser
(librsvg/imagemagick/inkscape) installed at build time.

Usage:
    python3 source/branding/render-icon.py icons/hpe-mgmt.png [size]

Default size is 64.  Anti-aliased edges via 4× supersampling.
"""

import os
import struct
import sys
import zlib


# Brand palette
HPE_GREEN = (1, 169, 130, 255)
HPE_GREEN_DARK = (1, 122, 93, 255)   # rack-ear shadow
WHITE = (255, 255, 255, 255)
NEAR_BLACK = (31, 31, 31, 255)
TRANSPARENT = (0, 0, 0, 0)


def blend(over, under):
    """Alpha-composite over onto under, both as (r,g,b,a) 0-255."""
    or_, og, ob, oa = over
    ur, ug, ub, ua = under
    if oa == 0:
        return under
    if oa == 255:
        return over
    ai = oa / 255.0
    out_a = oa + ua * (1 - ai)
    if out_a == 0:
        return TRANSPARENT
    out_r = (or_ * oa + ur * ua * (1 - ai)) / out_a
    out_g = (og * oa + ug * ua * (1 - ai)) / out_a
    out_b = (ob * oa + ub * ua * (1 - ai)) / out_a
    return (int(out_r), int(out_g), int(out_b), int(out_a))


class Canvas:
    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.px = [TRANSPARENT] * (w * h)

    def put(self, x, y, color):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = y * self.w + x
            self.px[i] = blend(color, self.px[i])

    def filled_rect(self, x0, y0, x1, y1, color, radius=0):
        # Inclusive coords; radius is corner radius in pixels.
        for y in range(y0, y1):
            for x in range(x0, x1):
                if radius > 0:
                    cx, cy = x, y
                    if cx < x0 + radius and cy < y0 + radius:
                        if (x0 + radius - cx) ** 2 + (y0 + radius - cy) ** 2 > radius * radius:
                            continue
                    elif cx >= x1 - radius and cy < y0 + radius:
                        if (cx - (x1 - radius - 1)) ** 2 + (y0 + radius - cy) ** 2 > radius * radius:
                            continue
                    elif cx < x0 + radius and cy >= y1 - radius:
                        if (x0 + radius - cx) ** 2 + (cy - (y1 - radius - 1)) ** 2 > radius * radius:
                            continue
                    elif cx >= x1 - radius and cy >= y1 - radius:
                        if (cx - (x1 - radius - 1)) ** 2 + (cy - (y1 - radius - 1)) ** 2 > radius * radius:
                            continue
                self.put(x, y, color)

    def vline(self, x, y0, y1, color, thickness=1):
        for t in range(thickness):
            for y in range(y0, y1):
                self.put(x + t, y, color)


def render(size: int) -> bytes:
    """Render at size×size via 4× supersampling, then box-downsample."""
    ss = 4
    big = Canvas(size * ss, size * ss)
    s = size * ss / 64.0  # scale factor: SVG viewBox is 0..64

    def S(v):
        return int(round(v * s))

    radius = max(1, S(6))

    # Green rounded backdrop, full canvas.
    big.filled_rect(0, 0, size * ss, size * ss, HPE_GREEN, radius=radius)

    # Server white panel (inset rectangle).
    big.filled_rect(S(8), S(24), S(56), S(40), WHITE)

    # Status LED (tiny green square on front-left).
    big.filled_rect(S(11), S(29), S(15), S(35), HPE_GREEN)

    # Drive bay separators (6 vertical lines).
    bay_thickness = max(1, ss // 2)
    for x_unit in (22, 28, 34, 40, 46, 52):
        big.vline(S(x_unit), S(26), S(38), NEAR_BLACK, thickness=bay_thickness)

    # Bottom rack-ear shadow.
    big.filled_rect(S(8), S(44), S(56), S(46), HPE_GREEN_DARK)

    # Box downsample 4×4 → 1
    out = Canvas(size, size)
    for y in range(size):
        for x in range(size):
            r_acc = g_acc = b_acc = a_acc = 0
            for dy in range(ss):
                for dx in range(ss):
                    sx = x * ss + dx
                    sy = y * ss + dy
                    pr, pg, pb, pa = big.px[sy * big.w + sx]
                    r_acc += pr * pa
                    g_acc += pg * pa
                    b_acc += pb * pa
                    a_acc += pa
            n = ss * ss
            if a_acc == 0:
                out.px[y * size + x] = TRANSPARENT
            else:
                out.px[y * size + x] = (
                    r_acc // a_acc,
                    g_acc // a_acc,
                    b_acc // a_acc,
                    a_acc // n,
                )

    return _png(out)


def _png(canvas: Canvas) -> bytes:
    """Encode canvas as RGBA PNG bytes."""
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", canvas.w, canvas.h, 8, 6, 0, 0, 0)

    raw = bytearray()
    for y in range(canvas.h):
        raw.append(0)  # filter byte: none
        for x in range(canvas.w):
            r, g, b, a = canvas.px[y * canvas.w + x]
            raw.extend((r, g, b, a))
    idat = zlib.compress(bytes(raw), 9)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def main(argv):
    if len(argv) < 2:
        print("usage: render-icon.py <out.png> [size]", file=sys.stderr)
        return 2
    out_path = argv[1]
    size = int(argv[2]) if len(argv) > 2 else 64
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(render(size))
    print(f"wrote {out_path} ({size}x{size})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
