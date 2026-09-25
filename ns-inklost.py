# -*- coding: utf-8 -*-
r"""Чи не втрачено друк між двома render однієї сторінки (було / стало).

  python ns-inklost.py <тека render А (було)> <тека render Б (стало)>

Для кожної пари pNN.jpg: шукає зсув Б відносно А (шаблон із центру Б на зменшеній копії,
потім уточнення на повному розмірі). Коефіцієнт збігу >= 0,98 — чистий зсув (без
масштабу): тоді все, що є в А і чого немає в Б (смуги по краях), перевіряється на
ТЕМНІ пікселі (< 130) — це і є втрачений друк. Менший збіг — стиснення/розтягнення
(render масштабує до 4 %): такі сторінки лише позначаються. Кількість темних пікселів у
всій сторінці для цього НЕ годиться: масштаб змінює їх на 5-10 % без жодної втрати.
Нічого не змінює.
"""
import glob
import os
import sys

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None
MM = 300 / 25.4


def main():
    da, db = sys.argv[1], sys.argv[2]
    lost_total = 0
    for f in sorted(glob.glob(os.path.join(db, "p[0-9][0-9].jpg"))):
        b = os.path.basename(f)
        fo = os.path.join(da, b)
        if not os.path.exists(fo):
            continue
        O = np.asarray(Image.open(fo).convert("L"))
        N = np.asarray(Image.open(f).convert("L"))
        ho, wo = O.shape
        hn, wn = N.shape
        s = 4
        On = cv2.resize(O, (wo // s, ho // s), interpolation=cv2.INTER_AREA)
        best = (-1.0, 1.0, 1.0, (0, 0))          # збіг, масштаб X, масштаб Y, положення шаблона
        for sx in np.arange(0.96, 1.0401, 0.005):       # нове = старе * sx: шукаємо, скільки в старому на 1 піксель нового
            for sy in (sx,):
                Nn = cv2.resize(N, (max(int(wn / s * sx), 8), max(int(hn / s * sy), 8)), interpolation=cv2.INTER_AREA)
                ty0, ty1 = int(Nn.shape[0] * 0.35), int(Nn.shape[0] * 0.65)
                tx0, tx1 = int(Nn.shape[1] * 0.35), int(Nn.shape[1] * 0.65)
                tpl = Nn[ty0:ty1, tx0:tx1]
                if tpl.shape[0] >= On.shape[0] or tpl.shape[1] >= On.shape[1]:
                    continue
                res = cv2.matchTemplate(On, tpl, cv2.TM_CCOEFF_NORMED)
                _, mx, _, loc = cv2.minMaxLoc(res)
                if mx > best[0]:
                    best = (mx, sx, sy, (loc[0] - tx0, loc[1] - ty0))
        mx, sx, sy, (ox, oy) = best
        if mx < 0.9:
            print("%s  збіг лише %.3f — не вдалося зіставити" % (b[:3], mx))
            continue
        # sx — це зменшення нового відносно того, що охоплює той самий вміст у старому
        # (нове більше в 1/sx разів)? Ми зменшували НОВЕ до розміру старого: sx = стара_довжина/нова_довжина
        # ⇒ нове охоплює в старому ділянку [ox*s, ox*s + wn*sx)
        dx, dy = ox * s, oy * s
        cw_old = wn * sx
        ch_old = hn * sy
        mask = np.ones(O.shape, bool)
        mask[max(int(dy), 0):max(int(dy + ch_old), 0), max(int(dx), 0):max(int(dx + cw_old), 0)] = False
        lost = int(((O < 130) & mask).sum())
        removed = "л%.1f п%.1f в%.1f н%.1f" % (dx / MM, (wo - dx - cw_old) / MM, dy / MM, (ho - dy - ch_old) / MM)
        lost_total += lost
        print("%s  збіг %.3f, масштаб нового %.3f, знято з краю (мм) %s: темних пікселів втрачено %d%s"
              % (b[:3], mx, 1.0 / sx, removed, lost, "  <<<" if lost > 300 else ""))
        continue
        lost = int(((O < 130) & mask).sum())
        removed = "л%.1f п%.1f в%.1f н%.1f" % (dx / MM, (wo - dx - wn) / MM, dy / MM, (ho - dy - hn) / MM)
        # у новому може бути й ДОДАНЕ (рамка більша) — нас цікавить лише втрата
        lost_total += lost
        print("%s  чистий зсув (збіг %.3f, залишкова різниця %.2f), знято з краю (мм) %s: темних пікселів втрачено %d%s"
              % (b[:3], mx, d, removed, lost, "  <<<" if lost > 200 else ""))
    print("усього втрачено темних пікселів на сторінках із чистим зсувом: %d" % lost_total)


if __name__ == "__main__":
    main()
