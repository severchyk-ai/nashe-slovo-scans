# Завершити день: зберегти роботу.
#
#   .\ns-endday.ps1              git commit + push теки Scans, резерв на зовнішній диск (якщо підключено)
#   .\ns-endday.ps1 -DryRun      лише показати, що було б зроблено
#   .\ns-endday.ps1 -NoBackup    лише git
#   .\ns-endday.ps1 -Dest F:\    диск резерву вказано явно (за умовчанням шукається диск із текою NS_BACKUP)
#
# Що береже (КОНВЕЄР.md, «Збереження роботи»):
#   1. скрипти й документи проєкту — git (коміт щодня, push на GitHub, коли сховище підключено);
#   2. майстри + маніфести + готові PDF — ns-backup -Quick на зовнішній диск: копіюється лише змінене,
#      звіряється за SHA-256 лише те, що ще не звірено.
# Майстри й NS_WORK у git не потрапляють ніколи (.gitignore). Немає диска — це не помилка: git робиться,
# а в кінці сказано, скільки сторінок лишилось без резерву.
# Права адміністратора не потрібні.

param(
    [switch]$DryRun,
    [switch]$NoBackup,
    [switch]$FullVerify,         # повна звірка копії за SHA-256 незалежно від давності останньої
    [switch]$NoGit,              # лише резерв (для випробувань на піску)
    [string]$Dest
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$line = "-" * 74
$logFile = Join-Path $script:LOGS "endday.log"
New-Item -ItemType Directory -Path $script:LOGS -Force | Out-Null
$result = [ordered]@{ git = "не робилось"; push = "не робилось"; backup = "не робилось"; full = "не потрібна" }

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "  $Text" -ForegroundColor Cyan }

function Invoke-NsScript {
    <#  Запустити .ps1 і чесно повернути код завершення. Якщо скрипт не запустився чи не вказав код
        (тоді $LASTEXITCODE лишається від попередньої команди й брехав би «ok»), — ненульовий код. #>
    param([string]$Path, [hashtable]$Params = @{})
    if (-not (Test-Path $Path)) { Write-Host "     Немає скрипта: $Path" -ForegroundColor Red; return 97 }
    $global:LASTEXITCODE = $null
    try { & $Path @Params } catch { Write-Host "     Скрипт упав: $($_.Exception.Message)" -ForegroundColor Red; return 99 }
    if ($null -eq $LASTEXITCODE) { return 98 }
    return [int]$LASTEXITCODE
}

function Invoke-Git {
    <#  git без винятків PowerShell: повертає @{ Code; Text }. #>
    param([string[]]$GitArgs)
    $out = & git -C $PSScriptRoot @GitArgs 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

Write-Host ""
Write-Host "  ЗАВЕРШИТИ ДЕНЬ" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor DarkGray
if ($DryRun) { Write-Host "  (пробний прогін: нічого не записується)" -ForegroundColor Yellow }

# ------------------------------------------------------------------ 1. git
Write-Step "1. Скрипти й документи (git)"
$hasGit = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if ($NoGit) {
    Write-Host "     Пропущено (-NoGit)."
    $result.git = "пропущено за проханням"; $result.push = "пропущено за проханням"
} elseif (-not $hasGit) {
    Write-Host "     git не встановлено — пропущено." -ForegroundColor Yellow
    $result.git = "git не встановлено"
} elseif (-not (Test-Path (Join-Path $PSScriptRoot ".git"))) {
    Write-Host "     Тека Scans не під git — пропущено." -ForegroundColor Yellow
    $result.git = "тека не під git"
} else {
    $st = Invoke-Git @("status", "--porcelain")
    $changed = @($st.Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($changed.Count -eq 0) {
        Write-Host "     Змін немає — новий коміт не потрібен."
        $h = (Invoke-Git @("rev-parse", "--short", "HEAD")).Text
        $result.git = "змін немає (останній коміт $h)"
    } else {
        Write-Host ("     Змінених файлів: {0}" -f $changed.Count)
        $changed | Select-Object -First 12 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        if ($changed.Count -gt 12) { Write-Host ("       … і ще {0}" -f ($changed.Count - 12)) -ForegroundColor DarkGray }
        if ($DryRun) {
            $result.git = "було б закомічено файлів: $($changed.Count)"
        } else {
            $null = Invoke-Git @("add", "-A")
            $msg = "Кінець дня {0}: файлів {1}" -f (Get-Date).ToString("dd.MM.yyyy"), $changed.Count
            $c = Invoke-Git @("commit", "-m", $msg)
            if ($c.Code -eq 0) {
                $h = (Invoke-Git @("rev-parse", "--short", "HEAD")).Text
                Write-Host ("     Коміт {0}: {1}" -f $h, $msg) -ForegroundColor Green
                $result.git = "коміт $h, файлів $($changed.Count)"
            } else {
                Write-Host "     Коміт не вдався:" -ForegroundColor Red
                Write-Host ("     " + $c.Text) -ForegroundColor Red
                $result.git = "КОМІТ НЕ ВДАВСЯ"
            }
        }
    }

    # push
    $remotes = @((Invoke-Git @("remote")).Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($remotes.Count -eq 0) {
        Write-Host "     GitHub ще не підключено (remote немає) — push пропущено; коміт лежить локально." -ForegroundColor Yellow
        $result.push = "remote не налаштовано"
    } elseif ($DryRun) {
        $result.push = "було б: git push ($($remotes -join ', '))"
    } else {
        $p = Invoke-Git @("push")
        if ($p.Code -eq 0) {
            Write-Host "     Push на $($remotes -join ', ') виконано." -ForegroundColor Green
            $result.push = "ok ($($remotes -join ', '))"
        } else {
            Write-Host "     Push не вдався (немає мережі чи доступу?). Коміт збережено локально; повторити завтра." -ForegroundColor Yellow
            $tail = ($p.Text -split "`r?`n" | Select-Object -Last 3) -join "`n     "
            Write-Host "     $tail" -ForegroundColor DarkGray
            $result.push = "НЕ ВДАВСЯ"
        }
    }
}

# ------------------------------------------------------------------ 2. резерв
Write-Step "2. Резерв майстрів і PDF (зовнішній диск)"
$lastBackup = $null
if (Test-Path $logFile) {
    $hit = @(Get-Content $logFile -Encoding UTF8 | Where-Object { $_ -match 'резерв: ok' }) | Select-Object -Last 1
    if ($hit -and $hit -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') { $lastBackup = [datetime]::Parse($Matches[1]) }
}

$destRoot = $null
if ($NoBackup) {
    Write-Host "     Пропущено (-NoBackup)."
    $result.backup = "пропущено за проханням"
} else {
    if ($Dest) {
        if (Test-Path $Dest) { $destRoot = $Dest }
    } else {
        $cand = @(Get-PSDrive -PSProvider FileSystem | Where-Object {
                      $_.Root -ne "C:\" -and $_.Root -ne "$($env:SystemDrive)\" -and (Test-Path (Join-Path $_.Root "NS_BACKUP")) })
        if ($cand.Count -eq 1) { $destRoot = $cand[0].Root }
        elseif ($cand.Count -gt 1) {
            Write-Host ("     Знайдено кілька дисків із NS_BACKUP: {0}. Вкажи -Dest." -f (($cand | ForEach-Object { $_.Root }) -join ", ")) -ForegroundColor Yellow
        }
    }
    if (-not $destRoot) {
        Write-Host "     Диск резерву не підключено (немає диска з текою NS_BACKUP) — копію не зроблено." -ForegroundColor Yellow
        Write-Host "     Підключи диск і запусти «Завершити день» ще раз." -ForegroundColor Yellow
        $result.backup = "диск не підключено"
    } elseif ($DryRun) {
        Write-Host "     Диск знайдено: $destRoot — було б: ns-backup -Quick."
        $result.backup = "було б: ns-backup -Quick на $destRoot"
    } else {
        Write-Host "     Диск: $destRoot" -ForegroundColor Green
        $rc = Invoke-NsScript -Path (Join-Path $PSScriptRoot "ns-backup.ps1") -Params @{ Dest = $destRoot; Quick = $true }
        if ($rc -eq 0) {
            $result.backup = "ok на $destRoot"
            # -Quick не бачить тихого псування вже звіреного файлу з тим самим розміром і часом,
            # тому раз на 7 днів — повна звірка всієї копії за SHA-256 (мінуси: кілька хвилин).
            $lastFull = $null
            if (Test-Path $logFile) {
                $hf = @(Get-Content $logFile -Encoding UTF8 | Where-Object { $_ -match 'повна звірка: ok' }) | Select-Object -Last 1
                if ($hf -and $hf -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') { $lastFull = [datetime]::Parse($Matches[1]) }
            }
            if ($FullVerify -or -not $lastFull -or ((Get-Date) - $lastFull).TotalDays -ge 7) {
                Write-Host ""
                Write-Host "     Повна звірка копії за SHA-256 (раз на 7 днів; кілька хвилин)…" -ForegroundColor Cyan
                $rf = Invoke-NsScript -Path (Join-Path $PSScriptRoot "ns-backup.ps1") -Params @{ Dest = $destRoot; VerifyOnly = $true }
                if ($rf -eq 0) { $result.full = "ok" }
                else { $result.full = "ЗБІЙ (код $rf) — копія не збігається з оригіналом або звірка не пройшла"; Write-Host "     Повна звірка НЕ пройшла!" -ForegroundColor Red }
            } else {
                $result.full = "не потрібна (остання {0})" -f $lastFull.ToString("dd.MM")
            }
        } else {
            $result.backup = "ЗБІЙ (код $rc) на $destRoot"
            Write-Host "     Резерв не завершено — див. повідомлення вище." -ForegroundColor Red
        }
    }
}

# ------------------------------------------------------------------ 3. що лишилось без резерву
Write-Step "3. Що не захищено"
$since = if ($result.backup -like "ok*") { Get-Date } else { $lastBackup }
$unprot = 0; $unprotIssues = @()
if ($since) {
    foreach ($d in (Get-ChildItem $script:NS_MASTERS -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}$' } |
                    ForEach-Object { Get-ChildItem $_.FullName -Directory })) {
        $m = Read-NsManifest -IssueDir $d.FullName
        if (-not $m) { continue }
        $n = @($m.pages | Where-Object { $_.scanned_at -and ([datetime]::Parse($_.scanned_at) -gt $since) }).Count
        if ($n -gt 0) { $unprot += $n; $unprotIssues += $m.seq_first }
    }
}
if ($result.backup -like "ok*") {
    Write-Host "     Майстри й PDF скопійовано й звірено — усе, що є, у резерві." -ForegroundColor Green
} elseif ($since) {
    Write-Host ("     Останній вдалий резерв за журналом: {0}." -f $since.ToString("dd.MM.yyyy HH:mm"))
    if ($unprot -gt 0) {
        Write-Host ("     БЕЗ РЕЗЕРВУ ПІСЛЯ НЬОГО: {0} стор. (номери {1})." -f $unprot, (($unprotIssues | Select-Object -First 8) -join ", ")) -ForegroundColor Yellow
    } else {
        Write-Host "     Після нього нових сторінок не було."
    }
} else {
    Write-Host "     Журнал не знає жодного резерву цим скриптом — скільки сторінок не захищено, не відомо." -ForegroundColor Yellow
    Write-Host "     (Раніше резерв робився вручну: ns-backup -Dest ...; його дату видно в <диск>\NS_BACKUP\_backup_stamp.txt.)" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ журнал
$entry = "{0}  git: {1}; push: {2}; резерв: {3}; повна звірка: {4}" -f (Get-Date).ToString("s"), $result.git, $result.push, $result.backup, $result.full
if (-not $DryRun) { Add-Content -Path $logFile -Value $entry -Encoding UTF8 }

Write-Host ""
Write-Host "  $line" -ForegroundColor DarkGray
Write-Host ("  git    : {0}" -f $result.git)
Write-Host ("  push   : {0}" -f $result.push)
Write-Host ("  резерв : {0}" -f $result.backup)
Write-Host ("  звірка : {0}" -f $result.full)
Write-Host ""
$bad = ($result.Values | Where-Object { $_ -match 'НЕ ВДАВСЯ|ЗБІЙ|НЕ пройшла' }).Count
if ($bad -gt 0) { exit 1 }
exit 0
