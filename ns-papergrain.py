# -*- coding: utf-8 -*-
"""Зерно доданого паперу — латками СПРАВЖНЬОГО паперу тієї ж сторінки (проба, 30.09.2026).

Викликає ns-paperpad.py, коли в job "grain": "patch" (ns-render -PaperPad -PadGrain patch).
За умовчанням ns-paperpad і далі кладе шум — цей модуль лише для A/B.

Чому: оператор побачив шов на 2316/10 — «піксель дрібніший і одноманітніший». Мірило
ns-seamprobe.py на відтвореному зразку: потужність зерна в смузі періодів 0,85-2 мм у
доданому x0,30 від справжнього (log2 -1,75; контроль справжнє/справжнє -0,21), 0,42-0,85 мм
-0,55 (контроль -0,12). Шум σ 0,6 пікс. не має крупних волокон і хмарності паперу.

Як:
  * тон — поле справжнього паперу, лише з масштабів 3-80 мм (без 1 мм: дрібніше несе
    латка, інакше її хмарність лягла б удруге);
  * зерно — залишок «папір мінус те саме поле» з латок 48 x 48 пікс. (4 мм при 300 dpi),
    узятих лише з паперу тону поля далі 3 мм від чорнила (темніше за поле на 18+) — урок
    2318: латка не має переносити друк. НЕ за гладкістю (див. коментар у quilt_fill);
  * латка — спершу з паперу того самого боку за 12 мм від доданого (з чим око порівнює),
    тоді того ж боку до 25 мм від краю, тоді будь-яка; повтор сусідів не допускається;
  * латки перекриваються на 12 пікс. з вагами cos/sin; сума зважених латок ділиться на
    корінь суми КВАДРАТІВ ваг — розкид незалежних латок у перекритті й біля краю полотна
    не падає (звичайне середнє дало б сітку тьмяніших смуг).
Нічого не пише; повертає заповнення (float32 H x W x 3) для пікселів synth.
"""
import cv2
import numpy as np

P = 48          # латка, пікс. (4 мм при 300 dpi)
O = 12          # перекриття, пікс.
STEP = P - O


def _weights():
    w = np.ones(P, np.float32)
    t = (np.arange(O, dtype=np.float32) + 0.5) / O * (np.pi / 2)
    w[:O] = np.sin(t)
    w[-O:] = np.cos(t)
    return np.outer(w, w)


def quilt_fill(canvas, synth, paper_ok, field_c, near, mm, rng, zero_mean=False, dest_field=None, src_block=None,
               src_pref=None):
    """canvas uint8 HxWx3 (справжнє на місці), synth — що заповнити, paper_ok — чистий
    справжній папір, field_c — тон 3-80 мм, near — найближчий бік (0 L 1 R 2 T 3 B).
    zero_mean — з кожної латки зняти її власне середнє (01.10.2026): джерело — найчистіший папір,
    він світліший за поле, яке усереднює й цятки з просвітом (2277/7 L: доданий на +0,4…+0,7 L*
    світліший за папір 2-4 мм від шва); тон тоді несе лише поле. dest_field — тон місця
    призначення, якщо не field_c (підгонка до місцевого паперу біля шва, ns-paperpad seam_tone).
    src_block — що НЕ може бути джерелом, якщо це не весь synth: з рампою (seam 3) synth — це й смуга
    справжнього паперу 5 мм уздовж швів, і без неї джерел лишалося б мало; тоді латка не береться з
    місця, що перекривається з її власною клітиною.
    src_pref — де брати латки насамперед (поля сторінки): усередині блоку друку «чистий» папір несе
    просвіт звороту, і на широкій доданій смузі (2316/10 R, 14 мм) латки звідти давали слабкі привиди
    літер. Якщо латок цілком у src_pref >= 200 — беруться лише вони."""
    H, W = synth.shape
    res = canvas.astype(np.float32) - field_c
    # Джерело — НЕ за гладкістю: paper_ok (розкид < 4 у вікні 1,5 мм) відсіює саме папір з
    # крупною структурою 0,5-1,5 мм, і перша версія латок мала крупної смуги x0,36-0,48
    # (2316/10 R log2 -1,21, 2277/7 L -1,44 — як шум). Тепер: справжній папір тону поля (±12)
    # на відстані >= 3 мм від ЧОРНИЛА — пікселя, темнішого за тон поля на 18+ (друк, цятки,
    # лінії; урок 2318: латка не переносить друк).
    lw = np.array([0.299, 0.587, 0.114], np.float32)
    Lc = canvas.astype(np.float32) @ lw
    Lf = field_c @ lw
    blk = synth if src_block is None else src_block
    ink = (Lc < Lf - 18) & ~blk
    dink = cv2.distanceTransform((~ink).astype(np.uint8), cv2.DIST_L2, 3)
    src = ~blk & (np.abs(Lc - Lf) < 12) & (dink >= 3 * mm)
    dsyn = cv2.distanceTransform((~synth).astype(np.uint8), cv2.DIST_L2, 3) / mm
    I = cv2.integral(src.astype(np.uint8))
    ys, xs = np.mgrid[0:H - P:8, 0:W - P:8]
    ys, xs = ys.ravel(), xs.ravel()
    full = (I[ys + P, xs + P] - I[ys, xs + P] - I[ys + P, xs] + I[ys, xs]) == P * P
    ys, xs = ys[full], xs[full]
    n_all = int(len(ys))
    if src_pref is not None and len(ys):
        Ip = cv2.integral(src_pref.astype(np.uint8))
        inp = (Ip[ys + P, xs + P] - Ip[ys, xs + P] - Ip[ys + P, xs] + Ip[ys, xs]) == P * P
        if int(inp.sum()) >= 200:
            ys, xs = ys[inp], xs[inp]
    if len(ys) < 20:
        return None, {"patches_src": int(len(ys))}
    cy, cx = ys + P // 2, xs + P // 2
    side = near[cy, cx]
    dedge = np.minimum(np.minimum(cx, W - 1 - cx), np.minimum(cy, H - 1 - cy)) / mm
    dnear = dsyn[cy, cx]      # відстань латки до доданого: спершу папір біля самого шва
    wgt = _weights()
    acc = np.zeros((H, W, 3), np.float32)
    ys_s, xs_s = np.nonzero(synth)
    y0, y1, x0, x1 = ys_s.min(), ys_s.max(), xs_s.min(), xs_s.max()
    Is = cv2.integral(synth.astype(np.uint8))
    w2 = np.zeros((H, W), np.float32)

    def starts(a0, a1, n):
        st = list(range(max(0, a0 - O), min(n - P, a1) + 1, STEP))
        if st and st[-1] + P < min(n, a1 + 1 + O):
            st.append(n - P)      # добити до краю полотна (там рамка)
        return st
    used, placed = [], 0
    stage = {s: [0, 0, 0] for s in "LRTB"}    # звідки латки: за 12 мм від доданого / до 25 мм від краю / будь-де
    for ty in starts(y0, y1, H):
        for tx in starts(x0, x1, W):
            if Is[ty + P, tx + P] - Is[ty, tx + P] - Is[ty + P, tx] + Is[ty, tx] == 0:
                continue
            s = near[min(H - 1, ty + P // 2), min(W - 1, tx + P // 2)]
            cand = np.nonzero((side == s) & (dnear <= 12))[0]
            st = 0
            if len(cand) < 20:
                cand = np.nonzero((side == s) & (dedge <= 25))[0]
                st = 1
            if len(cand) < 20:
                cand = np.arange(len(ys))
                st = 2
            stage["LRTB"[s]][st] += 1
            for _ in range(8):     # не брати латку, узяту для сусідньої клітини
                j = int(cand[rng.integers(len(cand))])
                if not any(abs(ys[j] - uy) < P and abs(xs[j] - ux) < P for uy, ux in used[-6:]) and                         (src_block is None or abs(ys[j] - ty) >= P or abs(xs[j] - tx) >= P):
                    break
            used.append((ys[j], xs[j]))
            pr = res[ys[j]:ys[j] + P, xs[j]:xs[j] + P]
            if zero_mean:
                pr = pr - pr.mean(axis=(0, 1))
            acc[ty:ty + P, tx:tx + P] += pr * wgt[..., None]
            w2[ty:ty + P, tx:tx + P] += wgt * wgt
            placed += 1
    # ділення на корінь суми квадратів ваг: розкид незалежних латок однаковий за будь-якого
    # перекриття (і біля краю полотна, де сусідньої латки немає — там це просто одна латка)
    fill = (field_c if dest_field is None else dest_field) + acc / np.sqrt(np.maximum(w2, 1e-6))[..., None]
    return fill, {"patches_src": int(len(ys)), "patches_src_all": n_all, "patches_placed": placed,
                  "stage": {k: v for k, v in stage.items() if sum(v)}}
