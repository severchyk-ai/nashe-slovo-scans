# -*- coding: utf-8 -*-
"""Паспорт року: числа по кожному номеру й УСІ позначені сторінки з причиною (02.10.2026, інструменти).

  python ns-pasport.py 2001                запис у NS_WORK\\pasport_2001.md, короткий підсумок — на екран
  python ns-pasport.py 2001 --design       ще й переміряти «друк до краю» по майстрах року (≈ 1 хв; далі з кешу)
  python ns-pasport.py 2001 --out файл.md

Рішення оператора 02.10.2026 (варіант А): звичайні номери йдуть одразу до готового PDF з OCR, оператор
дивиться лише позначені сторінки й кілька випадкових номерів на рік. Паспорт — той список.
Джерела (нічого не міряє заново, крім --design, і нічого не змінює):
  маніфести року                 дата, сторінки, стан, pdf_built, примітки (notes)
  NS_WORK\\<N>\\full.json          ns-full: МБ, слова OCR, % підозрілих, хвилини, позначки (підготовка,
                                 поля друку, qc, edgescan)
  ns-manual.csv                  номери «лише вручну» — у паспорті окремим списком, без чисел
  ns-edge-keep.csv               ручні зрізи у звичайних номерах — рядком «глянути»
  NS_WORK\\pasport_<рік>_design.csv   кеш --design: сторінки звичайних номерів із друком до краю (>= 40 %)
full.json вважається чинним, лише якщо PDF у NS_PDF зібрано САМЕ тим прогоном (pdf_built маніфесту лежить
між started і finished): PDF, перезібраний повз ns-full, у паспорт числами не йде — номер «не зроблено».
Три номери «на вибірку» — випадкові, але сталі для року (зерно = рік), з тих, що пройшли повний шлях.
"""
import argparse
import csv
import datetime
import glob
import importlib.util
import json
import os
import random
import statistics
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
MASTERS = os.environ.get("NS_TEST_MASTERS") or r"C:\NS_MASTERS"
WORK = os.environ.get("NS_TEST_WORK") or r"C:\NS_WORK"
PDF = os.environ.get("NS_TEST_PDF") or r"C:\NS_PDF"


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def load_json(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def design_pages(year, issues, remeasure):
    """{seq: [(стор., %), …]} — сторінки з друком до краю (>= 40 %); None, якщо кешу немає й не міряли."""
    cache = os.path.join(WORK, "pasport_%d_design.csv" % year)
    if remeasure:
        spec = importlib.util.spec_from_file_location("ns_designscan", os.path.join(HERE, "ns-designscan.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        rows = []
        for it in issues:
            for pg in it["man"].get("pages") or []:
                f = os.path.join(it["dir"], pg["file"])
                rows.append((it["seq"], int(pg["n"]), mod.page_value(f)))
        with open(cache, "w", encoding="utf-8-sig", newline="\n") as f:
            f.write("seq,page,edge_pct\n")
            for r in rows:
                f.write("%d,%d,%.1f\n" % r)
    if not os.path.exists(cache):
        return None, cache
    out = {}
    for r in read_csv(cache):
        if float(r["edge_pct"]) >= 40.0:
            out.setdefault(int(r["seq"]), []).append((int(r["page"]), float(r["edge_pct"])))
    return out, cache


def full_of(it):
    """(full.json, причина, чому його немає/він не чинний)."""
    seq, man = it["seq"], it["man"]
    fj = load_json(os.path.join(WORK, str(seq), "full.json"))
    if fj is None:
        return None, "повного шляху ще не було"
    st = fj.get("stage")
    if st != "done":
        why = {"prepared": "підготовлено, PDF з OCR не зібрано (pikepdf / ocrmypdf було заблоковано)",
               "stopped": "зупинено: ручний page_edge не із заміру — потрібне рішення",
               "manual": "лише вручну", "blocked": "OpenCV було заблоковано",
               "started": "прогін ще йде або обірваний"}.get(st, "збій: %s" % (fj.get("error") or st))
        return None, why
    built = man.get("pdf_built") or ""
    if not (fj.get("started", "") <= built <= fj.get("finished", "")):
        return None, "PDF у NS_PDF зібрано не цим прогоном ns-full (pdf_built %s)" % (built or "немає")
    if not os.path.exists(fj.get("pdf") or ""):
        return None, "PDF немає на місці: %s" % fj.get("pdf")
    return fj, ""


def rng(vals, fmt="%.1f"):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "—"
    return (fmt + " / " + fmt + " / " + fmt) % (min(vals), statistics.median(vals), max(vals))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("year", type=int)
    ap.add_argument("--design", action="store_true", help="переміряти друк до краю по майстрах року")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    year = a.year

    manual = {int(r["seq"]): r["reason"] for r in read_csv(os.path.join(HERE, "ns-manual.csv")) if r["seq"].isdigit()}
    keep = {int(r["seq"]): r for r in read_csv(os.path.join(HERE, "ns-edge-keep.csv")) if r["seq"].isdigit()}
    missing = [r for r in read_csv(os.path.join(MASTERS, "_catalog", "missing.csv")) if str(r.get("year", "")) == str(year)
               or str(r.get("date", "")).startswith(str(year))]

    issues = []
    for d in sorted(glob.glob(os.path.join(MASTERS, str(year), "*_*"))):
        man = load_json(os.path.join(d, "_manifest.json"))
        if not man:
            continue
        issues.append({"seq": int(man["seq_first"]), "dir": d, "man": man})
    if not issues:
        print("У каталозі немає номерів %d року (%s)." % (year, os.path.join(MASTERS, str(year))))
        sys.exit(1)

    usual = [it for it in issues if it["seq"] not in manual]
    design, design_cache = design_pages(year, usual, a.design)

    done, todo = [], []
    for it in usual:
        fj, why = full_of(it)
        it["full"] = fj
        if fj:
            done.append(it)
        else:
            todo.append((it, why))

    L = []
    w = L.append
    w("# Паспорт року %d — «Наше слово»" % year)
    w("")
    w("Складено %s скриптом `ns-pasport.py` з маніфестів і `NS_WORK\\<N>\\full.json`. Числа — з прогонів `ns-full`;"
      % datetime.datetime.now().strftime("%d.%m.%Y %H:%M"))
    w("файл переписується щоразу. Оператор дивиться розділи «Позначене» і «На вибірку».")
    w("")
    w("## Підсумок")
    w("")
    pages_all = sum(len(it["man"].get("pages") or []) for it in issues)
    w("- Номерів у каталозі: **%d** (%d-%d), сторінок %d." % (len(issues), issues[0]["seq"], issues[-1]["seq"], pages_all))
    if missing:
        w("- Немає в річнику: %s." % ", ".join(str(r.get("seq") or r.get("seq_first") or "?") for r in missing))
    flagged = [it for it in done if it["full"].get("flags")]
    w("- Повний шлях пройшли: **%d** із %d звичайних; без позначок %d, з позначками %d (позначок усього %d)."
      % (len(done), len(usual), len(done) - len(flagged), len(flagged), sum(len(it["full"]["flags"]) for it in flagged)))
    w("- Ще не зроблено: **%d**%s" % (len(todo), "." if not todo else " — " + ", ".join(str(it["seq"]) for it, _ in todo) + "."))
    man_year = [it for it in issues if it["seq"] in manual]
    w("- Лише вручну (поза цим паспортом): **%d**%s" % (len(man_year), "." if not man_year else " — " + ", ".join(str(it["seq"]) for it in man_year) + "."))
    if done:
        w("- PDF, МБ (мін / медіана / макс): %s; усього %.0f МБ." % (rng([it["full"].get("pdf_mb") for it in done]),
                                                                    sum(it["full"].get("pdf_mb") or 0 for it in done)))
        w("- Слів OCR на номер: %s; підозрілих слів, %%: %s (поріг qc 2 %%)."
          % (rng([it["full"].get("ocr_words") for it in done], "%.0f"), rng([it["full"].get("ocr_pct") for it in done], "%.2f")))
        w("- Хвилин на номер: %s." % rng([it["full"].get("minutes") for it in done]))
    w("")

    w("## Номери")
    w("")
    w("| № | дата | № у році | стор. | МБ | слів | підозр., % | позначок | стан |")
    w("|---|---|---|---|---|---|---|---|---|")
    why_of = {it["seq"]: why for it, why in todo}
    for it in issues:
        m, s = it["man"], it["seq"]
        head = "| %d | %s | %s | %d |" % (s, m.get("date"), m.get("issue_no_in_year"), len(m.get("pages") or []))
        if s in manual:
            w(head + " — | — | — | — | лише вручну |")
        elif it.get("full"):
            f = it["full"]
            pct = "%.2f" % f["ocr_pct"] if f.get("ocr_pct") is not None else "—"
            w(head + " %s | %s | %s | %d | %s |" % (f.get("pdf_mb"), f.get("ocr_words"), pct, len(f.get("flags") or []), f.get("state")))
        else:
            w(head + " — | — | — | — | НЕ ЗРОБЛЕНО: %s |" % why_of.get(s, ""))
    w("")

    w("## Позначене — глянути очима")
    w("")
    any_flag = False
    for it in done:
        s, f = it["seq"], it["full"]
        lines = list(f.get("flags") or [])
        # Шов доданого паперу: коротка рампа і заливка шумом — у позначки ns-full (і в стан номера) не
        # входять, але оператор має їх бачити: на пробі 02.10 він дивився саме такі боки (2291/2 верх).
        for pr in f.get("pad_report") or []:
            if (pr.startswith("рампа коротша") or pr.startswith("ЗАЛИТО ШУМОМ")) and not pr.rstrip().endswith("немає"):
                lines.append("шов доданого паперу — " + pr)
        if design and s in design:
            lines += ["друк до краю (ns-designscan): стор. %d — %.0f %%" % pv for pv in sorted(design[s])]
        k = keep.get(s)
        if k:
            lines.append("ручний зріз (ns-edge-keep.csv): %s%s — %s" % (k.get("keep") or "немає",
                         "; решту відкинуто" if (k.get("reset") or "").strip() == "1" else "", k.get("reason")))
        notes = it["man"].get("notes") or ""            # поле notes — рядок, примітки через « | » (ns-note)
        for nt in (notes.split(" | ") if isinstance(notes, str) else notes):
            if nt:
                lines.append("примітка до номера: %s" % nt)
        if not lines:
            continue
        any_flag = True
        w("### %d (%s) — `%s`" % (s, it["man"].get("date"), f.get("pdf")))
        for ln in lines:
            w("- " + ln)
        w("")
    if not any_flag:
        w("Позначок немає." if done else "Жоден номер ще не пройшов повного шляху.")
        w("")
    if design is None:
        w("_Друк до краю не міряно: запусти `python ns-pasport.py %d --design` (кеш — `%s`)._" % (year, design_cache))
        w("")

    if man_year:
        w("## Лише вручну")
        w("")
        for it in man_year:
            w("- %d (%s): %s" % (it["seq"], it["man"].get("date"), manual[it["seq"]]))
        w("")
    if todo:
        w("## Не зроблено")
        w("")
        for it, why in todo:
            w("- %d (%s): %s" % (it["seq"], it["man"].get("date"), why))
        w("")

    w("## На вибірку")
    w("")
    if done:
        pick = sorted(random.Random(year).sample([it["seq"] for it in done], min(3, len(done))))
        w("Три випадкові номери (зерно — рік): **%s**. Переглянути цілком, незалежно від позначок." % ", ".join(str(x) for x in pick))
    else:
        w("Вибирати ще немає з чого.")
    w("")

    out = a.out or os.path.join(WORK, "pasport_%d.md" % year)
    with open(out, "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write("\n".join(L))
    print("паспорт %d: %s" % (year, out))
    print("номерів %d; звичайних %d: зроблено %d (без позначок %d, з позначками %d), не зроблено %d; лише вручну %d"
          % (len(issues), len(usual), len(done), len(done) - len(flagged), len(flagged), len(todo), len(man_year)))
    for it in flagged:
        print("  %d: позначок %d" % (it["seq"], len(it["full"]["flags"])))


if __name__ == "__main__":
    main()
