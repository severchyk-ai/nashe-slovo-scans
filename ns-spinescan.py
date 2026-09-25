# -*- coding: utf-8 -*-
"""Виміряти проколи корінця: скільки мм краю треба зрізати.

  python ns-spinescan.py <тека з pNN.tif або майстрами> [--zone 30] [--big 4]
                         [--pages 1,2,3] [--side L|R|T|B] [--rotate 6:270,7:90] [--csv файл]

Тека: `C:\\NS_WORK\\<N>\\prep` (найкраще — зібрана з `ns-prep.ps1 -NoEdgeClean`,
там уже вирізано смугу скла й випрямлено перекіс) або тека майстрів. Файли беруться
за шаблоном `*pNN.tif`. Корінець: непарна сторінка — ліворуч, парна — праворуч
(як `Get-NsSpineRule`); для повернутих сторінок (вкладка) — `--rotate` з
`page_rotate` маніфеста: корінець їде на верх або низ (T/B). Нічого не змінює й не пише в каталог.

Що міряє, по кожній сторінці:
  * смугу самого краю (глибина, на якій темні пікселі займають > 50 % довжини);
  * КРУГЛІ темні безбарвні плями: дрібні (< --big мм по більшій стороні) —
    «нитка»; великі і заповнені >= 0,6 — «зшивач». Мірою є ДАЛЬНІЙ край плями
    від краю аркуша: саме його має накрити зріз;
  * скільки ниткових плям лишиться після зрізу c = 1..8 мм;
  * де починається друк (перший 0,5-міліметровий шар із >= 3 % «чорнила» поза
    плямами) — це верхня межа зрізу.

Поріг «темного» — той самий, що в Repair-NsHoles: папір смуги - 90, безбарвність —
хрома < 12 %. Контролем служить майстер 2318, де заміряно 105 ниток
(медіана 3,5 мм, найглибша 5,7 мм): див. звіт відділу інструментів 24.09.2026.
"""
import argparse
import glob
import json
import math
import os
import re
import sys

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

Image.MAX_IMAGE_PIXELS = None
DPI = 400.0
PX = DPI / 25.4


def strip_of(path, side, zone_mm):
    """Смуга корінця; глибина від краю аркуша завжди зростає ліворуч -> праворуч."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    z = int(zone_mm * PX)
    if side in ("L", "R"):
        box = (0, 0, z, h) if side == "L" else (w - z, 0, w, h)
        a = np.asarray(im.crop(box))
        if side == "R":
            a = a[:, ::-1]
    else:                                 # T/B: повернута сторінка (вкладка)
        box = (0, 0, w, z) if side == "T" else (0, h - z, w, h)
        a = np.asarray(im.crop(box))
        if side == "B":
            a = a[::-1, :]
        a = a.transpose(1, 0, 2)          # рядки стають стовпцями: глибина = стовпці
    return np.ascontiguousarray(a), (w, h)


def spine_side(page, rotate):
    """Як Get-NsSpineRule: непарна — Left, парна — Right; повернуту сторінку
    корінець їде разом із нею (-rotate 90 = за годинниковою стрілкою)."""
    side = "Left" if page % 2 else "Right"
    if rotate:
        side = {90: {"Left": "Top", "Right": "Bottom"},
                180: {"Left": "Right", "Right": "Left"},
                270: {"Left": "Bottom", "Right": "Top"}}[rotate][side]
    return side[0]


def analyse(path, side, zone_mm, big_mm, hole_zone):
    rgb, (W, H) = strip_of(path, side, zone_mm)
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    chroma = rgb.max(axis=2).astype(np.int16) - rgb.min(axis=2).astype(np.int16)
    small = cv2.resize(gray, (max(1, gray.shape[1] // 16), max(1, gray.shape[0] // 16)),
                       interpolation=cv2.INTER_AREA)
    paper = int(np.percentile(small, 90))
    thr = max(40, paper - 90)
    dark_any = gray < thr
    frac_depth = dark_any.mean(axis=0)                  # частка темних по кожній глибині
    band_px = 0
    while band_px < frac_depth.size and frac_depth[band_px] > 0.5:
        band_px += 1
    # друга мірка смуги — як детектор скла в ns-prep (Get-BandOffsets): середня
    # яскравість стовпця по всій довжині < 150. Сіре скло 2268/6 (6,8 мм) частку
    # «темніше за папір - 90» на половині довжини не давало, а середнє — дає.
    colmean = cv2.blur(gray.mean(axis=0).reshape(1, -1).astype(np.float32), (max(1, int(0.35 * PX)), 1)).ravel()
    # білий клин після випрямлення перекосу (0-0,5 мм, 255) перед склом не рахується:
    # без цього лічба зупинялась на нулі (2268/6: клин 0,5 мм, далі скло до 7,5 мм)
    band2 = 0
    skip = int(2.0 * PX)
    while band2 < min(skip, colmean.size) and colmean[band2] >= 150:
        band2 += 1
    if band2 >= skip:
        band2 = 0
    else:
        while band2 < colmean.size and colmean[band2] < 150:
            band2 += 1
    if band2 / PX <= 8.0:
        band_px = max(band_px, band2)
    dark = dark_any & (chroma < 0.12 * 255)
    dark[:, :band_px + 1] = False
    dark = cv2.morphologyEx(dark.astype(np.uint8), cv2.MORPH_CLOSE,
                            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
    n, lab, st, _ = cv2.connectedComponentsWithStats(dark, connectivity=8)
    res = dict(paper=paper, thr=thr, band=band_px / PX, threads=[], bigs=[], long=[], H=H)
    blob_mask = np.zeros(dark.shape, np.uint8)
    for i in range(1, n):
        x, y, w, h, area = st[i]
        if area < 0.15 * PX * PX:
            continue
        w_mm, h_mm = w / PX, h / PX                     # w — уздовж глибини, h — уздовж краю
        near, far = x / PX, (x + w) / PX
        along = (y + h / 2) / PX
        if near > max(hole_zone, 9.0):  # глибше — це друк, а не прокол
            continue
        fill = area / float(w * h)
        blob_mask[lab == i] = 1
        if h_mm >= 15.0:
            res["long"].append((along, h_mm, near, far))
        elif max(w_mm, h_mm) >= big_mm and fill >= 0.6 and w_mm >= 3.0 and h_mm >= 3.0:
            res["bigs"].append((along, w_mm, h_mm, near, far))
        elif w_mm < big_mm and h_mm < big_mm and min(w_mm, h_mm) >= 1.5 and near <= hole_zone:
            res["threads"].append((along, w_mm, h_mm, near, far))
        elif min(w_mm, h_mm) < 1.5:
            pass                                            # цятка < 1,5 мм: пил, не прокол
        else:
            res["long"].append((along, h_mm, near, far))    # неправильна пляма: не нитка
    # друк: темніше за папір - 60 поза плямами (розширеними на ~0,8 мм) і поза смугою краю
    ink = (gray < paper - 60)
    grow = cv2.dilate(blob_mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25)))
    ink &= (grow == 0)
    ink[:, :band_px + 1] = False
    col = ink.mean(axis=0)
    win = int(0.5 * PX)
    start = None
    for d in range(0, col.size - win, max(1, win // 2)):
        if col[d:d + win].mean() >= 0.03:
            start = d / PX
            break
    res["print_start"] = start
    res["profile"] = [float(frac_depth[int(d * PX)]) for d in (0, 0.5, 1, 1.5, 2, 3)
                      if int(d * PX) < frac_depth.size]
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--zone", type=float, default=30.0)
    ap.add_argument("--big", type=float, default=4.0)
    ap.add_argument("--holezone", type=float, default=6.0)   # пляма, що починається глибше, — не прокол (зшивач 2318 стартує до 3,2 мм)
    ap.add_argument("--pages", default="")
    ap.add_argument("--side", default="")
    ap.add_argument("--rotate", default="")     # page_rotate з маніфеста: "6:270,7:90"
    ap.add_argument("--csv", default="")
    ap.add_argument("--suggest", action="store_true")     # показати запропонований page_edge корінця
    ap.add_argument("--jsonout", default="")               # зберегти замір і пропозицію в JSON
    ap.add_argument("--margin", type=float, default=0.5)   # запас над найдальшою ниткою, мм
    ap.add_argument("--expect-big", type=int, default=2)  # скільки великих дірок від зшивача чекати на сторінці (2001: 0)
    a = ap.parse_args()
    files = {}
    for f in glob.glob(os.path.join(a.dir, "*p[0-9][0-9].tif")):
        m = re.search(r"p(\d\d)\.tif$", f)
        if m:
            files[int(m.group(1))] = f
    want = [int(x) for x in a.pages.split(",") if x.strip()] if a.pages else sorted(files)
    rot = {}
    for pair in a.rotate.split(","):
        if ":" in pair:
            k, v = pair.split(":")
            rot[int(k)] = int(v)
    all_thr, all_big, rows = [], [], []
    print("стор. бік  папір/поріг  смуга  ниток  далекий край: мед / 90 % / макс   великих  друк з")
    for p in want:
        if p not in files:
            continue
        side = a.side.upper() if a.side else spine_side(p, rot.get(p, 0))
        r = analyse(files[p], side, a.zone, a.big, a.holezone)
        fars = np.array([t[4] for t in r["threads"]]) if r["threads"] else np.array([])
        all_thr += list(fars)
        all_big += [(p,) + b for b in r["bigs"]]
        ps = "-" if r["print_start"] is None else "%.1f" % r["print_start"]
        if fars.size:
            st = "%.1f / %.1f / %.1f" % (np.median(fars), np.percentile(fars, 90), fars.max())
        else:
            st = "- / - / -"
        print("%4d  %s   %3d/%3d   %4.1f  %5d   %-22s  %5d   %s мм"
              % (p, side, r["paper"], r["thr"], r["band"], fars.size, st, len(r["bigs"]), ps))
        for b in r["bigs"]:
            print("        зшивач: %6.1f мм уздовж  %.1fx%.1f мм  глиб. %.1f-%.1f"
                  % (b[0], b[1], b[2], b[3], b[4]))
        for l in r["long"]:
            print("        довга пляма: %6.1f мм уздовж, довжина %.0f мм, глиб. %.1f-%.1f (не нитка й не зшивач)"
                  % l)
        rows.append((p, side, r))
    allf = np.array(all_thr)
    print()
    if allf.size:
        print("УСЬОГО ниткових плям: %d; далекий край від краю аркуша: мін %.1f, мед %.1f, "
              "90 %% %.1f, 99 %% %.1f, макс %.1f мм"
              % (allf.size, allf.min(), np.median(allf), np.percentile(allf, 90),
                 np.percentile(allf, 99), allf.max()))
        print("Зріз, мм -> ниток лишається (від %d):" % allf.size)
        print("   " + "  ".join("%dмм:%d" % (c, int((allf > c).sum())) for c in range(1, 9)))
    print("великих дірок: %d" % len(all_big))
    if a.suggest or a.jsonout:
        suggest(a, rows)
    if args_csv(a) and rows:
        with open(a.csv, "w", encoding="utf-8-sig") as fh:
            fh.write("page;side;along_mm;w_mm;h_mm;near_mm;far_mm\n")
            for p, side, r in rows:
                for t in r["threads"]:
                    fh.write("%d;%s;%.1f;%.1f;%.1f;%.1f;%.1f\n" % ((p, side) + t))


def suggest(a, rows):
    """Пропозиція page_edge для корінцевих сторін: найдальша нитка сторінки + запас, до кроку 0,5 мм.
    Верхня межа — початок друку мінус 1,5 мм (тоді позначка Review: різати глибше без
    друку не можна, вирішує оператор). Сторінка без ниток — медіана решти сторінок номера
    (теж позначка). Це ПРОПОЗИЦІЯ: у маніфест її пише ns-prepare / ns-prep -EdgeExtra."""
    out, cuts = [], []
    for p, side, r in rows:
        fars = [t[4] for t in r["threads"]]
        ps = r["print_start"]
        # Смуга краю (скло, тінь обрізу): суцільна по довжині (band) або довга пляма від самого
        # краю, не глибша 8 мм. Зріз корінця мусить накрити й її: з 25.09.2026 ns-prepare міряє
        # на prep БЕЗ обрізки скла на корінці (-NoSpineBand), бо page_edge у другому проході
        # вимикає детектор скла — і зріз, поміряний від обрізаного краю, лягав від сирого
        # (2268/6: скло 6,8 мм, зріз 5,5 — у PDF лишилась темна лінія).
        strip = r["band"]
        for (_al, ln, near, far) in r["long"]:
            if near <= 1.0 and far <= 8.0 and ln >= 20.0:
                strip = max(strip, far)
        item = {"n": p, "side": side, "threads": len(fars), "far_max": round(max(fars), 1) if fars else None,
                "bigs": len(r["bigs"]), "print_start": None if ps is None else round(ps, 1),
                "strip": round(strip, 1), "flags": []}
        item["strip_cut"] = math.ceil((strip + a.margin) / 0.5) * 0.5 if strip > 0 else 0.0
        if ps is not None:
            item["cap"] = math.floor((ps - 1.5) / 0.5) * 0.5
        if fars:
            deep = max(max(fars), strip)
            cut = math.ceil((deep + a.margin) / 0.5) * 0.5
            if ps is not None and cut > item["cap"]:
                item["flags"].append("Review: нитки/смуга до %.1f мм, друк з %.1f мм — зріз обмежено %.1f" % (deep, ps, item["cap"]))
                cut = item["cap"]
            item["cut"] = cut
            cuts.append(cut)
        else:
            item["cut"] = None
            item["flags"].append("нитки не знайдено")
        if len(r["bigs"]) != a.expect_big:
            item["flags"].append("великих дірок %d (очікувалось %d)" % (len(r["bigs"]), a.expect_big))
        out.append(item)
    med = sorted(cuts)[len(cuts) // 2] if cuts else None
    # глибина ниток ВІД КРАЮ ПАПЕРУ (за смугою): аркуш, покладений глибше під скло,
    # має нитки глибше на ширину смуги (2268/6: смуга 7,7 мм, нитки злиплись зі
    # смугою й не виділились; медіана номера 6 мм лишила дірки в PDF)
    rels = sorted(it["far_max"] - it["strip"] for it in out if it["far_max"] is not None)
    med_rel = rels[len(rels) // 2] if rels else 0.0
    for it in out:
        if it["cut"] is None and med is not None:
            by_strip = math.ceil((it["strip"] + med_rel + a.margin) / 0.5) * 0.5 if it["strip"] > 0 else 0.0
            it["cut"] = max(med, it["strip_cut"], by_strip)
            if "cap" in it and it["cut"] > it["cap"]:
                it["cut"] = it["cap"]
            it["flags"].append("Review: ниток не видно; зріз %.1f = max(медіана номера %.1f, смуга %.1f + нитки від краю паперу %.1f)" % (it["cut"], med, it["strip"], med_rel))
    tokens = ["%d%s%s" % (it["n"], it["side"], ("%g" % it["cut"])) for it in out if it["cut"] is not None]
    edge = " ".join(tokens)
    print()
    print("ПРОПОЗИЦІЯ page_edge (корінець): " + edge)
    for it in out:
        if it["flags"]:
            print("   стор. %d: %s" % (it["n"], "; ".join(it["flags"])))
    if a.jsonout:
        with open(a.jsonout, "w", encoding="utf-8") as fh:
            json.dump({"edge": edge, "pages": out}, fh, ensure_ascii=False, indent=1)


def args_csv(a):
    return bool(a.csv)


if __name__ == "__main__":
    main()
