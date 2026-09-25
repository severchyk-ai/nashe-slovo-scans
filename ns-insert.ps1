# Позначити сторінки вкладки зі СВОЄЮ нумерацією («Світанок», календар тощо).
#
#   .\ns-insert.ps1 -Seq 2332 -Pages "3-8"     позначити
#   .\ns-insert.ps1 -Seq 2332 -Clear           прибрати позначку
#   .\ns-insert.ps1 -Seq 2332                  показати, що записано
#
# Навіщо: вкладка має власну нумерацію сторінок, а основний блок після неї її
# пропускає. Без цього підказка під час сканування стабільно бреше: у 2332
# файл 15 має друковану 9, бо між ними шість сторінок вкладки (оператор,
# 23.09.2026). Запис іде в маніфест (insert_pages) і діє на всі подальші
# сканування та перезбірки номера.

param([Parameter(Mandatory = $true)][int]$Seq, [string]$Pages, [switch]$Clear)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$has = $man.PSObject.Properties.Name -contains 'insert_pages'

if ($Clear) {
    if ($has) { $man.PSObject.Properties.Remove('insert_pages'); Write-NsManifest -IssueDir $issueDir -Manifest $man }
    Write-Host "Позначку вкладки прибрано." -ForegroundColor Green
    exit 0
}
if (-not $Pages) {
    if ($has) { Write-Host "Вкладка номера ${Seq}: сторінки $($man.insert_pages)" } else { Write-Host "Вкладки не позначено." }
    exit 0
}
if ($Pages -notmatch '^\s*(\d+)\s*-\s*(\d+)\s*$') {
    Write-Host "Формат: -Pages `"3-8`"" -ForegroundColor Red; exit 1
}
$from = [int]$Matches[1]; $to = [int]$Matches[2]
$cnt = @($man.pages).Count
if ($from -lt 1 -or $to -lt $from) { Write-Host "Межі вкладки неправильні." -ForegroundColor Red; exit 1 }
if ($cnt -and $to -gt [math]::Max($cnt, [int]$man.pages_expected)) {
    Write-Host "УВАГА: у номері $cnt сторінок, а вкладка вказана до $to." -ForegroundColor Yellow
}
$man | Add-Member -NotePropertyName insert_pages -NotePropertyValue ("{0}-{1}" -f $from, $to) -Force
Write-NsManifest -IssueDir $issueDir -Manifest $man
$len = $to - $from + 1
Write-Host "Номер ${Seq}: вкладка на сторінках $from-$to ($len аркушів)." -ForegroundColor Green
Write-Host "Підказка під час сканування тепер рахуватиме так:"
foreach ($p in @(($from - 1), $from, $to, ($to + 1), ($to + 2)) | Where-Object { $_ -ge 1 -and $_ -le [int]$man.pages_expected }) {
    if ($p -ge $from -and $p -le $to) {
        Write-Host ("  файл {0,2} — вкладка, {1}-та сторінка вкладки" -f $p, ($p - $from + 1))
    } else {
        $pr = if ($p -gt $to) { $p - $len } else { $p }
        $side = if ($pr % 2 -eq 0) { "ліворуч" } else { "праворуч" }
        Write-Host ("  файл {0,2} — друкована «{1}», {2} унизу" -f $p, $pr, $side)
    }
}
