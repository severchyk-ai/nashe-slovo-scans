# Резервна копія проєкту на зовнішній диск і звірка копії за хешами маніфестів.
#
#   .\ns-backup.ps1 -Dest D:\                        скопіювати все й звірити
#   .\ns-backup.ps1 -Dest F:\ -Years 2002            лише майстри (і PDF) 2002 року + весь _catalog
#   .\ns-backup.ps1 -Dest F:\ -Years 2002 -Jobs masters,pdf    лише названі частини
#   .\ns-backup.ps1 -Dest D:\ -Years 2000,2001 -VerifyOnly     лише звірити наявну копію цих років (нічого не пише)
#   .\ns-backup.ps1 -Dest D:\ -Quick                 звіряти за SHA-256 лише сторінки, яких ще не звіряли
#                                                    (список звіреного: <Dest>\NS_BACKUP\_verified.txt; «Завершити день»)
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
# Копіювання ЛИШЕ ДОДАЄ й ОНОВЛЮЄ: robocopy /E без /MIR і /PURGE, тож на
# диску-копії нічого не видаляється. Щоб прибрати з копії те, чого вже немає в
# проєкті (напр. відкладені майстри), — лише з відома оператора.
# -VerifyOnly нічого не пише на диск (навіть мітку часу): лише читає й звіряє.
#
# Звірка: кожна сторінка з кожного маніфесту (лише вибраних років) у копії має бути на місці й мати
# той самий SHA-256 — як у маніфесті ОРИГІНАЛУ; якщо маніфест змінився (заміна, перейменування
# сторінки), копію треба оновити. Код виходу 0 — усе збігається, 1 — є розбіжності чи збій.

param([Parameter(Mandatory = $true)][string]$Dest,
      [switch]$VerifyOnly, [switch]$Quick,
      [string]$Years = "", [string]$Jobs = "all")

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$root = Join-Path $Dest "NS_BACKUP"
$yearList = @($Years -split '[,\s]+' | Where-Object { $_ -match '^\d{4}$' })
$jobSet = if ($Jobs -eq "all") { @("masters", "pdf", "scans", "archive", "naps2") } else { @($Jobs -split '[,\s]+' | Where-Object { $_ }) }
$bad0 = @($jobSet | Where-Object { @("masters", "pdf", "scans", "archive", "naps2") -notcontains $_ })
if ($bad0.Count) { Write-Host "Невідома частина в -Jobs: $($bad0 -join ', ')" -ForegroundColor Red; exit 1 }

# Перелік копіювань: (джерело, призначення, чи звичайне /E, чи лише *.xml)
$copy = @()
function Add-Copy { param([string]$Src, [string]$Dst, [string]$Kind = "tree") $script:copy += @{ src = $Src; dst = $Dst; kind = $Kind } }
foreach ($k in $jobSet) {
    switch ($k) {
        "masters" {
            if ($yearList.Count) {
                Add-Copy (Join-Path $script:NS_MASTERS "_catalog") (Join-Path $root "NS_MASTERS\_catalog")
                foreach ($y in $yearList) { Add-Copy (Join-Path $script:NS_MASTERS $y) (Join-Path $root "NS_MASTERS\$y") }
            } else { Add-Copy $script:NS_MASTERS (Join-Path $root "NS_MASTERS") }
        }
        "pdf" {
            if ($yearList.Count) { foreach ($y in $yearList) { Add-Copy (Join-Path $script:NS_PDF $y) (Join-Path $root "NS_PDF\$y") } }
            else { Add-Copy $script:NS_PDF (Join-Path $root "NS_PDF") }
        }
        "scans"   { Add-Copy $PSScriptRoot (Join-Path $root "Scans") }
        "archive" { Add-Copy "C:\NS_ARCHIVE_PROJECT" (Join-Path $root "NS_ARCHIVE_PROJECT") }
        "naps2"   { Add-Copy (Join-Path $env:APPDATA "NAPS2") (Join-Path $root "NAPS2") "xml" }
    }
}

function Get-DirBytes { param([string]$P) if (Test-Path $P) { [long](Get-ChildItem $P -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { 0L } }

if (-not $VerifyOnly) {
    $need = 0L; $already = 0L
    foreach ($j in $copy) { if (Test-Path $j.src) { $need += Get-DirBytes $j.src; $already += Get-DirBytes $j.dst } }
    $drive = (Get-Item $Dest).PSDrive
    $have = (Get-PSDrive $drive.Name).Free
    Write-Host ("Потрібно {0:N2} ГБ, на диску вже {1:N2} ГБ цієї копії, вільно {2:N2} ГБ{3}" -f ($need/1GB), ($already/1GB), ($have/1GB),
                $(if ($yearList.Count) { "  (роки: $($yearList -join ', '))" } else { "" }))
    if ($need - $already -gt $have) { Write-Host "Місця не вистачає — зупинка, нічого не скопійовано." -ForegroundColor Red; exit 1 }

    foreach ($j in $copy) {
        if (-not (Test-Path $j.src)) { Write-Host "  пропущено (немає): $($j.src)" -ForegroundColor Yellow; continue }
        Write-Host "  копіюю $($j.src) -> $($j.dst)"
        $rcArgs = @($j.src, $j.dst, "/E", "/COPY:DAT", "/DCOPY:T", "/FFT", "/R:2", "/W:2", "/MT:8", "/NFL", "/NDL", "/NJH", "/NP")  # /FFT: FAT-диск округлює час до 2 с — без цього кожен запуск перекопіював би все
        if ($j.kind -eq "xml") { $rcArgs = @($j.src, $j.dst, "*.xml", "/COPY:DAT", "/R:2", "/W:2", "/NFL", "/NDL", "/NJH", "/NP") }
        & robocopy @rcArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Host "  ЗБІЙ robocopy (код $LASTEXITCODE) на $($j.src)" -ForegroundColor Red; exit 1 }
    }
    if ($Years -or $Jobs -ne "all") {
        $scope = [ordered]@{ years = @($yearList | ForEach-Object { [int]$_ }); jobs = @($jobSet); written = (Get-Date).ToString("s") }
        [IO.File]::WriteAllText((Join-Path $root "_scope.json"), ($scope | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
}

# --- звірка майстрів у копії -----------------------------------------------
if ($jobSet -notcontains "masters") { Write-Host "Частина masters не вибрана — звірка майстрів пропущена."; exit 0 }
$bm = Join-Path $root "NS_MASTERS"
if (-not (Test-Path $bm)) { Write-Host "Копії майстрів немає: $bm" -ForegroundColor Red; exit 1 }
Write-Host ""
Write-Host ("Звірка копії майстрів за SHA-256{0}..." -f $(if ($yearList.Count) { " (роки: $($yearList -join ', '))" } else { "" })) -ForegroundColor Cyan
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
    if ($yearList.Count -and ($yearList -notcontains $rel.Split('\')[0])) { continue }
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
                $(if ($yearList.Count) { ", роки $($yearList -join ',')" } else { "" })) -Encoding UTF8
}
if ($bad.Count + $stale.Count) { exit 1 }
Write-Host "Копія повна й збігається з оригіналом." -ForegroundColor Green
# явний код: інакше скрипт віддає $LASTEXITCODE останнього robocopy (1 = «скопійовано», не помилка)
exit 0
