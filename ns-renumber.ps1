# Виправити нумерацію майстрів номера, коли сторінки відскановано не в тому
# порядку (помилка оператора, НЕ календарна вкладка — для вкладок є page_order).
#
#   .\ns-renumber.ps1 -Seq 2314 -Order "1,2,3,5,4,6,7,8,9,10" -Reason "..."
#   .\ns-renumber.ps1 -Seq 2314 -Order "..." -DryRun      лише показати план
#
# -Order: число на позиції K — номер НИНІШНЬОГО файлу, який має стати сторінкою K.
# Приклад 2294: друкована стор. 3 лежить у p10, а p03..p09 — це стор. 4..10:
#   -Order "1,2,10,3,4,5,6,7,8,9"
#
# Вміст файлів не змінюється — лише імена. Хеш і розмір їдуть разом із вмістом,
# у маніфесті в сторінки лишається запис renamed_from (старе ім'я, дата, причина).
# Порядок дій: звірити всі хеші -> план у _renumber.json -> тимчасові імена ->
# остаточні імена -> маніфест -> суми -> read-only -> повторна звірка всіх хешів.
# Якщо обірветься посередині, _renumber.json у теці номера каже, що де лежить.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][string]$Order,
    [string]$Reason = "сторінки відскановано не в тому порядку",
    [switch]$DryRun
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$pages = @($man.pages | Sort-Object { [int]$_.n })
$cnt = $pages.Count

$ord = @($Order -split ',' | ForEach-Object { [int]$_.Trim() })
if ($ord.Count -ne $cnt -or (($ord | Sort-Object) -join ',') -ne ((1..$cnt) -join ',')) {
    Write-Host "-Order має містити кожне число з 1..$cnt рівно раз." -ForegroundColor Red; exit 1
}
if ((($ord) -join ',') -eq ((1..$cnt) -join ',')) { Write-Host "Порядок не змінюється." -ForegroundColor Yellow; exit 0 }

# ключі, прив'язані до номерів сторінок, довелося б перерахувати — не вгадуємо
foreach ($k in 'page_order', 'page_rotate', 'page_edge') {
    if ($man.PSObject.Properties.Name -contains $k -and $man.$k) {
        Write-Host "У маніфесті є '$k' ($($man.$k)) — він прив'язаний до номерів сторінок. Спершу вирішити, як його перерахувати." -ForegroundColor Red
        exit 1
    }
}
if (@(Find-NsOrphans -IssueDir $issueDir -Manifest $man).Count) {
    Write-Host "У теці є файли поза маніфестом — спершу розібратися з ними." -ForegroundColor Red; exit 1
}

Write-Host "Номер $Seq ($issueDir)"
Write-Host "Звіряю хеші всіх $cnt сторінок перед перейменуванням..."
foreach ($p in $pages) {
    $f = Join-Path $issueDir $p.file
    if (-not (Test-Path $f) -or (Get-NsHash $f) -ne $p.sha256) {
        Write-Host "  $($p.file): хеш не збігається з маніфестом — зупинка, нічого не змінено." -ForegroundColor Red; exit 1
    }
}

$plan = @()
for ($k = 1; $k -le $cnt; $k++) {
    $src = $pages[$ord[$k - 1] - 1]
    $dst = Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page $k
    $plan += [pscustomobject]@{ n = $k; from = $src.file; to = $dst; sha256 = $src.sha256 }
    $mark = if ($src.file -ne $dst) { "->" } else { "  " }
    Write-Host ("  {0} {1} {2}" -f $src.file, $mark, $dst)
}
if ($DryRun) { Write-Host "DryRun: нічого не змінено."; exit 0 }

$journal = Join-Path $issueDir "_renumber.json"
$plan | ConvertTo-Json -Depth 5 | Set-Content -Path $journal -Encoding UTF8

$moving = @($plan | Where-Object { $_.from -ne $_.to })
foreach ($m in $moving) {
    $f = Join-Path $issueDir $m.from
    Set-ItemProperty -Path $f -Name IsReadOnly -Value $false
    Rename-Item -LiteralPath $f -NewName "$($m.from).renum_tmp"
}
foreach ($m in $moving) {
    Rename-Item -LiteralPath (Join-Path $issueDir "$($m.from).renum_tmp") -NewName $m.to
}

$stamp = (Get-Date).ToString("s")
$newPages = @()
foreach ($pl in $plan) {
    $src = @($pages | Where-Object { $_.file -eq $pl.from })[0]
    $e = $src.PSObject.Copy()
    $e.n = $pl.n; $e.file = $pl.to
    if ($pl.from -ne $pl.to) {
        $hist = @()
        if ($e.PSObject.Properties.Name -contains 'renamed_from') { $hist = @($e.renamed_from) }
        $hist += [pscustomobject]@{ file = $pl.from; at = $stamp; reason = $Reason }
        $e | Add-Member -NotePropertyName renamed_from -NotePropertyValue $hist -Force
    }
    $newPages += $e
}
$man.pages = $newPages
Write-NsManifest -IssueDir $issueDir -Manifest $man

$sumFile = Join-Path $script:CHECKSUMS "$($man.seq_first).sha256"
$lines = @(foreach ($p in $man.pages) { "$($p.sha256)  $($p.file)" })
[IO.File]::WriteAllLines($sumFile, $lines, [Text.UTF8Encoding]::new($false))

$bad = 0
foreach ($p in $man.pages) {
    $f = Join-Path $issueDir $p.file
    Set-ItemProperty -Path $f -Name IsReadOnly -Value $true
    if (-not (Test-NsPageDurable -IssueDir $issueDir -PageEntry $p)) { $bad++; Write-Host "  ! $($p.file) не пройшла звірку" -ForegroundColor Red }
}
if ($bad) { Write-Host "Звірка після перейменування: $bad розбіжностей. _renumber.json лишаю." -ForegroundColor Red; exit 1 }
Remove-Item $journal -Force

$bytesAll = [long](@($man.pages) | Measure-Object -Property bytes -Sum).Sum
Set-NsRegistryRow -Manifest $man -Status $man.status -Bytes $bytesAll

# похідні зроблені за старими іменами — прибрати, щоб збірка не взяла їх
$work = Join-Path $script:NS_WORK "$Seq"
if (Test-Path $work) { Remove-Item $work -Recurse -Force; Write-Host "Прибрано застарілі похідні: $work" }
$pdf = Join-Path (Join-Path $script:NS_PDF "$($man.year)") "$Seq.pdf"
if (Test-Path $pdf) { Write-Host "УВАГА: $pdf зібрано за старим порядком — перезібрати." -ForegroundColor Yellow }

$log = Join-Path $script:LOGS "renumber.log"
Add-Content -Path $log -Encoding UTF8 -Value ("{0}  {1}  -Order {2}  ({3})" -f $stamp, $Seq, ($ord -join ','), $Reason)
Write-Host ("Готово: перейменовано {0} файлів, усі {1} хешів збігаються." -f $moving.Count, $cnt) -ForegroundColor Green
