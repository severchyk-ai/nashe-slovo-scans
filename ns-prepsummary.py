# -*- coding: utf-8 -*-
"""Підсумок підготовки номерів (NS_WORK\\<N>\\prepare.json, пише ns-prepare.ps1) — числа для звіту.

  python ns-prepsummary.py 2320 2321 2322 [--work C:\\NS_WORK]

По кожному номеру: нитки (шт., найдальша, мед. по сторінках), зрізи корінця, скільки великих дірок
знайдено/зарощено, позначки НАГЛЯД і Review, не зведене до розміру, нерівна рамка. Наприкінці —
розкид глибини ниток у номері й між номерами (те, що показує, чи можна ставити один зріз на номер).
Нічого не змінює.
"""
import argparse
import io
import json
import os
import statistics
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seq", nargs="+")
    ap.add_argument("--work", default=r"C:\NS_WORK")
    a = ap.parse_args()
    allcuts, perissue = [], {}
    for n in a.seq:
        path = os.path.join(a.work, n, "prepare.json")
        if not os.path.exists(path):
            print("== %s: prepare.json немає" % n)
            continue
        d = json.load(io.open(path, encoding="utf-8-sig"))
        sp = d.get("spine") or {}
        pages = sp.get("pages", [])
        fars = [p["far_max"] for p in pages if p.get("far_max") is not None]
        cuts = [p["cut"] for p in pages if p.get("cut") is not None]
        thr = sum(p["threads"] for p in pages)
        bigs = sum(p["bigs"] for p in pages)
        h = d.get("holes", {})
        print("== %s (%s, %d стор., %s хв)" % (n, d.get("date"), d.get("pages"), d.get("minutes")))
        print("   нитки: %d шт.; найдальша по сторінках: мін %.1f, мед %.1f, макс %.1f мм; розкид (макс-мін) %.1f мм"
              % (thr, min(fars), statistics.median(fars), max(fars), max(fars) - min(fars)) if fars else "   нитки: не знайдено")
        print("   зрізи корінця (мм): %s" % " ".join("%d%s%g" % (p["n"], p["side"], p["cut"]) for p in pages if p.get("cut") is not None))
        print("   великих дірок знайдено (скан) %d; зарощено %s із очікуваних %s; лишено біля друку/за формою %s %s"
              % (bigs, h.get("filled"), h.get("expected"), h.get("left_near_print"), "; ".join(h.get("pages_with_left") or [])))
        rv = [(p["n"], p["flags"]) for p in pages if any(f.startswith("Review") for f in p.get("flags", []))]
        if rv:
            print("   Review (нитки глибше за друк / без ниток): %s" % rv)
        if d.get("edge_watch"):
            print("   НАГЛЯД (edgecheck): %s" % "; ".join(d["edge_watch"]))
        if d.get("render_not_unified"):
            print("   render не зведено до спільного розміру: %d стор." % len(d["render_not_unified"]))
        print("   рамка нерівних сторінок: %s" % (", ".join(d.get("frame_uneven") or []) or "немає"))
        allcuts += cuts
        perissue[n] = {"far_max": max(fars) if fars else None, "med_cut": statistics.median(cuts) if cuts else None,
                       "cuts": cuts}
    if len(perissue) > 1:
        print()
        print("МІЖ НОМЕРАМИ: найдальша нитка номера: %s" % ", ".join("%s: %.1f" % (k, v["far_max"]) for k, v in perissue.items() if v["far_max"] is not None))
        print("              зрізи по всіх сторінках: мін %g, мед %g, макс %g мм" % (min(allcuts), statistics.median(allcuts), max(allcuts)))
        uni = max(allcuts)
        print("              один спільний зріз %g мм лишив би всі нитки всіх номерів зрізаними" % uni)


if __name__ == "__main__":
    main()
