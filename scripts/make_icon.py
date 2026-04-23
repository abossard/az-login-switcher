#!/usr/bin/env python3
"""Generate Azure-themed app icon for az-login-switcher."""

import os
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "Pillow", "-q"])
    from PIL import Image, ImageDraw

AZURE_BLUE = (0, 120, 212, 255)
AZURE_LIGHT = (30, 150, 235, 255)
WHITE = (255, 255, 255, 255)
WHITE_SEMI = (255, 255, 255, 220)

def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size
    pad = int(s * 0.02)

    # Rounded square background
    r = int(s * 0.22)
    d.rounded_rectangle([pad, pad, s - pad, s - pad], radius=r, fill=AZURE_BLUE)

    # Subtle gradient: lighter top-left
    overlay = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.ellipse([int(-s * 0.2), int(-s * 0.4), int(s * 0.9), int(s * 0.5)],
               fill=(255, 255, 255, 25))
    img = Image.alpha_composite(img, overlay)
    d = ImageDraw.Draw(img)

    # Cloud — built from ellipses, proper proportions
    # Reference: classic cloud icon = flat bottom, 3 bumps on top
    cx = s * 0.5
    cy = s * 0.48

    # Flat base rectangle
    base_w = s * 0.56
    base_h = s * 0.12
    base_y = cy + s * 0.06
    d.rounded_rectangle(
        [int(cx - base_w/2), int(base_y),
         int(cx + base_w/2), int(base_y + base_h)],
        radius=int(base_h/2), fill=WHITE
    )

    # Left bump
    lr = int(s * 0.13)
    lx = int(cx - s * 0.15)
    ly = int(cy - s * 0.01)
    d.ellipse([lx - lr, ly - lr, lx + lr, ly + lr], fill=WHITE)

    # Center bump (biggest, tallest)
    cr = int(s * 0.18)
    ccx = int(cx + s * 0.02)
    ccy = int(cy - s * 0.08)
    d.ellipse([ccx - cr, ccy - cr, ccx + cr, ccy + cr], fill=WHITE)

    # Right bump
    rr = int(s * 0.11)
    rx = int(cx + s * 0.17)
    ry = int(cy + s * 0.02)
    d.ellipse([rx - rr, ry - rr, rx + rr, ry + rr], fill=WHITE)

    # Fill the gaps between bumps and base
    d.rectangle(
        [int(cx - base_w/2 + s*0.04), int(cy - s*0.02),
         int(cx + base_w/2 - s*0.04), int(base_y + base_h/2)],
        fill=WHITE
    )

    # Two small arrows below cloud (⇄ switch motif)
    arrow_y = int(s * 0.72)
    arrow_color = WHITE_SEMI
    gap = int(s * 0.03)

    # Left arrow ←
    ax = int(cx - gap)
    aw = int(s * 0.12)
    ah = int(s * 0.035)
    # shaft
    d.rectangle([ax - aw, arrow_y - ah//2, ax, arrow_y + ah//2], fill=arrow_color)
    # head
    d.polygon([(ax - aw, arrow_y - ah),
               (ax - aw - ah*2, arrow_y),
               (ax - aw, arrow_y + ah)], fill=arrow_color)

    # Right arrow →
    ax2 = int(cx + gap)
    d.rectangle([ax2, arrow_y - ah//2, ax2 + aw, arrow_y + ah//2], fill=arrow_color)
    d.polygon([(ax2 + aw, arrow_y - ah),
               (ax2 + aw + ah*2, arrow_y),
               (ax2 + aw, arrow_y + ah)], fill=arrow_color)

    return img


def build():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    iconset_dir = os.path.join(project_dir, "AppIcon.iconset")
    icns_path = os.path.join(project_dir, "Resources", "AppIcon.icns")

    os.makedirs(iconset_dir, exist_ok=True)
    os.makedirs(os.path.join(project_dir, "Resources"), exist_ok=True)

    base = draw_icon(1024)

    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]

    for pt, scale in specs:
        px = pt * scale
        resized = base.resize((px, px), Image.LANCZOS)
        suffix = "@2x" if scale == 2 else ""
        name = f"icon_{pt}x{pt}{suffix}.png"
        resized.save(os.path.join(iconset_dir, name))

    subprocess.check_call([
        "iconutil", "-c", "icns",
        iconset_dir, "-o", icns_path
    ])

    import shutil
    shutil.rmtree(iconset_dir)

    print(f"✅ App icon generated: {icns_path}")


if __name__ == "__main__":
    build()
