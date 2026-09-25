# -*- coding: utf-8 -*-
"""Маска червоної ручки (перекреслення) на сторінці — для сірої копії OCR.

  python ns-penmask.py <сторінка.jpg|png|tif> <маска.png> [--stats]

Навіщо (24.09.2026, 2319/10): три малі рамкові блоки перекреслено від руки червоною
ручкою. У сірій копії (`New-NsOcrGray`) червоне стає темно-сірим, лягає хрестом
поверх літер, і tesseract читає з блоків уривки. Через канал R (там червоне
світле) — майже все. Гасити канал R усюди не можна: друковане червоне
(календар 2318, заголовки, плашки) теж зникло б. Тому червоне гаситься
ТІЛЬКИ там, де воно схоже на ручку: довгі, неякісно прямі, не горизонтальні
й не вертикальні штрихи.

Як шукається (пороги виміряно за 2319/10 і 622 сторінками, див. звіт відділу інструментів):
  1. «червоність» = R - max(G, B); ядро > 40, широка зона > 18;
  2. широка зона закривається на 3 мм (пунктир штриха), беруться зв'язні області;
  3. зона ручки: велика (>= 14 мм, >= 25 мм2), ТОНКА (пікселів товщі 1,6 мм <= 2 %,
     90-й перцентиль пів-товщини <= 0,6 мм) і побудована з довгих прямих (>= 3 відрізків
     Хафа від 12 мм, не по осях, суцільно на червоному; на них >= 60 % червоного);
  4. маска = червоні пікселі в 1,2 мм від цих відрізків.
Пікселі поза маскою в сірій копії НЕ ЗМІНЮЮТЬСЯ. Не покрито: одиночне перекреслення
(вузька довга смуга: менша сторона < 14 мм) і замкнене коло — додавати за потреби.

Вивід: маска (255 = ручка) і рядок статистики: зон, площа маски, мм².
"""
import argparse
import sys

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

Image.MAX_IMAGE_PIXELS = None
DPI = 300.0
PX = DPI / 25.4


def pen_mask(rgb, dpi=300.0, core_thr=40, wide_thr=18, minlen=12.0,
             min_side_mm=14.0, min_area_mm2=25.0, max_thick=0.02, max_p90_mm=0.6,
             min_line_share=0.6, min_lines=3):
    """rgb: масив HxWx3 uint8. Повертає (маска uint8, кількість зон ручки).

    Зона ручки — зв'язна область «широкого» червоного (після закриття 3 мм, щоб
    зшити пунктир штриха), яка одночасно:
      * велика: менша сторона габариту >= 14 мм, площа червоного >= 25 мм2 (пил і
        окремі літери відпадають);
      * ТОНКА: «товстих» пікселів (відстань до краю плями > 0,8 мм) <= 2 %, а 90-й
        перцентиль пів-товщини <= 0,6 мм (справжні хрести 2319/10: 0 % і 0,28 мм;
        друковані плашки, заливки, малюнки — 3-79 % і 0,5-10,8 мм);
      * складається з ДОВГИХ прямих: не менше 3 відрізків Хафа >= 12 мм (не по осях),
        що суцільно лежать на червоному (>= 85 % довжини має червоне в смузі 2,4 мм),
        і на них припадає >= 60 % червоного зони (хрести 2319/10: 89-95 %; друкований
        червоний текст: 0-19 %).
    Усередині зони маска — червоні пікселі в 1,2 мм від таких відрізків. Друковане
    червоне без довгих тонких штрихів маски не дає."""
    px = dpi / 25.4
    im = rgb.astype(np.int16)
    red = im[..., 0] - np.maximum(im[..., 1], im[..., 2])
    core = (red > core_thr).astype(np.uint8)
    wide = (red > wide_thr).astype(np.uint8)
    h, w = core.shape
    mask = np.zeros((h, w), np.uint8)
    if core.sum() < 50:
        return mask, 0
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (int(3.0 * px) | 1, int(3.0 * px) | 1))
    closed = cv2.morphologyEx(wide, cv2.MORPH_CLOSE, k)
    n, lab, st, _ = cv2.connectedComponentsWithStats(closed, connectivity=8)
    if n <= 1:
        return mask, 0
    dt = None
    nz = 0
    lines_all = np.zeros((h, w), np.uint8)
    zone_all = np.zeros((h, w), np.uint8)
    r_cov = int(1.2 * px)
    for i in range(1, n):
        x, y, cw, ch, _a = st[i]
        if min(cw, ch) < min_side_mm * px:
            continue
        sel = (lab[y:y + ch, x:x + cw] == i) & (wide[y:y + ch, x:x + cw] > 0)
        area = int(sel.sum())
        if area < min_area_mm2 * px * px:
            continue
        # товщина: відстань від пікселя червоного до найближчого не червоного
        sub = np.pad(sel.astype(np.uint8), 1)
        d = cv2.distanceTransform(sub, cv2.DIST_L2, 3)[1:-1, 1:-1][sel] / px
        if (d > 0.8).mean() > max_thick or np.percentile(d, 90) > max_p90_mm:
            continue
        csub = (core[y:y + ch, x:x + cw] * sel).astype(np.uint8)
        seg = cv2.HoughLinesP(csub * 255, 1, np.pi / 720, threshold=int(4 * px),
                              minLineLength=int(minlen * px), maxLineGap=int(4 * px))
        if seg is None:
            continue
        wsub = sel.astype(np.uint8)
        good = np.zeros((ch, cw), np.uint8)
        nl = 0
        for (x1, y1, x2, y2) in np.asarray(seg).reshape(-1, 4):   # cv2 4.x: (N,1,4), 5.x: (N,4)
            ang = abs(np.degrees(np.arctan2(y2 - y1, x2 - x1))) % 180
            if min(ang, abs(ang - 90), abs(ang - 180)) < 5.0:
                continue
            steps = max(int(np.hypot(x2 - x1, y2 - y1) / (0.5 * px)), 2)
            hits = 0
            for t in np.linspace(0, 1, steps):
                cx_ = int(x1 + (x2 - x1) * t)
                cy_ = int(y1 + (y2 - y1) * t)
                if wsub[max(0, cy_ - r_cov):cy_ + r_cov + 1, max(0, cx_ - r_cov):cx_ + r_cov + 1].any():
                    hits += 1
            if hits / float(steps) >= 0.85:
                cv2.line(good, (int(x1), int(y1)), (int(x2), int(y2)), 255, int(2.4 * px))
                nl += 1
        if nl < min_lines:
            continue
        share = float(((good > 0) & (wsub > 0)).sum()) / max(area, 1)
        if share < min_line_share:
            continue
        lines_all[y:y + ch, x:x + cw] |= good
        zone_all[y:y + ch, x:x + cw] |= wsub
        nz += 1
    if not nz:
        return mask, 0
    m = (lines_all > 0) & (zone_all > 0)
    mask = cv2.dilate(m.astype(np.uint8) * 255,
                      cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (int(1.2 * px) | 1, int(1.2 * px) | 1)))
    return mask, nz


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--dpi", type=float, default=300.0)
    ap.add_argument("--core", type=int, default=40)
    ap.add_argument("--wide", type=int, default=18)
    ap.add_argument("--minlen", type=float, default=12.0)
    a = ap.parse_args()
    px = a.dpi / 25.4
    rgb = np.asarray(Image.open(a.src).convert("RGB"))
    mask, nseg = pen_mask(rgb, a.dpi, a.core, a.wide, a.minlen)
    Image.fromarray(mask).save(a.out)
    area_mm2 = float((mask > 0).sum()) / (px * px)
    print("зон ручки %d; маска %d px = %.0f мм2" % (nseg, int((mask > 0).sum()), area_mm2))


if __name__ == "__main__":
    main()
