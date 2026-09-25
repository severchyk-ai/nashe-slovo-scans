# -*- coding: utf-8 -*-
"""Технічна перевірка щойно відсканованого номера + аркуш підвалів для звірки очима.

  python ns-acceptcheck.py <тека номера> [--out підвали.jpg] [--json звіт.json]
                           [--width 4693] [--height 6583] [--footer-mm 24]

Станція 1a конвеєра («Приймання»), викликається з ns-accept.ps1 після Q у ns-scan.
Для КОЖНОЇ сторінки з маніфесту:
  * скільки кадрів у TIF (має бути 1: «Automatic Multiple» колись різала аркуш на кілька);
  * розмір (профіль дає 4693 x 6583; інший — попередження, дуже інший — помилка);
  * порожній/чорний кадр: розкид яскравості (Sd) < 0,05, або середнє < 0,35 і Sd < 0,08
    (пороги ns-scan, виміряно 24.09.2026: порожнє скло 0,007-0,016, справжні сторінки >= 0,10);
  * та сама сторінка двічі: RMSE нормованих зменшених копій (60x84): < 0,05 — помилка, < 0,10 — попередження —
    порівнюється КОЖНА з КОЖНОЮ, а не лише сусідні (2331: замість 5-ї вдруге знято 3-тю).
Аркуш підвалів: нижні --footer-mm кожної сторінки, одна під одною, з підписом номера файлу;
оператор порівнює друковані номери з номерами файлів (OCR номерів відкинуто — читають очі).
Вивід — JSON: pages[{n,file,w,h,frames,mean,sd}], flags[{lvl,text}], sheet. Нічого не змінює,
крім файлу --out.
"""
import argparse
import io
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None
SHEET_W = 1080


def font(size):
    for f in ("arial.ttf", "segoeui.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except Exception:
            pass
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--out", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--width", type=int, default=4693)
    ap.add_argument("--height", type=int, default=6583)
    ap.add_argument("--footer-mm", type=float, default=24.0)
    a = ap.parse_args()

    with io.open(os.path.join(a.dir, "_manifest.json"), encoding="utf-8-sig") as fh:
        man = json.load(fh)
    pages = sorted(man.get("pages") or [], key=lambda p: int(p["n"]))
    flags, info, smalls, rows = [], [], [], []
    for p in pages:
        path = os.path.join(a.dir, p["file"])
        n = int(p["n"])
        if not os.path.exists(path):
            flags.append({"lvl": "err", "text": "стор. %d: файл %s відсутній" % (n, p["file"])})
            continue
        im = Image.open(path)
        frames = getattr(im, "n_frames", 1)
        w, h = im.size
        im.load()
        rgb = im.convert("RGB") if im.mode not in ("RGB", "L") else im
        f = max(1, min(w, h) // 300)
        red = rgb.reduce(f) if f > 1 else rgb
        g = np.asarray(red.convert("L"), dtype=np.float32) / 255.0
        mean, sd = float(g.mean()), float(g.std())
        # як у Update-NsLive (ns-lib): сірий 60x84 і -normalize (мін->0, макс->1). Без нормування різні
        # текстові сторінки дають різницю 0,05-0,10 і хибно виглядали б дублями (перевірено на 2369).
        small = np.asarray(red.convert("L").resize((60, 84), Image.BILINEAR), dtype=np.float32) / 255.0
        lo, hi = float(small.min()), float(small.max())
        small = (small - lo) / (hi - lo) if hi > lo else small * 0.0
        smalls.append((n, small))
        info.append({"n": n, "file": p["file"], "w": w, "h": h, "frames": frames, "mean": round(mean, 3), "sd": round(sd, 3)})
        if frames != 1:
            flags.append({"lvl": "err", "text": "стор. %d: у файлі %d кадрів (має бути 1) — аркуш розрізано обрізкою" % (n, frames)})
        dw, dh = abs(w - a.width) / a.width, abs(h - a.height) / a.height
        if dw > 0.02 or dh > 0.02:
            flags.append({"lvl": "err", "text": "стор. %d: розмір %dx%d, очікувалось %dx%d" % (n, w, h, a.width, a.height)})
        elif dw > 0.001 or dh > 0.001:
            flags.append({"lvl": "warn", "text": "стор. %d: розмір %dx%d, профіль дає %dx%d" % (n, w, h, a.width, a.height)})
        if sd < 0.05 or (mean < 0.35 and sd < 0.08):
            flags.append({"lvl": "err", "text": "стор. %d: порожній або чорний кадр (середнє %.2f, розкид %.3f)" % (n, mean, sd)})
        # підвал для аркуша
        fpx = int(a.footer_mm / 25.4 * 400 * (w / float(a.width)))
        fpx = max(10, min(fpx, h))
        strip = rgb.crop((0, h - fpx, w, h)).convert("RGB")
        rh = max(8, int(round(fpx * SHEET_W / float(w))))
        rows.append((n, strip.resize((SHEET_W, rh), Image.BILINEAR)))
        im.close()

    for i in range(len(smalls)):
        for j in range(i + 1, len(smalls)):
            rmse = float(np.sqrt(np.mean((smalls[i][1] - smalls[j][1]) ** 2)))
            if rmse < 0.05:
                flags.append({"lvl": "err", "text": "стор. %d і %d — та сама сторінка? (різниця %.3f; той самий аркуш дає 0,015-0,031, різні 0,28-0,40)" % (smalls[i][0], smalls[j][0], rmse)})
            elif rmse < 0.10:
                # календарні сторінки схожі за версткою (2318/5 і 6: 0,093) — це привід глянути, а не помилка
                flags.append({"lvl": "warn", "text": "стор. %d і %d схожі (різниця %.3f) — календар чи повтор? глянь підвали" % (smalls[i][0], smalls[j][0], rmse)})

    sheet = ""
    if a.out and rows:
        lab, gap = 26, 6
        total = sum(r[1].height + gap for r in rows) + gap
        sheet_img = Image.new("RGB", (SHEET_W, total), (60, 60, 60))
        y = gap
        fnt = font(20)
        for n, strip in rows:
            sheet_img.paste(strip, (0, y))
            d = ImageDraw.Draw(sheet_img)
            d.rectangle([0, y, 118, y + lab], fill=(200, 120, 0))
            d.text((6, y + 2), "файл p%02d" % n, fill=(255, 255, 255), font=fnt)
            y += strip.height + gap
        sheet_img.save(a.out, "JPEG", quality=88)
        sheet = a.out

    res = {"seq": man.get("seq_first"), "pages": info, "flags": flags, "sheet": sheet}
    txt = json.dumps(res, ensure_ascii=False)
    if a.json:
        with io.open(a.json, "w", encoding="utf-8") as fh:
            fh.write(txt)
    print(txt)


if __name__ == "__main__":
    main()
