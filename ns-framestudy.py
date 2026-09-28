# -*- coding: utf-8 -*-
"""Дослід для СТАНДАРТУ РАМКИ: чому рамка нерівна і що дадуть інші правила.

  python ns-framestudy.py <N> [<N> ...]        номери з C:\\NS_WORK\\<N>\\render\\_fit.json
  python ns-framestudy.py --all                усі теки NS_WORK з _fit.json

Оператор (28.09.2026): рамка має бути РІВНА на всіх сторінках, у всіх номерах і
річниках; розтягнення друку — не більше 1,5 %. Скрипт нічого не змінює. Він бере:
  - _fit.json (ns-render з 28.09): ширина/висота сторінки після зрізів, запас
    чистого поля до друку з кожного боку, ціль номера, масштаб, боки page_edge;
  - заміри рамки ns-framecheck (той самий код) на готових pNN.jpg.
і пише:
  1) нерівні сторінки (розкид > 0,5 мм) і ПРИЧИНУ:
     page_edge — на боці «не чіпати» лишився білий клин;
     розмір    — сторінку не звести до цілі: бракує чистого поля, а масштаб поза
                 межами (стиснення ≤ scale_max, розтягнення ≤ grow_max);
     інше      — клин/перекіс, що лишився після зведення;
  2) варіанти стандарту (по ширині й висоті, книжкові окремо від альбомних):
     A  чинний: ціль — медіана досяжних розмірів номера, стиснення ≤ 4 %,
        розтягнення ≤ 1,5 %;
     B  ціль — НАЙВУЖЧА сторінка номера: решта ріжуть лишок з чистого поля, чого
        бракує — стиснення ≤ 4 %; розтягнення не буває;
     C  як B, але одна ціль на ВЕСЬ РІК (найвужча сторінка року, без 1 % викидів).
     Для кожного: скільки сторінок не зводиться (рамка буде нерівна), скільки
     чистого поля ріжеться (мм, медіана/макс), найбільше стиснення, і чи варіант
     вимагав би різати бік «не чіпати» (не вимагає за побудовою — там запас 0).
"""
import glob
import json
import os
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import importlib.util
_spec = importlib.util.spec_from_file_location("fc", os.path.join(HERE, "ns-framecheck.py"))
fc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fc)


def load(seq):
    f = os.path.join(r"C:\NS_WORK", str(seq), "render", "_fit.json")
    if not os.path.exists(f):
        return None
    return json.load(open(f, encoding="utf-8-sig"))


def reach(p, mmpx, axis):
    """(найбільший, найменший досяжний без масштабу) розмір сторінки по осі, пікс."""
    fr = p["free_mm"]
    if axis == 0:
        big = p["cw_before"]; free = (fr[0] + fr[1]) * mmpx
    else:
        big = p["ch_before"]; free = (fr[2] + fr[3]) * mmpx
    return big, max(1.0, big - free)


def fits(big, small, target, smax, gmax):
    """Чи зводиться до цілі: зріз чистого поля, тоді масштаб. -> (ок, зріз пікс., масштаб %)"""
    if target >= big:                       # треба розтягнути
        s = (target / big - 1) * 100
        return s <= gmax + 0.05, 0.0, s
    if target >= small:                     # вистачає чистого поля
        return True, big - target, 0.0
    s = (target / small - 1) * 100          # решта — стисненням
    return s >= -(smax + 0.05), big - small, s


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); return 2
    if args == ["--all"]:
        seqs = sorted(int(os.path.basename(os.path.dirname(os.path.dirname(f))))
                      for f in glob.glob(r"C:\NS_WORK\2[0-9][0-9][0-9]\render\_fit.json"))
    else:
        seqs = [int(a) for a in args]
    data = {s: load(s) for s in seqs}
    data = {s: d for s, d in data.items() if d}
    if not data:
        print("немає _fit.json"); return 1

    # --- 1. нерівні рамки і причини -------------------------------------
    print("1. НЕРІВНА РАМКА (розкид > 0,5 мм) і причина")
    cause_n = {"page_edge": 0, "розмір": 0, "інше": 0}
    tot_pages = 0; bad_pages = 0; spreads = []
    for s, d in data.items():
        mm = d["dpi"] / 25.4
        recs = {p["page"]: p for p in d["pages"]}
        lines = []
        for f in sorted(glob.glob(os.path.join(r"C:\NS_WORK", str(s), "render", "p[0-9][0-9].jpg"))):
            name = os.path.basename(f)[:3]
            tot_pages += 1
            g = np.asarray(Image.open(f).convert("L"))
            r = fc.frame_px(g)
            allv = [x / mm for k in r for x in r[k]]
            spread = max(allv) - min(allv)
            if spread <= 0.5 and max(abs(x - 7.0) for x in allv) <= 0.5:
                continue
            bad_pages += 1; spreads.append(spread)
            p = recs.get(name, {})
            kept = p.get("wedge_kept_mm", "") or ""
            try:
                kept_mm = max([float(t[1:]) for t in kept.split()] or [0])
            except Exception:
                kept_mm = 0
            if kept_mm >= 0.4:
                why = "page_edge"; txt = f"клин лишено ({kept})"
            elif p and not p.get("scaled", True):
                why = "розмір"; txt = "масштаб поза межами {}".format(p.get("scale_pct"))
            else:
                why = "інше"; txt = "масштаб {}".format(p.get("scale_pct"))
            cause_n[why] += 1
            lines.append(f"   {s}/{name}: {spread:.1f} мм — {why}: {txt}")
        for l in lines:
            print(l)
    print(f"   сторінок {tot_pages}, нерівних {bad_pages}"
          + (f" (розкид мед {np.median(spreads):.1f}, макс {max(spreads):.1f} мм)" if spreads else "")
          + "; причини: " + ", ".join(f"{k} {v}" for k, v in cause_n.items()))

    # --- 2. варіанти стандарту -------------------------------------------
    # По ШИРИНІ з симетрією полів: сторінка має запаси fL, fR до друку. Симетрія
    # знімає |fL - fR| з більшого боку -> «симетрична» ширина hi = big - |fL-fR|;
    # далі можна різати обидва боки порівну до lo = big - fL - fR. Ціль T:
    #   T <= lo        -> стиснення (T/lo - 1), симетрія повна;
    #   lo < T <= hi   -> лише зріз чистого поля, симетрія повна;
    #   T > hi         -> розтягнення (T/hi - 1) до grow_max; що не влазить —
    #                     симетрія неповна: лишок несиметрії (T - hi) мм... або рамка.
    # По ВИСОТІ симетрії немає: зріз до big - fT - fB, далі стиснення/розтягнення.
    print()
    print("2. ВАРІАНТИ СТАНДАРТУ (ширина — з симетрією полів; висота — без)")
    year_of = lambda s: 2000 if s < 2266 else (2001 if s < 2318 else 2002)
    pages = []
    for s, d in data.items():
        mm = d["dpi"] / 25.4
        for p in d["pages"]:
            fr = p["free_mm"]
            big = p["cw_before"]; sym = abs(fr[0] - fr[1]) * mm
            hi = big - sym; lo = big - (fr[0] + fr[1]) * mm
            bh = p["ch_before"]; loh = bh - (fr[2] + fr[3]) * mm
            pages.append(dict(seq=s, page=p["page"], land=p["land"], mm=mm, big=big, hi=hi, lo=lo, bh=bh, loh=loh,
                              tA=p["target"], smax=d["scale_max"], gmax=d["grow_max"], forced=bool(p.get("forced"))))
    def evalw(pg, T):
        mm = pg["mm"]
        if T <= pg["lo"]:
            return dict(cut=(pg["big"] - pg["lo"]) / mm, sc=(T / pg["lo"] - 1) * 100, asym=0.0)
        if T <= pg["hi"]:
            return dict(cut=(pg["big"] - T) / mm, sc=0.0, asym=0.0)
        need = (T / pg["hi"] - 1) * 100
        if need <= pg["gmax"] + 0.05:
            return dict(cut=(pg["big"] - pg["hi"]) / mm, sc=need, asym=0.0)
        # розтягнення на межі, решту — з симетрії (зріз менший) або рамкою
        hi_g = T / (1 + pg["gmax"] / 100.0)
        return dict(cut=max(0.0, pg["big"] - max(hi_g, pg["hi"])) / mm, sc=pg["gmax"], asym=(max(0.0, min(pg["big"], hi_g) - pg["hi"])) / mm)
    def evalh(pg, T):
        mm = pg["mm"]
        if T <= pg["loh"]:
            return dict(cut=(pg["bh"] - pg["loh"]) / mm, sc=(T / pg["loh"] - 1) * 100)
        if T <= pg["bh"]:
            return dict(cut=(pg["bh"] - T) / mm, sc=0.0)
        return dict(cut=0.0, sc=(T / pg["bh"] - 1) * 100)
    groups = {}
    for pg in pages:
        groups.setdefault((pg["seq"], pg["land"]), []).append(pg)
    yhi = {}
    for pg in pages:
        yhi.setdefault((year_of(pg["seq"]), pg["land"]), []).append((pg["hi"], pg["bh"]))
    variants = [("A", "чинний: ціль номера з ns-render (стиснення ≤ 4, розтягнення ≤ 1,5 %)"),
                ("B", "ціль = найвужча СИМЕТРИЧНА сторінка номера (розтягнень немає)"),
                ("C", "ціль = одна на РІК (1-й перцентиль симетричних ширин року)")]
    for key, name in variants:
        rows = []
        for (s, land), items in groups.items():
            if key == "A":
                tw, th = items[0]["tA"]
            elif key == "B":
                tw = min(i["hi"] for i in items); th = min(i["bh"] for i in items)
            else:
                arr = yhi[(year_of(s), land)]
                tw = float(np.percentile([a[0] for a in arr], 1)); th = float(np.percentile([a[1] for a in arr], 1))
            for pg in items:
                w = evalw(pg, tw); h = evalh(pg, th)
                sc_bad = w["sc"] < -(pg["smax"] + 0.05) or h["sc"] < -(pg["smax"] + 0.05) or h["sc"] > pg["gmax"] + 0.05
                rows.append(dict(id=f"{s}/{pg['page']}", w=w, h=h, bad=sc_bad or w["asym"] > 0.5, asym=w["asym"],
                                 forced=pg["forced"]))
        n = len(rows)
        asym2 = [r for r in rows if r["asym"] > 2.0]
        grow = [r for r in rows if r["w"]["sc"] > 0.05 or r["h"]["sc"] > 0.05]
        shr = [min(r["w"]["sc"], r["h"]["sc"]) for r in rows]
        cuts = [r["w"]["cut"] for r in rows]
        bad = [r for r in rows if r["bad"]]
        print(f"   {key} — {name}")
        print(f"      стор. {n}; не зведеться без ширшої рамки/несиметрії {len(bad)}; несиметрія > 2 мм {len(asym2)}; "
              f"розтягнень {len(grow)}; стиснення до {min(shr):+.1f} %; зріз чистого поля по ширині мед {np.median(cuts):.1f}, "
              f"90 % {np.percentile(cuts, 90):.1f}, макс {max(cuts):.1f} мм")
        if bad:
            print("      не зводяться: " + ", ".join(r["id"] for r in bad)[:500])
    return 0


if __name__ == "__main__":
    sys.exit(main())
