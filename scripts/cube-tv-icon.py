#!/usr/bin/env python3
"""Draws the Cube TV icon (assets/app-icons/cube-tv.png): the app icon's Mac mini and wall, widened into a console
scene. A big TV shows a made-up Cube TV home screen (hero, a row of tiles, the start of the next row) and the Mac mini
sits at the bottom right. Needs Pillow; run it only when the artwork changes."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 2          # supersampling
W = 1024 * S


def px(value):
    return int(round(value * S))


def box(x, y, w, h):
    return [px(x), px(y), px(x + w), px(y + h)]


def gradient(size, top, bottom):
    image = Image.new("RGB", size, top)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        draw.line([(0, y), (size[0], y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return image


def draw_icon():
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    scene = Image.new("RGBA", (W, W), "#718c91")
    d = ImageDraw.Draw(scene)
    # Oak cabinet, like the app icon.
    d.rectangle(box(0, 823, 1024, 201), fill="#9c704e")
    d.rectangle(box(0, 823, 1024, 30), fill="#b88b62")
    # TV: dark bezel, screen with the Cube TV home screen.
    d.rounded_rectangle(box(70, 92, 884, 548), radius=px(40), fill="#242a2d")
    sx, sy, sw, sh = 90, 112, 844, 508
    screen = gradient((px(sw), px(sh)), (46, 34, 92), (10, 8, 24)).convert("RGBA")
    sd = ImageDraw.Draw(screen)

    def sbox(x, y, w, h):
        return [px(x), px(y), px(x + w), px(y + h)]

    # Hero: a glow, a big title and a smaller line.
    glow = Image.new("RGBA", screen.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(sbox(380, -120, 560, 420), fill=(160, 128, 255, 90))
    screen = Image.alpha_composite(screen, glow.filter(ImageFilter.GaussianBlur(px(60))))
    sd = ImageDraw.Draw(screen)
    sd.rounded_rectangle(sbox(40, 36, 300, 40), radius=px(20), fill=(255, 255, 255, 235))
    sd.rounded_rectangle(sbox(40, 92, 190, 20), radius=px(10), fill=(255, 255, 255, 120))
    # Shelf title, then the focused tile and its neighbours.
    sd.rounded_rectangle(sbox(40, 168, 110, 16), radius=px(8), fill=(255, 255, 255, 150))
    tiles = [("#c4302b", 40, 200, 214, 100, True), ("#2a475e", 270, 200, 190, 100, False),
             ("#7b5cff", 476, 200, 190, 100, False), ("#2e9f6b", 682, 200, 190, 100, False)]
    for color, x, y, w, h, focused in tiles:
        if focused:
            sd.rounded_rectangle(sbox(x - 8, y - 8, w + 16, h + 16), radius=px(22), fill=(255, 255, 255, 255))
        sd.rounded_rectangle(sbox(x, y, w, h), radius=px(16), fill=color)
        sd.rounded_rectangle(sbox(x + 14, y + h - 30, w * 0.5, 12), radius=px(6), fill=(255, 255, 255, 150))
    # The next shelf, cut off by the screen edge.
    sd.rounded_rectangle(sbox(40, 346, 130, 16), radius=px(8), fill=(255, 255, 255, 110))
    for i, color in enumerate(["#3d3f6b", "#57407a", "#2f5266", "#6b4a3d"]):
        sd.rounded_rectangle(sbox(40 + i * 206, 376, 190, 160), radius=px(16), fill=color)
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen.size[0], screen.size[1]], radius=px(26), fill=255)
    scene.paste(screen, (px(sx), px(sy)), mask)
    d = ImageDraw.Draw(scene)
    # The Mac mini, small, bottom right, with its shadow on the cabinet.
    d.rounded_rectangle(box(508, 822, 470, 40), radius=px(20), fill="#815b41")
    d.rounded_rectangle(box(560, 806, 366, 36), radius=px(18), fill="#303638")
    d.rounded_rectangle(box(536, 618, 414, 232), radius=px(40), fill="#bcc3c8")
    d.rounded_rectangle(box(536, 618, 414, 110), radius=px(40), fill="#e6e9eb")
    for x in (636, 706):
        d.rounded_rectangle(box(x, 784, 14, 31), radius=px(7), fill="#424b52")
    d.ellipse(box(868, 790, 18, 18), fill="#424b52")
    # Rounded tile like the app icon.
    tile = Image.new("L", (W, W), 0)
    ImageDraw.Draw(tile).rounded_rectangle(box(16, 16, 992, 992), radius=px(218), fill=255)
    canvas.paste(scene, (0, 0), tile)
    return canvas.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "assets/app-icons/cube-tv.png"
    icon = draw_icon()
    icon.resize((512, 512), Image.LANCZOS).save(out)
    print("Wrote", out)
