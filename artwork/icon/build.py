"""Regenerates every app icon from the vector monogram in mark.py.

    python3 -m venv /tmp/iconenv && /tmp/iconenv/bin/pip install cairosvg pillow
    /tmp/iconenv/bin/python artwork/icon/build.py

Outputs (all opaque RGB PNG, no alpha):
  iOS  AppIcon.png (default), AppIcon-Dark.png, AppIcon-Tinted.png
  watchOS AppIcon.png
  AppIconPreview 1x/2x/3x, LaunchMark.svg, artwork/AppIconBlackMaster.png
"""
import io
import pathlib
import sys

import cairosvg
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from mark import monogram  # noqa: E402

HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">')


def default_svg():
    return f'''{HEAD}
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#1C2635"/><stop offset="1" stop-color="#080B11"/></linearGradient>
<radialGradient id="glow" cx="0.48" cy="0.36" r="0.64"><stop offset="0" stop-color="#477EB5" stop-opacity="0.15"/><stop offset="1" stop-color="#477EB5" stop-opacity="0"/></radialGradient>
<linearGradient id="pearl" gradientUnits="userSpaceOnUse" x1="324" y1="242" x2="640" y2="782"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#CDD8E7"/></linearGradient>
<linearGradient id="bar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#B3D4FF"/><stop offset="1" stop-color="#6DA4F4"/></linearGradient>
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<rect width="1024" height="1024" fill="url(#glow)"/>
{monogram("url(#pearl)", "url(#bar)")}
</svg>'''


def dark_svg():
    return f'''{HEAD}
<defs>
<linearGradient id="bar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8CBBFF"/><stop offset="1" stop-color="#3385FA"/></linearGradient>
</defs>
<rect width="1024" height="1024" fill="#05070B"/>
{monogram("#FFFFFF", "url(#bar)")}
</svg>'''


def tinted_svg():
    return f'''{HEAD}
<rect width="1024" height="1024" fill="#000000"/>
{monogram("#FFFFFF", "#B8B8B8")}
</svg>'''


def launch_mark_svg():
    # Flat colours only: Xcode's SVG importer is conservative about gradients.
    body = monogram("#FFFFFF", "#5C9DFF")
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <rect width="96" height="96" rx="25" fill="#101722"/>
  <g transform="scale(0.09375)">
{body}
  </g>
</svg>
'''


def png(svg, size=1024):
    data = cairosvg.svg2png(bytestring=svg.encode(), output_width=size,
                            output_height=size)
    return Image.open(io.BytesIO(data)).convert("RGB")


def save(image, path, size=None):
    path = ROOT / path
    path.parent.mkdir(parents=True, exist_ok=True)
    if size and image.size != (size, size):
        image = image.resize((size, size), Image.LANCZOS)
    image.save(path, optimize=True)
    print("wrote", path.relative_to(ROOT))


def main():
    default, dark, tinted = (png(default_svg()), png(dark_svg()),
                             png(tinted_svg()))
    ios = "PrivateMusic/Resources/Assets.xcassets/AppIcon.appiconset"
    save(default, f"{ios}/AppIcon.png")
    save(dark, f"{ios}/AppIcon-Dark.png")
    save(tinted, f"{ios}/AppIcon-Tinted.png")
    save(default, "PrivateMusicWatch/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    save(default, "artwork/AppIconBlackMaster.png")
    preview = "PrivateMusic/Resources/Assets.xcassets/AppIconPreview.imageset"
    save(default, f"{preview}/AppIconPreview1x.png", 256)
    save(default, f"{preview}/AppIconPreview.png", 512)
    save(default, f"{preview}/AppIconPreview3x.png", 768)
    (ROOT / "PrivateMusic/Resources/Assets.xcassets/LaunchMark.imageset/LaunchMark.svg"
     ).write_text(launch_mark_svg(), encoding="utf-8", newline="\n")
    print("wrote LaunchMark.svg")
    (HERE / "AppIcon.svg").write_text(default_svg(), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
