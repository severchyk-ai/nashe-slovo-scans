# Заростання дірки тим, що межує з нею («як затягується рана»).
#
#   python ns-inpaint.py <вхід> <маска> <вихід> [метод] [радіус]
#
# Маска: біле — заростити, чорне — лишити. Методи:
#   telea      (за умовчанням) — швидкий, добре тримає рівний тон і градієнт;
#   ns         Навʼє-Стокса: тягне лінії й межі всередину плями;
#   fsr        частотна реконструкція (cv2.xphoto): єдиний, що відтворює
#              ВІЗЕРУНОК, але повільніший у рази;
#   biharmonic бігармонічний (scikit-image): найплавніший, теж без візерунка;
#   diffuse    власний на чистому PIL — запасний, якщо бібліотек немає.
#
# ⚠︎ Це РЕТУШ: у копії для читання зʼявляється те, чого в аркуші немає.
# Майстер не чіпається. Найнебезпечніше тут НЕ сам метод, а ВИБІР плями:
# 23.09.2026 маска «все темне» стерла напис «Марії» й половину текстової
# колонки, а раніше — букву «К» у «Квітні». Маска має містити лише пляму,
# підтверджену формою, темнотою і відсутністю друку поруч.

import sys

import numpy as np
from PIL import Image

# кирилиця у виводі не має ламати скрипт під кодовою сторінкою 1252
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def _load(path_img, path_mask):
    img = np.array(Image.open(path_img).convert("RGB"))
    mask = np.array(Image.open(path_mask).convert("L"))
    return img, (mask > 127).astype(np.uint8) * 255


def paper_fill(img, mask, fallback=None, ring_px=24, min_paper=0.6, grow_px=19):
    """Дірка заповнюється КОЛЬОРОМ І ЗЕРНОМ ГАЗЕТНОГО ПАПЕРУ, що довкола неї.

    Оператор, 24.09.2026: «мені треба газетний білий колір, який знаходиться
    навколо цієї дірки». FSR продовжував у дірку іржаве кільце навколо неї
    (2318/4, 7), і латка рожевіла — «як рана, що загоїлась».
    Для кожної плями маски: кільце ~1,5 мм довкола; з нього беруться лише
    пікселі ПАПЕРУ (майже безбарвні й світлі — іржа, друк, тінь відпадають);
    медіана — тон, розкид — зерно. Край латки розмитий на ~3 пікс.
    Якщо паперу в кільці менше min_paper (дірка в плашці, орнаменті) —
    fallback (fsr) для цієї плями, бо «білий» там був би чужим.
    """
    import cv2
    out = img.copy()
    lab_n, lab = cv2.connectedComponents((mask > 0).astype(np.uint8), 8)
    rng = np.random.default_rng(0)
    luma_all = img.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    chroma_all = img.max(axis=-1).astype(np.int16) - img.min(axis=-1).astype(np.int16)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * ring_px + 1, 2 * ring_px + 1))
    # залита смуга під зріз (Repair-NsHoles -SkipMm) однотонна, без зерна —
    # у пробу паперу її не беремо: місцевий розкид > 0,3
    lf = luma_all
    loc_sd = np.sqrt(np.maximum(0, cv2.blur(lf * lf, (5, 5)) - cv2.blur(lf, (5, 5)) ** 2))
    grainy = loc_sd > 0.3
    report = []
    need_fb = np.zeros(mask.shape, np.uint8)
    grown = (mask > 0).astype(np.uint8)
    for i in range(1, lab_n):
        m = (lab == i).astype(np.uint8)
        ring = (cv2.dilate(m, k) > 0) & (m == 0)
        lum = luma_all[ring]
        if lum.size == 0:
            continue
        top = np.percentile(lum, 90)
        ring &= grainy
        paper = ring & (chroma_all <= 18) & (luma_all >= top - 25)
        frac = paper.sum() / max(1, ring.sum())
        if frac < min_paper:
            need_fb |= m
            report.append(f"пляма {i}: паперу в кільці {frac:.0%} — {fallback or 'лишено'}")
            continue
        px = img[paper].astype(np.float32)
        tone = np.median(px, axis=0)
        # ДОРОСТАННЯ (оператор: «тло сходиться до центру»): тінь рваного краю,
        # волокна й іржаве кільце, що з'єднані з діркою, теж заповнюються —
        # до grow_px углиб. Лише тут, де довкола >= 60 % чистого паперу, тож
        # друку поруч немає; інакше лишалися сірий обрис (2318/10) і
        # помаранчеві цятки (2318/4, 7).
        tl = float(tone @ np.array([0.299, 0.587, 0.114], np.float32))
        near = cv2.dilate(m, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * grow_px + 1, 2 * grow_px + 1))) > 0
        notpaper = near & ((luma_all < tl - 10) | (chroma_all > 18))
        cand = (notpaper | (m > 0)).astype(np.uint8)
        nl, cl = cv2.connectedComponents(cand, 8)
        ids = np.unique(cl[m > 0])
        m = np.isin(cl, ids[ids > 0]).astype(np.uint8)
        # +3 пікс. у папір: м'який перехід краю латки лягає на папір, не на тінь
        m = cv2.dilate(m, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
        grown |= m
        # зерно: розкид яскравості паперу (MAD), однаковий для каналів
        dl = luma_all[paper]
        sd = 1.4826 * np.median(np.abs(dl - np.median(dl)))
        ys, xs = np.nonzero(m)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        pad = 4
        y0, x0 = max(0, y0 - pad), max(0, x0 - pad)
        y1, x1 = min(m.shape[0], y1 + pad), min(m.shape[1], x1 + pad)
        noise = rng.normal(0, sd, (y1 - y0, x1 - x0)).astype(np.float32)
        noise = cv2.GaussianBlur(noise, (0, 0), 0.6)
        noise *= sd / max(1e-3, noise.std())
        patch = np.clip(tone[None, None, :] + noise[..., None], 0, 255)
        # м'який край ВСЕРЕДИНУ маски (~3 пікс.): поза маскою пікселі однаково
        # повертаються до оригіналу, а зовнішній шар маски — це вже папір
        # (маска розширена на 0,8 мм за тінь дірки)
        dist = cv2.distanceTransform(m[y0:y1, x0:x1], cv2.DIST_L2, 3)
        w = np.clip(dist / 3.0, 0, 1)[..., None]
        reg = out[y0:y1, x0:x1].astype(np.float32)
        out[y0:y1, x0:x1] = np.clip(reg * (1 - w) + patch * w, 0, 255).astype(np.uint8)
        report.append(f"пляма {i}: папір rgb({tone[0]:.0f},{tone[1]:.0f},{tone[2]:.0f}) зерно {sd:.1f} (паперу в кільці {frac:.0%})")
    if fallback and need_fb.any():
        fb = inpaint(img, need_fb * 255, fallback)
        sel = need_fb > 0
        out[sel] = fb[sel]
    print("; ".join(report))
    GROWN["mask"] = grown * 255
    return out


GROWN = {}   # маска після доростання — main() відновлює оригінал лише поза нею


def inpaint(img, mask, method="telea", radius=6):
    if method in ("telea", "ns"):
        import cv2
        flag = cv2.INPAINT_TELEA if method == "telea" else cv2.INPAINT_NS
        bgr = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
        out = cv2.inpaint(bgr, mask, radius, flag)
        return cv2.cvtColor(out, cv2.COLOR_BGR2RGB)

    if method in ("fsr", "fsrbest"):
        import cv2
        algo = cv2.xphoto.INPAINT_FSR_BEST if method == "fsrbest" else cv2.xphoto.INPAINT_FSR_FAST
        bgr = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
        # xphoto чекає маску, де 255 = ВІДОМІ пікселі
        # ⚠︎ xphoto.inpaint віддає результат через аргумент dst, а не як значення
        known = cv2.bitwise_not(mask)
        dst = np.zeros_like(bgr)
        cv2.xphoto.inpaint(bgr, known, dst, algo)
        return cv2.cvtColor(dst, cv2.COLOR_BGR2RGB)

    if method in ("paper", "auto"):
        return paper_fill(img, mask, fallback=("fsr" if method == "auto" else None))

    if method == "biharmonic":
        from skimage.restoration import inpaint_biharmonic
        out = inpaint_biharmonic(img / 255.0, mask > 0, channel_axis=-1)
        return (np.clip(out, 0, 1) * 255).astype(np.uint8)

    # запасний: дифузія (заповнення від країв + усереднення)
    out = img.astype(np.float32).copy()
    m = mask > 0
    for _ in range(400):
        blur = out.copy()
        blur[1:-1, 1:-1] = (out[:-2, 1:-1] + out[2:, 1:-1] + out[1:-1, :-2] + out[1:-1, 2:]) / 4.0
        out[m] = blur[m]
    return np.clip(out, 0, 255).astype(np.uint8)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("треба: вхід маска вихід [метод] [радіус]")
        sys.exit(1)
    method = sys.argv[4] if len(sys.argv) > 4 else "telea"
    radius = int(sys.argv[5]) if len(sys.argv) > 5 else 6
    image, m = _load(sys.argv[1], sys.argv[2])
    result = inpaint(image, m, method, radius)
    if "mask" in GROWN:
        grew = int(np.count_nonzero(GROWN["mask"])) - int(np.count_nonzero(m))
        print(f"доросло {grew} пікс.")
        m = GROWN["mask"]
    # Поза маскою не міняється ЖОДЕН піксель — повертаємо оригінал. Так друк
    # поза плямою недоторканий за побудовою, а не за вдачею методу
    # 24.09.2026 виміряно на 2318: fsr міняє 15-437 тис. пікселів ПОЗА маскою,
    # але щонайбільше на 1 рівень (округлення) — друк він не перемальовував.
    # Відновлення лишається як гарантія. Скільки й наскільки — у виводі.
    keep = m == 0
    diff = np.abs(result.astype(np.int16) - image.astype(np.int16)).max(axis=-1)[keep]
    changed = int(np.count_nonzero(diff))
    big = int(np.count_nonzero(diff > 8))
    dmax = int(diff.max()) if diff.size else 0
    result[keep] = image[keep]
    Image.fromarray(result).save(sys.argv[3])
    print(f"поза маскою fsr змінив {changed} пікс., з них >8 рівнів {big}, найбільше {dmax}; ВІДНОВЛЕНО")
