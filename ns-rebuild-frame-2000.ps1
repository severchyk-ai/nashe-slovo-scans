# ОДНОРАЗОВИЙ сценарій: перезбірка 2000 року під нову рамку (варіант Б).
# Заливка краю і доповнення тепер мають ОДИН тон: їх накладає ns-render
# ПІСЛЯ балансу білого, тоном виміряного паперу номера.
# Для 14 номерів задано виміряні глибини країв; решта бере значення з
# маніфестів, тож винятки 2214 (календар, марля) і 2237 (12,5 мм) уціліють.
# Після роботи файл можна видалити.

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole
$t0 = Get-Date
Write-Host ("ПОЧАТОК: {0}" -f $t0.ToString("yyyy-MM-dd HH:mm"))
$edges = @{
    2215 = "4T7 9T7"
    2216 = "4R7"
    2217 = "8L7"
    2219 = "2R7 8T7"
    2220 = "1T7"
    2221 = "4R7"
    2222 = "6L7"
    2223 = "7T7"
    2225 = "6R7"
    2227 = "1T7 3T7 6T7 4R7 6R7 8R7"
    2228 = "2T7 2R7"
    2232 = "2R7 3T7 4T7 4R7 9R7 10R7"
    2235 = "6L7 6R7 12L7 13L7 14L7 14R7"
    2245 = "7R7"
}
$failed = @()
foreach ($s in 2214..2265) {
    Write-Host ""; Write-Host ("=" * 70); Write-Host "  НОМЕР $s"; Write-Host ("=" * 70)
    $a = @{ Seq = $s; Force = $true }
    if ($edges.ContainsKey($s)) { $a.EdgeExtra = $edges[$s] }
    & "$PSScriptRoot\ns-prep.ps1" @a
    if ($LASTEXITCODE -ne 0) { $failed += $s; continue }
    & "$PSScriptRoot\ns-render.ps1" -Seq $s -Force
    if ($LASTEXITCODE -ne 0) { $failed += $s; continue }
    & "$PSScriptRoot\ns-build.ps1" -Seq $s -Force
    if ($LASTEXITCODE -ne 0) { $failed += $s; continue }
    foreach ($st in @("prep","render")) {
        Remove-Item (Join-Path (Join-Path $script:NS_WORK "$s") $st) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("  [{0:HH:mm}] {1} готовий, минуло {2:N1} год" -f (Get-Date), $s, ((Get-Date)-$t0).TotalHours)
}
Write-Host ""; Write-Host "=== ПЕРЕВІРКА ПІСЛЯ ПЕРЕЗБІРКИ ==="
foreach ($s in 2214..2265) { & "$PSScriptRoot\ns-qc.ps1" -Seq $s }
Write-Host ""
Write-Host ("З ПОМИЛКОЮ: {0}" -f $(if ($failed) { $failed -join ", " } else { "немає" }))
Write-Host ("КІНЕЦЬ: {0}, тривалість {1:N1} год" -f (Get-Date).ToString("yyyy-MM-dd HH:mm"), ((Get-Date)-$t0).TotalHours)
