"""
Build the IntuneWipeClient application icon.

Design rationale
----------------
The icon must read as "device reset" instantly. The previous attempt used a
hand-painted PIL composition that produced a wobbly arrowhead. This version
uses a single vector source (SVG) rasterised at full resolution by Edge
headless, then downsampled with Lanczos for each ICO sub-size.

Visual language:
  * Red rounded-square plate (squircle-ish, matches Windows 11 visual idiom).
  * Centred white circular "reset" arrow with a CLEAN triangular arrowhead -
    geometry borrowed from the Lucide `rotate-ccw` icon (ISC-licensed) and
    scaled to fill the plate.
  * Subtle vertical gradient on the plate for depth without being noisy.

Output:
  * source/assets/IntuneWipeClient.ico  (multi-size: 16/24/32/48/64/128/256)
  * source/assets/icon-<size>.png      (per-size reference renders)
  * tools/build/icon-source.svg        (vector source, kept for reuse)
  * tools/build/icon-1024.png          (master raster)

Re-run from anywhere; outputs are deterministic.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]          # client/intune-win32-package
ASSETS = ROOT / "source" / "assets"
BUILD = ROOT / "tools" / "build"
ASSETS.mkdir(parents=True, exist_ok=True)
BUILD.mkdir(parents=True, exist_ok=True)

SVG_PATH = BUILD / "icon-source.svg"
MASTER_PNG = BUILD / "icon-1024.png"
ICO_PATH = ASSETS / "IntuneWipeClient.ico"
SIZES = (16, 24, 32, 48, 64, 128, 256)

# ---------------------------------------------------------------------------
# SVG source
# ---------------------------------------------------------------------------
# Canvas: 1024 x 1024.
# Plate: rounded square, corner radius 192 (~18.75%), red gradient.
# Glyph: Lucide `rotate-ccw` (24-grid):
#   M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8
#   M3 3v5h5
# Scaled into a 720x720 inner box centred on the plate (centre 512,512).
# Scale factor 720/24 = 30, then translated so the original 24-grid origin
# lands at plate_centre - (12*30) = 512 - 360 = 152 on both axes.

SVG = """<?xml version='1.0' encoding='UTF-8'?>
<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1024 1024' width='1024' height='1024'>
  <defs>
    <linearGradient id='plate' x1='0' y1='0' x2='0' y2='1'>
      <stop offset='0%'  stop-color='#00A063'/>
      <stop offset='100%' stop-color='#006B41'/>
    </linearGradient>
    <filter id='glyphShadow' x='-10%' y='-10%' width='120%' height='120%'>
      <feGaussianBlur in='SourceAlpha' stdDeviation='6'/>
      <feOffset dx='0' dy='6' result='offsetblur'/>
      <feComponentTransfer><feFuncA type='linear' slope='0.35'/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in='SourceGraphic'/></feMerge>
    </filter>
  </defs>

  <!-- Plate -->
  <rect x='32' y='32' width='960' height='960' rx='192' ry='192' fill='url(#plate)'/>
  <!-- Inner highlight (very subtle) -->
  <rect x='32' y='32' width='960' height='32' rx='192' ry='192' fill='#ffffff' fill-opacity='0.10'/>

  <!-- Reset glyph: lucide rotate-ccw, translated+scaled (origin 152,152, scale 30) -->
  <g transform='translate(152 152) scale(30)' fill='none' stroke='#ffffff'
     stroke-width='2.4' stroke-linecap='round' stroke-linejoin='round'
     filter='url(#glyphShadow)'>
    <!-- 3/4 arc + tail down to (3,8) -->
    <path d='M3 12a9 9 0 1 0 9 -9 9.75 9.75 0 0 0 -6.74 2.74L3 8'/>
    <!-- Arrowhead (corner of the tail) -->
    <path d='M3 3v5h5'/>
  </g>
</svg>
"""


# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------
def find_edge() -> Path:
    """Locate msedge.exe."""
    candidates = [
        Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
        Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    ]
    for c in candidates:
        if c.exists():
            return c
    raise FileNotFoundError("msedge.exe not found in standard locations")


def render_svg_to_png(svg_file: Path, png_file: Path, size: int) -> None:
    """Rasterise SVG to PNG at the requested size via Edge headless."""
    edge = find_edge()
    # Wrap the SVG in HTML so we can size the viewport exactly and force
    # a transparent background.
    html = BUILD / f"_render_{size}.html"
    svg_text = svg_file.read_text(encoding="utf-8")
    html.write_text(
        f"""<!doctype html><html><head><meta charset='utf-8'><style>
html,body{{margin:0;padding:0;background:transparent;width:{size}px;height:{size}px;overflow:hidden}}
svg{{display:block;width:{size}px;height:{size}px}}
</style></head><body>{svg_text}</body></html>""",
        encoding="utf-8",
    )
    if png_file.exists():
        png_file.unlink()
    cmd = [
        str(edge),
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--default-background-color=00000000",
        f"--screenshot={png_file}",
        f"--window-size={size},{size}",
        html.resolve().as_uri(),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    if not png_file.exists():
        raise RuntimeError(f"Edge did not produce {png_file}")


def build_ico(master_png: Path, ico_path: Path) -> None:
    """Pack a multi-size ICO from the master PNG using Lanczos downsampling."""
    master = Image.open(master_png).convert("RGBA")
    images = []
    for s in SIZES:
        im = master.resize((s, s), Image.LANCZOS)
        images.append(im)
        per_size = ASSETS / f"icon-{s}.png"
        im.save(per_size, "PNG", optimize=True)
    # PIL packs all `sizes` from the image's content; pass our list as
    # explicit sub-image sizes and supply append_images so each size
    # rasterises from its tailored Lanczos render rather than from master.
    images[-1].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in SIZES],
        append_images=images[:-1],
    )


def main() -> int:
    SVG_PATH.write_text(SVG, encoding="utf-8")
    print(f"  Wrote {SVG_PATH.relative_to(ROOT)}")

    render_svg_to_png(SVG_PATH, MASTER_PNG, 1024)
    print(f"  Rendered {MASTER_PNG.relative_to(ROOT)} ({MASTER_PNG.stat().st_size // 1024} KB)")

    build_ico(MASTER_PNG, ICO_PATH)
    print(f"  Packed {ICO_PATH.relative_to(ROOT)} ({ICO_PATH.stat().st_size // 1024} KB)")
    print(f"  Per-size PNG samples in {ASSETS.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
