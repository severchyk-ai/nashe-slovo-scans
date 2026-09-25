# Етап 3b — вигляд. Баланс білого, колір, зменшення до 300 dpi,
# доповнення полів до спільного розміру, кодування в JPEG.
#
#   .\ns-render.ps1 -Seq 2231
#
# Вхід : C:\NS_WORK\<номер>\prep\pNN.tif    (400 dpi після етапу 3)
# Вихід: C:\NS_WORK\<номер>\render\pNN.jpg  (300 dpi, q55)
#
# Чому 300 dpi: це роздільність архіву 1956-1999, поруч з яким ці номери
# стоятимуть, і на ній різкість тексту виходить навіть кращою за еталонний
# 2183 (13,1 % півтонів на краях літер проти 13,8 %). Спершу тут було 200 dpi,
# обране за виміряною точністю OCR (0,57 % проти 0,84 % на 400 dpi) — але
# 300 dpi тоді просто не перевіряли, а на точність OCR роздільність у діапазоні
# 200-300 практично не впливає: різниця в межах шуму.
# Окремого етапу зменшення через Ghostscript немає: усе робить ImageMagick.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [int]$Dpi = 300,
    [int]$Quality = 55,
    [int]$Saturation = 125,
    [int]$PaperTarget = 244,
    [switch]$Force,
    [switch]$Descreen,      # растрове згладжування — тепер ВИМКНЕНЕ за умовчанням
    [int]$FrameTone = 255,   # тон рамки навколо сторінки: біла (рішення 16.09.2026)
    [double]$FrameMm = 7.0,  # стала ширина рамки (7 мм з 17.09.2026 — як у PDF 2225; 8 оператор назвав грубою)
    [switch]$HueFix,         # УВІМКНУТИ підгонку кольору під архів 1999; за умовчанням ВИМКНЕНА
    [switch]$FillEdge,       # стара поведінка: замальовувати край замість відрізати
    [switch]$NoBalance,
    [switch]$NoPad,
    [switch]$FitScale,            # застаріле: стиснення тепер увімкнене за умовчанням
    [switch]$NoFitScale,          # вимкнути стиснення ширших сторінок до спільного розміру
    [double]$FitScaleMaxPct = 4.0, # межа стиснення, % (погоджено оператором 21.09.2026)
    [double]$FitGrowMaxPct = 1.5,  # межа розтягнення вужчої за ціль сторінки, % (24.09.2026: рамка мусить бути однаковою з усіх боків)
    [switch]$NoWedge              # не знімати білі клини після випрямлення (стара поведінка)
)
# Стиснення до медіани номера — стандарт з 21.09.2026 (оператор: «виглядає
# добре» на 2294/2308: рамка 6,7-7,1 мм, 2294/1 стиснуто на 3,75 % по ширині).
$FitScale = -not $NoFitScale

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (-not (Test-NsTools -Need scan)) { Write-Host "Бракує інструментів." -ForegroundColor Red; exit 1 }

$prep = Join-Path (Join-Path $script:NS_WORK "$Seq") "prep"
if (-not (Test-Path $prep)) { Write-Host "Немає етапу prep для $Seq. Спершу ns-prep.ps1." -ForegroundColor Red; exit 1 }

$tifs = @(Get-ChildItem -Path $prep -Filter "p*.tif" -File | Sort-Object Name)
if ($tifs.Count -eq 0) { Write-Host "У $prep немає сторінок." -ForegroundColor Red; exit 1 }

$render = Get-NsWorkDir -Seq $Seq -Stage "render"

Write-Host ""
Write-Host "Етап 3b (вигляд): номер $Seq, $($tifs.Count) сторінок -> $Dpi dpi, JPEG q$Quality" -ForegroundColor Cyan
Write-Host ""

# --- прохід 1: тон, колір, різкість, зменшення -----------------------------
# Пишемо в PNG без втрат, щоб точні розміри після корекції можна було зміряти
# ДО доповнення полів і JPEG.
$tmp = Join-Path $env:TEMP ("ns_render_" + $Seq)
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# --- баланс білого: ОДИН НА НОМЕР, не на сторінку ---------------------------
# Спершу баланс рахувався окремо для кожної сторінки, і це давало помітну
# різницю між сусідніми сторінками одного номера: перша холодніша, четверта
# тепліша. Причина не в папері — відтінок B-R по сторінках 2225 тримається
# рівно 2-4, тобто папір скрізь однаковий. Гуляв сам ВИМІР: 218-227 залежно
# від того, скільки на сторінці друку. На густо задрукованій сторінці фільтр
# не витягує папір повністю й дає занижене число, і сторінка отримувала
# сильнішу поправку, ніж треба.
#
# Тому: міряємо всі сторінки, беремо 80-й перцентиль по кожному каналу
# (найменш задруковані сторінки показують справжній папір; медіана хилилася б
# до задрукованих, максимум — до випадкового викиду) і застосовуємо ОДНУ
# поправку до всього номера. Гортають саме номер, і різниця між сусідніми
# сторінками помітніша за різницю між номерами.
$balOps = @()
$balNote = "без балансу"
if (-not $NoBalance) {
    $mR = @(); $mG = @(); $mB = @()
    foreach ($t in $tifs) {
        $pc = Get-NsPaperColor -Path $t.FullName
        if ($pc) { $mR += $pc[0]; $mG += $pc[1]; $mB += $pc[2] }
    }
    if ($mR.Count -ge 1) {
        $q = { param($a) $s = @($a | Sort-Object); $s[[math]::Min($s.Count-1, [int]([math]::Floor($s.Count * 0.8)))] }
        $pr = & $q $mR; $pg = & $q $mG; $pb = & $q $mB
        # Ціль підібрана за архівом 1956-1999, міряним тією самою міркою
        # (папір по всій сторінці): там 244-250, і засвічується 0,66-1,18 %
        # сторінки. Наш вибір і його ціна:
        #     ціль 240 -> папір 240, засвічено 0,01 %
        #     ціль 244 -> папір 243, засвічено 0,22 %   <- беремо
        #     ціль 248 -> папір 246, засвічено 2,63 %
        #     ціль 252 -> папір 247, засвічено 18,03 %
        # 248 дав би папір точно як в архіві, але засвітив би вчетверо більше
        # за сам архів — а саме втрата світел (вибілені вікна на фотографіях)
        # і була скаргою оператора.
        foreach ($pair in @(@("R", $pr), @("G", $pg), @("B", $pb))) {
            $w = [math]::Round($pair[1] * 100.0 / $PaperTarget, 1)
            if ($w -lt 78) { $w = 78 }; if ($w -gt 100) { $w = 100 }
            $balOps += @("-channel", $pair[0], "-level", "0%,$w%")
        }
        $balOps += @("+channel")
        $balNote = "папір номера {0}/{1}/{2} -> ціль {3}" -f $pr, $pg, $pb, $PaperTarget
    }
}
Write-Host "  баланс білого: $balNote"
Write-Host ""

$pages = @()
foreach ($t in $tifs) {
    $png = Join-Path $tmp ($t.BaseName + ".png")
    $ops = @() + $balOps

    # Зсув відтінку на +3,6° (це і є «102»): наш синій логотипа лягає на 203,9°,
    # архівний — на 207,7-208,7°. Насиченість тепер безпечна, бо застосовується
    # ПІСЛЯ балансу: нейтральний піксель має нульову насиченість, множити його
    # ні на що, тож папір лишається нейтральним за будь-якого значення.
    # Насиченість і зсув відтінку підганяли наш колір під чужі скани 1999 року.
    # Виміряно на 2237 стор.1: без цього кроку синій логотип має насиченість
    # 56,2 % і відтінок 207,7° проти майстрових 58,1 % і 209,0°, а з ним —
    # 66,3 % і 212,1°. Тобто крок віддаляв від оригіналу, а не наближав.
    # Лишається лише за явною вимогою -HueFix.
    if ($HueFix) { $ops += @("-modulate", "100,$Saturation,102") }

    # Окремої тонової корекції тут БІЛЬШЕ НЕМАЄ. Раніше стояв
    # `-level 14%,92%` на всі канали разом: він піднімав папір, але заразом
    # зрізав світла (вікна на фотографіях вибілювалися начисто) і не лікував
    # синього відтінку паперу, бо діяв однаково на всі канали.
    # Баланс білого вище робить те саме коректніше: папір виходить нейтральним
    # і рівно тієї світлоти, що в архіві, а засвічується 0,07-0,09 % пікселів
    # замість помітної втрати деталі у світлах.

    # Дескринування ВИМКНЕНЕ за умовчанням. Воно згладжувало друкарський растр,
    # але коштувало саме тієї різкості, заради якої все й робиться. Виміряно на
    # стор. 3 номера 2231, частка півтонів на краях літер (менше = різкіше):
    #     розмиття ПІСЛЯ зменшення   19,7 %   <- як було найгірше
    #     розмиття ДО зменшення      14,9 %
    #     без розмиття, 300 dpi      11,4 %   <- тепер
    #     еталон 2183 (300 dpi)      13,8 %
    # На точність OCR не впливає жоден варіант: 2-5 підозрілих слів на 1500,
    # тобто в межах шуму. Зменшення 400 -> 300 саме по собі усереднює растр.
    # Вмикати `-Descreen`, якщо на якомусь номері з'явиться муар на фотографіях.
    if ($Descreen) { $ops += @("-gaussian-blur", "0x1.0", "-unsharp", "0x1.5+1.2+0.02") }

    # -resample використовує записану у файл роздільність, тому 400 -> 200 це
    # справжня зміна розміру, а не правка метаданих.
    $ops += @("-resample", "$Dpi")

    & magick $t.FullName @ops $png 2>$null | Out-Null
    if (-not (Test-Path $png)) { Write-Host "  ЗБІЙ на $($t.Name)" -ForegroundColor Red; exit 1 }

    $wh = (& magick identify -format "%w|%h" $png 2>$null) -split '\|'
    $pages += [pscustomobject]@{ Name = $t.BaseName; Path = $png; W = [int]$wh[0]; H = [int]$wh[1] }
}

# --- прохід 2: спільний розмір і JPEG --------------------------------------
# Навіть після обрізки сторінки виходять трохи різними: драйвер шукає край
# по-різному залежно від паперу. Якщо лишити як є, у переглядачі кожна друга
# сторінка «стрибає». Доповнення до спільного полотна по центру це прибирає,
# нічого не обрізаючи. Альбомні вкладки (календарі, свідомо повернуті)
# отримують власний спільний розмір, а не втискаються в книжковий.
#
# Колір доповнення — НЕ чисто білий, а той самий, у який баланс зводить папір.
# Чисто біла рамка (255) навколо паперу 243 читається як світліша облямівка по
# краю сторінки.
# Тон рамки — ВИМІРЯНИЙ тон паперу вже оброблених сторінок, а не стала 244.
# Ціль балансу 244 і справжній папір на сторінці — різні числа: баланс зводить
# до 244 ВИМІР паперу, а сам папір лягає на 236-246 залежно від сторінки.
# Беремо медіану по номеру: видимий стрибок між рамкою і папером падає з ~12
# одиниць до 3-4.
$tones = @()
# Міряємо тією самою функцією, що й скрізь у проєкті (перцентиль через
# локальні максимуми), а НЕ найяскравішою точкою: максимум узяв би відблиск
# або біле на фотографії, і рамка вийшла б світлішою за папір.
foreach ($p in $pages) {
    $pc = Get-NsPaperColor -Path $p.Path
    if ($pc) { $tones += [int](($pc[0] + $pc[1] + $pc[2]) / 3) }
}
$paperTone = if ($tones.Count) { (@($tones | Sort-Object))[[int]($tones.Count/2)] } else { $PaperTarget }
if ($paperTone -lt 200 -or $paperTone -gt 255) { $paperTone = $PaperTarget }
# ДВА РІЗНІ ТОНИ, і це не випадковість:
#  - заливка краю лежить УСЕРЕДИНІ сторінки (затирає проколи й тінь обрізу),
#    тож вона має бути кольором паперу, інакше вийде смуга поперек аркуша;
#  - рамка лежить ЗОВНІ сторінки, це вже не газета, а тло. Спершу її зробили
#    майже чорною (58), як у архіві 1956-1999 з трьох боків; 16.09.2026
#    оператор із керівництвом обрали БІЛУ (255). Папір 244 на білому тлі
#    лишається видимим як ледь сіріший прямокутник — так само, як у архіві
#    на лівому краї (поле 253, папір 233).
$fillColor  = "rgb($paperTone,$paperTone,$paperTone)"
$frameColor = "rgb($FrameTone,$FrameTone,$FrameTone)"
Write-Host "  заливка краю: $paperTone (папір номера); рамка: $FrameTone, ширина $FrameMm мм"

# Глибини вичищення краю, виміряні на етапі 3. Заливку накладаємо ТУТ, після
# балансу, тим самим тоном, що й доповнення.
$edgeMm = @{}
$edgeFile = Join-Path $prep "_edge.txt"
if (Test-Path $edgeFile) {
    foreach ($ln in (Get-Content $edgeFile)) {
        if ($ln -match '^p(\d+)\s+T=([\d.]+)\s+B=([\d.]+)\s+L=([\d.]+)\s+R=([\d.]+)') {
            # ключ береться ДО другого -match: той перезаписує $Matches, і
            # 18.09.2026 запис p01 ліг під ключ «p12» (з fT=12.5) — жодна
            # сторінка не отримала ні зрізання бруду, ні зведення розміру.
            $key = "p{0:D2}" -f [int]$Matches[1]
            $rec = @{
                Top = [double]$Matches[2]; Bottom = [double]$Matches[3]
                Left = [double]$Matches[4]; Right = [double]$Matches[5]
                fTop = 0.0; fBottom = 0.0; fLeft = 0.0; fRight = 0.0 }
            # запас до вмісту (з 17.09.2026; у старих _edge.txt його немає — тоді 0)
            if ($ln -match 'fT=([\d.]+)\s+fB=([\d.]+)\s+fL=([\d.]+)\s+fR=([\d.]+)') {
                $rec.fTop = [double]$Matches[1]; $rec.fBottom = [double]$Matches[2]
                $rec.fLeft = [double]$Matches[3]; $rec.fRight = [double]$Matches[4]
            }
            $edgeMm[$key] = $rec
        }
    }
}
# Брудний край (проколи від нитки, тінь обрізу, залишки скла) ВІДРІЗАЄМО,
# а не замальовуємо. Оператор обрав це, подивившись обидва варіанти поруч:
# замальований край лишає ледь помітну смугу іншого тону, відрізаний — ні,
# папір переходить одразу в рамку. Друкованого не втрачаємо: текст скрізь
# починається не ближче ніж за 9 мм від краю, а ріжемо щонайбільше 7
# (винятки прописані в маніфесті номера, напр. 2237 стор.2 — 12,5 мм).
# Розміри після обрізки потрібні ДО того, як рахувати спільне полотно,
# інакше рамка вийде різної ширини.
foreach ($p in $pages) {
    $cx = 0; $cy = 0; $cw = $p.W; $ch = $p.H
    if (-not $FillEdge -and $edgeMm.ContainsKey($p.Name)) {
        $e = $edgeMm[$p.Name]
        $t = [int]($e.Top / 25.4 * $Dpi);  $b = [int]($e.Bottom / 25.4 * $Dpi)
        $l = [int]($e.Left / 25.4 * $Dpi); $r = [int]($e.Right / 25.4 * $Dpi)
        if (($t + $b + $l + $r) -gt 0 -and ($p.W - $l - $r) -gt 200 -and ($p.H - $t - $b) -gt 200) {
            $cx = $l; $cy = $t; $cw = $p.W - $l - $r; $ch = $p.H - $t - $b
        }
    }
    $p | Add-Member -NotePropertyName CX -NotePropertyValue $cx -Force
    $p | Add-Member -NotePropertyName CY -NotePropertyValue $cy -Force
    $p | Add-Member -NotePropertyName CW -NotePropertyValue $cw -Force
    $p | Add-Member -NotePropertyName CH -NotePropertyValue $ch -Force
}

# ПРЯМИЙ КРАЙ (24.09.2026, оператор: «рамка повинна бути однакова з усіх
# чотирьох сторін»). Після випрямлення перекосу в ns-prep полотно має білі
# клини, і край паперу йде навскіс на 0,3-2,8 мм: клин зливається з білою
# рамкою, і вона виглядає нерівною (2323/9, 10: 6,8 проти 8,2 мм; вимір
# `python ns-framecheck.py <render>`). Знімаємо клин з кожного боку на його
# НАЙБІЛЬШУ глибину (ns-wedge.py міряє її в 25 місцях уздовж краю) — край
# стає прямим. Знята смужка — порожнє поле, тож і запас чистого поля до
# друку (fT..fR) зменшується на неї, щоб зведення розміру не зайшло в друк.
$wedgeLog = @()
if (-not $NoWedge) {
    foreach ($p in $pages) {
        $wo = & python "$PSScriptRoot\ns-wedge.py" $p.Path $p.CX $p.CY $p.CW $p.CH 2>$null
        if ("$wo" -match '^(\d+) (\d+) (\d+) (\d+)$') {
            $wl = [int]$Matches[1]; $wr = [int]$Matches[2]; $wt = [int]$Matches[3]; $wb = [int]$Matches[4]
            if (($wl + $wr + $wt + $wb) -gt 0 -and ($p.CW - $wl - $wr) -gt 200 -and ($p.CH - $wt - $wb) -gt 200) {
                $p.CX += $wl; $p.CY += $wt; $p.CW -= ($wl + $wr); $p.CH -= ($wt + $wb)
                if ($edgeMm.ContainsKey($p.Name)) {
                    $e = $edgeMm[$p.Name]; $k = 25.4 / $Dpi
                    $e.fLeft   = [math]::Max(0, $e.fLeft   - $wl * $k); $e.fRight  = [math]::Max(0, $e.fRight  - $wr * $k)
                    $e.fTop    = [math]::Max(0, $e.fTop    - $wt * $k); $e.fBottom = [math]::Max(0, $e.fBottom - $wb * $k)
                }
                $wedgeLog += ("{0}: клин знято л{1:N1} п{2:N1} в{3:N1} н{4:N1} мм" -f $p.Name, ($wl*25.4/$Dpi), ($wr*25.4/$Dpi), ($wt*25.4/$Dpi), ($wb*25.4/$Dpi))
            }
        }
    }
    foreach ($ln in $wedgeLog) { Write-Host "  $ln" -ForegroundColor DarkGray }
}

# РАМКА: FrameMm з усіх боків навколо спільного розміру групи (див. нижче).
# 17.09.2026 пробували «кожна сторінка = свій папір + рамка» — рамка однакова,
# але сторінки різного розміру, і оператор це відкинув.
$fm = [int]($FrameMm / 25.4 * $Dpi)

# ОДИН РОЗМІР СТОРІНОК НОМЕРА (18.09.2026). «Кожна сторінка = папір + рамка»
# дало однакову рамку, але різні розміри сторінок — оператор: «сторінки вийшли
# різні розміром». Тому сторінки групи (книжкові окремо, альбомні окремо)
# ЗРІЗАЮТЬСЯ до спільного розміру за рахунок чистого поля: ns-prep виміряв на
# кожному краї запас до друку (fT..fR у _edge.txt, з 1,5 мм відступу), і лишок
# знімається з країв пропорційно запасу. Ціль — найменша сторінка групи, але не
# менша, ніж дозволяє запас найтіснішої: друк не ріжемо заради формату. Якщо
# якась сторінка все ж менша за ціль — доповнюється рамкою, і журнал це каже.
function Get-NsSpan([int]$Extra, [double]$FreeA, [double]$FreeB, [int]$Dpi) {
    $fa = [int]($FreeA / 25.4 * $Dpi); $fb = [int]($FreeB / 25.4 * $Dpi)
    if ($Extra -le 0 -or ($fa + $fb) -le 0) { return @(0, 0) }
    $take = [math]::Min($Extra, $fa + $fb)
    $a = [math]::Min($fa, [int][math]::Round($take * $fa / ($fa + $fb)))
    $b = [math]::Min($fb, $take - $a); $a = [math]::Min($fa, $take - $b)
    return @($a, $b)
}
$groupSize = @{}
if (-not $NoPad) {
    $mmPx = $Dpi / 25.4
    foreach ($land in @($false, $true)) {
        $items = @($pages | Where-Object { ($_.CW -gt $_.CH) -eq $land })
        if ($items.Count -eq 0) { continue }
        $minW = 0; $minH = 0; $floorW = 0; $floorH = 0
        foreach ($p in $items) {
            $e = if ($edgeMm.ContainsKey($p.Name)) { $edgeMm[$p.Name] } else { @{ fTop=0; fBottom=0; fLeft=0; fRight=0 } }
            $p | Add-Member -NotePropertyName Free -NotePropertyValue $e -Force
            if ($minW -eq 0 -or $p.CW -lt $minW) { $minW = $p.CW }
            if ($minH -eq 0 -or $p.CH -lt $minH) { $minH = $p.CH }
            $fw = $p.CW - [int](($e.fLeft + $e.fRight) * $mmPx); $fh = $p.CH - [int](($e.fTop + $e.fBottom) * $mmPx)
            if ($fw -gt $floorW) { $floorW = $fw }; if ($fh -gt $floorH) { $floorH = $fh }
        }
        $tw = [math]::Max($minW, $floorW); $th = [math]::Max($minH, $floorH)
        # -FitScale (21.09.2026): ціль — ТИПОВА сторінка (медіана того, до чого
        # кожну можна зрізати), а не найширша. Інакше одна сторінка з логотипом
        # під край (2294/1, край не ріжемо за вказівкою) роздувала ціль, і ключ
        # РОЗТЯГУВАВ дев'ять інших на 1,5-3,9 %. Ширші за ціль стискаються, але
        # не більше FitScaleMaxPct — якщо треба більше, ціль піднімається.
        if ($FitScale) {
            $fws = @(); $fhs = @()
            foreach ($p in $items) {
                $fws += [math]::Max(1, $p.CW - [int](($p.Free.fLeft + $p.Free.fRight) * $mmPx))
                $fhs += [math]::Max(1, $p.CH - [int](($p.Free.fTop + $p.Free.fBottom) * $mmPx))
            }
            $sw = @($fws | Sort-Object); $sh = @($fhs | Sort-Object)
            $tw = [math]::Max($minW, $sw[[int][math]::Floor(($sw.Count - 1) / 2)])
            $th = [math]::Max($minH, $sh[[int][math]::Floor(($sh.Count - 1) / 2)])
            $k = 1 + $FitScaleMaxPct / 100.0
            foreach ($v in $fws) { if ($v -gt $tw * $k) { $tw = [int][math]::Ceiling($v / $k) } }
            foreach ($v in $fhs) { if ($v -gt $th * $k) { $th = [int][math]::Ceiling($v / $k) } }
        }
        foreach ($p in $items) {
            $lr = Get-NsSpan -Extra ($p.CW - $tw) -FreeA $p.Free.fLeft -FreeB $p.Free.fRight -Dpi $Dpi
            $tb = Get-NsSpan -Extra ($p.CH - $th) -FreeA $p.Free.fTop  -FreeB $p.Free.fBottom -Dpi $Dpi
            $p.CX += $lr[0]; $p.CW -= ($lr[0] + $lr[1])
            $p.CY += $tb[0]; $p.CH -= ($tb[0] + $tb[1])
            $dw = ($tw - $p.CW) / $mmPx; $dh = ($th - $p.CH) / $mmPx
            if ([math]::Abs($dw) -gt 0.5 -or [math]::Abs($dh) -gt 0.5) {
                Write-Host ("  {0}: не зведено до спільного розміру ({1:+0.0;-0.0} x {2:+0.0;-0.0} мм) — бракує чистого поля" -f $p.Name, -$dw, -$dh) -ForegroundColor Yellow
            }
        }
        $cw = [int](($items.CW | Measure-Object -Maximum).Maximum); $ch = [int](($items.CH | Measure-Object -Maximum).Maximum)
        if ($FitScale) { $cw = [int]$tw; $ch = [int]$th }   # ширші стиснуться до цілі в рендері
        $groupSize[$land] = @($cw, $ch)
    }
}

# Тон заливки міряємо ДЛЯ КОЖНОЇ СТОРІНКИ і саме в тому кільці, де заливка
# межує з папером (8-15 мм від краю), а не по центру сторінки.
# Чому не по центру: там більше друку, і число виходить заниженим. На 2227
# стор. 3 центр дає 240, а папір біля краю — 246; заливка 240 лишала видиму
# смугу. Чому не одне число на номер: у 2227 зовнішній аркуш (стор. 1, 2, 9, 10)
# має 235, а внутрішні 246-247 — одним тоном обидва не накриєш.
function Get-NsEdgePaperTone {
    param([string]$Path, [int]$W, [int]$H, [int]$Dpi)
    $a = [int](8.0 / 25.4 * $Dpi); $b = [int](12.0 / 25.4 * $Dpi); $t = $b - $a
    if ($t -lt 4 -or $W -lt 4*$b -or $H -lt 4*$b) { return $null }
    $vals = @()
    foreach ($crop in @("$($W - 2*$a)x$t+$a+$a", "$($W - 2*$a)x$t+$a+$($H - $b)",
                        "${t}x$($H - 2*$a)+$a+$a", "${t}x$($H - 2*$a)+$($W - $b)+$a")) {
        # ЗВИЧАЙНЕ СЕРЕДНЄ, не Maximum: у цій смузі майже самий папір, тож
        # середнє і є папір. Перевірено на 2227: середнє влучає точно
        # (233/245/245/232 при цілях 233/245/245/232), а Maximum завищує на
        # 5-7 одиниць, бо бере найяскравішу цятку у вікні — саме через це
        # перша версія зробила заливку СВІТЛІШОЮ за папір.
        $o = & magick $Path -alpha off -crop $crop +repage -colorspace Gray `
                     -format "%[fx:int(255*mean)]" info: 2>$null
        if ("$o" -match '^\d+$') { $vals += [int]$o }
    }
    if ($vals.Count -eq 0) { return $null }
    return (@($vals | Sort-Object))[[int]($vals.Count / 2)]
}

$total = 0
foreach ($p in $pages) {
    $jpg = Join-Path $render ($p.Name + ".jpg")
    # -units PixelsPerInch обов'язковий. Без нього ImageMagick пише щільність
    # у JFIF цілими точками на сантиметр: 200 dpi = 78,74 -> 78, і сторінка в
    # PDF виходить на 1 % більшою за справжню (305,2 мм замість 302,1).
    # Проміжний PNG тут ні до чого — він зберігає точки на метр і точний.
    $dens = @("-units", "PixelsPerInch", "-density", "${Dpi}x${Dpi}")
    $draw = @()
    if (($p.CW -ne $p.W) -or ($p.CH -ne $p.H)) {
        $draw = @("-crop", "$($p.CW)x$($p.CH)+$($p.CX)+$($p.CY)", "+repage")
    }
    if ($FillEdge -and $edgeMm.ContainsKey($p.Name)) {
        $e = $edgeMm[$p.Name]
        $t = [int]($e.Top / 25.4 * $Dpi); $b = [int]($e.Bottom / 25.4 * $Dpi)
        $l = [int]($e.Left / 25.4 * $Dpi); $r = [int]($e.Right / 25.4 * $Dpi)
        if ($t -gt 0) { $draw += @("-draw", "rectangle 0,0 $($p.W),$t") }
        if ($b -gt 0) { $draw += @("-draw", "rectangle 0,$($p.H - $b) $($p.W),$($p.H)") }
        if ($l -gt 0) { $draw += @("-draw", "rectangle 0,0 $l,$($p.H)") }
        if ($r -gt 0) { $draw += @("-draw", "rectangle $($p.W - $r),0 $($p.W),$($p.H)") }
        # тон саме цієї сторінки; якщо вимір зірвався або різко випадає
        # (кольоровий розворот, де фото заходять у поля — 2244 стор. 5 дала 90),
        # беремо медіану по номеру
        $pt = Get-NsEdgePaperTone -Path $p.Path -W $p.W -H $p.H -Dpi $Dpi
        if ($null -eq $pt -or [math]::Abs($pt - $paperTone) -gt 25) { $pt = $paperTone }
        $pageFill = "rgb($pt,$pt,$pt)"
        if ($draw.Count -gt 0) { $draw = @("-fill", $pageFill, "-stroke", "none") + $draw }
    }
    if ($NoPad) {
        & magick $p.Path @draw @dens -quality $Quality $jpg 2>$null | Out-Null
        $note = "{0}x{1}" -f $p.W, $p.H
    } else {
        $gs = $groupSize[($p.CW -gt $p.CH)]; $tw = $gs[0] + 2 * $fm; $th = $gs[1] + 2 * $fm
        # -FitScale: коли чистого поля забракло, різниця в 1-3 мм лишається як
        # ширша рамка. Ключ натомість стискає сторінку рівно до спільного
        # розміру — але не більше ніж на FitScaleMaxPct (за умовчанням 1,5 %),
        # інакше це вже спотворення, а не вирівнювання.
        if ($FitScale) {
            # стискаємо ширшу за ціль (до FitScaleMaxPct) і РОЗТЯГУЄМО вужчу
            # (до FitGrowMaxPct): інакше вужча сторінка доповнюється рамкою з двох
            # боків більше, ніж з двох інших, а рамка має бути однаковою з усіх
            # чотирьох (24.09.2026). Розтягнення на 1,5 % — 6 мм на 400 мм, не помітно;
            # більше вже не робимо (2294, 21.09.2026: 1,5-3,9 % розтягнення відкинуто).
            $nw = $gs[0]; $nh = $gs[1]
            $dx = ($nw / [double]$p.CW - 1) * 100; $dy = ($nh / [double]$p.CH - 1) * 100
            $okx = ($dx -ge -($FitScaleMaxPct + 0.05)) -and ($dx -le $FitGrowMaxPct + 0.05)
            $oky = ($dy -ge -($FitScaleMaxPct + 0.05)) -and ($dy -le $FitGrowMaxPct + 0.05)
            if ($okx -and $oky -and ($nw -ne $p.CW -or $nh -ne $p.CH)) {
                $draw += @("-resize", ("{0}x{1}!" -f $nw, $nh))
                $note2 = "{0} {1:+0.00;-0.00} x {2:+0.00;-0.00} %" -f $(if ($dx -lt 0 -or $dy -lt 0) { "масштаб" } else { "розтягнуто" }), $dx, $dy
                Write-Host ("  {0}: {1}" -f $p.Name, $note2) -ForegroundColor DarkGray
            }
        }
        & magick $p.Path @draw -gravity center -background $frameColor -extent "${tw}x${th}" `
                 @dens -quality $Quality $jpg 2>$null | Out-Null
        $note = "{0}x{1} -> {2}x{3} -> {4}x{5}" -f $p.W, $p.H, $p.CW, $p.CH, $tw, $th
    }
    if (-not (Test-Path $jpg)) { Write-Host "  ЗБІЙ на $($p.Name)" -ForegroundColor Red; exit 1 }
    $mb = (Get-Item $jpg).Length / 1MB
    $total += $mb
    Write-Host ("  {0}  {1}  {2:N2} МБ" -f $p.Name, $note, $mb)
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("Готово: {0}  ({1} сторінок, разом {2:N1} МБ)" -f $render, $pages.Count, $total) -ForegroundColor Green
