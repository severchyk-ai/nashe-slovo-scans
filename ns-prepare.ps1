# Підготувати номер 2002 року до збирання: замір ниток -> page_edge -> заростання дірок -> render -> PDF без OCR.
#
#   .\ns-prepare.ps1 -Seq 2320
#   .\ns-prepare.ps1 -Seq 2320 -NoPreview        без PDF для перегляду
#   .\ns-prepare.ps1 -Seq 2320 -Edge "1L7 2R7 …"  page_edge вказано вручну (замір пропускається)
#
# Робить те, що відділ інструментів робив руками на 2318, 2319, 2323:
#   1. ns-prep -NoEdgeClean            геометрія без чистки країв (клин, перекіс, поворот з маніфеста)
#   2. ns-edgecheck -Brief             сторони, які алгоритм позначає «НАГЛЯД» (до чистки)
#   3. ns-spinescan.py --suggest       нитки корінця -> page_edge (найдальша нитка + 0,5 мм, крок 0,5)
#   4. ns-prep -FillHoles -EdgeExtra   зріз корінця + заростання великих дірок від зшивача (fill_holes у маніфест)
#   5. ns-render                       тон, рамка, JPEG (стандарт 25.09.2026)
#   6. PDF без OCR                     C:\NS_WORK\<N>_vyglyad_<ДД.ММ>.pdf — для огляду оператором
#   7. підсумок                        NS_WORK\<N>\prepare.json: нитки, зрізи, дірки, рамка, позначки (числа для звіту)
# Майстри лише читаються; маніфест міняється лише полями обробки (page_edge, fill_holes) — через ns-prep.
# Тривалість ≈ 20 хв на номер. Стан номера не змінюється.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [string]$Edge,
    [switch]$NoPreview
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$t0 = Get-Date
$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$work = Join-Path $script:NS_WORK "$Seq"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$logf = Join-Path $work "prepare.log"
"" | Set-Content $logf -Encoding UTF8
$py = if ($script:PYTHON) { $script:PYTHON } else { "python" }

function Write-Log { param([string]$T, [string]$Color = "Gray") Write-Host $T -ForegroundColor $Color; Add-Content -Path $logf -Value $T -Encoding UTF8 }

function Invoke-NsStep {
    <#  Запустити скрипт, чесно повернути код (порожній код — теж збій). Вивід — у журнал. #>
    param([string]$Name, [string]$Path, [hashtable]$Params = @{})
    Write-Log ("[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $Name) Cyan
    $global:LASTEXITCODE = $null
    $out = & $Path @Params 2>&1 | ForEach-Object { "$_" }
    foreach ($l in $out) { Add-Content -Path $logf -Value $l -Encoding UTF8 }
    $rc = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($rc -ne 0) { Write-Log "    ЗБІЙ (код $rc): $Name — див. $logf" Red; exit 1 }
    return $out
}

Write-Log ("ПІДГОТОВКА {0} ({1}, {2} стор.)" -f $Seq, $man.date, @($man.pages).Count) White
$rot = if ($man.PSObject.Properties.Name -contains 'page_rotate' -and $man.page_rotate) { [string]$man.page_rotate } else { "" }
$summary = [ordered]@{ seq = $Seq; date = $man.date; pages = @($man.pages).Count }

# --- 1-3: замір -----------------------------------------------------------
$spineJson = Join-Path $work "spine.json"
if ($Edge) {
    $edge = $Edge
    Write-Log "page_edge задано вручну: $edge" Yellow
    $summary.edge_source = "вручну"
    # замір з попереднього запуску (spine.json) лишається в підсумку — щоб повторний прогін не стирав числа для звіту
    if (Test-Path $spineJson) { $summary.spine = (Get-Content $spineJson -Raw -Encoding UTF8 | ConvertFrom-Json) }
} else {
    $null = Invoke-NsStep "prep -NoEdgeClean (геометрія без чистки)" (Join-Path $PSScriptRoot "ns-prep.ps1") @{ Seq = $Seq; NoEdgeClean = $true; Force = $true }
    $ec = Invoke-NsStep "edgecheck -Brief (позначки нагляду до чистки)" (Join-Path $PSScriptRoot "ns-edgecheck.ps1") @{ Seq = $Seq; Brief = $true }
    $watch = @($ec | Where-Object { $_ -match 'НАГЛЯД' })
    $summary.edge_watch = @($watch | ForEach-Object { $_.Trim() })
    Write-Log ("    сторін із позначкою НАГЛЯД: {0}" -f $watch.Count) $(if ($watch.Count) { "Yellow" } else { "Green" })
    foreach ($w in $watch) { Write-Log ("      " + $w.Trim()) Yellow }

    Write-Log ("[{0}] замір ниток (ns-spinescan.py)" -f (Get-Date).ToString("HH:mm:ss")) Cyan
    $sa = @((Join-Path $work "prep"), "--suggest", "--jsonout", $spineJson)
    if ($rot) { $sa += @("--rotate", $rot) }
    $env:PYTHONIOENCODING = "utf-8"
    $so = & $py (Join-Path $PSScriptRoot "ns-spinescan.py") @sa 2>&1 | ForEach-Object { "$_" }
    foreach ($l in $so) { Add-Content -Path $logf -Value $l -Encoding UTF8 }
    if (-not (Test-Path $spineJson)) { Write-Log "    замір не дав результату — див. $logf" Red; exit 1 }
    $sp = Get-Content $spineJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $edge = [string]$sp.edge
    $sumLine = @($so | Where-Object { $_ -match 'УСЬОГО ниткових' })[0]
    Write-Log ("    " + $sumLine) Gray
    Write-Log ("    page_edge (пропозиція): " + $edge) Green
    foreach ($it in @($sp.pages)) { foreach ($f in @($it.flags)) { Write-Log ("      стор. {0}: {1}" -f $it.n, $f) Yellow } }
    $summary.edge_source = "ns-spinescan"
    $summary.spine = $sp
}
$summary.edge = $edge

# --- 4: зріз корінця й заростання -----------------------------------------
$null = Invoke-NsStep "prep -FillHoles -EdgeExtra (зріз корінця, заростання)" (Join-Path $PSScriptRoot "ns-prep.ps1") @{ Seq = $Seq; FillHoles = $true; Force = $true; EdgeExtra = $edge }
$filled = 0; $left = 0; $holePages = @()
$hd = Join-Path $work "holes"
foreach ($f in @(Get-ChildItem $hd -Filter "p*_log.txt" -ErrorAction SilentlyContinue)) {
    $txt = Get-Content $f.FullName -Encoding UTF8
    $a = @($txt | Where-Object { $_ -match 'ЗАРОЩЕНО' }).Count
    $b = @($txt | Where-Object { $_ -match 'ЛИШЕНО: біля друку|лишено: форма|лишено: маска' }).Count
    $filled += $a; $left += $b
    if ($b -gt 0) { $holePages += ("{0}: залишено {1}" -f $f.BaseName.Substring(0, 3), $b) }
}
$pagesN = @($man.pages).Count
$summary.holes = [ordered]@{ filled = $filled; expected = 2 * $pagesN; left_near_print = $left; pages_with_left = $holePages }
Write-Log ("    дірок зарощено {0} із очікуваних {1}; лишено біля друку/за формою: {2} {3}" -f $filled, (2 * $pagesN), $left, ($holePages -join "; ")) $(if ($filled -lt 2 * $pagesN) { "Yellow" } else { "Green" })

# --- 5: render ------------------------------------------------------------
$rl = Invoke-NsStep "render (тон, рамка, JPEG)" (Join-Path $PSScriptRoot "ns-render.ps1") @{ Seq = $Seq; Force = $true }
$notUnified = @($rl | Where-Object { $_ -match 'не зведено до спільного розміру' } | ForEach-Object { $_.Trim() })
$summary.render_not_unified = $notUnified
if ($notUnified.Count) { Write-Log ("    не зведено до спільного розміру: {0} стор." -f $notUnified.Count) Yellow }

$fc = & $py (Join-Path $PSScriptRoot "ns-framecheck.py") (Join-Path $work "render") 2>&1 | ForEach-Object { "$_" }
foreach ($l in $fc) { Add-Content -Path $logf -Value $l -Encoding UTF8 }
$uneven = @($fc | Where-Object { $_ -match '<<<' } | ForEach-Object { ($_ -split '\s+')[0] })
$summary.frame_uneven = $uneven
Write-Log ("    рамка: нерівних сторінок {0} {1}" -f $uneven.Count, ($uneven -join ", ")) $(if ($uneven.Count) { "Yellow" } else { "Green" })

# --- 6: PDF без OCR --------------------------------------------------------
$pdf = ""
if (-not $NoPreview) {
    $pdf = Join-Path $script:NS_WORK ("{0}_vyglyad_{1}.pdf" -f $Seq, (Get-Date).ToString("dd.MM"))
    $env:NS_PDF_OUT = $pdf; $env:NS_PDF_SRC = (Join-Path $work "render")
    $r = & $py -c "import img2pdf,glob,os; fs=sorted(glob.glob(os.path.join(os.environ['NS_PDF_SRC'],'p*.jpg'))); open(os.environ['NS_PDF_OUT'],'wb').write(img2pdf.convert(fs)); print(len(fs), os.path.getsize(os.environ['NS_PDF_OUT']))" 2>&1
    Write-Log ("[{0}] PDF без OCR: {1} ({2})" -f (Get-Date).ToString("HH:mm:ss"), $pdf, $r) Green
    $summary.preview_pdf = $pdf
}

$summary.minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $work "prepare.json") -Encoding UTF8
Write-Log ("ГОТОВО {0}: {1} хв. Підсумок: {2}" -f $Seq, $summary.minutes, (Join-Path $work "prepare.json")) White
exit 0
