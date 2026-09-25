# ns-edgescan.py — детектор залишених смуг краю в готових PDF.
#   python ns-edgescan.py C:\NS_PDF\2001          усі PDF у теці
#   python ns-edgescan.py C:\NS_PDF\2001\2266.pdf один номер
# Рендер на 40 dpi, смуга 3 мм від КРАЮ СТОРІНКИ (рамку пропускає), для кожної
# позиції — НАЙТЕМНІША точка вглиб (мінімум, не середнє), частка позицій
# темніших за 100; поріг 0,40. Перед роботою — контроль на штучних сторінках,
# включно зі сторінкою в білій рамці; не пройшов — рахувати відмовляється.
# Автор — сесія старого лептопа (18.09.2026); до того запускався з тимчасової
# теки й тому не переїхав. Виправлено сліпоту: міряв зовнішні 3 мм, а на PDF
# з рамкою 7-8 мм це сама рамка.
import subprocess, sys, os, glob, tempfile
sys.stdout.reconfigure(encoding="utf-8")
DPI, BAND_MM, THR, FRAC = 40, 3.0, 100, 0.40

def frame_depth(gray, w, h, side, maxd):
    for k in range(maxd):
        if side == "T":   line = gray[k*w:(k+1)*w]
        elif side == "B": line = gray[(h-1-k)*w:(h-k)*w]
        elif side == "L": line = gray[k::w]
        else:             line = gray[w-1-k::w]
        n = len(line); mid = line[n//4:3*n//4]
        if min(mid) < 235: return k
    return 0

def edges_of_png(img):
    w, h = [int(x) for x in subprocess.run(["magick","identify","-format","%w|%h",img],capture_output=True,text=True).stdout.split("|")]
    d = max(3, int(BAND_MM/25.4*DPI)); res = {}
    gray = subprocess.run(["magick",img,"-alpha","off","-colorspace","Gray","-depth","8","gray:-"],capture_output=True).stdout
    maxd = int(20/25.4*DPI)
    for side in "TBLR":
        f = frame_depth(gray, w, h, side, maxd)
        crop = {"T":f"{w}x{d}+0+{f}","B":f"{w}x{d}+0+{h-d-f}","L":f"{d}x{h}+{f}+0","R":f"{d}x{h}+{w-d-f}+0"}[side]
        raw = subprocess.run(["magick",img,"-alpha","off","-crop",crop,"+repage","-colorspace","Gray","-depth","8","gray:-"],capture_output=True).stdout
        if not raw: res[side] = -1.0; continue
        cw, ch = (w, d) if side in "TB" else (d, h)
        mins = ([min(raw[r*cw+c] for r in range(ch)) for c in range(cw)] if side in "TB"
                else [min(raw[r*cw+c] for c in range(cw)) for r in range(ch)])
        res[side] = sum(1 for v in mins if v < THR) / len(mins)
    return res

def self_test(tmp):
    W, H = int(300/25.4*DPI), int(420/25.4*DPI)
    px = lambda mm: max(1, int(mm/25.4*DPI))
    cases = {
        "чиста": ([], {}, 0),
        "лінія 1 мм справа": ([f"rectangle {W-px(1)},0 {W},{H}"], {"R":1}, 0),
        "смуга 8 мм зліва": ([f"rectangle 0,0 {px(8)},{H}"], {"L":1}, 0),
        "у рамці, чиста": ([], {}, 8),
        "у рамці, лінія 1 мм справа": ([f"rectangle {W-px(1)},0 {W},{H}"], {"R":1}, 8),
    }
    ok = True
    for name, (draws, want, frame_mm) in cases.items():
        f = os.path.join(tmp, "ctl.png")
        args = ["magick","-size",f"{W}x{H}","xc:rgb(240,240,240)","-fill","rgb(30,30,30)"]
        for dr in draws: args += ["-draw", dr]
        if frame_mm:
            fr = px(frame_mm); args += ["-bordercolor","rgb(255,255,255)","-border",f"{fr}x{fr}"]
        subprocess.run(args + [f])
        got = edges_of_png(f)
        for s in "TBLR":
            if (got[s] >= FRAC) != (want.get(s,0) == 1):
                ok = False; print(f"  КОНТРОЛЬ ЗБІЙ: {name}, край {s}: {got[s]:.2f}")
    return ok

def main():
    target = sys.argv[1]
    pdfs = sorted(glob.glob(os.path.join(target,"*.pdf"))) if os.path.isdir(target) else [target]
    tmp = tempfile.mkdtemp(prefix="ns_edge_")
    if not self_test(tmp):
        print("Детектор НЕ пройшов контроль — рахувати не буду."); sys.exit(1)
    print("контроль пройдено\n"); found = 0
    for pdf in pdfs:
        seq = os.path.splitext(os.path.basename(pdf))[0]
        for f in glob.glob(os.path.join(tmp,"s-*.png")): os.remove(f)
        subprocess.run(["pdftoppm","-r",str(DPI),"-png",pdf,os.path.join(tmp,"s")],capture_output=True)
        worst = 0.0
        for img in sorted(glob.glob(os.path.join(tmp,"s-*.png"))):
            pg = int(os.path.splitext(img)[0].rsplit("-",1)[1])
            for side, fr in edges_of_png(img).items():
                worst = max(worst, fr)
                if fr >= FRAC:
                    found += 1; print(f"  {seq} стор.{pg:2d} край {side}: темно на {fr*100:.0f} %")
        print(f"  {seq}: найтемніший край {worst*100:.0f} %")
    print(f"\nкраїв зі смугою: {found}  — позначене дивитися очима: рамка календаря чи фото навиліт теж дають смугу.")

if __name__ == "__main__":
    main()
