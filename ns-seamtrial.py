# -*- coding: utf-8 -*-
"""Проба шва в піску без повного ns-render (01.10.2026, інструменти). Лише для дослідів.

  python ns-seamtrial.py <номер> <seam 1|2|3> <сторінки для виміру, напр. p07> [зрізи: p10:R:8.25,...]

Потрібна тимчасова тека ns_render_<номер> у TEMP від
  ns-render -Seq N -PaperPad -PadGrain patch -KeepTmp   (з NS_TEST_WORK = пісок).
Бере звідти _paperpad_job.json і PNG після балансу, ставить job "grain": "patch", "seam": N і
(якщо задано) ручний прямий зріз боку cut_mm; запускає ns-paperpad.py. Виходи — лише в пісок
_seam_sandbox/<номер>/render_seam<N> (JPEG q70 усіх сторінок) і masks_seam<N>; для названих
сторінок друкує рядки ns-seamprobe. Каталогу й робочих тек номерів не чіпає.
"""
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SANDBOX = "C:/NS_WORK/_seam_sandbox"


def main():
    seq, seam, pages = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(",")
    tmp = os.path.join(os.environ["TEMP"], "ns_render_" + seq)
    job = json.load(io.open(os.path.join(tmp, "_paperpad_job.json"), encoding="utf-8-sig"))
    od = os.path.join(tmp, "seam%d" % seam)
    rd = "%s/%s/render_seam%d" % (SANDBOX, seq, seam)
    md = "%s/%s/masks_seam%d" % (SANDBOX, seq, seam)
    for d in (od, rd, md):
        os.makedirs(d, exist_ok=True)
    job["grain"] = "patch"
    job["seam"] = seam
    job["mask_dir"] = md
    job["report"] = rd + "/_paperpad.json"
    cuts = [x.split(":") for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else []
    for p in job["pages"]:
        for nm, sd, v in cuts:
            if nm == p["name"]:
                p.setdefault("cut_mm", {})[sd] = float(v)
        p["out"] = os.path.join(od, p["name"] + "_pp.png")
    jf = os.path.join(od, "job.json")
    json.dump(job, io.open(jf, "w", encoding="utf-8"), ensure_ascii=False)
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    r = subprocess.run([sys.executable, os.path.join(HERE, "ns-paperpad.py"), jf], env=env,
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-3000:])
        sys.exit(1)
    rep = json.load(io.open(rd + "/_paperpad.json", encoding="utf-8"))
    for pg in rep["pages"]:
        if pg["page"] in pages:
            print(pg["page"], "бруд/зріз", {k: (v["max_mm"], v.get("cut_mm")) for k, v in pg["dirt"].items()},
                  "доп.", pg["pad_mm"], "поля друку", pg["margin_block_mm"],
                  "латки", {k: v for k, v in (pg.get("grain_patch") or {}).items() if k != "stage"})
    print("темних у доданому:", sum(p.get("synth_dark_px", 0) for p in rep["pages"]), "на", len(rep["pages"]), "стор.")
    for p in job["pages"]:
        subprocess.run(["magick", p["out"], "-units", "PixelsPerInch", "-density", "300x300", "-quality", "70",
                        "%s/%s.jpg" % (rd, p["name"])], check=True)
    for n in pages:
        r = subprocess.run([sys.executable, os.path.join(HERE, "ns-seamprobe.py"), "%s/%s.jpg" % (rd, n),
                            "%s/%s_synth.png" % (md, n)], env=env, capture_output=True, text=True, encoding="utf-8")
        print("\n".join(ln for ln in r.stdout.splitlines()
                        if "стик" in ln or "шов  " in ln or "3-6 мм" in ln or (ln.startswith("  ") and ln[2:4] in ("L:", "R:", "T:", "B:"))))


if __name__ == "__main__":
    main()
