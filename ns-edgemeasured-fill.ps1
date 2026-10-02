# Разове заповнення page_edge_measured у маніфестах уже підготовлених ЗВИЧАЙНИХ номерів — з наявних
# NS_WORK\<N>\spine.json, без нового заміру (рішення головної 02.10.2026).
#
#   .\ns-edgemeasured-fill.ps1 -DryRun     лише показати, що було б записано
#   .\ns-edgemeasured-fill.ps1
#
# Навіщо: походження зрізів («із заміру ниток» чи «слово оператора») досі жило лише в spine.json, а теку
# NS_WORK дозволено видаляти — після цього ns-prepare прийняв би власний давній замір за слово оператора й
# зупинився (код 3). Далі поле пише сам ns-prepare; цей скрипт — для номерів, підготовлених раніше.
# У поле йдуть лише знаки, що є І в page_edge маніфесту, І в spine.json; знаки з ns-edge-keep.csv (слово
# оператора) — ні. Номери «лише вручну» не чіпаються. Де поле вже є — пропуск. Сторінки не змінюються:
# хеші звіряються до й після (Set-NsEdgeMeasured). Журнал — _catalog\logs\edgemeasured.log.

param([switch]$DryRun)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$manual = Get-NsManual
$nWritten = 0; $nHas = 0; $nNoEdge = 0; $nNoSpine = 0; $nNone = 0; $nManual = 0; $nFail = 0
foreach ($row in @(Read-NsRegistry | Sort-Object { [int]$_.seq_first })) {
    $seq = [int]$row.seq_first
    if ($manual.ContainsKey($seq)) { $nManual++; continue }
    $dir = Find-NsIssueDir -Seq $seq
    if (-not $dir) { continue }
    $man = Read-NsManifest -IssueDir $dir
    if (-not ($man.PSObject.Properties.Name -contains 'page_edge') -or -not $man.page_edge) { $nNoEdge++; continue }
    if ($man.PSObject.Properties.Name -contains 'page_edge_measured' -and $man.page_edge_measured) { $nHas++; continue }
    $sjf = Join-Path (Join-Path $script:NS_WORK "$seq") "spine.json"
    if (-not (Test-Path $sjf)) { $nNoSpine++; Write-Host ("  {0}: page_edge є ({1}), spine.json немає — не чіпаю" -f $seq, $man.page_edge) -ForegroundColor Yellow; continue }
    $spineTok = @{}
    try { foreach ($tk in ("$((Get-Content $sjf -Raw -Encoding UTF8 | ConvertFrom-Json).edge)" -split '[,\s]+')) { if ($tk) { $spineTok[$tk.ToUpper()] = $true } } } catch { }
    $keepTok = @{}; $ek = Get-NsEdgeKeep -Seq $seq
    foreach ($tk in @($ek.Keep)) { if ($tk) { $keepTok[$tk] = $true } }
    $all = @("$($man.page_edge)" -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpper() })
    $meas = @($all | Where-Object { $spineTok.ContainsKey($_) -and -not $keepTok.ContainsKey($_) })
    $hand = @($all | Where-Object { $meas -notcontains $_ })
    if ($meas.Count -eq 0) { $nNone++; Write-Host ("  {0}: жоден знак page_edge не збігається із заміром — не чіпаю ({1})" -f $seq, $man.page_edge) -ForegroundColor Yellow; continue }
    $line = "{0}: із заміру {1} знаків ({2}){3}" -f $seq, $meas.Count, ($meas -join " "), $(if ($hand.Count) { "; слово оператора: " + ($hand -join " ") } else { "" })
    if ($DryRun) { Write-Host ("  [проба] " + $line); $nWritten++; continue }
    try {
        $null = Set-NsEdgeMeasured -IssueDir $dir -Measured ($meas -join " ")
        Add-Content -Path (Join-Path $script:LOGS "edgemeasured.log") -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date).ToString("s"), $line)
        Write-Host ("  " + $line) -ForegroundColor Green
        $nWritten++
    } catch { $nFail++; Write-Host ("  {0}: ЗБІЙ — {1}" -f $seq, $_.Exception.Message) -ForegroundColor Red }
}
Write-Host ""
Write-Host ("{0}: {1}; уже мали поле: {2}; без page_edge: {3}; page_edge без spine.json: {4}; без збігу із заміром: {5}; лише вручну (не чіпав): {6}; збоїв: {7}" -f `
    $(if ($DryRun) { "Було б записано" } else { "Записано page_edge_measured" }), $nWritten, $nHas, $nNoEdge, $nNoSpine, $nNone, $nManual, $nFail)
exit $(if ($nFail) { 1 } else { 0 })
