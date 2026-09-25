# Спільна бібліотека конвеєра «Наше слово».
# Підключати з інших скриптів:  . "$PSScriptRoot\ns-lib.ps1"

# ---------------------------------------------------------------- налаштування
# Переїзд на інший том = зміна цих трьох рядків і більше нічого.
# NS_TEST_* — лише для випробувань на піску (клон-каталог у C:\NS_WORK\_sandbox); у роботі не задаються.
$script:NS_MASTERS = if ($env:NS_TEST_MASTERS) { $env:NS_TEST_MASTERS } else { "C:\NS_MASTERS" }
$script:NS_WORK    = if ($env:NS_TEST_WORK)    { $env:NS_TEST_WORK }    else { "C:\NS_WORK" }
$script:NS_PDF     = if ($env:NS_TEST_PDF)     { $env:NS_TEST_PDF }     else { "C:\NS_PDF" }

$script:CATALOG    = Join-Path $NS_MASTERS "_catalog"
$script:REGISTRY   = Join-Path $CATALOG "issues.csv"
$script:CHECKSUMS  = Join-Path $CATALOG "checksums"
$script:LOGS       = Join-Path $CATALOG "logs"

# Інструменти. Tesseract не в PATH, ocrmypdf.exe теж — тому повні шляхи / python -m.
$script:TESSERACT  = "C:\Program Files\Tesseract-OCR\tesseract.exe"
# Мовні файли їздять разом зі скриптами, тож шлях — від теки самої бібліотеки,
# а не від імені користувача чи розташування «Документів».
$script:TESSDATA   = Join-Path $PSScriptRoot "tessdata"
$script:NAPS2_PROFILE = "Arhiv400"

# NAPS2 на різних машинах стоїть по-різному: інсталятор кладе його в Program
# Files, магазин — ярликом у WindowsApps. Шукаємо за файлом, як і Ghostscript.
$script:NAPS2 = $null
foreach ($cand in @("$env:ProgramFiles\NAPS2\NAPS2.Console.exe",
                    "${env:ProgramFiles(x86)}\NAPS2\NAPS2.Console.exe",
                    "$env:LOCALAPPDATA\Microsoft\WindowsApps\NAPS2.Console.exe")) {
    if (Test-Path $cand) { $script:NAPS2 = $cand; break }
}
if (-not $script:NAPS2) {
    $c = Get-Command NAPS2.Console -ErrorAction SilentlyContinue
    if ($c) { $script:NAPS2 = $c.Source }
}

# Python викликається в конвеєрі за іменем (`python -m ocrmypdf`). На чистій
# Windows `python` у PATH — це ярлик магазину, який лише пише «Python was not
# found»; перевірка «команда існує» на ньому хибно каже «так». Тому шукаємо
# справжній інтерпретатор за відповіддю на --version і ставимо його теку
# першою в PATH цього процесу.
$script:PYTHON = $null
$pyCands = @(Get-Command python -All -CommandType Application -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Source })
$pyCands += @(Get-ChildItem "C:\Python3*\python.exe",
                            "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                            "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | ForEach-Object { $_.FullName })
foreach ($cand in $pyCands) {
    try {
        $v = (& $cand --version 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $v -match 'Python 3') { $script:PYTHON = $cand; break }
    } catch { }
}
if ($script:PYTHON) {
    $d = Split-Path $script:PYTHON -Parent
    if ($env:PATH -notlike "$d;*") { $env:PATH = "$d;$d\Scripts;$env:PATH" }
}

# Ghostscript ставиться з номером версії в шляху, тож шукаємо його, а не
# покладаємося на PATH: у щойно запущеній оболонці PATH може бути ще старий.
$script:GHOSTSCRIPT = $null
foreach ($cand in @(Get-ChildItem "C:\Program Files\gs\gs*\bin\gswin64c.exe" -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending)) {
    $script:GHOSTSCRIPT = $cand.FullName; break
}
if (-not $script:GHOSTSCRIPT) {
    $c = Get-Command gswin64c -ErrorAction SilentlyContinue
    if ($c) { $script:GHOSTSCRIPT = $c.Source }
}

# Очікуваний розмір готового PDF — НА СТОРІНКУ, не на номер: номери бувають
# і 8, і 10, і 16 сторінок, тож поріг на цілий файл нічого не означає.
# Орієнтир — архів 1956-1999: заміряно 1,72-2,40 МБ/стор. на 15 номерах.
# Вихід за межі не помилка, а привід глянути.
$script:PDF_MB_PER_PAGE_MIN = 1.2
$script:PDF_MB_PER_PAGE_MAX = 3.2

$script:PUBLISHER  = "Zwiazek Ukraincow w Polsce"
$script:ISSN       = "0027-8254"
$script:TITLE      = "Наше слово"

# ------------------------------------------------------------------- допоміжне

function Initialize-NsConsole {
    <#  Кирилиця у виводі має пережити перенаправлення у файл.
        PowerShell 5.1 віддає консольний вивід у кодуванні поточної кодової
        сторінки (тут 437/1252), і при `... > log.txt` усі українські літери
        стають знаками питання БЕЗПОВОРОТНО — у файлі вже немає чого рятувати.
        Через це лог довгої перезбірки довелося читати за структурою рядків,
        а двічі я прочитав його неправильно.
        Викликати на початку будь-якого скрипта, вивід якого можуть зберегти. #>
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
        $PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
    } catch { }
}

function Test-NsTools {
    <#  Перевірити наявність лише тих інструментів, які потрібні цьому етапу.
        Сканування не має падати через відсутній OCR — це різні етапи.
          Test-NsTools -Need scan     NAPS2 + ImageMagick
          Test-NsTools -Need ocr      + Tesseract, tessdata, ocrmypdf, Ghostscript
          Test-NsTools -Need all      усе                                        #>
    param([ValidateSet("scan", "ocr", "all")][string]$Need = "all")

    # Перевірки навмисно тихі: python друкує версію в потік помилок, тому
    # покладатися на код виходу від --version не можна.
    $checks = @{
        "ImageMagick" = { $null = & magick -version 2>&1; $LASTEXITCODE -eq 0 }
        "NAPS2"       = { Test-Path $script:NAPS2 }
        "Tesseract"   = { Test-Path $script:TESSERACT }
        "tessdata"    = { (Test-Path (Join-Path $script:TESSDATA "ukr.traineddata")) -and
                          (Test-Path (Join-Path $script:TESSDATA "pol.traineddata")) }
        "ocrmypdf"    = { $null = & python -c "import ocrmypdf" 2>&1; $LASTEXITCODE -eq 0 }
        "Ghostscript" = { $script:GHOSTSCRIPT -and (Test-Path $script:GHOSTSCRIPT) }
    }
    # УВАГА: імена змінних у PowerShell нечутливі до регістру, тому назвати
    # цю змінну $need не можна — це був би той самий $Need із ValidateSet.
    $required = switch ($Need) {
        "scan" { @("ImageMagick", "NAPS2") }
        "ocr"  { @("ImageMagick", "Tesseract", "tessdata", "ocrmypdf", "Ghostscript") }
        default { @($checks.Keys) }
    }

    $ok = $true
    foreach ($n in $required) {
        $pass = $false
        try { $pass = [bool](& $checks[$n]) } catch { $pass = $false }
        if (-not $pass) { Write-Host "  БРАКУЄ: $n" -ForegroundColor Red; $ok = $false }
    }
    return $ok
}

function Initialize-NsOcrEnv {
    <#  ocrmypdf викликає tesseract і gswin64c ЗА ІМЕНЕМ, а не за шляхом, тож
        обидва мають бути в PATH цього процесу — у системному їх немає.
        Мовні файли ukr/pol лежать у теці проєкту, а не поруч із tesseract.exe,
        тому ще й TESSDATA_PREFIX. Без цього ocrmypdf падає з невиразним
        «tesseract not found» або «Failed loading language». #>
    $dirs = @((Split-Path $script:TESSERACT -Parent))
    if ($script:GHOSTSCRIPT) { $dirs += (Split-Path $script:GHOSTSCRIPT -Parent) }
    foreach ($d in $dirs) {
        if ($env:PATH -notlike "*$d*") { $env:PATH = "$d;$env:PATH" }
    }
    $env:TESSDATA_PREFIX = $script:TESSDATA
}

function Get-NsOcrPath {
    <#  Розпізнаний текст номера лежить ПОРУЧ ІЗ МАЙСТРАМИ, а не в NS_WORK.
        Спершу він був у NS_WORK разом із проміжними теками — і я двічі стер
        його, прибираючи за налагодженням: `rm -rf NS_WORK\<номер>` забирає
        разом і те єдине, що там треба було зберегти. Перевірки одразу
        поскаржилися, але PDF лишалися цілі, тож два номери могли б назавжди
        лишитися без контролю якості.
        За змістом він і так тут доречніший: це результат обробки, як і
        контрольні суми, а не одноразове сміття. #>
    param([string]$IssueDir)
    Join-Path $IssueDir "_ocr.txt"
}

function Get-NsWorkDir {
    <#  Похідні для одного номера. Вміст можна видалити будь-коли — він
        повністю відтворюваний з майстрів. #>
    param([int]$Seq, [string]$Stage)
    $d = Join-Path (Join-Path $script:NS_WORK "$Seq") $Stage
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Find-NsIssueDir {
    <#  Тека номера за наскрізним номером. Порожньо, якщо немає або неоднозначно. #>
    param([int]$Seq)
    $f = @(Get-ChildItem -Path $script:NS_MASTERS -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "${Seq}_*" -and (Test-Path (Join-Path $_.FullName "_manifest.json")) })
    if ($f.Count -eq 1) { return $f[0].FullName }
    return $null
}

# ------------------------------------------------- пошук смуги невкритого скла
# Ложе сканера довше за газетну сторінку, тож на частині сторінок лишається
# майже чорна смуга. Звичайний -trim її не бере: він припускає симетричну рамку
# одного кольору від кута, а смуга є лише з одного краю, і один світлий піксель
# на межі зводить його нанівець.
# Тут зображення стискається в смужку 1 пікселя по кожній осі (один resize,
# не цикл по рядках), і від кожного краю йдемо всередину, доки кілька поспіль
# відліків не почнуть читатися як папір, а не скло.
# Перевіряються всі чотири краї: поворот на 90° (календарні вкладки) переносить
# смугу з верху/низу на бік.
#
# Після переходу на розшиті аркуші смуги зазвичай немає зовсім — ця перевірка
# стала страхувальною сіткою: коли смуги немає, вона нічого не обрізає.

function Get-AxisOffsets {
    param([string]$Path, [string]$ResizeGeom, [string]$Coord, [int]$Length,
          [int]$Samples, [int]$Threshold = 150, [int]$MinRun = 3)

    $raw = & magick $Path -resize $ResizeGeom -colorspace Gray -depth 8 txt: 2>$null
    $vals = @()
    $pattern = if ($Coord -eq 'y') { '^0,(\d+):\s*\((\d+)' } else { '^(\d+),0:\s*\((\d+)' }
    foreach ($line in $raw) {
        if ($line -match $pattern) { $vals += [int]$Matches[2] }
    }
    if ($vals.Count -lt $Samples) { return @{ Start = 0; End = 0 } }

    $pxPerSample = $Length / $vals.Count

    $startIdx = 0
    for ($i = 0; $i -le $vals.Count - $MinRun; $i++) {
        $run = $vals[$i..($i + $MinRun - 1)]
        if (($run | Where-Object { $_ -lt $Threshold }).Count -eq 0) { $startIdx = $i; break }
    }
    $endIdx = 0
    for ($i = 0; $i -le $vals.Count - $MinRun; $i++) {
        $j = $vals.Count - 1 - $i
        $run = $vals[($j - $MinRun + 1)..$j]
        if (($run | Where-Object { $_ -lt $Threshold }).Count -eq 0) { $endIdx = $i; break }
    }

    # Відступаємо на один відлік назад, щоб лінія різу лягла всередину смуги,
    # а не точно на її межу.
    @{ Start = [math]::Max(0, [int](($startIdx - 1) * $pxPerSample))
       End   = [math]::Max(0, [int](($endIdx   - 1) * $pxPerSample)) }
}

function Get-NsLastScanTime {
    <#  Коли востаннє щось сканували. Тримаємо окремою міткою, а не обходом
        усіх майстрів: на 7300 сторінках обхід був би повільним щоразу. #>
    $p = Join-Path $script:CATALOG "last_scan.txt"
    if (-not (Test-Path $p)) { return $null }
    try { [datetime]::Parse((Get-Content $p -Raw).Trim()) } catch { $null }
}

function Set-NsLastScanTime {
    $p = Join-Path $script:CATALOG "last_scan.txt"
    [IO.File]::WriteAllText($p, (Get-Date).ToString("s"), [Text.UTF8Encoding]::new($false))
}

function Get-NsPaperColor {
    <#  Колір паперу сторінки як 95-й перцентиль по кожному каналу.
        Не максимум — той ловить поодинокий викид; не середнє — те затягує
        в себе текст і виходить помітно темнішим за папір (на пробі 186 замість
        219). Повертає масив R,G,B у 0-255.                                  #>
    param([string]$Path, [int]$Sample = 400)
    # Рахує сам ImageMagick, без розбору пікселів у PowerShell: локальний
    # максимум 15x15 «затягує» папір поверх тонких штрихів тексту, після чого
    # звичайне середнє вже і є кольором паперу.
    # Звірено з чесним 95-м перцентилем: 223/224/226 проти 223/224/226 — збіг
    # точний. Розбір 32 тисяч рядків регулярним виразом у PowerShell на порядок
    # повільніший, а на 7300 сторінках це вже години.
    $out = & magick $Path -resize "${Sample}x${Sample}!" -colorspace sRGB `
                   -statistic Maximum 15x15 `
                   -format "%[fx:int(255*mean.r)]|%[fx:int(255*mean.g)]|%[fx:int(255*mean.b)]" info: 2>$null
    $p = "$out" -split '\|'
    if ($p.Count -lt 3) { return $null }
    $v = @([int]$p[0], [int]$p[1], [int]$p[2])
    if ($v[0] -le 0 -and $v[1] -le 0 -and $v[2] -le 0) { return $null }
    return $v
}

function Get-NsIssueCast {
    <#  Відтінок паперу номера (B-R): медіана по всіх сторінках.
        Спільний для ns-qc (перевірка #9) і ns-compare, щоб звірка з еталоном
        міряла тим самим способом, що й контроль якості.                     #>
    param([string]$IssueDir, $Manifest)
    $casts = @()
    foreach ($p in ($Manifest.pages | Sort-Object { [int]$_.n })) {
        $pc = Get-NsPaperColor -Path (Join-Path $IssueDir $p.file) -Sample 64
        if ($pc) { $casts += ($pc[2] - $pc[0]) }
    }
    if ($casts.Count -lt 3) { return $null }
    $sc = @($casts | Sort-Object)
    return $sc[[int]($sc.Count / 2)]
}

function Get-NsOcrStats {
    <#  Кількість слів і частка підозрілих у тексті OCR (перевірка #6).
        Слово — щонайменше 3 літери. Підозріле — змішані кирилиця й латиниця,
        або суцільно латинське слово від 4 літер із самих лише двійників
        (А-A, В-B, С-C...). Справжні латинські слова майже завжди мають літери
        поза цим набором.
        ⚠︎ Інший спосіб рахунку (напр. \w+) дає зовсім інше число слів — для
        звірки з еталоном брати тільки цю функцію.                           #>
    param([string]$Text)
    $words = @([regex]::Matches($Text, '[^\W\d_]{3,}') | ForEach-Object { $_.Value })
    $cyr  = 'абвгдеєжзиіїйклмнопрстуфхцчшщьюяАБВГДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯґҐ'
    $look = 'ABCEHIKMOPTXYaceiopxy'
    $sus = 0
    foreach ($w in $words) {
        $hasCyr = $w -match "[$cyr]"
        $hasLat = $w -match '[a-zA-Z]'
        if ($hasCyr -and $hasLat) { $sus++; continue }
        if (-not $hasCyr -and $w.Length -ge 4 -and ($w -replace "[$look]", "") -eq "") { $sus++ }
    }
    $pct = if ($words.Count) { 100.0 * $sus / $words.Count } else { 0 }
    [pscustomobject]@{ Words = $words.Count; Suspicious = $sus; Pct = $pct }
}

function Get-NsInkMargin {
    <#  Найменше чисте поле від краю кадру до першої суцільної фарби, у мм.
        Рахується по профілях: середнє кожного рядка й кожного стовпця. Саме
        середнє, а не мінімум, робить вимір стійким до поодиноких плям —
        прокол від нитки не зрушить середнє по рядку, а текстова шпальта
        зрушить одразу.
        Поріг прив'язаний до рівня паперу САМОГО зображення: абсолютний поріг
        на темнішому скані рахує чистий папір за фарбу й дає хибний нуль.
        IgnoreMm — скільки міліметрів від краю пропустити (там сміття).      #>
    param([string]$Path, [int]$Dpi = 400, [double]$IgnoreMm = 8.0)

    $ins = [int]($IgnoreMm / 25.4 * $Dpi)
    $wh = (& magick identify -format "%w|%h" $Path 2>$null) -split '\|'
    if ($wh.Count -lt 2) { return 999.0 }
    $W = [int]$wh[0]; $H = [int]$wh[1]
    if ($W -le 2*$ins -or $H -le 2*$ins) { return 999.0 }
    $crop = "{0}x{1}+{2}+{3}" -f ($W-2*$ins), ($H-2*$ins), $ins, $ins

    $rowsRaw = & magick $Path -crop $crop +repage -colorspace Gray -resize "1x300!" -depth 8 txt: 2>$null
    $colsRaw = & magick $Path -crop $crop +repage -colorspace Gray -resize "300x1!" -depth 8 txt: 2>$null
    $rv = @($rowsRaw | ForEach-Object { if ($_ -match '^0,(\d+):\s*\((\d+)') { [int]$Matches[2]/255.0 } })
    $cv = @($colsRaw | ForEach-Object { if ($_ -match '^(\d+),0:\s*\((\d+)') { [int]$Matches[2]/255.0 } })
    if ($rv.Count -lt 50 -or $cv.Count -lt 50) { return 999.0 }

    $all = @($rv + $cv | Sort-Object)
    $thr = $all[[int]($all.Count * 0.95)] - 0.05
    $wmm = ($W-2*$ins)/$Dpi*25.4; $hmm = ($H-2*$ins)/$Dpi*25.4

    $fc = $cv.Count; for ($i=0; $i -lt $cv.Count; $i++) { if ($cv[$i] -lt $thr) { $fc = $i; break } }
    $lc = $cv.Count; for ($i=$cv.Count-1; $i -ge 0; $i--) { if ($cv[$i] -lt $thr) { $lc = $cv.Count-1-$i; break } }
    $fr = $rv.Count; for ($i=0; $i -lt $rv.Count; $i++) { if ($rv[$i] -lt $thr) { $fr = $i; break } }
    $lr = $rv.Count; for ($i=$rv.Count-1; $i -ge 0; $i--) { if ($rv[$i] -lt $thr) { $lr = $rv.Count-1-$i; break } }

    $m = @(($IgnoreMm + $fc/300.0*$wmm), ($IgnoreMm + $lc/300.0*$wmm),
           ($IgnoreMm + $fr/300.0*$hmm), ($IgnoreMm + $lr/300.0*$hmm))
    ($m | Measure-Object -Minimum).Minimum
}

function Get-NsInkMargins {
    <#  Те саме, що Get-NsInkMargin, але ОКРЕМО по кожному краю, у мм.
        Потрібне, бо зміст підходить до країв нерівномірно: у верстці з жовтня
        2000 текст стоїть за 3 мм від низу, тоді як збоку лишається 15 мм.
        Вичищати всі краї на однакову глибину означає або лишити бруд збоку,
        або зрізати текст знизу.

        IgnoreMm = 3 підібрано виміром: на 2 мм замір ламається об залишок
        скла (2225 дає 2.0 замість 12.6), на 8 мм він сліпий у тій самій зоні,
        яку має захищати (2254 дає 8.0, хоча текст за 3 мм).             #>
    param([string]$Path, [int]$Dpi = 400, [double]$IgnoreMm = 3.0)

    $ins = [int]($IgnoreMm / 25.4 * $Dpi)
    $wh = (& magick identify -format "%w|%h" $Path 2>$null) -split '\|'
    if ($wh.Count -lt 2) { return $null }
    $W = [int]$wh[0]; $H = [int]$wh[1]
    if ($W -le 2*$ins -or $H -le 2*$ins) { return $null }
    $crop = "{0}x{1}+{2}+{3}" -f ($W-2*$ins), ($H-2*$ins), $ins, $ins

    # Кожен край ділиться на 4 відрізки, і береться НАЙГІРШИЙ з них.
    # Середнє по всій довжині краю сліпе до кутового вмісту: підвал «Наше
    # Слово, 8 października 2000» займає чверть ширини, і в середньому по
    # рядку губиться — замір показував «низ вільний на 25 мм», тоді як текст
    # стояв за 6 мм, і вичищення його стерло.
    # Один виклик magick із -resize "4x300!" дає одразу середні по кожному з
    # чотирьох відрізків: дешевше, ніж чотири окремі виміри.
    $rowsRaw = & magick $Path -crop $crop +repage -colorspace Gray -resize "4x300!" -depth 8 txt: 2>$null
    $colsRaw = & magick $Path -crop $crop +repage -colorspace Gray -resize "300x4!" -depth 8 txt: 2>$null

    $rows = @{ 0=@(); 1=@(); 2=@(); 3=@() }   # [відрізок][рядок згори вниз]
    foreach ($ln in $rowsRaw) {
        if ($ln -match '^(\d+),(\d+):\s*\((\d+)') { $rows[[int]$Matches[1]] += [int]$Matches[3]/255.0 }
    }
    $cols = @{ 0=@(); 1=@(); 2=@(); 3=@() }   # [відрізок][стовпець зліва направо]
    foreach ($ln in $colsRaw) {
        if ($ln -match '^(\d+),(\d+):\s*\((\d+)') { $cols[[int]$Matches[2]] += [int]$Matches[3]/255.0 }
    }
    if ($rows[0].Count -lt 50 -or $cols[0].Count -lt 50) { return $null }

    # Просадка 0,08 від рівня паперу — підібрано виміром, і це не дрібниця.
    # Треба розвести дві різні речі, що обидві темнішають біля краю:
    #     залишок краю аркуша  просаджує середнє по смужці на ~0,04
    #     справжній текст      просаджує на ~0,15
    # Поріг 0,05 (стояв спершу) спрацьовував на обох, і вичищення відмовлялося
    # чистити старі номери; поріг 0,11 переставав помічати підвал із датою.
    # Заміряно на трьох показових випадках:
    #     2231 p02 правий край (залишок)   0,05 -> 3,0 мм   0,08 -> 20,7 мм
    #     2254 p02 низ (підвал у куті)     0,05 -> 4,4 мм   0,08 ->  5,7 мм
    #     2254 p12 низ (текст на всю ширину) 0,05 -> 4,4 мм 0,08 ->  4,4 мм
    $all = @(0..3 | ForEach-Object { $rows[$_] + $cols[$_] } | Sort-Object)
    $thr = $all[[int]($all.Count * 0.95)] - 0.08
    $wmm = ($W-2*$ins)/$Dpi*25.4; $hmm = ($H-2*$ins)/$Dpi*25.4

    $res = @{ Left = 9999.0; Right = 9999.0; Top = 9999.0; Bottom = 9999.0 }
    foreach ($k in 0..3) {
        $cv = $cols[$k]; $rv = $rows[$k]
        $fc = $cv.Count; for ($i=0; $i -lt $cv.Count; $i++) { if ($cv[$i] -lt $thr) { $fc = $i; break } }
        $lc = $cv.Count; for ($i=$cv.Count-1; $i -ge 0; $i--) { if ($cv[$i] -lt $thr) { $lc = $cv.Count-1-$i; break } }
        $fr = $rv.Count; for ($i=0; $i -lt $rv.Count; $i++) { if ($rv[$i] -lt $thr) { $fr = $i; break } }
        $lr = $rv.Count; for ($i=$rv.Count-1; $i -ge 0; $i--) { if ($rv[$i] -lt $thr) { $lr = $rv.Count-1-$i; break } }
        $res.Left   = [math]::Min($res.Left,   $IgnoreMm + $fc/300.0*$wmm)
        $res.Right  = [math]::Min($res.Right,  $IgnoreMm + $lc/300.0*$wmm)
        $res.Top    = [math]::Min($res.Top,    $IgnoreMm + $fr/300.0*$hmm)
        $res.Bottom = [math]::Min($res.Bottom, $IgnoreMm + $lr/300.0*$hmm)
    }
    return $res
}

function Get-NsEdgeProfile {
    <#  Профіль краю: для кожної глибини (крок 0,5 мм, до DepthMm) — ЧАСТКА
        ВІДРІЗКІВ уздовж краю (по SegMm), у яких є фарба.
        Навіщо частка, а не середнє по рядку (як Get-NsInkMargins): стовпчик
        проколів від нитки — це 9-10 плям на 415 мм, тобто кілька відсотків
        відрізків, а шпальта тексту чи підвал із датою — десятки відсотків.
        Середнє обидва випадки змішує й бачить «текст за 3 мм» там, де лише
        проколи (2266 стор. 5, 6, 8, 10 — дірки лишилися в PDF).
        «Фарба» — відрізок темніший за папір СВОЄЇ смуги (90-й перцентиль) на 30.
        Повертає @{ Top=[double[]]; Bottom=...; Left=...; Right=... }.         #>
    param([string]$Path, [int]$Dpi = 400, [double]$DepthMm = 30.0, [double]$SegMm = 3.0)
    $wh = (& magick identify -ping -format "%w|%h" "$Path[0]" 2>$null) -split '\|'
    if ($wh.Count -lt 2) { return $null }
    $W = [int]$wh[0]; $H = [int]$wh[1]
    $dpx = [int]($DepthMm / 25.4 * $Dpi)
    $cols = [int]($DepthMm / 0.5)
    $tmp = Join-Path $env:TEMP ("ns_edge_" + [guid]::NewGuid().ToString("N") + ".gray")
    $res = @{}
    # кожну смугу повертаємо так, щоб край аркуша став ЛІВИМ стовпцем
    $spec = @{
        Left   = @{ crop = "${dpx}x$H+0+0";             op = @();              len = $H }
        Right  = @{ crop = "${dpx}x$H+$($W - $dpx)+0";  op = @("-flop");       len = $H }
        Top    = @{ crop = "${W}x$dpx+0+0";             op = @("-rotate","-90"); len = $W }
        Bottom = @{ crop = "${W}x$dpx+0+$($H - $dpx)";  op = @("-rotate","90");  len = $W }
    }
    foreach ($side in @("Top","Bottom","Left","Right")) {
        $s = $spec[$side]
        $rows = [math]::Max(20, [int](($s.len / $Dpi * 25.4) / $SegMm))
        & magick "$Path[0]" -crop $s.crop +repage @($s.op) -colorspace Gray -filter Box `
                 -resize "${cols}x${rows}!" -depth 8 "gray:$tmp" 2>$null | Out-Null
        if (-not (Test-Path $tmp)) { return $null }
        $b = [IO.File]::ReadAllBytes($tmp); Remove-Item $tmp -Force
        if ($b.Length -ne $cols * $rows) { return $null }
        $sorted = [byte[]]$b.Clone(); [Array]::Sort($sorted)
        $paper = [int]$sorted[[int]($sorted.Length * 0.9)]
        $thr = $paper - 30
        $thrInk = $paper - 70
        $frac = New-Object 'double[]' $cols
        $ink  = New-Object 'double[]' $cols
        $mean = New-Object 'double[]' $cols
        for ($c = 0; $c -lt $cols; $c++) {
            $n = 0; $k = 0; $sum = 0
            for ($r = 0; $r -lt $rows; $r++) {
                $v = $b[$r * $cols + $c]; $sum += $v
                if ($v -lt $thr) { $n++ }
                if ($v -lt $thrInk) { $k++ }
            }
            $frac[$c] = $n / $rows; $ink[$c] = $k / $rows; $mean[$c] = $sum / $rows
        }
        $res[$side] = $frac
        # Друга й третя мірки (17.09.2026): частка ТЕМНОЇ фарби (папір - 70) —
        # її не проходить світлий фоновий малюнок, а текст і фото проходять;
        # і середня яскравість — лише вона відрізняє чорну смугу скла від фото
        # на виліт (частка фарби в обох 50-60 %).
        $res["${side}Ink"] = $ink
        $res["${side}Mean"] = $mean
        $res["${side}Paper"] = $paper
        # сама сітка (рядок = відрізок уздовж краю, стовпець = 0,5 мм углиб) —
        # для місцевого запобіжника Get-NsEdgeLocal (21.09.2026)
        $res["${side}Grid"] = $b
        $res["${side}Rows"] = $rows
        $res["${side}Cols"] = $cols
    }
    return $res
}

function New-NsOcrGray {
    <#  Сіра копія сторінки для OCR, у якій ПЛАШКИ (світлий текст на темній
        рівній заливці) інвертовано — стають темним текстом на світлому.
        Інверсія не зсуває жодного пікселя, тож координати тексту збігаються з
        кольоровою сторінкою, і текстовий шар лишається один.
        Навіщо: thresholding_method=2 (Sauvola, обраний під сині плашки 2254)
        губить білий текст на темному. 2266/4 — польська плашка про Никифора і
        «Постанова IV з'їзду»: без інверсії 2 з 8 контрольних слів, з нею 8 з 8.
        Otsu читає такі плашки, але на 2254/1 дає 434 слова замість 766.
        Як шукаються плашки (18.09.2026, підбір на 2266/1, 4, 8, 2254/1, 2227/3):
          зменшена у 4 рази копія -> медіана 5x5 (прибирає літери) -> темніше
          за 55 % -> закриття -> зв'язні області, і плашкою вважається лише та,
          що заливає >= 85 % свого габариту й має щонайменше 6 x 20 мм.
        Саме заповнення габариту відсіює фото й гравюри: у них усередині багато
        світлого. Перша проба (лише «темне», без форми) інвертувала фото 2266/1
        і підняла частку підозрілих слів з 0,99 до 2,32 %; друга («темне +
        рівне» за розкидом) не брала плашку з великими літерами.
        Повертає частку інвертованої площі, %.                                  #>
    param([string]$Src, [string]$Out, [int]$DarkPct = 55, [double]$MinFill = 0.85)
    $T = Join-Path $env:TEMP ("ns_ocrg_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $T -Force | Out-Null
    try {
        & magick $Src -alpha off -colorspace Gray "$T\g.png" 2>$null
        # ЧЕРВОНА РУЧКА (24.09.2026, 2319/10): перекреслення від руки в сірій копії
        # стає темним хрестом поверх літер, і tesseract читає з блоків уривки
        # (слів у трьох блоках: 4 / 8 / 42 проти 35 / 42 / 56). Там, де ns-penmask
        # знайшов ручку, беремо канал R (червоне стає світлим); поза маскою піксель
        # лишається як був, тож друковане червоне (календар 2318, заголовки) не
        # гаситься. Збій скрипта — сіра копія без змін.
        $script:NS_LAST_PEN = ""
        $penOut = & python "$PSScriptRoot\ns-penmask.py" $Src "$T\pen.png" 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path "$T\pen.png") -and "$penOut" -match 'зон ручки (\d+); маска \d+ px = (\d+)' -and [int]$Matches[1] -gt 0) {
            $script:NS_LAST_PEN = "{0} зон, {1} мм2" -f $Matches[1], $Matches[2]
            & magick "$T\g.png" `( $Src -alpha off -channel R -separate +channel `) "$T\pen.png" -alpha off -composite "$T\g_pen.png" 2>$null
            if (Test-Path "$T\g_pen.png") { Move-Item "$T\g_pen.png" "$T\g.png" -Force }
        }
        $wh = (& magick identify -format "%w|%h" "$T\g.png" 2>$null) -split '\|'; $W = [int]$wh[0]; $H = [int]$wh[1]
        & magick "$T\g.png" -resize 25% -statistic Median 5x5 -threshold "$DarkPct%" -negate -morphology Close Disk:2 "$T\dark.png" 2>$null
        $sw = [int](& magick identify -format "%w" "$T\dark.png" 2>$null); $k = $W / [double]$sw
        $mm = $sw / ($W / 300.0 * 25.4)          # пікселів зменшеної копії на мм
        $cc = & magick "$T\dark.png" -define connected-components:verbose=true `
                       -define connected-components:area-threshold=300 -connected-components 8 null: 2>$null
        $draw = @()
        foreach ($ln in $cc) {
            if ($ln -match '^\s*\d+:\s+(\d+)x(\d+)\+(\d+)\+(\d+)\s+[\d.]+,[\d.]+\s+(\d+)\s+(?:gray|srgb)\((255|100%|65535)') {
                $bw = [int]$Matches[1]; $bh = [int]$Matches[2]; $bx = [int]$Matches[3]; $by = [int]$Matches[4]
                $fill = [int]$Matches[5] / [double]($bw * $bh)
                if ($fill -ge $MinFill -and $bh -ge 6 * $mm -and $bw -ge 20 * $mm) {
                    $draw += @("-draw", ("rectangle {0},{1} {2},{3}" -f [int]($bx*$k), [int]($by*$k), [int](($bx+$bw)*$k), [int](($by+$bh)*$k)))
                }
            }
        }
        if ($draw.Count -eq 0) { Copy-Item "$T\g.png" $Out -Force; return 0 }
        & magick -size "${W}x${H}" xc:black -fill white @draw "$T\mask.png" 2>$null
        & magick "$T\g.png" -negate "$T\neg.png" 2>$null
        & magick "$T\g.png" "$T\neg.png" "$T\mask.png" -composite $Out 2>$null
        return [double](& magick "$T\mask.png" -format "%[fx:round(1000*mean)/10]" info: 2>$null)
    } finally {
        Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-NsEdgeLocal {
    <#  Місцевий запобіжник краю (21.09.2026): де починається друк у КОЖНОМУ
        відрізку краю окремо, а не в частці по всій довжині.
        Навіщо: Get-NsEdgeCut міряє частку відрізків по всій довжині сторінки, і
        логотип, банер чи кілька рядків біля краю (кілька відсотків довжини) у
        ній губляться. 2294/1 і 2308/1 — «виліт до краю, ріжу 8» через логотип
        і банер «Лемківської ватри» (літери з 7,5 мм), 2308/10 прав. — друк «за
        10 мм» у середньому, а блок рядків ближче; усі три зрізали друк.
        У відрізку (0,5 мм на клітинку), починаючи з 2,5 мм від краю, друк —
          (А) темна фарба (папір - 70) 1,5 мм поспіль — текст, логотип, фото;
          (Б) світла фарба (папір - 40) одразу після >= 1,5 мм чистого паперу
              (папір -15..+12) — бліді кольори, літери банера 2294/1 (155-190).
        Чому не один поріг: пожовклий край аркуша (2266/5: 170-190 при папері
        223) і бліді літери лежать в одному діапазоні; розрізняє їх лише те, що
        перед літерами є чистий папір. Білий клин вирівнювання нахилу (255) —
        теж не папір, інакше будь-який папір після нього читався б «спадом»
        (так було в спробі з «різким спадом» 21.09.2026 — «друк за 2,5» скрізь).
        Пляма, що кінчається до 7,5 мм і має за собою 2 мм без фарби того ж
        рівня, — прокол, смуга скла чи тінь (у prep смугу відсуває клин, вона
        починається з ~2,5 мм — 2266/5, 6, 8). Справжній друк на боці йде вглиб.
        Пляма, перед якою від краю немає >= 1,5 мм паперового тону (білий клин
        і світлі місця фото не рахуються), — виліт чи смуга, не друк.
        Виліт (для позначки): фарба (папір - 30) суцільно від краю до 8 мм і далі.
        Відрізки ближче 10 мм до кутів пропускаються: там смуга сусіднього краю.
        Повертає @{ ContentMm (-1 якщо друку нема); ContentRows (скільки
        відрізків мають друк ближче MinMm); BleedRows }.                      #>
    param($EdgeProfile, [string]$Side, [double]$StepMm = 0.5, [double]$MinMm = 9.5, [double]$EdgeZoneMm = 2.5,
          [double]$HoleMaxMm = 7.5)   # глибина, до якої пляма може бути проколом (2002: 11 — див. NS_SPINE_RULES)
    $g = $EdgeProfile["${Side}Grid"]; $rows = $EdgeProfile["${Side}Rows"]; $cols = $EdgeProfile["${Side}Cols"]
    if (-not $g) { return @{ ContentMm = -1; ContentRows = 0; BleedRows = 0 } }
    $paper = $EdgeProfile["${Side}Paper"]; $thr = $paper - 30; $thrD = $paper - 70; $thrL = $paper - 40

    $skip = [math]::Max(1, [int]([math]::Ceiling($rows * 10.0 / 420.0)))
    $best = -1.0; $near = 0; $bleed = 0; $vals = @(); $bestRow = -1
    $z = [int]($EdgeZoneMm / $StepMm); $w = [int](2.0 / $StepMm)
    for ($r = $skip; $r -lt $rows - $skip; $r++) {
        $o = $r * $cols
        # виліт — лише для позначки: пляма від краю (фарба = папір - 30) до 8 мм і далі
        $e0 = -1
        for ($c = 0; $c -lt $cols; $c++) { if ($g[$o + $c] -lt $thr -or ($c + 1 -lt $cols -and $g[$o + $c + 1] -lt $thr)) { $e0 = $c } else { break } }
        if (($e0 + 1) * $StepMm -ge 8.0) { $bleed++ }
        # друк: (А) темна фарба (папір - 70) 1,5 мм поспіль; (Б) світла фарба
        # (папір - 40) одразу після >= 1,5 мм ЧИСТОГО паперу (у межах папір -15..+12:
        # не білий клин вирівнювання нахилу і не пожовклий край). Пляма, що
        # кінчається до 7,5 мм і має за собою 2 мм без фарби того ж рівня, —
        # прокол, смуга скла чи тінь.
        $content = -1.0
        for ($c = $z; $c -lt $cols - 2 -and $content -lt 0; $c++) {
            $lvl = -1
            if ($g[$o + $c] -lt $thrD -and $g[$o + $c + 1] -lt $thrD -and $g[$o + $c + 2] -lt $thrD) { $lvl = $thrD }
            elseif ($g[$o + $c] -lt $thrL -and $c -ge 3) {
                $pc = $true
                for ($k = $c - 3; $k -lt $c; $k++) { if ($g[$o + $k] -lt $paper - 15 -or $g[$o + $k] -gt $paper + 12) { $pc = $false } }
                if ($pc) { $lvl = $thrL }
            }
            if ($lvl -lt 0) { continue }
            $e = $c
            while ($e + 1 -lt $cols -and ($g[$o + $e + 1] -lt $lvl -or ($e + 2 -lt $cols -and $g[$o + $e + 2] -lt $lvl))) { $e++ }
            $clear = $true
            for ($k = $e + 1; $k -le [math]::Min($cols - 1, $e + $w); $k++) { if ($g[$o + $k] -lt $lvl) { $clear = $false } }
            if (($e + 1) * $StepMm -le $HoleMaxMm -and $clear) { $c = $e; continue }
            # пляма, що тягнеться від самого краю (фото на виліт, смуга скла з
            # проколами — 2266/2, 2266/8), — не друк, що «починається» тут
            # папір перед плямою = >= 1,5 мм поспіль паперового тону (папір -15..+12);
            # світлі місця фото на виліт папером не є (2294/5, 2308/1 — 21.09.2026)
            $fromEdge = $true; $run = 0
            for ($k = 1; $k -lt $c; $k++) {
                if ($g[$o + $k] -ge $paper - 15 -and $g[$o + $k] -le $paper + 12) { $run++; if ($run -ge 3) { $fromEdge = $false } } else { $run = 0 }
            }
            if ($fromEdge) { $c = $e; continue }
            $content = $c * $StepMm
        }
        if ($content -ge 0) {
            $vals += $content
            if ($best -lt 0 -or $content -lt $best) { $best = $content; $bestRow = $r }
            if ($content -lt $MinMm) { $near++ }
        }
    }
    # BestAtMm — де вздовж краю (від початку смуги, мм) лежить найближчий друк
    return @{ ContentMm = $best; ContentRows = $near; BleedRows = $bleed; Values = @($vals | Sort-Object)
              BestAtMm = if ($bestRow -ge 0) { [math]::Round(($bestRow + 0.5) * 3.0, 0) } else { -1 } }
}

function Repair-NsEdgeLine {
    <#  Замалювати ТОНКУ темну лінію вздовж краю (слід краю скла чи кришки),
        узявши папір із глибини тієї самої сторінки (23.09.2026, 2319/4 —
        оператор побачив чорну смужку згори готового PDF).
        Чому не зріз: лінія скісна (після вирівнювання нахилу) і є лише на
        частині ширини; щоб її відтяти, довелося б зрізати ~4 мм чистого поля
        на всю сторінку, а зрізане чисте поле оператор уже називав неохайним.
        Ретуш того ж роду, що й латання проколів (Repair-NsHoles).
        Обережності: працюємо лише в перших ZoneMm (5 мм); якщо темного в смузі
        більша за MaxThickMm (1 мм) — це не лінія, а плашка верстки чи фото до
        краю, і ми нічого не робимо. Джерело — смуга з глибини ZoneMm..2*ZoneMm.
        Повертає частку замальованого, %.                                      #>
    param([string]$Path, [string]$Side, [double]$ZoneMm = 5.0, [int]$Dpi = 400,
          [int]$DarkBelow = 50, [double]$MaxThickMm = 1.0)
    $wh = (& magick identify -ping -format "%w|%h" $Path 2>$null) -split '\|'
    if ($wh.Count -lt 2) { return 0 }
    $W = [int]$wh[0]; $H = [int]$wh[1]
    $z = [int]($ZoneMm / 25.4 * $Dpi)
    $spec = @{
        Top    = @{ crop = "${W}x$z+0+0";            src = "${W}x$z+0+$z" }
        Bottom = @{ crop = "${W}x$z+0+$($H - $z)";   src = "${W}x$z+0+$($H - 2*$z)" }
        Left   = @{ crop = "${z}x$H+0+0";            src = "${z}x$H+$z+0" }
        Right  = @{ crop = "${z}x$H+$($W - $z)+0";   src = "${z}x$H+$($W - 2*$z)+0" }
    }[$Side]
    if (-not $spec) { return 0 }
    $T = Join-Path $env:TEMP ("ns_line_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $T -Force | Out-Null
    try {
        & magick $Path -alpha off -crop $spec.crop +repage "$T\z.tif" 2>$null
        if (-not (Test-Path "$T\z.tif")) { return 0 }
        $paper = [int](& magick "$T\z.tif" -colorspace Gray -format "%[fx:round(255*maxima)]" info: 2>$null)
        $thr = [math]::Max(40, $paper - $DarkBelow)
        # ⚠︎ частку темного міряємо на СИРІЙ масці: після Dilate 4 px тонка лінія
        # на всю ширину дає 13-20 % і сама себе відхиляє (2319/4, 23.09.2026)
        $rawMask = Join-Path $T "rawmask.png"
        & magick "$T\z.tif" -colorspace Gray -threshold ("{0:N4}%" -f (100.0 * $thr / 255)) -negate -alpha off $rawMask 2>$null
        $ink = [double](& magick $rawMask -format "%[fx:100*mean]" info: 2>$null)
        # міра — СЕРЕДНЯ ТОВЩИНА темного, а не частка: частка залежить від ширини
        # смуги (7,2 % від 5 мм — це лінія 0,36 мм, тобто тонка; 23.09.2026)
        $thickMm = $ink / 100.0 * $ZoneMm
        if ($thickMm -lt 0.02 -or $thickMm -gt $MaxThickMm) { return 0 }
        # ширше розмиття маски (0x10) робить перехід непомітним: латка з глибини
        # трохи світліша за край, і при різкій межі лишався світлий слід лінії
        & magick $rawMask -morphology Dilate Disk:5 -blur 0x10 -alpha off -colorspace Gray "$T\mblur.png" 2>$null
        # ⚠︎ і лише по ПАПЕРУ: над краєм аркуша лежить біла зона від вирівнювання
        # нахилу (поза аркушем), і розмита латка замальовувала папером ще і її —
        # на кожній сторінці згори з'являлася сіра смуга (оператор, 23.09.2026)
        $paperMask = Join-Path $T "paper.png"
        & magick "$T\z.tif" -colorspace Gray -threshold ("{0:N4}%" -f (100.0 * ($paper - 12) / 255)) -negate `
                 -morphology Dilate Disk:3 -alpha off -colorspace Gray $paperMask 2>$null
        & magick "$T\mblur.png" $paperMask -compose Multiply -composite -alpha off -colorspace Gray "$T\m.png" 2>$null
        & magick $Path -alpha off -crop $spec.src +repage "$T\src.tif" 2>$null
        & magick "$T\z.tif" "$T\src.tif" "$T\m.png" -composite "$T\fixed.tif" 2>$null
        if (-not (Test-Path "$T\fixed.tif")) { return 0 }
        $off = ($spec.crop -split '\+')
        & magick $Path "$T\fixed.tif" -geometry ("+{0}+{1}" -f $off[1], $off[2]) -composite -compress LZW "$T\page.tif" 2>$null
        if (Test-Path "$T\page.tif") { Move-Item "$T\page.tif" $Path -Force; return [math]::Round($thickMm, 2) }
        return 0
    } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-NsEdgeDirtDepth {
    <#  Глибина темної лінії краю, поміряна В КОЖНОМУ ВІДРІЗКУ окремо.
        Навіщо: після вирівнювання нахилу лінія скла лягає СКІСНО (2319/4 — від
        ~1,5 мм зліва до 0 справа), і НАД нею білий клин від повороту. Профіль по
        всій ширині її не бачить: на кожній глибині вона займає малу частку
        довжини краю, тож частка фарби ~0, зріз нульовий — у PDF лишається тонка
        чорна смужка (оператор помітив на 2319/4).
        Рахуємо: у кожному відрізку шукаємо ПЕРШУ темну (папір - 70) смугу в
        перших ScanMm; якщо вона тонка (<= ThickMm — лінія, а не текст і не
        плашка), запам'ятовуємо її кінець. Беремо 90-й перцентиль по відрізках.
        Повертає 0, якщо таку лінію видно менш ніж у Frac відрізків.           #>
    param($EdgeProfile, [string]$Side, [double]$StepMm = 0.5, [double]$ThickMm = 1.5,
          [double]$ScanMm = 4.0, [double]$MaxMm = 5.0, [double]$Frac = 0.5)
    $g = $EdgeProfile["${Side}Grid"]; $rows = $EdgeProfile["${Side}Rows"]; $cols = $EdgeProfile["${Side}Cols"]
    if (-not $g) { return 0.0 }
    $thrD = $EdgeProfile["${Side}Paper"] - 70
    $scan = [int]($ScanMm / $StepMm)
    $depths = @()
    for ($r = 0; $r -lt $rows; $r++) {
        $o = $r * $cols
        for ($c = 0; $c -lt [math]::Min($scan, $cols - 1); $c++) {
            if ($g[$o + $c] -ge $thrD) { continue }
            $e = $c
            while ($e + 1 -lt $cols -and $g[$o + $e + 1] -lt $thrD) { $e++ }
            if ((($e - $c + 1) * $StepMm) -le $ThickMm) { $depths += ($e + 1) * $StepMm }
            break
        }
    }
    if ($depths.Count -lt [int]($rows * $Frac)) { return 0.0 }
    $sorted = @($depths | Sort-Object)
    $p90 = $sorted[[int]([math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * 0.9)))]
    return [math]::Min($MaxMm, $p90 + 0.5)
}

function Get-NsEdgeCut {
    <#  Скільки різати з кожного краю і скільки чистого поля лишається до друку.
        Вхід — Get-NsEdgeProfile (крок 0,5 мм): частка фарби (Frac), частка
        ТЕМНОЇ фарби (Ink, папір - 70) і середня яскравість.
        Повертає @{ Top=@{Cut; Free; Why}; ... } у мм.
          Cut  — зрізати як бруд;
          Free — скільки ще можна зняти ПІСЛЯ Cut, лишивши 1,5 мм до друку
                 (для зведення сторінок номера до одного розміру в ns-render).

        Правила (калібрування 17.09.2026 на prep 2266 до заливки, контроль 2254):
        ВЕРХ/НИЗ — лише темний край: смуга скла, лінія кришки, тінь обрізу.
          Темний край = суцільно від краю ті глибини (у перших 6 мм), де частка
          темної фарби перевищує фон глибини 3-8 мм більш ніж на 3 %.
          Ріжемо до його кінця + 0,5 мм. Чисте поле не чіпаємо: 7 мм зрізаного
          низу оператор назвав «дуже помітно і неохайно». 2266/3 верх — 2,0;
          2266/6 низ (фото до краю) — 1,5; 2254/2 низ (дата за 4,5) — 1,5;
          чорна плашка на всю глибину (2266/8 верх) — 0.
        БОКИ — там проколи, смуга скла, фото на виліт:
          шукаємо чисту смугу (темна фарба <= 2 % на 1 мм), починаючи з 1 мм
          (перші 0,5-1 мм часто займає білий клин від вирівнювання нахилу);
          якщо за нею друк (темна фарба >= 5 % на 1,5 мм) — ріжемо не ближче
          1,5 мм до нього (2266/10 лів.: поле, далі фото з 4 мм — 2,5;
          2254/2 лів.: текст з 6,5 — 5); якщо друку за смугою нема — ріжемо
          CleanMm (проколи, смуга: 2266/5, 2266/6);
          якщо чистої смуги нема зовсім — це виліт (фото, фоновий малюнок),
          ріжемо CleanMm за вказівкою оператора «на боках різати сміливо»
          (2266/10 прав., 2266/8).
        Вказівка в маніфесті (page_edge) має перевагу над усім цим.
        ⚠︎ Історія того ж дня: версія 1 (калібрована на майстрах) на prep не
        чистила нічого; версія 2 різала 8 мм з обох боків і 8 мм чистого низу;
        версія 3 («до останнього бруду») відрізала фото на 2266/10 зліва.
        Одна частка фарби не розрізняє смугу скла, фото і фоновий малюнок —
        потрібні всі три мірки.                                              #>
    param($EdgeProfile, [double]$CleanMm = 8.0, [double]$StepMm = 0.5,
          [string]$SpineSide = "", [double]$SpineCleanMm = 12.0, [double]$SpineHoleMaxMm = 11.0)
    if (-not $EdgeProfile) { return $null }
    $out = @{}
    $guard = 1.5
    foreach ($side in @("Top","Bottom","Left","Right")) {
        $ink = $EdgeProfile["${side}Ink"]; $n = $ink.Count
        # корінцевий бік року з великими проколами (NS_SPINE_RULES): глибший зріз
        # і плями до SpineHoleMaxMm вважаються проколами, а не друком
        $isSpine = ($SpineSide -and $side -eq $SpineSide)
        $cm = if ($isSpine) { $SpineCleanMm } else { $CleanMm }
        $hm = if ($isSpine) { $SpineHoleMaxMm } else { 7.5 }
        $why = ""; $cut = 0.0; $contentAt = -1
        if ($side -eq "Top" -or $side -eq "Bottom") {
            $b0 = [int](3.0 / $StepMm); $b1 = [math]::Min($n - 1, [int](8.0 / $StepMm))
            $base = (@($ink[$b0..$b1] | Sort-Object))[[int](($b1 - $b0) / 2)]
            $runEnd = -1
            for ($i = 0; $i -lt [math]::Min($n, [int](6.0 / $StepMm)); $i++) {
                if ($ink[$i] -gt $base + 0.03) { $runEnd = $i } elseif ($i -gt 1) { break }
            }
            $cut = if ($runEnd -ge 0) { ($runEnd + 1) * $StepMm + 0.5 } else { 0.0 }
            if ($base -gt 0.5) { $cut = 0.0; $why = "темна плашка до краю — не ріжу" }
            else {
                # скісна лінія краю (2319/4): міряємо по відрізках, а не по всій ширині
                $dd = Get-NsEdgeDirtDepth -EdgeProfile $EdgeProfile -Side $side -StepMm $StepMm
                if ($dd -gt $cut) { $cut = $dd; $why = ("скісна лінія краю — ріжу {0:N1}" -f $dd) }
            }
            # друк: після смуги <= 2 % — перша темна фарба >= 5 % на 1 мм
            $gap = $false
            for ($i = [int]($cut / $StepMm); $i -lt $n - 1; $i++) {
                if ($ink[$i] -le 0.02) { $gap = $true }
                if ($gap -and $ink[$i] -ge 0.05 -and $ink[$i+1] -ge 0.05) { $contentAt = $i; break }
            }
        } else {
            $i0 = [int](1.0 / $StepMm)
            $gapAt = -1
            for ($i = $i0; $i -lt [math]::Min($n - 1, [int](6.0 / $StepMm)); $i++) {
                if ($ink[$i] -le 0.02 -and $ink[$i+1] -le 0.02) { $gapAt = $i; break }
            }
            if ($gapAt -lt 0) {
                $cut = $cm; $why = "виліт до краю — ріжу $cm"
            } else {
                for ($i = $gapAt; $i -lt $n - 2; $i++) {
                    if ($ink[$i] -ge 0.05 -and $ink[$i+1] -ge 0.05 -and $ink[$i+2] -ge 0.05) { $contentAt = $i; break }
                }
                $cut = $cm
                if ($contentAt -ge 0 -and $contentAt * $StepMm - $guard -lt $cut) {
                    $cut = [math]::Max(0.0, $contentAt * $StepMm - $guard)
                    $why = "друк за {0:N1} мм" -f ($contentAt * $StepMm)
                }
            }
        }
        $free = 0.0
        if ($contentAt -ge 0) { $free = [math]::Max(0.0, $contentAt * $StepMm - $guard - $cut) }
        elseif ($why -like "*виліт*") { $free = 4.0 }   # фото/фон на виліт збоку: оператор дозволив різати боки
        elseif ($why -notlike "*плашка*") { $free = [math]::Max(0.0, $n * $StepMm - $guard - $cut) }
        # Місцевий запобіжник (21.09.2026) — див. Get-NsEdgeLocal. Правила вище
        # дивляться на частку по всій довжині й не бачать логотипа чи кількох
        # рядків біля краю. Сторінку, де він спрацював або де зріз іде по
        # друку на виліт, позначаємо Review — край вирішує оператор (page_edge).
        $review = $false
        $loc = Get-NsEdgeLocal -EdgeProfile $EdgeProfile -Side $side -StepMm $StepMm -HoleMaxMm $hm
        if ($loc.ContentMm -ge 0) {
            $lim = [math]::Max(0.0, $loc.ContentMm - $guard)
            # На КОРІНЦІ (рік із великими проколами) усе, що ближче за глибину
            # зрізу, — сліди зшивання: текст там починається з 18-20 мм (2002,
            # виміряно на 2319). Знахідка ближче не скорочує зріз, лише позначає
            # сторінку для нагляду: на 2319/6 злиплі проколи читалися як «друк за
            # 2,5 мм» і лишали дірки в готовому PDF.
            if ($isSpine -and $loc.ContentMm -lt $cm) {
                $review = $true
                $why = ("{0}; знахідка за {1:N1} мм — проколи, зріз не скорочую" -f $why, $loc.ContentMm).TrimStart('; ')
                $lim = $cut
            }
            if ($lim -lt $cut) {
                if ($cut - $lim -ge 0.5) { $review = $true }
                $why = ("місцевий друк за {0:N1} мм у {1} відрізк.; було {2:N1}" -f $loc.ContentMm, $loc.ContentRows, $cut)
                $cut = $lim; $free = 0.0
            } else {
                $free = [math]::Min($free, [math]::Max(0.0, $lim - $cut))
            }
        }
        if ($loc.BleedRows -ge 3 -and $cut -ge 3.0) {
            $review = $true
            $why = ("{0}; виліт у {1} відрізк." -f $why, $loc.BleedRows).TrimStart('; ')
        }
        # СКАСОВАНО 21.09.2026 (ввечері): «на позначеній стороні лише темний
        # край». Фото на виліт лишалися з дірками (2294/5, 2294/10), а ширші на
        # 10-15 мм сторінки роздували спільний розмір — рамка на решті ставала
        # нерівною (2294, 2308). Оператор: на фото дірки «можна прибрати, жодної
        # втрати». Тепер виліт ріжеться 8 мм, як раніше; захищається лише друк,
        # що починається після чистого паперу (місцевий запобіжник вище).
        if ($isSpine) { $why = ("корінець {0}; {1}" -f $cm, $why).TrimEnd(' ', ';') }
        $out[$side] = @{ Cut = [math]::Round($cut, 1); Free = [math]::Round($free, 1); Why = $why; Review = $review }
    }
    return $out
}

function Get-BandOffsets {
    param([string]$Path, [int]$Width, [int]$Height, [int]$Samples = 850)
    $v = Get-AxisOffsets -Path $Path -ResizeGeom "1x$Samples!"       -Coord 'y' -Length $Height -Samples $Samples
    $h = Get-AxisOffsets -Path $Path -ResizeGeom "${Samples}x1!"     -Coord 'x' -Length $Width  -Samples $Samples
    @{ Top = $v.Start; Bottom = $v.End; Left = $h.Start; Right = $h.End }
}

function Initialize-NsStore {
    foreach ($d in @($script:NS_MASTERS, $script:NS_WORK, $script:NS_PDF,
                     $script:CATALOG, $script:CHECKSUMS, $script:LOGS)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Get-NsIssueDir {
    param([int]$SeqFirst, [string]$Date)      # Date = РРРР-ММ-ДД
    $year = $Date.Substring(0, 4)
    Join-Path (Join-Path $script:NS_MASTERS $year) "${SeqFirst}_${Date}"
}

function Get-NsPageName {
    param([int]$SeqFirst, [string]$Date, [int]$Page)
    "{0}_{1}_p{2:D2}.tif" -f $SeqFirst, $Date, $Page
}

function Get-NsFrameCount {
    <#  Скільки зображень у TIF. Майстер сторінки має рівно одне.
        Обрізка «Automatic Multiple» у профілі сканера, знайшовши на аркуші
        кілька окремих ділянок, пише кожну окремим кадром в один TIF. Так
        11.09.2026 розпалися 2266 стор. 8 (шматок заголовка 567x190 окремо від
        решти сторінки, верх заголовка втрачено) і 2267 стор. 4 (календар —
        дві половини). Перевірка «файл читається» це пропускала: identify
        повертав злиплі розміри «567x1904692x5811», і рядок був непорожній.
        -ping читає лише заголовки, без декодування пікселів.               #>
    param([string]$Path)
    @(& magick identify -ping -format "%p`n" $Path 2>$null | Where-Object { $_ }).Count
}

function Get-NsHash {
    param([string]$Path)
    (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}

# ------------------------------------------------------- маніфест (стан номера)

function Read-NsManifest {
    param([string]$IssueDir)
    $p = Join-Path $IssueDir "_manifest.json"
    if (-not (Test-Path $p)) { return $null }
    Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-NsManifest {
    <#  Атомарний запис: спершу .tmp, потім заміна. Обрив живлення посеред
        запису не лишає напівзіпсованого маніфесту. #>
    param([string]$IssueDir, $Manifest)
    $p   = Join-Path $IssueDir "_manifest.json"
    $tmp = "$p.tmp"
    $json = $Manifest | ConvertTo-Json -Depth 10
    # PowerShell 5.1 екранує кирилицю як \uXXXX — розгортаємо назад, щоб файл
    # лишався придатним для читання й ручної правки людиною.
    $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})',
              { param($m) [char][int]("0x" + $m.Groups[1].Value) })
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $p -Force
}

function New-NsManifest {
    param([int]$SeqFirst, [int]$SeqLast, [string]$Date, [int]$NoInYear,
          [int]$PagesExpected, [string]$Source, [string]$Operator)
    [pscustomobject]@{
        title           = $script:TITLE
        publisher       = $script:PUBLISHER
        issn            = $script:ISSN
        seq_first       = $SeqFirst
        seq_last        = $SeqLast
        year            = [int]$Date.Substring(0, 4)
        issue_no_in_year = $NoInYear
        date            = $Date
        pages_expected  = $PagesExpected
        source          = $Source
        operator        = $Operator
        scan_date       = ""
        status          = "pending"
        pages           = @()
    }
}

function Get-NsNextPage {
    <#  Наступний номер сторінки = максимальний у маніфесті + 1.
        Саме маніфест, а не вміст теки: файл без запису в маніфесті вважається
        обірваним записом і не підхоплюється мовчки. #>
    param($Manifest)
    if (-not $Manifest.pages -or $Manifest.pages.Count -eq 0) { return 1 }
    # [int] обов'язковий: Measure-Object повертає Maximum як Double, а формат
    # "{0:D2}" (ім'я файлу сторінки) для нецілих типів падає з
    # "Format specifier was invalid". Виявлялося лише на відновленні номера.
    [int](($Manifest.pages | Measure-Object -Property n -Maximum).Maximum) + 1
}

function Add-NsPage {
    <#  Зареєструвати сторінку як надійно прийняту: хеш, розмір, час, read-only. #>
    param([string]$IssueDir, $Manifest, [int]$PageNo, [string]$FileName)
    $full = Join-Path $IssueDir $FileName
    $entry = [pscustomobject]@{
        n          = $PageNo
        file       = $FileName
        sha256     = Get-NsHash $full
        bytes      = (Get-Item $full).Length
        scanned_at = (Get-Date).ToString("s")
    }
    $Manifest.pages = @($Manifest.pages) + $entry
    Set-ItemProperty -Path $full -Name IsReadOnly -Value $true
    Write-NsManifest -IssueDir $IssueDir -Manifest $Manifest
    return $entry
}

function Test-NsPageDurable {
    <#  Сторінка надійна лише якщо: файл є, read-only, і хеш збігається з маніфестом. #>
    param([string]$IssueDir, $PageEntry)
    $full = Join-Path $IssueDir $PageEntry.file
    if (-not (Test-Path $full)) { return $false }
    if (-not (Get-Item $full).IsReadOnly) { return $false }
    (Get-NsHash $full) -eq $PageEntry.sha256
}

function Find-NsOrphans {
    <#  Файли в теці, яких немає в маніфесті — показати, але не підхоплювати. #>
    param([string]$IssueDir, $Manifest)
    $known = @($Manifest.pages | ForEach-Object { $_.file })
    Get-ChildItem -Path $IssueDir -Filter "*.tif" -File |
        Where-Object { $known -notcontains $_.Name }
}

# --------------------------------------------------------------- реєстр (CSV)

function Read-NsRegistry {
    if (-not (Test-Path $script:REGISTRY)) { return @() }
    @(Import-Csv -Path $script:REGISTRY -Encoding UTF8)
}

function Write-NsRegistry {
    param($Rows)
    $tmp = "$script:REGISTRY.tmp"
    # Однаковий набір колонок у КОЖНОМУ рядку: Export-Csv бере колонки з першого об'єкта, і старі
    # рядки без `state` (25.09.2026, стан конвеєра) інакше втратили б або перекосили нову колонку.
    $cols = @("seq_first", "seq_last", "year", "issue_no_in_year", "date", "pages", "source_volume",
              "scan_date", "operator", "status", "bytes", "notes", "state")
    @($Rows) | ForEach-Object {
        $r = $_; $o = [ordered]@{}
        foreach ($c in $cols) { $o[$c] = if ($r.PSObject.Properties.Name -contains $c) { $r.$c } else { "" } }
        [pscustomobject]$o
    } | Sort-Object { [int]$_.seq_first } | Export-Csv -Path $tmp -NoTypeInformation -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:REGISTRY -Force
}

# ------------------------------------------------ стан номера в конвеєрі (КОНВЕЄР.md)
# Джерело істини — поле `state` у маніфесті; колонка `state` у реєстрі лише віддзеркалює його.
# Старі номери (до 25.09.2026) поля не мають: їхній стан порожній і меню їх не чіпає.
#   scanning -> scanned -> accepted -> ready | review -> fix -> review ... -> done -> backed_up
$script:NS_STATES = @("scanning", "scanned", "accepted", "review", "fix", "ready", "done", "backed_up")

function Get-NsIssueState {
    param($Manifest)
    if ($Manifest -and $Manifest.PSObject.Properties.Name -contains 'state' -and $Manifest.state) { return [string]$Manifest.state }
    return ""
}

function Set-NsIssueState {
    <#  Записати стан номера в маніфест (з історією `state_log`) і віддзеркалити в реєстр. #>
    param([string]$IssueDir, $Manifest, [string]$State, [string]$Note = "")
    if ($script:NS_STATES -notcontains $State) { throw "Невідомий стан '$State'. Дозволені: $($script:NS_STATES -join ', ')" }
    $now = (Get-Date).ToString("s")
    $Manifest | Add-Member -NotePropertyName state -NotePropertyValue $State -Force
    $Manifest | Add-Member -NotePropertyName state_at -NotePropertyValue $now -Force
    $log = @()
    if ($Manifest.PSObject.Properties.Name -contains 'state_log') { $log = @($Manifest.state_log) }
    $log += [pscustomobject]@{ state = $State; at = $now; note = $Note }
    $Manifest | Add-Member -NotePropertyName state_log -NotePropertyValue $log -Force
    Write-NsManifest -IssueDir $IssueDir -Manifest $Manifest
    $bytes = if (@($Manifest.pages).Count -gt 0) { [long](@($Manifest.pages) | Measure-Object -Property bytes -Sum).Sum } else { 0 }
    Set-NsRegistryRow -Manifest $Manifest -Status $Manifest.status -Bytes $bytes
}

function Set-NsRegistryRow {
    <#  Додати або оновити рядок реєстру за seq_first. #>
    param($Manifest, [string]$Status, [long]$Bytes = 0)
    $rows = @(Read-NsRegistry)
    $row = [pscustomobject]@{
        seq_first        = $Manifest.seq_first
        seq_last         = $Manifest.seq_last
        year             = $Manifest.year
        issue_no_in_year = $Manifest.issue_no_in_year
        date             = $Manifest.date
        pages            = @($Manifest.pages).Count
        source_volume    = $Manifest.source
        scan_date        = $Manifest.scan_date
        operator         = $Manifest.operator
        status           = $Status
        bytes            = $Bytes
        notes            = ""
        state            = (Get-NsIssueState $Manifest)
    }
    $rows = @($rows | Where-Object { [int]$_.seq_first -ne [int]$Manifest.seq_first })
    Write-NsRegistry -Rows (@($rows) + $row)
}

function Sync-NsRegistry {
    <#  Перебудувати реєстр із маніфестів.
        Реєстр — похідні дані: джерело істини завжди маніфест у теці номера.
        Тому реєстр має бути відновлюваним, а не лікуватися вручну.
        Повертає перелік виправлених розбіжностей. #>
    $before = @{}
    foreach ($r in Read-NsRegistry) { $before["$($r.seq_first)"] = $r }

    $rows = @()
    $fixed = @()
    foreach ($dir in Get-ChildItem -Path $script:NS_MASTERS -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '^\d{4}$' } |
                     ForEach-Object { Get-ChildItem -Path $_.FullName -Directory }) {
        $man = Read-NsManifest -IssueDir $dir.FullName
        if (-not $man) { continue }
        $pages = @($man.pages).Count
        $bytes = if ($pages -gt 0) { (@($man.pages) | Measure-Object -Property bytes -Sum).Sum } else { 0 }
        $rows += [pscustomobject]@{
            seq_first        = $man.seq_first
            seq_last         = $man.seq_last
            year             = $man.year
            issue_no_in_year = $man.issue_no_in_year
            date             = $man.date
            pages            = $pages
            source_volume    = $man.source
            scan_date        = $man.scan_date
            operator         = $man.operator
            status           = $man.status
            bytes            = $bytes
            notes            = ""
            state            = (Get-NsIssueState $man)
        }
        $old = $before["$($man.seq_first)"]
        if (-not $old) {
            $fixed += "$($man.seq_first): не було в реєстрі, додано ($pages стор.)"
        } elseif ([int]$old.pages -ne $pages -or $old.status -ne $man.status) {
            $fixed += "$($man.seq_first): реєстр казав $($old.pages) стор./$($old.status), маніфест — $pages/$($man.status)"
        }
    }
    if ($rows.Count -gt 0) { Write-NsRegistry -Rows $rows }
    return $fixed
}

function Test-NsDateContinuity {
    <#  Газета тижнева, тож між сусідніми номерами має бути рівно 7 днів.
        Виняток: випуск за кілька тижнів. Такий був у 2000 році — № 52 (2265)
        з датою «24-31 грудня»: номер одиничний, а покриває два тижні, і
        наступний вийшов аж 7 січня. Без поправки це виглядає як пропущений
        номер, з поправкою — як задокументована особливість.
        Щоб перевірка мовчала, у маніфесті має бути поле `covers` виду
        "2000-12-24..2000-12-31".
        Питати про це при кожному заведенні номера не варто: зайвий Enter на
        кожен із ~715 випусків заради кількох випадків на межі років. Краще
        хай скаже перевірка саме тоді, коли трапиться.                      #>
    $rows = @(Read-NsRegistry | Sort-Object { [int]$_.seq_first })
    $out = @()
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $prev = $rows[$i-1]; $cur = $rows[$i]
        try {
            $d1 = [datetime]::ParseExact($prev.date, "yyyy-MM-dd", $null)
            $d2 = [datetime]::ParseExact($cur.date,  "yyyy-MM-dd", $null)
        } catch { continue }
        $days = ($d2 - $d1).Days
        if ($days -eq 7) { continue }
        # номери, яких фізично немає (missing.csv), додають свої тижні:
        # 2316 -> 2318 це 14 днів, бо між ними відсутній 2317 (23.09.2026)
        $gapWeeks = @(Get-NsMissing | Where-Object { [int]$_.seq -gt [int]$prev.seq_last -and [int]$_.seq -lt [int]$cur.seq_first }).Count
        if ($days -eq 7 * (1 + $gapWeeks)) { continue }

        # чи пояснено це полем covers у попередньому номері
        $ok = $false
        $pd = Find-NsIssueDir -Seq ([int]$prev.seq_first)
        if ($pd) {
            $pm = Read-NsManifest -IssueDir $pd
            if ($pm -and $pm.PSObject.Properties.Name -contains 'covers' -and $pm.covers -match '\.\.(\d{4}-\d{2}-\d{2})$') {
                try {
                    $end = [datetime]::ParseExact($Matches[1], "yyyy-MM-dd", $null)
                    if (($d2 - $end).Days -eq 7) { $ok = $true }
                } catch { }
            }
        }
        if (-not $ok) {
            $out += "між $($prev.seq_first) ($($prev.date)) і $($cur.seq_first) ($($cur.date)) — $days днів замість 7"
        }
    }
    return $out
}

function Get-NsMissing {
    <#  Номери, яких ФІЗИЧНО немає в річнику (21.09.2026: 2317 — між 2316 і
        першим номером 2002 року 2318). Ведеться вручну за словами оператора в
        _catalog\missing.csv: seq,date,year,no_in_year,note. Дата й номер у
        році — розрахункові (тижнева закономірність), бо примірника немає.  #>
    $p = Join-Path $script:CATALOG "missing.csv"
    if (-not (Test-Path $p)) { return @() }
    @(Import-Csv -Path $p -Encoding UTF8)
}

function Test-NsSeqContinuity {
    <#  Перевірка #4 зі специфікації: seq_first[n] == seq_last[n-1] + 1.
        Повертає перелік розривів. Номери з missing.csv розривом не є. #>
    $rows = @(Read-NsRegistry | Sort-Object { [int]$_.seq_first })
    $miss = @(Get-NsMissing | ForEach-Object { [int]$_.seq })
    $gaps = @()
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $prev = [int]$rows[$i - 1].seq_last
        $cur  = [int]$rows[$i].seq_first
        $exp = $prev + 1
        while ($miss -contains $exp) { $exp++ }
        if ($cur -ne $exp) {
            $gaps += "розрив: після $prev очікувався $exp, а є $cur"
        }
    }
    return $gaps
}


# ------------------------------------------------ живий перегляд скану (21.09.2026)
# ns-scan після кожної сторінки кладе в NS_WORK\_live зменшену копію, збільшений
# кут із номером сторінки й state.json з перевірками; ns-viewer.ps1 показує це на
# другому моніторі. Перевірки — підказки для ока оператора, не вироки.
$script:NS_LIVE = Join-Path $script:NS_WORK "_live"

function Write-NsLiveState {
    param([hashtable]$State)
    New-Item -ItemType Directory -Path $script:NS_LIVE -Force | Out-Null
    $p = Join-Path $script:NS_LIVE "state.json"; $tmp = "$p.tmp"
    $State.ts = (Get-Date).ToString("o")
    [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    # ⚠︎ Move-Item -Force падає з «Cannot create a file when that file already
    # exists», якщо саме в цю мить state.json читає ns-viewer (23.09.2026,
    # сканування 2325 стор. 4 — сторінка збереглася, впав лише перегляд).
    # Спроби з паузою, а як не вийшло — пишемо поверх; живий перегляд не варто
    # того, щоб через нього спинялося сканування.
    for ($i = 0; $i -lt 5; $i++) {
        try { Move-Item -Path $tmp -Destination $p -Force -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 }
    }
    try {
        [IO.File]::Copy($tmp, $p, $true)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Set-NsLiveStatus {
    <#  Лише змінити статус (scanning / done), лишивши останню картинку. #>
    param([string]$Status, [int]$Page = 0)
    $p = Join-Path $script:NS_LIVE "state.json"
    $st = @{}
    if (Test-Path $p) {
        $o = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $o.PSObject.Properties.Name) { $st[$k] = $o.$k }
    }
    $st.status = $Status
    if ($Page) { $st.next = $Page }
    Write-NsLiveState -State $st
}

function Get-NsPageHint {
    <#  Що має бути надруковано на цій сторінці (з поправкою на вкладку).     #>
    param([int]$Page, [string]$Insert = "")
    $f = 0; $t = 0
    if ($Insert -match '^\s*(\d+)\s*-\s*(\d+)\s*$') { $f = [int]$Matches[1]; $t = [int]$Matches[2] }
    if ($f -and $Page -ge $f -and $Page -le $t) { return ("Вкладка: {0}-та сторінка вкладки (своя нумерація)" -f ($Page - $f + 1)) }
    $printed = $Page
    if ($f -and $Page -gt $t) { $printed = $Page - ($t - $f + 1) }
    if ($printed -eq 1) { return "Перша сторінка — друкованого номера немає" }
    if ($printed % 2 -eq 0) { return "Має бути «$printed» — ЛІВОРУЧ унизу" }
    return "Має бути «$printed» — ПРАВОРУЧ унизу"
}

function Show-NsLiveFast {
    <#  ШВИДКИЙ показ щойно відсканованої сторінки: один запуск ImageMagick
        (0,7 с), і сторінка вже на екрані. Решта перевірок іде окремим
        процесом (ns-livecheck.ps1) і дописує тривоги в той самий state.json.
        Прохання оператора 23.09.2026: «хочу одразу бачити те, що щойно пройшло
        в сканері» — раніше показ чекав на всі перевірки (до 8 с) і відставав
        на кілька сторінок.
        Повертає @{ Mean; Sd } з тієї ж зменшеної копії — цього досить, щоб
        одразу відсіяти порожній/чорний кадр, не декодуючи майстер удруге.   #>
    param([string]$Tif, [int]$Seq, [int]$Page, [int]$Expected, [string]$Insert = "", [int]$Frames = 1)
    $L = $script:NS_LIVE
    New-Item -ItemType Directory -Path $L -Force | Out-Null
    $prev = Join-Path $L "preview.jpg"
    $stat = $null; $mean = 0.5; $sd = 0.2
    # Постійний працівник (ns-fastpreview.py, запускає ns-scan): PIL уже
    # завантажений, показ ~0,45 с замість ~0,85 с з ImageMagick (24.09.2026).
    # Не відповів за 4 с — нижче звичайний ImageMagick, як раніше.
    if ($script:NS_FASTWORKER) {
        $script:NS_FASTREQ = [int]$script:NS_FASTREQ + 1
        $rq = Join-Path $L "req.json"; $rs = Join-Path $L "resp.json"
        $json = '{"id":' + $script:NS_FASTREQ + ',"tif":"' + $Tif.Replace('\', '\\') + '"}'
        [IO.File]::WriteAllText("$rq.tmp", $json, [Text.UTF8Encoding]::new($false))
        Move-Item "$rq.tmp" $rq -Force
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 4) {
            try {
                $o = Get-Content $rs -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                if ($o.id -eq $script:NS_FASTREQ -and -not $o.error) {
                    $mean = [double]$o.mean; $sd = [double]$o.sd; $stat = "ok"; break
                }
                if ($o.id -eq $script:NS_FASTREQ) { break }
            } catch { }
            Start-Sleep -Milliseconds 5
        }
        # не відповів — далі працюємо без нього, щоб не платити 4 с щоразу
        if (-not $stat) { $script:NS_FASTWORKER = $false }
    }
    if (-not $stat) {
    $stat = & magick "$Tif[0]" -resize 1080x1600 -quality 88 -write $prev `
                     -colorspace Gray -format "%[fx:mean] %[fx:standard_deviation]" info: 2>$null
    if ($stat) {
        $pp = "$stat".Trim() -split '\s+'
        if ($pp.Count -ge 2) {
            $mean = [double]::Parse($pp[0], [Globalization.CultureInfo]::InvariantCulture)
            $sd = [double]::Parse($pp[1], [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    }
    Write-NsLiveState -State @{
        status = "ready"; seq = $Seq; page = $Page; expected = $Expected
        dims = ""; frames = $Frames; expect = (Get-NsPageHint -Page $Page -Insert $Insert)
        warnings = @(); checking = $true; next = $Page + 1
    }
    return @{ Mean = $mean; Sd = $sd }
}

function Update-NsLive {
    <#  Готує перегляд щойно відсканованої сторінки й перевіряє її.
        Пороги (калібрування 21.09.2026 на наявних майстрах):
          та сама сторінка ще раз — RMSE нормованих сірих 60x84 < 0,10:
            той самий аркуш, перезнятий (2280, старі скани в removed): 0,015-0,031,
            навіть посунутий; різні сусідні сторінки (2280, 2290): 0,28-0,40;
          порожній/чорний кадр — середнє < 0,35 або розкид < 0,05:
            2240/11 (скло без аркуша) 0,10 / 0,016; звичайна сторінка 0,71 / 0,20;
          смуга кришки — чорне (< 115) від межі кадру вздовж УСЬОГО боку (обидві
            половини >= 1,5 мм): на сталій області 298x418 аркуш займає весь кадр,
            звичайні скани дають 0 мм з усіх боків; темна плашка під край (2280/1)
            займає лише половину боку й тривоги не дає;
          розмір — профіль Arhiv400 дає рівно 4693x6583.                        #>
    param([string]$Tif, [int]$Seq, [int]$Page, [int]$Expected, [string]$PrevTif = "",
          [string]$IssueDir = "", [string]$Insert = "", [string]$Title = "",
          [switch]$NoPreview, [int]$ExpectW = 4693, [int]$ExpectH = 6583)
    $L = $script:NS_LIVE
    New-Item -ItemType Directory -Path $L -Force | Out-Null
    $warn = @()
    $wh = (& magick identify -ping -format "%w|%h" "$Tif[0]" 2>$null) -split '\|'
    $W = [int]$wh[0]; $H = [int]$wh[1]
    $frames = Get-NsFrameCount -Path $Tif
    if ($frames -ne 1) { $warn += @{ lvl = "err"; text = "Скан розпався на $frames кадрів" } }
    if ($W -ne $ExpectW -or $H -ne $ExpectH) { $warn += @{ lvl = "err"; text = "Розмір ${W}x$H замість ${ExpectW}x$ExpectH — інший профіль чи область?" } }

    $small = Join-Path $L ("small_p{0:D2}.png" -f $Page)
    # збільшений кут і мініатюру попередньої оператор назвав зайвими (21.09.2026) —
    # лише сторінка, якнайбільша
    # ⚠︎ швидкодія: декодування майстра на 65 МБ — найдорожча дія, тому робимо
    # ЇЇ ОДИН РАЗ і одразу пишемо всі похідні (23.09.2026: перегляд відставав на
    # кілька сторінок, бо на кожен скан ішло до дванадцяти запусків ImageMagick).
    $cur60 = Join-Path $L "cmp_cur.gray"
    if ($NoPreview) {
        # показ уже зробив Show-NsLiveFast — тут лише те, що потрібно перевіркам
        & magick "$Tif[0]" -resize 25% -write $small `
                 -colorspace Gray -resize '60x84!' -normalize -depth 8 "gray:$cur60" 2>$null
    } else {
        & magick "$Tif[0]" -resize 25% -write $small `
                 '(' +clone -resize 1080x1600 -quality 88 -write (Join-Path $L "preview.jpg") +delete ')' `
                 -colorspace Gray -resize '60x84!' -normalize -depth 8 "gray:$cur60" 2>$null
    }

    # порожній / чорний кадр
    $st = (& magick $small -colorspace Gray -format "%[fx:mean] %[fx:standard_deviation]" info: 2>$null) -split ' '
    $mean = [double]::Parse($st[0], [Globalization.CultureInfo]::InvariantCulture)
    $sd = [double]::Parse($st[1], [Globalization.CultureInfo]::InvariantCulture)
    if ($mean -lt 0.35 -or $sd -lt 0.05) { $warn += @{ lvl = "err"; text = "Порожній або чорний кадр — кришка відкрита чи аркуша немає?" } }

    # смуга кришки вздовж усього боку (на порожньому кадрі — зайве)
    # ⚠︎ змінна половини — $hh, НЕ $h: $h і висота $H — та сама змінна (регістр)
    $names = @{ T = "згори"; B = "знизу"; L = "зліва"; R = "справа" }
    if (-not ($mean -lt 0.35 -or $sd -lt 0.05)) {
        # одна команда на всі чотири сторони: кожна смуга 40 клітинок углиб,
        # 2 половини вздовж краю (раніше було чотири окремі запуски)
        $bandFile = @{}
        $args4 = @($small, "-colorspace", "Gray", "-write", "mpr:pg", "+delete")
        foreach ($sd2 in @(@('T','0'),@('B','180'),@('L','90'),@('R','-90'))) {
            $f = Join-Path $L ("band_{0}.gray" -f $sd2[0]); $bandFile[$sd2[0]] = $f
            $args4 += @("(", "mpr:pg", "-rotate", $sd2[1], "-gravity", "north", "-crop", "100%x40+0+0", "+repage",
                        "-resize", "2x40!", "-depth", "8", "-write", "gray:$f", "+delete", ")")
        }
        $args4 += "null:"
        & magick @args4 2>$null
        foreach ($k in @('T','B','L','R')) {
            $f = $bandFile[$k]
            if (-not (Test-Path $f)) { continue }
            $b = [IO.File]::ReadAllBytes($f); Remove-Item $f -Force -ErrorAction SilentlyContinue
            if ($b.Length -lt 80) { continue }
            $dd = @()
            foreach ($hh in 0, 1) { $d = 0; for ($y = 0; $y -lt 40; $y++) { if ($b[$y * 2 + $hh] -lt 115) { $d = ($y + 1) / 4 } else { break } }; $dd += $d }
            if ($dd[0] -ge 1.5 -and $dd[1] -ge 1.5) {
                $warn += @{ lvl = "warn"; text = ("Чорна смуга кришки {0} ({1}-{2} мм) — аркуш зсунуто? Протилежний край може бути зрізано" -f $names[$k], $dd[0], $dd[1]) }
            }
        }
    }

    $rmse = $null; $dupPage = 0
    if ((Test-Path $cur60) -and $Page -gt 1 -and $IssueDir -and (Test-Path $IssueDir)) {
        $a = [IO.File]::ReadAllBytes($cur60)
        foreach ($q in (Get-ChildItem $IssueDir -Filter "*_p*.tif" -File)) {
            if ($q.Name -notmatch '_p(\d+)\.tif$') { continue }
            $qn = [int]$Matches[1]
            if ($qn -ge $Page) { continue }
            $qf = Join-Path $L ("cmp_p{0:D2}.gray" -f $qn)
            if (-not (Test-Path $qf)) {
                & magick "$($q.FullName)[0]" -colorspace Gray -resize '60x84!' -normalize -depth 8 "gray:$qf" 2>$null
            }
            if (-not (Test-Path $qf)) { continue }
            $b = [IO.File]::ReadAllBytes($qf)
            if ($b.Length -ne $a.Length) { continue }
            $acc = 0.0
            for ($i = 0; $i -lt $a.Length; $i++) { $d = [double]($a[$i] - $b[$i]); $acc += $d * $d }
            $v = [math]::Sqrt($acc / $a.Length) / 255.0
            if ($null -eq $rmse -or $v -lt $rmse) { $rmse = $v; $dupPage = $qn }
        }
        if ($null -ne $rmse -and $rmse -lt 0.10) {
            $warn += @{ lvl = "err"; text = ("Майже те саме, що стор. {0} (відмінність {1:N3}) — той самий аркуш ще раз?" -f $dupPage, $rmse) }
        }
    }
    if (Test-Path $cur60) { Copy-Item $cur60 (Join-Path $L ("cmp_p{0:D2}.gray" -f $Page)) -Force }

    # малі копії потрібні до кінця номера — прибираються на старті ns-scan
    Get-ChildItem $L -Filter "small_p*.png" | Where-Object { $_.Name -ne (Split-Path $small -Leaf) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    if ($Expected -and $Page -gt $Expected) { $warn += @{ lvl = "warn"; text = "Сторінок уже більше, ніж очікувалось ($Expected)" } }

    $expect = Get-NsPageHint -Page $Page -Insert $Insert

    # не перебивати стан, якщо оператор уже гортає НАСТУПНУ сторінку
    # (перевірки йдуть у фоні й можуть закінчитися вже після наступного скану)
    $sp = Join-Path $L "state.json"
    if ($NoPreview -and (Test-Path $sp)) {
        try {
            $cur = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$cur.page -ne $Page) { return @($warn) }
        } catch { }
    }

    Write-NsLiveState -State @{
        status = "ready"; seq = $Seq; page = $Page; expected = $Expected; title = $Title
        dims = "${W}x$H"; frames = $frames; expect = $expect; warnings = @($warn)
        rmse = $rmse; next = $Page + 1; checking = $false
    }
    return @($warn)
}


function Get-NsViewerScreen {
    <#  Екран для живого перегляду: вертикальний неосновний (HP X24ih), інакше
        найбільший неосновний; $null, якщо другого екрана немає.            #>
    Add-Type -AssemblyName System.Windows.Forms
    $all = [System.Windows.Forms.Screen]::AllScreens
    $s = $all | Where-Object { -not $_.Primary -and $_.Bounds.Height -gt $_.Bounds.Width } | Select-Object -First 1
    if (-not $s) { $s = $all | Where-Object { -not $_.Primary } | Sort-Object { $_.Bounds.Width * $_.Bounds.Height } -Descending | Select-Object -First 1 }
    return $s
}

$script:NS_CONSOLE_RESERVE = 380   # пікселів унизу екрана перегляду — під консоль

function Move-NsConsoleBelowViewer {
    <#  Перенести ВЛАСНЕ вікно консолі в нижню смугу екрана перегляду (HP X24ih),
        де оператор його тримає, — вікно перегляду займає верх (прохання
        оператора 21.09.2026: «щоб консоль відкривалася на додатковому»).
        Класична консоль: вікно дає GetConsoleWindow.
        Windows Terminal (так відкривається ярлик на цій машині): GetConsoleWindow
        дає невидиме вікно-посередник, і перша версія «успішно» рухала його, а
        справжнє вікно лишалося на основному моніторі. Тому шукаємо вікно
        WindowsTerminal за ЗАГОЛОВКОМ — на мить робимо заголовок вкладки
        унікальним (з PID), знаходимо, рухаємо, повертаємо заголовок.
        Кожна спроба пишеться в NS_WORK\_live\console_move.log.                #>
    $scr = Get-NsViewerScreen
    $logf = Join-Path $script:NS_LIVE "console_move.log"
    New-Item -ItemType Directory -Path $script:NS_LIVE -Force | Out-Null
    function Log-Move([string]$m) { Add-Content -Path $logf -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date).ToString("s"), $m) }
    if (-not $scr) { Log-Move "другого екрана немає"; return $false }
    if (-not ("NsW.Win2" -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
namespace NsW { public static class Win2 {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr FindByTitle(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
      if (sb.ToString().Contains(title)) { found = h; return false; }
      return true; }, IntPtr.Zero);
    return found; }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
} }
"@
    }
    $wa = $scr.WorkingArea; $r = $script:NS_CONSOLE_RESERVE
    $x = $wa.X; $y = $wa.Y + $wa.Height - $r; $w = $wa.Width

    # 1) класична консоль — лише якщо її вікно справді видиме й не нульове
    $h = [NsW.Win2]::GetConsoleWindow()
    $rc = New-Object NsW.Win2+RECT
    if ($h -ne [IntPtr]::Zero -and [NsW.Win2]::IsWindowVisible($h) -and [NsW.Win2]::GetWindowRect($h, [ref]$rc) -and ($rc.R - $rc.L) -gt 50) {
        $pn = (Get-Process -Id ([NsW.Win2]::Pid($h)) -ErrorAction SilentlyContinue).ProcessName
        if ($pn -ne "WindowsTerminal") {
            [void][NsW.Win2]::ShowWindow($h, 9)
            $ok = [NsW.Win2]::MoveWindow($h, $x, $y, $w, $r, $true)
            Log-Move ("класична консоль ({0}): MoveWindow={1} -> {2},{3} {4}x{5}" -f $pn, $ok, $x, $y, $w, $r)
            return $ok
        }
    }
    # 2) Windows Terminal — за унікальним заголовком вкладки
    $old = $Host.UI.RawUI.WindowTitle
    $tag = "ns-move-$PID"
    try {
        $Host.UI.RawUI.WindowTitle = "$old $tag"
        $wt = [IntPtr]::Zero
        for ($i = 0; $i -lt 20 -and $wt -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $wt = [NsW.Win2]::FindByTitle($tag) }
    } finally { $Host.UI.RawUI.WindowTitle = $old }
    if ($wt -eq [IntPtr]::Zero) { Log-Move "вікна з заголовком '$tag' не знайдено (заголовок '$old')"; return $false }
    $pn = (Get-Process -Id ([NsW.Win2]::Pid($wt)) -ErrorAction SilentlyContinue).ProcessName
    [void][NsW.Win2]::ShowWindow($wt, 9)
    $ok = [NsW.Win2]::MoveWindow($wt, $x, $y, $w, $r, $true)
    [void][NsW.Win2]::GetWindowRect($wt, [ref]$rc)
    Log-Move ("{0}: MoveWindow={1} -> {2},{3} {4}x{5}; тепер {6},{7}-{8},{9}" -f $pn, $ok, $x, $y, $w, $r, $rc.L, $rc.T, $rc.R, $rc.B)
    return $ok
}


# ------------------------------------------------ корінець із великими проколами (21.09.2026)
# Річник 2002 зшивали інакше: на корінці ряд дрібних проколів (1-3 мм від краю)
# і по два ВЕЛИКІ (~5 мм у діаметрі) на 5-11,5 мм углиб (2319: p01/03/05/07/09
# зліва, p02/04/08 справа; аркуш смуг NS_WORK\edgesheet9.png), а текст біля
# корінця починається з 18-20 мм. Тож на КОРІНЦЕВОМУ боці ріжемо 13 мм, і плями
# до 12,5 мм вважаємо проколами (перша спроба 12/11 лишала великі на стор. 1, 2, 7). Корінець: непарна сторінка — ліворуч, парна — праворуч
# (так лягли проколи на всіх сторінках 2319). Повернутих сторінок не стосується.
$script:NS_SPINE_RULES = @{
    # FillHoles = $true: дірки латаються папером (Repair-NsHoles), тож глибокий
    # зріз не потрібен — корінець ріжеться як звичайний бік, 8 мм, і поля
    # виходять симетричні (рішення оператора 23.09.2026, варіант A).
    # FillHoles тепер ВИМКНЕНО за умовчанням (23.09.2026): заповнення двічі
    # зіпсувало друк (2318 — календар, підвали). Вмикається лише для номера,
    # де оператор подивився й дозволив: ns-prep.ps1 -FillHoles (пишеться в
    # маніфест як fill_holes). Глибини зрізу правило дає завжди.
    # BigMinMm (24.09.2026, рішення оператора): заростають лише плями, більші
    # за цю межу, — великі дірки від зшивача (~7,6 x 6,5 мм). Дрібні від нитки
    # (до 2,9 мм, углиб до 5,7 мм) ріже page_edge корінця 6 мм (рішення
    # оператора 24.09.2026). Велика дірка шукається ЗА лінією зрізу, і там від
    # неї лишається 4,2-6,1 мм уздовж краю (2318, усі сторінки) — тому межа 4:
    # посередині між 2,9 і 4,5. З межею 5 на 2318/10 лишилася дірка 4,2x4,5.
    2002 = @{ CleanMm = 8.0; HoleMaxMm = 12.5; FillHoles = $false; ZoneMm = 16.0; BigMinMm = 4.0 }
}

function Get-NsSpineRule {
    <#  Повертає @{ Side; CleanMm; HoleMaxMm } або $null.                    #>
    param([int]$Year, [int]$PageNo, [int]$Rotate = 0)
    if (-not $script:NS_SPINE_RULES.ContainsKey($Year)) { return $null }
    $r = $script:NS_SPINE_RULES[$Year]
    $side = if ($PageNo % 2 -eq 1) { "Left" } else { "Right" }
    # Сторінку вже повернуто (вкладка надрукована впоперек) — корінець разом із
    # нею переїхав на інший край. Без цього правило вимикалося, і на вкладках
    # лишалися дірки (2323, «Світанок»; 23.09.2026). -rotate 90 = за годинником.
    if ($Rotate -ne 0) {
        $map = @{
            90  = @{ Left = "Top";    Right = "Bottom" }
            180 = @{ Left = "Right";  Right = "Left"   }
            270 = @{ Left = "Bottom"; Right = "Top"    }
        }
        $m = $map[[int]$Rotate]
        if (-not $m) { return $null }
        $side = $m[$side]
    }
    @{ Side = $side; CleanMm = $r.CleanMm; HoleMaxMm = $r.HoleMaxMm
       FillHoles = [bool]$r.FillHoles; ZoneMm = $(if ($r.ZoneMm) { [double]$r.ZoneMm } else { 16.0 })
       BigMinMm = $(if ($r.BigMinMm) { [double]$r.BigMinMm } else { 0.0 }) }
}


function Repair-NsHoles {
    <#  Заповнити великі проколи від зшивача ТОНОМ ПАПЕРУ цієї ж сторінки.
        ⚠︎ 23.09.2026 переписано. Перша версія брала латку з тієї самої смуги
        краю, зсунутої вздовж нього. На 2319 (чисте поле) це виглядало добре,
        але на 2318 смуга краю містить друк — і латка ПЕРЕНЕСЛА його: у
        календарі зникла «С» у «Січні» та «К» у «Квітні», з'явилися зайві цифри,
        біля ікони на стор. 9 подвоївся візерунок. Обробка міняла ЗМІСТ сторінки,
        і оператор це побачив. Копіювання скасовано назавжди.
        З 23.09.2026 заростають і ДРІБНІ проколи від нитки (від 1,5 мм) —
        пропозиція оператора: краще затягнути дірки, ніж різати весь край
        сторінки. Тоді бічний зріз потрібен лише на темну смугу краю.
        Тепер: пляма заростає (FSR) тим, що межує з нею
        (щоб не було пласкої латки), і лише якщо НАВКОЛО НЕЇ ЧИСТИЙ ПАПІР —
        кільце ~4 мм довкола не має темного. Пляма біля друку, рамки чи
        календарної сітки лишається як є: краще дірка, ніж стертий друк.
        ⚠︎ 24.09.2026, рішення оператора: заростання ВСІХ проколів підряд
        скасовано як невдале. Дрібні дірочки від нитки (1,8-2,8 мм на 0-3 мм
        углиб) ЗРІЗАЄ page_edge; заростають лише ВЕЛИКІ дірки від зшивача
        (~7,6 x 6,5 мм на 2,9-10,5 мм). Межу між ними дає -BigMinMm (з
        NS_SPINE_RULES). Пошук півдірок на самому краю за профілем глибини
        (дав 4 плями з ~15) вимкнено — вмикається -EdgeHoles.
        Журнал кожної плями-кандидата (розмір, глибина від краю, яскравість,
        насиченість, заповнення, найтемніше в кільці, рішення) — у
        <ReportDir>\<ReportName>_log.txt.
        Повертає кількість заповнених плям.                                   #>
    param([string]$Path, [string]$Side, [double]$ZoneMm = 16.0, [int]$Dpi = 400,
          [int]$DarkPct = 62, [double]$MinMm = 1.5, [double]$MaxMm = 12.0,
          [double]$BigMinMm = 0, [switch]$EdgeHoles, [double]$SkipMm = 0, [string]$PaperColor = "",
          [double]$EdgeClearMm = 2.5, [string]$ReportDir = "", [string]$ReportName = "hole")
    $log = @()
    $wh = (& magick identify -ping -format "%w|%h" $Path 2>$null) -split '\|'
    if ($wh.Count -lt 2) { return 0 }
    $W = [int]$wh[0]; $H = [int]$wh[1]
    $px = $Dpi / 25.4
    $zone = [int]($ZoneMm * $px)
    $crop = switch ($Side) {
        "Left"   { "${zone}x$H+0+0" }
        "Right"  { "${zone}x$H+$($W - $zone)+0" }
        "Top"    { "${W}x$zone+0+0" }
        "Bottom" { "${W}x$zone+0+$($H - $zone)" }
    }
    if (-not $crop) { return 0 }
    $T = Join-Path $env:TEMP ("ns_holes_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $T -Force | Out-Null
    try {
        $strip = Join-Path $T "s.tif"
        & magick $Path -alpha off -crop $crop +repage $strip 2>$null
        if (-not (Test-Path $strip)) { return 0 }
        $sw = [int](& magick identify -format "%w" $strip 2>$null)
        $sh = [int](& magick identify -format "%h" $strip 2>$null)

        # мапа ~1 мм на клітинку — щоб перевірити, чи навколо плями чистий папір
        $mw = [math]::Max(1, [int]($sw / $px)); $mh = [math]::Max(1, [int]($sh / $px))
        $rawMap = Join-Path $T "map.gray"
        & magick $strip -colorspace Gray -resize "${mw}x${mh}!" -depth 8 "gray:$rawMap" 2>$null
        if (-not (Test-Path $rawMap)) { return 0 }
        $mp = [IO.File]::ReadAllBytes($rawMap)
        $sorted = [byte[]]$mp.Clone(); [Array]::Sort($sorted)
        $paperGray = [int]$sorted[[int]($sorted.Length * 0.9)]
        $dirty = $paperGray - 40

        $pc = (& magick $strip -colorspace sRGB -format "%[fx:round(255*maxima.r)] %[fx:round(255*maxima.g)] %[fx:round(255*maxima.b)]" info: 2>$null) -split ' '
        $pm = (& magick $strip -colorspace sRGB -format "%[fx:round(255*mean.r)] %[fx:round(255*mean.g)] %[fx:round(255*mean.b)]" info: 2>$null) -split ' '
        $pr = [int]((([int]$pc[0]) + 2 * ([int]$pm[0])) / 3)
        $pg = [int]((([int]$pc[1]) + 2 * ([int]$pm[1])) / 3)
        $pb = [int]((([int]$pc[2]) + 2 * ([int]$pm[2])) / 3)

        # СМУГА ПІД ЗРІЗ (-SkipMm, 24.09.2026): те, що однаково відріжеться
        # (page_edge корінця), заливаємо папером ДО пошуку плям. Інакше великі
        # дірки злипаються з проколами від нитки й темним краєм у довгі плями
        # і не проходять за розміром (2318: 9 із 20). Після заливки від великої
        # дірки лишається її частина за лінією зрізу — окрема кругла пляма;
        # а FSR бере для неї папір, а не темряву з-під зрізу.
        Copy-Item $strip (Join-Path $T "orig.tif") -Force     # для аркушів «як є» — до заливки
        if ($SkipMm -gt 0) {
            # ⚠︎ колір заливки — ПАПІР НОМЕРА з ns-prep: оцінка (макс + 2*середнє)/3
            # з цієї смуги виходила темнішою за папір, і FSR тягнув її в дірку
            # сірою латкою (2318/9, 10; 24.09.2026)
            if ($PaperColor -match 'rgb\((\d+),(\d+),(\d+)\)') { $pr = [int]$Matches[1]; $pg = [int]$Matches[2]; $pb = [int]$Matches[3] }
            $sk = [int]($SkipMm * $px)
            $skRect = switch ($Side) {
                "Left"   { "rectangle 0,0 $sk,$sh" }
                "Right"  { "rectangle $($sw - $sk),0 $sw,$sh" }
                "Top"    { "rectangle 0,0 $sw,$sk" }
                "Bottom" { "rectangle 0,$($sh - $sk) $sw,$sh" }
            }
            # ⚠︎ -alpha off обов'язково: -draw додає альфа-канал, плями виходять
            # graya(...) і розбір connected-components мовчки не бачить жодної
            & magick $strip -fill "rgb($pr,$pg,$pb)" -stroke none -draw $skRect -alpha off -compress LZW "$T\s2.tif" 2>$null
            if (Test-Path "$T\s2.tif") { Move-Item "$T\s2.tif" $strip -Force }
            $EdgeClearMm = [math]::Max($EdgeClearMm, $SkipMm)
        }

        # ⚠︎ Поріг «темного» — ВІДНОСНИЙ до паперу цієї смуги (папір - 90), а не
        # сталі 62 %: 23.09.2026 на 2318/3 папір біля краю 227, а сталий поріг
        # 158 злипав дірки зі смугою обрізу в області до 37 мм завдовжки, і
        # жодна не проходила за розміром. Зі своїм порогом дрібні проколи
        # виходять окремо (2,4-2,6 мм), великі — 9,5x6 мм разом зі смугою.
        $thrHole = [math]::Max(40, $paperGray - 90)
        $thrArg = "{0:N4}%" -f (100.0 * $thrHole / 255)
        if ($SkipMm -gt 0) {
            # РЕЖИМ ЛІНІЇ ЗРІЗУ (24.09.2026): дірка — це кришка сканера, тобто
            # темне Й БЕЗБАРВНЕ. На 2318/5-6 велика дірка злипалася з червоною
            # плашкою «Квітня» (пляма 10x21 мм); з умовою «безбарвне» плашка
            # відпадає, і на 2318/5 лишаються рівно дві дірки 4,4x5,5 мм.
            # ⚠︎ «безбарвне» міряється ХРОМОЮ (макс - мін каналів, HCL), а не
            # насиченістю HSL: у темних пікселях HSL-насиченість шумна, і частина
            # дірки (центр, край) ішла в «кольоровий друк» — лишалися чорні цятки
            # й серпики (перша спроба 24.09.2026)
            & magick $strip `( +clone -colorspace Gray -threshold $thrArg -negate `) `
                     `( -clone 0 -colorspace HCL -channel G -separate +channel -threshold 12% -negate `) `
                     -delete 0 -compose Multiply -composite -alpha off "$T\dark.png" 2>$null
            # кольоровий друк (хрома > 20 % і темніше за папір) — вилучається з маски
            & magick $strip `( +clone -colorspace Gray -threshold ("{0:N4}%" -f (100.0 * ($paperGray - 30) / 255)) -negate `) `
                     `( -clone 0 -colorspace HCL -channel G -separate +channel -threshold 20% `) `
                     -delete 0 -compose Multiply -composite -alpha off "$T\color.png" 2>$null
            & magick "$T\dark.png" -morphology Close Disk:3 "$T\d.png" 2>$null
        } else {
            & magick $strip -colorspace Gray -threshold $thrArg -negate `
                     -morphology Close Disk:3 "$T\d.png" 2>$null
        }
        $cc = & magick "$T\d.png" -define connected-components:verbose=true `
                       -define connected-components:area-threshold=300 -connected-components 8 null: 2>$null
        $draw = @(); $n = 0; $spots = @(); $blobMasks = @()
        foreach ($ln in $cc) {
            if ($ln -notmatch '^\s*(?<id>\d+):\s+(\d+)x(\d+)\+(\d+)\+(\d+)\s+[\d.]+,[\d.]+\s+(\d+)\s+(?:gray|srgb)\((255|100%|65535)') { continue }
            $ccId = [int]$Matches['id']
            $bw = [int]$Matches[1]; $bh = [int]$Matches[2]; $bx = [int]$Matches[3]; $by = [int]$Matches[4]
            $fillRatio = [int]$Matches[5] / [double]($bw * $bh)
            $mmW = $bw / $px; $mmH = $bh / $px
            # ⚠︎ 23.09.2026: заповнювач стер букву «К» у «Квітні» (2318/5) —
            # заголовок набрано з широкими проміжками, тож «навколо чистий папір»
            # пройшло, а буква кругла й темна. Тепер проколом вважається лише
            # ТЕМНА (кришка сканера, яскравість < 70), НЕКОЛЬОРОВА (насиченість
            # < 0,12) і КРУГЛА (заповнення габариту >= 0,7) пляма. Друкована
            # літера — сіра або кольорова фарба на папері — цього не проходить.
            # глибина плями від краю аркуша (мм): ближчий і дальший край габариту
            $dNear = switch ($Side) { "Left" { $bx } "Right" { $sw - $bx - $bw } "Top" { $by } "Bottom" { $sh - $by - $bh } }
            $dFar  = switch ($Side) { "Left" { $bx + $bw } "Right" { $sw - $bx } "Top" { $by + $bh } "Bottom" { $sh - $by } }
            $along = switch ($Side) { { $_ -in "Left","Right" } { ($by + $bh / 2) / $px } default { ($bx + $bw / 2) / $px } }
            $desc = "{0,6:N1} мм уздовж  {1,4:N1}x{2,-4:N1} мм  глиб. {3,4:N1}-{4,-4:N1}  запов. {5:N2}" -f `
                    $along, $mmW, $mmH, ($dNear / $px), ($dFar / $px), $fillRatio
            if ($mmW -lt $MinMm -or $mmW -gt $MaxMm -or $mmH -lt $MinMm -or $mmH -gt $MaxMm) {
                if ($mmW -ge $MinMm -or $mmH -ge $MinMm) { $log += "$desc  -> лишено: розмір" }
                continue
            }
            # форму (заповнення) перевіряємо ПІСЛЯ вимірів, щоб у журналі були
            # яскравість і кільце й для великих плям, які не пройшли за формою
            if ($BigMinMm -gt 0 -and [math]::Max($mmW, $mmH) -lt $BigMinMm) {
                $log += "$desc  -> дрібний (< $BigMinMm мм): не заростає"
                continue
            }
            $blobStat = (& magick $strip -crop "${bw}x${bh}+${bx}+${by}" +repage -colorspace HSL `
                          -format "%[fx:round(255*mean.b)] %[fx:round(100*mean.g)]" info: 2>$null) -split ' '
            if ($blobStat.Count -lt 2) { continue }
            $desc += "  яскр. {0,3} нас. {1,2}" -f $blobStat[0], $blobStat[1]
            # ⚠︎ межа яскравості 100, не 70: кришку підсвічує лампа, і справжні
            # проколи на 2318/8 мають 74 і 82 (23.09.2026 — з межею 70 не
            # заповнювалося нічого). Літеру це не пропускає: її відсіює форма
            # (заповнення габариту >= 0,7) і чистий папір навколо.
            # 25.09.2026: межа 100 -> 112. Виміряно на 5 номерах 2002 р. (2318-2321, 2323; 96 плям на позиціях зшивача
            # 165-175 і 245-255 мм): яскравість справжніх дірок 59-107 (медіана 80); 94 із 96 заросли, дві лишились саме через 107 і 104
            # (2321/3, 4 — лампа підсвічує кришку сильніше). Найближча пляма НЕ на позиції зшивача — 105 (2323/7, вкладка,
            # заповнення не застосовується) і 128, 130, 132 далі. 112 = запас 5 над 107 і 16 до 128.
            if ([int]$blobStat[0] -gt 112 -or [int]$blobStat[1] -gt 12) { $log += "$desc  -> лишено: не темна/кольорова"; continue }
            $x0 = [int]($bx / $px); $y0 = [int]($by / $px)
            $x1 = [int](($bx + $bw) / $px); $y1 = [int](($by + $bh) / $px)
            $clean = $true; $ringMin = 255
            # смугу самого краю в перевірці кільця не рахуємо: вона темна завжди
            # і через неї «брудним» виглядало оточення кожної дірки біля краю
            $clrCells = [int]$EdgeClearMm + 1
            for ($y = $y0 - 4; $y -le $y1 + 4; $y++) {
                for ($x = $x0 - 4; $x -le $x1 + 4; $x++) {
                    if ($y -lt 0 -or $x -lt 0 -or $y -ge $mh -or $x -ge $mw) { continue }
                    if ($x -ge $x0 - 1 -and $x -le $x1 + 1 -and $y -ge $y0 - 1 -and $y -le $y1 + 1) { continue }
                    if ($Side -eq "Left"   -and $x -lt $clrCells) { continue }
                    if ($Side -eq "Right"  -and $x -ge $mw - $clrCells) { continue }
                    if ($Side -eq "Top"    -and $y -lt $clrCells) { continue }
                    if ($Side -eq "Bottom" -and $y -ge $mh - $clrCells) { continue }
                    $v = $mp[$y * $mw + $x]
                    if ($v -lt $ringMin) { $ringMin = $v }
                    if ($v -lt $dirty) { $clean = $false }
                }
            }
            $desc += "  кільце мін {0} (поріг {1})" -f $ringMin, $dirty
            if ($fillRatio -lt 0.6) { $log += "$desc  -> лишено: форма (заповнення < 0,6)"; continue }
            # Пляма впирається в лінію зрізу — це залишок великої дірки: дрібні
            # проколи від нитки (до 5,7 мм углиб) лежать цілком під зрізом 6 мм.
            # Чистого кільця тут НЕ вимагаємо (2318/5, 8: дірка за 1-3 мм від
            # друку), зате маска — САМА ПЛЯМА (+0,5 мм), без кольорового друку й
            # без жодної іншої темної плями. Друк поза плямою не змінюється.
            $atCut = $SkipMm -gt 0 -and ($dNear / $px) -le $SkipMm + 0.5
            if ($atCut) {
                $km = Join-Path $T "k$ccId.png"
                & magick "$T\d.png" -define connected-components:keep-ids=$ccId -define connected-components:mean-color=true `
                         -define connected-components:area-threshold=300 -connected-components 8 -alpha off "$T\k0.png" 2>$null
                # інші темні плями = усе темне мінус ця пляма
                & magick "$T\dark.png" "$T\k0.png" -compose MinusSrc -composite -alpha off "$T\oth.png" 2>$null
                # Close заповнює світліші цятки всередині дірки; Dilate 0,8 мм —
                # як відступ старої прямокутної маски (тінь краю дірки)
                & magick "$T\k0.png" -morphology Close Disk:6 -morphology Dilate Disk:13 `
                         `( "$T\oth.png" "$T\color.png" -compose Lighten -composite -morphology Dilate Disk:2 -negate `) `
                         -compose Multiply -composite -alpha off $km 2>$null
                if (-not (Test-Path $km)) { $log += "$desc  -> лишено: маска не вийшла"; continue }
                $log += "$desc  -> ЗАРОЩЕНО (на лінії зрізу, маска — пляма)" + $(if (-not $clean) { " — друк поруч, не зачеплено" } else { "" })
                $blobMasks += $km
                $spots += ,@($bw, $bh, $bx, $by)
                $n++
                continue
            }
            if (-not $clean) { $log += "$desc  -> ЛИШЕНО: біля друку"; continue }
            $log += "$desc  -> ЗАРОЩЕНО"
            # дірка впритул до краю: маска має діставати самого краю, інакше
            # від неї лишається темний серпик (2318, 23.09.2026)
            $pad = [int](0.8 * $px)
            $x1m = $bx - $pad; $x2m = $bx + $bw + $pad
            $y1m = $by - $pad; $y2m = $by + $bh + $pad
            if ($Side -eq "Left"   -and $x1m -lt 2 * $px) { $x1m = -5 }
            if ($Side -eq "Right"  -and $x2m -gt $sw - 2 * $px) { $x2m = $sw + 5 }
            if ($Side -eq "Top"    -and $y1m -lt 2 * $px) { $y1m = -5 }
            if ($Side -eq "Bottom" -and $y2m -gt $sh - 2 * $px) { $y2m = $sh + 5 }
            $draw += @("-draw", ("roundrectangle {0},{1} {2},{3} {4},{4}" -f [int]$x1m, [int]$y1m, [int]$x2m, [int]$y2m, [int](0.6 * $px)))
            $spots += ,@($bw, $bh, $bx, $by)
            $n++
        }
        # ДІРКИ НА САМОМУ КРАЮ: вони зливаються зі смугою обрізу, і як окрема
        # кругла пляма не розпізнаються (2318/3: після заростання лишалося 15
        # півдірок рівно на краю аркуша). Тому окремо міряємо глибину темної
        # смуги в кожному рядку вздовж краю: де вона раптом глибша за звичайну
        # (медіана + 1,5 мм) — там дірка, і ми беремо її від самого краю.
        $prof = Join-Path $T "edgeprof.gray"
        $rowsN =[math]::Min(2200, [int]($(if ($Side -eq "Left" -or $Side -eq "Right") { $sh } else { $sw }) / 3))
        $rot = switch ($Side) { "Left" { "0" } "Right" { "180" } "Top" { "90" } "Bottom" { "-90" } }
        # 24.09.2026: вимкнено за умовчанням (див. опис) — лише з -EdgeHoles
        if ($EdgeHoles) { & magick $strip -colorspace Gray -rotate $rot -resize ("40x{0}!" -f $rowsN) -depth 8 "gray:$prof" 2>$null }
        if ($EdgeHoles -and (Test-Path $prof)) {
            $pb = [IO.File]::ReadAllBytes($prof)
            $depth = New-Object 'double[]' $rowsN
            $zoneMmPerCell = $ZoneMm / 40.0
            for ($r = 0; $r -lt $rowsN; $r++) {
                $d = 0.0
                for ($c = 0; $c -lt 40; $c++) { if ($pb[$r * 40 + $c] -lt $thrHole) { $d = ($c + 1) * $zoneMmPerCell } else { break } }
                $depth[$r] = $d
            }
            $srt = @($depth | Sort-Object)
            $med = $srt[[int]($rowsN / 2)]
            $lim = $med + 1.5
            $mmPerRow = $(if ($Side -eq "Left" -or $Side -eq "Right") { $sh } else { $sw }) / $px / $rowsN
            $r = 0
            while ($r -lt $rowsN) {
                if ($depth[$r] -le $lim) { $r++; continue }
                $r0 = $r
                while ($r -lt $rowsN -and $depth[$r] -gt $lim) { $r++ }
                $lenMm = ($r - $r0) * $mmPerRow
                $maxD = 0.0; for ($q = $r0; $q -lt $r; $q++) { if ($depth[$q] -gt $maxD) { $maxD = $depth[$q] } }
                # прокол на краю: смуга 1,5-10 мм уздовж краю і не глибша за 12 мм
                if ($lenMm -lt 1.5 -or $lenMm -gt 10 -or $maxD -gt 12) { continue }
                $a0 = [int](($r0 - 1) * $mmPerRow * $px); $a1 = [int](($r + 1) * $mmPerRow * $px)
                $dd = [int](($maxD + 1.0) * $px)
                $rect = switch ($Side) {
                    "Left"   { "roundrectangle -5,$a0 $dd,$a1 8,8" }
                    "Right"  { "roundrectangle $($sw - $dd),$a0 $($sw + 5),$a1 8,8" }
                    "Top"    { "roundrectangle $a0,-5 $a1,$dd 8,8" }
                    "Bottom" { "roundrectangle $a0,$($sh - $dd) $a1,$($sh + 5) 8,8" }
                }
                $draw += @("-draw", $rect)
                $spots += ,@([int](2 * $px), [int](2 * $px), [int]$(if ($Side -eq "Right") { $sw - $dd } else { 0 }), $a0)
                $n++
            }
        }

        if ($n -eq 0) { return 0 }
        # ЗАРОСТАННЯ (FSR, ns-inpaint.py): дірка заповнюється тим, що межує з
        # нею, — продовжується тон, градієнт і навіть растр колонки. Пласка
        # заливка тоном паперу лишалася помітною плямою (порівняння методів
        # 23.09.2026: telea/ns розмазують межу, fsr її тримає).
        & magick -size "${sw}x${sh}" xc:black -fill white @draw -alpha off -colorspace Gray "$T\m.png" 2>$null
        foreach ($km in $blobMasks) {
            & magick "$T\m.png" $km -compose Lighten -composite -alpha off -colorspace Gray "$T\m2.png" 2>$null
            if (Test-Path "$T\m2.png") { Move-Item "$T\m2.png" "$T\m.png" -Force }
        }
        $log += "маска: {0} пікс." -f [int](& magick "$T\m.png" -format "%[fx:round(mean*w*h)]" info: 2>$null)
        $before = Join-Path $T "before.png"
        Copy-Item (Join-Path $T "orig.tif") $before -Force
        $fixed = Join-Path $T "fixed.png"
        # auto (24.09.2026, оператор): дірка в папері — тоном і зерном паперу
        # довкола неї; у плашці чи орнаменті (паперу в кільці < 60 %) — fsr
        $ipOut = & python (Join-Path $PSScriptRoot "ns-inpaint.py") $strip "$T\m.png" $fixed "auto" 10 2>$null
        $log += "inpaint: " + (@($ipOut) -join " ")
        if (-not (Test-Path $fixed)) { return 0 }
        # аркуш «до і після» на кожну заповнену пляму — для перегляду оператором
        if ($ReportDir) {
            New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
            $k = 0
            foreach ($bb in $spots) {
                $k++
                $cx = [int]($bb[2] + $bb[0] / 2); $cy = [int]($bb[3] + $bb[1] / 2)
                $x = [math]::Max(0, $cx - 150); $y = [math]::Max(0, $cy - 150)
                $a = Join-Path $T "a$k.png"; $b2 = Join-Path $T "b$k.png"
                & magick $before -crop "300x300+$x+$y" +repage -gravity north -background white -splice 0x14 -pointsize 12 -annotate +0+0 "як є" $a 2>$null
                & magick $fixed  -crop "300x300+$x+$y" +repage -gravity north -background white -splice 0x14 -pointsize 12 -annotate +0+0 "після" $b2 2>$null
                & magick $a $b2 +append -bordercolor gray -border 1 (Join-Path $ReportDir ("{0}_{1}.png" -f $ReportName, $k)) 2>$null
            }
        }
        $off = ($crop -split '\+')
        & magick $Path $fixed -geometry ("+{0}+{1}" -f $off[1], $off[2]) -composite -compress LZW "$T\page.tif" 2>$null
        if (Test-Path "$T\page.tif") { Move-Item "$T\page.tif" $Path -Force; return $n }
        return 0
    } finally {
        if ($ReportDir) {
            New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
            $hdr = "{0}  бік {1}  плям-кандидатів {2}" -f $ReportName, $Side, $log.Count
            [IO.File]::WriteAllLines((Join-Path $ReportDir "${ReportName}_log.txt"), [string[]](@($hdr) + $log), (New-Object Text.UTF8Encoding $true))
        }
        Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}
