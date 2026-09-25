# -*- coding: utf-8 -*-
"""Глибина чорної смуги скла (і білого клина) на кожному з чотирьох країв.

  python ns-edgedepth.py <тека prep> [--pages 1,5,6] [--dark 90]

Береться prep, зібраний `ns-prep.ps1 -NoEdgeClean` (нічого не замальовано).
Для кожного краю в П'ЯТИ місцях уздовж нього (10/30/50/70/90 % довжини)
міряє, на яку глибину від краю тягнеться СУЦІЛЬНО ТЕМНЕ (>= 70 % пікселів
смужки темніші за --dark, 90 з 255): це смуга скла. Окремо — глибина суцільно
білого (>= 97 % пікселів > 250): клин після випрямлення перекосу. Числа —
мм, п'ять значень уздовж краю. Різниця між ними — скіс краю.

Береться не середнє по краю, а кожне місце окремо: довга смуга з одного кінця
й нічого з другого («скіс») і є те, що дає нерівну рамку. Нічого не змінює.
"""
import argparse
import glob
import os
import re
import sys

import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

Image.MAX_IMAGE_PIXELS = None
SCALE = 4                    # 400 dpi -> 100 dpi
MM_PX = 100.0 / 25.4


def run_len(v, ok, skip=0):
    """Скільки поспіль стовпців задовольняють ok. skip — скільки перших стовпців
    (клин, край, що осипається) можна пропустити, поки не почнеться суцільне."""
    n = 0
    while n < min(skip, v.size) and not ok(v[n]):
        n += 1
    if n >= min(skip, v.size) and skip and (v.size == 0 or not ok(v[n] if n < v.size else 0)):
        return 0
    while n < v.size and ok(v[n]):
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--pages", default="")
    ap.add_argument("--dark", type=int, default=90)
    a = ap.parse_args()
    files = {}
    for f in glob.glob(os.path.join(a.dir, "p[0-9][0-9].tif")):
        files[int(re.search(r"p(\d\d)\.tif$", f).group(1))] = f
    want = [int(x) for x in a.pages.split(",") if x.strip()] if a.pages else sorted(files)
    print("сторінка / край: ЧОРНА смуга скла, мм у 5 місцях (10/30/50/70/90 %)  |  БІЛИЙ клин, мм")
    for p in want:
        if p not in files:
            continue
        im = Image.open(files[p]).convert("L")
        im = im.resize((im.width // SCALE, im.height // SCALE), Image.BOX)
        g = np.asarray(im)
        for name, arr in (("Верх", g.T), ("Низ", g[::-1].T), ("Ліво", g), ("Право", g[:, ::-1])):
            # arr: рядки = позиції вздовж краю, стовпці = глибина
            n_along = arr.shape[0]
            blk, wht = [], []
            for f in (0.1, 0.3, 0.5, 0.7, 0.9):
                r0 = int(n_along * f)
                r1 = r0 + max(6, int(n_along * 0.03))
                band = arr[r0:r1, :int(40 * MM_PX)]
                dark = (band < a.dark).mean(axis=0)
                white = (band > 250).mean(axis=0)
                blk.append(run_len(dark, lambda x: x >= 0.70, skip=int(2.0 * MM_PX)) / MM_PX)
                wht.append(run_len(white, lambda x: x >= 0.97) / MM_PX)
            print("  p%02d %-5s  чорна %s  |  білий %s"
                  % (p, name, " ".join("%4.1f" % x for x in blk), " ".join("%4.1f" % x for x in wht)))


if __name__ == "__main__":
    main()
