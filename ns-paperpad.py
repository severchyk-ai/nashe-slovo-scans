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


def paper_field(canvas, weight, mm, fallback):
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
    for sig_mm in (1.0, 3.0, 8.0, 25.0, 80.0):
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
                canvas[synth] = fill[synth]
                rec["grain_sd"] = [round(float(v), 2) for v in sd]
                rec["grain_rho"] = round(rho, 2)
                rec["seam"] = seam_metrics(canvas, synth, paper_ok, dpi)
                rec["synth_mm2"] = round(float(synth.sum()) / mm / mm)
            rec["margin_block_mm"] = {s: round(pd[s][0] + rec["pad_mm"][s], 1) for s in "LRTB"}
            out = cv2.copyMakeBorder(canvas, fm, fm, fm, fm, cv2.BORDER_CONSTANT,
                                     value=(frame_tone, frame_tone, frame_tone))
            Image.fromarray(out).save(q["out"])
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
