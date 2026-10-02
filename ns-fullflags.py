# -*- coding: utf-8 -*-
"""Додаткові позначки номера для ns-full (рішення головної 02.10.2026, 18:00). Нічого не змінює.

  python ns-fullflags.py --work C:\\NS_WORK\\2270 --issue C:\\NS_MASTERS\\2001\\2270_2001-02-04

Друкує по рядку на позначку (порожньо — позначок немає). Джерела — те, що лишається після прибирання
prep / render: prepare.log (посторінкова таблиця шва від ns-padreport) і prepare.json (замір ниток).

1. ШОВ доданого паперу гірший за поріг: |dL*| медіана > 1,00 АБО 90-й перцентиль > 1,50. Спершу поріг
   був найгіршим швом схваленої проби (2291/1 низ: 0,67 / 1,10), але з ним у review пішли 3 номери з 4,
   а оператор про 2270 стор. 7 і 8 низ (0,82/1,25 і 0,85/1,16) сказав: «шов не видно» (02.10.2026).
   Числа — поки що; остаточні — після розподілу по всіх номерах 2001.
2. ЗРІЗ КОРІНЦЯ БЕЗ НИТОК («за смугою»: ниток на сторінці не знайдено) глибший за 8,5 мм (стеля заміру
   ниток 2001-2003) АБО на сторінці з друком до краю (ns-designscan >= 40 %; смуга скла, ширша за 4 мм,
   дає те саме число — 2268/6). У рядку — відстань від лінії зрізу до друку (початок друку за
   ns-spinescan мінус зріз); менше 1,5 мм — рядок починається з «УВАГА».
3. ДОПОВНЕННЯ ширше за 4,0 мм (слово оператора 02.10.2026, вечір): на 2277 стор. 1 і 5 зліва додано 7,3 і
   5,4 мм паперу — «дуже помітно, відрізняється від усієї решти сторінки», хоча шов там «добрий»
   (0,18/0,67; 0,31/0,52). Мірило шва міряє СТИК (сусідні смуги), а око бачить СМУГУ цілком проти сторінки;
   на схваленій 2277/7 доданого 4,2 мм. Мірила «смуга проти паперу сторінки» ще немає — поки що позначка
   за шириною.
Код 0 — відпрацював; 2 — немає даних (prepare.log / prepare.json / таблиці шва): тоді ns-full ставить
позначку «не пораховано», а не «чисто».
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SEAM_MED, SEAM_P90 = 1.00, 1.50          # поріг оператора 02.10.2026 (вечір), поки що — до розподілу по 2001
CUT_MAX_MM = 8.5                         # стеля заміру ниток 2001-2003
PAD_MAX_MM = 4.0                         # доданий папір, ширший за це, оператор бачить смугою (2277/1, /5 ліво)
DESIGN_PCT = 40.0
SIDE = {"L": "ліво", "R": "право", "T": "верх", "B": "низ"}
HERE = os.path.dirname(os.path.abspath(__file__))


def num(x):
    return ("%.2f" % x).replace(".", ",")


def seam_flags(log_path):
    """Позначки шва з ОСТАННЬОЇ таблиці ns-padreport у prepare.log; None — таблиці немає."""
    with open(log_path, encoding="utf-8-sig", errors="replace") as f:
        lines = f.read().splitlines()
    start = max((i for i, l in enumerate(lines) if l.startswith("стор.") and "шов:" in l), default=None)
    if start is None:
        return None
    out, rows = [], 0
    for l in lines[start + 1:]:
        m = re.match(r"^p(\d\d)\s", l)
        if not m:
            break
        rows += 1
        for s in re.finditer(r"([LRTB]) (\d+\.\d+)/(\d+\.\d+), (\d+\.\d+)", l):
            med, p90 = float(s.group(2)), float(s.group(3))
            if med > SEAM_MED or p90 > SEAM_P90:
                out.append("шов гірший за поріг (%s/%s): стор. %d %s — |dL*| мед./90-й %s/%s"
                           % (num(SEAM_MED), num(SEAM_P90), int(m.group(1)), SIDE[s.group(1)], num(med), num(p90)))
    return out if rows else None


def pad_widths(log_path):
    """[(стор., бік, мм)] — скільки паперу ДОДАНО з кожного боку (лише додатні), з ОСТАННЬОЇ таблиці
    ns-padreport у prepare.log (стовпець «доп. L/R/T/B, мм»); None — таблиці немає."""
    with open(log_path, encoding="utf-8-sig", errors="replace") as f:
        lines = f.read().splitlines()
    start = max((i for i, l in enumerate(lines) if l.startswith("стор.") and "доп. L/R/T/B" in l), default=None)
    if start is None:
        return None
    out, rows = [], 0
    for l in lines[start + 1:]:
        m = re.match(r"^p(\d\d)\s+([+-]\d+\.\d+)\s+([+-]\d+\.\d+)\s+([+-]\d+\.\d+)\s+([+-]\d+\.\d+)", l)
        if not m:
            break
        rows += 1
        for side, v in zip("LRTB", m.groups()[1:]):
            if float(v) > 0:
                out.append((int(m.group(1)), side, float(v)))
    return out if rows else None


def pad_flags(log_path):
    """Позначка «доповнення N мм» на бік, де доданого паперу більше за PAD_MAX_MM; None — таблиці немає."""
    pads = pad_widths(log_path)
    if pads is None:
        return None
    return ["доповнення %s мм: стор. %d %s (доданого паперу більше за %s мм)"
            % (("%.1f" % v).replace(".", ","), p, SIDE[s], ("%g" % PAD_MAX_MM).replace(".", ","))
            for p, s, v in pads if v > PAD_MAX_MM]


def cut_flags(prep, issue_dir):
    out = []
    spine = prep.get("spine") or {}
    edge = {}
    for tk in (prep.get("edge") or "").upper().split():
        m = re.match(r"^(\d+)([LRTB])([\d.]+)$", tk)
        if m:
            edge[(int(m.group(1)), m.group(2))] = float(m.group(3))
    keep = {tk.upper() for tk in (prep.get("edge_keep") or [])}
    page_value = None
    for it in spine.get("pages") or []:
        if it.get("threads"):
            continue
        key = (int(it["n"]), it["side"])
        cut = edge.get(key)
        if cut is None or ("%d%s%g" % (key[0], key[1], cut)) in keep:
            continue                                    # знака немає або бік ріжеться за словом оператора
        design = None
        tifs = glob.glob(os.path.join(issue_dir, "*_p%02d.tif" % key[0])) if issue_dir else []
        if tifs:
            if page_value is None:
                spec = importlib.util.spec_from_file_location("ns_designscan", os.path.join(HERE, "ns-designscan.py"))
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                page_value = mod.page_value
            design = page_value(tifs[0])
        if not (cut > CUT_MAX_MM or (design is not None and design >= DESIGN_PCT)):
            continue
        ps = it.get("print_start")
        gap = None if ps is None else ps - cut
        why = []
        if cut > CUT_MAX_MM:
            why.append("глибше за %s мм" % ("%g" % CUT_MAX_MM).replace(".", ","))
        if design is not None and design >= DESIGN_PCT:
            why.append("друк або смуга до краю %.0f %%" % design)
        txt = ("зріз корінця %s мм без ниток, стор. %d %s (%s; смуга %s мм): від лінії зрізу до друку %s"
               % (("%g" % cut).replace(".", ","), key[0], SIDE[key[1]], "; ".join(why),
                  ("%g" % (it.get("strip") or 0)).replace(".", ","),
                  "не міряно" if gap is None else ("%.1f мм" % gap).replace(".", ",")))
        if gap is not None and gap < 1.5:
            txt = "УВАГА, ЗРІЗ БІЛЯ ДРУКУ: " + txt
        out.append(txt)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--issue", default="")
    a = ap.parse_args()
    pj, pl = os.path.join(a.work, "prepare.json"), os.path.join(a.work, "prepare.log")
    if not (os.path.exists(pj) and os.path.exists(pl)):
        print("немає prepare.json або prepare.log у %s" % a.work, file=sys.stderr)
        sys.exit(2)
    with open(pj, encoding="utf-8-sig") as f:
        prep = json.load(f)
    seams = seam_flags(pl)
    pads = pad_flags(pl)
    if seams is None or pads is None:
        print("у prepare.log немає таблиці шва (ns-padreport)", file=sys.stderr)
        sys.exit(2)
    for l in seams + pads + cut_flags(prep, a.issue):
        print(l)


if __name__ == "__main__":
    main()
