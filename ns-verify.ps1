# Перевірка цілісності: перерахувати SHA-256 кожної сторінки і звірити з маніфестом.
# Виконувати після копіювання на резервний диск і час від часу для всього масиву.
#
#   .\ns-verify.ps1              — усі номери в каталозі
#   .\ns-verify.ps1 -Seq 2225    — один номер

param([int]$Seq = 0)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$dirs = if ($Seq) {
    @(Get-ChildItem -Path $script:NS_MASTERS -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "${Seq}_*" })
} else {
    @(Get-ChildItem -Path $script:NS_MASTERS -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName "_manifest.json") } | Sort-Object Name)
}

if ($dirs.Count -eq 0) { Write-Host "Нічого перевіряти." -ForegroundColor Yellow; exit 0 }

# Реєстр — похідні дані, тож перед перевіркою відновлюємо його з маніфестів.
# Інакше перервана сесія лишає рядок із застарілою кількістю сторінок, а
# перевірка #4 нижче читає саме реєстр.
$resynced = @(Sync-NsRegistry)

$okPages = 0; $badPages = 0; $missing = 0; $notRO = 0; $issues = 0; $problems = @()

foreach ($d in $dirs) {
    $man = Read-NsManifest -IssueDir $d.FullName
    if (-not $man) { continue }
    $issues++
    $bad = 0

    foreach ($p in $man.pages) {
        $full = Join-Path $d.FullName $p.file
        if (-not (Test-Path $full)) {
            $problems += "$($man.seq_first) : НЕМАЄ $($p.file)"; $missing++; $bad++; continue
        }
        if (-not (Get-Item $full).IsReadOnly) {
            $problems += "$($man.seq_first) : не read-only $($p.file)"; $notRO++
        }
        if ((Get-NsHash $full) -ne $p.sha256) {
            $problems += "$($man.seq_first) : ХЕШ НЕ ЗБІГАЄТЬСЯ $($p.file)"; $badPages++; $bad++
        } else { $okPages++ }
        # Хеш доводить лише, що файл не змінився з моменту сканування, — а не
        # що скан був правильний. 2266 стор. 8 і 2267 стор. 4 мали збіжні хеші
        # і при цьому по два кадри замість одного.
        $fc = Get-NsFrameCount -Path $full
        if ($fc -ne 1) {
            $problems += "$($man.seq_first) : $($p.file) містить $fc кадрів замість одного — сторінку розрізано при скануванні"; $bad++
        }
    }

    # перевірка #1 зі специфікації: кількість сторінок
    if (@($man.pages).Count -ne $man.pages_expected) {
        $problems += "$($man.seq_first) : сторінок $(@($man.pages).Count), очікувалось $($man.pages_expected)"
    }
    # перевірка #2: дублікат хешу в межах номера (сторінку відскановано двічі)
    $dups = @($man.pages | Group-Object sha256 | Where-Object { $_.Count -gt 1 })
    foreach ($g in $dups) {
        $problems += "$($man.seq_first) : однаковий вміст у $($g.Group.file -join ', ')"
    }
    # перевірка #3: розрив у нумерації сторінок
    $nums = @($man.pages | ForEach-Object { [int]$_.n } | Sort-Object)
    for ($i = 0; $i -lt $nums.Count; $i++) {
        if ($nums[$i] -ne $i + 1) { $problems += "$($man.seq_first) : розрив у нумерації сторінок"; break }
    }

    $mark = if ($bad -eq 0) { "ok" } else { "ПОМИЛКИ" }
    Write-Host ("{0}  {1}  {2,2} стор  {3}" -f $man.seq_first, $man.date, @($man.pages).Count, $mark)
}

# перевірка #4: безперервність наскрізних номерів
$gaps = @(Test-NsSeqContinuity) + @(Test-NsDateContinuity)

Write-Host ""
Write-Host ("Номерів: {0} | сторінок звірено: {1} | розбіжностей: {2} | відсутніх: {3}" -f `
    $issues, $okPages, $badPages, $missing)
if ($notRO -gt 0) { Write-Host "Сторінок без read-only: $notRO" -ForegroundColor Yellow }

if ($resynced.Count -gt 0) {
    Write-Host "`nРеєстр розходився з маніфестами, виправлено:" -ForegroundColor Yellow
    $resynced | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

if ($problems.Count -gt 0) {
    Write-Host "`nПроблеми:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
if ($gaps.Count -gt 0) {
    Write-Host "`nБезперервність номерів:" -ForegroundColor Yellow
    $gaps | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
if ($problems.Count -eq 0 -and $gaps.Count -eq 0) {
    Write-Host "`nУсе ціле, розривів немає." -ForegroundColor Green
    exit 0
}
exit 1
