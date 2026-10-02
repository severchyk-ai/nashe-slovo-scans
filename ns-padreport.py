# -*- coding: utf-8 -*-
"""Звіт номера після ns-render -PaperPad (доповнення папером): числа для проби стандарту (02.10.2026).

  python ns-padreport.py <тека render> [--masks <тека масок>] [--tmp <ns_render_N від -KeepTmp>] [--top 3]

Читає _paperpad.json (пише ns-paperpad.py) і готові pNN.jpg; нічого не змінює.
На сторінку:
  доп.      — скільки паперу додано з кожного боку, мм (L R T B);
  темних    — пікселів у доданому, темніших за тон поля на 30+ (перенесений друк; має бути 0);
  рампа     — по боках: медіана довжини рампи, мм, і частка шва, де вона коротша за 3 мм, %;
  шов       — ns-seamprofile на JPEG, смуги від −1 до +6 мм від шва, відрізки 15 мм: найбільша сходинка
              |dL*| між СУСІДНІМИ смугами — медіана за відрізками / 90-й перцентиль (найгірші місця),
              і найбільша сходинка дрібного зерна, |log2|. Смуга впритул до рамки не береться (дзвін JPEG).
              Маска — pNN_seam0.png (шов до рампи: край аркуша після зрізу бруду), якщо є; інакше
              pNN_synth.png (середина рампи).
З --tmp (тека з PNG після балансу і pNN_pp.png) — звірка «масштаб 0»: кожен піксель справжнього поза
зоною рампи має бути тим самим, що у вхідному PNG (зсув цілий, без перерахунку); друк (темні пікселі)
не змінено ніде поза доданим.
  ШУМ       — сторінка, де латок справжнього паперу не знайшлося (< 20): доданий залито шумом, без рампи
              (2305/1, 2322/7 у пробі 02.10.2026) — такі сторінки дивитися очима.
Підсумок: шум, малий пул латок, темних, рамп коротших за 3 мм на > 50 % шва, найгірші шви (--top), змінено поза рампою.
Для порівняння — зразок, схвалений оператором 02.10.2026 (latky3, 2277/7 T): сходинка |dL*| 0,35 / 0,83,
дрібне зерно 0,10.
"""
import argparse
import glob
import importlib.util
import io
import json
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
HERE = os.path.dirname(os.path.abspath(__file__))


def load_seamprofile():
    spec = importlib.util.spec_from_file_location("ns_seamprofile", os.path.join(HERE, "ns-seamprofile.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def seam_scores(sp, rgb, synth):
    """{бік: (сходинка dL* мед., 90-й перц., сходинка дрібного зерна мед., відрізків)} для боків, де є шов."""
    out = {}
    res = sp.measure(rgb, synth, "LRTB")
    lo = [i for i, b in enumerate(sp.BANDS) if b[0] >= -1.0]          # пари смуг від −1 мм і глибше
    for s, r in res.items():
        if "med" not in r:
            continue
        valid = ~np.isnan(r["med"][:, 0])
        if valid.sum() < 4 or not valid[[i for i, b in enumerate(sp.BANDS) if b[1] <= 0]].any():
            continue                                                 # доданого на цьому боці немає
        first = int(np.argmax(valid))                                # смуга впритул до рамки
        pairs = [i for i in lo[:-1] if i > first and i < len(sp.BANDS) - 1]
        with np.errstate(all="ignore"):
            mL, pL, mF = (np.array([r[k][i] for i in pairs], float) for k in ("mL", "pL", "mF"))
        if np.all(np.isnan(mL)):
            continue
        out[s] = (float(np.nanmax(mL)), float(np.nanmax(pL)), float(np.nanmax(mF)), r["nseg"])
    return out


def scale_check(job_page, rec, tmp, dpi, fm, synth_out):
    """Справжні пікселі: скільки змінено всього, далі 5,2 мм від маски доданого і серед темних (друк)."""
    mm = dpi / 25.4
    src = np.array(Image.open(job_page["png"]).convert("RGB"))
    x, y, w, h = job_page["crop"]
    src = src[y:y + h, x:x + w]
    out = np.array(Image.open(os.path.join(tmp, rec["page"] + "_pp.png")).convert("RGB"))
    out = out[fm:out.shape[0] - fm, fm:out.shape[1] - fm]
    th, tw = out.shape[:2]
    ax, ay = -int(round(rec["pad_mm"]["L"] * mm)), -int(round(rec["pad_mm"]["T"] * mm))
    sx0, sy0, sx1, sy1 = max(0, ax), max(0, ay), min(w, ax + tw), min(h, ay + th)
    dx0, dy0 = sx0 - ax, sy0 - ay
    a = src[sy0:sy1, sx0:sx1]
    b = out[dy0:dy0 + sy1 - sy0, dx0:dx0 + sx1 - sx0]
    syn = synth_out[dy0:dy0 + sy1 - sy0, dx0:dx0 + sx1 - sx0]
    diff = (a != b).any(axis=2) & ~syn
    # рампа — 5 мм від доданого (маска synth його містить): далі 5,2 мм не може бути змінено нічого
    far = cv2.distanceTransform((~syn).astype(np.uint8), cv2.DIST_L2, 5) > 5.2 * mm
    lum = a.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    dark = lum < np.percentile(lum, 90) - 40
    return int(diff.sum()), int((diff & far).sum()), int((diff & dark).sum()), int((~syn).sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("render")
    ap.add_argument("--masks", default="")
    ap.add_argument("--tmp", default="")
    ap.add_argument("--top", type=int, default=3)
    a = ap.parse_args()
    rep = json.load(io.open(os.path.join(a.render, "_paperpad.json"), encoding="utf-8"))
    dpi, fm = rep["dpi"], rep["frame_px"]
    mm = dpi / 25.4
    sp = load_seamprofile() if a.masks else None
    job = None
    if a.tmp:
        job = {p["name"]: p for p in json.load(io.open(os.path.join(a.tmp, "_paperpad_job.json"), encoding="utf-8-sig"))["pages"]}
    seams, short, dark_tot, far_tot, ink_tot, chg_tot, real_tot = [], [], 0, 0, 0, 0, 0
    noise, small = [], []
    kind = None
    print(a.render)
    print("стор.  доп. L/R/T/B, мм        темних  рампа мед., мм (частка < 3 мм, %)          шов: |dL*| мед./90-й, зерно")
    for rec in sorted(rep["pages"], key=lambda r: r["page"]):
        n = rec["page"]
        pad = rec["pad_mm"]
        dark = rec.get("synth_dark_px", 0)
        dark_tot += dark
        gp = rec.get("grain_patch") or {}
        ramp = gp.get("ramp") or {}
        if rec.get("grain_fallback") or (gp and "patches_placed" not in gp):
            noise.append("%s (джерел %d)" % (n, gp.get("patches_src", 0)))
        elif gp.get("patches_src", 10 ** 9) < 200:
            small.append("%s латок %d на %d місць%s" % (n, gp["patches_src"], gp["patches_placed"], ", сходинка %d" % gp["pool_level"] if gp.get("pool_level") else ""))
        rtxt = " ".join("%s %.1f (%.0f)" % (s, ramp[s]["ramp_med_mm"], ramp[s]["under_3mm_pct"]) for s in "LRTB" if s in ramp)
        for s in "LRTB":
            if s in ramp and ramp[s]["under_3mm_pct"] > 50:
                short.append("%s %s (%.1f мм, %.0f %%)" % (n, s, ramp[s]["ramp_med_mm"], ramp[s]["under_3mm_pct"]))
        stxt = ""
        synth = None
        if a.masks:
            mf = os.path.join(a.masks, n + "_seam0.png")
            k = "шов до рампи"
            if not os.path.exists(mf):
                mf, k = os.path.join(a.masks, n + "_synth.png"), "середина рампи"
            if os.path.exists(mf):
                kind = k
                synth = np.array(Image.open(mf).convert("L")) > 127
                rgb = np.array(Image.open(os.path.join(a.render, n + ".jpg")).convert("RGB"))
                sc = seam_scores(sp, rgb, synth)
                for s, v in sc.items():
                    seams.append((v[1], v[0], v[2], n, s))
                stxt = " ".join("%s %.2f/%.2f, %.2f" % (s, v[0], v[1], v[2]) for s, v in sc.items())
        ctxt = ""
        if job and n in job:
            mo = os.path.join(a.masks, n + "_synth.png") if a.masks else ""
            if mo and os.path.exists(mo):
                so = np.array(Image.open(mo).convert("L")) > 127
                so = so[fm:so.shape[0] - fm, fm:so.shape[1] - fm]
                c, far, ink, real = scale_check(job[n], rec, a.tmp, dpi, fm, so)
                chg_tot += c
                far_tot += far
                ink_tot += ink
                real_tot += real
                ctxt = "  змінено справжнього %.0f мм², далі 5,2 мм від доданого %d пікс., темних %d" % (c / mm / mm, far, ink)
        print("%s    %+5.1f %+5.1f %+5.1f %+5.1f   %5d   %-44s %s%s"
              % (n, pad["L"], pad["R"], pad["T"], pad["B"], dark, rtxt or "-", stxt or "-", ctxt))
    print("")
    print("сторінок: %d; темних у доданому: %d пікс." % (len(rep["pages"]), dark_tot))
    print("ЗАЛИТО ШУМОМ (латок паперу немає, рампи немає): %s" % ("; ".join(noise) if noise else "немає"))
    print("НА ОГЛЯД — малий пул латок (< 200): %s" % ("; ".join(small) if small else "немає"))
    print("рампа коротша за 3 мм на > 50 %% шва: %s" % ("; ".join(short) if short else "немає"))
    if seams:
        seams.sort(reverse=True)
        print("найгірші шви (маска — %s; |dL*| мед./90-й перц., дрібне зерно |log2|): %s"
              % (kind, "; ".join("%s %s %.2f/%.2f, %.2f" % (n, s, m, p, f) for p, m, f, n, s in seams[:a.top])))
        print("медіана по %d боках: |dL*| %.2f/%.2f, зерно %.2f"
              % (len(seams), np.median([x[1] for x in seams]), np.median([x[0] for x in seams]), np.median([x[2] for x in seams])))
    if job:
        print("масштаб: справжніх пікселів %d, змінено %d (%.2f %%, рампа); далі 5,2 мм від доданого змінено %d; темних (друк) змінено %d"
              % (real_tot, chg_tot, 100.0 * chg_tot / max(1, real_tot), far_tot, ink_tot))


if __name__ == "__main__":
    main()
