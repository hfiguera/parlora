#!/usr/bin/env python3
"""Export the authored sharing artwork. Optional tooling, never a site build dependency.

Requires Pillow, fonttools and brotli; see website/README.md.
Uses the publication's existing, OFL licensed Fraunces and DM Sans fonts.
"""

from io import BytesIO
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/social"
SCALE = 2
PAPER, INK, ACCENT, RULE = "#f6f1e8", "#183e36", "#b84226", "#d7cdbf"


def font(name, size, weight=400):
    face = TTFont(ROOT / f"assets/fonts/{name}-latin.woff2")
    axes = {a.axisTag: a.defaultValue for a in face["fvar"].axes}
    axes["wght"] = weight
    if "opsz" in axes:
        axes["opsz"] = 72 if name == "fraunces" else 14
    face = instantiateVariableFont(face, axes, inplace=True)
    face.flavor = None
    stream = BytesIO()
    face.save(stream)
    stream.seek(0)
    return ImageFont.truetype(stream, size * SCALE)


def render(name, lines, subtitle, footer):
    image = Image.new("RGB", (1200 * SCALE, 630 * SCALE), PAPER)
    draw = ImageDraw.Draw(image)

    def line(points, fill, width=1):
        draw.line([(x * SCALE, y * SCALE) for x, y in points], fill=fill, width=width * SCALE)

    def text(x, y, value, face, fill=INK):
        draw.text((x * SCALE, y * SCALE), value, font=face, fill=fill, anchor="lt")

    # The same five-stroke voice mark as the publication masthead.
    for x, half in ((0, 7), (11, 16), (22, 23), (33, 12), (44, 7)):
        line([(72 + x, 94 - half), (72 + x, 94 + half)], INK, 4)
    text(137, 72, "Parlora", font("dmsans", 35, 500))
    line([(72, 145), (1128, 145)], RULE)

    title = font("fraunces", 92)
    for i, value in enumerate(lines):
        if draw.textlength(value, font=title) > 1056 * SCALE:
            raise ValueError(f"Sharing title does not fit: {value}")
        text(68, 193 + i * 110, value, title)
    text(72, 435, subtitle, font("dmsans", 32))
    line([(72, 529), (1128, 529)], RULE)
    text(72, 558, "hfiguera.github.io/parlora", font("dmsans", 23))
    label = font("dmsans", 23, 500)
    label_width = draw.textlength(footer, font=label) / SCALE
    text(1128 - label_width, 558, footer, label, ACCENT)

    # Provenance travels with each PNG; all artwork is code, with no stock or AI image.
    info = PngImagePlugin.PngInfo()
    info.add_text("Origin", "Authored by the Parlora project. Source: website/social/render.py. "
                  "Palette and voice mark: website/assets/site.css and website/templates/layout.html. "
                  "Fraunces and DM Sans: website/assets/fonts/, SIL Open Font License. "
                  "Rendered with Pillow and fonttools; no generated or stock imagery.")
    info.add_text("impeccable:prompt", "Programmatic export of Parlora's conversation journal identity: "
                  "warm ivory, forest green and terracotta; Fraunces and DM Sans; the five-stroke voice mark. "
                  f"Title: {' '.join(lines)} Subtitle: {subtitle} Footer: {footer}. "
                  "Source: website/social/render.py; fonts licensed under SIL OFL.")
    OUT.mkdir(parents=True, exist_ok=True)
    image.resize((1200, 630), Image.Resampling.LANCZOS).save(OUT / name, pnginfo=info, optimize=True)


if __name__ == "__main__":
    render("parlora.png", ["Voice AI agents,", "built with Elixir."],
           "The conversation. The work in between.", "Parlora")
    render("introducing-parlora.png", ["Introducing", "Parlora."],
           "Build voice AI agents with Elixir.", "Parlora 0.1.0")
