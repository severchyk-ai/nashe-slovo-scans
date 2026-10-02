# Пакет номерів з обмеженим паралелізмом: ns-prepare для кожного, або (-Full) повний шлях ns-full.
#
#   .\ns-prepare-batch.ps1 -Seq 2326,2327,2328,2329,2330,2331            за умовчанням 2 одночасно
#   .\ns-prepare-batch.ps1 -Seq 2326..2331 -Parallel 3
#   .\ns-prepare-batch.ps1 -Seq 2269..2279 -Full -Parallel 3             до готового PDF з OCR (ns-full)
#   .\ns-prepare-batch.ps1 -Seq 2269..2279 -Full -BuildOnly              підготовлені раніше — лише PDF з OCR
#
# Кожен номер — окремий процес (журнал NS_WORK\<N>\prepare.log, для -Full ще й full.log). Тут лише черга:
# коли один закінчується, стартує наступний. Скрипт нічого не змінює сам. Номери «лише вручну»
# (ns-manual.csv) пропускаються. Без -Full: PDF без OCR оператору, не більше двох неоглянутих пакетів
# наперед (правило головної, 25.09.2026). З -Full (рішення оператора 02.10.2026, варіант А): одразу готовий
# PDF з OCR; якщо pikepdf / ocrmypdf заблоковано Windows — номери ГОТУЮТЬСЯ далі (код 43), а збирання йде
# другим проходом, коли блокування мине (чекає до 6 год).

param(
    [Parameter(Mandatory = $true)][string[]]$Seq,
    [int]$Parallel = 2,
    [switch]$IncludeManual,     # брати й номери зі списку «лише вручну» (ns-manual.csv); без ключа вони пропускаються
    [switch]$Full,              # повний шлях ns-full: підготовка -> PDF з OCR -> перевірки -> full.json
    [switch]$BuildOnly,         # разом з -Full: підготовку вже зроблено — лише PDF з OCR і перевірки
    [switch]$KeepWork           # разом з -Full: не прибирати prep / render після успіху
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (($BuildOnly -or $KeepWork) -and -not $Full) { Write-Host "-BuildOnly і -KeepWork мають сенс лише з -Full." -ForegroundColor Red; exit 1 }

$list = @()
# з `powershell -File` список «2326,2327» приходить ОДНИМ рядком — розбити й тут (02.10.2026)
foreach ($s in @($Seq | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })) {
    if ($s -match '^(\d+)\.\.(\d+)$') { $list += [int]$Matches[1]..[int]$Matches[2] }
    elseif ($s -match '^\d+$') { $list += [int]$s }
    else { Write-Host "Не зрозумів номер: $s" -ForegroundColor Red; exit 1 }
}
$list = @($list | Select-Object -Unique)
# «лише вручну» (ns-manual.csv): пакет такі номери не чіпає
$manualSkipped = @()
if (-not $IncludeManual) {
    $manual = Get-NsManual
    foreach ($n in $list) { if ($manual.ContainsKey($n)) { $manualSkipped += $n; Write-Host ("  {0}: лише вручну — {1} — ПРОПУЩЕНО" -f $n, $manual[$n]) -ForegroundColor Yellow } }
    $list = @($list | Where-Object { $manualSkipped -notcontains $_ })
    if ($list.Count -eq 0) { Write-Host "У пакеті не лишилося номерів." -ForegroundColor Yellow; exit 0 }
}
# номера, якого немає в каталозі (2317), не запускати: окремий процес лише сказав би «не знайдено»
$absent = @($list | Where-Object { -not (Find-NsIssueDir -Seq $_) })
foreach ($n in $absent) { Write-Host ("  {0}: немає в каталозі — ПРОПУЩЕНО" -f $n) -ForegroundColor Yellow }
$list = @($list | Where-Object { $absent -notcontains $_ })
if ($list.Count -eq 0) { Write-Host "У пакеті не лишилося номерів." -ForegroundColor Yellow; exit 0 }

$t0 = Get-Date
$worker = if ($Full) { "ns-full.ps1" } else { "ns-prepare.ps1" }
$resultFile = if ($Full) { "full.json" } else { "prepare.json" }
$script:failed = @(); $script:stopped = @(); $script:notDone = @(); $script:pending = @(); $script:blocked = $false

function Test-NsBatchDone {
    <#  Чи лишив номер СВІЖИЙ результат цього прогону (старий json незробленого номера — не результат). #>
    param([int]$N)
    $f = Join-Path $script:NS_WORK "$N\$resultFile"
    if (-not (Test-Path $f) -or (Get-Item $f).LastWriteTime -le $t0) { return $false }
    if ($Full) { try { return ((Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).stage -eq "done") } catch { return $false } }
    return $true
}

function Invoke-NsBatchQueue {
    <#  Черга: не більше $Parallel процесів $worker водночас. WaitSet — які модулі Python мають вантажитися,
        щоб починати номер (img — підготовка; ocr — збирання PDF з OCR).                              #>
    param([int[]]$Items, [string[]]$Extra = @(), [string]$WaitSet = "img")
    $queue = [System.Collections.Queue]::new(); foreach ($n in $Items) { $queue.Enqueue($n) }
    $running = @{}; $tries = @{}
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) {
            # перед КОЖНИМ номером: Windows часом блокує OpenCV посеред ночі (01.10.2026 22:06), а pikepdf —
            # посеред дня (02.10.2026 13:59). Чекати й пробувати кожні 10 хв до 6 год (Wait-NsPyModules,
            # рішення головної 02.10.2026); не дочекалися — решту черги назвати «не зроблено», а не дати
            # кожному номерові впасти окремо
            if ($script:blocked -or -not (Wait-NsPyModules -Set $WaitSet -For ("номери " + (@($queue.ToArray()) -join ", ")))) {
                $script:blocked = $true; $script:notDone += @($queue.ToArray()); $queue.Clear(); break
            }
            $n = [int]$queue.Dequeue()
            $p = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList (@(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $PSScriptRoot $worker)`"", "-Seq", "$n") + $Extra)
            $null = $p.Handle       # без цього ExitCode процесу, що вже завершився, часом порожній
            $running[$n] = $p
            Write-Host ("  [{0}] старт {1}" -f (Get-Date).ToString("HH:mm:ss"), $n)
        }
        Start-Sleep -Seconds 10
        foreach ($n in @($running.Keys)) {
            $p = $running[$n]
            if (-not $p.HasExited) { continue }
            $running.Remove($n)
            $code = $p.ExitCode
            $now = (Get-Date).ToString("HH:mm:ss")
            if ($code -eq $script:NS_EXIT_OCR_WAIT -and $WaitSet -eq "img") {
                # ns-full: підготовлено, а pikepdf / ocrmypdf заблоковано — це не збій; зберемо другим проходом
                $script:pending += $n
                Write-Host ("  [{0}] {1}: підготовлено; PDF з OCR — пізніше (pikepdf / ocrmypdf заблоковано)" -f $now, $n) -ForegroundColor Yellow
                continue
            }
            if ($code -eq $script:NS_EXIT_BLOCKED -or $code -eq $script:NS_EXIT_OCR_WAIT) {
                # заблоковано ПОСЕРЕД номера: почати його (цей прохід) заново, не продовжувати з середини;
                # на початок черги — там на нього чекає Wait-NsPyModules. До 3 разів.
                $tries[$n] = 1 + [int]$tries[$n]
                if ($tries[$n] -le 3 -and -not $script:blocked) {
                    Write-Host ("  [{0}] {1}: модулі Python заблоковано посеред номера — почну заново (повтор {2} з 3)" -f $now, $n, $tries[$n]) -ForegroundColor Yellow
                    $q2 = [System.Collections.Queue]::new(); $q2.Enqueue($n); foreach ($x in $queue.ToArray()) { $q2.Enqueue($x) }; $queue = $q2
                } else { $script:blocked = $true; $script:notDone += $n }
                continue
            }
            if ($code -eq 3) {
                # не збій, а «потрібне рішення»: ручний page_edge не із заміру чи номер «лише вручну»
                $script:stopped += $n
                Write-Host ("  [{0}] {1}: ЗУПИНЕНО — потрібне рішення (код 3), див. NS_WORK\{1}\prepare.log" -f $now, $n) -ForegroundColor Yellow
                continue
            }
            $ok = Test-NsBatchDone $n
            if (-not $ok) { $script:failed += $n }
            Write-Host ("  [{0}] {1}: {2} (код {3})" -f $now, $n, $(if ($ok) { "готово" } else { "ЗБІЙ — див. NS_WORK\$n\$($resultFile -replace 'json$', 'log')" }), $code) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
        }
    }
}

$extra = @()
if ($Full -and $KeepWork) { $extra += "-KeepWork" }
Write-Host ("Пакет{0}: {1} ({2} номерів), одночасно {3}" -f $(if ($Full) { " (повний шлях)" } else { "" }), ($list -join ", "), $list.Count, $Parallel) -ForegroundColor Cyan

if ($Full -and $BuildOnly) { $script:pending = @($list) }
else { Invoke-NsBatchQueue -Items $list -Extra $extra -WaitSet "img" }

if ($Full -and $script:pending.Count -gt 0) {
    if ($script:blocked) { $script:notDone += $script:pending }
    else {
        $todo = @($script:pending | Sort-Object); $script:pending = @()
        Write-Host ("Збирання PDF з OCR ({0} номерів): {1}" -f $todo.Count, ($todo -join ", ")) -ForegroundColor Cyan
        Invoke-NsBatchQueue -Items $todo -Extra (@("-BuildOnly") + $extra) -WaitSet "ocr"
    }
}

Write-Host ""
Write-Host ("Пакет закінчено за {0:N0} хв. Збійних: {1}" -f ((Get-Date) - $t0).TotalMinutes, $(if ($script:failed.Count) { $script:failed -join ", " } else { "немає" }))
if ($script:stopped.Count) { Write-Host ("Зупинено, потрібне рішення (ручний page_edge / лише вручну): {0}" -f ($script:stopped -join ", ")) -ForegroundColor Yellow }
if ($script:blocked) {
    Write-Host ("ЗУПИНКА: модулі Python заблоковано Windows (Smart App Control). НЕ ЗРОБЛЕНО номери: {0}. Не обходити; сказати оператору." -f $(if ($script:notDone.Count -or $script:failed.Count) { (@($script:failed) + @($script:notDone) | Sort-Object -Unique) -join ", " } else { "—" })) -ForegroundColor Red
}
if ($Full) {
    # підготовлено цим прогоном, а PDF з OCR не зібрано (pikepdf / ocrmypdf так і не розблокувалися)
    $preparedOnly = @($list | Where-Object {
        $f = Join-Path $script:NS_WORK "$_\full.json"
        (Test-Path $f) -and (Get-Item $f).LastWriteTime -gt $t0 -and ((Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).stage -eq "prepared") })
    if ($preparedOnly.Count) {
        Write-Host ("Підготовлено, PDF з OCR НЕ зібрано: {0}. Коли блокування мине: ns-prepare-batch -Seq {1} -Full -BuildOnly" -f ($preparedOnly -join ", "), ($preparedOnly -join ",")) -ForegroundColor Yellow
    }
}
$env:PYTHONIOENCODING = "utf-8"
$py = if ($script:PYTHON) { $script:PYTHON } else { "python" }
# підсумок — лише по номерах, що справді пройшли цього разу (старий json незробленого номера
# читався б як свіжий результат)
$doneNow = @($list | Where-Object { Test-NsBatchDone $_ })
if ($doneNow.Count) {
    if ($Full) {
        foreach ($n in $doneNow) {
            $d = Get-Content (Join-Path $script:NS_WORK "$n\full.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ("  {0}: {1} стор., {2} МБ, слів {3}, підозрілих {4} %, позначок {5}, стан {6}, {7} хв" -f $n, $d.pages, $d.pdf_mb, $d.ocr_words, $d.ocr_pct, $d.flags_n, $d.state, $d.minutes) -ForegroundColor $(if ($d.flags_n) { "Yellow" } else { "Green" })
        }
    } else { & $py (Join-Path $PSScriptRoot "ns-prepsummary.py") @($doneNow | ForEach-Object { "$_" }) }
}
exit $(if ($script:blocked) { $script:NS_EXIT_BLOCKED } elseif ($script:failed.Count -or $script:stopped.Count) { 1 } else { 0 })
