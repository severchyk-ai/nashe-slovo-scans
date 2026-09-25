# Прибрати зайву сторінку з номера й підтягнути нумерацію наступних.
#
#   .\ns-droppage.ps1 -Seq 2331 -Page 5 -Reason "повторно відскановано стор. 3"
#   .\ns-droppage.ps1 -Seq 2331 -Page 5 -DryRun        лише показати план
#
# Навіщо: під час сканування трапляється покласти на скло той самий аркуш
# удруге (2331: замість 5-ї сторінки вдруге знято 3-тю). Тоді в номері стає
# зайвий файл, а всі наступні зсунуті на одиницю.
#
# Майстер НЕ знищується: він переноситься в _catalog\removed з міткою часу,
# як відкладені кадри й замінені сторінки. Далі файли p06..pNN перейменовуються
# на p05..p(NN-1), маніфест, суми й реєстр оновлюються, похідні прибираються.
# Порядок: звірка всіх хешів -> план у _drop.json -> тимчасові імена ->
# остаточні -> маніфест -> суми -> read-only -> повторна звірка.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][int]$Page,
    [string]$Reason = "зайва сторінка (той самий аркуш удруге)",
    [switch]$DryRun
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$pages = @($man.pages | Sort-Object { [int]$_.n })
$cnt = $pages.Count
if ($Page -lt 1 -or $Page -gt $cnt) { Write-Host "У номері $Seq немає сторінки $Page." -ForegroundColor Red; exit 1 }

foreach ($k in 'page_order', 'page_rotate', 'page_edge') {
    if ($man.PSObject.Properties.Name -contains $k -and $man.$k) {
        Write-Host "У маніфесті є '$k' ($($man.$k)) — він прив'язаний до номерів сторінок." -ForegroundColor Red
        Write-Host "Спершу вирішити, як його перерахувати після вилучення сторінки." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Номер $Seq ($issueDir): $cnt сторінок"
Write-Host "Звіряю хеші перед зміною..."
foreach ($p in $pages) {
    $f = Join-Path $issueDir $p.file
    if (-not (Test-Path $f) -or (Get-NsHash $f) -ne $p.sha256) {
        Write-Host "  $($p.file): хеш не збігається з маніфестом — зупинка." -ForegroundColor Red; exit 1
    }
}

$drop = $pages[$Page - 1]
$plan = @()
for ($k = $Page + 1; $k -le $cnt; $k++) {
    $src = $pages[$k - 1]
    $dst = Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page ($k - 1)
    $plan += [pscustomobject]@{ n = $k - 1; from = $src.file; to = $dst }
}
Write-Host "  прибрати: $($drop.file)  ->  _catalog\removed" -ForegroundColor Yellow
foreach ($m in $plan) { Write-Host ("  {0} -> {1}" -f $m.from, $m.to) }
if ($DryRun) { Write-Host "DryRun: нічого не змінено."; exit 0 }

$journal = Join-Path $issueDir "_drop.json"
@{ drop = $drop.file; plan = $plan; at = (Get-Date).ToString("s") } | ConvertTo-Json -Depth 5 |
    Set-Content -Path $journal -Encoding UTF8

$removedDir = Join-Path $script:CATALOG "removed"
New-Item -ItemType Directory -Path $removedDir -Force | Out-Null
$dropFull = Join-Path $issueDir $drop.file
Set-ItemProperty -Path $dropFull -Name IsReadOnly -Value $false
$parked = Join-Path $removedDir ("{0}_dropped_{1}.tif" -f [IO.Path]::GetFileNameWithoutExtension($drop.file), (Get-Date).ToString("yyyyMMdd-HHmmss"))
Move-Item -Path $dropFull -Destination $parked -Force

foreach ($m in $plan) {
    $f = Join-Path $issueDir $m.from
    Set-ItemProperty -Path $f -Name IsReadOnly -Value $false
    Rename-Item -LiteralPath $f -NewName "$($m.from).drop_tmp"
}
foreach ($m in $plan) {
    Rename-Item -LiteralPath (Join-Path $issueDir "$($m.from).drop_tmp") -NewName $m.to
}

$stamp = (Get-Date).ToString("s")
$newPages = @()
foreach ($p in $pages) {
    if ([int]$p.n -eq $Page) { continue }
    $e = $p.PSObject.Copy()
    if ([int]$p.n -gt $Page) {
        $mv = @($plan | Where-Object { $_.from -eq $p.file })[0]
        $e.n = $mv.n; $e.file = $mv.to
        $hist = @()
        if ($e.PSObject.Properties.Name -contains 'renamed_from') { $hist = @($e.renamed_from) }
        $hist += [pscustomobject]@{ file = $mv.from; at = $stamp; reason = "після вилучення стор. $Page" }
        $e | Add-Member -NotePropertyName renamed_from -NotePropertyValue $hist -Force
    }
    $newPages += $e
}
$man.pages = $newPages
$hist2 = @()
if ($man.PSObject.Properties.Name -contains 'dropped') { $hist2 = @($man.dropped) }
$hist2 += [pscustomobject]@{ page = $Page; file = $drop.file; sha256 = $drop.sha256
                             parked = (Split-Path $parked -Leaf); at = $stamp; reason = $Reason }
$man | Add-Member -NotePropertyName dropped -NotePropertyValue $hist2 -Force
$man.status = if (@($man.pages).Count -eq $man.pages_expected) { "scanned" } else { "qc_flagged" }
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
if ($bad) { Write-Host "Після зміни $bad розбіжностей — _drop.json лишаю." -ForegroundColor Red; exit 1 }
Remove-Item $journal -Force

$bytesAll = [long](@($man.pages) | Measure-Object -Property bytes -Sum).Sum
Set-NsRegistryRow -Manifest $man -Status $man.status -Bytes $bytesAll

$work = Join-Path $script:NS_WORK "$Seq"
if (Test-Path $work) { Remove-Item $work -Recurse -Force; Write-Host "Прибрано застарілі похідні: $work" }

Add-Content -Path (Join-Path $script:LOGS "droppage.log") -Encoding UTF8 `
    -Value ("{0}  {1}  стор {2}  -> {3}  ({4})" -f $stamp, $Seq, $Page, (Split-Path $parked -Leaf), $Reason)
Write-Host ("Готово: сторінку {0} прибрано, {1} перейменовано, у номері {2} сторінок." -f $Page, $plan.Count, @($man.pages).Count) -ForegroundColor Green
