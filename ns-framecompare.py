# -*- coding: utf-8 -*-
r"""Порівняти два набори render одного номера: рамка, розміри сторінок, збереження друку.

  python ns-framecompare.py <тека render А (було)> <тека render Б (стало)>

Для кожної пари pNN.jpg: розкид ширини рамки (мм; макс - мін по 12 місцях), розмір,
зміна кількості темних пікселів (< 150) — за нею видно, чи не з'їдено друк. Підсумок:
скільки сторінок нерівних (розкид або відхилення від 7 мм > 0,5), скільки різних розмірів.
Викликати на копіях (NS_WORK\9NNN) — не на робочих теках. Нічого не змінює.
"""
import glob
import importlib.util
import os
import sys

import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fc", os.path.join(HERE, "ns-framecheck.py"))
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)
MM = 300 / 25.4


def measure(g):
    r = fc.frame_px(g)
    v = [x / MM for k in r for x in r[k]]
    return max(v) - min(v), max(abs(x - 7.0) for x in v)


def main():
    da, db = sys.argv[1], sys.argv[2]
    rows = []
    for f in sorted(glob.glob(os.path.join(db, "p[0-9][0-9].jpg"))):
        b = os.path.basename(f)
        fo = os.path.join(da, b)
        if not os.path.exists(fo):
            continue
        gn = np.asarray(Image.open(f).convert("L"))
        go = np.asarray(Image.open(fo).convert("L"))
        so, oo = measure(go)
        sn, on = measure(gn)
        ia, ib = (go < 150).sum(), (gn < 150).sum()
        rows.append((b[:3], so, sn, go.shape[::-1], gn.shape[::-1], 100.0 * (ib - ia) / max(ia, 1), max(so, oo), max(sn, on)))
    for r in rows:
        flag = "  <<<" if (r[7] > 0.5 or abs(r[5]) > 1.0) else ""
        print("%s  розкид %.2f -> %.2f мм   розмір %dx%d -> %dx%d   чорнила %+.2f%%%s" % (r[0], r[1], r[2], r[3][0], r[3][1], r[4][0], r[4][1], r[5], flag))
    print("нерівних (>0,5 мм): було %d, стало %d з %d; різних розмірів: було %d, стало %d; розкид сер.: %.2f -> %.2f мм"
          % (sum(1 for r in rows if r[6] > 0.5), sum(1 for r in rows if r[7] > 0.5), len(rows),
             len(set(r[3] for r in rows)), len(set(r[4] for r in rows)),
             np.mean([r[1] for r in rows]), np.mean([r[2] for r in rows])))


if __name__ == "__main__":
    main()
