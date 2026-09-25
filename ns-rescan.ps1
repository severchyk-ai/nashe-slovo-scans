# Пересканувати одну сторінку вже відсканованого номера й замінити майстер.
#
#   .\ns-rescan.ps1 -Seq 2266 -Page 8 -Reason "розрізано на 2 кадри"
#   .\ns-rescan.ps1 -Seq 2267 -Page 4 -FromFile "C:\NS_MASTERS\_catalog\removed\....tif" -Reason "..."
#
# Аркуш має вже лежати на склі: скрипт сканує одразу, без запитань.
# -FromFile: не сканувати, а взяти вже готовий скан (напр. аркуш, помилково
# знятий під чужим номером і відкладений у removed). Файл ПЕРЕНОСИТЬСЯ, а не
# копіюється; якщо перевірка не пройде — повертається туди, звідки взятий.
# ⚠︎ Скрипт перевіряє форму скану (кадри, розмір), але НЕ вміст: що на скані
# саме ця сторінка, підтверджує людина.
#
# Майстри незмінні, тож заміна — це НЕ перезапис:
#   1. новий скан пишеться в _incoming і перевіряється: читається, рівно
#      ОДИН кадр, розмір схожий на газетний аркуш;
#   2. якщо перевірка не пройшла — старий майстер лишається як є, новий
#      файл видаляється, нічого не змінено;
#   3. якщо пройшла — старий майстер ПЕРЕНОСИТЬСЯ в _catalog\removed (як
#      відкладений кадр 2240), новий стає на його ім'я, read-only, хеш;
#   4. маніфест: нові sha256/bytes/scanned_at, а в полі replaced — старий хеш,
#      куди відкладено старий файл, коли й чому. Суми, реєстр, _scan.log.
# Ім'я файлу сторінки не змінюється.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][int]$Page,
    [string]$Reason = "",
    [string]$FromFile = ""
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if ($FromFile) {
    if (-not (Test-Path -LiteralPath $FromFile)) { Write-Host "Немає файлу $FromFile" -ForegroundColor Red; exit 1 }
} elseif (-not (Test-NsTools -Need scan)) { Write-Host "Бракує інструментів — зупинка." -ForegroundColor Red; exit 1 }

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$entry = @($man.pages | Where-Object { [int]$_.n -eq $Page })
if ($entry.Count -ne 1) { Write-Host "Сторінки $Page у маніфесті номера $Seq немає." -ForegroundColor Red; exit 1 }
$entry = $entry[0]
$master = Join-Path $issueDir $entry.file

# Замінювати можна лише те, що точно є тим, за що себе видає.
if (-not (Test-NsPageDurable -IssueDir $issueDir -PageEntry $entry)) {
    Write-Host "Старий майстер $($entry.file) не збігається з маніфестом або не read-only — розібратися вручну." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Пересканування: номер $Seq, сторінка $Page ($($entry.file))" -ForegroundColor Cyan
if ($FromFile) { Write-Host "  джерело: $FromFile (без сканування)" }
else           { Write-Host "  профіль: $script:NAPS2_PROFILE" }

# --- 1. скан або готовий файл ----------------------------------------------
$tmp = Join-Path $issueDir ("_incoming_p{0:D2}.tif" -f $Page)
if (Test-Path $tmp) { Remove-Item $tmp -Force }
if ($FromFile) {
    Move-Item -LiteralPath $FromFile -Destination $tmp
} else {
    & $script:NAPS2 -p $script:NAPS2_PROFILE -o $tmp --tiffcomp lzw 2>&1 | Out-Null
}

function Stop-Rescan([string]$Why) {
    Write-Host "  [!] $Why" -ForegroundColor Yellow
    Write-Host "  Старий майстер НЕ змінено." -ForegroundColor Yellow
    if (Test-Path $tmp) {
        if ($FromFile) {
            Move-Item -LiteralPath $tmp -Destination $FromFile
            Write-Host "  Файл повернуто: $FromFile" -ForegroundColor Yellow
        } else {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    exit 1
}

if (-not (Test-Path $tmp)) { Stop-Rescan "Скан не вдався (сканер міг заснути) — повторити." }

# --- 2. перевірка ----------------------------------------------------------
$frames = Get-NsFrameCount -Path $tmp
if ($frames -ne 1) { Stop-Rescan "Скан розпався на $frames кадрів — обрізка сканера знову розрізала аркуш." }

$wh = (& magick identify -ping -format "%w|%h|%x" $tmp 2>$null) -split '\|'
if ($wh.Count -lt 3) { Stop-Rescan "Файл не читається." }
$dpi = [double]$wh[2]; if ($dpi -le 0) { $dpi = 400 }
$mmA = [int]$wh[0] / $dpi * 25.4; $mmB = [int]$wh[1] / $dpi * 25.4
$short = [math]::Min($mmA, $mmB); $long = [math]::Max($mmA, $mmB)
# Майстри річників 2000-2001: 297-303 x 413-421 мм. Допуск із запасом,
# але 5-сантиметрової втрати, як у 2266 стор. 8 (369 мм), не пропустить.
if ($short -lt 285 -or $short -gt 315 -or $long -lt 405 -or $long -gt 430) {
    Stop-Rescan ("Розмір {0:N1} x {1:N1} мм не схожий на газетний аркуш (очікувано ~298 x 418)." -f $mmA, $mmB)
}
$probe = "{0}x{1}" -f $wh[0], $wh[1]
Write-Host ("  новий скан: {0}, {1:N1} x {2:N1} мм, один кадр" -f $probe, $mmA, $mmB) -ForegroundColor Green

# --- 3. відкласти старий, поставити новий -----------------------------------
$removedDir = Join-Path $script:CATALOG "removed"
if (-not (Test-Path $removedDir)) { New-Item -ItemType Directory -Path $removedDir -Force | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$parked = Join-Path $removedDir ("{0}_replaced_{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($entry.file), $stamp, [IO.Path]::GetExtension($entry.file))

$oldSha = $entry.sha256; $oldBytes = $entry.bytes
Move-Item -LiteralPath $master -Destination $parked
if ((Get-NsHash $parked) -ne $oldSha) {
    # Неможливо в нормі; але якщо так — нічого далі не чіпати.
    Write-Host "  [!] Відкладений файл не збігся з хешем старого майстра. Зупинка; новий скан лишено в $tmp" -ForegroundColor Red
    exit 1
}
Move-Item -LiteralPath $tmp -Destination $master
Set-ItemProperty -Path $master -Name IsReadOnly -Value $true

# --- 4. маніфест, суми, реєстр, журнал -------------------------------------
$now = (Get-Date).ToString("s")
$entry.sha256     = Get-NsHash $master
$entry.bytes      = (Get-Item $master).Length
$entry.scanned_at = $now
$note = [pscustomobject]@{
    at         = $now
    old_sha256 = $oldSha
    old_bytes  = $oldBytes
    parked_as  = "_catalog\removed\" + [IO.Path]::GetFileName($parked)
    reason     = $Reason
}
$hist = @()
if ($entry.PSObject.Properties.Name -contains 'replaced') { $hist = @($entry.replaced) }
$hist += $note
$entry | Add-Member -NotePropertyName replaced -NotePropertyValue $hist -Force
Write-NsManifest -IssueDir $issueDir -Manifest $man

$sumFile = Join-Path $script:CHECKSUMS "$($man.seq_first).sha256"
$lines = @(foreach ($p in $man.pages) { "$($p.sha256)  $($p.file)" })
[IO.File]::WriteAllLines($sumFile, $lines, [Text.UTF8Encoding]::new($false))

$bytesAll = [long](@($man.pages) | Measure-Object -Property bytes -Sum).Sum
Set-NsRegistryRow -Manifest $man -Status $man.status -Bytes $bytesAll
Set-NsLastScanTime

# Похідні номера зроблені зі СТАРОГО майстра. ns-prep пропускає сторінки, для
# яких вихід «вже є», тож без цього збірка тихо взяла б стару сторінку —
# 16.09.2026 так і сталося: після заміни 2266 стор. 8 prep підхопив обробку
# розрізаного скану. NS_WORK за визначенням відтворюваний, втрачати нічого.
$work = Join-Path $script:NS_WORK "$Seq"
if (Test-Path $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
    Write-Host "  прибрано застарілі похідні: $work"
}

Add-Content -Path (Join-Path $issueDir "_scan.log") -Encoding UTF8 -Value (
    "{0}  стор {1:D2}  ЗАМІНА  {2}  {3} байт  {4}  (старий {5} -> {6}; {7})" -f `
    $now, $Page, $probe, $entry.bytes, $entry.sha256, $oldSha, [IO.Path]::GetFileName($parked), $Reason)

# Перевірка результату тим самим правилом, що й скрізь.
if (Test-NsPageDurable -IssueDir $issueDir -PageEntry $entry) {
    Write-Host "  замінено: $($entry.file)  ($([math]::Round($entry.bytes/1MB,1)) МБ)" -ForegroundColor Green
    Write-Host "  старий відкладено: $parked"
    exit 0
}
Write-Host "  [!] Після заміни сторінка не проходить перевірку надійності — розібратися." -ForegroundColor Red
exit 1
