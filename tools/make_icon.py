"""Draws Sage's app icon and writes it into the iPhone and watch asset catalogs.

The icon carries the face's identity: the near-black dial with its ring of minute ticks in the track colour (the
hour marks in sage), and Sage's idea, two sleeps a day: a large ivory crescent for the night and a small sage moon
for the nap, sitting in the crescent's opening.

Run:  python tools/make_icon.py        (needs Pillow)
"""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 4096                      # drawn large, scaled down to 1024 for clean edges

IVORY = (226, 217, 201)
SAGE = (140, 154, 126)
SAGE_LIGHT = (185, 196, 170)
TRACK = (67, 68, 62)


def radial_background(size):
    """near-black with a green cast, a little lighter behind the moon"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    cx, cy = size * 0.47, size * 0.44
    inner, outer = (31, 36, 27), (9, 10, 8)
    rmax = size * 0.75
    for y in range(size):
        for x in range(0, size):
            t = min(1.0, math.hypot(x - cx, y - cy) / rmax)
            t = t * t * (3 - 2 * t)
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * t) for i in range(3))
    return img


def draw_icon():
    # the gradient is smooth, so draw it small and scale it up
    bg = radial_background(512).resize((S, S), Image.BICUBIC)
    d = ImageDraw.Draw(bg)
    c = S / 2

    # the ring of minute ticks, as on the face's railway track; the five-minute marks in sage
    r_out, r_minor, r_major = S * 0.435, S * 0.405, S * 0.385
    for i in range(60):
        a = i / 60 * 2 * math.pi
        major = i % 5 == 0
        r_in = r_major if major else r_minor
        x0, y0 = c + math.sin(a) * r_in, c - math.cos(a) * r_in
        x1, y1 = c + math.sin(a) * r_out, c - math.cos(a) * r_out
        d.line([(x0, y0), (x1, y1)], fill=SAGE if major else TRACK, width=int(S * (0.011 if major else 0.006)))

    # the night: an ivory crescent opening to the upper right
    moon = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(moon)
    mx, my, mr = S * 0.475, S * 0.525, S * 0.235
    md.ellipse([mx - mr, my - mr, mx + mr, my + mr], fill=255)
    cut_x, cut_y, cut_r = mx + S * 0.105, my - S * 0.085, mr * 0.86
    md.ellipse([cut_x - cut_r, cut_y - cut_r, cut_x + cut_r, cut_y + cut_r], fill=0)

    # a soft glow under the crescent, then the crescent itself
    glow = moon.filter(ImageFilter.GaussianBlur(S * 0.03))
    bg.paste(Image.new("RGB", (S, S), (120, 128, 100)), (0, 0), glow.point(lambda v: int(v * 0.22)))
    bg.paste(Image.new("RGB", (S, S), IVORY), (0, 0), moon)

    # the nap: a small sage crescent, the same shape as the night's, in its opening (two moons, two sleeps)
    nx, ny, nr = S * 0.655, S * 0.375, S * 0.085
    nap = Image.new("L", (S, S), 0)
    nd = ImageDraw.Draw(nap)
    nd.ellipse([nx - nr, ny - nr, nx + nr, ny + nr], fill=255)
    k = nr / mr
    ncx, ncy, ncr = nx + S * 0.105 * k, ny - S * 0.085 * k, cut_r * k
    nd.ellipse([ncx - ncr, ncy - ncr, ncx + ncr, ncy + ncr], fill=0)
    bg.paste(Image.new("RGB", (S, S), SAGE_LIGHT), (0, 0), nap)

    return bg.resize((1024, 1024), Image.LANCZOS)


def write_catalog(folder, platform, icon):
    cat = os.path.join(ROOT, folder, "Assets.xcassets")
    iconset = os.path.join(cat, "AppIcon.appiconset")
    os.makedirs(iconset, exist_ok=True)
    with open(os.path.join(cat, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    icon.save(os.path.join(iconset, "AppIcon.png"))
    with open(os.path.join(iconset, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    icon = draw_icon()
    write_catalog("iOS", "ios", icon)
    write_catalog("Watch", "watchos", icon)
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    icon.save(os.path.join(ROOT, "docs", "app-icon.png"))
    print("wrote iOS/ and Watch/ Assets.xcassets and docs/app-icon.png")
