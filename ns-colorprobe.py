# -*- coding: utf-8 -*-
"""Відтінок паперу по сторінці на трьох кроках: майстер -> prep -> render. Нічого не змінює.

  python ns-colorprobe.py <номер> <стор.> [--grid 4x6] [--box 0.05,0.70,0.40,0.95 ...]

Навіщо (оператор, 29.09.2026): у PDF видно рожеві, зеленкуваті, синюваті,
жовтуваті відтінки газетного білого (2277/1 небо на фото, 2287/2 ліво жовто-
зелене / право синювате, 2287/8 угорі жовтувате). Питання — на якому кроці
відтінок з'являється: у майстрі (папір, лампа сканера, кольоровий муар растру)
чи в обробці (баланс по каналах, JPEG).

Сітка: поле паперу ділиться на клітини; у кожній — пікселі ПАПЕРУ (верхня
чверть яскравості клітини й не темніші за 80 % паперу сторінки), їх середній
колір -> CIELAB (sRGB, D65): a* (+ рожевий / - зелений), b* (+ жовтий / - синій)
і B-R. Друкується сама карта і ВІДХИЛЕННЯ від медіани сторінки (візерунок):
баланс номера — множення каналів, тож візерунок майстра він лише зсуває й трохи
підсилює, а новий візерунок на render означав би вину обробки.
--box (частки паперу x0,y0,x1,y1) — ділянка вмісту (фото): середній a*/b* усіх
пікселів і «кольоровий муар» — розкид a*, b* після усереднення вікном 1 мм.
Середнє по площі JPEG-субдискретизація не змінює; муар — видно на всіх кроках.
Кроки міряються на зменшеній копії (1 пікс. ~ 0,25 мм), муар — на повній.
"""
import argparse
import glob
import os
import sys

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None


def to_lab(rgb):
    """sRGB 0-255 (N,3) -> CIELAB D65."""
    c = rgb.astype(np.float64) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ M.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    L = 116 * f[:, 1] - 16
    a = 500 * (f[:, 0] - f[:, 1])
    b = 200 * (f[:, 1] - f[:, 2])
    return np.stack([L, a, b], axis=1)


def paper_box(g, stage):
    """Межі паперу: для майстра — поза чорною кришкою (< 110), для render — поза білою рамкою (>= 254)."""
    h, w = g.shape
    bad = (g < 110) if stage == "майстер" else (g >= 254) if stage == "render" else (g < 60) | (g >= 254)
    cols = bad[int(h * 0.12):int(h * 0.88)].mean(axis=0)
    rows = bad[:, int(w * 0.12):int(w * 0.88)].mean(axis=1)

    def first(v):
        i = 0
        while i < v.size and v[i] >= 0.9:
            i += 1
        return i
    return first(cols), w - first(cols[::-1]), first(rows), h - first(rows[::-1])


def load(path, dpi, target_mm=0.25):
    im = Image.open(path).convert("RGB")
    f = max(1, int(round(dpi * target_mm / 25.4)))
    small = np.asarray(im.reduce(f)) if f > 1 else np.asarray(im)
    return im, small, dpi / f


def grid_stats(small, stage, gx, gy):
    g = small.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    x0, x1, y0, y1 = paper_box(g, stage)
    # 2 % від краю паперу не беремо (тінь, скло)
    mx, my = int((x1 - x0) * 0.02), int((y1 - y0) * 0.02)
    x0, x1, y0, y1 = x0 + mx, x1 - mx, y0 + my, y1 - my
    pg = np.percentile(g[y0:y1, x0:x1], 90)
    res = np.full((gy, gx, 4), np.nan)
    xs = np.linspace(x0, x1, gx + 1).astype(int)
    ys = np.linspace(y0, y1, gy + 1).astype(int)
    for j in range(gy):
        for i in range(gx):
            cg = g[ys[j]:ys[j + 1], xs[i]:xs[i + 1]]
            cc = small[ys[j]:ys[j + 1], xs[i]:xs[i + 1]]
            sel = (cg >= np.percentile(cg, 75)) & (cg >= 0.8 * pg)
            if sel.sum() < 200:
                continue
            m = cc[sel].reshape(-1, 3).mean(axis=0)
            lab = to_lab(m[None, :])[0]
            res[j, i] = (lab[1], lab[2], m[2] - m[0], lab[0])
    return res, (x0, x1, y0, y1)


def box_stats(im, dpi, stage, box):
    full = np.asarray(im)
    g = full.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    x0, x1, y0, y1 = paper_box(g, stage)
    bx0, by0, bx1, by1 = box
    X0, X1 = int(x0 + bx0 * (x1 - x0)), int(x0 + bx1 * (x1 - x0))
    Y0, Y1 = int(y0 + by0 * (y1 - y0)), int(y0 + by1 * (y1 - y0))
    reg = full[Y0:Y1, X0:X1]
    lab = to_lab(reg.reshape(-1, 3)).reshape(reg.shape).astype(np.float32)
    k = max(1, int(round(dpi / 25.4)))
    a1 = cv2.blur(lab[..., 1], (k, k))[::k, ::k]
    b1 = cv2.blur(lab[..., 2], (k, k))[::k, ::k]
    return {"L": float(lab[..., 0].mean()), "a": float(lab[..., 1].mean()), "b": float(lab[..., 2].mean()),
            "moire_a": float(a1.std()), "moire_b": float(b1.std()),
            "a_p5_p95": (float(np.percentile(a1, 5)), float(np.percentile(a1, 95))),
            "b_p5_p95": (float(np.percentile(b1, 5)), float(np.percentile(b1, 95)))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seq")
    ap.add_argument("page", type=int)
    ap.add_argument("--grid", default="4x6")
    ap.add_argument("--box", action="append", default=[])
    ap.add_argument("--quiet-grid", action="store_true")
    ap.add_argument("--jpegtest", action="store_true", help="prep з балансом render -> PNG і JPEG: що додає JPEG")
    ap.add_argument("--quality", type=int, default=55)
    ap.add_argument("--render-dir", default="", help="render з іншої теки (клон із варіантом JPEG); майстер і prep — з номера")
    ap.add_argument("--only-render", action="store_true", help="міряти лише render (швидко)")
    a = ap.parse_args()
    gx, gy = [int(v) for v in a.grid.split("x")]
    m = glob.glob(r"C:\NS_MASTERS\*\%s_*\%s_*_p%02d.tif" % (a.seq, a.seq, a.page))
    stages = [("майстер", m[0] if m else None, 400),
              ("prep", r"C:\NS_WORK\%s\prep\p%02d.tif" % (a.seq, a.page), 400),
              ("render", os.path.join(a.render_dir, "p%02d.jpg" % a.page) if a.render_dir
               else r"C:\NS_WORK\%s\render\p%02d.jpg" % (a.seq, a.page), 300)]
    if a.only_render:
        stages = stages[2:]
    print("%s стор. %d" % (a.seq, a.page))
    maps = {}
    for name, path, dpi in stages:
        if not path or not os.path.exists(path):
            print("  %s: немає файлу" % name)
            continue
        im, small, sdpi = load(path, dpi)
        res, box = grid_stats(small, name, gx, gy)
        maps[name] = res
        med = np.nanmedian(res.reshape(-1, 4), axis=0)
        print("  %-8s розмах візерунка a* %.2f, b* %.2f (клітин %d)" % (
            name, np.nanmax(res[..., 0]) - np.nanmin(res[..., 0]), np.nanmax(res[..., 1]) - np.nanmin(res[..., 1]),
            int((~np.isnan(res[..., 0])).sum())))
        if not a.quiet_grid:
            print("  %-8s папір: L %.1f  a* %+.2f  b* %+.2f  B-R %+.1f  (медіана клітин)" % (name, med[3], med[0], med[1], med[2]))
            for lbl, k in (("a*", 0), ("b*", 1)):
                print("    %s відхилення від медіани, рядки згори вниз:" % lbl)
                for j in range(gy):
                    print("      " + " ".join("%+5.2f" % (res[j, i, k] - med[k]) if not np.isnan(res[j, i, k]) else "   . " for i in range(gx)))
        for bs in a.box:
            b = [float(v) for v in bs.split(",")]
            st = box_stats(im, dpi, name, b)
            print("  %-8s ділянка %s: L %.1f a* %+.2f b* %+.2f; муар (1 мм) a* %.2f [%+.1f..%+.1f], b* %.2f [%+.1f..%+.1f]"
                  % (name, bs, st["L"], st["a"], st["b"], st["moire_a"], *st["a_p5_p95"], st["moire_b"], *st["b_p5_p95"]))
    if a.jpegtest and "prep" in maps and "render" in maps:
        # prep x підсилення каналів (папір prep -> папір render, як баланс номера) -> 300 dpi ->
        # PNG без втрат і JPEG q55 тим самим magick: що додає саме JPEG
        import subprocess
        import tempfile
        tmp = tempfile.mkdtemp(prefix="ns_colorprobe_")
        try:
            im = np.asarray(Image.open(stages[1][1]).convert("RGB")).astype(np.float32)
            rp = np.asarray(Image.open(stages[2][1]).convert("RGB")).astype(np.float32)

            def paper_rgb(x):
                g = x @ np.array([0.299, 0.587, 0.114], np.float32)
                h, w = g.shape
                c = g[h // 4:3 * h // 4, w // 4:3 * w // 4]
                sel = c >= np.percentile(c, 90)
                return x[h // 4:3 * h // 4, w // 4:3 * w // 4][sel].mean(axis=0)
            gain = paper_rgb(rp) / paper_rgb(im)
            bal = np.clip(im * gain, 0, 255).astype(np.uint8)
            src = os.path.join(tmp, "bal.png")
            Image.fromarray(bal).save(src, dpi=(400, 400))
            png, jpg = os.path.join(tmp, "r.png"), os.path.join(tmp, "r.jpg")
            subprocess.run(["magick", src, "-units", "PixelsPerInch", "-density", "400", "-resample", "300", png], check=True)
            subprocess.run(["magick", png, "-units", "PixelsPerInch", "-density", "300x300", "-quality", str(a.quality), jpg], check=True)
            print("  jpegtest: підсилення каналів R %.3f G %.3f B %.3f" % tuple(gain))
            variants = [("PNG", png), ("JPEG q%d" % a.quality, jpg)]
            # проби: без субдискретизації кольору (4:4:4) і вища якість — розмір файлу поруч
            for q, sf in ((a.quality, "1x1"), (70, "2x2"), (70, "1x1")):
                v = os.path.join(tmp, "v_q%d_%s.jpg" % (q, sf))
                subprocess.run(["magick", png, "-units", "PixelsPerInch", "-density", "300x300", "-quality", str(q),
                                "-sampling-factor", sf, v], check=True)
                variants.append(("q%d %s" % (q, "4:4:4" if sf == "1x1" else "4:2:0"), v))
            print("  розмір: JPEG q%d %.2f МБ" % (a.quality, os.path.getsize(jpg) / 2**20)
                  + "".join(", %s %.2f МБ" % (n, os.path.getsize(pth) / 2**20) for n, pth in variants[2:]))
            for name, path in variants:
                _, small, _ = load(path, 300)
                res, _ = grid_stats(small, "prep", gx, gy)
                maps[name] = res
                med = np.nanmedian(res.reshape(-1, 4), axis=0)
                print("  %-9s папір a* %+.2f b* %+.2f; розмах візерунка a* %.2f, b* %.2f"
                      % (name, med[0], med[1], np.nanmax(res[..., 0]) - np.nanmin(res[..., 0]), np.nanmax(res[..., 1]) - np.nanmin(res[..., 1])))
        finally:
            for f in ["bal.png", "r.png", "r.jpg"] + ["v_q%d_%s.jpg" % (q, sf) for q, sf in ((a.quality, "1x1"), (70, "2x2"), (70, "1x1"))]:
                try:
                    os.remove(os.path.join(tmp, f))
                except OSError:
                    pass
            os.rmdir(tmp)
    # подібність візерунка між кроками
    names = [n for n in ("майстер", "prep", "PNG", "JPEG q%d" % a.quality, "render") if n in maps]
    for k, lbl in ((0, "a*"), (1, "b*")):
        for i in range(len(names) - 1):
            A = maps[names[i]][..., k].ravel()
            B = maps[names[i + 1]][..., k].ravel()
            ok = ~np.isnan(A) & ~np.isnan(B)
            if ok.sum() > 3:
                A2, B2 = A[ok] - np.median(A[ok]), B[ok] - np.median(B[ok])
                r = np.corrcoef(A2, B2)[0, 1]
                sc = np.polyfit(A2, B2, 1)[0]
                print("  візерунок %s: %s -> %s  кореляція %.2f, нахил %.2f, розмах %.2f -> %.2f"
                      % (lbl, names[i], names[i + 1], r, sc, np.ptp(A2), np.ptp(B2)))


if __name__ == "__main__":
    main()
