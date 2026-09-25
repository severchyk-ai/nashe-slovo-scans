# -*- coding: utf-8 -*-
r"""Скільки «ручки» знаходить ns-penmask на готових PDF/теках render — контроль хибних спрацювань.

  python ns-penscan.py <PDF або тека PDF або тека render> [--csv файл]

Для PDF: сторінки витягуються `pdfimages -j` (у наших PDF одна JPEG-картинка на сторінку,
300 dpi) у ВЛАСНУ тимчасову теку скрипта. Скрипт видаляє лише її; вхідні файли (PDF, JPEG
у теці render) не чіпає ніколи — 24.09.2026 попередня версія стерла C:\NS_WORK\2319\render.
Виводить лише сторінки, де маска не порожня, і підсумок: сторінок, сторінок з ручкою.
"""
import argparse
import glob
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pm", os.path.join(HERE, "ns-penmask.py"))
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)


def pages_of(path, work):
    """Віддає (мітка, файл). PDF розкладається лише в підтеку `work` (власна тека)."""
    if os.path.isdir(path):
        pdfs = sorted(glob.glob(os.path.join(path, "*.pdf")))
        if pdfs:
            for p in pdfs:
                yield from pages_of(p, work)
            return
        for f in sorted(glob.glob(os.path.join(path, "p[0-9][0-9].jpg"))):
            yield os.path.basename(os.path.dirname(f)) + ":" + os.path.basename(f)[:3], f
        return
    name = os.path.splitext(os.path.basename(path))[0]
    sub = os.path.join(work, name)
    os.makedirs(sub, exist_ok=True)
    subprocess.run(["pdfimages", "-j", path, os.path.join(sub, "i")], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for k, f in enumerate(sorted(glob.glob(os.path.join(sub, "i-*.jpg")))):
        yield "%s:p%02d" % (name, k + 1), f
    shutil.rmtree(sub, ignore_errors=True)               # лише всередині work


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--csv", default="")
    a = ap.parse_args()
    n = hit = 0
    rows = []
    work = tempfile.mkdtemp(prefix="ns_penscan_")        # єдине місце, де скрипт щось видаляє
    try:
        for label, f in pages_of(a.path, work):
            rgb = np.asarray(Image.open(f).convert("RGB"))
            mask, nzones = pm.pen_mask(rgb)
            n += 1
            area = float((mask > 0).sum()) / (300 / 25.4) ** 2
            rows.append((label, nzones, area))
            if nzones:
                hit += 1
                print("%-12s зон %3d  маска %6.0f мм2" % (label, nzones, area))
                sys.stdout.flush()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("")
    print("сторінок перевірено %d; з ручкою %d" % (n, hit))
    if a.csv:
        with open(a.csv, "w", encoding="utf-8-sig") as fh:
            fh.write("page;zones;mm2\n")
            for r in rows:
                fh.write("%s;%d;%.0f\n" % r)


if __name__ == "__main__":
    main()
