#!/usr/bin/env python3
"""Draw the EasySend app icon and write the masters into assets/.

Two phones with a blue triangle between them, on cream. Everything is geometry
drawn at 4x and downsampled, so no edge carries the artefacts a recoloured
bitmap would. Run it after changing anything here:

    python3 tools/make_icon.py

then regenerate the launcher icons with:

    dart run flutter_launcher_icons
"""

import os

from PIL import Image, ImageDraw

SS = 4  # supersampling factor
SIZE = 1024

CREAM = (255, 247, 223)  # #FFF7DF, also adaptive_icon_background in pubspec.yaml
TEAL = (130, 211, 224)  # #82D3E0, the screens
TRIANGLE = (1, 56, 163)  # #0138A3, 9.4:1 against the cream
INK = (17, 17, 17)  # #111111, the phone bodies

HEIGHT = 0.45  # phone height as a fraction of the canvas
# The round launcher mask leaves a 61% circle. The far corner of the drawing has
# to sit inside it, and this is the scale at which it does.
SAFE = 0.646

ASSETS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")


def phone(d, x, y, w, h):
    """Ink body, rounded, with a screen, an earpiece slot and a home button."""
    r = w * 0.18
    d.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=INK)
    bez_x, bez_top, bez_bot = w * 0.09, h * 0.10, h * 0.11
    d.rounded_rectangle(
        [x + bez_x, y + bez_top, x + w - bez_x, y + h - bez_bot],
        radius=r * 0.25,
        fill=TEAL,
    )
    ew, eh = w * 0.30, h * 0.022
    d.rounded_rectangle(
        [x + w / 2 - ew / 2, y + h * 0.045, x + w / 2 + ew / 2, y + h * 0.045 + eh],
        radius=eh / 2,
        fill=TEAL,
    )
    bw, bh = w * 0.26, h * 0.028
    d.rounded_rectangle(
        [x + w / 2 - bw / 2, y + h - h * 0.075, x + w / 2 + bw / 2, y + h - h * 0.075 + bh],
        radius=bh / 2,
        fill=TEAL,
    )


def drawing(background, scale=1.0):
    """The whole icon on the given background, scaled around the centre."""
    s = SIZE * SS
    im = Image.new("RGBA", (s, s), background)
    d = ImageDraw.Draw(im)
    pw, ph = s * 0.235 * scale, s * HEIGHT * scale
    margin = s / 2 - s * 0.415 * scale
    y = (s - ph) / 2
    phone(d, margin, y, pw, ph)
    phone(d, s - margin - pw, y, pw, ph)
    tw, th = s * 0.20 * scale, s * 0.26 * scale
    x0, y0 = (s - tw) / 2, (s - th) / 2
    d.polygon([(x0, y0), (x0 + tw, y0 + th / 2), (x0, y0 + th)], fill=TRIANGLE)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    square = drawing(CREAM).convert("RGB")
    # The master and the square the plain-icon launchers mask themselves.
    # icon2.png is not written here: the Linux window icon is its own drawing,
    # a phone and a monitor, and it is not this one.
    for name in ("icon.png", "icon_small.png"):
        square.save(os.path.join(ASSETS, name))
    # The adaptive foreground: the drawing on nothing, already inset to the safe
    # circle, which is why pubspec.yaml adds no inset of its own.
    drawing((0, 0, 0, 0), SAFE).save(os.path.join(ASSETS, "icon_fg.png"))
    print(f"written to {ASSETS}")


if __name__ == "__main__":
    main()
