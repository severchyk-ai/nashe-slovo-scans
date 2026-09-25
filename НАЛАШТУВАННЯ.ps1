# Перший запуск на новій машині: встановлення і розкладання проєкту «Наше слово».
#
#   .\НАЛАШТУВАННЯ.ps1              зробити все
#   .\НАЛАШТУВАННЯ.ps1 -Check       лише показати стан, нічого не міняти
#
# Запускати з теки НАШЕ_СЛОВО на флешці, краще від імені адміністратора.

param(
    [switch]$Check,
    [string]$Disk = "C:"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stick = Split-Path -Parent $Root

function Step($n, $t) { Write-Host ""; Write-Host "[$n] $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    ok   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    !    $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "    ЗБІЙ $t" -ForegroundColor Red }

# На чистій Windows `python` у PATH — ярлик магазину, який лише пише «Python was
# not found». Тож «команда існує» нічого не доводить: справжній інтерпретатор
# впізнаємо за відповіддю на --version.
function Find-Python {
    $cands = @(Get-Command python -All -CommandType Application -ErrorAction SilentlyContinue |
               ForEach-Object { $_.Source })
    $cands += @(Get-ChildItem "C:\Python3*\python.exe",
                              "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                              "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | ForEach-Object { $_.FullName })
    foreach ($c in $cands) {
        try {
            $v = (& $c --version 2>&1 | Out-String)
            if ($LASTEXITCODE -eq 0 -and $v -match 'Python 3') { return $c }
        } catch { }
    }
    return $null
}

# Ті самі місця, що й у ns-lib.ps1.
function Find-Naps2 {
    foreach ($c in @("$env:ProgramFiles\NAPS2\NAPS2.Console.exe",
                     "${env:ProgramFiles(x86)}\NAPS2\NAPS2.Console.exe",
                     "$env:LOCALAPPDATA\Microsoft\WindowsApps\NAPS2.Console.exe")) {
        if (Test-Path $c) { return $c }
    }
    $g = Get-Command NAPS2.Console -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

# Щойно встановлене потрапляє в PATH реєстру, але не в PATH цього процесу.
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

Write-Host ""
Write-Host "=== НАШЕ СЛОВО: налаштування нової машини ===" -ForegroundColor Cyan
Write-Host "флешка: $Stick"
Write-Host "диск для даних: $Disk"
if ($Check) { Write-Host "режим: ЛИШЕ ПЕРЕВІРКА, нічого не міняю" -ForegroundColor Yellow }

# ---------- 1. інструменти ----------
Step 1 "Інструменти"
$pkgs = @(
    @{ id = "ImageMagick.ImageMagick";  name = "ImageMagick"; test = { $null -ne (Get-Command magick -ErrorAction SilentlyContinue) } },
    @{ id = "UB-Mannheim.TesseractOCR"; name = "Tesseract";   test = { Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe" } },
    @{ id = "Python.Python.3.14";       name = "Python";      test = { $null -ne (Find-Python) } },
    @{ id = "oschwartz10612.Poppler";   name = "poppler";     test = { $null -ne (Get-Command pdftoppm -ErrorAction SilentlyContinue) } },
    @{ id = "Cyanfish.NAPS2";           name = "NAPS2";       test = { $null -ne (Find-Naps2) } }
)
foreach ($p in $pkgs) {
    if (& $p.test) { Ok "$($p.name) вже є"; continue }
    if ($Check)    { Warn "$($p.name) — БРАКУЄ (winget: $($p.id))"; continue }
    Write-Host "    встановлюю $($p.name)..."
    winget install --id $p.id --exact --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
    Update-SessionPath
    if (& $p.test) { Ok "$($p.name) встановлено" } else { Warn "$($p.name): можливо, треба перезапустити консоль" }
}

# Ghostscript у winget немає через ліцензію
$gs = Get-ChildItem "C:\Program Files\gs\gs*\bin\gswin64c.exe" -ErrorAction SilentlyContinue
if ($gs) {
    Ok "Ghostscript уже є"
} else {
    $instDir = Join-Path $Stick "Інсталятори"
    $inst = Get-ChildItem $instDir -Filter "*.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^gs\d|hostscript' } | Select-Object -First 1
    # Запускати лише файл, звірений з опублікованим хешем. Заголовок MZ цілості
    # не доводить: 16.09.2026 тут лежав обірваний на 40 МіБ інсталятор.
    # Еталон: github.com/ArtifexSoftware/ghostpdl-downloads/releases/tag/gs10071
    $gsKnown = @{ "gs10071w64.exe" = "3a4c28d0aac47aa7cccd35a5932c55110376e9dbd966898dde388b7faba444a4" }
    $instOk = $false
    if ($inst) {
        $want = $gsKnown[$inst.Name]
        $got  = (Get-FileHash $inst.FullName -Algorithm SHA256).Hash.ToLower()
        if (-not $want)       { Bad "$($inst.Name): немає еталонного SHA-256, не запускаю" }
        elseif ($got -ne $want) { Bad "$($inst.Name): SHA-256 не збігається з опублікованим (файл пошкоджений), не запускаю" }
        else                  { $instOk = $true }
    }
    if ($instOk -and -not $Check) {
        Write-Host "    ставлю Ghostscript із флешки: $($inst.Name) (SHA-256 звірено)"
        Start-Process $inst.FullName -ArgumentList "/S" -Wait
        $gs = Get-ChildItem "C:\Program Files\gs\gs*\bin\gswin64c.exe" -ErrorAction SilentlyContinue
    }
    if ($gs) { Ok "Ghostscript встановлено" }
    elseif ($instOk -and $Check) { Warn "Ghostscript — БРАКУЄ (поставлю з флешки: $($inst.Name), SHA-256 звірено)" }
    else { Warn "Ghostscript БРАКУЄ. Завантажити з ghostscript.com/releases/gsdnld.html (Windows 64-bit). Без нього не буде PDF/A." }
}

# ---------- 2. пакунки Python ----------
Step 2 "Пакунки Python: ocrmypdf, img2pdf, pikepdf"
$pyExe = Find-Python
$py = $null
if ($pyExe) { $py = & $pyExe -c "import ocrmypdf, img2pdf, pikepdf; print('ok')" 2>$null }
if ($py -eq "ok")   { Ok "уже встановлені ($pyExe)" }
elseif (-not $pyExe) {
    if ($Check) { Warn "БРАКУЄ — поставлю після Python: pip install ocrmypdf img2pdf" }
    else        { Bad "справжнього Python не знайдено, пакунки не ставлю. Перезапустити консоль і повторити." }
}
elseif ($Check)     { Warn "БРАКУЄ — буде: $pyExe -m pip install ocrmypdf img2pdf" }
else {
    & $pyExe -m pip install --quiet ocrmypdf img2pdf 2>&1 | Out-Null
    $py = & $pyExe -c "import ocrmypdf, img2pdf, pikepdf; print('ok')" 2>$null
    if ($py -eq "ok") { Ok "встановлено ($pyExe)" } else { Bad "не встановилися, глянути вручну" }
}

# ---------- 3. скрипти ----------
Step 3 "Скрипти і документи"
$dst = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Scans"
if ($Check) { Warn "скопіював би Scans -> $dst" }
else {
    robocopy (Join-Path $Root "Scans") $dst /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
    if (Test-Path (Join-Path $dst "ns-lib.ps1")) { Ok "скрипти в $dst" } else { Bad "не скопіювалися" }
}

# ---------- 4. профіль сканера ----------
Step 4 "Профіль сканера NAPS2"
$naps = Join-Path $env:AppData "NAPS2"
if ($Check) { Warn "скопіював би profiles.xml і config.xml -> $naps" }
else {
    New-Item -ItemType Directory -Path $naps -Force | Out-Null
    Copy-Item (Join-Path $Root "NAPS2\*.xml") $naps -Force
    if (Test-Path (Join-Path $naps "profiles.xml")) { Ok "профіль Arhiv400 на місці" } else { Bad "профіль не скопіювався" }
}
Warn "Драйвер сканера ставити ОКРЕМО, до першого сканування: тека Драйвер_сканера"

# ---------- 5. теки даних ----------
Step 5 "Теки даних на $Disk"
foreach ($d in @("NS_MASTERS","NS_WORK","NS_PDF")) {
    $path = Join-Path $Disk $d
    if (Test-Path $path)   { Ok "$path уже є" }
    elseif ($Check)        { Warn "створив би $path" }
    else { New-Item -ItemType Directory -Path $path -Force | Out-Null; Ok "створено $path" }
}
if ($Disk -ne "C:") { Warn "Диск не C: — виправити шляхи в $dst\ns-lib.ps1, рядки 6-8" }

# ---------- 6. дані ----------
Step 6 "Майстри і готові PDF"
$mSrc = Join-Path $Stick "NS_MASTERS"
$pSrc = Join-Path $Stick "NS_PDF"
if (-not (Test-Path $mSrc)) { Warn "на цій флешці немає NS_MASTERS — вони на другій" }
elseif ($Check) { Warn "скопіював би майстри -> $Disk\NS_MASTERS (39 ГБ, це надовго)" }
else {
    Write-Host "    копіюю майстри, це надовго..."
    robocopy $mSrc (Join-Path $Disk "NS_MASTERS") /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /MT:8 /NFL /NDL /NJH /NJS | Out-Null
    Write-Host "    повертаю атрибут «лише для читання»..."
    Get-ChildItem (Join-Path $Disk "NS_MASTERS") -Recurse -Filter *.tif | ForEach-Object { $_.IsReadOnly = $true }
    Ok "майстри на місці"
}
if ((Test-Path $pSrc) -and -not $Check) {
    robocopy $pSrc (Join-Path $Disk "NS_PDF") /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
    Ok "готові PDF скопійовано"
}

# ---------- 7. перевірка ----------
Step 7 "Перевірка цілості каталогу"
if ($Check) { Warn "запустив би ns-verify.ps1" }
else {
    $v = Join-Path $dst "ns-verify.ps1"
    if (Test-Path $v) { & $v } else { Bad "ns-verify.ps1 не знайдено" }
}

# ---------- 8. ярлик ----------
# Окремим кроком, бо 16.09.2026 його забули: скрипти переїхали, а ярлика на
# робочому столі не стало. Створюється завжди заново — так він гарантовано
# веде на ns-menu.ps1 у ЦІЙ теці Scans, а не на шлях зі старої машини.
Step 8 "Ярлик «Наше слово» на робочому столі"
$lnk  = Join-Path ([Environment]::GetFolderPath("Desktop")) "Наше слово.lnk"
$menu = Join-Path $dst "ns-menu.ps1"
# Сама наявність .lnk нічого не доводить: він може вести на стару теку.
# Аргументи в .lnk записані як UTF-16, тож шлях до меню видно в байтах.
# ⚠︎ Рядки стоять із НЕПАРНОГО зсуву: розбір від байта 0 їх не бачить і казав
# «веде не туди» про щойно створений правильний ярлик. Читаємо з обох зсувів.
function Test-Shortcut {
    if (-not (Test-Path -LiteralPath $lnk)) { return $false }
    $b = [IO.File]::ReadAllBytes($lnk)
    $t = [Text.Encoding]::Unicode.GetString($b) + [Text.Encoding]::Unicode.GetString($b, 1, $b.Length - 1)
    return $t.Contains($menu)
}
$lnkOk = Test-Shortcut
if ($Check) {
    if ($lnkOk) { Ok "ярлик є і веде на $menu" }
    elseif (Test-Path -LiteralPath $lnk) { Warn "ярлик є, але веде не на $menu — перестворив би" }
    else { Warn "створив би ярлик: $lnk" }
} else {
    $sc = Join-Path $dst "ns-shortcut.ps1"
    if (Test-Path $sc) {
        & $sc
        $lnkOk = Test-Shortcut
        if ($lnkOk) { Ok "ярлик веде на $menu" } else { Bad "ярлик не створився або веде не туди" }
    } else { Bad "ns-shortcut.ps1 не знайдено в $dst" }
}

Write-Host ""
Write-Host "=== ЩО ДАЛІ ===" -ForegroundColor Cyan
Write-Host "1. Поставити драйвер сканера з теки Драйвер_сканера, підключити сканер."
Write-Host "2. Відкрити NAPS2 і перевірити, що профіль Arhiv400 бачить пристрій."
Write-Host "3. Запустити Claude Code у теці $dst — він прочитає CLAUDE.md і буде в курсі справ."
if (-not $Check) { Write-Host "   Ярлик «Наше слово» на робочому столі вже створено (крок 8)." }
Write-Host "4. Найперше діло: РЕЗЕРВНА КОПІЯ майстрів на другу флешку."
Write-Host ""
