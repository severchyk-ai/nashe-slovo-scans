# Резервна копія проєкту на зовнішній диск і звірка копії за хешами маніфестів.
#
#   .\ns-backup.ps1 -Dest D:\                        скопіювати все й звірити
#   .\ns-backup.ps1 -Dest F:\ -Years 2002            лише майстри (і PDF) 2002 року + весь _catalog
#   .\ns-backup.ps1 -Dest F:\ -Years 2002 -Jobs masters,pdf    лише названі частини
#   .\ns-backup.ps1 -Dest D:\ -Years 2000,2001 -VerifyOnly     лише звірити наявну копію цих років (нічого не пише)
#   .\ns-backup.ps1 -Dest F:\ -Years 2002 -Jobs masters,pdf -JobYears "pdf=2001,2002"   PDF інших років, ніж майстри
#   .\ns-backup.ps1 -Dest D:\ -Quick                 звіряти за SHA-256 лише сторінки, яких ще не звіряли
#                                                    (список звіреного: <Dest>\NS_BACKUP\_verified.txt; «Завершити день»)
#   .\ns-backup.ps1 -Dest D:\ -DryRun                лише порахувати, що влізе (нічого не пише й не звіряє)
#
# Частини (-Jobs, за умовчанням all) — у <Dest>\NS_BACKUP\:
#   masters   NS_MASTERS      майстри, каталог, суми — ГОЛОВНЕ
#   pdf       NS_PDF          готові PDF (відтворювані, але копіювати швидше, ніж збирати)
#   scans     Scans           скрипти, CLAUDE.md, tessdata (їх береже й git)
#   archive   NS_ARCHIVE_PROJECT  хронологія, план, зразки, розмови
#   naps2     NAPS2           profiles.xml, config.xml (профіль сканера)
# -Years обмежує masters і pdf вказаними роками; _catalog (реєстр, суми, відкладені кадри) копіюється ЗАВЖДИ ЦІЛИМ.
# Диск під частину проєкту (напр. 2002 рік) веде файл <Dest>\NS_BACKUP\_scope.json — його пише цей скрипт
# за явних -Years/-Jobs, і «Завершити день» (ns-endday) береже такий диск саме в цих межах.
#
# Місце перевіряється ДО копіювання, по частинах (порядок: masters, naps2, scans, archive, pdf):
#   - МАЙСТРИ: якщо не влізають цілком — нічого з них не копіюється, червоний рядок, код 1. Мовчки не пропускаються ніколи.
#   - PDF (відтворювані): копіюються по одному, скільки влізе; решта — червоний рядок «ПРОПУЩЕНО», код 3.
#     Кожен PDF пишеться в <ім'я>.part і лише після перевірки розміру перейменовується — обірваних файлів на диску не лишається.
#   - решта частин (scans, archive, naps2): не влізає — пропускається з червоним рядком, код 3.
#   Запас: 2 % від дописуваного + 1 МБ (не більше 32 МБ) на частину; для PDF — 4 МБ.
# Наприкінці — «місця на диску вистачить ще на N PDF».
#
# Копіювання ЛИШЕ ДОДАЄ й ОНОВЛЮЄ: robocopy /E без /MIR і /PURGE, тож на
# диску-копії нічого не видаляється. Щоб прибрати з копії те, чого вже немає в
# проєкті (напр. відкладені майстри), — лише з відома оператора.
# -VerifyOnly нічого не пише на диск (навіть мітку часу): лише читає й звіряє.
#
# Звірка: кожна сторінка з кожного маніфесту (лише вибраних років) у копії має бути на місці й мати
# той самий SHA-256 — як у маніфесті ОРИГІНАЛУ; якщо маніфест змінився (заміна, перейменування
# сторінки), копію треба оновити.
# Код виходу: 0 — усе збігається; 1 — є розбіжності, збій чи майстри не влізли; 3 — усе, що влізло, збігається,
# але щось (PDF та ін.) пропущено за браком місця.

param([Parameter(Mandatory = $true)][string]$Dest,
      [switch]$VerifyOnly, [switch]$Quick, [switch]$DryRun,
      [string]$Years = "", [string]$Jobs = "all", [string]$JobYears = "")

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$root = Join-Path $Dest "NS_BACKUP"
$yearList = @($Years -split '[,\s]+' | Where-Object { $_ -match '^\d{4}$' })
# -JobYears "pdf=2001,2002;masters=2002": роки для окремої частини замість загальних -Years (диск може берегти майстри одних років, а PDF інших)
$jobYearMap = @{}
foreach ($pair in @($JobYears -split ';' | Where-Object { $_.Trim() })) {
    $kv = $pair -split '=', 2
    if ($kv.Count -ne 2) { Write-Host "Не зрозумів -JobYears: '$pair' (треба частина=рік,рік)" -ForegroundColor Red; exit 1 }
    $jobYearMap[$kv[0].Trim()] = @($kv[1] -split '[,\s]+' | Where-Object { $_ -match '^\d{4}$' })
}
$mYears = if ($jobYearMap.ContainsKey("masters")) { @($jobYearMap["masters"]) } else { $yearList }
$pYears = if ($jobYearMap.ContainsKey("pdf")) { @($jobYearMap["pdf"]) } else { $yearList }
$jobSet = if ($Jobs -eq "all") { @("masters", "pdf", "scans", "archive", "naps2") } else { @($Jobs -split '[,\s]+' | Where-Object { $_ }) }
$bad0 = @($jobSet | Where-Object { @("masters", "pdf", "scans", "archive", "naps2") -notcontains $_ })
if ($bad0.Count) { Write-Host "Невідома частина в -Jobs: $($bad0 -join ', ')" -ForegroundColor Red; exit 1 }

# Перелік копіювань: (частина, джерело, призначення, чи звичайне /E, чи лише *.xml)
$copy = @()
function Add-Copy { param([string]$Job, [string]$Src, [string]$Dst, [string]$Kind = "tree") $script:copy += @{ job = $Job; src = $Src; dst = $Dst; kind = $Kind } }
foreach ($k in $jobSet) {
    switch ($k) {
        "masters" {
            if ($mYears.Count) {
                Add-Copy "masters" (Join-Path $script:NS_MASTERS "_catalog") (Join-Path $root "NS_MASTERS\_catalog")
                foreach ($y in $mYears) { Add-Copy "masters" (Join-Path $script:NS_MASTERS $y) (Join-Path $root "NS_MASTERS\$y") }
            } else { Add-Copy "masters" $script:NS_MASTERS (Join-Path $root "NS_MASTERS") }
        }
        "pdf" {
            if ($pYears.Count) { foreach ($y in $pYears) { Add-Copy "pdf" (Join-Path $script:NS_PDF $y) (Join-Path $root "NS_PDF\$y") } }
            else { Add-Copy "pdf" $script:NS_PDF (Join-Path $root "NS_PDF") }
        }
        "scans"   { Add-Copy "scans" $PSScriptRoot (Join-Path $root "Scans") }
        "archive" { Add-Copy "archive" "C:\NS_ARCHIVE_PROJECT" (Join-Path $root "NS_ARCHIVE_PROJECT") }
        "naps2"   { Add-Copy "naps2" (Join-Path $env:APPDATA "NAPS2") (Join-Path $root "NAPS2") "xml" }
    }
}

function Get-DirBytes { param([string]$P) if (Test-Path $P) { [long](Get-ChildItem $P -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { 0L } }
function Get-Free { if ($env:NS_TEST_FREE) { return [long]$env:NS_TEST_FREE }   # лише для проб: удаваний вільний обсяг
    [long](Get-PSDrive ((Get-Item $Dest).PSDrive.Name)).Free }
function Format-Gb { param([long]$B) "{0:N2} ГБ" -f ($B / 1GB) }

$MARGIN = 32MB
function Test-Fits {
    <#  Влізає delta байтів, якщо лишається запас: 2 % + 1 МБ, але не більше 32 МБ (кластери, службові дані ФС). #>
    param([long]$Delta, [long]$Free)
    if ($Delta -le 0) { return $true }
    $m = [math]::Min([long]$MARGIN, [long]($Delta * 0.02) + 1MB)
    return (($Delta + $m) -le $Free)
}
$skipped = @()      # що пропущено за браком місця (потрапляє в код 3)
$failNoFit = $false # майстри не влізли (код 1)

function Get-PdfTodo {
    <#  PDF-файли частини, яких у копії немає або які відрізняються (розмір; час із допуском 2 с — FAT). #>
    param($Job)
    $todo = @()
    foreach ($f in (Get-ChildItem $Job.src -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Job.src.Length).TrimStart('\')
        $df = Join-Path $Job.dst $rel
        $same = $false
        if (Test-Path -LiteralPath $df) {
            $d = Get-Item -LiteralPath $df
            $same = ($d.Length -eq $f.Length) -and ([math]::Abs(($d.LastWriteTimeUtc - $f.LastWriteTimeUtc).TotalSeconds) -le 2)
        }
        if (-not $same) { $todo += [pscustomobject]@{ Src = $f.FullName; Dst = $df; Length = [long]$f.Length; Rel = $rel; Exists = (Test-Path -LiteralPath $df) } }
    }
    return $todo
}

if (-not $VerifyOnly) {
    $free = Get-Free
    $prio = @{ masters = 1; naps2 = 2; scans = 3; archive = 4; pdf = 5 }
    foreach ($j in $copy) {
        if (-not (Test-Path $j.src)) { $j.need = 0L; $j.already = 0L; $j.delta = 0L; continue }
        if ($j.job -eq "pdf") {
            $j.todo = @(Get-PdfTodo $j)
            $j.delta = [long](($j.todo | Where-Object { -not $_.Exists } | Measure-Object Length -Sum).Sum) +
                       [long](($j.todo | Where-Object { $_.Exists } | Measure-Object Length -Sum).Sum)   # перезапис: у гіршому разі стара копія ще на місці
        } else {
            $j.need = Get-DirBytes $j.src; $j.already = Get-DirBytes $j.dst
            $j.delta = [math]::Max(0L, $j.need - $j.already)
        }
    }
    Write-Host ("Вільно на {0}: {1}{2}" -f $Dest, (Format-Gb $free), $(if ($mYears.Count -or $pYears.Count) { "  (майстри: $(if ($mYears.Count) { $mYears -join ', ' } else { 'усі' }); PDF: $(if ($pYears.Count) { $pYears -join ', ' } else { 'усі' }))" } else { "" }))
    foreach ($jn in ($jobSet | Sort-Object { $prio[$_] })) {
        $d = [long](($copy | Where-Object { $_.job -eq $jn } | ForEach-Object { $_.delta } | Measure-Object -Sum).Sum)
        Write-Host ("  {0,-8} треба дописати {1}" -f $jn, (Format-Gb $d))
    }

    # МАЙСТРИ: цілком або нічого
    $mNeed = [long](($copy | Where-Object { $_.job -eq "masters" } | ForEach-Object { $_.delta } | Measure-Object -Sum).Sum)
    if ($jobSet -contains "masters" -and -not (Test-Fits $mNeed $free)) {
        $failNoFit = $true
        Write-Host ("  МАЙСТРИ НЕ ВЛІЗУТЬ: треба {0} (+запас), вільно {1}. Майстри НЕ копіюю жодного — потрібне місце!" -f (Format-Gb $mNeed), (Format-Gb $free)) -ForegroundColor Red
    }

    foreach ($j in ($copy | Sort-Object { $prio[$_.job] })) {
        if (-not (Test-Path $j.src)) { Write-Host "  пропущено (немає): $($j.src)" -ForegroundColor Yellow; continue }
        $free = Get-Free
        if ($j.job -eq "masters") {
            if ($failNoFit) { continue }
        } elseif ($j.job -eq "pdf") {
            $todo = @($j.todo)
            if ($todo.Count -eq 0) { Write-Host "  PDF $($j.src): усе вже скопійовано"; continue }
            $left = $free - 4MB
            $take = @(); $rest = @()
            foreach ($t in $todo) {
                # файл, що вже є, замінюється через .part — під час заміни потрібне місце під новий, старий ще лежить
                if ($t.Length -le $left) { $take += $t; $left -= $t.Length } else { $rest += $t }
            }
            Write-Host ("  PDF {0}: до копіювання {1} (з них влізає {2})" -f $j.src, $todo.Count, $take.Count)
            if ($DryRun) { }
            else {
                foreach ($t in $take) {
                    $part = $t.Dst + ".part"
                    New-Item -ItemType Directory -Path (Split-Path $t.Dst) -Force | Out-Null
                    try {
                        Copy-Item -LiteralPath $t.Src -Destination $part -Force -ErrorAction Stop
                        if ((Get-Item -LiteralPath $part).Length -ne $t.Length) { throw "розмір копії не збігається" }
                        (Get-Item -LiteralPath $part).LastWriteTimeUtc = (Get-Item -LiteralPath $t.Src).LastWriteTimeUtc
                        Move-Item -LiteralPath $part -Destination $t.Dst -Force -ErrorAction Stop
                    } catch {
                        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                        $rest += $t
                        Write-Host ("  PDF не скопійовано: {0} — {1}" -f $t.Rel, $_.Exception.Message) -ForegroundColor Red
                    }
                }
            }
            if ($rest.Count) {
                $restMb = [math]::Round((($rest | Measure-Object Length -Sum).Sum) / 1MB)
                Write-Host ("  PDF ПРОПУЩЕНО за браком місця: {0} шт. (~{1} МБ): {2}" -f $rest.Count, $restMb, (($rest | Select-Object -First 8 | ForEach-Object { $_.Rel }) -join ", ") + $(if ($rest.Count -gt 8) { " …" } else { "" })) -ForegroundColor Red
                $skipped += "pdf ($($rest.Count) шт.)"
            }
            continue
        } else {
            if (-not (Test-Fits $j.delta $free)) {
                Write-Host ("  {0} ПРОПУЩЕНО за браком місця: треба {1}, вільно {2}" -f $j.job, (Format-Gb $j.delta), (Format-Gb $free)) -ForegroundColor Red
                $skipped += $j.job
                continue
            }
        }
        if ($DryRun) { Write-Host "  (пробний прогін) копіював би $($j.src) -> $($j.dst)"; continue }
        Write-Host "  копіюю $($j.src) -> $($j.dst)"
        $rcArgs = @($j.src, $j.dst, "/E", "/COPY:DAT", "/DCOPY:T", "/FFT", "/R:2", "/W:2", "/MT:8", "/NFL", "/NDL", "/NJH", "/NP")  # /FFT: FAT-диск округлює час до 2 с — без цього кожен запуск перекопіював би все
        if ($j.kind -eq "xml") { $rcArgs = @($j.src, $j.dst, "*.xml", "/COPY:DAT", "/R:2", "/W:2", "/NFL", "/NDL", "/NJH", "/NP") }
        & robocopy @rcArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Host "  ЗБІЙ robocopy (код $LASTEXITCODE) на $($j.src)" -ForegroundColor Red; exit 1 }
    }

    # прогноз: скільки ще PDF влізе
    $allPdf = @(Get-ChildItem $script:NS_PDF -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue)
    if ($allPdf.Count -gt 0) {
        $avg = ($allPdf | Measure-Object Length -Average).Average
        $freeNow = Get-Free
        $more = [math]::Max(0, [math]::Floor(($freeNow - 4MB) / $avg))
        Write-Host ("  Вільно {0}: місця вистачить ще на ~{1} PDF (середній {2:N1} МБ)" -f (Format-Gb $freeNow), $more, ($avg / 1MB)) -ForegroundColor $(if ($more -lt 10) { "Yellow" } else { "Gray" })
    }
    if ($DryRun) {
        Write-Host "(пробний прогін: нічого не записано)" -ForegroundColor Yellow
        if ($failNoFit) { exit 1 }
        if ($skipped.Count) { exit 3 }
        exit 0
    }
    if (($Years -or $Jobs -ne "all" -or $JobYears) -and -not $failNoFit) {
        $scope = [ordered]@{ years = @($yearList | ForEach-Object { [int]$_ }); jobs = @($jobSet) }
        if ($jobYearMap.Count) { $yb = [ordered]@{}; foreach ($k in $jobYearMap.Keys) { $yb[$k] = @($jobYearMap[$k] | ForEach-Object { [int]$_ }) }; $scope.years_by_job = $yb }
        $scope.written = (Get-Date).ToString("s")
        [IO.File]::WriteAllText((Join-Path $root "_scope.json"), ($scope | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    if ($failNoFit) { Write-Host "Резерв майстрів НЕ зроблено (немає місця) — звірку пропущено." -ForegroundColor Red; exit 1 }
}
if ($DryRun) { Write-Host "-DryRun разом з -VerifyOnly нічого не робить."; exit 0 }

# --- звірка майстрів у копії -----------------------------------------------
if ($jobSet -notcontains "masters") { Write-Host "Частина masters не вибрана — звірка майстрів пропущена."; if ($skipped.Count) { exit 3 }; exit 0 }
$bm = Join-Path $root "NS_MASTERS"
if (-not (Test-Path $bm)) { Write-Host "Копії майстрів немає: $bm" -ForegroundColor Red; exit 1 }
Write-Host ""
Write-Host ("Звірка копії майстрів за SHA-256{0}..." -f $(if ($mYears.Count) { " (роки: $($mYears -join ', '))" } else { "" })) -ForegroundColor Cyan
$ok = 0; $bad = @(); $stale = @()
# -Quick: сторінка, звірена раніше з ТИМ САМИМ хешем маніфеста, вдруге не хешується.
# Ключ включає хеш, тож заміна сторінки (ns-rescan) змусить звірити її знову.
$vfile = Join-Path $root "_verified.txt"
$done = New-Object 'System.Collections.Generic.HashSet[string]'
if ($Quick -and (Test-Path $vfile)) { foreach ($l in [IO.File]::ReadAllLines($vfile)) { [void]$done.Add($l) } }
$newlyVerified = New-Object System.Collections.Generic.List[string]
$skippedQuick = 0
$issueDirs = @(Get-ChildItem $script:NS_MASTERS -Directory -Recurse -Depth 1 | Where-Object { Test-Path (Join-Path $_.FullName "_manifest.json") })
foreach ($d in $issueDirs) {
    $rel = $d.FullName.Substring($script:NS_MASTERS.Length).TrimStart('\')
    if ($mYears.Count -and ($mYears -notcontains $rel.Split('\')[0])) { continue }
    $man = Read-NsManifest -IssueDir $d.FullName
    $bd = Join-Path $bm $rel
    foreach ($p in $man.pages) {
        $bf = Join-Path $bd $p.file
        if (-not (Test-Path -LiteralPath $bf)) { $bad += "$rel\$($p.file): немає в копії"; continue }
        $key = "$rel\$($p.file)|$($p.sha256)"
        if ($Quick -and $done.Contains($key)) { $ok++; $skippedQuick++; continue }
        if ((Get-NsHash $bf) -ne $p.sha256) { $stale += "$rel\$($p.file): хеш не збігається з оригіналом"; continue }
        $ok++
        if ($Quick) { $newlyVerified.Add($key) }
    }
}
if ($Quick -and $newlyVerified.Count -gt 0 -and -not $VerifyOnly) { [IO.File]::AppendAllLines($vfile, $newlyVerified, [Text.UTF8Encoding]::new($false)) }
Write-Host ("  звірено: {0} сторінок збігаються" -f $ok) -ForegroundColor Green
if ($Quick) { Write-Host ("  із них звірених раніше: {0}, звірено зараз: {1}" -f $skippedQuick, $newlyVerified.Count) -ForegroundColor DarkGray }
foreach ($x in $bad + $stale) { Write-Host "  ! $x" -ForegroundColor Yellow }
Write-Host ("  розбіжностей: немає в копії {0}, хеш не збігається {1}" -f $bad.Count, $stale.Count)
$rm = @(Get-ChildItem (Join-Path $bm "_catalog\removed") -File -ErrorAction SilentlyContinue).Count
Write-Host "  відкладених файлів у копії _catalog\removed: $rm"
Write-Host ("  вільно на диску: {0:N2} ГБ" -f ((Get-PSDrive ((Get-Item $Dest).PSDrive.Name)).Free/1GB))
if (-not $VerifyOnly) {
    Set-Content -Path (Join-Path $root "_backup_stamp.txt") -Value ("{0}  сторінок {1}, розбіжностей {2}{3}" -f (Get-Date).ToString("s"), $ok, ($bad.Count + $stale.Count),
                $(if ($mYears.Count) { ", роки $($mYears -join ',')" } else { "" })) -Encoding UTF8
}
if ($bad.Count + $stale.Count) { exit 1 }
if ($skipped.Count) {
    Write-Host ("Майстри збігаються з оригіналом, але ПРОПУЩЕНО за браком місця: {0}" -f ($skipped -join ", ")) -ForegroundColor Red
    exit 3
}
Write-Host "Копія повна й збігається з оригіналом." -ForegroundColor Green
# явний код: інакше скрипт віддає $LASTEXITCODE останнього robocopy (1 = «скопійовано», не помилка)
exit 0
