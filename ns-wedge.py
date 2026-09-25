# -*- coding: utf-8 -*-
"""Скільки пікселів треба зняти з кожного боку, щоб край був прямий і без білого клина.

  python ns-wedge.py <png> <x> <y> <w> <h>

Викликається з ns-render.ps1 для кожної сторінки ПІСЛЯ вирізання брудного краю.
Після випрямлення перекосу (ns-prep, -deskew) полотно розширюється білими
клинами, і край паперу йде навскіс на 0,3-7 мм: клин зливається з білою рамкою, і
рамка виглядає нерівною (оператор 24.09.2026: «рамка повинна бути однакова з усіх
чотирьох сторін»).

Що робить: шукає найбільший осьовий прямокутник без білого клина. Білим вважається
блок 4x4, у якому ВСІ пікселі >= 254 (чисте біле). Кожна з чотирьох меж клина — пряма (сторона
повернутого аркуша): вона вимірюється по середніх 60 % довжини (кути зіпсовані клином
сусіднього боку) і підбирається методом найменших квадратів; потім 6 кіл: зсув кожної
межі береться в кінцях вже зменшеного прямокутника. Перша версія, що міряла глибину в
25 місцях уздовж краю, у крайніх місцях бачила повністю білі рядки клина й знімала
12,6 мм замість 0-3 (2319/2, 24.09.2026); друга (перший небілий піксель у рядку) —
теж, бо кутові рядки задають межу.

Запобіжник: скільки б не вийшло, з кожного боку знімається не більше 3 % розміру
(і не більше 8 мм) — світла сторінка, де ВЕСЬ папір > 250, не має з'їстися.
Вивід: чотири цілі числа  ліво право верх низ  (пікселі). Нічого не пише.
"""
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
BLK = 4


def main():
    path = sys.argv[1]
    x, y, w, h = (int(v) for v in sys.argv[2:6])
    dpi = float(sys.argv[6]) if len(sys.argv) > 6 else 300.0
    g = np.asarray(Image.open(path).convert("L"))[y:y + h, x:x + w]
    hh, ww = (g.shape[0] // BLK) * BLK, (g.shape[1] // BLK) * BLK
    # Клин — це ЧИСТЕ біле (255): усі 16 пікселів блоку >= 254. Папір, навіть світлий і
    # підрізаний балансом, має зерно, тож у блоці завжди є піксель темніший (2318/9:
    # середня яскравість блоків паперу біля краю > 250 — перша версія з порогом на
    # СЕРЕДНЄ приймала його за клин і знімала 8 мм замість 1).
    b = g[:hh, :ww].reshape(hh // BLK, BLK, ww // BLK, BLK).min(axis=(1, 3))
    nonwhite = b < 254                                     # блокова карта: True = не клин
    bh, bw = nonwhite.shape
    # Межі клина — прямі лінії (сторона повернутого аркуша). Кожну вимірюємо лише по
    # середніх 60 % довжини (кути зіпсовані клином сусіднього боку) і підбираємо
    # пряму методом найменших квадратів; далі лінія екстраполюється до країв.
    def line(first, n):
        idx = np.arange(int(n * 0.2), int(n * 0.8))
        v = first[idx].astype(float)
        keep = np.abs(v - np.median(v)) <= max(6.0, 3 * np.std(v))      # відкидаємо викиди
        if keep.sum() < 10:
            return (0.0, float(np.median(v)))
        k, c = np.polyfit(idx[keep], v[keep], 1)
        return (float(k), float(c))

    any_r = nonwhite.any(axis=1)
    fx = np.where(any_r, nonwhite.argmax(axis=1), 0)                      # перший небілий зліва
    lx = np.where(any_r, bw - 1 - nonwhite[:, ::-1].argmax(axis=1), bw - 1)   # останній небілий
    any_c = nonwhite.any(axis=0)
    fy = np.where(any_c, nonwhite.argmax(axis=0), 0)
    ly = np.where(any_c, bh - 1 - nonwhite[::-1, :].argmax(axis=0), bh - 1)
    kL, cL = line(fx, bh)
    kR, cR = line(bw - 1 - lx, bh)                       # глибина від правого краю
    kT, cT = line(fy, bw)
    kB, cB = line(bh - 1 - ly, bw)                       # глибина від нижнього краю
    xl = lambda y: kL * y + cL
    xr = lambda y: kR * y + cR
    yt = lambda x: kT * x + cT
    yb = lambda x: kB * x + cB
    L = R = T = B = 0.0
    for _ in range(6):
        L = max(0.0, xl(T), xl(bh - 1 - B))
        R = max(0.0, xr(T), xr(bh - 1 - B))
        T = max(0.0, yt(L), yt(bw - 1 - R))
        B = max(0.0, yb(L), yb(bw - 1 - R))
    # 1 блок запасу (~0,3 мм) на нерівність краю
    x0, x1 = int(np.ceil(L)) + (1 if L > 0 else 0), bw - (int(np.ceil(R)) + (1 if R > 0 else 0))
    y0, y1 = int(np.ceil(T)) + (1 if T > 0 else 0), bh - (int(np.ceil(B)) + (1 if B > 0 else 0))
    px_mm = dpi / 25.4
    cap_w = int(min(0.03 * w, 8.0 * px_mm))
    cap_h = int(min(0.03 * h, 8.0 * px_mm))
    l = min(x0 * BLK, cap_w)
    r = min((bw - x1) * BLK + (g.shape[1] - ww), cap_w)
    t = min(y0 * BLK, cap_h)
    bt = min((bh - y1) * BLK + (g.shape[0] - hh), cap_h)
    print("%d %d %d %d" % (l, r, t, bt))


if __name__ == "__main__":
    main()
