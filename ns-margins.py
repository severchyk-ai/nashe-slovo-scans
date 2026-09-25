# -*- coding: utf-8 -*-
"""Поля друку в готовому номері: від краю ПАПЕРУ (не рамки) до друку на кожному боці.

  python ns-margins.py <тека render> [--rotate 6:270,7:90] [--dpi 300] [--tol 2]

Навіщо (25.09.2026, огляд оператора 2001 і 2002): «сторінка не посередині».
Зовнішній бік (протилежний корінцю) різали так само глибоко, як корінець, і поле
друку з двох боків виходило різне. Скрипт міряє саме те, що бачить оператор:
у JPEG із `C:\\NS_WORK\\<N>\\render` біла рамка (>= 254) відділяє папір, далі —
скільки мм паперу до друку зліва, справа, згори, знизу.

Корінець: непарна сторінка — ліворуч, парна — праворуч (як `Get-NsSpineRule`);
повернуті сторінки — через `--rotate` (page_rotate маніфеста), корінець їде на
верх або низ. Несиметрія = поле ЗОВНІШНЬОГО боку мінус поле КОРІНЦЯ:
  > 0 — друк зсунутий до корінця (зовні зайвий папір),
  < 0 — зовні зрізано глибше, ніж треба для симетрії.

Друк — дві мірки, обидві від краю паперу, у середніх 76 % довжини краю:
  блок   — перший шар 0,5 мм, від якого три шари поспіль мають >= 3 % темних
           пікселів (папір - 70): край колонки тексту;
  місц.  — 5-й перцентиль по 40 відрізках краю, де в кожному відрізку перший
           шар із >= 15 % темних: логотип, заголовок, фото ближче за колонку.
Несиметрія рахується за «блоком». Якщо з сусідньої теки `prep\\_edge.txt`
видно зріз prep — друкується поруч. Нічого не змінює.
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

ROT_MAP = {90: {"L": "T", "R": "B"}, 180: {"L": "R", "R": "L"}, 270: {"L": "B", "R": "T"}}
OPP = {"L": "R", "R": "L", "T": "B", "B": "T"}


def paper_box(gray):
    """Межі паперу: перший рядок/стовпець від краю, де < 90 % пікселів чисто білі (>= 254)."""
    h, w = gray.shape
    white = gray >= 254
    cols = white[int(h * 0.12):int(h * 0.88), :].mean(axis=0)
    rows = white[:, int(w * 0.12):int(w * 0.88)].mean(axis=1)

    def first(v):
        i = 0
        while i < v.size and v[i] >= 0.9:
            i += 1
        return i
    return first(cols), w - first(cols[::-1]), first(rows), h - first(rows[::-1])


def strip(gray, box, side, depth_px):
    """Смуга краю паперу глибиною depth_px; глибина росте ліворуч -> праворуч, довжина — рядки."""
    x0, x1, y0, y1 = box
    if side == "L":
        a = gray[y0:y1, x0:x0 + depth_px]
    elif side == "R":
        a = gray[y0:y1, x1 - depth_px:x1][:, ::-1]
    elif side == "T":
        a = gray[y0:y0 + depth_px, x0:x1].T
    else:
        a = gray[y1 - depth_px:y1, x0:x1][::-1, :].T
    n = a.shape[0]
    return a[int(n * 0.12):int(n * 0.88), :]


def print_start(a, thr, step):
    d = a < thr
    nb = d.shape[1] // step
    frac = np.array([d[:, i * step:(i + 1) * step].mean() for i in range(nb)])
    block = -1
    for i in range(nb - 2):
        if frac[i] >= 0.03 and frac[i + 1] >= 0.03 and frac[i + 2] >= 0.03:
            block = i
            break
    seg = np.array_split(np.arange(d.shape[0]), 40)
    firsts = []
    for s in seg:
        dd = d[s[0]:s[-1] + 1]
        fr = np.array([dd[:, i * step:(i + 1) * step].mean() for i in range(nb)])
        hit = np.nonzero(fr >= 0.15)[0]
        firsts.append(hit[0] if hit.size else nb)
    local = float(np.percentile(firsts, 5))
    return block, local, nb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--rotate", default="")
    ap.add_argument("--dpi", type=float, default=300.0)
    ap.add_argument("--depth", type=float, default=40.0, help="до якої глибини шукати друк, мм")
    ap.add_argument("--tol", type=float, default=2.0, help="позначати несиметрію більшу за, мм")
    a = ap.parse_args()
    rot = {}
    for t in [x for x in re.split(r"[,\s]+", a.rotate) if x]:
        m = re.match(r"^(\d+):(\d+)$", t)
        if m:
            rot[int(m.group(1))] = int(m.group(2))
    mm = a.dpi / 25.4
    step = max(1, int(round(0.5 * mm)))
    edge = {}
    ef = os.path.join(os.path.dirname(os.path.abspath(a.dir.rstrip("\\/"))), "prep", "_edge.txt")
    if os.path.exists(ef):
        for ln in open(ef, encoding="utf-8-sig"):
            m = re.match(r"^p(\d+)\s+T=([\d.]+)\s+B=([\d.]+)\s+L=([\d.]+)\s+R=([\d.]+)", ln)
            if m:
                edge[int(m.group(1))] = dict(T=float(m.group(2)), B=float(m.group(3)),
                                             L=float(m.group(4)), R=float(m.group(5)))
    files = sorted(glob.glob(os.path.join(a.dir, "p[0-9][0-9].jpg")))
    print("стор. корінь  поле друку, мм (блок/місц.)                       несим.  зріз prep, мм")
    print("              Ліво        Право       Верх        Низ           зовн-кор  корінь/зовні")
    asyms = []
    for f in files:
        n = int(os.path.basename(f)[1:3])
        g = np.asarray(Image.open(f).convert("L")).astype(np.int16)
        box = paper_box(g)
        x0, x1, y0, y1 = box
        paper = int(np.percentile(g[y0 + (y1 - y0) // 4:y1 - (y1 - y0) // 4, x0 + (x1 - x0) // 4:x1 - (x1 - x0) // 4], 90))
        thr = paper - 70
        dpx = int(a.depth * mm)
        res = {}
        for s in ("L", "R", "T", "B"):
            blk, loc, nb = print_start(strip(g, box, s, dpx), thr, step)
            res[s] = (blk * step / mm if blk >= 0 else float("nan"), loc * step / mm)
        sp = "L" if n % 2 == 1 else "R"
        if n in rot and rot[n] in ROT_MAP:
            sp = ROT_MAP[rot[n]][sp]
        out = OPP[sp]
        asym = res[out][0] - res[sp][0]
        flag = ""
        if not np.isnan(asym):
            asyms.append(asym)
            if abs(asym) > a.tol:
                flag = "  <<<"
        cut = ""
        if n in edge:
            cut = "%4.1f / %4.1f" % (edge[n][sp], edge[n][out])
        cells = "  ".join("%4.1f/%4.1f" % res[s] for s in ("L", "R", "T", "B"))
        print("p%02d   %s     %s    %+5.1f    %s%s" % (n, sp, cells, asym, cut, flag))
    if asyms:
        v = np.array(asyms)
        print("")
        print("сторінок %d; несиметрія (зовн - корінь), мм: медіана %+.1f, |медіана| %.1f, найбільша |%.1f|; понад %.1f мм: %d"
              % (v.size, np.median(v), np.median(np.abs(v)), np.max(np.abs(v)), a.tol, int((np.abs(v) > a.tol).sum())))


if __name__ == "__main__":
    main()
