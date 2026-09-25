# Етапи 5–6 — збірка PDF з текстовим шаром і метаданими.
#
#   .\ns-build.ps1 -Seq 2231
#   .\ns-build.ps1 -Seq 2231 -PageOrder "1,2,3,4,8,6,7,5"
#   .\ns-build.ps1 -Seq 2231 -NoOcr        швидко, без текстового шару
#
# Вхід : C:\NS_WORK\<номер>\render\pNN.jpg
# Вихід: C:\NS_PDF\<рік>\<номер>.pdf   + текст OCR у NS_WORK\<номер>\ocr.txt
#
# Порядок сторінок у PDF може відрізнятися від порядку сканування: календарні
# та інші вкладки часто вшиті поза порядком читання. -PageOrder записується в
# маніфест номера, тож задається один раз і діє на всі подальші перезбірки —
# це властивість номера, а не команди. Майстри й їхні імена НІКОЛИ не
# переставляються: вони лишаються в порядку сканування.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [string]$PageOrder,
    [switch]$NoOcr,
    [switch]$Force,
    [ValidateSet("pdfa", "pdf")][string]$PdfType = "pdfa"
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$needTools = if ($NoOcr) { "scan" } else { "ocr" }
if (-not (Test-NsTools -Need $needTools)) { Write-Host "Бракує інструментів." -ForegroundColor Red; exit 1 }

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено в каталозі." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir

$render = Join-Path (Join-Path $script:NS_WORK "$Seq") "render"
$jpgs = @(Get-ChildItem -Path $render -Filter "p*.jpg" -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($jpgs.Count -eq 0) { Write-Host "Немає етапу render для $Seq. Спершу ns-render.ps1." -ForegroundColor Red; exit 1 }

# --- порядок сторінок ------------------------------------------------------
if ($PageOrder) {
    $order = @($PageOrder -split ',' | ForEach-Object { [int]$_.Trim() })
    if ($order.Count -ne $jpgs.Count -or
        (($order | Sort-Object) -join ',') -ne ((1..$jpgs.Count) -join ',')) {
        Write-Host "-PageOrder має містити кожне число з 1..$($jpgs.Count) рівно раз." -ForegroundColor Red
        exit 1
    }
    # запам'ятовуємо в маніфесті, щоб не задавати щоразу
    $man | Add-Member -NotePropertyName page_order -NotePropertyValue $PageOrder -Force
    Write-NsManifest -IssueDir $issueDir -Manifest $man
    Write-Host "Порядок сторінок записано в маніфест: $PageOrder" -ForegroundColor Yellow
} elseif ($man.PSObject.Properties.Name -contains 'page_order' -and $man.page_order) {
    $order = @($man.page_order -split ',' | ForEach-Object { [int]$_.Trim() })
    Write-Host "Порядок сторінок з маніфеста: $($man.page_order)" -ForegroundColor Yellow
} else {
    $order = @(1..$jpgs.Count)
}
$ordered = @($order | ForEach-Object { $jpgs[$_ - 1] })

$outDir = Join-Path $script:NS_PDF "$($man.year)"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$name = if ($man.seq_last -ne $man.seq_first) { "$($man.seq_first)-$($man.seq_last)" } else { "$($man.seq_first)" }
$out = Join-Path $outDir "$name.pdf"

if ((Test-Path $out) -and -not $Force) {
    Write-Host "$out вже існує. -Force, щоб перебудувати." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Етапи 5-6: номер $name, $($ordered.Count) сторінок" -ForegroundColor Cyan

# --- PDF лише із зображень -------------------------------------------------
$tmp = Join-Path $env:TEMP ("ns_build_" + $Seq)
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$imgPdf = Join-Path $tmp "images.pdf"

# img2pdf вкладає готовий потік JPEG у PDF як є, без перекодування, і бере
# розмір сторінки з роздільності зображення. ImageMagick на запис у PDF стискав
# би JPEG удруге — втрати на порожньому місці. img2pdf приходить залежністю
# ocrmypdf, тож окремо ставити нічого не треба; magick лишається запасним
# шляхом на випадок його відсутності.
$viaImg2pdf = $false
$null = & python -c "import img2pdf" 2>&1
if ($LASTEXITCODE -eq 0) {
    & python -m img2pdf --output $imgPdf @($ordered.FullName) 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $viaImg2pdf = Test-Path $imgPdf
}
if (-not $viaImg2pdf) {
    Write-Host "  img2pdf недоступний — збираю через ImageMagick (з повторним стисненням)." -ForegroundColor Yellow
    & magick @($ordered.FullName) $imgPdf 2>$null | Out-Null
}
if (-not (Test-Path $imgPdf)) { Write-Host "Не вдалося зібрати PDF із зображень." -ForegroundColor Red; exit 1 }

$srcMb = (@($ordered) | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ("  зображення зібрано: {0:N1} МБ (з {1:N1} МБ JPEG){2}" -f `
            ((Get-Item $imgPdf).Length / 1MB), $srcMb, $(if ($viaImg2pdf) { ", без перекодування" } else { "" }))

# --- текстовий шар ---------------------------------------------------------
$title = "$($script:TITLE), № $($man.issue_no_in_year) ($($man.date))"

if ($NoOcr) {
    Copy-Item $imgPdf $out -Force
} else {
    Initialize-NsOcrEnv
    $sidecar = Get-NsOcrPath -IssueDir $issueDir

    # --- розпізнаємо СІРИЙ переклад, а віддаємо кольорове -------------------
    # Tesseract помітно краще читає сірий переклад сторінки, ніж кольорове
    # зображення. Виміряно на стор. 1 номера 2225 — блакитні заголовки:
    #     «Зустріч президентів держав Центральної і Східної Європи»
    #     «Енджіоси» в боротьбі з «Матріксом»
    #     «Засідання Головної управи ОУП»
    # у кольоровому варіанті не розпізнаються ЗОВСІМ, у сірому — усі.
    # Порогові режими самого ocrmypdf (--tesseract-thresholding
    # otsu / adaptive-otsu / sauvola) дають лише часткове й непослідовне
    # покращення, тому вони тут не рятують.
    # Плашки (світлий текст на темній заливці) у сірій копії інвертуються —
    # див. New-NsOcrGray у ns-lib (18.09.2026, 2266/4: 2 -> 8 з 8 контрольних слів).
    Write-Host "  сірі копії для OCR (плашки інвертуються)..." -ForegroundColor DarkGray
    $grayList = @()
    $invNotes = @()
    $penNotes = @()
    foreach ($j in $ordered) {
        $g = Join-Path $tmp ($j.BaseName + "_gray.png")
        $cov = New-NsOcrGray -Src $j.FullName -Out $g
        if (-not (Test-Path $g)) { Write-Host "  ЗБІЙ на $($j.Name)" -ForegroundColor Red; exit 1 }
        if ($cov -gt 0) { $invNotes += ("{0} {1} %" -f $j.BaseName, $cov) }
        if ($script:NS_LAST_PEN) { $penNotes += ("{0} {1}" -f $j.BaseName, $script:NS_LAST_PEN) }
        $grayList += $g
    }
    if ($invNotes.Count) { Write-Host ("    інвертовано плашки: " + ($invNotes -join ", ")) -ForegroundColor DarkGray }
    if ($penNotes.Count) { Write-Host ("    погашено червону ручку в OCR-копії: " + ($penNotes -join ", ")) -ForegroundColor DarkGray }
    $listFile = Join-Path $tmp "pages.txt"
    [IO.File]::WriteAllLines($listFile, $grayList, [Text.UTF8Encoding]::new($false))

    # `-c textonly_pdf=1` дає PDF із самим лише невидимим текстом, без
    # зображення. Список файлів на вході — один виклик на весь номер.
    # thresholding_method=2 - локальний поріг Sauvola замість глобального Otsu.
    # Otsu рахує поріг НА ВСЮ СТОРІНКУ, де переважає білий папір із чорним
    # текстом, тому кольорова плашка нової верстки стає суцільно чорною й текст
    # у ній тоне. Справа не в кольорі: на вирізаній окремо плашці той самий
    # Otsu читає її без проблем.
    # Заміряно на 2254: з 11 рядків плашок Otsu знаходив 7, Sauvola - 10;
    # слів усього 20676 проти 19666. На старій верстці не гірше: 2225 ті самі
    # 6148 слів при 0,57 % підозрілих замість 0,62 %.
    $textBase = Join-Path $tmp "textlayer"
    Write-Host "  OCR (ukr+pol) на $($grayList.Count) сторінках..." -ForegroundColor DarkGray
    & $script:TESSERACT $listFile $textBase --tessdata-dir $script:TESSDATA `
                        -l ukr+pol -c thresholding_method=2 -c textonly_pdf=1 pdf txt 2>$null | Out-Null
    if (-not (Test-Path "$textBase.pdf")) {
        Write-Host "Tesseract не видав текстовий шар." -ForegroundColor Red
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    if (Test-Path "$textBase.txt") { Copy-Item "$textBase.txt" $sidecar -Force }

    $merged = Join-Path $tmp "merged.pdf"
    & python "$PSScriptRoot\ns-textlayer.py" $imgPdf "$textBase.pdf" $merged 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if (-not (Test-Path $merged)) {
        Write-Host "Не вдалося накласти текстовий шар." -ForegroundColor Red
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # ocrmypdf тепер лише переводить у PDF/A і проставляє метадані:
    # --skip-text каже не чіпати сторінки, де текст уже є, тобто всі.
    $ocrArgs = @(
        "-m", "ocrmypdf",
        "--skip-text",
        "--output-type", $PdfType,
        "--optimize", "0",
        "--title", $title,
        "--author", $script:PUBLISHER,
        "--subject", "$($script:TITLE) $($man.year), № $($man.issue_no_in_year), наскрізний $name",
        "--keywords", "ISSN $($script:ISSN); $($man.date)",
        "--quiet",
        $merged, $out
    )
    Write-Host "  PDF/A і метадані..." -ForegroundColor DarkGray
    & python @ocrArgs 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if (-not (Test-Path $out)) {
        Write-Host "ocrmypdf не видав файл." -ForegroundColor Red
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# --- запис у каталог -------------------------------------------------------
$mb   = (Get-Item $out).Length / 1MB
$hash = Get-NsHash $out
$man | Add-Member -NotePropertyName pdf      -NotePropertyValue "$($man.year)/$name.pdf" -Force
$man | Add-Member -NotePropertyName pdf_sha256 -NotePropertyValue $hash -Force
$man | Add-Member -NotePropertyName pdf_built -NotePropertyValue (Get-Date).ToString("s") -Force
$man.status = "delivered"
Write-NsManifest -IssueDir $issueDir -Manifest $man
Set-NsRegistryRow -Manifest $man -Status "delivered" `
                  -Bytes (@($man.pages) | Measure-Object -Property bytes -Sum).Sum

Write-Host ""
$perPage = $mb / [math]::Max(1, @($ordered).Count)
Write-Host ("Готово: {0}  ({1:N1} МБ, {2:N2} МБ/стор.)" -f $out, $mb, $perPage) -ForegroundColor Green
if ($perPage -lt $script:PDF_MB_PER_PAGE_MIN -or $perPage -gt $script:PDF_MB_PER_PAGE_MAX) {
    Write-Host ("  УВАГА: {0:N2} МБ/стор. поза орієнтиром архіву {1}-{2}." -f `
                $perPage, $script:PDF_MB_PER_PAGE_MIN, $script:PDF_MB_PER_PAGE_MAX) -ForegroundColor Yellow
}
