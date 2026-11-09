# Replays recorded Painter calls with Pillow at SCALE x.
#   python replay2.py SCALE OUT.png IN.json            one image
#   python replay2.py SCALE OUT.gif IN1.json:ms ...    an animated GIF
import json, sys
from PIL import Image, ImageDraw, ImageFont

SCALE = float(sys.argv[1])
fonts = {}

def font(size, bold, family):
    mono = family.lower() in ("consolas", "cascadia mono", "courier new")
    px = max(1, round(size * 96 / 72 * SCALE))
    key = (px, bold, mono)
    if key not in fonts:
        name = ("consolab.ttf" if bold else "consola.ttf") if mono else ("segoeuib.ttf" if bold else "segoeui.ttf")
        fonts[key] = ImageFont.truetype("C:/Windows/Fonts/" + name, px)
    return fonts[key]

def rgba(rgb, a):
    return tuple(int(c) for c in rgb) + (int(round(255 * a)),)

def render(path):
    data = json.load(open(path, encoding="utf-8"))
    W, H = [int(v * SCALE) for v in data["size"]]
    img = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    s = SCALE
    for op in data["ops"]:
        kind, args = op[0], op[1:]
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        if kind == "fill_rect":
            x, y, w, h, rgb, *r = args
            if w > 0 and h > 0:
                d.rectangle([x * s, y * s, max(x * s, (x + w) * s - 1), max(y * s, (y + h) * s - 1)], fill=rgba(rgb, r[0] if r else 1.0))
        elif kind == "stroke_rect":
            x, y, w, h, rgb, *r = args
            t = r[0] if r else 1.0
            d.rectangle([x * s, y * s, (x + w) * s, (y + h) * s], outline=rgba(rgb, r[1] if len(r) > 1 else 1.0), width=max(1, round(t * s)))
        elif kind == "fill_circle":
            cx, cy, rad, rgb, *r = args
            d.ellipse([(cx - rad) * s, (cy - rad) * s, (cx + rad) * s, (cy + rad) * s], fill=rgba(rgb, r[0] if r else 1.0))
        elif kind == "stroke_circle":
            cx, cy, rad, rgb, *r = args
            t = r[0] if r else 1.0
            d.ellipse([(cx - rad) * s, (cy - rad) * s, (cx + rad) * s, (cy + rad) * s], outline=rgba(rgb, r[1] if len(r) > 1 else 1.0), width=max(1, round(t * s)))
        elif kind == "polyline":
            pts, rgb, *r = args
            t = r[0] if r else 1.0
            d.line([(px * s, py * s) for px, py in zip(pts[0::2], pts[1::2])], fill=rgba(rgb, r[1] if len(r) > 1 else 1.0), width=max(1, round(t * s)))
        elif kind == "text":
            x, y, width, text, rgb, size, bold, align, alpha, family = args
            f = font(size, bold, family)
            for i, line in enumerate(text.split("\n")):
                ly = (y * s) + i * f.size * 1.33
                lx = x * s
                if align == "center" and width and width > 0:
                    lx = x * s + (width * s - d.textlength(line, font=f)) / 2
                d.text((lx, ly), line, fill=rgba(rgb, alpha), font=f)
        img = Image.alpha_composite(img, layer)
    return img.convert("RGB")

out = sys.argv[2]
if out.endswith(".gif"):
    frames, durations = [], []
    for spec in sys.argv[3:]:
        path, ms = spec.rsplit(":", 1)
        frames.append(render(path))
        durations.append(int(ms))
    pal = [f.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE) for f in frames]
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=durations, loop=0, optimize=True, disposal=1)
else:
    render(sys.argv[3]).save(out, optimize=True)
print("wrote", out)
