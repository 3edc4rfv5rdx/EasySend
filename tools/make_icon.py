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

CREAM = (255, 247, 223)  # #FFF7DF, the mark
BLUE = (1, 56, 163)  # #0138A3, the ground; adaptive_icon_background in pubspec

# The mark: an outlined device and a page walking out through its right wall.
# One picture, no arrow — an arrow out of a frame is the sign every system uses
# for 'log out'. Fractions of the canvas.
MARK_FRAME_W, MARK_FRAME_H = 0.34, 0.54
MARK_STROKE = 0.036
MARK_SHEET_W, MARK_SHEET_H = 0.30, 0.238
# Where the page starts, as a fraction of the frame's width: it has to overlap
# the wall, or it reads as standing beside the device rather than leaving it.
MARK_OVERLAP = 0.62

DOC_FOLD = 0.34  # the folded corner, as a fraction of the sheet's width
DOC_GAP = 0.28  # how far the flap is pulled off the cut, as a fraction of it

# The one mark that says the outline is a phone and not a window: the front
# camera, drawn as a ring in the strip the page leaves free above it. Fractions
# of the canvas, like everything else here. A ring rather than a dot on purpose;
# the bottom button and the screen's own edge were both tried and dropped —
# at launcher size they thickened the body instead of describing it.
CAM_R = 0.018
CAM_RING = 0.009

# The round launcher mask leaves a 61% circle. The mark is wider on the left than
# on the right, so the foreground is centred on its own bounding box first; this
# is the scale at which its far corner then sits inside the circle.
SAFE = 0.82

ASSETS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")


def document(d, x, y, w, h, fill, flap):
    """A sheet with its top-right corner turned back. The corner is cut out
    square, so the ground shows through it, and the turned flap sits inside the
    cut with a gap all round. With the flap the same colour as the sheet, that
    gap alone does the work of the fold."""
    f = w * DOC_FOLD
    d.polygon(
        [
            (x, y),
            (x + w - f, y),
            (x + w - f, y + f),
            (x + w, y + f),
            (x + w, y + h),
            (x, y + h),
        ],
        fill=fill,
    )
    # The flap fills the lower half of the cut, pulled towards its own middle so
    # the gap appears on every side of it at once.
    corners = [(x + w - f, y), (x + w, y + f), (x + w - f, y + f)]
    cx = sum(p[0] for p in corners) / 3
    cy = sum(p[1] for p in corners) / 3
    k = 1 - DOC_GAP
    d.polygon([(cx + (px - cx) * k, cy + (py - cy) * k) for px, py in corners], fill=flap)


def drawing(background, scale=1.0, ink=CREAM, center=False):
    """The launcher mark: a device in outline and a page stepping out through a
    gap in its right wall. The page sits in the middle of the icon and the
    device to the left of it — the page is the subject, the device is where it
    is coming from."""
    s = SIZE * SS
    im = Image.new("RGBA", (s, s), background)
    d = ImageDraw.Draw(im)
    fw, fh = s * MARK_FRAME_W * scale, s * MARK_FRAME_H * scale
    sw, sh = s * MARK_SHEET_W * scale, s * MARK_SHEET_H * scale
    stroke = s * MARK_STROKE * scale

    sx, sy = (s - sw) / 2, (s - sh) / 2
    fx, fy = sx - fw * MARK_OVERLAP, (s - fh) / 2
    if center:
        # Under a round mask the empty right side is not visible, so the mark is
        # hung on its own middle instead of the page's.
        dx = (s - (sx + sw - fx)) / 2 - fx
        fx += dx
        sx += dx
    r = fw * 0.20
    d.rounded_rectangle([fx, fy, fx + fw, fy + fh], radius=r, fill=ink)
    d.rounded_rectangle(
        [fx + stroke, fy + stroke, fx + fw - stroke, fy + fh - stroke],
        radius=r - stroke / 2,
        fill=background,
    )
    # The camera, centred on the frame's own width and midway between the top
    # wall and the page. Drawn before the wall is cut open, like the page itself.
    cam_r = s * CAM_R * scale
    cam_cx = fx + fw / 2
    cam_cy = (fy + stroke + sy) / 2
    d.ellipse(
        [cam_cx - cam_r, cam_cy - cam_r, cam_cx + cam_r, cam_cy + cam_r],
        outline=ink,
        # Never thinner than a pixel of the supersampled canvas, whatever the
        # scale: a ring that rounds to zero simply would not be drawn.
        width=max(1, round(s * CAM_RING * scale)),
    )
    # The way out: without a gap in the wall the page only lies against it.
    d.rectangle(
        [fx + fw - stroke * 1.6, sy - stroke, fx + fw + stroke * 1.6, sy + sh + stroke],
        fill=background,
    )
    document(d, sx, sy, sw, sh, fill=ink, flap=ink)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    # A solid ground with one mark on it, the way a launcher icon carries: the
    # blue is the whole tile and the drawing is the only shape.
    square = drawing(BLUE).convert("RGB")
    # The master, the square the plain-icon launchers mask themselves, and the
    # window icon the Linux runner loads from the bundle: one mark everywhere.
    for name in ("icon.png", "icon_small.png", "icon2.png"):
        square.save(os.path.join(ASSETS, name))
    # The adaptive foreground: the drawing on nothing, already inset to the safe
    # circle, which is why pubspec.yaml adds no inset of its own.
    drawing((0, 0, 0, 0), SAFE, center=True).save(os.path.join(ASSETS, "icon_fg.png"))
    print(f"written to {ASSETS}")


if __name__ == "__main__":
    main()
