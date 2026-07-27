#!/usr/bin/env python3
"""Renders the app icon renditions from the source logo.

The logo as drawn is not an app icon: its rounded-rect tile uses a 16.7% corner
radius where macOS 26 uses ~22.4%, and the sail mark sits at 64% x 70% of the
tile, pushed left. Rasterising it and then insetting it again on the classic
824/1024 macOS grid stacked two insets and produced a small icon with visibly
wrong corners.

So the tile is redrawn here at full bleed and the sail is recomposed centred and
scaled up, rather than the source being rasterised as-is. macOS 26 masks a
legacy icon into its own shape, and drawing our own rounding at the same radius
means the two agree either way.

Only the two sail paths are taken from the source; the background and geometry
are computed. Re-run after editing VelaLogo.svg.
"""

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICONSET = ROOT / "MacClient/Resources/Assets.xcassets/AppIcon.appiconset"
SOURCE = ICONSET / "VelaLogo.svg"

CANVAS = 1024
# macOS 26 / iOS squircle proportion. The system mask sits here too.
CORNER = CANVAS * 0.2237
# Fraction of the canvas the sail spans on its longer axis. The mark is a thin
# diagonal, so it needs to run larger than a compact glyph would to read at 32pt.
MARK_SPAN = 0.78

GRADIENT_TOP = "#4d29aa"
GRADIENT_BOTTOM = "#1e123d"

# Every rendition verify.sh asserts, as (file suffix, pixel size).
RENDITIONS = [
    ("16x16", 16),
    ("16x16@2x", 32),
    ("32x32", 32),
    ("32x32@2x", 64),
    ("128x128", 128),
    ("128x128@2x", 256),
    ("256x256", 256),
    ("256x256@2x", 512),
    ("512x512", 512),
    ("512x512@2x", 1024),
]


def sail_paths(svg: str) -> tuple[list[str], float]:
    """The two sail outlines and their stroke width, lifted from the source."""
    paths = re.findall(r'd="(m72\.48877[^"]+|m237\.84839[^"]+)"', svg)
    # Fill and stroke are separate elements sharing a `d`, hence the dedupe.
    unique = list(dict.fromkeys(paths))
    if len(unique) != 2:
        sys.exit(f"expected 2 sail paths in {SOURCE.name}, found {len(unique)}")
    stroke = re.search(r'stroke-width="([\d.]+)"', svg)
    return unique, float(stroke.group(1)) if stroke else 9.876640419947506


def optical_parameters(pixel_size: int) -> tuple[float, float, str]:
    """Returns span, outline multiplier, and fill tuned for a rendition.

    Straight downsampling made the thin sail outline less than half a pixel at
    16 pt and nearly erased the mark. Small renditions need a heavier outline
    and more fill contrast, like a typeface needs optical sizes.
    """
    if pixel_size <= 16:
        return 0.76, 2.5, "#a18bd5"
    if pixel_size <= 32:
        return 0.77, 2.0, "#8b73c6"
    if pixel_size <= 64:
        return 0.78, 1.4, "#755db6"
    return MARK_SPAN, 1.0, "#674ea7"


def mark_transform(stroke: float, mark_span: float) -> str:
    """Scales the sail to MARK_SPAN of the canvas and centres it.

    The bounding box is the union of both sails' extreme points, grown by half
    the stroke width, since a stroke straddles its path.
    """
    half = stroke / 2
    min_x, max_x = 72.48877 - half, 381.18561 + half
    min_y, max_y = 70.793045 - half, 409.208 + half
    width, height = max_x - min_x, max_y - min_y

    scale = (CANVAS * mark_span) / max(width, height)
    tx = (CANVAS - width * scale) / 2 - min_x * scale
    ty = (CANVAS - height * scale) / 2 - min_y * scale
    return f"translate({tx:.4f} {ty:.4f}) scale({scale:.6f})"


def build_svg(pixel_size: int) -> str:
    source = SOURCE.read_text()
    sails, stroke = sail_paths(source)
    mark_span, outline_multiplier, fill = optical_parameters(pixel_size)
    transform = mark_transform(stroke, mark_span)
    # Stroke width is in user space, so scaling the group scales it too, which
    # is what keeps the outline weight proportional at any size.
    outlines = "".join(
        f'<path fill="{fill}" d="{d}"/>'
        f'<path fill="none" stroke="#20124d" stroke-width="{stroke * outline_multiplier:.6f}" '
        f'stroke-linejoin="round" d="{d}"/>'
        for d in sails
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}">'
        f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="{CANVAS}" '
        f'gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{GRADIENT_TOP}"/>'
        f'<stop offset="1" stop-color="{GRADIENT_BOTTOM}"/>'
        f"</linearGradient></defs>"
        f'<rect width="{CANVAS}" height="{CANVAS}" rx="{CORNER:.2f}" ry="{CORNER:.2f}" '
        f'fill="url(#bg)"/>'
        f'<g transform="{transform}">{outlines}</g>'
        f"</svg>"
    )


def rasterise(svg_path: pathlib.Path, work: pathlib.Path) -> pathlib.Path:
    """qlmanage is the only SVG rasteriser present; rsvg/Inkscape are not."""
    subprocess.run(
        ["qlmanage", "-t", "-s", str(CANVAS), "-o", str(work), str(svg_path)],
        check=True,
        capture_output=True,
    )
    rendered = next(work.glob("*.png"), None)
    if rendered is None:
        sys.exit("qlmanage produced no output")
    # qlmanage pads to a square but does not guarantee the exact size.
    subprocess.run(
        ["sips", "-z", str(CANVAS), str(CANVAS), str(rendered)],
        check=True,
        capture_output=True,
    )
    return rendered


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        work = pathlib.Path(raw)
        masters: dict[int, pathlib.Path] = {}
        for size in sorted({size for _, size in RENDITIONS}):
            rendition_work = work / str(size)
            rendition_work.mkdir()
            svg_path = rendition_work / "icon.svg"
            svg_path.write_text(build_svg(size))
            masters[size] = rasterise(svg_path, rendition_work)

        for suffix, size in RENDITIONS:
            target = ICONSET / f"AppIcon-{suffix}.png"
            subprocess.run(
                ["sips", "-z", str(size), str(size), str(masters[size]), "--out", str(target)],
                check=True,
                capture_output=True,
            )
            print(f"  {target.name}  {size}x{size}")


if __name__ == "__main__":
    main()
