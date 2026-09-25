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
    [int]$Parallel = 2
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$list = @()
foreach ($s in $Seq) {
    if ($s -match '^(\d+)\.\.(\d+)$') { $list += [int]$Matches[1]..[int]$Matches[2] }
    elseif ($s -match '^\d+$') { $list += [int]$s }
    else { Write-Host "Не зрозумів номер: $s" -ForegroundColor Red; exit 1 }
}
$list = @($list | Select-Object -Unique)
$t0 = Get-Date
$queue = [System.Collections.Queue]::new(); foreach ($n in $list) { $queue.Enqueue($n) }
$running = @{}
$failed = @()
Write-Host ("Пакет: {0} ({1} номерів), одночасно {2}" -f ($list -join ", "), $list.Count, $Parallel) -ForegroundColor Cyan

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) {
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
            $ok = (Test-Path (Join-Path $script:NS_WORK "$n\prepare.json")) -and ((Get-Item (Join-Path $script:NS_WORK "$n\prepare.json")).LastWriteTime -gt $t0)
            if (-not $ok) { $failed += $n }
            Write-Host ("  [{0}] {1}: {2} (код {3})" -f (Get-Date).ToString("HH:mm:ss"), $n, $(if ($ok) { "готово" } else { "ЗБІЙ — див. NS_WORK\$n\prepare.log" }), $p.ExitCode) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            $running.Remove($n)
        }
    }
}

Write-Host ""
Write-Host ("Пакет закінчено за {0:N0} хв. Збійних: {1}" -f ((Get-Date) - $t0).TotalMinutes, $(if ($failed.Count) { $failed -join ", " } else { "немає" }))
$env:PYTHONIOENCODING = "utf-8"
$py = if ($script:PYTHON) { $script:PYTHON } else { "python" }
& $py (Join-Path $PSScriptRoot "ns-prepsummary.py") @($list | ForEach-Object { "$_" })
exit $(if ($failed.Count) { 1 } else { 0 })
