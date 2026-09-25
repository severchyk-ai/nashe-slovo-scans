# Завершити день: зберегти роботу.
#
#   .\ns-endday.ps1              git commit + push теки Scans; резерв на КОЖЕН підключений диск із NS_BACKUP
#   .\ns-endday.ps1 -DryRun      лише показати, що було б зроблено
#   .\ns-endday.ps1 -NoBackup    лише git;   -NoGit   лише резерв
#   .\ns-endday.ps1 -Dest F:\    лише цей диск;   -FullVerify   повна звірка копій незалежно від давності
#
# Що береже (КОНВЕЄР.md, «Збереження роботи»):
#   1. скрипти й документи проєкту — git (коміт щодня, push на GitHub);
#   2. майстри + маніфести + PDF — на зовнішні диски. Кожен диск має файл <диск>\NS_BACKUP\_scope.json
#      {"years":[2002],"jobs":["masters","pdf"]} — це ЄДИНЕ, що на ньому береже ns-backup (-Quick: копіюється лише
#      змінене, звіряється за SHA-256 лише нове). Диск без _scope.json НЕ ЧІПАЄТЬСЯ — скрипт лише каже про нього.
#   3. підсумок: скільки сторінок за роками не має копії на жодному підключеному диску (для нових років без диска
#      це видно щодня), і скільки вільно на кожному диску.
# Раз на 7 днів на кожному диску — повна звірка за SHA-256 (-Quick не бачить тихого псування вже звіреного файлу).
# Майстри й NS_WORK у git не потрапляють ніколи (.gitignore). Права адміністратора не потрібні.

param(
    [switch]$DryRun,
    [switch]$NoBackup,
    [switch]$FullVerify,
    [switch]$NoGit,
    [string]$Dest
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$line = "-" * 74
$logFile = Join-Path $script:LOGS "endday.log"
New-Item -ItemType Directory -Path $script:LOGS -Force | Out-Null
$result = [ordered]@{ git = "не робилось"; push = "не робилось"; backup = "не робилось"; full = "не потрібна" }

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "  $Text" -ForegroundColor Cyan }

function Invoke-Git {
    <#  git без винятків PowerShell: повертає @{ Code; Text }. #>
    param([string[]]$GitArgs)
    $out = & git -C $PSScriptRoot @GitArgs 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Invoke-NsScript {
    <#  Запустити .ps1 і чесно повернути код завершення. Якщо скрипт не стартував чи не вказав код
        (тоді $LASTEXITCODE лишається від попередньої команди й брехав би «ok»), — ненульовий код. #>
    param([string]$Path, [hashtable]$Params = @{})
    if (-not (Test-Path $Path)) { Write-Host "     Немає скрипта: $Path" -ForegroundColor Red; return 97 }
    $global:LASTEXITCODE = $null
    try { & $Path @Params } catch { Write-Host "     Скрипт упав: $($_.Exception.Message)" -ForegroundColor Red; return 99 }
    if ($null -eq $LASTEXITCODE) { return 98 }
    return [int]$LASTEXITCODE
}

function Get-LastLogTime {
    <#  Час останнього запису журналу, що містить $Pattern. #>
    param([string]$Pattern)
    if (-not (Test-Path $logFile)) { return $null }
    $hit = @(Get-Content $logFile -Encoding UTF8 | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    if ($hit -and $hit -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') { return [datetime]::Parse($Matches[1]) }
    return $null
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

# ------------------------------------------------------------------ 2. резерв на кожний диск
Write-Step "2. Резерв майстрів і PDF (зовнішні диски)"
$disks = @()   # @{ Root; Scope (або $null); Years; Jobs; Result }
if ($NoBackup) {
    Write-Host "     Пропущено (-NoBackup)."
    $result.backup = "пропущено за проханням"
} else {
    $roots = @()
    if ($Dest) { if (Test-Path $Dest) { $roots = @($Dest) } }
    else {
        $roots = @(Get-PSDrive -PSProvider FileSystem | Where-Object {
                       $_.Root -ne "C:\" -and $_.Root -ne "$($env:SystemDrive)\" -and (Test-Path (Join-Path $_.Root "NS_BACKUP")) } | ForEach-Object { $_.Root })
    }
    if ($roots.Count -eq 0) {
        Write-Host "     Жодного диска з текою NS_BACKUP не підключено — копію не зроблено." -ForegroundColor Yellow
        Write-Host "     Підключи диск(и) і запусти «Завершити день» ще раз." -ForegroundColor Yellow
        $result.backup = "диск не підключено"
    }
    $parts = @(); $fulls = @()
    foreach ($r in $roots) {
        $d = @{ Root = $r; Scope = $null; Years = @(); Jobs = @(); Result = "" }
        $scopeFile = Join-Path $r "NS_BACKUP\_scope.json"
        Write-Host ""
        Write-Host ("     Диск {0}  (вільно {1:N1} ГБ)" -f $r, ((Get-PSDrive $r.Substring(0, 1)).Free / 1GB)) -ForegroundColor White
        if (-not (Test-Path $scopeFile)) {
            Write-Host "       Немає _scope.json — диск НЕ ЧІПАЮ. Що на ньому берегти, скажи ns-backup:" -ForegroundColor Yellow
            Write-Host ("         .\ns-backup.ps1 -Dest {0} -Years <роки> -Jobs masters,pdf   (він запише _scope.json)" -f $r) -ForegroundColor DarkGray
            $d.Result = "без _scope.json — не чіпав"
            $parts += "$r $($d.Result)"; $disks += $d; continue
        }
        try { $d.Scope = Get-Content $scopeFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if (-not $d.Scope) {
            Write-Host "       _scope.json не читається — диск НЕ ЧІПАЮ." -ForegroundColor Red
            $d.Result = "_scope.json зіпсований"; $parts += "$r ЗБІЙ: $($d.Result)"; $disks += $d; continue
        }
        $d.Years = @($d.Scope.years | ForEach-Object { [int]$_ }); $d.Jobs = @($d.Scope.jobs)
        Write-Host ("       Береже: роки {0}; частини {1}" -f $(if ($d.Years.Count) { $d.Years -join ", " } else { "усі" }), ($d.Jobs -join ", "))
        $bp = @{ Dest = $r; Quick = $true; Jobs = ($d.Jobs -join ",") }
        if ($d.Years.Count) { $bp.Years = ($d.Years -join ",") }
        if ($DryRun) {
            $bp.DryRun = $true; $bp.Remove("Quick")
            $rc = Invoke-NsScript -Path (Join-Path $PSScriptRoot "ns-backup.ps1") -Params $bp
            $d.Result = switch ($rc) { 0 { "було б: ns-backup -Quick, місця досить" } 3 { "було б: ПРОПУЩЕНО за браком місця" } default { "було б: НЕ ВЛІЗЕ (код $rc)" } }
            $parts += "$r $($d.Result)"; $disks += $d; continue
        }
        $rc = Invoke-NsScript -Path (Join-Path $PSScriptRoot "ns-backup.ps1") -Params $bp
        if ($rc -eq 0 -or $rc -eq 3) {
            $d.Result = if ($rc -eq 3) { "ok, але ПРОПУЩЕНО за браком місця (червоні рядки вище)" } else { "ok" }
            if ($rc -eq 3) { Write-Host "       Частину не скопійовано — немає місця (див. вище)." -ForegroundColor Red }
            # повна звірка раз на 7 днів на кожному диску
            $lastFull = Get-LastLogTime ("повна звірка \[" + [regex]::Escape($r) + "\]: ok")
            if ($FullVerify -or -not $lastFull -or ((Get-Date) - $lastFull).TotalDays -ge 7) {
                Write-Host ""
                Write-Host "       Повна звірка копії за SHA-256 (раз на 7 днів; кілька хвилин)…" -ForegroundColor Cyan
                $vp = @{ Dest = $r; VerifyOnly = $true; Jobs = "masters" }
                if ($d.Years.Count) { $vp.Years = ($d.Years -join ",") }
                $rf = Invoke-NsScript -Path (Join-Path $PSScriptRoot "ns-backup.ps1") -Params $vp
                if ($rf -eq 0) { $fulls += "повна звірка [$r]: ok" }
                else { $fulls += "повна звірка [$r]: НЕ пройшла (код $rf)"; $d.Result = "$($d.Result); повна звірка НЕ пройшла"; Write-Host "       Повна звірка НЕ пройшла!" -ForegroundColor Red }
            }
        } else {
            $d.Result = "ЗБІЙ (код $rc)"
            Write-Host "       Резерв на $r не завершено — див. повідомлення вище." -ForegroundColor Red
        }
        $parts += "$r $($d.Result)"; $disks += $d
    }
    if ($roots.Count -gt 0) { $result.backup = ($parts -join "; ") }
    if ($fulls.Count) { $result.full = ($fulls -join "; ") }
}

# ------------------------------------------------------------------ 3. що не захищено
Write-Step "3. Скільки сторінок має копію"
$noCopyTotal = -1
$activeDisks = @($disks | Where-Object { $_.Scope })
if ($NoBackup) {
    Write-Host "     (пропущено разом із резервом)"
} elseif ($activeDisks.Count -eq 0) {
    $lb = Get-LastLogTime 'резерв: .*ok'
    if ($lb) { Write-Host ("     Диска немає; останній вдалий резерв за журналом: {0}." -f $lb.ToString("dd.MM.yyyy HH:mm")) }
    else { Write-Host "     Диска немає, і журнал не знає жодного резерву цим скриптом." -ForegroundColor Yellow }
} else {
    # копія сторінки = файл з тим самим розміром у NS_MASTERS\<рік>\<тека>\ на диску, чий _scope.json охоплює цей рік
    $byYear = @{}
    foreach ($dir in (Get-ChildItem $script:NS_MASTERS -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}$' })) {
        $y = [int]$dir.Name
        foreach ($idir in (Get-ChildItem $dir.FullName -Directory)) {
            $m = Read-NsManifest -IssueDir $idir.FullName
            if (-not $m) { continue }
            foreach ($p in @($m.pages)) {
                if (-not $byYear.ContainsKey($y)) { $byYear[$y] = @{ total = 0; copied = 0 } }
                $byYear[$y].total++
                foreach ($d in $activeDisks) {
                    if ($d.Jobs -notcontains "masters") { continue }
                    if ($d.Years.Count -and ($d.Years -notcontains $y)) { continue }
                    $cf = Join-Path $d.Root ("NS_BACKUP\NS_MASTERS\{0}\{1}\{2}" -f $y, $idir.Name, $p.file)
                    if ((Test-Path -LiteralPath $cf) -and ((Get-Item -LiteralPath $cf).Length -eq [long]$p.bytes)) { $byYear[$y].copied++; break }
                }
            }
        }
    }
    $noCopyTotal = 0
    foreach ($y in ($byYear.Keys | Sort-Object)) {
        $t = $byYear[$y].total; $c = $byYear[$y].copied; $w = $t - $c; $noCopyTotal += $w
        if ($w -eq 0) { Write-Host ("     {0}: {1} стор., усі мають копію" -f $y, $t) -ForegroundColor Green }
        else { Write-Host ("     {0}: {1} стор., БЕЗ КОПІЇ {2}" -f $y, $t, $w) -ForegroundColor $(if ($c -eq 0) { "Red" } else { "Yellow" }) }
    }
    if ($noCopyTotal -gt 0) {
        Write-Host ("     УСЬОГО БЕЗ КОПІЇ: {0} стор. — потрібен диск (або вільне місце) для років, де копії немає." -f $noCopyTotal) -ForegroundColor Red
    } else {
        Write-Host "     Усі сторінки каталогу мають копію на підключених дисках." -ForegroundColor Green
    }
    foreach ($d in $activeDisks) { Write-Host ("     Диск {0}: вільно {1:N1} ГБ" -f $d.Root, ((Get-PSDrive $d.Root.Substring(0, 1)).Free / 1GB)) -ForegroundColor DarkGray }
}

# ------------------------------------------------------------------ журнал
$entry = "{0}  git: {1}; push: {2}; резерв: {3}; {4}; без копії: {5}" -f (Get-Date).ToString("s"), $result.git, $result.push, $result.backup,
         $(if ($result.full -like "повна звірка*") { $result.full } else { "повна звірка: " + $result.full }), $(if ($noCopyTotal -ge 0) { $noCopyTotal } else { "не рахувалось" })
if (-not $DryRun) { Add-Content -Path $logFile -Value $entry -Encoding UTF8 }

Write-Host ""
Write-Host "  $line" -ForegroundColor DarkGray
Write-Host ("  git    : {0}" -f $result.git)
Write-Host ("  push   : {0}" -f $result.push)
Write-Host ("  резерв : {0}" -f $result.backup)
Write-Host ("  звірка : {0}" -f $result.full)
if ($noCopyTotal -ge 0) { Write-Host ("  без копії: {0} стор." -f $noCopyTotal) -ForegroundColor $(if ($noCopyTotal -gt 0) { "Red" } else { "Green" }) }
Write-Host ""
$bad = @($result.Values | Where-Object { $_ -match 'НЕ ВДАВСЯ|ЗБІЙ|НЕ пройшла' }).Count
if ($bad -gt 0) { exit 1 }
exit 0
