# -*- coding: utf-8 -*-
"""Ясна зупинка, коли Windows блокує модуль Python (02.10.2026, інструменти).

Smart App Control на цій машині час від часу блокує непідписані DLL: scipy — постійно, OpenCV (cv2) —
23.09, 28.09, 30.09 17:39-17:46, 01.10 22:06 (дані сесії «Оптимізація ноутбука»). Скрипт тоді падав
посеред роботи з `ImportError: DLL load failed ... An Application Control policy has blocked this file`,
а виклики з PowerShell із `2>$null` мовчки йшли запасним шляхом: дірка лишалася незарощеною, перекреслене
ручкою розпізнавалося без маски. Тут — одна перевірка з одним зрозумілим рядком і сталим кодом виходу.

У скрипті, перед `import cv2`:
    import ns_modcheck
    ns_modcheck.need("cv2")
Окремо (з PowerShell: `Test-NsPyModules` у ns-lib.ps1):
    python ns_modcheck.py            набір img: numpy, PIL, cv2
    python ns_modcheck.py ocr        img + pikepdf, img2pdf, ocrmypdf
    python ns_modcheck.py cv2 numpy  названі модулі
    python ns_modcheck.py --lock        записати requirements.lock (pip freeze + sha256 DLL/PYD пакетів)
    python ns_modcheck.py --lock-check  звірити встановлене з requirements.lock (0 — без розбіжностей)
Код виходу 0 — усе вантажиться (друкує версії); 42 — щось не вантажиться: рядок «ЗУПИНКА: …» у stdout.
Блокування НЕ обходити (копії DLL, інший Python, вимкнення захисту) — сказати оператору.
NS_TEST_BLOCK=cv2 (змінна середовища) удає блокування названих модулів — лише щоб випробувати зупинку.
"""
import importlib
import os
import sys

EXIT_BLOCKED = 42
SETS = {
    "img": ("numpy", "PIL.Image", "cv2"),
    "ocr": ("numpy", "PIL.Image", "cv2", "pikepdf", "img2pdf", "ocrmypdf"),
}
NAMES = {"cv2": "OpenCV (cv2)", "PIL.Image": "Pillow (PIL)"}


def probe(mods):
    """[(модуль, чи це блокування Windows, текст помилки)] для модулів, що не вантажаться."""
    bad = []
    fake = [x for x in os.environ.get("NS_TEST_BLOCK", "").split(",") if x]   # лише для проб зупинки
    for m in mods:
        if m in fake:
            bad.append((m, True, "ImportError: DLL load failed while importing %s: An Application Control policy has "
                                 "blocked this file. (УДАВАНЕ: NS_TEST_BLOCK)" % m))
            continue
        try:
            importlib.import_module(m)
        except Exception as e:                      # ImportError, OSError від DLL тощо
            txt = "%s: %s" % (type(e).__name__, e)
            low = txt.lower()
            bad.append((m, "application control" in low or "blocked" in low, txt))
    return bad


def message(bad, what):
    parts = []
    for m, blocked, txt in bad:
        parts.append("%s %s" % (NAMES.get(m, m), "заблоковано Windows (Smart App Control)" if blocked else "не вантажиться"))
    return ("ЗУПИНКА: %s — %s не виконано. Не обходити; сказати оператору. [%s]"
            % ("; ".join(parts), what, " | ".join(t for _, _, t in bad)))


def need(*mods, what=None):
    """Перевірити модулі; якщо котрийсь не вантажиться — рядок «ЗУПИНКА» і вихід із кодом 42."""
    bad = probe(mods)
    if bad:
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
        print(message(bad, what or os.path.basename(sys.argv[0] or "скрипт")), flush=True)
        sys.exit(EXIT_BLOCKED)


LOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements.lock")
NATIVE_PKGS = ("cv2", "numpy", "numpy.libs", "PIL", "pillow.libs", "pikepdf", "pikepdf.libs", "lxml", "scipy", "scipy.libs")


def lock_state():
    """(рядки pip freeze, {відносний шлях: (sha256, розмір)}) — версії пакетів і хеші їхніх DLL/PYD.
    Smart App Control вирішує за ХЕШЕМ файлу: оновлений пакет — це новий файл із новим вердиктом."""
    import hashlib
    import subprocess
    import sysconfig
    fr = subprocess.run([sys.executable, "-m", "pip", "freeze"], capture_output=True, text=True, encoding="utf-8").stdout
    site = sysconfig.get_paths()["purelib"]
    files = {}
    for pkg in NATIVE_PKGS:
        root = os.path.join(site, pkg)
        for dp, _, fns in os.walk(root):
            for fn in fns:
                if fn.lower().endswith((".pyd", ".dll")):
                    p = os.path.join(dp, fn)
                    h = hashlib.sha256()
                    with open(p, "rb") as f:
                        for blk in iter(lambda: f.read(1 << 20), b""):
                            h.update(blk)
                    files[os.path.relpath(p, site).replace("\\", "/")] = (h.hexdigest(), os.path.getsize(p))
    return [l.strip() for l in fr.splitlines() if l.strip()], files


def lock_write(path):
    import datetime
    freeze, files = lock_state()
    out = ["# requirements.lock — версії пакетів Python проєкту «Наше слово» і хеші їхніх DLL/PYD.",
           "# Записано %s, Python %s. Пакети БЕЗ ПОТРЕБИ НЕ ОНОВЛЮВАТИ: Smart App Control вирішує за хешем"
           % (datetime.date.today().isoformat(), sys.version.split()[0]),
           "# файлу, оновлений пакет — новий файл і новий вердикт. Звірка: python ns_modcheck.py --lock-check",
           "# Оновити запис (лише після свідомого оновлення пакета): python ns_modcheck.py --lock", ""]
    out += freeze
    out += ["", "# хеші DLL/PYD пакетів: sha256, розмір у байтах, файл відносно site-packages"]
    out += ["# sha256 %s %d %s" % (h, sz, rel) for rel, (h, sz) in sorted(files.items())]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("записано %s: пакетів %d, DLL/PYD %d" % (path, len(freeze), len(files)))


def lock_check(path):
    if not os.path.exists(path):
        print("немає %s — спершу python ns_modcheck.py --lock" % path)
        return 1
    want_pk, want_f = {}, {}
    for l in open(path, encoding="utf-8"):
        l = l.strip()
        if l.startswith("# sha256 ") and len(l.split(" ", 4)) == 5 and len(l.split(" ", 4)[2]) == 64:
            _, _, h, sz, rel = l.split(" ", 4)
            want_f[rel] = (h, int(sz))
        elif l and not l.startswith("#"):
            want_pk[l.split("==")[0].split(" @ ")[0].lower()] = l
    freeze, files = lock_state()
    have_pk = {l.split("==")[0].split(" @ ")[0].lower(): l for l in freeze}
    diff = []
    for k in sorted(set(want_pk) | set(have_pk)):
        if want_pk.get(k) != have_pk.get(k):
            diff.append("пакет: %s -> %s" % (want_pk.get(k, "(не було)"), have_pk.get(k, "(немає)")))
    for k in sorted(set(want_f) | set(files)):
        if want_f.get(k) != files.get(k):
            diff.append("файл:  %s %s" % (k, "ЗМІНЕНО" if k in want_f and k in files else ("новий" if k in files else "зник")))
    for d in diff:
        print(d)
    print("звірка з %s: пакетів %d, DLL/PYD %d, розбіжностей %d" % (os.path.basename(path), len(have_pk), len(files), len(diff)))
    return 1 if diff else 0


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if sys.argv[1:2] == ["--lock"]:
        lock_write(sys.argv[2] if len(sys.argv) > 2 else LOCK)
        return
    if sys.argv[1:2] == ["--lock-check"]:
        sys.exit(lock_check(sys.argv[2] if len(sys.argv) > 2 else LOCK))
    args = sys.argv[1:] or ["img"]
    what = "робота"
    if "--what" in args:
        i = args.index("--what")
        what = args[i + 1]
        del args[i:i + 2]
    mods = []
    for a in args or ["img"]:
        mods += list(SETS.get(a, (a,)))
    mods = list(dict.fromkeys(mods))
    bad = probe(mods)
    if bad:
        print(message(bad, what), flush=True)
        sys.exit(EXIT_BLOCKED)
    vers = []
    for m in mods:
        mod = sys.modules[m.split(".")[0]]
        vers.append("%s %s" % (m.split(".")[0], getattr(mod, "__version__", "?")))
    print("модулі Python гаразд: " + ", ".join(vers))


if __name__ == "__main__":
    main()
