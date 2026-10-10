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
<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#181A22"/><stop offset="1" stop-color="#050507"/></linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.34" r="0.62"><stop offset="0" stop-color="#3385FA" stop-opacity="0.24"/><stop offset="1" stop-color="#3385FA" stop-opacity="0"/></radialGradient>
<linearGradient id="bar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8CBBFF"/><stop offset="1" stop-color="#3385FA"/></linearGradient>
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<rect width="1024" height="1024" fill="url(#glow)"/>
{monogram("#FFFFFF", "url(#bar)")}
</svg>'''


def dark_svg():
    return f'''{HEAD}
<defs>
<linearGradient id="bar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8CBBFF"/><stop offset="1" stop-color="#3385FA"/></linearGradient>
</defs>
<rect width="1024" height="1024" fill="#000000"/>
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
  <rect x="1" y="1" width="94" height="94" rx="25" fill="#121216" stroke="#303030" stroke-width="2"/>
  <g transform="translate(-5.76 -5.76) scale(0.105)">
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
     ).write_text(launch_mark_svg())
    print("wrote LaunchMark.svg")
    (HERE / "AppIcon.svg").write_text(default_svg())


if __name__ == "__main__":
    main()
