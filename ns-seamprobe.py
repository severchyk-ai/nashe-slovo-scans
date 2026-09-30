# -*- coding: utf-8 -*-
"""Мірило шва «справжній папір | доданий папір» — колір і РОЗМІР зерна, з контролем.

  python ns-seamprobe.py <render.jpg> <маска_synth.png> [--dpi 300] [--json out.json]

Маска — 255 там, де папір ДОДАНО (ns-render -PaperPad -PadMaskDir <тека>), 0 — справжнє
й рамка. Міряється на готовому JPEG — тобто так, як бачить оператор.

Навіщо (30.09.2026): оператор побачив шов на 2316/10 — «піксель дрібніший і
одноманітніший», тон/колір інший, — а міра ns-paperpad його не бачила. Вона порівнювала
лише яскравість (dL) і ВІДНОШЕННЯ РОЗКИДУ (x0,87-1,10), а розкид однаковий для дрібного й
крупного зерна: шум σ 0,6 пікс. і волокна паперу 0,2-1 мм дають той самий розкид.

Для кожного боку сторінки (L R T B — найближчий бік) три смуги:
  A — доданий папір, 0,3-2 мм від справжнього (колір) / плитки цілком у доданому (зерно);
      «далі» — доданий 2-6 мм від справжнього проти B (тон поля, продовжений углиб);
  B — справжній папір, 0,3-2 мм від доданого / плитки справжнього в 6 мм від шва;
  C — КОНТРОЛЬ: справжній папір 2,3-4 мм (колір) / 6-12 мм (зерно) від шва.
Шов = A проти B; контроль = C проти B тією самою мірою. Шов, якого не видно, має
давати числа в межах контролю.
  колір: CIELAB, середнє в кожному з 20 відрізків уздовж боку; dL*, da*, db*, dE —
         медіана і найбільше за відрізками;
  зерно: плитки 24 x 24 пікс. (2 мм при 300 dpi) лише чистого паперу (розкид після
         розмиття 0,5 мм < 4, як у ns-paperpad); L* мінус площина, вікно Ганна, FFT;
         потужність у смугах періоду 0,17-0,25 / 0,25-0,42 / 0,42-0,85 / 0,85-2 мм;
         log2(A/B) по смугах (0 — те саме зерно; > 0 — у доданому більше; дрібне
         зерно шуму дає + у першій смузі й − у крупних).
Нічого не змінює.
"""
import argparse
import json
import sys

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None
NSEG = 20
TILE = 24
BANDS_MM = [(0.17, 0.25), (0.25, 0.42), (0.42, 0.85), (0.85, 2.0)]


def nearest_side(H, W):
    yy, xx = np.mgrid[0:H, 0:W]
    return np.argmin(np.stack([xx, W - 1 - xx, yy, H - 1 - yy]), axis=0)   # 0 L, 1 R, 2 T, 3 B


def lab_of(rgb):
    return cv2.cvtColor(rgb.astype(np.float32) / 255.0, cv2.COLOR_RGB2LAB)


def seg_color(lab, ma, mb, side, H, W):
    n = H if side in "LR" else W
    rows = []
    for seg in np.array_split(np.arange(n), NSEG):
        sl = (slice(seg[0], seg[-1] + 1), slice(None)) if side in "LR" else (slice(None), slice(seg[0], seg[-1] + 1))
        a, b = ma[sl], mb[sl]
        if a.sum() > 150 and b.sum() > 150:
            la, lb = lab[sl][a].mean(axis=0), lab[sl][b].mean(axis=0)
            rows.append(la - lb)
    if not rows:
        return None
    d = np.array(rows)
    de = np.sqrt((d ** 2).sum(axis=1))
    out = {"segs": len(rows)}
    for k, nm in enumerate(("dL", "da", "db")):
        out[nm] = [round(float(np.median(d[:, k])), 2), round(float(d[np.argmax(np.abs(d[:, k])), k]), 2)]
    out["dE"] = [round(float(np.median(de)), 2), round(float(de.max()), 2)]
    return out


def band_power(tiles, dpi):
    """Середня потужність у смугах періоду для набору плиток L* (N x T x T)."""
    if len(tiles) == 0:
        return None
    T = TILE
    yy, xx = np.mgrid[0:T, 0:T].astype(np.float32)
    A = np.stack([np.ones(T * T), xx.ravel(), yy.ravel()], 1)
    win = np.outer(np.hanning(T), np.hanning(T)).astype(np.float32)
    f = np.fft.fftfreq(T)
    fr = np.sqrt(f[None, :] ** 2 + f[:, None] ** 2)   # цикли/пікс.
    per_mm = np.where(fr > 0, 1.0 / np.maximum(fr, 1e-9) / (dpi / 25.4), np.inf)
    acc = np.zeros(len(BANDS_MM))
    for t in tiles:
        coef, *_ = np.linalg.lstsq(A, t.ravel(), rcond=None)
        r = (t.ravel() - A @ coef).reshape(T, T) * win
        P = np.abs(np.fft.fft2(r)) ** 2
        for k, (lo, hi) in enumerate(BANDS_MM):
            m = (per_mm >= lo) & (per_mm < hi)
            acc[k] += P[m].mean()
    return acc / len(tiles)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("mask")
    ap.add_argument("--dpi", type=float, default=300.0)
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    rgb = np.array(Image.open(a.image).convert("RGB"))
    synth = np.array(Image.open(a.mask).convert("L")) > 127
    if synth.shape != rgb.shape[:2]:
        sys.exit("розмір маски %s не збігається із зображенням %s" % (synth.shape, rgb.shape[:2]))
    H, W = synth.shape
    mm = a.dpi / 25.4
    lab = lab_of(rgb)
    L = lab[..., 0]
    # рамка (біле >= 254 уздовж краю, не додане) — не папір
    white = np.all(rgb >= 254, axis=-1)
    nl, labc = cv2.connectedComponents(white.astype(np.uint8), 8)
    ids = set(np.unique(np.concatenate([labc[0], labc[-1], labc[:, 0], labc[:, -1]]))) - {0}
    frame = np.isin(labc, list(ids)) & ~synth
    real = ~synth & ~frame
    # чистий папір: гладке тло (як у ns-paperpad) і світле
    Lb = cv2.GaussianBlur(L * 2.55, (0, 0), 0.5 * mm)
    kk = int(1.5 * mm) | 1
    sdb = np.sqrt(np.maximum(0, cv2.blur(Lb * Lb, (kk, kk)) - cv2.blur(Lb, (kk, kk)) ** 2))
    paper = (sdb < 4) & (L > 70)
    d_to_real = cv2.distanceTransform((~real).astype(np.uint8), cv2.DIST_L2, 3)   # для пікселів доданого
    d_to_syn = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 3)   # для справжніх
    near = nearest_side(H, W)
    cA = synth & (d_to_real >= 0.3 * mm) & (d_to_real <= 2 * mm) & paper
    cB = real & paper & (d_to_syn >= 0.3 * mm) & (d_to_syn <= 2 * mm)
    cC = real & paper & (d_to_syn >= 2.3 * mm) & (d_to_syn <= 4 * mm)
    cF = synth & (d_to_real > 2 * mm) & (d_to_real <= 6 * mm) & paper     # далі в доданому: тон поля екстраполюється
    res = {"image": a.image, "sides": {}}
    # плитки (крок 8 пікс.)
    step = 8
    ys = np.arange(0, H - TILE, step)
    xs = np.arange(0, W - TILE, step)
    ii = cv2.integral(synth.astype(np.uint8))
    ip = cv2.integral((real & paper).astype(np.uint8))
    ipp = cv2.integral((synth & paper).astype(np.uint8))

    def box(I, y, x):
        return I[y + TILE, x + TILE] - I[y, x + TILE] - I[y + TILE, x] + I[y, x]
    full = TILE * TILE
    tiles = {s: {"A": [], "B": [], "C": []} for s in "LRTB"}
    for y in ys:
        for x in xs:
            cy, cx = y + TILE // 2, x + TILE // 2
            s = "LRTB"[near[cy, cx]]
            nsyn = box(ii, y, x)
            if nsyn == full and box(ipp, y, x) >= 0.95 * full:
                tiles[s]["A"].append((y, x))
            elif nsyn == 0 and box(ip, y, x) >= 0.95 * full:
                d = d_to_syn[cy, cx] / mm
                if d <= 6:
                    tiles[s]["B"].append((y, x))
                elif d <= 12:
                    tiles[s]["C"].append((y, x))
    for k, s in enumerate("LRTB"):
        side = near == k
        if (synth & side).sum() < 2000:
            continue
        r = {"synth_mm2": round(float((synth & side).sum()) / mm / mm)}
        r["color_seam"] = seg_color(lab, cA & side, cB & side, s, H, W)
        r["color_ctrl"] = seg_color(lab, cC & side, cB & side, s, H, W)
        r["color_far"] = seg_color(lab, cF & side, cB & side, s, H, W)
        pw = {}
        for g in "ABC":
            pw[g] = band_power(np.array([L[y:y + TILE, x:x + TILE] for y, x in tiles[s][g]], np.float32), a.dpi)
        r["tiles"] = {g: len(tiles[s][g]) for g in "ABC"}
        if pw["A"] is not None and pw["B"] is not None:
            r["grain_seam_log2"] = [round(float(np.log2(pw["A"][i] / pw["B"][i])), 2) for i in range(len(BANDS_MM))]
        if pw["C"] is not None and pw["B"] is not None:
            r["grain_ctrl_log2"] = [round(float(np.log2(pw["C"][i] / pw["B"][i])), 2) for i in range(len(BANDS_MM))]
        res["sides"][s] = r
    bands = " / ".join("%.2g-%.2g" % b for b in BANDS_MM)
    print("%s  (зерно: log2 потужності A/B у смугах %s мм; колір: медіана/найбільше за відрізками)" % (a.image, bands))
    for s, r in res["sides"].items():
        print("  %s: додано %d мм², плиток A/B/C %d/%d/%d" % (s, r["synth_mm2"], r["tiles"]["A"], r["tiles"]["B"], r["tiles"]["C"]))
        for nm, key in (("шов     ", "seam"), ("далі 2-6", "far"), ("контроль", "ctrl")):
            c = r.get("color_" + key)
            g = r.get("grain_%s_log2" % key)
            ctxt = ("dL* %+.2f/%+.2f  da* %+.2f/%+.2f  db* %+.2f/%+.2f  dE %.2f/%.2f" %
                    (c["dL"][0], c["dL"][1], c["da"][0], c["da"][1], c["db"][0], c["db"][1], c["dE"][0], c["dE"][1])) if c else "колір —"
            gtxt = ("зерно " + " ".join("%+.2f" % v for v in g)) if g else "зерно —"
            print("    %s %s | %s" % (nm, ctxt, gtxt))
    if a.json:
        json.dump(res, open(a.json, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
