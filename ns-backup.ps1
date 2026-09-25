# Резервна копія проєкту на зовнішній диск і звірка копії за хешами маніфестів.
#
#   .\ns-backup.ps1 -Dest D:\           скопіювати й звірити
#   .\ns-backup.ps1 -Dest D:\ -VerifyOnly   лише звірити наявну копію
#   .\ns-backup.ps1 -Dest D:\ -Quick        звіряти за SHA-256 лише сторінки, яких ще не звіряли
#                                        (список звіреного: <Dest>\NS_BACKUP\_verified.txt; «Завершити день»)
#
# Що копіюється (у <Dest>\NS_BACKUP\):
#   NS_MASTERS       майстри, каталог, суми — ГОЛОВНЕ
#   NS_PDF           готові PDF (відтворювані, але копіювати швидше, ніж збирати)
#   Scans            скрипти, CLAUDE.md, tessdata
#   NS_ARCHIVE_PROJECT  хронологія, план, зразки, розмови
#   NAPS2            profiles.xml, config.xml (профіль сканера)
#
# Копіювання ЛИШЕ ДОДАЄ й ОНОВЛЮЄ: robocopy /E без /MIR і /PURGE, тож на
# диску-копії нічого не видаляється. Щоб прибрати з копії те, чого вже немає в
# проєкті (напр. відкладені майстри), — лише з відома оператора.
#
# Звірка: кожна сторінка з кожного маніфесту в копії має бути на місці й мати
# той самий SHA-256. Порівнюється з маніфестом КОПІЇ і з маніфестом оригіналу —
# якщо маніфест змінився (заміна сторінки), копію треба оновити.

param([Parameter(Mandatory = $true)][string]$Dest, [switch]$VerifyOnly, [switch]$Quick)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$root = Join-Path $Dest "NS_BACKUP"
$jobs = @(
    @{ src = $script:NS_MASTERS;                             dst = Join-Path $root "NS_MASTERS" },
    @{ src = $script:NS_PDF;                                 dst = Join-Path $root "NS_PDF" },
    @{ src = $PSScriptRoot;                                  dst = Join-Path $root "Scans" },
    @{ src = "C:\NS_ARCHIVE_PROJECT";                        dst = Join-Path $root "NS_ARCHIVE_PROJECT" },
    @{ src = (Join-Path $env:APPDATA "NAPS2");               dst = Join-Path $root "NAPS2" }
)

if (-not $VerifyOnly) {
    $need = 0L
    foreach ($j in $jobs) { if (Test-Path $j.src) { $need += (Get-ChildItem $j.src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
    $drive = (Get-Item $Dest).PSDrive
    $have = (Get-PSDrive $drive.Name).Free
    $already = 0L
    if (Test-Path $root) { $already = (Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    Write-Host ("Потрібно {0:N2} ГБ, на диску вже {1:N2} ГБ копії, вільно {2:N2} ГБ" -f ($need/1GB), ($already/1GB), ($have/1GB))
    if ($need - $already -gt $have) { Write-Host "Місця не вистачає — зупинка, нічого не скопійовано." -ForegroundColor Red; exit 1 }

    foreach ($j in $jobs) {
        if (-not (Test-Path $j.src)) { Write-Host "  пропущено (немає): $($j.src)" -ForegroundColor Yellow; continue }
        Write-Host "  копіюю $($j.src) -> $($j.dst)"
        $rcArgs = @($j.src, $j.dst, "/E", "/COPY:DAT", "/DCOPY:T", "/R:2", "/W:2", "/MT:8", "/NFL", "/NDL", "/NJH", "/NP")
        if ($j.src -like "*NAPS2") { $rcArgs = @($j.src, $j.dst, "*.xml", "/COPY:DAT", "/R:2", "/W:2", "/NFL", "/NDL", "/NJH", "/NP") }
        & robocopy @rcArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Host "  ЗБІЙ robocopy (код $LASTEXITCODE) на $($j.src)" -ForegroundColor Red; exit 1 }
    }
}

# --- звірка майстрів у копії -----------------------------------------------
$bm = Join-Path $root "NS_MASTERS"
if (-not (Test-Path $bm)) { Write-Host "Копії майстрів немає: $bm" -ForegroundColor Red; exit 1 }
Write-Host ""
Write-Host "Звірка копії майстрів за SHA-256..." -ForegroundColor Cyan
$ok = 0; $bad = @(); $stale = @()
# -Quick: сторінка, звірена раніше з ТИМ САМИМ хешем маніфеста, вдруге не хешується.
# Ключ включає хеш, тож заміна сторінки (ns-rescan) змусить звірити її знову.
$vfile = Join-Path $root "_verified.txt"
$done = New-Object 'System.Collections.Generic.HashSet[string]'
if ($Quick -and (Test-Path $vfile)) { foreach ($l in [IO.File]::ReadAllLines($vfile)) { [void]$done.Add($l) } }
$newlyVerified = New-Object System.Collections.Generic.List[string]
$skippedQuick = 0
foreach ($d in (Get-ChildItem $script:NS_MASTERS -Directory -Recurse -Depth 1 | Where-Object { Test-Path (Join-Path $_.FullName "_manifest.json") })) {
    $man = Read-NsManifest -IssueDir $d.FullName
    $rel = $d.FullName.Substring($script:NS_MASTERS.Length).TrimStart('\')
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
if ($Quick -and $newlyVerified.Count -gt 0) { [IO.File]::AppendAllLines($vfile, $newlyVerified, [Text.UTF8Encoding]::new($false)) }
Write-Host ("  звірено: {0} сторінок збігаються" -f $ok) -ForegroundColor Green
if ($Quick) { Write-Host ("  із них звірених раніше: {0}, звірено зараз: {1}" -f $skippedQuick, $newlyVerified.Count) -ForegroundColor DarkGray }
foreach ($x in $bad + $stale) { Write-Host "  ! $x" -ForegroundColor Yellow }
$rm = @(Get-ChildItem (Join-Path $bm "_catalog\removed") -File -ErrorAction SilentlyContinue).Count
Write-Host "  відкладених файлів у копії _catalog\removed: $rm"
Write-Host ("  вільно на диску: {0:N2} ГБ" -f ((Get-PSDrive ((Get-Item $Dest).PSDrive.Name)).Free/1GB))
Set-Content -Path (Join-Path $root "_backup_stamp.txt") -Value ("{0}  сторінок {1}, розбіжностей {2}" -f (Get-Date).ToString("s"), $ok, ($bad.Count + $stale.Count)) -Encoding UTF8
if ($bad.Count + $stale.Count) { exit 1 }
Write-Host "Копія повна й збігається з оригіналом." -ForegroundColor Green
# явний код: інакше скрипт віддає $LASTEXITCODE останнього robocopy (1 = «скопійовано», не помилка)
exit 0
