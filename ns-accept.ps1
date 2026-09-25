# Приймання номера одразу після сканування (станція 1a конвеєра, КОНВЕЄР.md).
#
#   .\ns-accept.ps1 -Seq 2370            технічна перевірка + підвали всіх сторінок; Enter — прийнято
#   .\ns-accept.ps1 -Seq 2370 -NoPrompt  лише перевірка й підсумок (стан не змінюється)
#   .\ns-accept.ps1 -Seq 2370 -NoView    без вікна на другому моніторі
#
# Викликається з ns-scan після Q (вимкнути: ns-scan -NoAccept) і з меню («Прийняти номер»).
# Що робить:
#   1. ns-acceptcheck.py: кадри (1 на сторінку), розмір, порожні/чорні, дублі КОЖНОЇ з КОЖНОЮ;
#   2. кількість сторінок проти заявленої й проти звичної для року (за реєстром);
#   3. на верхньому моніторі — смуга підвалів усіх сторінок: оператор дивиться, що друковані
#      номери йдуть по порядку й збігаються з номерами файлів;
#   4. Enter — прийнято (state = accepted у маніфесті); номер(и) сторінок через кому — перезняти
#      (ns-rescan) і перевірити знову; Q — не приймати зараз.
# Прийняття з зауваженнями — лише після явного «y». Кількість сторінок, що відрізняється від
# заявленої, оператор підтверджує окремо (тоді pages_expected = фактична, статус scanned).
# Коди виходу: 0 — прийнято (або -NoPrompt без помилок), 2 — не прийнято.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [switch]$NoPrompt,
    [switch]$NoView,
    [int]$Width = 4693,
    [int]$Height = 6583
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$line = "-" * 74
$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено в каталозі." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
if (-not $man -or @($man.pages).Count -eq 0) { Write-Host "У номері $Seq немає сторінок." -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Path $script:NS_LIVE -Force | Out-Null
$sheet = Join-Path $script:NS_LIVE "preview.jpg"
$json = Join-Path $script:NS_LIVE "accept.json"

# вікно перегляду: якщо ns-scan його вже відкрив — користуємось ним; ні — відкриваємо своє
$ownViewer = $false
if (-not $NoView) {
    $viewerUp = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -match 'ns-viewer\.ps1' }).Count -gt 0
    if (-not $viewerUp) {
        Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", "`"$(Join-Path $PSScriptRoot 'ns-viewer.ps1')`"", "-ParentPid", "$PID")
        $ownViewer = $true
        Start-Sleep -Milliseconds 800
    }
}

function Get-NsUsualPages {
    <#  Скільки сторінок у номерах цього року за реєстром: звичайне число й скільки номерів його мають. #>
    param([int]$Year, [int]$ExceptSeq)
    $rows = @(Read-NsRegistry | Where-Object { [int]$_.year -eq $Year -and [int]$_.seq_first -ne $ExceptSeq -and [int]$_.pages -gt 0 })
    if ($rows.Count -eq 0) { return $null }
    $g = @($rows | Group-Object { [int]$_.pages } | Sort-Object Count -Descending)[0]
    [pscustomobject]@{ pages = [int]$g.Name; have = $g.Count; of = $rows.Count }
}

function Invoke-NsAcceptCheck {
    <#  Повертає @{ Pages; Flags; Count }. Малює аркуш підвалів у preview.jpg і сповіщає перегляд. #>
    param($Man)
    $py = if ($script:PYTHON) { $script:PYTHON } else { "python" }
    $null = & $py "$PSScriptRoot\ns-acceptcheck.py" $issueDir --out $sheet --json $json --width $Width --height $Height 2>&1
    if (-not (Test-Path $json)) { throw "ns-acceptcheck.py не дав звіту" }
    $rep = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
    $count = @($rep.pages).Count
    $flags = @($rep.flags | ForEach-Object { @{ lvl = $_.lvl; text = $_.text } })
    if ($count -ne [int]$Man.pages_expected) {
        $flags += @{ lvl = "err"; text = "сторінок $count, а заявлено $($Man.pages_expected)" }
    }
    $u = Get-NsUsualPages -Year ([int]$Man.year) -ExceptSeq ([int]$Man.seq_first)
    if ($u -and $count -ne $u.pages) {
        $flags += @{ lvl = "warn"; text = "у $($Man.year) р. зазвичай $($u.pages) стор. ($($u.have) з $($u.of) номерів), тут $count" }
    }
    $ins = if ($Man.PSObject.Properties.Name -contains 'insert_pages') { [string]$Man.insert_pages } else { "" }
    if (-not $NoView) {
        Write-NsLiveState -State @{
            status = "ready"; seq = $Man.seq_first; page = $count; expected = $count
            dims = "приймання"; frames = 1
            expect = "Підвали всіх $count сторінок — друковані номери мають іти по порядку й збігатися з підписом «файл pNN»" + $(if ($ins) { " (вкладка $ins має свою нумерацію)" } else { "" })
            warnings = $flags; checking = $false; next = $count + 1
        }
    }
    return @{ Rep = $rep; Flags = $flags; Count = $count }
}

$accepted = $false
while ($true) {
    Write-Host ""
    Write-Host "  ПРИЙМАННЯ НОМЕРА $Seq" -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor DarkGray
    Write-Host "  Перевіряю кадри, розмір, порожні, дублі; складаю підвали…" -ForegroundColor DarkGray
    $man = Read-NsManifest -IssueDir $issueDir
    try { $res = Invoke-NsAcceptCheck -Man $man } catch { Write-Host "  ПОМИЛКА перевірки: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

    Write-Host ""
    Write-Host ("  {0} ({1}, № {2} у році): {3} сторінок" -f $man.seq_first, $man.date, $man.issue_no_in_year, $res.Count)
    foreach ($p in $res.Rep.pages) {
        Write-Host ("    стор. {0,2}   {1}x{2}   кадрів {3}   яскравість {4:N2}   розкид {5:N3}" -f `
                    $p.n, $p.w, $p.h, $p.frames, $p.mean, $p.sd) -ForegroundColor DarkGray
    }
    Write-Host ""
    $errs = @($res.Flags | Where-Object { $_.lvl -eq "err" })
    if ($res.Flags.Count -eq 0) {
        Write-Host "  Технічних зауважень немає." -ForegroundColor Green
    } else {
        foreach ($f in $res.Flags) {
            Write-Host "  [!] $($f.text)" -ForegroundColor $(if ($f.lvl -eq "err") { "Red" } else { "Yellow" })
        }
    }
    Write-Host ""
    if ($NoPrompt) {
        Write-Host "  (-NoPrompt: стан не змінено.)" -ForegroundColor DarkGray
        if ($ownViewer) { Set-NsLiveStatus -Status "done" }
        exit $(if ($errs.Count -gt 0) { 2 } else { 0 })
    }

    Write-Host "  Дивись підвали на верхньому моніторі: друкований номер має збігатися з номером файлу." -ForegroundColor White
    Write-Host "    Enter        — прийнято"
    Write-Host "    5  або  3,7  — перезняти сторінку(и) з таким номером файлу"
    Write-Host "    Q            — не приймати зараз (номер лишається «scanned»)"
    $ans = (Read-Host "  Вибір").Trim()

    if ($ans -match '^[QqКк]') { break }

    if ($ans -match '^\d+(\s*,\s*\d+)*$') {
        foreach ($pn in @($ans -split '\s*,\s*' | ForEach-Object { [int]$_ })) {
            Write-Host ""
            Write-Host "  Перезнімаю сторінку $pn…" -ForegroundColor Cyan
            & "$PSScriptRoot\ns-rescan.ps1" -Seq $Seq -Page $pn -Reason "приймання: оператор попросив перезняти"
        }
        continue                                        # перевіряємо знову вже з новими файлами
    }

    if ($ans -ne "") { Write-Host "  Не зрозумів." -ForegroundColor Yellow; continue }

    # Enter — прийняти
    if ($errs.Count -gt 0) {
        $y = Read-Host "  Є помилки в перевірці. Прийняти все одно? [y/N]"
        if ($y -notmatch '^[YyТт]') { continue }
    }
    $note = "оператор підтвердив підвали"
    if ($res.Count -ne [int]$man.pages_expected) {
        $y = Read-Host ("  Сторінок {0}, а заявлено {1}. {0} — правильно? [y/N]" -f $res.Count, $man.pages_expected)
        if ($y -notmatch '^[YyТт]') { continue }
        $man.pages_expected = $res.Count
        $man.status = "scanned"
        $note += "; кількість сторінок $($res.Count) підтверджена"
    }
    if ($errs.Count -gt 0) { $note += "; прийнято попри зауваження: " + (($errs | ForEach-Object { $_.text }) -join " | ") }
    Set-NsIssueState -IssueDir $issueDir -Manifest $man -State "accepted" -Note $note
    Write-Host ""
    Write-Host "  Номер $Seq ПРИЙНЯТО (state = accepted). Обробка піде без тебе; на огляд він прийде, якщо буде що показати." -ForegroundColor Green
    $accepted = $true
    break
}

if ($ownViewer) { Set-NsLiveStatus -Status "done" }
exit $(if ($accepted) { 0 } else { 2 })
