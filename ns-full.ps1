# Повний шлях ЗВИЧАЙНОГО номера: від майстрів до готового PDF з OCR і всіх перевірок — однією командою.
#
#   .\ns-full.ps1 -Seq 2273
#   .\ns-full.ps1 -Seq 2273 -BuildOnly     підготовку вже зроблено (render на місці) — лише PDF з OCR і перевірки
#   .\ns-full.ps1 -Seq 2273 -KeepWork      не прибирати prep / render / masks після успіху
#   .\ns-full.ps1 -Seq 2273 -Reflag        готовий номер: перерахувати позначки шва й зрізу без ниток, нічого не збираючи
#
# Рішення оператора 02.10.2026 (варіант А): звичайний номер іде одразу до готового PDF з OCR; оператор
# дивиться лише позначені сторінки й кілька випадкових номерів на рік. ns-issue для цього не годиться —
# він не міряє нитки (бере page_edge з маніфесту); ns-prepare міряє, але PDF з OCR не збирає. Тут ланцюжок:
#   1. ns-prepare -NoPreview     замір ниток -> page_edge -> (заростання) -> render за стандартом 02.10
#   2. ns-margins.py             поля друку на render (несиметрія > 2 мм — позначка)
#   3. старий PDF                NS_PDF\<рік>\<N>.pdf -> NS_WORK\_old_pdf_02.10\ (копія; нічого не перезаписується)
#   4. ns-build -Force           OCR (ukr+pol), PDF/A-2b -> NS_PDF
#   5. ns-qc, ns-edgescan.py     перевірки готового PDF
#   6. NS_WORK\<N>\full.json     числа й УСІ позначки номера (джерело «паспорта року»); стан: done / review
# Номери «лише вручну» (ns-manual.csv) сюди не йдуть: зупинка з кодом 3 (-IncludeManual — узяти все одно).
# Коди: 0 готово; 1 збій; 3 потрібне рішення (лише вручну, ручний page_edge); 42 заблоковано OpenCV;
# 43 підготовлено, але pikepdf/ocrmypdf заблоковано — PDF з OCR не зібрано (далі -BuildOnly).
# Майстри лише читаються. Журнал — NS_WORK\<N>\full.log (і prepare.log від кроку 1).

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [switch]$BuildOnly,
    [switch]$IncludeManual,
    [switch]$KeepWork,
    [switch]$Reflag,            # нічого не збирати: перерахувати позначки готового номера з наявних журналів
    [string]$OldPdfDir = "_old_pdf_02.10"
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$t0 = Get-Date
$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$work = Join-Path $script:NS_WORK "$Seq"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$logf = Join-Path $work "full.log"
$fullJson = Join-Path $work "full.json"
$py = if ($script:PYTHON) { $script:PYTHON } else { "python" }
$env:PYTHONIOENCODING = "utf-8"

function Write-Log { param([string]$T, [string]$Color = "Gray") Write-Host $T -ForegroundColor $Color; Add-Content -Path $logf -Value $T -Encoding UTF8 }

function Get-NsExtraFlags {
    <#  Позначки, що рахуються з журналів підготовки (ns-fullflags.py, рішення головної 02.10.2026): шов,
        гірший за схвалений оператором, і зріз корінця без ниток. Скрипт не відпрацював — це ПОЗНАЧКА,
        а не «чисто».                                                                                #>
    $ef = @(& $py (Join-Path $PSScriptRoot "ns-fullflags.py") "--work" $work "--issue" $issueDir 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { return @("додаткові позначки не пораховано (ns-fullflags, код $LASTEXITCODE): " + ($ef -join " ")) }
    return @($ef | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

# --- -Reflag: перерахувати позначки готового номера, нічого не збираючи ------
# Позначки шва й зрізу без ниток з'явилися, коли частину року вже було зібрано; вони рахуються з того,
# що лишається після прибирання (prepare.log, prepare.json), тож перебудовувати номер не треба.
# Решта позначок full.json лишається як була. Стан міняється лише між done і review.
if ($Reflag) {
    $extraRx = '^(шов гірший за |зріз корінця .* без ниток|УВАГА, ЗРІЗ БІЛЯ ДРУКУ|додаткові позначки не пораховано)'
    $old = $null
    if (Test-Path $fullJson) { try { $old = Get-Content $fullJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    if (-not $old -or $old.stage -ne "done") { Write-Host "Номер ${Seq}: повний шлях не завершено (full.json: $(if ($old) { $old.stage } else { 'немає' })) — позначки не перераховано." -ForegroundColor Yellow; exit 1 }
    $kept = @($old.flags | Where-Object { $_ -and $_ -notmatch $extraRx })
    $newFlags = @($kept) + @(Get-NsExtraFlags)
    $wasN = @($old.flags | Where-Object { $_ }).Count
    $old.flags = $newFlags
    $old.flags_n = $newFlags.Count
    $curState = Get-NsIssueState $man
    $wantState = if ($newFlags.Count -eq 0) { "done" } else { "review" }
    if ($curState -in @("done", "review") -and $curState -ne $wantState) {
        Set-NsIssueState -IssueDir $issueDir -Manifest $man -State $wantState -Note ("ns-full -Reflag: позначок {0} (було {1})" -f $newFlags.Count, $wasN)
        $curState = $wantState
    }
    $old.state = $curState
    $old | ConvertTo-Json -Depth 6 | Set-Content $fullJson -Encoding UTF8
    Write-Log ("[{0}] -Reflag {1}: позначок {2} (було {3}); стан {4}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Seq, $newFlags.Count, $wasN, $curState) $(if ($newFlags.Count) { "Yellow" } else { "Green" })
    foreach ($f in $newFlags) { Write-Log ("    ! " + $f) Yellow }
    exit 0
}
"" | Set-Content $logf -Encoding UTF8

$full = [ordered]@{ seq = $Seq; date = $man.date; year = $man.year; pages = @($man.pages).Count; stage = "started"; started = $t0.ToString("s") }
function Save-Full { param([string]$Stage) $full.stage = $Stage; $full | ConvertTo-Json -Depth 6 | Set-Content $fullJson -Encoding UTF8 }

function Invoke-NsLogged {
    <#  Запустити проєктний скрипт у цьому ж процесі; увесь його вивід — у журнал і на екран; код — у $script:lastRc. #>
    param([string]$Name, [string]$File, [hashtable]$Params = @{})
    Write-Log ("[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $Name) Cyan
    $global:LASTEXITCODE = $null
    $out = @(& (Join-Path $PSScriptRoot $File) @Params *>&1 | ForEach-Object {
        $l = "$_"; Add-Content -Path $logf -Value $l -Encoding UTF8; Write-Host $l -ForegroundColor DarkGray; $l })
    $script:lastRc = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    return $out
}

function Stop-Full {
    param([string]$Text, [int]$Code = 1, [string]$Stage = "failed")
    Write-Log $Text Red
    $full.error = $Text
    Save-Full $Stage
    exit $Code
}

Write-Log ("ПОВНИЙ ШЛЯХ {0} ({1}, {2} стор.){3}" -f $Seq, $man.date, @($man.pages).Count, $(if ($BuildOnly) { " — лише збирання" } else { "" })) White
# full.json попереднього прогону не має читатися як свіжий результат, якщо цей прогін упаде
Save-Full "started"

$manual = Get-NsManual
if ($manual.ContainsKey($Seq) -and -not $IncludeManual) {
    Stop-Full ("ЗУПИНКА: {0} — лише вручну ({1}). Повний шлях — для звичайних номерів; -IncludeManual — узяти все одно. Номер НЕ ЗРОБЛЕНО." -f $Seq, $manual[$Seq]) 3 "manual"
}

# --- 1: підготовка ---------------------------------------------------------
$pj = Join-Path $work "prepare.json"
$render = Join-Path $work "render"
if (-not $BuildOnly) {
    $null = Invoke-NsLogged "ns-prepare (замір ниток, зрізи, render)" "ns-prepare.ps1" @{ Seq = $Seq; NoPreview = $true }
    if ($lastRc -eq $script:NS_EXIT_BLOCKED) { Stop-Full "ЗУПИНКА: OpenCV заблоковано Windows — номер $Seq НЕ ЗРОБЛЕНО (підготовка). Не обходити; сказати оператору." $script:NS_EXIT_BLOCKED "blocked" }
    if ($lastRc -eq 3) { Stop-Full "ЗУПИНКА: ns-prepare зупинився на ручному page_edge номера $Seq (код 3) — див. $work\prepare.log. Номер НЕ ЗРОБЛЕНО." 3 "stopped" }
    if ($lastRc -ne 0) { Stop-Full "ЗБІЙ: ns-prepare, код $lastRc — див. $work\prepare.log. Номер $Seq НЕ ЗРОБЛЕНО." 1 }
    $full.minutes_prepare = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
}

# Підготовка має бути ПРО ЦЕЙ render і ПРО ЦЕЙ page_edge: prepare.json — джерело позначок, і застарілий
# читався б як свіжий (-BuildOnly після чиєїсь правки маніфесту чи окремого ns-render).
if (-not (Test-Path $pj)) { Stop-Full "ЗБІЙ: немає $pj — спершу підготовка (ns-full без -BuildOnly). Номер $Seq НЕ ЗРОБЛЕНО." }
$pjItem = Get-Item $pj
if (-not $BuildOnly -and $pjItem.LastWriteTime -lt $t0) { Stop-Full "ЗБІЙ: prepare.json старший за цей прогін — ns-prepare не дійшов до кінця. Номер $Seq НЕ ЗРОБЛЕНО." }
$prep = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
$man = Read-NsManifest -IssueDir $issueDir
$pagesN = @($man.pages).Count
$jpgs = @(Get-ChildItem -Path $render -Filter "p*.jpg" -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($jpgs.Count -ne $pagesN) { Stop-Full ("ЗБІЙ: у render {0} сторінок, у маніфесті {1}. Номер {2} НЕ ЗРОБЛЕНО." -f $jpgs.Count, $pagesN, $Seq) }
$normEdge = { param($s) (@("$s" -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpper() } | Sort-Object) -join " ") }
$manEdge = if ($man.PSObject.Properties.Name -contains 'page_edge') { & $normEdge $man.page_edge } else { "" }
if ($manEdge -ne (& $normEdge $prep.edge)) {
    Stop-Full ("ЗБІЙ: page_edge у маніфесті ({0}) не той, з яким зроблено render ({1}) — підготувати заново. Номер {2} НЕ ЗРОБЛЕНО." -f $manEdge, (& $normEdge $prep.edge), $Seq)
}
$newerJpg = @($jpgs | Where-Object { $_.LastWriteTime -gt $pjItem.LastWriteTime })
if ($newerJpg.Count -gt 0) { Stop-Full ("ЗБІЙ: render ({0} стор.) новіший за prepare.json — позначки підготовки не про цей render; підготувати заново. Номер {1} НЕ ЗРОБЛЕНО." -f $newerJpg.Count, $Seq) }

# --- 2: поля друку на render -----------------------------------------------
$tc = Get-Date
$rot = if ($man.PSObject.Properties.Name -contains 'page_rotate' -and $man.page_rotate) { [string]$man.page_rotate } else { "" }
$ma = @($render); if ($rot) { $ma += @("--rotate", $rot) }
Write-Log ("[{0}] ns-margins.py (поля друку)" -f (Get-Date).ToString("HH:mm:ss")) Cyan
$mo = @(& $py (Join-Path $PSScriptRoot "ns-margins.py") @ma 2>&1 | ForEach-Object { "$_" })
foreach ($l in $mo) { Add-Content -Path $logf -Value $l -Encoding UTF8 }
$marginSum = @($mo | Where-Object { $_ -match '^сторінок' })[0]
if (-not $marginSum) { Stop-Full "ЗБІЙ: ns-margins.py не дав підсумку (код $LASTEXITCODE) — див. $logf. Номер $Seq НЕ ЗРОБЛЕНО." }
$marginOver = @($mo | Where-Object { $_ -match '<<<' } | ForEach-Object { ($_ -replace '\s*<<<\s*$', '').Trim() })
Write-Log ("    " + $marginSum) $(if ($marginOver.Count) { "Yellow" } else { "Green" })
$checkMin = ((Get-Date) - $tc).TotalMinutes

# --- 3-4: PDF з OCR --------------------------------------------------------
# pikepdf / ocrmypdf Windows блокує окремо від OpenCV (02.10.2026 13:59): підготовка тоді ціла й лишається,
# а збирання — пізніше, з -BuildOnly. Це не збій номера.
if (-not (Test-NsPyModules -Set ocr -For "PDF з OCR номера $Seq" -Quiet)) {
    Write-Log "ПІДГОТОВЛЕНО $Seq, але PDF з OCR НЕ ЗІБРАНО: pikepdf / ocrmypdf заблоковано Windows (Smart App Control). Коли мине: ns-full -Seq $Seq -BuildOnly. Не обходити." Yellow
    Save-Full "prepared"
    exit $script:NS_EXIT_OCR_WAIT
}
$name = if ($man.seq_last -ne $man.seq_first) { "$($man.seq_first)-$($man.seq_last)" } else { "$($man.seq_first)" }
$pdf = Join-Path (Join-Path $script:NS_PDF "$($man.year)") "$name.pdf"
if (Test-Path $pdf) {
    # старий PDF не зникає: перша копія лягає під іменем номера; якщо там уже лежить ІНШИЙ файл —
    # поруч, з часом його збирання в імені. Наявного не перезаписуємо ніколи.
    $od = Join-Path $script:NS_WORK $OldPdfDir
    New-Item -ItemType Directory -Path $od -Force | Out-Null
    $oldHash = Get-NsHash $pdf
    $dst = Join-Path $od "$name.pdf"
    if ((Test-Path $dst) -and (Get-NsHash $dst) -ne $oldHash) {
        $dst = Join-Path $od ("{0}_{1}.pdf" -f $name, (Get-Item $pdf).LastWriteTime.ToString("yyyyMMdd-HHmmss"))
    }
    if (Test-Path $dst) {
        if ((Get-NsHash $dst) -ne $oldHash) { Stop-Full "ЗБІЙ: копія старого PDF $dst уже є й вона інша — не перезаписую. Номер $Seq НЕ ЗРОБЛЕНО." }
        Write-Log "    старий PDF уже збережено: $dst" Gray
    } else {
        Copy-Item $pdf $dst
        if ((Get-NsHash $dst) -ne $oldHash) { Stop-Full "ЗБІЙ: копія старого PDF $dst не збіглася з оригіналом. Номер $Seq НЕ ЗРОБЛЕНО." }
        Write-Log "    старий PDF збережено: $dst" Gray
    }
    $full.old_pdf = $dst
}
$tb = Get-Date
$null = Invoke-NsLogged "ns-build -Force (OCR, PDF/A)" "ns-build.ps1" @{ Seq = $Seq; Force = $true }
if ($lastRc -eq $script:NS_EXIT_BLOCKED) {
    Write-Log "ПІДГОТОВЛЕНО $Seq, але PDF з OCR НЕ ЗІБРАНО: модулі заблоковано Windows посеред збирання. Коли мине: ns-full -Seq $Seq -BuildOnly. Не обходити." Yellow
    Save-Full "prepared"
    exit $script:NS_EXIT_OCR_WAIT
}
if ($lastRc -ne 0) { Stop-Full "ЗБІЙ: ns-build, код $lastRc — див. $logf. Номер $Seq НЕ ЗРОБЛЕНО." }
if (-not (Test-Path $pdf) -or (Get-Item $pdf).LastWriteTime -lt $tb) { Stop-Full "ЗБІЙ: ns-build не лишив свіжого $pdf. Номер $Seq НЕ ЗРОБЛЕНО." }
$full.minutes_build = [math]::Round(((Get-Date) - $tb).TotalMinutes, 1)
$full.pdf = $pdf
$full.pdf_mb = [math]::Round((Get-Item $pdf).Length / 1MB, 1)

# --- 5: перевірки готового PDF ---------------------------------------------
$tc = Get-Date
$qc = Invoke-NsLogged "ns-qc" "ns-qc.ps1" @{ Seq = $Seq }
$qcFlags = @($qc | Where-Object { $_ -match '^\s+! ' } | ForEach-Object { ($_ -replace '^\s+! ', '').Trim() })
if (-not (@($qc | Where-Object { $_ -match "^Номер $Seq " }).Count)) { $qcFlags += "ns-qc не відпрацював (код $lastRc)" }
$ocrLine = @($qc | Where-Object { $_ -match 'OCR: (\d+) слів, підозрілих (\d+) \(([\d.,]+) %\)' })[0]
if ($ocrLine -and $ocrLine -match 'OCR: (\d+) слів, підозрілих (\d+) \(([\d.,]+) %\)') {
    $full.ocr_words = [int]$Matches[1]; $full.ocr_suspicious = [int]$Matches[2]
    $full.ocr_pct = [double]::Parse(($Matches[3] -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
}

Write-Log ("[{0}] ns-edgescan.py (смуги краю в PDF)" -f (Get-Date).ToString("HH:mm:ss")) Cyan
$es = @(& $py (Join-Path $PSScriptRoot "ns-edgescan.py") $pdf 2>&1 | ForEach-Object { "$_" })
foreach ($l in $es) { Add-Content -Path $logf -Value $l -Encoding UTF8 }
$esFlags = @($es | Where-Object { $_ -match 'стор\.\s*\d+ край [TBLR]: темно' } | ForEach-Object { $_.Trim() })
# без пройденого контролю і без підсумкового рядка детектор висновку не дає — це позначка, а не «чисто»
if (-not (@($es | Where-Object { $_ -match 'контроль пройдено' }).Count) -or -not (@($es | Where-Object { $_ -match 'найтемніший край' }).Count)) {
    $esFlags += "ns-edgescan не дав висновку (контроль або рендер PDF)"
}
$checkMin += ((Get-Date) - $tc).TotalMinutes
$full.minutes_checks = [math]::Round($checkMin, 1)

# --- 6: позначки, стан, підсумок -------------------------------------------
$flags = @()
foreach ($w in @($prep.edge_watch)) { if ($w) { $flags += ("край (нагляд): " + $w) } }
if ($prep.spine) { foreach ($p in @($prep.spine.pages)) { foreach ($f in @($p.flags)) { if ($f) { $flags += ("нитки, стор. {0}: {1}" -f $p.n, $f) } } } }
if ($prep.holes -and $prep.holes.pages_with_left) { foreach ($h in @($prep.holes.pages_with_left)) { if ($h) { $flags += ("дірка лишилась, стор. " + $h) } } }
foreach ($u in @($prep.render_not_unified)) { if ($u) { $flags += ("не зведено до спільного розміру: " + $u) } }
foreach ($u in @($prep.frame_uneven)) { if ($u) { $flags += ("рамка нерівна: " + $u) } }
foreach ($u in @($prep.pad_review)) { if ($u) { $flags += ("доданий папір: " + $u) } }
foreach ($u in $marginOver) { $flags += ("поля друку > 2 мм: " + $u) }
foreach ($u in $qcFlags) { $flags += ("qc: " + $u) }
foreach ($u in $esFlags) { $flags += ("edgescan: " + $u) }
foreach ($u in @(Get-NsExtraFlags)) { if ($u) { $flags += $u } }
$full.margins = $marginSum
$full.pad_report = @($prep.pad_report)
$full.edge = $prep.edge
if ($prep.PSObject.Properties.Name -contains 'edge_keep') { $full.edge_keep = @($prep.edge_keep) }
$full.flags = $flags
$full.flags_n = $flags.Count
foreach ($f in $flags) { Write-Log ("    ! " + $f) Yellow }

$man = Read-NsManifest -IssueDir $issueDir
$newState = if ($flags.Count -eq 0) { "done" } else { "review" }
Set-NsIssueState -IssueDir $issueDir -Manifest $man -State $newState -Note ("ns-full: PDF з OCR, позначок {0}" -f $flags.Count)
$full.state = $newState

if (-not $KeepWork) {
    # проміжні теки цього номера (їх створив ns-prepare) відтворюються з майстрів; журнали й json лишаються
    foreach ($st in @("prep", "render", "masks")) { Remove-Item (Join-Path $work $st) -Recurse -Force -ErrorAction SilentlyContinue }
}
$full.minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
$full.finished = (Get-Date).ToString("s")
Save-Full "done"
Write-Log ("ГОТОВО {0}: {1}, {2} МБ; слів {3}, підозрілих {4} %; позначок {5}; стан {6}; {7} хв (підготовка {8}, збирання {9}, перевірки {10})" -f `
    $Seq, $pdf, $full.pdf_mb, $full.ocr_words, $full.ocr_pct, $flags.Count, $newState, $full.minutes, $full.minutes_prepare, $full.minutes_build, $full.minutes_checks) White
exit 0
