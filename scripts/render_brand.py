"""Render the Kavach brand SVGs into the PNGs the app, launcher and web need.

    python scripts/render_brand.py          (needs: pip install playwright; uses installed Chrome)

Outputs into mobile/assets/brand/:
  icon_1024.png          full app icon (ink tile + mark)            -> legacy launcher, web, stores
  foreground_1024.png    mark on transparent, inside the safe zone   -> Android adaptive foreground
  monochrome_1024.png    single-colour silhouette                    -> Android 13 themed icon
  mark_512.png           mark on transparent                          -> splash / docs
"""
import re
from pathlib import Path

from playwright.sync_api import sync_playwright

BRAND = Path(__file__).resolve().parents[1] / "mobile" / "assets" / "brand"
mark_src = (BRAND / "kavach_mark.svg").read_text(encoding="utf-8")
MARK = re.search(r"<svg[^>]*>(.*)</svg>", mark_src, re.S).group(1)


def svg(body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}</svg>'


TILE = """
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#161925"/><stop offset="1" stop-color="#06070A"/></linearGradient>
  <radialGradient id="aura" cx="0.5" cy="0.45" r="0.55">
    <stop offset="0" stop-color="#8C9BFF" stop-opacity="0.30"/>
    <stop offset="1" stop-color="#8C9BFF" stop-opacity="0"/></radialGradient>
</defs>
<rect width="1024" height="1024" rx="{rx}" fill="url(#bg)"/>
<rect width="1024" height="1024" rx="{rx}" fill="url(#aura)"/>
"""


def placed(scale: float, body: str = MARK) -> str:
    off = 512 * (1 - scale)
    return f'<g transform="translate({off} {off}) scale({scale})">{body}</g>'


# themed (monochrome) icon: shield silhouette with the K and nodes cut out via a mask
SHIELD = re.search(r'<!-- shield -->\s*<path fill="[^"]+"\s*d="([^"]+)"', MARK).group(1)
CUTS = MARK[MARK.index("<!-- K: spine"):].replace('#0A0B0D', '#000000').replace('url(#node)', '#000000')
CUTS = re.sub(r'<circle cx="(\d+)" cy="(\d+)" r="20" fill="#ECE9E2"/>', r'<circle cx="\g<1>" cy="\g<2>" r="20" fill="#FFFFFF"/>', CUTS)
mono = (f'<mask id="m"><rect width="1024" height="1024" fill="#000"/><path fill="#FFF" d="{SHIELD}"/>{CUTS}</mask>'
        f'<rect width="1024" height="1024" fill="#FFFFFF" mask="url(#m)"/>')

JOBS = {
    "icon_1024.png": svg(TILE.format(rx=232) + placed(0.88)),
    "icon_square_1024.png": svg(TILE.format(rx=0) + placed(0.80)),     # stores / web maskable
    "foreground_1024.png": svg(placed(0.64)),
    "monochrome_1024.png": svg(placed(0.64, mono)),
    "mark_512.png": svg(MARK),
}

with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome", headless=True)
    page = b.new_page(viewport={"width": 1024, "height": 1024})
    for name, doc in JOBS.items():
        page.set_content(f"<html><body style='margin:0;background:transparent'>{doc}</body></html>")
        size = 512 if name.startswith("mark") else 1024
        page.set_viewport_size({"width": 1024, "height": 1024})
        out = BRAND / name
        page.locator("svg").screenshot(path=str(out), omit_background=True)
        if size != 1024:
            from PIL import Image
            Image.open(out).resize((size, size), Image.LANCZOS).save(out)
        print("wrote", out.name)
    b.close()
