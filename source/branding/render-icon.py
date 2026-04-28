#!/usr/bin/env python3
"""
Render the HPE-SMH plugin icon to PNG using only the Python stdlib.

Layout (64×64 canvas, transparent background):

    - "HPE" wordmark in black uppercase at the top.
    - "HPE Element" rectangle in the middle as a horizontal separator:
      hollow 5:1 horizontal bar (the iconic HPE corporate mark
      proportions), 3-px green (#01A982) stroke, transparent fill,
      sharp corners.
    - "mngr" wordmark in black lowercase below the rectangle.

Glyphs come from a hand-drawn 5×7 bitmap font built into this script
so we don't need a TTF, librsvg, imagemagick, or PIL at build time.

Usage:
    python3 source/branding/render-icon.py icons/hpe-mgmt.png [size]

Default size is 64.  Anti-aliased edges via 4× supersampling.
"""

import os
import struct
import sys
import zlib


HPE_GREEN = (1, 169, 130, 255)
# Mid neutral gray — picked to match the perceived tone of stock unRAID
# Font Awesome icons in the /Plugins listing on the default light theme.
TEXT_GRAY = (90, 96, 102, 255)
TRANSPARENT = (0, 0, 0, 0)


# ---------------------------------------------------------------------------
# 5×7 pixel font.  '#' = pixel on, '.' = off.
# ---------------------------------------------------------------------------
GLYPHS = {
    "H": [
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    ],
    "P": [
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#....",
        "#....",
        "#....",
    ],
    "E": [
        "#####",
        "#....",
        "#....",
        "####.",
        "#....",
        "#....",
        "#####",
    ],
    "m": [
        ".....",
        ".....",
        "##.#.",
        "#.#.#",
        "#.#.#",
        "#.#.#",
        "#.#.#",
    ],
    "n": [
        ".....",
        ".....",
        "####.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
    ],
    "g": [
        ".....",
        ".####",
        "#...#",
        "#...#",
        ".####",
        "....#",
        "####.",
    ],
    "r": [
        ".....",
        ".....",
        "####.",
        "#...#",
        "#....",
        "#....",
        "#....",
    ],
}
GLYPH_W = 5
GLYPH_H = 7


def blend(over, under):
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

    def filled_rect(self, x0, y0, x1, y1, color):
        for y in range(y0, y1):
            for x in range(x0, x1):
                self.put(x, y, color)

    def hollow_rect(self, x0, y0, x1, y1, thickness, color):
        self.filled_rect(x0, y0, x1, y0 + thickness, color)
        self.filled_rect(x0, y1 - thickness, x1, y1, color)
        self.filled_rect(x0, y0 + thickness, x0 + thickness, y1 - thickness, color)
        self.filled_rect(x1 - thickness, y0 + thickness, x1, y1 - thickness, color)

    def draw_glyph(self, x0, y0, glyph, scale, color):
        rows = GLYPHS.get(glyph)
        if rows is None:
            return
        for ry, row in enumerate(rows):
            for rx, ch in enumerate(row):
                if ch == "#":
                    self.filled_rect(
                        x0 + rx * scale,
                        y0 + ry * scale,
                        x0 + (rx + 1) * scale,
                        y0 + (ry + 1) * scale,
                        color,
                    )

    def draw_text(self, x0, y0, text, scale, color, spacing=1):
        x = x0
        for ch in text:
            self.draw_glyph(x, y0, ch, scale, color)
            x += GLYPH_W * scale + spacing * scale

    def text_width(self, text, scale, spacing=1):
        n = len(text)
        if n == 0:
            return 0
        return n * GLYPH_W * scale + (n - 1) * spacing * scale


def render(size: int) -> bytes:
    """Render at size×size via 4× supersampling, then box-downsample."""
    ss = 4
    big = Canvas(size * ss, size * ss)
    s = size * ss / 64.0  # scale factor: design space is 0..64

    def S(v):
        return int(round(v * s))

    # ---- "HPE" — uppercase, large, top of canvas ---------------------
    # 5×7 font at scale 3 → 15×21 per glyph; total 51×21 wordmark.
    hpe_scale = max(1, S(3))
    hpe_w = big.text_width("HPE", hpe_scale, spacing=1)
    hpe_x = (size * ss - hpe_w) // 2
    hpe_y = S(5)
    big.draw_text(hpe_x, hpe_y, "HPE", hpe_scale, TEXT_GRAY, spacing=1)

    # ---- HPE Element rectangle: 5:1 wide horizontal bar --------------
    # Sits between the two wordmarks as a horizontal separator.
    # 50 design units wide × 8 tall (~6:1 to match the official mark
    # which is even thinner than 5:1), sharp corners, 3-px stroke.
    frame_x0 = S(7)
    frame_y0 = S(31)
    frame_x1 = S(57)
    frame_y1 = S(39)
    frame_stroke = max(1, S(3))
    big.hollow_rect(frame_x0, frame_y0, frame_x1, frame_y1, frame_stroke, HPE_GREEN)

    # ---- "mngr" — lowercase, smaller, below the Element bar ----------
    # 5×7 font at scale 2 → 10×14 per glyph; total 46×14 wordmark.
    mngr_scale = max(1, S(2))
    mngr_w = big.text_width("mngr", mngr_scale, spacing=1)
    mngr_x = (size * ss - mngr_w) // 2
    mngr_y = S(45)
    big.draw_text(mngr_x, mngr_y, "mngr", mngr_scale, TEXT_GRAY, spacing=1)

    # ---- Box downsample 4×4 → 1 --------------------------------------
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
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", canvas.w, canvas.h, 8, 6, 0, 0, 0)

    raw = bytearray()
    for y in range(canvas.h):
        raw.append(0)
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
