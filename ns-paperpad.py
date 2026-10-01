# -*- coding: utf-8 -*-
"""Спільний розмір сторінок номера БЕЗ МАСШТАБУ: доповнення газетним папером.

  python ns-paperpad.py <job.json>

Викликає ns-render.ps1 -PaperPad. Рішення оператора 29.09.2026: «текст не
змінювати взагалі — ні збільшувати, ні зменшувати; краще додати газетного
білого з того чи іншого боку, згори чи знизу, щоб заповнити й відцентрувати
сторінку»; брудний край — «не обрізати смужку, а заповнити до рамки газетним
білим».

Для кожної сторінки (PNG після балансу, 300 dpi, уже зрізаний край prep):
  1. КЛИН: чисто біле (>= 252 у всіх каналах), з'єднане з краєм, до 6 мм углиб —
     полотно після випрямлення.
  2. БРУД (крім боків, де page_edge — слово оператора): край ділиться на 20
     відрізків; у кожному від краю шукається перша чиста смуга паперу >= 1,5 мм
     (шари 0,25 мм: середнє >= папір-12 і темних < 2 %; клин — НЕ чистий, бо за
     ним ховається скло: 9304/3); усе до неї — бруд (скло, проколи, тінь обрізу).
     Глибина відрізка — не ближче 1,5 мм до друку в ньому і не глибше 8 мм;
     відрізок без чистої смуги до 12 мм (фото навиліт) — 0. Між відрізками —
     плавно (максимум сусідів, тоді лінійно).
     Клин і бруд ЗАЛИВАЮТЬСЯ папером на місці (не зрізаються): справжній папір
     лишається там, де він чистий. Перша версія різала прямокутником на
     найглибший відрізок — 9304/4, 6 втратили 6,1 мм чистого паперу через клин.
  3. ДРУК: «блок» — як у ns-margins.py (для центрування); «найближчий» — перший
     шар 0,5 мм із >= 15 % темних у будь-якому з 40 відрізків по всій довжині
     краю (ближче за нього + 1,5 мм чисте поле не зрізається).
Номер: ціль групи (книжкові/альбомні окремо) — ширина = більша з медіани ширин
і найширшого друку + 2 x 1,5 мм; висота так само. Кожна сторінка стає у вікно
цілі: по ширині блок друку ПОСЕРЕДИНІ (поля ліво = право), по висоті — зміна
полів порівну згори й знизу (пропорцію верх/низ газети не чіпаємо; center_v —
центрувати й по висоті). Лишок чистого поля зрізається, нестача — доповнюється.
Папір: тон — поле з блоків 3 мм (медіана світлих безбарвних пікселів справжнього
паперу), продовжене на невідоме; зерно — шум із розкидом і кореляцією каналів
паперу цієї сторінки. Далі біла рамка frame_px.
Міра шва (кожен бік окремо): додане в межах 2 мм від справжнього паперу проти
справжнього паперу в межах 2 мм від доданого — різниця середнього яскравості
(ціле і найбільша з 20 відрізків уздовж боку) і відношення розкиду (зерно).
Нічого, крім виходів у job, не пише.
"""
import json
import sys

import cv2
import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
Image.MAX_IMAGE_PIXELS = None

LW = np.array([0.299, 0.587, 0.114], np.float32)
NSEG = 20


def luma(a):
    return a.astype(np.float32) @ LW


def side_view(arr, side):
    """Вісь 0 — уздовж краю, вісь 1 — углиб (0 = край)."""
    if side == "L":
        return arr
    if side == "R":
        return arr[:, ::-1]
    if side == "T":
        return np.swapaxes(arr, 0, 1)
    return np.swapaxes(arr[::-1, :], 0, 1)


def layer_stats(v, step, nseg, lo, hi, dark_thr, nlayers):
    """Середнє й частка темних по відрізках x шарах; повертає й межі відрізків."""
    n = v.shape[0]
    a, b = int(n * lo), int(n * hi)
    v = v[a:b, :nlayers * step]
    segs = np.array_split(np.arange(v.shape[0]), nseg)
    mean = np.zeros((nseg, nlayers), np.float32)
    dark = np.zeros((nseg, nlayers), np.float32)
    for i, s in enumerate(segs):
        blk = v[s[0]:s[-1] + 1].reshape(len(s), nlayers, step)
        mean[i] = blk.mean(axis=(0, 2))
        dark[i] = (blk < dark_thr).mean(axis=(0, 2))
    centers = np.array([a + (s[0] + s[-1]) / 2.0 for s in segs])
    return mean, dark, centers


def dirt_depths(img, wedge, dpi, forced, fill, P):
    """Глибина бруду вздовж кожного краю, пікс. (масив довжини краю), і числа для звіту.
    Бік зі словом оператора (forced) не заливається, крім названих у fill (fill_edge маніфеста:
    «не різати, а заповнити до рамки», 2280). Чистота шару — ВІДНОСНО ТЛА свого відрізка
    (75-й перцентиль яскравості шарів глибше 2 мм, без клину), а не тону паперу: на синій
    плашці (2280/1 зліва) «папір-12» не досягався ніде, і бруд там не знаходився б."""
    mm = dpi / 25.4
    Ln = luma(img)
    Ln[wedge] = np.nan
    out, rep = {}, {}
    for s in "LRTB":
        v = side_view(Ln, s)
        n = v.shape[0]
        if s in forced and s not in fill:
            out[s] = np.zeros(n, np.float32)
            rep[s] = {"max_mm": 0.0, "segs": 0, "forced": True}
            continue
        st = max(1, int(round(0.25 * mm)))
        nl = min(int(12 * mm) // st, v.shape[1] // st)
        run = int(np.ceil(1.5 * mm / st))
        j2 = int(2 * mm / st)
        a0, a1 = int(n * 0.02), int(n * 0.98)
        segs = np.array_split(np.arange(a0, a1), NSEG)
        cen = np.array([(q[0] + q[-1]) / 2.0 for q in segs])
        d = np.zeros(NSEG, np.float32)
        refs = []
        for i, q in enumerate(segs):
            blk = v[q[0]:q[-1] + 1, :nl * st].reshape(len(q), nl, st)
            isw = np.isnan(blk)
            wf = isw.mean(axis=(0, 2))
            with np.errstate(all="ignore"):
                mean_l = np.nanmean(blk, axis=(0, 2))
            deep = mean_l[j2:]
            deep = deep[~np.isnan(deep)]
            if deep.size == 0:
                continue
            ref = float(np.percentile(deep, 75))
            refs.append(ref)
            # сам по собі бруд заливається лише на ПАПЕРІ; тло-плашку — лише за словом оператора
            # (fill_edge). 2296/1 знизу без цього залито 6,3 мм біля плашки й фото (шов 32 од.)
            if s not in fill and ref < P - 15:
                continue
            nw = np.maximum(1, (~isw).sum(axis=(0, 2)))
            dark_l = np.where(isw, False, blk < ref - 45).sum(axis=(0, 2)) / nw
            prn_l = np.where(isw, False, blk < ref - 70).sum(axis=(0, 2)) / nw
            clean = (wf < 0.05) & (np.abs(np.nan_to_num(mean_l, nan=-999) - ref) < 12) & (dark_l < 0.02)
            j0 = None
            for j in range(0, nl - run):
                if clean[j:j + run].all():
                    j0 = j
                    break
            if j0 is None or j0 == 0:
                continue
            hit = np.nonzero(prn_l >= 0.15)[0]
            hit = hit[hit >= j0 + run]
            pf = (hit[0] if hit.size else nl) * st
            d[i] = min(j0 * st, pf - 1.5 * mm, 8 * mm)
        d = np.maximum(d, 0)
        dm = d.copy()
        dm[1:] = np.maximum(dm[1:], d[:-1])
        dm[:-1] = np.maximum(dm[:-1], d[1:])
        out[s] = np.interp(np.arange(n), cen, dm).astype(np.float32)
        rep[s] = {"max_mm": round(float(d.max() / mm), 2), "segs": int((d > 0).sum()), "forced": s in forced,
                  "bg_min": round(float(min(refs)), 1) if refs else None}
    return out, rep


def band_mask(shape, depths):
    """Маска: від кожного краю на глибину depths[s][t]."""
    H, W = shape
    m = np.zeros(shape, bool)
    xs, ys = np.arange(W)[None, :], np.arange(H)[:, None]
    m |= xs < depths["L"][:, None]
    m |= (W - 1 - xs) < depths["R"][:, None]
    m |= ys < depths["T"][None, :]
    m |= (H - 1 - ys) < depths["B"][None, :]
    return m


def print_dist(L, dpi, P, depth_mm=60.0):
    """Блок (як ns-margins) і найближчий друк (min по 40 відрізках) від кожного краю, мм."""
    mm = dpi / 25.4
    step = max(1, int(round(0.5 * mm)))
    out = {}
    for s in "LRTB":
        v = side_view(L, s)
        nb = min(int(depth_mm * mm), v.shape[1]) // step
        n = v.shape[0]
        mid = v[int(n * 0.12):int(n * 0.88), :nb * step]
        frac = (mid < P - 70).reshape(mid.shape[0], nb, step).mean(axis=(0, 2))
        blk = nb
        for i in range(nb - 2):
            if (frac[i] >= 0.03 and frac[i + 1] >= 0.03 and frac[i + 2] >= 0.03) or frac[i] >= 0.05:  # або лінія: 9278/4 (29.09) — рамка колонки 51 %, 2296/8 — тонка лінія 8,8 %, шар 0,5 мм; три шари поспіль ловили її чи ні залежно від сітки
                blk = i
                break
        _, dk, _ = layer_stats(v, step, 40, 0.01, 0.99, P - 70, nb)
        firsts = [np.nonzero(dk[i] >= 0.15)[0] for i in range(40)]
        near = min([f[0] if f.size else nb for f in firsts])
        out[s] = (blk * step / mm, near * step / mm)
    return out


def _blur(a, sig):
    """Гаусове розмиття; для великого sigma — через зменшену копію (швидко)."""
    if sig <= 24:
        return cv2.GaussianBlur(a, (0, 0), sig)
    f = int(sig // 8)
    h, w = a.shape[:2]
    sm = cv2.resize(a, (max(1, w // f), max(1, h // f)), interpolation=cv2.INTER_AREA)
    sm = cv2.GaussianBlur(sm, (0, 0), sig / f)
    return cv2.resize(sm, (w, h), interpolation=cv2.INTER_LINEAR)


def paper_field(canvas, weight, mm, fallback, scales=(1.0, 3.0, 8.0, 25.0, 80.0)):
    """Тон паперу для доданого: зважене розмиття справжнього паперу (weight — чистий папір),
    від дрібного масштабу до великого — кожен піксель бере найдрібніший, де паперу досить.
    Біля шва тон — із найближчого паперу, тож градієнт краю аркуша (9304/5 знизу: 214 на
    1 мм -> 219 на 7 мм) продовжується. Перша версія брала блоки 3 мм: неповний останній
    ряд блоків брав тон вище, і додане знизу виходило на 1,5 од. світлішим."""
    H, W, _ = canvas.shape
    wt = weight.astype(np.float32)
    num_src = canvas.astype(np.float32) * wt[..., None]
    field = np.empty((H, W, 3), np.float32)
    done = np.zeros((H, W), bool)
    for sig_mm in scales:
        sig = sig_mm * mm
        ws = _blur(wt, sig)
        ok = (ws > 0.05) & ~done
        if ok.any():
            num = _blur(num_src, sig)
            field[ok] = num[ok] / ws[ok][:, None]
            done |= ok
        if done.all():
            break
    field[~done] = fallback
    return field


def grain_stats(img, mask, field):
    """Розкид кожного каналу паперу навколо поля (MAD) і середня кореляція каналів."""
    r = img[mask].astype(np.float32) - field[mask]
    if r.shape[0] < 1000:
        return np.array([1.5, 1.5, 1.5], np.float32), 0.8
    r = r - np.median(r, axis=0)
    sd = 1.4826 * np.median(np.abs(r), axis=0)
    ok = np.all(np.abs(r) < 4 * sd.max() + 1, axis=1)
    c = np.corrcoef(r[ok].T)
    rho = float(np.clip((c[0, 1] + c[0, 2] + c[1, 2]) / 3, 0, 0.99))
    return sd.astype(np.float32), rho


def nearest_side(H, W):
    """Найближчий край кожного пікселя: 0 L, 1 R, 2 T, 3 B."""
    xs = np.arange(W, dtype=np.int32)[None, :]
    ys = np.arange(H, dtype=np.int32)[:, None]
    dx = np.minimum(xs, W - 1 - xs)
    dy = np.minimum(ys, H - 1 - ys)
    sx = np.where(xs <= W - 1 - xs, 0, 1).astype(np.int8)
    sy = np.where(ys <= H - 1 - ys, 2, 3).astype(np.int8)
    return np.where(dx <= dy, sx, sy)


def clean_paper(canvas, synth, base, mm, ink_mm):
    """Чистий справжній папір аж до самого шва. paper_ok для цього не годиться: розкид рахується
    по полотну, де доданий ще чорний (0), і в ~1,3 мм від шва папір «не гладкий» — перша проба
    seam_tone через це не мала жодного пікселя (2277/7 B: сходинка +1,02 -> +0,73 лише від
    zero_mean). Тут доданий на час виміру замінено тоном поля. Умови: гладко (розкид < 4 після
    розмиття 0,5 мм у вікні 1,5 мм), у межах 12 від поля, не ближче ink_mm до чорнила (поле − 18)."""
    Lc, Lb = luma(canvas), luma(base)
    Ls = cv2.GaussianBlur(np.where(synth, Lb, Lc), (0, 0), 0.5 * mm)
    kk = int(1.5 * mm) | 1
    sdb = np.sqrt(np.maximum(0, cv2.blur(Ls * Ls, (kk, kk)) - cv2.blur(Ls, (kk, kk)) ** 2))
    ink = ~synth & (Lc < Lb - 18)
    d_ink = cv2.distanceTransform((~ink).astype(np.uint8), cv2.DIST_L2, 3)
    return ~synth & (sdb < 4) & (np.abs(Lc - Lb) < 12) & (d_ink >= ink_mm * mm)


def seam_tone(canvas, synth, paper_ok, base, mm):
    """Перехід на шві (оператор 01.10.2026: «світліша рівна смуга вздовж шва»). Справжній папір
    в останніх 1-2 мм перед швом має свій тон (тінь краю: 2277/7 B −0,9 L*, 2278/4 R −1,3 проти
    паперу 2-4 мм углиб), а поле 3 мм його не бачить — на шві сходинка. Тут: відхилення чистого
    паперу в 1 мм від шва від поля base, усереднене вздовж шва (σ 1,5 мм), продовжується в
    доданий і згасає на ~3 мм. Де біля шва чистого паперу немає (друк) — нуль."""
    d_syn = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 3)
    d_real = cv2.distanceTransform(synth.astype(np.uint8), cv2.DIST_L2, 3)
    w = (clean_paper(canvas, synth, base, mm, 0.75) & (d_syn <= 1.0 * mm)).astype(np.float32)
    sig = 1.5 * mm
    num = cv2.GaussianBlur((canvas.astype(np.float32) - base) * w[..., None], (0, 0), sig)
    den = cv2.GaussianBlur(w, (0, 0), sig)
    return num / (den + 0.005)[..., None] * np.exp(-d_real / (3.0 * mm))[..., None]


def grow_irregular(synth, clean, near, skip_sides, mm, rng):
    """Нерівна межа: доданий заходить у ЧИСТИЙ справжній папір на 0,2-1,2 мм (глибина — плавний
    шум, σ 0,8 мм), щоб шов не був прямою лінією. Лише clean (папір тону поля, не ближче 1,5 мм
    до чорнила); боки зі словом оператора (skip_sides) не чіпаються."""
    H, W = synth.shape
    d_syn = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 3)
    n = cv2.GaussianBlur(rng.normal(0, 1, (H, W)).astype(np.float32), (0, 0), 0.8 * mm)
    n /= max(1e-6, float(n.std()))
    depth = (0.2 + 1.0 * np.clip(0.5 + 0.35 * n, 0, 1)) * mm
    grow = ~synth & (d_syn <= depth) & clean
    for k in skip_sides:
        grow &= near != k
    return synth | grow


def ramp_alpha(canvas, synth, base, near, forced, pd, mm, ramp_mm, edge_mm):
    """Плавний шов (оператор 01.10.2026: «перехід значно-значно плавніший»). Повертає s1 (що замінити
    цілком), al (частка доданого 0..1 для кожного пікселя) і числа для звіту.
      * s1 = доданий + смужка edge_mm справжнього паперу вздовж шва: сам край аркуша (обріз, тінь, світла
        лінія) лишився б видним за будь-якого змішування. Смужка не береться, де ближче 1,5 мм є чорнило
        ГЛИБШЕ за неї (друк навиліт сягає вглиб і так себе видає), і на боках, де найближчий друк < 3 мм.
      * далі частка доданого сходить з 1 до 0 на ramp_mm, а де чистого поля менше — на стільки, скільки
        є: al = min(1 − d/ramp, dN/(d + dN)), d — відстань від s1, dN — до зони 1,5 мм навколо чорнила
        (будь-який канал темніший за поле на 22+: і чорний друк, і кольоровий). Перешкода — ЛИШЕ чорнило:
        перша версія брала «нечистий» за clean_paper (гладкість), і рампа виходила 1,0-2,3 мм (мед), у
        70-100 % шва коротша за 3 мм — просвіт звороту й цятки в полях рвали її. Рампа — smoothstep.
      * боки зі словом оператора (forced) — без смужки й без рампи."""
    H, W = synth.shape
    Lc, Lb = luma(canvas), luma(base)
    d0 = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 5)
    ink_deep = ~synth & (Lc < Lb - 18) & (d0 > edge_mm * mm)
    d_inkd = cv2.distanceTransform((~ink_deep).astype(np.uint8), cv2.DIST_L2, 5)
    strip = ~synth & (d0 <= edge_mm * mm) & (d_inkd >= 1.5 * mm)
    off = np.zeros((H, W), bool)
    for k, s in enumerate("LRTB"):
        if s in forced:
            off |= near == k
        elif pd[s][1] < 3.0:
            strip &= near != k
    strip &= ~off
    s1 = synth | strip
    inkp = ~s1 & (canvas.astype(np.float32) < base - 22).any(axis=2)
    d_inkp = cv2.distanceTransform((~inkp).astype(np.uint8), cv2.DIST_L2, 5)
    d1 = cv2.distanceTransform((~s1).astype(np.uint8), cv2.DIST_L2, 5)
    dn = np.maximum(0, d_inkp - 1.5 * mm)
    al = np.clip(np.minimum(1 - d1 / (ramp_mm * mm), dn / np.maximum(d1 + dn, 1e-3)), 0, 1)
    al[off] = 0
    al = al * al * (3 - 2 * al)
    al[s1] = 1
    info = {}
    seam_px = ~s1 & (d1 <= 1.5)
    for k, s in enumerate("LRTB"):
        m = seam_px & (near == k) & ~off
        if m.sum() >= 300:
            r = np.minimum(ramp_mm, dn[m] / mm)
            info[s] = {"ramp_med_mm": round(float(np.median(r)), 2), "ramp_p10_mm": round(float(np.percentile(r, 10)), 2),
                       "under_3mm_pct": round(100.0 * float((r < 3).mean()), 1),
                       "strip_pct": round(100.0 * float((strip & (near == k)).sum()) / max(1, int((~synth & (d0 <= edge_mm * mm) & (near == k)).sum())), 1)}
    return s1, al.astype(np.float32), info


def seam_metrics(canvas, synth, paper_ok, dpi):
    """По боках: додане в 2 мм від справжнього проти справжнього паперу в 2 мм від доданого."""
    mm = dpi / 25.4
    H, W = synth.shape
    r2 = 2 * mm
    d_to_real = cv2.distanceTransform(synth.astype(np.uint8), cv2.DIST_L2, 3)
    d_to_syn = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 3)
    a_m = synth & (d_to_real <= r2)
    b_m = (~synth) & paper_ok & (d_to_syn <= r2)
    L = luma(canvas)
    near = nearest_side(H, W)
    out = {}
    for k, s in enumerate("LRTB"):
        a_s, b_s = a_m & (near == k), b_m & (near == k)
        if a_s.sum() < 2000 or b_s.sum() < 2000:
            continue
        n = H if s in "LR" else W
        diffs = []
        for seg in np.array_split(np.arange(n), NSEG):
            if s in "LR":
                sa, sb = a_s[seg[0]:seg[-1] + 1], b_s[seg[0]:seg[-1] + 1]
                Ls = L[seg[0]:seg[-1] + 1]
            else:
                sa, sb = a_s[:, seg[0]:seg[-1] + 1], b_s[:, seg[0]:seg[-1] + 1]
                Ls = L[:, seg[0]:seg[-1] + 1]
            if sa.sum() > 200 and sb.sum() > 200:
                diffs.append(float(Ls[sa].mean() - Ls[sb].mean()))
        out[s] = {"dL": round(float(L[a_s].mean() - L[b_s].mean()), 2),
                  "dL_max": round(float(np.max(np.abs(diffs))) if diffs else 0.0, 2),
                  "sd_ratio": round(float(L[a_s].std() / max(0.1, L[b_s].std())), 2)}
    return out


def main():
    job = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    dpi = job["dpi"]
    mm = dpi / 25.4
    fm = int(job["frame_px"])
    frame_tone = int(job.get("frame_tone", 255))
    center_v = bool(job.get("center_v", False))
    min_px = int(round(1.5 * mm))
    rng = np.random.default_rng(int(job.get("seed", 0)))
    pages = []
    for p in job["pages"]:
        img = np.array(Image.open(p["png"]).convert("RGB"))
        x, y, w, h = p["crop"]
        img = img[y:y + h, x:x + w].copy()
        forced = set(p.get("forced", []))
        L0 = luma(img)
        H0, W0 = L0.shape
        P = float(np.percentile(L0[H0 // 4:3 * H0 // 4, W0 // 4:3 * W0 // 4], 90))
        white = np.all(img >= 252, axis=-1).astype(np.uint8)
        nl, lab = cv2.connectedComponents(white, 8)
        edge_ids = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
        wedge = np.isin(lab, list(edge_ids)) if edge_ids else np.zeros(white.shape, bool)
        d6 = int(6 * mm)
        band = np.zeros(white.shape, bool)
        band[:d6] = band[-d6:] = True
        band[:, :d6] = band[:, -d6:] = True
        wedge &= band
        depths, drep = dirt_depths(img, wedge, dpi, forced, set(p.get("fill", [])), P)
        synth0 = wedge | band_mask(L0.shape, depths)
        Lp = L0.copy()
        Lp[synth0] = P
        pd = print_dist(Lp, dpi, P)
        # cut_mm (job, на сторінку), напр. {"R": 7}: ПРЯМИЙ зріз боку на всю довжину — сліди зшивання на
        # корінці (тканина, клей, здертий шар: 2316/10 R). Оператор 01.10.2026: «просто обрізати, щоб
        # відцентрувати сторінку, але рамка має бути рівною» — нерівну межу здертого шару не обводити,
        # доданий папір має стикуватися вже з чистим. Не ближче 1,5 мм до найближчого друку.
        for s, cmm in (p.get("cut_mm") or {}).items():
            c_px = min(float(cmm), max(0.0, pd[s][1] - 1.5)) * mm
            depths[s] = np.maximum(depths[s], c_px).astype(np.float32)
            drep[s]["cut_mm"] = round(c_px / mm, 2)
        if p.get("cut_mm"):
            synth0 = wedge | band_mask(L0.shape, depths)
            Lp = L0.copy()
            Lp[synth0] = P
            pd = print_dist(Lp, dpi, P)
        # бік зі словом оператора (page_edge) — вікно цілі його НЕ зрізає: «найближчий друк» = 1,5 мм,
        # тож дозволений зріз там 0, а центрування доповнює з інших боків (2288/7: зведення висоти
        # по «чистому полю» зрізало червону ручку «Дати репліку!» — її детектор друку не бачить)
        for s in forced:
            pd[s] = (pd[s][0], min(pd[s][1], 1.5))
        pages.append(dict(name=p["name"], out=p["out"], img=img, synth0=synth0, P=P, forced=sorted(forced),
                          dirt=drep, pd=pd, w=W0, h=H0, land=W0 > H0,
                          wedge_px=int(wedge.sum()), dirt_px=int((synth0 & ~wedge).sum())))
    report = {"dpi": dpi, "frame_px": fm, "center_v": center_v, "pages": []}
    for land in (False, True):
        grp = [q for q in pages if q["land"] == land]
        if not grp:
            continue
        # поле 1,5 мм вимагається лише там, де між краєм і друком є папір; друк навиліт (найближчий
        # < 0,5 мм: плашка, фото до краю) поля не має — інакше 2296/1, 2 дістали смугу паперу навколо
        # плашок, а номер — +3 мм до спільного розміру
        def mpx(q, s):
            return 0 if q["pd"][s][1] < 0.5 else min_px
        need_w = max(q["w"] - int(q["pd"]["L"][1] * mm) - int(q["pd"]["R"][1] * mm) + mpx(q, "L") + mpx(q, "R") for q in grp)
        need_h = max(q["h"] - int(q["pd"]["T"][1] * mm) - int(q["pd"]["B"][1] * mm) + mpx(q, "T") + mpx(q, "B") for q in grp)
        tw = max(int(np.median([q["w"] for q in grp])), need_w)
        th = max(int(np.median([q["h"] for q in grp])), need_h)
        for q in grp:
            w, h, pd = q["w"], q["h"], q["pd"]
            bl, br = pd["L"][0] * mm, pd["R"][0] * mm
            ax = int(round((bl + (w - br)) / 2 - tw / 2))
            # друк навиліт на осі (плашка, фото до краю) — центр друку нічого не значить: центруємо
            # аркуш (2280: центр друку зсував сторінки на 4-6 мм і доклав папір біля плашок)
            # (рішення — за БЛОКОМ, середні 76 % боку: 2296/10 куточок синього підвалу справа дав
            # «найближчий друк 0» і зсунув сторінку на 5 мм)
            if pd["L"][0] < 0.5 or pd["R"][0] < 0.5:
                ax = int(round((w - tw) / 2))
            lo = int(w - pd["R"][1] * mm) + mpx(q, "R") - tw
            hi = int(pd["L"][1] * mm) - mpx(q, "L")
            ax_c = min(max(ax, lo), hi) if lo <= hi else ax
            if center_v and pd["T"][0] >= 0.5 and pd["B"][0] >= 0.5:
                bt, bb = pd["T"][0] * mm, pd["B"][0] * mm
                ay = int(round((bt + (h - bb)) / 2 - th / 2))
            else:
                ay = int(round((h - th) / 2))
            lo = int(h - pd["B"][1] * mm) + mpx(q, "B") - th
            hi = int(pd["T"][1] * mm) - mpx(q, "T")
            ay_c = min(max(ay, lo), hi) if lo <= hi else ay
            canvas = np.zeros((th, tw, 3), np.uint8)
            known = np.zeros((th, tw), bool)
            sx0, sy0 = max(0, ax_c), max(0, ay_c)
            sx1, sy1 = min(w, ax_c + tw), min(h, ay_c + th)
            dx0, dy0 = sx0 - ax_c, sy0 - ay_c
            canvas[dy0:dy0 + sy1 - sy0, dx0:dx0 + sx1 - sx0] = q["img"][sy0:sy1, sx0:sx1]
            known[dy0:dy0 + sy1 - sy0, dx0:dx0 + sx1 - sx0] = ~q["synth0"][sy0:sy1, sx0:sx1]
            synth = ~known
            rec = {"page": q["name"], "land": land, "target": [tw, th], "size": [w, h],
                   "dirt": q["dirt"], "forced": q["forced"], "wedge_px": q["wedge_px"], "dirt_px": q["dirt_px"],
                   "print_block_mm": {s: round(pd[s][0], 1) for s in "LRTB"},
                   "print_near_mm": {s: round(pd[s][1], 1) for s in "LRTB"},
                   "clamped": [ax_c != ax, ay_c != ay]}
            rec["pad_mm"] = {"L": round(-ax_c / mm, 2), "R": round((ax_c + tw - w) / mm, 2),
                             "T": round(-ay_c / mm, 2), "B": round((ay_c + th - h) / mm, 2)}
            if synth.any():
                Lc = luma(canvas)
                # тло = гладкі ділянки будь-якого кольору (папір, плашка): розкид яскравості після
                # розмиття 0,5 мм у вікні 1,5 мм < 4 — друк і його краї відпадають, зерно й растр ні.
                # 2280/1: дірки на синій плашці мають заростати синім, не газетним білим
                Lb = cv2.GaussianBlur(Lc, (0, 0), 0.5 * mm)
                kk = int(1.5 * mm) | 1
                sdb = np.sqrt(np.maximum(0, cv2.blur(Lb * Lb, (kk, kk)) - cv2.blur(Lb, (kk, kk)) ** 2))
                paper_w = known & (sdb < 4)
                field = paper_field(canvas, paper_w, mm, q["P"])
                paper_ok = paper_w & (np.abs(Lc - luma(field)) < 12)
                edge = np.zeros((th, tw), bool)
                e15 = int(15 * mm)
                edge[:e15] = edge[-e15:] = True
                edge[:, :e15] = edge[:, -e15:] = True
                sd, rho = grain_stats(canvas, paper_ok & edge, field)
                # зерно — окремо для кожного боку: папір у 6 мм від доданого біля того боку
                # (одне число на сторінку давало знизу розкид x1,13-1,21 проти справжнього, 9304)
                near = nearest_side(th, tw)
                d_syn = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 3)
                sdmap = np.empty((th, tw, 3), np.float32)
                sdmap[:] = sd
                side_sd = {}
                for k, sname in enumerate("LRTB"):
                    msk = paper_ok & (near == k) & (d_syn <= 6 * mm)
                    if msk.sum() >= 5000:
                        sdk, _ = grain_stats(canvas, msk, field)
                        sdmap[near == k] = sdk
                        side_sd[sname] = [round(float(v), 2) for v in sdk]
                rec["grain_side"] = side_sd
                n0 = cv2.GaussianBlur(rng.normal(0, 1, (th, tw)).astype(np.float32), (0, 0), 0.6)
                n0 /= max(1e-3, n0.std())
                noise = np.empty((th, tw, 3), np.float32)
                for k in range(3):
                    nk = cv2.GaussianBlur(rng.normal(0, 1, (th, tw)).astype(np.float32), (0, 0), 0.6)
                    nk /= max(1e-3, nk.std())
                    noise[..., k] = sdmap[..., k] * (np.sqrt(rho) * n0 + np.sqrt(1 - rho) * nk)
                fill = np.clip(field + noise, 0, 255).astype(np.uint8)
                # проба 30.09.2026: зерно латками справжнього паперу (ns-papergrain.py), job "grain": "patch"
                if job.get("grain") == "patch":
                    import importlib.util
                    spec = importlib.util.spec_from_file_location("ns_papergrain", __file__.replace("ns-paperpad.py", "ns-papergrain.py"))
                    pg = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(pg)
                    field_c = paper_field(canvas, paper_w, mm, q["P"], scales=(3.0, 8.0, 25.0, 80.0))
                    # проба 01.10.2026, job "seam": 1 — латки без власного середнього + тон доданого біля шва
                    # з місцевого паперу (seam_tone); 2 — ще й нерівна межа з розчиненням (grow_irregular)
                    seam_mode = int(job.get("seam", 0))
                    wmask = None
                    if seam_mode == 0:
                        qf, qinfo = pg.quilt_fill(canvas, synth, paper_ok, field_c, near, mm, rng)
                    elif seam_mode >= 3:
                        s1, al, rinfo = ramp_alpha(canvas, synth, field_c, near, q["forced"], q["pd"], mm,
                                                   float(job.get("ramp_mm", 5.0)), float(job.get("edge_mm", 0.75)))
                        zone = al > 0.01
                        dest = field_c + seam_tone(canvas, s1, paper_ok, field_c, mm)
                        # джерело латок — поля сторінки (поза блоком друку з запасом 1 мм)
                        mb = {s: max(0, int((pd[s][0] + rec["pad_mm"][s] - 1.0) * mm)) for s in "LRTB"}
                        marg = np.ones((th, tw), bool)
                        marg[mb["T"]:th - mb["B"], mb["L"]:tw - mb["R"]] = False
                        qf, qinfo = pg.quilt_fill(canvas, zone, paper_ok, field_c, near, mm, rng,
                                                  zero_mean=True, dest_field=dest, src_block=s1, src_pref=marg)
                        qinfo["seam"] = seam_mode
                        qinfo["ramp"] = rinfo
                        if qf is not None:
                            # у рампі тон і зерно змішуються окремо; зерно — з діленням на корінь суми квадратів
                            # ваг (два незалежні зерна в сумі 50/50 дали б смугу вдвічі меншого розкиду)
                            cf = canvas.astype(np.float32)
                            wr = (known & ~s1).astype(np.float32)
                            sg = 0.7 * mm
                            tr = cv2.GaussianBlur(cf * wr[..., None], (0, 0), sg) / np.maximum(cv2.GaussianBlur(wr, (0, 0), sg), 1e-3)[..., None]
                            a3 = al[..., None]
                            rz = zone & ~s1
                            # зерно латок слабше за місцевий папір (джерело — найчистіші місця; 2277/7 згори на JPEG
                            # розкид рядка 1,3 проти 1,6): підсилити до розкиду справжнього паперу в рампі того ж
                            # боку, але не більше x1,35 і ніколи не послаблювати
                            res_f = qf - dest
                            hr = np.where(s1, luma(dest), luma(cf))
                            hr = hr - cv2.GaussianBlur(hr, (0, 0), 4)
                            hf = luma(res_f)
                            hf = hf - cv2.GaussianBlur(hf, (0, 0), 4)
                            d_s1 = cv2.distanceTransform((~s1).astype(np.uint8), cv2.DIST_L2, 3)
                            gains = {}
                            for k, sname in enumerate("LRTB"):
                                mr = rz & (near == k) & (d_s1 > 0.5 * mm)
                                mf = s1 & (near == k)
                                if mr.sum() >= 5000 and mf.sum() >= 2000:
                                    g = float(np.clip(hr[mr].std() / max(1e-3, hf[mf].std()), 1.0, 1.35))
                                    res_f[near == k] *= g
                                    gains[sname] = [round(float(hr[mr].std()), 2), round(float(hf[mf].std()), 2), round(g, 2)]
                            qinfo["grain_gain"] = gains
                            qf = dest + res_f
                            mixv = a3 * dest + (1 - a3) * tr + (a3 * res_f + (1 - a3) * (cf - tr)) / np.sqrt(a3 * a3 + (1 - a3) ** 2)
                            qf[rz] = mixv[rz]
                            qinfo["touched_mm2"] = round(float(rz.sum()) / mm / mm)
                            wmask = zone
                            synth = s1 | (al >= 0.5)
                    else:
                        syn_q = synth
                        if seam_mode >= 2:
                            clean = clean_paper(canvas, synth, field_c, mm, 1.5)
                            keep = set(q["forced"])      # слово оператора (page_edge): межу там не чіпати
                            syn_q = grow_irregular(synth, clean, near, ["LRTB".index(s) for s in keep], mm, rng)
                        dest = field_c + seam_tone(canvas, syn_q, paper_ok, field_c, mm)
                        qf, qinfo = pg.quilt_fill(canvas, syn_q, paper_ok, field_c, near, mm, rng,
                                                  zero_mean=True, dest_field=dest)
                        qinfo["seam"] = seam_mode
                        if qf is not None and seam_mode >= 2:
                            # розчинення: на 2-3 пікс. по обидва боки нової межі справжній чистий папір і латка
                            # змішуються (лише там, де справжній піксель чистий); далі synth = розширена маска
                            al = cv2.GaussianBlur(syn_q.astype(np.float32), (0, 0), 1.5)
                            mix = known & clean & (al > 0.02)
                            for s in keep:
                                mix &= near != "LRTB".index(s)
                            qf[mix] = al[mix][:, None] * qf[mix] + (1 - al[mix])[:, None] * canvas[mix].astype(np.float32)
                            qinfo["grown_px"] = int((syn_q & ~synth).sum())
                            synth = syn_q | mix
                    rec["grain_patch"] = qinfo
                    if qf is not None:
                        fill = np.clip(qf, 0, 255).astype(np.uint8)
                # перенесений друк: у доданому пікселі на 30+ темніші за тон поля (має бути ~0)
                if wmask is None:
                    wmask = synth
                rec["synth_dark_px"] = int(((luma(fill) < luma(field) - 30) & wmask).sum())
                canvas[wmask] = fill[wmask]
                rec["grain_sd"] = [round(float(v), 2) for v in sd]
                rec["grain_rho"] = round(rho, 2)
                rec["seam"] = seam_metrics(canvas, synth, paper_ok, dpi)
                rec["synth_mm2"] = round(float(synth.sum()) / mm / mm)
            rec["margin_block_mm"] = {s: round(pd[s][0] + rec["pad_mm"][s], 1) for s in "LRTB"}
            out = cv2.copyMakeBorder(canvas, fm, fm, fm, fm, cv2.BORDER_CONSTANT,
                                     value=(frame_tone, frame_tone, frame_tone))
            Image.fromarray(out).save(q["out"])
            # маска доданого (255 = синтез, рамка 0) — для мірила шва ns-seamprobe.py (30.09.2026)
            if job.get("mask_dir"):
                mk = cv2.copyMakeBorder((synth * 255).astype(np.uint8), fm, fm, fm, fm, cv2.BORDER_CONSTANT, value=0)
                Image.fromarray(mk).save("%s/%s_synth.png" % (job["mask_dir"], q["name"]))
            report["pages"].append(rec)
            m, dr = rec["margin_block_mm"], rec["dirt"]
            sm = " ".join("%s %+.1f/%.1f x%.2f" % (s, v["dL"], v["dL_max"], v["sd_ratio"])
                          for s, v in rec.get("seam", {}).items())
            print("%s: бруд (мм, відр.) L%.1f/%d R%.1f/%d T%.1f/%d B%.1f/%d, клин %d пікс.; доп. L%+.1f R%+.1f T%+.1f B%+.1f мм; "
                  "поля друку L%.1f R%.1f T%.1f B%.1f%s; шов %s"
                  % (q["name"], dr["L"]["max_mm"], dr["L"]["segs"], dr["R"]["max_mm"], dr["R"]["segs"],
                     dr["T"]["max_mm"], dr["T"]["segs"], dr["B"]["max_mm"], dr["B"]["segs"], q["wedge_px"],
                     rec["pad_mm"]["L"], rec["pad_mm"]["R"], rec["pad_mm"]["T"], rec["pad_mm"]["B"],
                     m["L"], m["R"], m["T"], m["B"], " (УПОР у друк)" if any(rec["clamped"]) else "", sm or "-"))
    json.dump(report, open(job["report"], "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
