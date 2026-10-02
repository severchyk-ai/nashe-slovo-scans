# -*- coding: utf-8 -*-
"""Профіль упоперек шва «доданий | справжній» — МІСЦЕВИЙ, з тоном і зерном (01.10.2026).

  python ns-seamprofile.py <render.jpg> <маска_шва.png> <боки, напр. T або LTB> [--seg 15] [--dpi 300]

Маска — та, від межі якої рахувати відстань (255 = доданий). Щоб порівнювати варіанти заповнення
в одних координатах, усім давати маску ПЕРШОГО варіанта (шов до будь-якого розчинення).

Навіщо: оператор на 2277/7 згори (зразок latky2) бачив різкий перехід — «над швом смуга рівніша й
світліша, сам шов — тонка світла лінія, під ним зерно грубіше», — а ns-seamprobe там показував рівно:
він усереднює по всьому боку й міряє лише тон у смугах 1 мм, а зерно — плитками 2 мм (на смужці
1,5-2,7 мм їх 3). Тут: смуги 0,5-1 мм по обидва боки шва, окремо в кожному відрізку --seg мм уздовж
боку (місцеве не усереднюється), на готовому JPEG:
  L*      — середнє смуги мінус справжній папір 6-8 мм углиб (той самий відрізок);
  дрібне  — розкид L* після віднімання розмиття σ 2 пікс. (зерно до ~0,3 мм);
  крупне  — розкид різниці розмить σ 2 і σ 8 пікс. (хмарність ~0,3-1,5 мм);
  цятки   — частка пікселів, темніших за місцеве тло (розмиття σ 8) на L* 2,5+, %: волокна, цятки,
            просвіт звороту — те, чого в латках із найчистішого паперу немає;
  плями b*— розкид b* у смузі ~0,3-1,5 мм (жовтуваті плями паперу).
Не міряється лише справжній друк (ближче 0,5 мм до пікселя, темнішого за розмиття 3 мм на L* 25),
рамка й 0,3 мм біля неї. Перша версія відкидала все темніше на L* 7 разом із 1 мм навколо — тобто
саме цятки, якими справжній папір відрізняється від доданого. Рядки: медіана за відрізками; «сходинка» — найбільша різниця між СУСІДНІМИ
смугами: медіана за відрізками і 90-й перцентиль (найгірші місця). Нічого не змінює.
"""
import argparse
import sys
import warnings

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None
warnings.filterwarnings("ignore", category=RuntimeWarning)
BANDS = [(-3, -2), (-2, -1), (-1, -0.5), (-0.5, 0), (0, 0.5), (0.5, 1), (1, 2), (2, 3), (3, 4.5), (4.5, 6)]


def measure(rgb, synth, sides, seg=15.0, dpi=300.0):
    """Числа профілю для боків sides: {бік: dict(nseg) (мало відрізків) або dict(nseg, med, mL, pL, mF, pF,
    mC, pC, mS, pS)}; med — смуги x (L*, дрібне, крупне, цятки, плями b*), решта — сходинки між
    сусідніми смугами (медіана і 90-й перцентиль за відрізками). Для ns-padreport.py (02.10.2026)."""
    H, W = synth.shape
    mm = dpi / 25.4
    lab = cv2.cvtColor(rgb.astype(np.float32) / 255.0, cv2.COLOR_RGB2LAB)
    L, B = lab[..., 0], lab[..., 2]
    white = np.all(rgb >= 254, axis=-1)
    _, lc = cv2.connectedComponents(white.astype(np.uint8), 8)
    ids = set(np.unique(np.concatenate([lc[0], lc[-1], lc[:, 0], lc[:, -1]]))) - {0}
    frame = np.isin(lc, list(ids)) & ~synth
    # JPEG: біля рамки дзвін, і пікселі рамки впритул до сторінки вже не >= 254 — вони ставали «справжнім
    # папером» на зовнішньому боці доданої смужки, і смуга −0,5…0 мм збирала темний дзвін рамки як «цятки»
    # (2277/7 L: 5,7 % проти 2,5 % поруч; на PNG до JPEG — 2,7 %). Недодане в 8 пікс. від рамки — теж рамка.
    frame |= ~synth & (cv2.distanceTransform((~frame).astype(np.uint8), cv2.DIST_L2, 5) <= 8)
    real = ~synth & ~frame
    d_fr = cv2.distanceTransform((~frame).astype(np.uint8), cv2.DIST_L2, 5) / mm
    ink = (L < cv2.GaussianBlur(L, (0, 0), 3 * mm) - 25) & ~frame
    d_ink = cv2.distanceTransform((~ink).astype(np.uint8), cv2.DIST_L2, 5) / mm
    sd = np.where(synth, -cv2.distanceTransform((~real).astype(np.uint8), cv2.DIST_L2, 5),
                  cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 5)) / mm
    b2, b8 = cv2.GaussianBlur(L, (0, 0), 2), cv2.GaussianBlur(L, (0, 0), 8)
    fine, coarse = L - b2, b2 - b8
    speck = (L - b8 < -2.5).astype(np.float32) * 100
    bmot = cv2.GaussianBlur(B, (0, 0), 2) - cv2.GaussianBlur(B, (0, 0), 8)
    ok = ~frame & (d_fr > 0.3) & (d_ink >= 0.5)
    yy, xx = np.mgrid[0:H, 0:W]
    near = np.argmin(np.stack([xx, W - 1 - xx, yy, H - 1 - yy]), axis=0)
    # Смуги (sd < 8 мм) лежать не далі від свого краю, ніж найглибший доданий піксель + 8 мм: рахувати
    # лише в цьому вікні відрізка, а не масками на всю сторінку (02.10.2026: ×10 швидше, числа ті самі).
    dedge = np.minimum(np.minimum(xx, W - 1 - xx), np.minimum(yy, H - 1 - yy))
    depth = (int(dedge[synth].max()) if synth.any() else 0) + int(8 * mm) + 3
    res = {}
    for s in sides:
        k = "LRTB".index(s)
        side = ok & (near == k)
        n = H if s in "LR" else W
        step = int(seg * mm)
        rows = []
        for a0 in range(int(0.04 * n), int(0.96 * n) - step, step):
            if s in "LR":
                win = (slice(a0, a0 + step), slice(0, depth) if s == "L" else slice(max(0, W - depth), W))
            else:
                win = (slice(0, depth) if s == "T" else slice(max(0, H - depth), H), slice(a0, a0 + step))
            sg, sdw, Lw, fw, cw, spw, bw = side[win], sd[win], L[win], fine[win], coarse[win], speck[win], bmot[win]
            refm = sg & (sdw >= 6) & (sdw < 8)
            if refm.sum() < 300:
                continue
            ref = Lw[refm].mean()
            r = []
            for lo, hi in BANDS:
                q = sg & (sdw >= lo) & (sdw < hi)
                r.append((Lw[q].mean() - ref, fw[q].std(), cw[q].std(), spw[q].mean(), bw[q].std()) if q.sum() >= 150 else (np.nan,) * 5)
            rows.append(r)
        if len(rows) < 3:
            res[s] = {"nseg": len(rows)}
            continue
        v = np.array(rows)                       # відрізки x смуги x 5
        with np.errstate(all="ignore"):
            med = np.nanmedian(v, axis=0)
            dL = np.abs(np.diff(v[..., 0], axis=1))
            dF = np.abs(np.diff(np.log2(v[..., 1]), axis=1))
            dC = np.abs(np.diff(np.log2(v[..., 2]), axis=1))
            dS = np.abs(np.diff(v[..., 3], axis=1))
            j = lambda d: (np.nanmedian(d, axis=0), np.nanpercentile(d, 90, axis=0))
            (mL, pL), (mF, pF), (mC, pC), (mS, pS) = j(dL), j(dF), j(dC), j(dS)
        res[s] = dict(nseg=len(rows), med=med, mL=mL, pL=pL, mF=mF, pF=pF, mC=mC, pC=pC, mS=mS, pS=pS)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("mask")
    ap.add_argument("sides")
    ap.add_argument("--seg", type=float, default=15.0)
    ap.add_argument("--dpi", type=float, default=300.0)
    a = ap.parse_args()
    rgb = np.array(Image.open(a.image).convert("RGB"))
    synth = np.array(Image.open(a.mask).convert("L")) > 127
    res = measure(rgb, synth, a.sides, a.seg, a.dpi)
    print(a.image)
    for s in a.sides:
        r = res[s]
        if "med" not in r:
            print("  %s: мало відрізків (%d)" % (s, r["nseg"]))
            continue
        med, mL, pL, mF, pF, mC, pC, mS, pS = (r[k] for k in ("med", "mL", "pL", "mF", "pF", "mC", "pC", "mS", "pS"))
        print("  %s: відрізків %d по %.0f мм; смуги мм (− доданий, + справжній): %s"
              % (s, r["nseg"], a.seg, " ".join("%+.1f…%+.1f" % b for b in BANDS)))
        fmt = lambda arr, f: " ".join((f % x) if not np.isnan(x) else "    -" for x in arr)
        print("    L* (мед.)        " + fmt(med[:, 0], "%+5.2f"))
        print("    дрібне зерно     " + fmt(med[:, 1], "%5.2f"))
        print("    крупне зерно     " + fmt(med[:, 2], "%5.2f"))
        print("    цятки, %         " + fmt(med[:, 3], "%5.1f"))
        print("    плями b*         " + fmt(med[:, 4], "%5.2f"))
        print("    сходинка між сусідніми смугами (мед. / 90-й перц. за відрізками):")
        print("      |dL*|             " + fmt(mL, "%5.2f") + "   /   " + fmt(pL, "%5.2f"))
        print("      |log2 дрібного|   " + fmt(mF, "%5.2f") + "   /   " + fmt(pF, "%5.2f"))
        print("      |log2 крупного|   " + fmt(mC, "%5.2f") + "   /   " + fmt(pC, "%5.2f"))
        print("      |цятки, п.п.|     " + fmt(mS, "%5.1f") + "   /   " + fmt(pS, "%5.1f"))


if __name__ == "__main__":
    main()
