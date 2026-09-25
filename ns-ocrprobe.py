# -*- coding: utf-8 -*-
"""Скільки слів OCR читає в заданих прямокутниках сторінки — за варіантами сірої копії.

  python ns-ocrprobe.py <сторінка.jpg> --box A:1450,290,2030,1140 --box B:... [--variants gray,r,pen]
                        [--pen <маска.png>] [--dump теки для txt]

Варіанти сірої копії:
  gray — звичайна (`magick -colorspace Gray`), як досі в New-NsOcrGray;
  r    — канал R (червоне світле; друковане червоне теж зникає — лише як межа);
  pen  — gray, а в масці ручки (ns-penmask.py) — канал R;
  file:<шлях.png> — готова сіра копія (напр. з New-NsOcrGray) — без перетворень.
Розпізнавання — як в ns-build: tesseract -l ukr+pol -c thresholding_method=2 на ВСІЙ
сторінці (а не на вирізці: розмітка сторінки на вирізці інша). Слова беруться з TSV,
у прямокутник потрапляє слово, чий центр у ньому; лічиться слово з >= 2 літер і
впевненістю >= 30. Нічого не змінює в каталозі.
"""
import argparse
import csv
import io
import os
import shutil
import subprocess
import sys
import tempfile

TESS = r"C:\Program Files\Tesseract-OCR\tesseract.exe"
HERE = os.path.dirname(os.path.abspath(__file__))

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def make_gray(src, variant, pen, out):
    if variant == "gray":
        subprocess.run(["magick", src, "-alpha", "off", "-colorspace", "Gray", out], check=True)
    elif variant == "r":
        subprocess.run(["magick", src, "-alpha", "off", "-channel", "R", "-separate", out], check=True)
    elif variant.startswith("file:"):
        subprocess.run(["magick", variant[5:], out], check=True)
    elif variant == "pen":
        g = out + ".g.png"
        r = out + ".r.png"
        subprocess.run(["magick", src, "-alpha", "off", "-colorspace", "Gray", g], check=True)
        subprocess.run(["magick", src, "-alpha", "off", "-channel", "R", "-separate", r], check=True)
        subprocess.run(["magick", g, r, pen, "-alpha", "off", "-composite", out], check=True)
    else:
        raise SystemExit("невідомий варіант " + variant)


def run_tess(png):
    env = dict(os.environ, TESSDATA_PREFIX=os.path.join(HERE, "tessdata"))
    p = subprocess.run([TESS, png, "stdout", "--tessdata-dir", os.path.join(HERE, "tessdata"),
                        "-l", "ukr+pol", "-c", "thresholding_method=2", "tsv"],
                       capture_output=True, env=env)
    txt = p.stdout.decode("utf-8", errors="replace")
    rows = list(csv.reader(io.StringIO(txt), delimiter="\t", quoting=csv.QUOTE_NONE))
    words = []
    for r in rows[1:]:
        if len(r) < 12 or r[0] != "5":
            continue
        try:
            x, y, w, h, conf = int(r[6]), int(r[7]), int(r[8]), int(r[9]), float(r[10])
        except ValueError:
            continue
        words.append((x + w / 2.0, y + h / 2.0, r[11], conf))
    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--box", action="append", default=[])
    ap.add_argument("--variants", default="gray,r,pen")
    ap.add_argument("--pen", default="")
    ap.add_argument("--dump", default="")
    a = ap.parse_args()
    boxes = []
    for b in a.box:
        name, c = b.split(":")
        boxes.append((name, [int(v) for v in c.split(",")]))
    tmp = tempfile.mkdtemp(prefix="ns_ocrprobe_")      # власна тека: після роботи видаляється цілком
    try:
        run_variants(a, boxes, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_variants(a, boxes, tmp):
    for v in a.variants.split(","):
        png = os.path.join(tmp, v.replace(":", "_").replace("\\", "_").replace("/", "_") + ".png")
        make_gray(a.src, v, a.pen, png)
        words = run_tess(png)
        good = [w for w in words if len(w[2].strip()) >= 2 and w[3] >= 30]
        line = ["%-5s усього слів %5d (упевн. >=30: %5d)" % (v, len(words), len(good))]
        for name, (x0, y0, x1, y1) in boxes:
            inb = [w for w in good if x0 <= w[0] <= x1 and y0 <= w[1] <= y1]
            line.append("%s:%3d" % (name, len(inb)))
            if a.dump:
                os.makedirs(a.dump, exist_ok=True)
                with open(os.path.join(a.dump, "%s_%s.txt" % (v, name)), "w", encoding="utf-8") as fh:
                    fh.write(" ".join(w[2] for w in sorted(inb, key=lambda t: (round(t[1] / 25), t[0]))))
        print("   ".join(line))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
