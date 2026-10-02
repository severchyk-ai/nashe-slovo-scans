# -*- coding: utf-8 -*-
"""Заростити ОДНУ велику дірку в місці, яке вказав оператор (fill_at у маніфесті).

  python ns-holeat.py <prep.tif> <L|R|T|B> <уздовж_мм> <вихід.png> [--skip мм] [--paper rgb(r,g,b)]
                      [--sheet аркуш.png] [--dump вікно.png]

Навіщо окремо від Repair-NsHoles. Автоматика заростає дірку, лише коли навколо неї
чистий газетний папір, — це урок 2318 (латка перенесла друк). Але оператор оглянув
2280 (28.09.2026) і велів заростити дірки й там, де тло НЕ папір: стор. 1 — на
блакитній плашці, стор. 5 — на межі білого паперу й сірого тла фото. Такі дірки
автоматика або лишає («біля друку»), або взагалі не бачить (на 2280/5 дірка злипається
з темним фото в пляму 13 x 16 мм). Тут місце дає людина, а скрипт лише знаходить саму
дірку й заростає її тим, що довкола.

Що робить:
  1. вікно ±14 мм уздовж краю від указаного місця, 0-30 мм углиб;
  2. дірка = ТЕМНЕ (< 100) і БЕЗБАРВНЕ (макс - мін каналів < 30) — це кришка сканера;
     друк на папері й кольорове тло цього не проходять. Виміряно на 2280/1, 2, 5:
     дірки 4,2-5,7 x 5,6-6,2 мм, заповнення габариту 0,77-0,83, окремо від фото;
  3. береться пляма, чий центр не далі 6 мм від указаного місця, розміром 3-9 мм і
     заповненням >= 0,6; інакше — нічого не робить і каже чому (краще дірка, ніж
     стерте);
  4. маска = пляма + 0,8 мм (тінь рваного краю), але БЕЗ інших темних плям;
     смуга під зріз (--skip) спершу заливається тоном паперу, щоб темрява краю не
     потрапила в латку;
  5. заростання: якщо в кільці довкола >= 90 % газетного паперу — тоном і зерном
     паперу (як у Repair-NsHoles); інакше — FSR з того, що межує (блакитна плашка,
     сіре тло), бо «білий» там був би чужим;
  6. поза маскою не змінюється жоден піксель (перевіряється й пишеться).
Вихід — PNG вікна; позицію вікна друкує останній рядок «OFFSET x y» (ns-prep кладе
його назад через magick, щоб зберегти роздільність TIFF). Аркуш «як є / після» — для
огляду.
"""
import importlib.util
import os
import sys

import ns_modcheck
ns_modcheck.need("cv2")      # Windows часом блокує OpenCV — ясна зупинка (код 42), не падіння
import cv2
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DPI = 400.0
PX = DPI / 25.4


def load_inpaint():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("ns_inpaint", os.path.join(here, "ns-inpaint.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def region_fill(img, mask, other_dark, skip_px, core, ring_px=24, grow_px=19):
    """Дірка на НЕ паперовому тлі (блакитна плашка 2280/1; межа білого паперу й
    сірого растру фото 2280/5). Проби 28.09.2026:
      - FSR: гладка світліша латка, лишався білий обідок рваного краю (2280/1),
        а на межі двох тонів сіре розмазувалось по білому (2280/5);
      - «найближча мітка кільця»: горб сірого над межею (ліва частина кільця
        під зрізом); тони з нерозмитого зображення плутали світлі крапки растру
        з папером — межа виходила косою, растр ставав білим.
    Тепер:
      1. тони (1 або 2) — k-середні по РОЗМИТОМУ (σ 2,5 пікс.) Lab кільця:
         растр стає рівним сірим, як його бачить око;
      2. доростання: піксель СВІТЛІШИЙ за найближчий тон (L > +10, розмито) і
         з'єднаний із діркою — білий обідок рваного краю — іде в маску (до 1,2 мм).
         Лише світліше: «чуже обом тонам» захоплювало й візерунок писанки поруч
         (2280/5) — це вже друк;
      3. два тони — межа між ними ПРЯМА (підбір по межі в кільці, розкид
         <= 0,5 мм), нею й ділиться дірка; інакше — найближча мітка кільця;
      4. тон без растру (зерно <= 8) — медіана тону + шум зерна; РАСТР (зерно
         > 8) — копія того ж растру, зсунута ВЗДОВЖ межі на ширину дірки, лише
         якщо ВСЕ джерело — рівне тло того самого тону (не маска, не інша
         темна пляма, розмита яскравість ±8 від медіани). Друк так не переноситься:
         джерело з друком не проходить перевірку, і тоді — шум.
    """
    m = mask > 0
    k_ring = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * ring_px + 1, 2 * ring_px + 1))
    ring = (cv2.dilate(m.astype(np.uint8), k_ring) > 0) & ~m & ~other_dark
    ring[:, :skip_px + (10 if skip_px > 0 else 0)] = False
    blur_rgb = cv2.GaussianBlur(img, (0, 0), 2.5)
    labb = cv2.cvtColor(blur_rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    rv = labb[ring]
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    _, lbl, ctr = cv2.kmeans(rv, 2, None, crit, 3, cv2.KMEANS_PP_CENTERS)
    lbl = lbl.ravel()
    share = min((lbl == 0).mean(), (lbl == 1).mean())
    if np.linalg.norm(ctr[0] - ctr[1]) <= 12 or share < 0.15:
        lbl[:] = 0
        ctr = np.median(rv, axis=0)[None, :]
    nt = len(ctr)
    dist_all = np.stack([np.linalg.norm(labb - c, axis=2) for c in ctr])
    tone_of = np.argmin(dist_all, axis=0)            # тон кожного пікселя (розмито)
    dmin = dist_all.min(axis=0)
    near = cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * grow_px + 1, 2 * grow_px + 1))) > 0
    lighter = labb[..., 0] > ctr[:, 0][tone_of] + 6 * 255 / 100.0   # L у OpenCV — 0..255
    cand = ((near & lighter & (dmin > 10) & ~other_dark) | m).astype(np.uint8)
    cand[:, :skip_px] = m[:, :skip_px]
    nl, cl = cv2.connectedComponents(cand, 8)
    ids = np.unique(cl[m])
    grown = np.isin(cl, ids[ids > 0])
    # +4 пікс.: тонка темна лінія тіні на самому краю білого обідка (2280/1 — лишався дуговий слід)
    grown = cv2.dilate(grown.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))) > 0
    grown &= ~other_dark
    ring2 = ring & ~grown
    lmap = np.zeros(m.shape, np.int32)
    lmap[ring2] = tone_of[ring2] + 1
    # найближчий піксель кільця — OpenCV (scipy на цій машині заблоковано політикою
    # Application Control): мітка кожного нуля + таблиця «мітка -> тон»
    _, lids = cv2.distanceTransformWithLabels((lmap == 0).astype(np.uint8), cv2.DIST_L2, 5,
                                              labelType=cv2.DIST_LABEL_PIXEL)
    lut = np.zeros(int(lids.max()) + 1, np.int32)
    zs = lmap > 0
    lut[lids[zs]] = lmap[zs]
    near_lbl = lut[lids] - 1
    u = (0.0, 1.0)                                    # напрям «уздовж» за умовчанням — уздовж краю
    dline = None                                      # відстань до межі тонів (пікс., зі знаком)
    if nt == 2:
        # межу шукаємо в смузі 3 мм довкола дірки за тоном КОЖНОГО пікселя (розмито):
        # у ring2 її немає — перехідну смугу між тонами забирає доростання
        band = (cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * int(3 * PX) + 1,) * 2)) > 0) & ~m & ~other_dark
        # +10 пікс.: розмиття (σ 2,5) несе заливку смуги під зріз у сусідні стовпці —
        # на 2280/5 біла заливка поруч із растром дала хибну вертикальну «межу»,
        # пряма лягла під -29,8° (повний прогін 28.09.2026)
        band[:, :skip_px + (10 if skip_px > 0 else 0)] = False
        a_ = (band & (tone_of == 0)).astype(np.uint8); b_ = (band & (tone_of == 1)).astype(np.uint8)
        k3 = np.ones((3, 3), np.uint8)
        edge = ((cv2.dilate(a_, k3) > 0) & (b_ > 0)) | ((cv2.dilate(b_, k3) > 0) & (a_ > 0))
        ey, ex = np.nonzero(edge)
        if len(ey) >= 20:
            vx, vy, cx0, cy0 = cv2.fitLine(np.column_stack([ex, ey]).astype(np.float32), cv2.DIST_HUBER, 0, 0.01, 0.01).ravel()
            res_ = np.abs((ex - cx0) * vy - (ey - cy0) * vx)
            yy, xx = np.mgrid[0:m.shape[0], 0:m.shape[1]]
            side_ = ((xx - cx0) * vy - (yy - cy0) * vx) > 0
            by_, bx_ = np.nonzero(band)
            sb = side_[by_, bx_]; tb = tone_of[by_, bx_]
            t_plus = 0 if (tb[sb] == 0).mean() >= 0.5 else 1
            # межа має справді ділити тони: >= 90 % смуги по свій бік (у повному
            # прогоні 2280/5 пряма лягла під -29,8° з розкидом 0,48 мм і біле
            # залило растр — такій межі не віримо)
            acc = float((np.where(sb, t_plus, 1 - t_plus) == tb).mean())
            if np.median(res_) <= 0.25 * PX and acc >= 0.9:
                near_lbl = np.where(side_, t_plus, 1 - t_plus)
                u = (float(vx), float(vy))
                dline = (xx - cx0) * vy - (yy - cy0) * vx
                print(f"межа тонів — пряма, нахил {np.degrees(np.arctan2(vy, vx)):.1f}°, розкид {np.median(res_) / PX:.2f} мм, ділить {acc:.0%}")
            else:
                print(f"межа тонів непевна (розкид {np.median(res_) / PX:.2f} мм, ділить {acc:.0%})")
                return None, None
        else:
            print(f"межа тонів не знайдена ({len(ey)} пікс.)")
            return None, None
    rng = np.random.default_rng(0)
    lum = img.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    lblur = cv2.GaussianBlur(lum, (0, 0), 3)
    patch = img.astype(np.float32).copy()          # де латка нічого не ставить — оригінал
    H_, W_ = m.shape
    for t in range(nt):
        sel = ring2 & (tone_of == t)
        if sel.sum() < 30:
            continue
        bl = lblur[sel]
        med_b = np.median(bl)
        flat = sel & (np.abs(lblur - med_b) <= 8)
        src = flat if flat.sum() >= 50 else sel
        tone = np.median(img[src].astype(np.float32), axis=0)
        hf = (lum - lblur)[src]
        sd = 1.4826 * np.median(np.abs(hf - np.median(hf)))
        where = grown & (near_lbl == t)
        if sd > 8:
            # растр: міняємо лише те, що помітно відрізняється від рівного растру
            # (сама дірка, тінь); растр, який уже є в масці, лишається своїм
            where &= np.abs(lblur - med_b) > 12
            # і лише те, що з'єднане з самою діркою: сусідній друк (писанка) — ні
            nl_, cl_ = cv2.connectedComponents((where | (core > 0)).astype(np.uint8), 8)
            ids_ = np.unique(cl_[core > 0])
            where &= np.isin(cl_, ids_[ids_ > 0])
        ty, tx = np.nonzero(where)
        how = "шум"
        noise_px = None
        if sd > 8 and len(ty):
            # растр: зсув уздовж межі (кілька відстаней, обидва боки), де ВСЕ джерело —
            # рівний растр того ж тону; фаза растру при цьому може зсунутися на
            # пів крапки — це видно лише під лупою, а шум видно одразу
            ext0 = max(ty.max() - ty.min(), tx.max() - tx.min()) + int(1 * PX)
            clean_ = ~grown & ~other_dark
            clean_[:, :skip_px] = False
            if dline is not None:
                # біля межі тонів растр законно світліший (пів білого в розмитті) —
                # рівність міряємо проти тла на ТІЙ САМІЙ відстані від межі
                di = np.round(dline).astype(np.int32)
                lo = di.min()
                ref = np.full(di.max() - lo + 1, np.nan, np.float32)
                for v in np.unique(di[where]):
                    sel_ = clean_ & (di == v)
                    if sel_.sum() >= 20:
                        ref[v - lo] = np.median(lblur[sel_])
                refmap = ref[di - lo]
                # ±12: розмитий растр сам гуляє на 8-10 (2280/5: при ±8 рівним
                # визнавалось 90 %); писанка поруч відхиляється на 20-80
                flat_ = np.abs(lblur - refmap) <= 12         # nan -> False
            else:
                flat_ = np.abs(lblur - med_b) <= 12
            okmap = clean_ & flat_ & ((tone_of == t) | (np.abs(dline) <= 2 * PX) if dline is not None else (tone_of == t))
            # найкращий зсув — з найбільшою часткою чистого джерела; приймається від 95 %.
            # Пікселі з нечистим джерелом (край маски, край писанки) — шумом тону:
            # друку з джерела не беремо ні піксела.
            best_ = None
            for ext, sgn in [(e, g_) for e in (ext0, int(ext0 * 1.5), 2 * ext0, 3 * ext0) for g_ in (1, -1)]:
                oy = int(round(sgn * ext * u[1])); ox = int(round(sgn * ext * u[0]))
                sy, sx = ty + oy, tx + ox
                if not ((sy >= 0) & (sy < H_) & (sx >= 0) & (sx < W_)).all():
                    continue
                q = okmap[sy, sx].mean()
                if best_ is None or q > best_[0]:
                    best_ = (q, sy, sx, sgn * ext)
            noise_px = None
            if best_ is not None and best_[0] >= 0.95:
                q, sy, sx, sh = best_
                good = okmap[sy, sx]
                patch[ty[good], tx[good]] = img[sy[good], sx[good]]
                noise_px = ~good
                how = f"растр зсувом {sh / PX:+.1f} мм уздовж межі (чистого джерела {q:.0%}, решта шумом)"
            else:
                how = "шум (чистого джерела растру немає" + (f", найкраще {best_[0]:.0%})" if best_ else ")")
        if how.startswith("шум") or (sd > 8 and len(ty) and noise_px is not None and noise_px.any()):
            noise = cv2.GaussianBlur(rng.normal(0, 1, m.shape).astype(np.float32), (0, 0), 0.6)
            noise *= sd / max(1e-3, noise.std())
            nw = where.copy()
            if not how.startswith("шум"):
                nw[:] = False
                nw[ty[noise_px], tx[noise_px]] = True
            patch[nw] = np.clip(tone[None, :] + noise[nw][:, None], 0, 255)
        print(f"тон {t + 1}: rgb({tone[0]:.0f},{tone[1]:.0f},{tone[2]:.0f}) зерно {sd:.1f}, латка {len(ty)} пікс. — {how}")
    w = np.clip(cv2.distanceTransform(grown.astype(np.uint8), cv2.DIST_L2, 3) / 3.0, 0, 1)[..., None]
    out = np.clip(img.astype(np.float32) * (1 - w) + patch * w, 0, 255).astype(np.uint8)
    return out, grown.astype(np.uint8) * 255


def main():
    a = sys.argv[1:]
    if len(a) < 4:
        print("треба: prep.tif L|R|T|B уздовж_мм вихід.png [--skip мм] [--paper rgb(r,g,b)] [--sheet аркуш.png]")
        return 2
    path, side, along, out = a[0], a[1].upper(), float(a[2]), a[3]
    skip, paper, sheet, dump = 0.0, None, None, None
    i = 4
    while i < len(a):
        if a[i] == "--skip":
            skip = float(a[i + 1]); i += 2
        elif a[i] == "--paper":
            v = a[i + 1].strip().lower().replace("rgb(", "").replace(")", "").split(",")
            paper = np.array([int(x) for x in v], np.uint8); i += 2
        elif a[i] == "--sheet":
            sheet = a[i + 1]; i += 2
        elif a[i] == "--dump":
            dump = a[i + 1]; i += 2
        else:
            i += 1

    img = np.array(Image.open(path).convert("RGB"))
    H, W, _ = img.shape
    # вікно в координатах сторінки; далі все рахуємо в «канонічній» орієнтації,
    # де край — ліворуч (x = глибина від краю, y = уздовж)
    half, deep = int(14 * PX), int(30 * PX)   # 30 мм углиб: місце для зсуву растру (2280/5)
    c = int(along * PX)
    if side in ("L", "R"):
        y0, y1 = max(0, c - half), min(H, c + half)
        x0, x1 = (0, deep) if side == "L" else (W - deep, W)
    else:
        x0, x1 = max(0, c - half), min(W, c + half)
        y0, y1 = (0, deep) if side == "T" else (H - deep, H)
    win = img[y0:y1, x0:x1].copy()

    def canon(arr):
        if side == "L":
            return arr
        if side == "R":
            return arr[:, ::-1]
        if side == "T":
            return np.swapaxes(arr, 0, 1)
        return np.swapaxes(arr, 0, 1)[:, ::-1]

    def uncanon(arr):
        if side == "L":
            return arr
        if side == "R":
            return arr[:, ::-1]
        if side == "T":
            return np.swapaxes(arr, 0, 1)
        return np.swapaxes(arr[:, ::-1], 0, 1)

    cw = np.ascontiguousarray(canon(win))
    if dump:
        # для розбору й повтору: вхідне вікно як є, до будь-якої зміни
        Image.fromarray(cw).save(dump)
    orig = cw.copy()
    sk = int(skip * PX)
    if sk > 0:
        # смуга під зріз: тон паперу (однаково відріжеться) — щоб темрява краю
        # не злипалася з діркою й не тяглася в латку
        tone = paper if paper is not None else np.median(cw[:, sk:sk + int(3 * PX)].reshape(-1, 3), axis=0).astype(np.uint8)
        cw[:, :sk] = tone
    g = cw.astype(np.float32).mean(axis=2)
    chroma = cw.max(axis=2).astype(np.int16) - cw.min(axis=2).astype(np.int16)
    dark = ((g < 100) & (chroma < 30)).astype(np.uint8)
    dark = cv2.morphologyEx(dark, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
    n, lab, st, cen = cv2.connectedComponentsWithStats(dark, 8)
    tgt = along * PX - (y0 if side in ("L", "R") else x0)
    best, why = None, []
    for k in range(1, n):
        bx, by, bw, bh, area = st[k]
        if area < 200:
            continue
        mw, mh = bw / PX, bh / PX
        fill = area / float(bw * bh)
        dist = abs(by + bh / 2 - tgt) / PX
        desc = f"{mw:.1f}x{mh:.1f} мм, глиб. {bx / PX:.1f}-{(bx + bw) / PX:.1f}, запов. {fill:.2f}, від місця {dist:.1f} мм"
        if dist > 6:
            continue
        if not (3 <= mw <= 9 and 3 <= mh <= 9):
            why.append(desc + " — розмір")
            continue
        if fill < 0.6:
            why.append(desc + " — форма")
            continue
        if best is None or dist < best[0]:
            best = (dist, k, desc)
    if best is None:
        print("ДІРКУ НЕ ЗНАЙДЕНО: у місці немає круглої темної безбарвної плями 3-9 мм" + ("; " + "; ".join(why) if why else ""))
        return 1
    _, k, desc = best
    hole = (lab == k).astype(np.uint8)
    hole = cv2.morphologyEx(hole, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
    grow = cv2.dilate(hole, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * 13 + 1, 2 * 13 + 1)))
    others = ((dark > 0) & (lab != k)).astype(np.uint8)
    # суцільна область: між крапками растру світлі пікселі — без замикання маска
    # просочувалась у растр фото (2280/5: сіре тло за 3 пікс. під діркою) і латка
    # брала його сірий тон
    others = cv2.morphologyEx(others, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15)))
    others = cv2.dilate(others, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    mask = ((grow > 0) & (others == 0)) | (hole > 0)
    mask = mask.astype(np.uint8) * 255

    ip = load_inpaint()
    # кільце ~1,5 мм: частка газетного паперу вирішує метод
    res = ip.paper_fill(cw, mask, fallback=None, min_paper=0.9)
    m_final = ip.GROWN.get("mask", mask)
    if np.array_equal(res[mask > 0], cw[mask > 0]):     # paper_fill пляму лишив
        # паперу замало (плашка, сіре тло фото): тонами тла довкола
        res, m_final = region_fill(cw, mask, others > 0, sk, hole)
        if res is None:
            # два тони без певної прямої межі: заростити охайно не вийде — лишаємо
            print("лишено: форма тла (два тони, межа непевна) — дірку не чіпаю")
            return 1
    keep = m_final == 0
    diff = np.abs(res.astype(np.int16) - cw.astype(np.int16)).max(axis=-1)[keep]
    res[keep] = cw[keep]
    # смуга під зріз повертається як була (її відріже page_edge)
    if sk > 0:
        res[:, :sk] = orig[:, :sk]
    changed_out = int(np.count_nonzero(res[keep] != orig[keep]))
    fixed = np.ascontiguousarray(uncanon(res))
    Image.fromarray(fixed).save(out)
    if sheet:
        a_ = Image.fromarray(win); b_ = Image.fromarray(fixed)
        s = Image.new("RGB", (a_.width * 2 + 8, a_.height), (128, 128, 128))
        s.paste(a_, (0, 0)); s.paste(b_, (a_.width + 8, 0))
        s = s.resize((s.width // 2, s.height // 2))
        s.save(sheet)
    print(f"ЗАРОЩЕНО: {desc}; маска {int(np.count_nonzero(m_final))} пікс.; поза маскою змінено {changed_out} пікс.")
    print(f"OFFSET {x0} {y0}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
