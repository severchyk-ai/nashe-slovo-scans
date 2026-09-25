# -*- coding: utf-8 -*-
"""Постійний працівник швидкого показу (24.09.2026).

Навіщо: показ сторінки на другому моніторі мав ~0,85 с, з них ~0,7 с --
запуск ImageMagick і декодування 65 МБ TIFF (LZW, один смуговий блок --
паралельно не розпакувати). Тут процес живе увесь сеанс сканування: PIL і
numpy уже завантажені, тож лишається сама розпаковка (~0,37 с) і зменшення.

Обмін через файли в теці NS_WORK\\_live (без сокетів):
  req.json   {"id": N, "tif": "шлях"}      -- пише ns-scan (Show-NsLiveFast)
  resp.json  {"id": N, "mean": m, "sd": s, "secs": t}   -- пишу я
  preview.jpg -- зменшена сторінка 1080x1600 (пишу через .tmp і os.replace)
mean/sd -- середнє й розкид сірого 0..1, як `%[fx:mean]` у ImageMagick:
за ними ns-scan відсіює порожній/чорний кадр.

Завершується, коли зникає батьківський процес (ns-scan) або з'являється
stop.flag. Якщо працівник не відповів, Show-NsLiveFast бере ImageMagick як раніше.
"""
import json
import os
import sys
import time

from PIL import Image
import numpy as np

live = sys.argv[1]
parent = int(sys.argv[2]) if len(sys.argv) > 2 else 0
req_p = os.path.join(live, "req.json")
resp_p = os.path.join(live, "resp.json")
prev_p = os.path.join(live, "preview.jpg")
stop_p = os.path.join(live, "stop.flag")
BOX = (1080, 1600)


def parent_alive(pid):
    if not pid:
        return True
    import ctypes
    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED
    if not h:
        return False
    code = ctypes.c_ulong()
    ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
    ctypes.windll.kernel32.CloseHandle(h)
    return code.value == 259  # STILL_ACTIVE


def work(tif):
    t0 = time.time()
    with Image.open(tif) as im:
        im.seek(0)
        im.load()
        w, h = im.size
        k = min(BOX[0] / w, BOX[1] / h)
        size = (max(1, round(w * k)), max(1, round(h * k)))
        f = 4  # цілочисельне зменшення дешеве, тоді доточуємо до потрібного розміру
        small = im.reduce(f) if im.mode in ("RGB", "L") else im.convert("RGB").reduce(f)
        small = small.resize(size, Image.BILINEAR)
    rgb = small if small.mode == "RGB" else small.convert("RGB")
    tmp = prev_p + ".tmp"
    rgb.save(tmp, "JPEG", quality=88)
    os.replace(tmp, prev_p)
    g = np.asarray(rgb.convert("L"), dtype=np.float32) / 255.0
    return float(g.mean()), float(g.std()), time.time() - t0


# прогрів: імпорти вже зроблено, лишається прогріти JPEG/ресайз
try:
    Image.new("RGB", (64, 64)).resize((32, 32), Image.BILINEAR)
except Exception:
    pass

last_id = None
while True:
    if os.path.exists(stop_p) or not parent_alive(parent):
        break
    try:
        with open(req_p, "r", encoding="utf-8-sig") as fh:
            req = json.load(fh)
    except Exception:
        req = None
    if req and req.get("id") != last_id:
        last_id = req["id"]
        try:
            m, s, secs = work(req["tif"])
            out = {"id": last_id, "mean": m, "sd": s, "secs": secs}
        except Exception as e:
            out = {"id": last_id, "error": str(e)}
        tmp = resp_p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(out, fh)
        os.replace(tmp, resp_p)
        continue
    time.sleep(0.01)
