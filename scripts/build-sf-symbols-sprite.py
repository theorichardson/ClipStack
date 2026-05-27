#!/usr/bin/env python3
"""Build an inline-ready SF Symbols sprite from docs/images/sf/*.svg exports."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SF_DIR = ROOT / "docs" / "images" / "sf"
OUT = ROOT / "docs" / "sf-symbols.svg"

SYMBOLS = [
    "magnifyingglass",
    "link",
    "text-alignleft",
    "photo",
    "rectangle-dashed",
    "macwindow",
    "square-resize-down",
    "ellipsis",
]


def slug_to_id(slug: str) -> str:
    return f"sf-{slug}"


def extract_paths(svg_text: str) -> tuple[str, str]:
    viewbox = "0 0 24 24"
    match = re.search(r'viewBox="([^"]+)"', svg_text)
    if match:
        viewbox = match.group(1)

    paths = []
    for path_match in re.finditer(r"<path\b[^>]*?/>", svg_text):
        path = path_match.group(0)
        path = re.sub(r'\sfill="[^"]*"', ' fill="currentColor"', path)
        path = re.sub(r'\sdata-layer="[^"]*"', "", path)
        paths.append(path)

    if not paths:
        raise ValueError("No paths found in SVG")

    return viewbox, "\n    ".join(paths)


def main() -> int:
    symbols_xml = []
    for slug in SYMBOLS:
        source = SF_DIR / f"{slug}.svg"
        if not source.exists():
            print(f"Missing export: {source}", file=sys.stderr)
            return 1

        viewbox, paths = extract_paths(source.read_text())
        symbol_id = slug_to_id(slug)
        symbols_xml.append(
            f'  <symbol id="{symbol_id}" viewBox="{viewbox}">\n    {paths}\n  </symbol>'
        )

    sprite = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" style="display:none">\n'
        + "\n".join(symbols_xml)
        + "\n</svg>\n"
    )
    OUT.write_text(sprite)
    print(f"Wrote {OUT} ({len(SYMBOLS)} symbols)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
