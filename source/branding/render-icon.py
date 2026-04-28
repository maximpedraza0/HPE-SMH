#!/usr/bin/env python3
"""
Rasterise source/branding/hpe-mgmt.svg to PNG.

Thin wrapper over rsvg-convert (librsvg2-bin) — chosen over a
hand-rolled SVG renderer so the SVG can be edited freely (paths,
filters, gradients, anything librsvg supports) without re-coding
the rasteriser.

Install on Debian/Ubuntu:
    sudo apt-get install librsvg2-bin

Usage:
    python3 source/branding/render-icon.py <out.png> [size]

Default size is 64.  Generates both icons/<file>.png and
images/<file>.png paths if --pair is passed.
"""

import os
import shutil
import subprocess
import sys


def render_one(svg_path: str, out_path: str, size: int) -> None:
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), svg_path, "-o", out_path],
        check=True,
    )
    print(f"wrote {out_path} ({size}x{size})")


def main(argv: list[str]) -> int:
    if shutil.which("rsvg-convert") is None:
        print(
            "rsvg-convert not found. Install librsvg2-bin "
            "(e.g. `sudo apt-get install librsvg2-bin`).",
            file=sys.stderr,
        )
        return 2

    if len(argv) < 2:
        print("usage: render-icon.py <out.png> [size]", file=sys.stderr)
        return 2

    out_path = argv[1]
    size = int(argv[2]) if len(argv) > 2 else 64

    here = os.path.dirname(os.path.abspath(__file__))
    svg_path = os.path.join(here, "hpe-mgmt.svg")
    if not os.path.exists(svg_path):
        print(f"missing source SVG at {svg_path}", file=sys.stderr)
        return 2

    render_one(svg_path, out_path, size)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
