# Підготувати пакет номерів (ns-prepare для кожного) з обмеженим паралелізмом.
#
#   .\ns-prepare-batch.ps1 -Seq 2326,2327,2328,2329,2330,2331            за умовчанням 2 одночасно
#   .\ns-prepare-batch.ps1 -Seq 2326..2331 -Parallel 3
#
# Кожен номер — окремий процес ns-prepare.ps1 (журнал NS_WORK\<N>\prepare.log). Тут лише черга: коли один
# закінчується, стартує наступний. Підсумок — ns-prepsummary.py по всіх; номери, де ns-prepare упав, названо
# окремо. Скрипт нічого не змінює сам: усе робить ns-prepare (замір ниток -> page_edge -> заростання -> render
# -> PDF без OCR). Не запускати більше двох неоглянутих пакетів наперед (правило головної, 25.09.2026).

param(
    [Parameter(Mandatory = $true)][string[]]$Seq,
    [int]$Parallel = 2,
    [switch]$IncludeManual      # брати й номери зі списку «лише вручну» (ns-manual.csv); без ключа вони пропускаються
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

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
$t0 = Get-Date
$queue = [System.Collections.Queue]::new(); foreach ($n in $list) { $queue.Enqueue($n) }
$running = @{}
$failed = @()
$blocked = $false; $notDone = @(); $tries = @{}
Write-Host ("Пакет: {0} ({1} номерів), одночасно {2}" -f ($list -join ", "), $list.Count, $Parallel) -ForegroundColor Cyan

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) {
        # перед КОЖНИМ номером: Windows часом блокує OpenCV посеред ночі (01.10.2026 22:06). Чекати й
        # пробувати кожні 10 хв до 6 год (Wait-NsPyModules, рішення головної 02.10.2026); не дочекалися —
        # решту черги назвати «не зроблено», а не дати кожному номерові впасти окремо
        if ($blocked -or -not (Wait-NsPyModules -For ("номери " + (@($queue.ToArray()) -join ", ")))) {
            $blocked = $true; $notDone += @($queue.ToArray()); $queue.Clear(); break
        }
        $n = [int]$queue.Dequeue()
        $p = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $PSScriptRoot 'ns-prepare.ps1')`"", "-Seq", "$n")
        $running[$n] = $p
        Write-Host ("  [{0}] старт {1}" -f (Get-Date).ToString("HH:mm:ss"), $n)
    }
    Start-Sleep -Seconds 10
    foreach ($n in @($running.Keys)) {
        $p = $running[$n]
        if ($p.HasExited) {
            if ($p.ExitCode -eq $script:NS_EXIT_BLOCKED) {
                # заблоковано ПОСЕРЕД номера: почати його заново (ns-prepare сам іде з prep -Force), не
                # продовжувати з середини; на початок черги — там на нього чекає Wait-NsPyModules. До 3 разів.
                $running.Remove($n)
                $tries[$n] = 1 + [int]$tries[$n]
                if ($tries[$n] -le 3 -and -not $blocked) {
                    Write-Host ("  [{0}] {1}: OpenCV заблоковано посеред номера — почну заново (повтор {2} з 3)" -f (Get-Date).ToString("HH:mm:ss"), $n, $tries[$n]) -ForegroundColor Yellow
                    $q2 = [System.Collections.Queue]::new(); $q2.Enqueue($n); foreach ($x in $queue.ToArray()) { $q2.Enqueue($x) }; $queue = $q2
                } else { $blocked = $true; $notDone += $n }
                continue
            }
            $ok = (Test-Path (Join-Path $script:NS_WORK "$n\prepare.json")) -and ((Get-Item (Join-Path $script:NS_WORK "$n\prepare.json")).LastWriteTime -gt $t0)
            if (-not $ok) { $failed += $n }
            Write-Host ("  [{0}] {1}: {2} (код {3})" -f (Get-Date).ToString("HH:mm:ss"), $n, $(if ($ok) { "готово" } else { "ЗБІЙ — див. NS_WORK\$n\prepare.log" }), $p.ExitCode) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            $running.Remove($n)
        }
    }
}

Write-Host ""
Write-Host ("Пакет закінчено за {0:N0} хв. Збійних: {1}" -f ((Get-Date) - $t0).TotalMinutes, $(if ($failed.Count) { $failed -join ", " } else { "немає" }))
if ($blocked) {
    Write-Host ("ЗУПИНКА: OpenCV заблоковано Windows (Smart App Control). НЕ ЗРОБЛЕНО номери: {0}. Не обходити; сказати оператору." -f $(if ($notDone.Count -or $failed.Count) { (@($failed) + @($notDone) | Sort-Object -Unique) -join ", " } else { "—" })) -ForegroundColor Red
}
$env:PYTHONIOENCODING = "utf-8"
$py = if ($script:PYTHON) { $script:PYTHON } else { "python" }
# підсумок — лише по номерах, що справді пройшли цього разу (старий prepare.json незробленого номера
# читався б як свіжий результат)
$doneNow = @($list | Where-Object { $failed -notcontains $_ -and $notDone -notcontains $_ })
if ($doneNow.Count) { & $py (Join-Path $PSScriptRoot "ns-prepsummary.py") @($doneNow | ForEach-Object { "$_" }) }
exit $(if ($blocked) { $script:NS_EXIT_BLOCKED } elseif ($failed.Count) { 1 } else { 0 })
