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
#      (ns-rescan) і перевірити знову; +N — вставити пропущений аркуш (ns-insertpage, лише з «+»,
#      по одній); -N — прибрати зайву сторінку (ns-droppage, з підтвердженням); V a-b — позначити
#      вкладку (ns-insert), V - — прибрати; Q — не приймати зараз.
#      Біля кожної смуги й у консолі — очікуваний друкований номер з поправкою на вкладку.
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
    $ins = if ($Man.PSObject.Properties.Name -contains 'insert_pages') { [string]$Man.insert_pages } else { "" }
    # вкладка має свої аркуші: 2373 — 10 + 6 вкладки = 16, і тривога «зазвичай 10, тут 16» була хибна
    $insLen = 0
    if ($ins -match '^\s*(\d+)\s*-\s*(\d+)\s*$') { $insLen = [int]$Matches[2] - [int]$Matches[1] + 1 }
    $u = Get-NsUsualPages -Year ([int]$Man.year) -ExceptSeq ([int]$Man.seq_first)
    if ($u -and $count -ne $u.pages -and ($count - $insLen) -ne $u.pages) {
        $t = "у $($Man.year) р. зазвичай $($u.pages) стор. ($($u.have) з $($u.of) номерів), тут $count"
        if ($insLen) { $t += " (з них вкладка $ins — $insLen)" }
        $flags += @{ lvl = "warn"; text = $t }
    }
    if (-not $NoView) {
        Write-NsLiveState -State @{
            status = "ready"; seq = $Man.seq_first; page = $count; expected = $count
            dims = "приймання"; frames = 1
            expect = "Підвали всіх $count сторінок — друкований номер має збігатися з тим, що в підписі «pNN → …»" + $(if ($ins) { " (вкладка ${ins}: чотири кути довгих боків — номер у парі, що читається прямо)" } else { "" })
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
        Write-Host ("    стор. {0,2}   {1}x{2}   кадрів {3}   яскравість {4:N2}   розкид {5:N3}   → {6}" -f `
                    $p.n, $p.w, $p.h, $p.frames, $p.mean, $p.sd, $p.expect) -ForegroundColor DarkGray
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
    Write-Host "    5  або  3,7  — перезняти сторінку(и) з таким номером файлу (вона вже є, вміст поганий)"
    Write-Host "    +5           — вставити сторінку 5, якої ще немає (пропущений аркуш) — наступні самі зсунуться"
    Write-Host "    -11          — прибрати зайву сторінку 11 (той самий аркуш удруге), наступні підтягнуться"
    Write-Host "    V 3-8        — вкладка зі своєю нумерацією на файлах 3-8 (V - — прибрати позначку)"
    Write-Host "    Q            — не приймати зараз (номер лишається «scanned»)"
    # натиснуте під час перевірки (кілька секунд) не має стати відповіддю: Enter тут — «прийнято»
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
    $ans = (Read-Host "  Вибір").Trim()

    # -N — прибрати зайву сторінку (30.09.2026, 2374: p11 — подвійний Enter, тут її не було чим прибрати).
    # Майстер не знищується: ns-droppage кладе його в _catalog\removed; лише з підтвердженням.
    if ($ans -match '^-\s*(\d+)$') {
        $dn = [int]$Matches[1]
        $existing = @($man.pages | ForEach-Object { [int]$_.n })
        if ($existing -notcontains $dn) { Write-Host "  Сторінки $dn у номері немає (є 1-$($existing.Count))." -ForegroundColor Yellow; continue }
        $y = Read-Host "  Прибрати сторінку $dn (файл p$('{0:D2}' -f $dn)) і підтягнути наступні? [y/N]"
        if ($y -match '^[YyТт]') {
            & "$PSScriptRoot\ns-droppage.ps1" -Seq $Seq -Page $dn -Reason "приймання: оператор прибрав зайву сторінку"
        }
        continue
    }

    if ($ans -match '^[QqКк]') { break }

    # вкладку часто помічають саме тут, на аркуші підвалів (оператор, 30.09.2026) —
    # те саме, що клавіша V у ns-scan / ns-insert.ps1; очікувані номери перерахуються
    if ($ans -match '^[VvМм]\s*(.*)$') {
        $arg = $Matches[1].Trim()
        if ($arg -eq '-' -or $arg -eq '0') { & "$PSScriptRoot\ns-insert.ps1" -Seq $Seq -Clear }
        elseif ($arg -match '^(\d+)\s*-\s*(\d+)$') { & "$PSScriptRoot\ns-insert.ps1" -Seq $Seq -Pages "$($Matches[1])-$($Matches[2])" }
        else { Write-Host "  Вкладка: «V 3-8» (файли з 3-го по 8-й) або «V -» — прибрати." -ForegroundColor Yellow }
        continue
    }

    if ($ans -match '^[+\d][\d,+\s]*$' -and $ans -match '\d') {
        # Сторінка, якої ще немає в маніфесті, — це не заміна, а бракуюча сторінка
        # (напр. пропущений при скануванні аркуш): ns-rescan вимагає ІСНУЮЧОЇ
        # сторінки. 29.09.2026: 2372 — п'яту пропустили, і без вставки кожна
        # заміна лише зсувала «зайву» на одну далі (5→6→7→8→9), а десяту не було
        # чим замінити, бо такої сторінки не існувало. Тепер за + йде
        # ns-insertpage (вставляє й сам зсуває решту, як ns-droppage навпаки).
        # 30.09.2026 (перегляд інструментів): вставка — ЛИШЕ з явним «+». Голе
        # число сторінки, якої немає (друкарська «11» у номері з 10), раніше
        # мовчки запускало сканер і дописувало аркуш — тепер відмова з підказкою.
        # «5+3», «5 3» — не зрозуміло (раніше падало на [int]). Вставка — по
        # одній у рядку: після неї номери наступних файлів зсуваються, і решта
        # рядка вказувала б уже не на ті сторінки, які оператор бачив на аркуші.
        $toks = @($ans -split '\s*,\s*' | Where-Object { $_ })
        if (@($toks | Where-Object { $_ -notmatch '^\+?\d+$' }).Count) { Write-Host "  Не зрозумів: пиши «5», «3,7» або «+5»." -ForegroundColor Yellow; continue }
        $items = @($toks | ForEach-Object { [pscustomobject]@{ Insert = $_.StartsWith('+'); N = [int]($_.TrimStart('+')) } })
        if (@($items | Where-Object { $_.Insert }).Count -and $items.Count -gt 1) {
            Write-Host "  Вставку (+N) — окремо, по одній: після неї номери наступних файлів зсуваються." -ForegroundColor Yellow; continue
        }
        $existing = @($man.pages | ForEach-Object { [int]$_.n })
        $absent = @($items | Where-Object { -not $_.Insert -and $existing -notcontains $_.N })
        if ($absent.Count) {
            Write-Host ("  Сторінки {0} у номері немає (є 1-{1}). Пропущений аркуш — введи +{0}: вставиться, наступні зсунуться." -f $absent[0].N, $existing.Count) -ForegroundColor Yellow
            continue
        }
        foreach ($it in $items) {
            if ($it.Insert) {
                Write-Host ""
                Write-Host "  Сторінка $($it.N) вставляється як бракуюча (поклади аркуш на скло)…" -ForegroundColor Cyan
                & "$PSScriptRoot\ns-insertpage.ps1" -Seq $Seq -Page $it.N -Reason "приймання: оператор поклав пропущений аркуш"
            } else {
                Write-Host ""
                Write-Host "  Перезнімаю сторінку $($it.N)…" -ForegroundColor Cyan
                & "$PSScriptRoot\ns-rescan.ps1" -Seq $Seq -Page $it.N -Reason "приймання: оператор попросив перезняти"
            }
            $man = Read-NsManifest -IssueDir $issueDir   # для правильної перевірки наступного номера в цьому ж рядку
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
