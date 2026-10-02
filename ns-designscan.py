# -*- coding: utf-8 -*-
"""Новий дизайн чи звичайний: частка друку в смузі 4-12 мм від краю аркуша (02.10.2026, інструменти).

  python ns-designscan.py <тека року або теки номерів …> [--thr 5] [--jobs 8] [--csv файл]

Мірило з 28.09.2026 (ЗВІТИ\\2026-09-28_інструменти.md, Додаток 6; тоді рахувалося разово, скрипта не
лишилося): майстер сторінки зменшується до 25 dpi (1 пікс. ≈ 1 мм); у смузі 4-12 мм від КОЖНОГО краю
кадру — частка пікселів, темніших за 150 (друк); на сторінку береться найбільша з чотирьох боків, на
номер — МЕДІАНА сторінок. Звичайна верстка має поля 12-25 мм, смуга порожня (2001: 0,0-1,1 %); новий
дизайн (плашки, фото, тло до краю) — 8,0-31,5 %. Поріг --thr 5 % — у розриві між ними.
Додатково друкується найбільше значення по сторінках: одна сторінка до краю у звичайному номері
(календар 2267 — 95, 2268 — 47, 2296 — 75) номер «новим» не робить, але її варто глянути.
Смуга скла й кришка лежать у 0-2 мм від краю кадру і в смугу 4-12 мм не потрапляють.
Майстри лише читаються. Нічого не змінює.
"""
import argparse
import glob
import os
import re
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None


def page_value(path):
    im = Image.open(path)
    im.seek(0)
    g = im.convert("L")
    k = 16                                      # 400 dpi -> 25 dpi
    g = g.reduce(k)
    a = np.asarray(g)
    dark = a < 150
    vals = [dark[4:12, :].mean(), dark[-12:-4, :].mean(), dark[:, 4:12].mean(), dark[:, -12:-4].mean()]
    return 100.0 * float(max(vals))


def issue_dirs(args):
    out = []
    for a in args:
        if glob.glob(os.path.join(a, "*_p[0-9][0-9].tif")):
            out.append(a)
        else:
            out += sorted(d for d in glob.glob(os.path.join(a, "*_*")) if os.path.isdir(d) and re.match(r"^\d{4}_", os.path.basename(d)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--thr", type=float, default=5.0)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--csv", default="")
    a = ap.parse_args()
    dirs = issue_dirs(a.paths)
    tasks = []
    for d in dirs:
        for f in sorted(glob.glob(os.path.join(d, "*_p[0-9][0-9].tif"))):
            tasks.append((os.path.basename(d).split("_")[0], f))
    with Pool(a.jobs) as pool:
        vals = pool.map(page_value, [t[1] for t in tasks], chunksize=4)
    by = {}
    for (seq, f), v in zip(tasks, vals):
        by.setdefault(seq, []).append(v)
    rows = []
    print("номер  стор.  медіана %  найб. %  сторінок >= 40 %   висновок")
    for seq in sorted(by):
        v = np.array(by[seq])
        med, mx, n40 = float(np.median(v)), float(v.max()), int((v >= 40).sum())
        verdict = "НОВИЙ ДИЗАЙН" if med >= a.thr else ("глянути сторінку" if n40 else "")
        rows.append((seq, len(v), med, mx, n40, verdict))
        print("%s   %3d    %6.1f    %6.1f   %3d              %s" % (seq, len(v), med, mx, n40, verdict))
    new = [r[0] for r in rows if r[2] >= a.thr]
    print("")
    print("номерів %d; новий дизайн (медіана >= %.0f %%): %d — %s" % (len(rows), a.thr, len(new), ", ".join(new) if new else "немає"))
    usual = [r[2] for r in rows if r[2] < a.thr]
    if usual:
        print("звичайні: медіана %.1f-%.1f %%; найближчий до порогу знизу %.1f, згори %s"
              % (min(usual), max(usual), max(usual), ("%.1f" % min(r[2] for r in rows if r[2] >= a.thr)) if new else "-"))
    if a.csv:
        with open(a.csv, "w", encoding="utf-8-sig", newline="\n") as f:
            f.write("seq,pages,median_pct,max_pct,pages_ge40\n")
            for r in rows:
                f.write("%s,%d,%.1f,%.1f,%d\n" % r[:5])


if __name__ == "__main__":
    main()
