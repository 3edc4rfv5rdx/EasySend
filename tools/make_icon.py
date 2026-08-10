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

# Everything below is a fraction of the canvas. The triangle narrows to a point,
# so an equal gap on both sides of it reads as a hole on the right: the right one
# is closed to about half.
PHONE_W, PHONE_H = 0.235, 0.45
TRI_W, TRI_H = 0.20, 0.26
GAP_LEFT = 0.08
GAP_RIGHT = 0.05

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


def monitor(d, x, y, w, h):
    """Ink body with a teal screen, on a neck and a foot. h is the body alone;
    the stand hangs below it."""
    r = w * 0.05
    d.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=INK)
    bez = w * 0.045
    d.rounded_rectangle(
        [x + bez, y + bez, x + w - bez, y + h - bez * 1.6],
        radius=r * 0.5,
        fill=TEAL,
    )
    nw, nh = w * 0.13, h * 0.20
    d.rectangle([x + w / 2 - nw / 2, y + h, x + w / 2 + nw / 2, y + h + nh], fill=INK)
    fw, fh = w * 0.44, h * 0.09
    d.rounded_rectangle(
        [x + w / 2 - fw / 2, y + h + nh, x + w / 2 + fw / 2, y + h + nh + fh],
        radius=fh / 2,
        fill=INK,
    )


def triangle(d, x, y, w, h):
    d.polygon([(x, y), (x + w, y + h / 2), (x, y + h)], fill=TRIANGLE)


def drawing(background, scale=1.0):
    """The whole icon on the given background, scaled around the centre."""
    s = SIZE * SS
    im = Image.new("RGBA", (s, s), background)
    d = ImageDraw.Draw(im)
    pw, ph = s * PHONE_W * scale, s * PHONE_H * scale
    tw, th = s * TRI_W * scale, s * TRI_H * scale
    # Laid out left to right from the group's own width, so closing one gap
    # moves the pieces and leaves the whole drawing centred.
    total = (PHONE_W + GAP_LEFT + TRI_W + GAP_RIGHT + PHONE_W) * scale * s
    x = (s - total) / 2
    phone(d, x, (s - ph) / 2, pw, ph)
    x += pw + s * GAP_LEFT * scale
    triangle(d, x, (s - th) / 2, tw, th)
    x += tw + s * GAP_RIGHT * scale
    phone(d, x, (s - ph) / 2, pw, ph)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def desktop_drawing(background):
    """The window icon of the desktop build: a phone sending to a monitor. The
    same hand as the launcher icon, the same two devices it has always shown."""
    s = SIZE * SS
    im = Image.new("RGBA", (s, s), background)
    d = ImageDraw.Draw(im)
    pw, ph = s * 0.19, s * 0.40
    phone(d, s * 0.07, (s - ph) / 2, pw, ph)
    tw, th = s * 0.13, s * 0.19
    triangle(d, s * 0.325, (s - th) / 2, tw, th)
    mw, mh = s * 0.40, s * 0.30
    stand = mh * 0.29  # neck plus foot, so the whole thing can be centred
    monitor(d, s * 0.51, (s - mh - stand) / 2, mw, mh)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    square = drawing(CREAM).convert("RGB")
    # The master and the square the plain-icon launchers mask themselves.
    for name in ("icon.png", "icon_small.png"):
        square.save(os.path.join(ASSETS, name))
    # The window icon the Linux runner loads from the bundle: its own drawing,
    # a phone sending to a monitor, because that build runs on the monitor.
    desktop_drawing(CREAM).convert("RGB").save(os.path.join(ASSETS, "icon2.png"))
    # The adaptive foreground: the drawing on nothing, already inset to the safe
    # circle, which is why pubspec.yaml adds no inset of its own.
    drawing((0, 0, 0, 0), SAFE).save(os.path.join(ASSETS, "icon_fg.png"))
    print(f"written to {ASSETS}")


if __name__ == "__main__":
    main()
