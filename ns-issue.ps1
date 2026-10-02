# Увесь шлях від майстрів до готового PDF однією командою.
#
#   .\ns-issue.ps1 -Seq 2231          один номер
#   .\ns-issue.ps1 -All               усі відскановані, для яких PDF ще немає
#   .\ns-issue.ps1 -Seq 2231 -Force   перебудувати, навіть якщо все вже є
#
# Етапи: 3 (геометрія) -> 3b (вигляд) -> 5-6 (PDF з текстовим шаром).
# Кожен етап — окремий скрипт і окрема тека в NS_WORK, тож будь-який можна
# перезапустити окремо, а вміст NS_WORK видалити будь-коли: він повністю
# відтворюється з майстрів.

param(
    [int]$Seq,
    [switch]$All,
    [switch]$Rebuild,      # разом з -All: брати й уже зібрані номери
    [int[]]$Skip = @(),    # разом з -All: пропустити ці номери
    [switch]$Force,
    [switch]$NoOcr,
    [switch]$KeepWork      # не прибирати похідні після успішної збірки
)
if ($Rebuild) { $All = $true; $Force = $true }

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (-not $Seq -and -not $All) {
    Write-Host "Вкажи -Seq <номер> або -All." -ForegroundColor Red; exit 1
}

$targets = @()
if ($All) {
    # -All бере тільки ще не зібрані. -Rebuild додає й зібрані: це потрібно,
    # коли змінився сам конвеєр і всі номери треба прогнати наново. Без нього
    # після першої ж повної збірки -All не знаходив нічого, і масову
    # перезбірку доводилося запускати списком повз меню.
    $want = if ($Rebuild) { @("scanned", "delivered", "qc_flagged") } else { @("scanned") }
    $targets = @(Read-NsRegistry |
                 Where-Object { $want -contains $_.status } |
                 Sort-Object { [int]$_.seq_first } |
                 ForEach-Object { [int]$_.seq_first })
    if ($Skip.Count -gt 0) {
        $targets = @($targets | Where-Object { $Skip -notcontains $_ })
    }
    # «лише вручну» (ns-manual.csv): -All такі номери не чіпає; одиничний -Seq N — працює
    $manual = Get-NsManual
    foreach ($n in @($targets)) { if ($manual.ContainsKey($n)) { Write-Host ("  {0}: лише вручну — {1} — ПРОПУЩЕНО" -f $n, $manual[$n]) -ForegroundColor Yellow } }
    $targets = @($targets | Where-Object { -not $manual.ContainsKey($_) })
    if ($targets.Count -eq 0) {
        Write-Host "Нічого збирати: немає номерів у потрібному стані." -ForegroundColor Yellow
        exit 0
    }
    $mins = [int]($targets.Count * 13)
    Write-Host ("До збірки {0} номерів: {1}" -f $targets.Count, ($targets -join ', ')) -ForegroundColor Cyan
    Write-Host ("Орієнтовно {0} год {1} хв (13 хв на номер)." -f [int]($mins/60), ($mins % 60)) -ForegroundColor DarkGray
} else {
    $targets = @($Seq)
}

$done = @(); $failed = @(); $blocked = $false

foreach ($s in $targets) {
    Write-Host ""
    Write-Host ("=" * 74) -ForegroundColor DarkGray
    Write-Host "  НОМЕР $s" -ForegroundColor Cyan
    Write-Host ("=" * 74) -ForegroundColor DarkGray

    $started = Get-Date
    $ok = $true
    $try = 0

    # Windows часом блокує OpenCV (02.10.2026): перед кожним номером дочекатися модулів (пробувати
    # кожні 10 хв до 6 год); заблокувало ПОСЕРЕД номера — почати номер заново (-Force), до 3 разів.
    while ($true) {
        $try++
        if (-not (Wait-NsPyModules -Set $(if ($NoOcr) { "img" } else { "ocr" }) -For "номер $s")) { $blocked = $true; $ok = $false; break }
        $ok = $true; $hit42 = $false
        foreach ($stage in @(
            @{ name = "3  геометрія"; script = "ns-prep.ps1"   },
            @{ name = "3b вигляд";    script = "ns-render.ps1" },
            @{ name = "5-6 PDF";      script = "ns-build.ps1"  }
        )) {
            # Розсипати треба ХЕШ-ТАБЛИЦЮ, не масив: масив передає елементи
            # позиційно, і рядок "-Seq" прилітає в $Seq як значення замість імені
            # параметра («Cannot convert value "-Seq" to type System.Int32»).
            $callArgs = @{ Seq = $s }
            if ($Force -or $try -gt 1) { $callArgs.Force = $true }
            if ($NoOcr -and $stage.script -eq "ns-build.ps1") { $callArgs.NoOcr = $true }
            & "$PSScriptRoot\$($stage.script)" @callArgs
            if ($LASTEXITCODE -ne 0) {
                if ($LASTEXITCODE -eq $script:NS_EXIT_BLOCKED) { $hit42 = $true }
                Write-Host "Етап «$($stage.name)» завершився помилкою на номері $s." -ForegroundColor Red
                $ok = $false
                break
            }
        }
        if ($hit42 -and $try -lt 3) {
            Write-Host "OpenCV заблоковано посеред номера $s — почну номер заново (повтор $try з 2)." -ForegroundColor Yellow
            continue
        }
        if ($hit42) { $blocked = $true }
        break
    }
    # OpenCV заблоковано Windows (код 42 від етапу): решта номерів упала б так само — зупинити весь прогін
    if ($blocked) {
        $failed += $s
        $rest = @($targets | Where-Object { $done -notcontains $_ -and $failed -notcontains $_ })
        Write-Host ("ЗУПИНКА: OpenCV заблоковано Windows (Smart App Control) — номер {0} НЕ ЗРОБЛЕНО; не починав: {1}. Не обходити; сказати оператору." -f $s, $(if ($rest.Count) { $rest -join ', ' } else { "—" })) -ForegroundColor Red
        break
    }

    if ($ok) {
        $mins = ((Get-Date) - $started).TotalMinutes
        Write-Host ("Номер {0} готовий за {1:N1} хв." -f $s, $mins) -ForegroundColor Green
        $done += $s
        if (-not $KeepWork) {
            # Похідні більше не потрібні: вони відтворюються з майстрів за
            # ті самі хвилини, а місця займають більше за самі майстри.
            $w = Join-Path $script:NS_WORK "$s"
            foreach ($st in @("prep", "render")) {
                Remove-Item (Join-Path $w $st) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        $failed += $s
    }
}

Write-Host ""
Write-Host ("=" * 74) -ForegroundColor DarkGray
Write-Host ("Зібрано: {0}" -f $(if ($done.Count) { $done -join ', ' } else { "нічого" })) -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host ("З помилкою: {0}" -f ($failed -join ', ')) -ForegroundColor Red
    exit $(if ($blocked) { $script:NS_EXIT_BLOCKED } else { 1 })
}
