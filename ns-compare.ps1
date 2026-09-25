# Звірка зібраного номера з еталоном — після переїзду, оновлення ImageMagick,
# Tesseract чи ocrmypdf, або після змін у конвеєрі.
#
#   .\ns-compare.ps1                  номер 2227 проти ns-reference.json
#   .\ns-compare.ps1 -Seq 2254        інший номер, якщо для нього є еталон
#   .\ns-compare.ps1 -Seq 2254 -Save  записати поточні виміри як еталон
#
# Номер має бути вже зібраний (ns-issue.ps1 -Seq N -Force). Скрипт нічого не
# збирає й нічого не змінює, окрім ns-reference.json при -Save.
#
# Допуски — з ПЕРЕЇЗД.md, розд. 8:
#   сторінок, розмір сторінки, QC без зауважень — точно (геометрія від версій
#   не залежить); розмір файлу — 3 %; слова — 50; відтінок паперу — 0,5.
# Слова рахуються Get-NsOcrStats із _ocr.txt, тим самим кодом, що в ns-qc.
# НЕ через pdftotext і не іншим регулярним виразом: \w+ на 2227 дає 20 354
# замість 15 148 — число буде «правильне», але про інше.

param([int]$Seq = 2227, [switch]$Save)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$refPath = Join-Path $PSScriptRoot "ns-reference.json"

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено в каталозі." -ForegroundColor Red; exit 2 }
$man = Read-NsManifest -IssueDir $issueDir

$name = if ($man.seq_last -ne $man.seq_first) { "$($man.seq_first)-$($man.seq_last)" } else { "$($man.seq_first)" }
$pdf = Join-Path (Join-Path $script:NS_PDF "$($man.year)") "$name.pdf"
if (-not (Test-Path $pdf)) { Write-Host "PDF не зібрано: $pdf" -ForegroundColor Red; exit 2 }

$ocr = Get-NsOcrPath -IssueDir $issueDir
if (-not (Test-Path $ocr)) { Write-Host "Немає тексту OCR: $ocr" -ForegroundColor Red; exit 2 }

# ------------------------------------------------------------------ виміри
Write-Host ""
Write-Host "Звірка номера $Seq" -ForegroundColor Cyan

$info = & python -c "import pikepdf,json,sys; p=pikepdf.open(sys.argv[1]); print(json.dumps({'pages':len(p.pages),'sizes':sorted({'%.2fx%.2f' % (float(x.mediabox[2])-float(x.mediabox[0]), float(x.mediabox[3])-float(x.mediabox[1])) for x in p.pages})}))" $pdf 2>$null
if (-not $info) { Write-Host "Не вдалося прочитати PDF через pikepdf." -ForegroundColor Red; exit 2 }
$pi = $info | ConvertFrom-Json

$os = Get-NsOcrStats -Text ([IO.File]::ReadAllText($ocr, [Text.UTF8Encoding]::new($false)))
$cast = Get-NsIssueCast -IssueDir $issueDir -Manifest $man

Write-Host "  запускаю ns-qc..."
& "$PSScriptRoot\ns-qc.ps1" -Seq $Seq | Out-Null
$qcClean = ($LASTEXITCODE -eq 0)

$verMagick = "$((& magick -version 2>$null) | Select-Object -First 1)" -replace '^Version:\s*(ImageMagick\s*)?', '' -replace '\s+https?://.*$', ''
$verTess   = "$((& $script:TESSERACT --version 2>&1) | Select-Object -First 1)"
# ocrmypdf друкує версію в stderr, не в stdout
$verOcr    = "$((& python -m ocrmypdf --version 2>&1) | Select-Object -First 1)"
$versions  = "ImageMagick $verMagick, $verTess, ocrmypdf $verOcr"

$now = [ordered]@{
    source     = "$env:COMPUTERNAME, $((Get-Date).ToString('dd.MM.yyyy'))"
    versions   = $versions
    pages      = [int]$pi.pages
    page_sizes = @($pi.sizes)
    bytes      = [long](Get-Item $pdf).Length
    words      = [int]$os.Words
    suspicious = [int]$os.Suspicious
    cast       = if ($null -ne $cast) { [double]$cast } else { $null }
    qc_clean   = $qcClean
}

# ------------------------------------------------------------ запис еталона
$refs = [ordered]@{}
if (Test-Path $refPath) {
    $obj = [IO.File]::ReadAllText($refPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    foreach ($pr in $obj.PSObject.Properties) { $refs[$pr.Name] = $pr.Value }
}

if ($Save) {
    $refs["$Seq"] = $now
    [IO.File]::WriteAllText($refPath, ($refs | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-Host "  еталон для $Seq записано в ns-reference.json" -ForegroundColor Green
    exit 0
}

if (-not $refs.Contains("$Seq")) {
    Write-Host "Для номера $Seq еталона немає. Записати поточні виміри: -Save" -ForegroundColor Yellow
    exit 2
}
$ref = $refs["$Seq"]

# ------------------------------------------------------------------ звірка
$bad = 0
function Show-Row([string]$What, $Ref, $Cur, [bool]$Ok, [string]$Tol) {
    $mark = if ($Ok) { "ok" } else { "!!" }
    $color = if ($Ok) { "Green" } else { "Yellow" }
    Write-Host ("  {0,-2}  {1,-20} еталон {2,-18} зараз {3,-18} {4}" -f $mark, $What, $Ref, $Cur, $Tol) -ForegroundColor $color
    if (-not $Ok) { $script:bad++ }
}

Write-Host ""
Write-Host "  еталон: $($ref.source)"
Write-Host "          $($ref.versions)"
Write-Host "  зараз:  $($now.source)"
Write-Host "          $($now.versions)"
Write-Host ""

Show-Row "сторінок" $ref.pages $now.pages ($ref.pages -eq $now.pages) "точно"

$rs = (@($ref.page_sizes) | Sort-Object) -join ", "
$cs = (@($now.page_sizes) | Sort-Object) -join ", "
Show-Row "розмір сторінки, pt" $rs $cs ($rs -eq $cs) "точно"

$dBytes = 100.0 * ($now.bytes - $ref.bytes) / $ref.bytes
Show-Row "розмір файлу, байт" $ref.bytes $now.bytes ([math]::Abs($dBytes) -le 3.0) ("{0:+0.00;-0.00} %, допуск 3 %" -f $dBytes)

$dWords = $now.words - $ref.words
Show-Row "слів OCR" $ref.words $now.words ([math]::Abs($dWords) -le 50) ("{0:+0;-0}, допуск 50" -f $dWords)

$refPct = if ($ref.words) { 100.0 * $ref.suspicious / $ref.words } else { 0 }
$curPct = if ($now.words) { 100.0 * $now.suspicious / $now.words } else { 0 }
Show-Row "підозрілих слів" ("{0} ({1:N2} %)" -f $ref.suspicious, $refPct) ("{0} ({1:N2} %)" -f $now.suspicious, $curPct) ($curPct -le 2.0) "поріг QC 2 %"

$castOk = ($null -ne $now.cast) -and ([math]::Abs($now.cast - $ref.cast) -le 0.5)
Show-Row "відтінок B-R" $ref.cast $now.cast $castOk "допуск 0,5"

Show-Row "QC без зауважень" $ref.qc_clean $now.qc_clean ($ref.qc_clean -eq $now.qc_clean) "точно"

Write-Host ""
if ($bad -eq 0) {
    Write-Host "Збігається з еталоном." -ForegroundColor Green
    exit 0
}
Write-Host "Розбіжностей: $bad — зупинитися й розібратися, не продовжувати." -ForegroundColor Yellow
exit 1
