# Етап 3 — геометрія. Обрізка смуги скла, автоповорот, вирівнювання перекосу.
# Тон, колір і різкість НЕ чіпаються: це етап 3b (ns-render.ps1).
#
#   .\ns-prep.ps1 -Seq 2231
#   .\ns-prep.ps1 -Seq 2231 -Force        перебудувати, навіть якщо вже є
#
# Вхід : C:\NS_MASTERS\<рік>\<номер>_<дата>\*.tif   (400 dpi, read-only)
# Вихід: C:\NS_WORK\<номер>\prep\pNN.tif            (400 dpi, LZW)
#
# Майстри лише читаються. Скрипт звіряє їхні SHA-256 ДО і ПІСЛЯ роботи й
# зупиняється, якщо хоч один змінився: це головна гарантія всього конвеєра,
# тож вона перевіряється, а не декларується.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [switch]$Force,
    [switch]$NoRotate,          # не повертати сторінки за результатом OSD
    [switch]$NoEdgeClean,        # лишити проколи від зшивання і смугу краю
    [double]$EdgeCleanMm = 8.0,  # глибина вичищення краю (8 з 17.09.2026: проколи сидять до 7 мм)
    [double]$BandMaxMm = 8.0,    # глибше цього обрізка країв не робиться взагалі
    [string]$RotatePages,        # ручний поворот: "11:90,13:270" — записується в маніфест
    [string]$EdgeExtra,          # примусове вичищення: "1L3 5L3 8R3" — сторінка, край, мм
    [switch]$FillHoles,          # заповнювати великі проколи тоном паперу (лише з дозволу оператора)
    [switch]$NoOuterRule,        # зовнішній бік різати як раніше (8 мм), а не лише до паперу (правило 25.09.2026)
    [string]$FillThreadsPages,   # "1,2": заростати й дрібні нитки на цих сторінках (за вказівкою оператора) — пишеться в маніфест
    [switch]$NoSpineBand         # не обрізати смугу скла на корінці (для заміру ниток у ns-prepare)
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (-not (Test-NsTools -Need scan)) { Write-Host "Бракує інструментів." -ForegroundColor Red; exit 1 }

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено в каталозі." -ForegroundColor Red; exit 1 }

$man = Read-NsManifest -IssueDir $issueDir
if (@($man.pages).Count -eq 0) { Write-Host "У номері $Seq немає сторінок." -ForegroundColor Red; exit 1 }

# --- майстри мають бути цілими ДО початку ----------------------------------
foreach ($p in $man.pages) {
    if (-not (Test-NsPageDurable -IssueDir $issueDir -PageEntry $p)) {
        Write-Host "Сторінка $($p.file) не проходить перевірку цілості — зупинка." -ForegroundColor Red
        exit 1
    }
}

# --- ручний поворот окремих сторінок ---------------------------------------
# Автоповорот вимикається порогом упевненості 12, і це правильно: нижче нього
# OSD плутає газетні шпальти. Але буває, що він має рацію й без упевненості —
# у номері 2259 дитячий додаток надруковано впоперек, і сторінки 11 та 13
# лишилися лежати боком при впевненості 9,8 і 6,2, хоча кут OSD вгадав.
# Вказівка оператора записується в МАНІФЕСТ і діє на всі подальші перезбірки:
# це властивість номера, а не команди — так само, як -PageOrder.
$rotMap = @{}
if ($RotatePages) {
    foreach ($pair in ($RotatePages -split ',')) {
        if ($pair.Trim() -match '^(\d+)\s*:\s*(\d+)$') { $rotMap[[int]$Matches[1]] = [int]$Matches[2] }
    }
    $man | Add-Member -NotePropertyName page_rotate -NotePropertyValue $RotatePages -Force
    Write-NsManifest -IssueDir $issueDir -Manifest $man
    Write-Host "  ручний поворот записано в маніфест: $RotatePages" -ForegroundColor Yellow
} elseif ($man.PSObject.Properties.Name -contains 'page_rotate' -and $man.page_rotate) {
    foreach ($pair in ($man.page_rotate -split ',')) {
        if ($pair.Trim() -match '^(\d+)\s*:\s*(\d+)$') { $rotMap[[int]$Matches[1]] = [int]$Matches[2] }
    }
    Write-Host "  ручний поворот із маніфеста: $($man.page_rotate)" -ForegroundColor Yellow
}

# --- примусове вичищення окремих країв ---------------------------------------
# Автоматика міряє, де починається фарба, і не чистить далі. Але проколи від
# нитки бувають глибші за цю межу, а поруч із ними нічого корисного немає —
# тоді рішення ухвалює оператор, подивившись на сторінку.
# Формат: "1L3 5L3 8R3" — сторінка, край (L/R/T/B), глибина в мм.
# Записується в МАНІФЕСТ і діє на всі подальші перезбірки.
$edgeMap = @{}
$edgeSpec = $null
if ($EdgeExtra) { $edgeSpec = $EdgeExtra }
elseif ($man.PSObject.Properties.Name -contains 'page_edge' -and $man.page_edge) { $edgeSpec = $man.page_edge }
if ($edgeSpec) {
    foreach ($tok in ($edgeSpec -split '[,\s]+')) {
        if ($tok -match '^(\d+)([LRTBlrtb])([\d.]+)$') {
            $pn = [int]$Matches[1]
            $side = switch ($Matches[2].ToUpper()) { "L" {"Left"} "R" {"Right"} "T" {"Top"} "B" {"Bottom"} }
            if (-not $edgeMap.ContainsKey($pn)) { $edgeMap[$pn] = @{} }
            $edgeMap[$pn][$side] = [double]$Matches[3]
        }
    }
    if ($EdgeExtra) {
        $man | Add-Member -NotePropertyName page_edge -NotePropertyValue $EdgeExtra -Force
        Write-NsManifest -IssueDir $issueDir -Manifest $man
        Write-Host "  примусове вичищення записано в маніфест: $EdgeExtra" -ForegroundColor Yellow
    } else {
        Write-Host "  примусове вичищення з маніфеста: $edgeSpec" -ForegroundColor Yellow
    }
}

if ($FillHoles) {
    $man | Add-Member -NotePropertyName fill_holes -NotePropertyValue $true -Force
    Write-NsManifest -IssueDir $issueDir -Manifest $man
    Write-Host "  заповнення проколів дозволено оператором — записано в маніфест" -ForegroundColor Yellow
}
if ($FillThreadsPages) {
    $man | Add-Member -NotePropertyName fill_threads_pages -NotePropertyValue $FillThreadsPages -Force
    Write-NsManifest -IssueDir $issueDir -Manifest $man
    Write-Host "  нитки заростають на сторінках $FillThreadsPages — записано в маніфест" -ForegroundColor Yellow
}

$prep = Get-NsWorkDir -Seq $Seq -Stage "prep"
$hasOsd = Test-Path (Join-Path $script:TESSDATA "osd.traineddata")
if (-not $NoRotate -and -not $hasOsd) {
    Write-Host "osd.traineddata немає — автоповорот вимкнено." -ForegroundColor Yellow
    $NoRotate = $true
}

Write-Host ""
Write-Host "Етап 3 (геометрія): номер $Seq, $(@($man.pages).Count) сторінок" -ForegroundColor Cyan

# Колір заливки краю — ОДИН НА НОМЕР, із найменш задрукованих сторінок.
# Вимір паперу зміщується вниз тим сильніше, чим більше на сторінці друку
# (по 2225: 218 на густій сторінці проти 227 на рідкій, хоча папір той самий).
# Якби заливали поміряним значенням кожної сторінки, на густих сторінках
# рамка виходила б темнішою за власний папір.
$fillColor = "white"
if (-not $NoEdgeClean) {
    $mR = @(); $mG = @(); $mB = @()
    foreach ($p in $man.pages) {
        $pc = Get-NsPaperColor -Path (Join-Path $issueDir $p.file)
        if ($pc) { $mR += $pc[0]; $mG += $pc[1]; $mB += $pc[2] }
    }
    if ($mR.Count -ge 1) {
        $q = { param($a) $s = @($a | Sort-Object); $s[[math]::Min($s.Count-1, [int]([math]::Floor($s.Count * 0.8)))] }
        $fillColor = "rgb($(& $q $mR),$(& $q $mG),$(& $q $mB))"
        Write-Host "  колір паперу номера: $fillColor"
    }
}
Write-Host ""

$report = @()
# Глибини вичищення краю на кожну сторінку. Саму заливку тепер накладає
# ns-render ПІСЛЯ балансу білого, щоб її тон збігався з тоном доповнення:
# інакше prep міряє папір на майстрах (228), render на своїх сторінках (221),
# баланс зводить 221 до 244, і заливка 228 підіймається до 251 — це і є
# «подвійна рамка», яку бачив оператор.
$edgeRec = @()

foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
    $src = Join-Path $issueDir $p.file
    $dst = Join-Path $prep ("p{0:D2}.tif" -f [int]$p.n)

    # «Вже є» лише якщо похідний файл НОВІШИЙ за майстер. Після заміни сторінки
    # (ns-rescan) старий prep інакше тихо пішов би в PDF — 16.09.2026 так
    # і сталося з 2266 стор. 8 і 2267 стор. 4.
    if ((Test-Path $dst) -and -not $Force -and
        (Get-Item $dst).LastWriteTime -gt (Get-Item $src).LastWriteTime) {
        Write-Host ("  p{0:D2}  вже є, пропущено" -f [int]$p.n) -ForegroundColor DarkGray
        continue
    }

    $wh = (& magick identify -format "%w|%h" $src 2>$null) -split '\|'
    $w = [int]$wh[0]; $h = [int]$wh[1]

    # --- автоповорот -------------------------------------------------------
    # OSD читається з окремого швидкого зменшеного файлу: гнати 50 МБ через
    # Tesseract лише заради кута — марна витрата хвилин.
    $rotate = 0; $osdNote = ""
    if ($rotMap.ContainsKey([int]$p.n)) {
        # вказівка оператора має перевагу над OSD й над -NoRotate
        $rotate = $rotMap[[int]$p.n]
        $osdNote = "поворот $rotate° за вказівкою оператора"
    } elseif (-not $NoRotate) {
        $probe = Join-Path $env:TEMP ("ns_osd_{0}_{1}.png" -f $Seq, [int]$p.n)
        & magick $src -resample 100 -colorspace Gray $probe 2>$null | Out-Null
        if (Test-Path $probe) {
            $osd = & $script:TESSERACT $probe stdout --tessdata-dir $script:TESSDATA --psm 0 2>$null
            $deg = 0; $conf = 0
            foreach ($l in $osd) {
                if ($l -match 'Rotate:\s*(\d+)')            { $deg  = [int]$Matches[1] }
                if ($l -match 'Orientation confidence:\s*([\d.]+)') { $conf = [double]$Matches[1] }
            }
            # Поріг 12 підібраний раніше: нижче нього OSD плутає газетні шпальти.
            if ($deg -ne 0 -and $conf -ge 12) { $rotate = $deg; $osdNote = "поворот $deg° (впевненість $conf)" }
            elseif ($deg -ne 0)               { $osdNote = "OSD радив $deg°, але впевненість лише $conf — не повертаю" }
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        }
    }

    # Поворот роблю окремим проходом, бо зміщення смуги треба шукати вже на
    # поверненому зображенні: після 90° вона переїжджає з верху/низу на бік.
    $work = $src
    $rotated = $null
    if ($rotate -ne 0) {
        $rotated = Join-Path $env:TEMP ("ns_rot_{0}_{1}.tif" -f $Seq, [int]$p.n)
        & magick $src -rotate $rotate +repage -compress LZW $rotated 2>$null | Out-Null
        if (Test-Path $rotated) {
            $work = $rotated
            $wh = (& magick identify -format "%w|%h" $work 2>$null) -split '\|'
            $w = [int]$wh[0]; $h = [int]$wh[1]
        } else {
            $osdNote += " (поворот не вдався, лишаю як є)"; $rotate = 0
        }
    }

    # --- обрізка смуги + перекос -------------------------------------------
    $ops = @()
    $band = Get-BandOffsets -Path $work -Width $w -Height $h
    # Край із вказівкою оператора (page_edge) не чіпає й детектор скла: на
    # календарі 2267 він прийняв коричневу друковану рамку за скло й зрізав
    # 2-2,5 мм з лівого боку (17.09.2026).
    $forcedBand = if ($edgeMap.ContainsKey([int]$p.n)) { $edgeMap[[int]$p.n] } else { @{} }
    foreach ($side in @($forcedBand.Keys)) { $band[$side] = 0 }
    # -NoSpineBand (ns-prepare, перший прохід): і на корінці детектор скла не ріже.
    # Там зріз дає page_edge із заміру ниток, а page_edge у другому проході детектор
    # вимикає — тож і міряти треба від того самого, сирого краю (2268/6, 25.09.2026:
    # скло 6,8 мм обрізано лише в першому проході, зріз 5,5 ліг від сирого краю).
    if ($NoSpineBand) {
        $nsb = Get-NsSpineSide -PageNo ([int]$p.n) -Rotate $rotate
        if ($nsb) { $band[$nsb] = 0 }
    }

    # ЗАПОБІЖНИК: смуга невкритого скла фізично мала. Виміряно на 704 значеннях
    # із 39 номерів: медіана 0, 95-й перцентиль 33 px (2 мм), майже все нижче
    # 60 px. Усе, що більше — не скло, а темний елемент верстки, і різати його
    # означає нищити зміст.
    # Так і сталося на номері 2254 (новий дизайн із жовтня 2000): угорі
    # 1-ї сторінки темна плашка яскравістю 121-135, тобто нижче порога 150,
    # і детектор зрізав 865 px = 55 мм сторінки.
    $capPx = [int]($BandMaxMm / 25.4 * 400)
    $capped = @()
    foreach ($side in @("Top", "Bottom", "Left", "Right")) {
        if ($band[$side] -gt $capPx) {
            $capped += "$side $($band[$side]) px"
            $band[$side] = 0        # не ріжемо взагалі: краще лишити смугу, ніж відтяти зміст
        }
    }
    if ($capped.Count -gt 0) {
        $osdNote += ("; УВАГА: обрізку скасовано ($($capped -join ', ')) — глибше за {0} мм це вже верстка, а не скло" -f $BandMaxMm)
    }

    $cropNote = "без обрізки"
    if ($band.Top -gt 0 -or $band.Bottom -gt 0 -or $band.Left -gt 0 -or $band.Right -gt 0) {
        $cw = $w - $band.Left - $band.Right
        $ch = $h - $band.Top - $band.Bottom
        $ops += @("-crop", "${cw}x${ch}+$($band.Left)+$($band.Top)", "+repage")
        $cropNote = "обрізано в:$($band.Top) н:$($band.Bottom) л:$($band.Left) п:$($band.Right)"
    }
    $ops += @("-background", "white", "-deskew", "40%", "+repage")

    & magick $work @ops -compress LZW $dst 2>$null | Out-Null

    # --- вичищення краю ----------------------------------------------------
    # Річник був зшитий, тож уздовж одного краю лишається стовпчик проколів
    # від нитки — круглі темні плями діаметром близько 2,3 мм. Поруч із ними
    # сидить нерівна темна смуга самого краю аркуша й залишки скла.
    # Виміряно: усе це вкладається у зовнішні 7 мм, а найменше чисте поле до
    # тексту по всіх 19 номерах — 11,0 мм. Тобто 7 мм можна віддати з запасом.
    #
    # Заповнюємо ВЛАСНИМ кольором паперу сторінки, а не білим: біла рамка на
    # сіруватому папері читалася б як рамка. Далі етап 3b однаково зведе папір
    # у нейтраль, і шов лишиться невидимим.
    # Вичищається КОЖЕН КРАЙ НА СВОЮ ГЛИБИНУ.
    #
    # Спершу тут стояла однакова глибина на всі чотири краї, і на верстці з
    # жовтня 2000 це знищило зміст: у номері 2254 текст стоїть за 3 мм від
    # низу сторінки, а вичищалося 6 мм — тобто нижній рядок і дату просто
    # стерто. Оператор побачив це в готовому PDF.
    #
    # Друга, глибша помилка була в самому запобіжнику: він міряв відступ до
    # тексту, ігноруючи зовнішні 8 мм, тобто був СЛІПИЙ рівно в тій зоні, яку
    # мав захищати. Повертав свою нижню межу 8, код віднімав 2 і спокійно
    # вичищав 6 мм поверх тексту.
    $edgeNote = ""
    if (-not $NoEdgeClean -and (Test-Path $dst)) {
        # 17.09.2026: глибину визначає профіль ЧАСТКИ відрізків із фарбою
        # (Get-NsEdgeProfile + Get-NsEdgeCut), а не середня яскравість краю
        # (Get-NsInkMargins). Середнє приймало стовпчик проколів і смугу скла
        # за текст — «текст за 3,0 мм» — і вичищало 1 мм; у PDF 2266 стор. 5, 6,
        # 8, 10 лишилися дірки й смуга. Правила й калібрування — у коментарі
        # до Get-NsEdgeCut.
        $spine = Get-NsSpineRule -Year ([int]$man.year) -PageNo ([int]$p.n) -Rotate $rotate
        # дірки від зшивання латаються ДО виміру краю: інакше вони читаються
        # як друк і зріз скорочується (2319/6 — 1 мм замість 8)
        $doFill = $FillHoles -or ($man.PSObject.Properties.Name -contains 'fill_holes' -and $man.fill_holes)
        # fill_skip_pages в маніфесті ("5,6,7,8,9,10"): сторінки, де заповнення не застосовується
        # (2323, вкладка «Світанок»: дірки посеред розвороту, друк до самого краю — рішення оператора 24.09.2026)
        if ($doFill -and $man.PSObject.Properties.Name -contains 'fill_skip_pages' -and $man.fill_skip_pages) {
            if (@($man.fill_skip_pages -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) -contains [int]$p.n) { $doFill = $false }
        }
        # Рік без NS_SPINE_RULES (2001), але оператор велів заростити дірки номера
        # (fill_holes у маніфесті; 2280, 25.09.2026): бік корінця за парністю,
        # зона й межа великих — як у 2002 (ті самі дірки 5,7-6,4 мм на 2280).
        $holeRule = $spine
        if (-not $holeRule -and $doFill) {
            $hs = Get-NsSpineSide -PageNo ([int]$p.n) -Rotate $rotate
            if ($hs) { $holeRule = @{ Side = $hs; ZoneMm = 16.0; BigMinMm = 4.0 } }
        }
        # fill_threads_pages ("1,2"): на цих сторінках заростають і дрібні нитки —
        # де корінець за вказівкою оператора не ріжеться, бо нитки в тексті (2280/1, 2).
        # Repair-NsHoles однаково лишає пляму, біля якої немає чистого паперу.
        $bigMin = if ($holeRule) { $holeRule.BigMinMm } else { 0 }
        $holeMin = 1.5
        if ($holeRule -and $man.PSObject.Properties.Name -contains 'fill_threads_pages' -and $man.fill_threads_pages) {
            # нитки 2280/1 — щілини 1,1 x 2,9 мм: з межею 1,5 відкидались за розміром (24 шт.)
            if (@($man.fill_threads_pages -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) -contains [int]$p.n) { $bigMin = 0; $holeMin = 1.0 }
        }
        if ($holeRule -and $doFill) {
            # смуга, яку однаково відріже page_edge корінця, не заважає шукати великі дірки
            $skip = if ($edgeMap.ContainsKey([int]$p.n) -and $edgeMap[[int]$p.n].ContainsKey($holeRule.Side)) { $edgeMap[[int]$p.n][$holeRule.Side] } else { 0 }
            $nh = Repair-NsHoles -Path $dst -Side $holeRule.Side -ZoneMm $holeRule.ZoneMm -BigMinMm $bigMin -MinMm $holeMin -SkipMm $skip -PaperColor $fillColor `
                                 -ReportDir (Join-Path (Split-Path $prep -Parent) "holes") `
                                 -ReportName ("p{0:D2}" -f [int]$p.n)
            if ($nh -gt 0) { $edgeNote = ($edgeNote, ("залатано проколів: {0} ({1})" -f $nh, $holeRule.Side) | Where-Object { $_ }) -join "; " }
        }
        # Замальовування тонкої лінії краю (Repair-NsEdgeLine) ВИМКНЕНО
        # 23.09.2026: воно лишало сіру смугу згори кожної сторінки (латка
        # заходила в білу зону поза аркушем) і на корінці переносило великі
        # проколи ближче до краю. Рішення оператора: «чорну смужку на стор. 4
        # можна просто відрізати» — тобто вказівкою page_edge, як завжди.
        # Функція лишилася в ns-lib на випадок, якщо колись знадобиться.
        $spArgs = @{}
        if ($spine) { $spArgs = @{ SpineSide = $spine.Side; SpineCleanMm = $spine.CleanMm; SpineHoleMaxMm = $spine.HoleMaxMm } }
        # Зовнішній бік (протилежний корінцю) — лише до початку паперу, глибше лише
        # для симетрії полів і не глибше за корінець (рішення оператора 25.09.2026,
        # Get-NsEdgeCut -OuterSide). Корінець із page_edge передаємо як є.
        if (-not $NoOuterRule) {
            $spSide = Get-NsSpineSide -PageNo ([int]$p.n) -Rotate $rotate
            if ($spSide) {
                $spArgs.OuterSide = @{ Left = "Right"; Right = "Left"; Top = "Bottom"; Bottom = "Top" }[$spSide]
                if ($edgeMap.ContainsKey([int]$p.n) -and $edgeMap[[int]$p.n].ContainsKey($spSide)) { $spArgs.SpineCutMm = [double]$edgeMap[[int]$p.n][$spSide] }
            }
        }
        # 35 мм (було 25): правило зовнішнього боку шукає колонку друку зовні, а
        # вона на 2002 починається з 22-24 мм (2328/1) — у 25 мм не вміщалась.
        $ec = Get-NsEdgeCut -EdgeProfile (Get-NsEdgeProfile -Path $dst -Dpi 400 -DepthMm 35) -CleanMm $EdgeCleanMm @spArgs
        $px = @{}
        $mmSide = @{}
        $freeSide = @{}
        $tight = @()
        $forced = if ($edgeMap.ContainsKey([int]$p.n)) { $edgeMap[[int]$p.n] } else { @{} }
        foreach ($side in @("Top", "Bottom", "Left", "Right")) {
            $allow = if ($ec) { $ec[$side].Cut } else { 0 }
            $free  = if ($ec) { $ec[$side].Free } else { 0 }
            # вказівка оператора має перевагу: він подивився на сторінку й бачить,
            # що там лише проколи. Але кажемо, що про це думав вимір.
            if ($forced.ContainsKey($side)) {
                $note = if ($ec -and [math]::Abs($forced[$side] - $allow) -ge 0.5) { " (вимір радив {0:N1})" -f $allow } else { "" }
                $tight += ("{0} {1:N1}мм за вказівкою{2}" -f $side, $forced[$side], $note)
                $allow = $forced[$side]; $free = 0
            } elseif ($ec -and $allow -lt $EdgeCleanMm - 0.5) {
                $tight += ("{0} {1:N1}мм ({2})" -f $side, $allow, $ec[$side].Why)
            }
            $px[$side] = [int]($allow / 25.4 * 400)
            $mmSide[$side] = [math]::Round($allow, 2)
            $freeSide[$side] = [math]::Round($free, 1)
        }
        if ($tight.Count -gt 0) { $edgeNote = ($edgeNote, ("край вичищено менше: " + ($tight -join ", ")) | Where-Object { $_ } ) -join "; " }

        if (($px.Values | Measure-Object -Sum).Sum -gt 0) {
            $wh3 = (& magick identify -format "%w|%h" $dst 2>$null) -split '\|'
            $cw = [int]$wh3[0]; $ch = [int]$wh3[1]
            $draw = @()
            if ($px.Top    -gt 0) { $draw += @("-draw", "rectangle 0,0 $cw,$($px.Top)") }
            if ($px.Bottom -gt 0) { $draw += @("-draw", "rectangle 0,$($ch - $px.Bottom) $cw,$ch") }
            if ($px.Left   -gt 0) { $draw += @("-draw", "rectangle 0,0 $($px.Left),$ch") }
            if ($px.Right  -gt 0) { $draw += @("-draw", "rectangle $($cw - $px.Right),0 $cw,$ch") }
            $tmpc = "$dst.clean.tif"
            & magick $dst -fill $fillColor -stroke none @draw -compress LZW $tmpc 2>$null | Out-Null
            if (Test-Path $tmpc) { Move-Item -Path $tmpc -Destination $dst -Force }
        }
    }
    if ($rotated) { Remove-Item $rotated -Force -ErrorAction SilentlyContinue }

    if (-not (Test-Path $dst)) {
        Write-Host ("  p{0:D2}  ЗБІЙ" -f [int]$p.n) -ForegroundColor Red
        exit 1
    }

    if ($mmSide.Count -gt 0) {
        # fT..fR — запас чистого поля до друку після чистки (для одного розміру сторінок у ns-render)
        $edgeRec += ("p{0:D2} T={1} B={2} L={3} R={4} fT={5} fB={6} fL={7} fR={8}" -f [int]$p.n,
                     $mmSide.Top, $mmSide.Bottom, $mmSide.Left, $mmSide.Right,
                     $freeSide.Top, $freeSide.Bottom, $freeSide.Left, $freeSide.Right)
    }
    $wh2 = (& magick identify -format "%w|%h" $dst 2>$null) -split '\|'
    $report += [pscustomobject]@{ n = [int]$p.n; w = [int]$wh2[0]; h = [int]$wh2[1] }

    $msg = "  p{0:D2}  {1}x{2} -> {3}x{4}  {5}" -f [int]$p.n, $w, $h, [int]$wh2[0], [int]$wh2[1], $cropNote
    if ($osdNote)  { $msg += "; $osdNote" }
    if ($edgeNote) { $msg += "; $edgeNote" }
    Write-Host $msg
}

# --- майстри мають бути цілими ПІСЛЯ роботи --------------------------------
$touched = @()
foreach ($p in $man.pages) {
    if ((Get-NsHash (Join-Path $issueDir $p.file)) -ne $p.sha256) { $touched += $p.file }
}
Write-Host ""
if ($touched.Count -gt 0) {
    Write-Host "ТРИВОГА: майстри змінилися під час обробки:" -ForegroundColor Red
    $touched | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Майстри недоторкані (SHA-256 звірено до і після)." -ForegroundColor Green

# --- перевірка #8: відхилення ширини від медіани ---------------------------
# Єдиний автоматичний захист від криво покладеного аркуша: запасу по краях
# немає, тож сторінка помітно вужча за решту — ознака зрізаного краю.
# Книжкові й альбомні сторінки міряються ОКРЕМО. Альбомні бувають законно:
# вкладки, надруковані впоперек аркуша, автоповорот ставить їх на бік, і їхня
# ширина дорівнює висоті книжкової. На номері 2235 таких сторінок п'ять, і при
# спільній медіані вони давали «відхилення 40 %» — тобто перевірка кричала на
# правильно оброблений вміст.
foreach ($grp in @(@{ n = "книжкові";  items = @($report | Where-Object { $_.w -le $_.h }) },
                   @{ n = "альбомні"; items = @($report | Where-Object { $_.w -gt $_.h }) })) {
    $items = $grp.items
    if ($items.Count -lt 3) { continue }
    $ws = @($items.w | Sort-Object)
    $median = $ws[[int]($ws.Count / 2)]
    foreach ($r in $items) {
        $dev = [math]::Abs($r.w - $median) / $median * 100
        if ($dev -gt 3) {
            Write-Host ("  УВАГА p{0:D2}: ширина {1} px, медіана {2} px серед {3} — відхилення {4:N1} %" -f `
                        $r.n, $r.w, $median, $grp.n, $dev) -ForegroundColor Yellow
        }
    }
}

if ($edgeRec.Count -gt 0) {
    [IO.File]::WriteAllLines((Join-Path $prep "_edge.txt"), $edgeRec, [Text.UTF8Encoding]::new($false))
}
Write-Host "Готово: $prep" -ForegroundColor Green
