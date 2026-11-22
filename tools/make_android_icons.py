"""Membuat ikon launcher + splash Android untuk APK (android-app/native/res).

Jalankan dari root proyek SETELAH tools/make_icons.py:
    backend\\.venv\\Scripts\\python tools\\make_android_icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "mobile" / "icons"
RES = ROOT / "android-app" / "native" / "res"
TOP, BOTTOM = (124, 92, 255), (67, 45, 196)
DENSITY = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
# Ukuran splash bawaan template Capacitor (port = tegak, land = mendatar)
SPLASH = {"mdpi": (320, 480), "hdpi": (480, 800), "xhdpi": (720, 1280), "xxhdpi": (960, 1600), "xxxhdpi": (1280, 1920)}


def gradient(w, h):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return g.resize((w, h), Image.BILINEAR)


def circle_mask(n):
    big = Image.new("L", (n * 4, n * 4), 0)
    ImageDraw.Draw(big).ellipse([0, 0, n * 4 - 1, n * 4 - 1], fill=255)
    return big.resize((n, n), Image.LANCZOS)


def save(img, rel):
    p = RES / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    img.save(p, optimize=True)


def main():
    fg = Image.open(ICONS / "icon-foreground-1024.png").convert("RGBA")   # siluet di zona aman
    full = Image.open(ICONS / "icon-1024-maskable.png").convert("RGBA")   # latar + siluet, full-bleed

    for name, s in DENSITY.items():
        n108, n48 = round(108 * s), round(48 * s)
        save(fg.resize((n108, n108), Image.LANCZOS), f"mipmap-{name}/ic_launcher_foreground.png")
        save(gradient(n108, n108), f"mipmap-{name}/ic_launcher_background.png")
        legacy = full.resize((n48, n48), Image.LANCZOS)
        rounded = Image.new("L", (n48 * 4, n48 * 4), 0)
        ImageDraw.Draw(rounded).rounded_rectangle([0, 0, n48 * 4 - 1, n48 * 4 - 1], radius=n48, fill=255)
        sq = legacy.copy()
        sq.putalpha(rounded.resize((n48, n48), Image.LANCZOS))
        save(sq, f"mipmap-{name}/ic_launcher.png")
        rd = legacy.copy()
        rd.putalpha(circle_mask(n48))
        save(rd, f"mipmap-{name}/ic_launcher_round.png")

    # Splash (Android < 12 dan latar transisi): gradasi + siluet di tengah.
    for name, (w, h) in SPLASH.items():
        for orient, (sw, sh) in (("port", (w, h)), ("land", (h, w))):
            img = gradient(sw, sh).convert("RGBA")
            side = round(min(sw, sh) * 0.55)
            logo = fg.resize((side, side), Image.LANCZOS)
            img.alpha_composite(logo, ((sw - side) // 2, (sh - side) // 2))
            save(img.convert("RGB"), f"drawable-{orient}-{name}/splash.png")
    base = gradient(480, 320).convert("RGBA")
    base.alpha_composite(fg.resize((200, 200), Image.LANCZOS), (140, 60))
    save(base.convert("RGB"), "drawable/splash.png")
    print("Ikon & splash Android dibuat di", RES)


if __name__ == "__main__":
    main()
