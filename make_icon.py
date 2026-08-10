#!/usr/bin/env python3
"""Generate the widget icon: a Jellyfin-style bell with a play mark inside.

Ours, not Jellyfin's asset — same visual language (the bell + tentacles silhouette
and the purple->blue gradient) with a play triangle to say "something is playing".

Drawn at 8x and downsampled, which is how the edges get antialiased without
depending on any SVG rasteriser being installed.
"""
from PIL import Image, ImageDraw

OUT, S, SS = "nowplaying.png", 256, 8      # final size, supersample factor
W = S * SS

# Jellyfin's gradient endpoints
TOP    = (0xAA, 0x5C, 0xC3)   # purple
BOTTOM = (0x00, 0xA4, 0xDC)   # blue

img  = Image.new("RGBA", (W, W), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# ---- silhouette: a bell (dome) plus three tentacles ----
mask = Image.new("L", (W, W), 0)
m = ImageDraw.Draw(mask)

pad      = int(W * 0.06)   # tighter: fill more of the canvas at small sizes
bell_w   = W - pad * 2
bell_top = pad
bell_h   = int(W * 0.56)
# dome: an ellipse whose bottom half is squared off by a rectangle
m.ellipse([pad, bell_top, pad + bell_w, bell_top + bell_h], fill=255)
m.rectangle([pad, bell_top + bell_h // 2, pad + bell_w, bell_top + bell_h], fill=255)

# scalloped underside so it reads as a jellyfish rather than a capsule
scallop_r = bell_w // 6
y_scallop = bell_top + bell_h
for i in range(3):
    cx = pad + scallop_r + i * (bell_w - 2 * scallop_r) // 2
    m.ellipse([cx - scallop_r, y_scallop - scallop_r,
               cx + scallop_r, y_scallop + scallop_r], fill=0)

# three thick tentacles — thick so they survive a 20px bar
t_w   = int(W * 0.105)     # thicker: thin tentacles vanish under 20px
t_top = y_scallop - scallop_r // 2
t_bot = int(W * 0.90)
for i, frac in enumerate((0.30, 0.50, 0.70)):
    cx = int(W * frac)
    length = t_bot if i == 1 else int(t_bot - W * 0.07)   # centre one longest
    m.rounded_rectangle([cx - t_w // 2, t_top, cx + t_w // 2, length],
                        radius=t_w // 2, fill=255)

# ---- vertical gradient, clipped to the silhouette ----
grad = Image.new("RGBA", (W, W))
g = ImageDraw.Draw(grad)
for y in range(W):
    t = y / (W - 1)
    g.line([(0, y), (W, y)],
           fill=(round(TOP[0] + (BOTTOM[0] - TOP[0]) * t),
                 round(TOP[1] + (BOTTOM[1] - TOP[1]) * t),
                 round(TOP[2] + (BOTTOM[2] - TOP[2]) * t), 255))
img = Image.composite(grad, img, mask)

# ---- play triangle inside the bell ----
d = ImageDraw.Draw(img)
cx, cy = W // 2, bell_top + int(bell_h * 0.46)
r = int(W * 0.195)         # owner asked for a bigger triangle; also the one element
                           # that must survive a 16px bar, so err large
d.polygon([(cx - r * 0.80, cy - r), (cx - r * 0.80, cy + r), (cx + r * 0.80, cy)],
          fill=(255, 255, 255, 255))

img.resize((S, S), Image.LANCZOS).save(OUT)
print(f"wrote {OUT} ({S}x{S})")
