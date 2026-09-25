# -*- coding: utf-8 -*-
"""Ширина білої рамки на всіх чотирьох боках кожної сторінки готового номера.

  python ns-framecheck.py <тека render> [--dpi 300] [--tol 0.5] [--frame 7]

Стандарт оператора (24.09.2026): рамка ОДНАКОВА з усіх чотирьох сторін, на
всіх сторінках, альбомних і книжкових. Скрипт міряє її на JPEG із теки
`C:\\NS_WORK\\<N>\\render` (pNN.jpg) і позначає сторінки, де будь-яке місце рамки
відхиляється від заданої (7 мм) більше ніж на --tol мм або де сторони різняться
між собою більше ніж на --tol.

Як міряє: на кожному боці в ТРЬОХ місцях (12 %, 50 %, 88 % довжини) береться
смужка; рамка — кількість рядків (стовпців) від краю, де >= 97 % пікселів
яскравіші за 250 (чисте біле); далі папір (тон ~244) або друк. Три місця
потрібні, щоб бачити скошений край (клин після випрямлення), якого середина
не показує. Нічого не змінює.
"""
import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

Image.MAX_IMAGE_PIXELS = None


def run(v):
    n = 0
    while n < v.size and v[n] >= 0.97:
        n += 1
    return n


def frame_px(gray):
    h, w = gray.shape
    white = gray >= 254            # чисте біле: світлий папір (250-253) рамкою не вважається
    res = {}
    for name, length, axis, rev in (("L", h, 0, False), ("R", h, 0, True),
                                    ("T", w, 1, False), ("B", w, 1, True)):
        vals = []
        for f in (0.12, 0.5, 0.88):
            c0 = int(length * f)
            c1 = c0 + max(8, int(length * 0.04))
            prof = white[c0:c1, :].mean(axis=0) if axis == 0 else white[:, c0:c1].mean(axis=1)
            if rev:
                prof = prof[::-1]
            vals.append(run(prof))
        res[name] = vals
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--dpi", type=float, default=300.0)
    ap.add_argument("--tol", type=float, default=0.5)
    ap.add_argument("--frame", type=float, default=7.0)
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.dir, "p[0-9][0-9].jpg")))
    mm = a.dpi / 25.4
    bad = 0
    print("стор.  розмір px    Ліво 12/50/88 %    Право            Верх             Низ        розкид, мм")
    for f in files:
        g = np.asarray(Image.open(f).convert("L"))
        r = frame_px(g)
        allv = [x / mm for k in r for x in r[k]]
        spread = max(allv) - min(allv)
        off = max(abs(x - a.frame) for x in allv)
        flag = "  <<< НЕРІВНА" if (spread > a.tol or off > a.tol) else ""
        if flag:
            bad += 1
        cells = "   ".join("/".join("%.1f" % (x / mm) for x in r[k]) for k in ("L", "R", "T", "B"))
        print("%s  %4dx%-4d   %s     %.1f%s" % (os.path.basename(f)[:3], g.shape[1], g.shape[0], cells, spread, flag))
    print("")
    print("сторінок: %d; з нерівною рамкою (допуск %.1f мм від %.1f): %d" % (len(files), a.tol, a.frame, bad))


if __name__ == "__main__":
    main()
