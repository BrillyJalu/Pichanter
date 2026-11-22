"""Membuat ikon Pichanter (PWA + sumber ikon APK).

Jalankan dari root proyek:  backend\\.venv\\Scripts\\python tools\\make_icons.py
Motif: siluet orang putih di latar ungu + kilau (Picture + Enchanter).
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "mobile" / "icons"
S = 1024
TOP, BOTTOM = (124, 92, 255), (67, 45, 196)


def gradient() -> Image.Image:
    g = Image.new("RGB", (1, S))
    for y in range(S):
        t = y / (S - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return g.resize((S, S))


def sparkle(d: ImageDraw.ImageDraw, cx, cy, r, w):
    d.polygon([(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w),
               (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)], fill="white")


def foreground(scale=1.0) -> Image.Image:
    """Siluet + kilau, digambar dalam zona aman ikon maskable (lingkaran r=40%)."""
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    c = S / 2

    def p(v):  # skala terhadap pusat
        return c + (v - c) * scale

    d.ellipse([p(377), p(300), p(647), p(570)], fill="white")                 # kepala
    body = Image.new("L", (S, S), 0)
    ImageDraw.Draw(body).ellipse([p(262), p(610), p(762), p(1060)], fill=255)  # bahu
    ImageDraw.Draw(body).rectangle([0, p(845), S, S], fill=0)                 # potong bawah
    fg.paste((255, 255, 255, 255), mask=body)
    sparkle(d, p(745), p(300), 92 * scale, 22 * scale)
    sparkle(d, p(820), p(430), 40 * scale, 10 * scale)
    return fg


def rounded(img: Image.Image, radius: int) -> Image.Image:
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m)
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    base = gradient().convert("RGBA")

    maskable = base.copy()
    maskable.alpha_composite(foreground(0.92))
    maskable.convert("RGB").save(OUT / "icon-1024-maskable.png")
    for n in (192, 512):
        maskable.resize((n, n), Image.LANCZOS).convert("RGB").save(OUT / f"maskable-{n}.png")

    anyicon = base.copy()
    anyicon.alpha_composite(foreground(1.08))
    anyicon = rounded(anyicon, 230)
    anyicon.save(OUT / "icon-1024.png")
    for n in (192, 512):
        anyicon.resize((n, n), Image.LANCZOS).save(OUT / f"icon-{n}.png")
    anyicon.resize((180, 180), Image.LANCZOS).save(OUT / "apple-touch-icon.png")
    anyicon.resize((64, 64), Image.LANCZOS).save(OUT / "favicon-64.png")

    # Foreground transparan untuk ikon adaptif Android (tahap APK).
    fg = foreground(0.75)
    fg.save(OUT / "icon-foreground-1024.png")
    print("Ikon dibuat di", OUT)


if __name__ == "__main__":
    main()
