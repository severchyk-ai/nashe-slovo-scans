# Примітка до номера в маніфест (поле notes) — особливість оригіналу, рішення оператора тощо.
#
#   .\ns-note.ps1 -Seq 2376 -Text "у підвалах парних стор. надруковано № 7 (2375) — помилка газети"
#   .\ns-note.ps1 -Seq 2376                 показати, що записано
#
# Навіщо (30.09.2026): маніфест руками не правимо, а особливості паперу (друкарська
# помилка в підвалі, вклеєний аркуш) мають лишатися поруч із майстрами, щоб наступна
# перевірка не «виправляла» оригінал. Поле notes — рядок (так було в 2214, 2235,
# 2237, 2265); нова примітка дописується з датою через « | ». Сторінки не змінюються:
# хеші звіряються до й після запису; журнал _catalog\logs\note.log.

param([Parameter(Mandatory = $true)][int]$Seq, [string]$Text = "")

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$has = $man.PSObject.Properties.Name -contains 'notes' -and $man.notes
if (-not $Text.Trim()) {
    if ($has) { Write-Host "Примітки номера ${Seq}:"; ($man.notes -split ' \| ') | ForEach-Object { Write-Host "  $_" } }
    else { Write-Host "Приміток у номері $Seq немає." }
    exit 0
}

function Test-AllPages {
    $bad = 0
    foreach ($p in $man.pages) { if (-not (Test-NsPageDurable -IssueDir $issueDir -PageEntry $p)) { $bad++; Write-Host "  ! $($p.file)" -ForegroundColor Red } }
    return $bad
}
if ((Test-AllPages) -gt 0) { Write-Host "Сторінки не збігаються з маніфестом — примітку НЕ записано." -ForegroundColor Red; exit 1 }

$entry = "[{0}] {1}" -f (Get-Date -Format "dd.MM.yyyy"), $Text.Trim()
$new = if ($has) { "$($man.notes) | $entry" } else { $entry }
$man | Add-Member -NotePropertyName notes -NotePropertyValue $new -Force
Write-NsManifest -IssueDir $issueDir -Manifest $man
$man = Read-NsManifest -IssueDir $issueDir
if ((Test-AllPages) -gt 0) { Write-Host "Після запису сторінки не збігаються — перевірити!" -ForegroundColor Red; exit 1 }
Add-Content -Path (Join-Path $script:LOGS "note.log") -Encoding UTF8 -Value ("{0}  {1}  {2}" -f (Get-Date).ToString("s"), $Seq, $Text.Trim())
Write-Host "Номер ${Seq}: примітку записано ($(@($man.pages).Count) стор., хеші до й після збігаються)." -ForegroundColor Green
Write-Host "  $entry"
