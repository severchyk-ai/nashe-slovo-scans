# Головне меню конвеєра «Наше слово».
#
# Точка входу для ярлика з робочого столу. Ярлик не вміє передавати аргументи,
# тому все, що потрібно знати (номер, дата, номер у році), меню питає саме —
# і саме ж підказує, бо газета тижнева: наступний номер = попередній + 1,
# наступна дата = попередня + 7 днів.
#
# Права адміністратора НЕ потрібні: запис іде лише в C:\NS_MASTERS, NS_WORK, NS_PDF.

try { $Host.UI.RawUI.WindowTitle = "Наше слово — архів" } catch { }
try {
    $b = $Host.UI.RawUI.BufferSize; $b.Width = 100; $b.Height = 3000
    $Host.UI.RawUI.BufferSize = $b
    $w = $Host.UI.RawUI.WindowSize; $w.Width = 100; $w.Height = 34
    $Host.UI.RawUI.WindowSize = $w
} catch { }

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole
# вікно меню — одразу в нижню смугу X24ih, під майбутнє вікно перегляду
# (оператор тримає консоль там; 21.09.2026). Другого монітора немає — лишається де є.
$null = Move-NsConsoleBelowViewer

$line = "-" * 74

function Show-NsOverview {
    <#  Шапка: скільки вже зроблено і де саме зупинилися. #>
    $rows = @(Read-NsRegistry)
    Write-Host ""
    Write-Host "  НАШЕ СЛОВО - архів" -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor DarkGray

    if ($rows.Count -eq 0) {
        Write-Host "  Каталог порожній." -ForegroundColor Yellow
        Write-Host ""
        return $rows
    }

    $pages = ($rows | Measure-Object -Property pages -Sum).Sum
    $bytes = ($rows | ForEach-Object { [long]$_.bytes } | Measure-Object -Sum).Sum
    $last  = $rows | Sort-Object { [int]$_.seq_first } | Select-Object -Last 1

    Write-Host ("  Каталог  : {0} номерів, {1} сторінок, {2:N1} ГБ" -f `
                $rows.Count, $pages, ($bytes / 1GB))
    Write-Host ("  Останній : {0}  ({1}, № {2} у році)" -f `
                $last.seq_first, $last.date, $last.issue_no_in_year)

    $gaps = @(Test-NsSeqContinuity)
    if ($gaps.Count -gt 0) {
        Write-Host "  УВАГА    : розриви в нумерації:" -ForegroundColor Yellow
        $gaps | ForEach-Object { Write-Host "             $_" -ForegroundColor Yellow }
    }
    Write-Host ""
    return $rows
}

function Get-NsUnfinished {
    <#  Номери, які почали, але не довели до кінця, або довели не до очікуваної
        кількості сторінок. Обидва випадки потребують уваги оператора, тому
        обидва лишаються в меню, доки він їх не закриє. #>
    param($Rows)
    @($Rows | Where-Object { $_.status -eq "scanning" -or $_.status -eq "qc_flagged" } |
              Sort-Object { [int]$_.seq_first })
}

function Get-NsSuggestion {
    <#  Підказати метадані наступного номера з тижневої закономірності.
        Рік змінився - нумерація в році починається спочатку.

        Тиждень відлічується від КІНЦЯ того, що покриває останній номер, а не
        від його дати. Різниця виникає на здвоєних тижнях: 2265 датований
        24 грудня, але в шапці стоїть «2000.12.24-31», тож наступний номер
        вийшов 7 січня 2001, а не 31 грудня 2000. Кінець покриття лежить у
        полі covers маніфеста (реєстр його не зберігає), тож читаємо маніфест. #>
    param($Rows)
    if ($Rows.Count -eq 0) { return $null }
    $last = $Rows | Sort-Object { [int]$_.seq_last } | Select-Object -Last 1
    $from = [datetime]::ParseExact($last.date, "yyyy-MM-dd", $null)
    $dir = Find-NsIssueDir -Seq ([int]$last.seq_last)
    if ($dir) {
        $lm = Read-NsManifest -IssueDir $dir
        if ($lm -and $lm.PSObject.Properties.Name -contains 'covers' -and $lm.covers -match '\.\.\s*(\d{4}-\d{2}-\d{2})') {
            $end = [datetime]::ParseExact($Matches[1], "yyyy-MM-dd", $null)
            if ($end -gt $from) { $from = $end }
        }
    }
    $d = $from.AddDays(7)
    $noInYear = if ($d.Year -eq [int]$last.year) { [int]$last.issue_no_in_year + 1 } else { 1 }
    $seq = [int]$last.seq_last + 1
    # номери, яких фізично немає (missing.csv), пропускаємо — із їхнім тижнем
    $miss = @(Get-NsMissing | ForEach-Object { [int]$_.seq })
    while ($miss -contains $seq) {
        $seq++
        $y = $d.Year; $d = $d.AddDays(7)
        $noInYear = if ($d.Year -eq $y) { $noInYear + 1 } else { 1 }
    }
    [pscustomobject]@{
        seq      = $seq
        date     = $d.ToString("yyyy-MM-dd")
        noInYear = $noInYear
    }
}

function Read-NsField {
    <#  Запит із підказкою: Enter приймає запропоноване. #>
    param([string]$Label, [string]$Default)
    $v = Read-Host ("  {0} [{1}]" -f $Label, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Invoke-NsNewIssue {
    <#  Завести й відсканувати новий номер. Усі поля з підказками. #>
    param($Suggestion)
    Write-Host ""
    Write-Host "  НОВИЙ НОМЕР" -ForegroundColor Cyan
    Write-Host "  Enter приймає значення в дужках." -ForegroundColor DarkGray
    Write-Host ""

    $seq  = Read-NsField -Label "Наскрізний номер   " -Default $(if ($Suggestion) { $Suggestion.seq } else { "" })
    if ($seq -notmatch '^\d+$') { Write-Host "  Номер має бути числом." -ForegroundColor Red; return }

    $date = Read-NsField -Label "Дата (РРРР-ММ-ДД)  " -Default $(if ($Suggestion) { $Suggestion.date } else { "" })
    if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host "  Дата має бути РРРР-ММ-ДД." -ForegroundColor Red; return }

    $noy  = Read-NsField -Label "Номер у році       " -Default $(if ($Suggestion) { $Suggestion.noInYear } else { "" })
    if ($noy -notmatch '^\d+$') { Write-Host "  Номер у році має бути числом." -ForegroundColor Red; return }

    $pgs  = Read-NsField -Label "Скільки сторінок   " -Default "10"
    if ($pgs -notmatch '^\d+$') { Write-Host "  Кількість має бути числом." -ForegroundColor Red; return }

    # Здвоєний номер: 2245/2246 в одному випуску. Порожньо = одинарний.
    $lastSeq = Read-NsField -Label "Здвоєний до номера " -Default $seq
    if ($lastSeq -notmatch '^\d+$') { Write-Host "  Номер має бути числом." -ForegroundColor Red; return }

    Write-Host ""
    Write-Host ("  Заводжу: {0}" -f $(if ($lastSeq -ne $seq) { "$seq/$lastSeq" } else { $seq })) -ForegroundColor Green
    Write-Host ("           {0}, № {1} у році, {2} сторінок" -f $date, $noy, $pgs) -ForegroundColor Green
    $ok = Read-Host "  Правильно? [Enter = так, N = ні]"
    if ($ok -match '^[NnНн]') { Write-Host "  Скасовано." -ForegroundColor Yellow; return }

    & "$PSScriptRoot\ns-scan.ps1" -Seq ([int]$seq) -Date $date -NoInYear ([int]$noy) `
                                  -PagesExpected ([int]$pgs) -SeqLast ([int]$lastSeq)
}

# ------------------------------------------------------------------ головний цикл

try {
    if (-not (Test-NsTools -Need scan)) {
        Write-Host ""
        Write-Host "  Бракує інструментів для сканування." -ForegroundColor Red
    }
    Initialize-NsStore

    while ($true) {
        Clear-Host
        $rows       = Show-NsOverview
        $unfinished = @(Get-NsUnfinished -Rows $rows)
        $sugg       = Get-NsSuggestion -Rows $rows

        Write-Host "  $line" -ForegroundColor DarkGray

        $n = 0
        $actions = @{}

        foreach ($u in $unfinished) {
            $n++
            $actions["$n"] = @{ kind = "resume"; seq = [int]$u.seq_first }
            Write-Host ("  [{0}]  Продовжити {1}  ({2}, поки {3} стор., {4})" -f `
                        $n, $u.seq_first, $u.date, $u.pages, $u.status) -ForegroundColor Yellow
        }

        # відскановані, але ще не прийняті (станція 1a): state = scanned. Старі номери без поля state не чіпаємо.
        $toAccept = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'state' -and $_.state -eq "scanned" } |
                              Sort-Object { [int]$_.seq_first })
        foreach ($u in $toAccept) {
            $n++
            $actions["$n"] = @{ kind = "accept"; seq = [int]$u.seq_first }
            Write-Host ("  [{0}]  Прийняти номер {1}  ({2}, {3} стор.) — підвали й перевірка" -f $n, $u.seq_first, $u.date, $u.pages) -ForegroundColor Yellow
        }

        $n++
        $actions["$n"] = @{ kind = "new" }
        if ($sugg) {
            Write-Host ("  [{0}]  Новий номер   {1}   {2}   № {3} у році" -f `
                        $n, $sugg.seq, $sugg.date, $sugg.noInYear) -ForegroundColor Green
        } else {
            Write-Host ("  [{0}]  Новий номер" -f $n) -ForegroundColor Green
        }

        $n++; $actions["$n"] = @{ kind = "verify" }
        Write-Host ("  [{0}]  Перевірити цілісність каталогу (хеші всіх сторінок)" -f $n)

        $n++; $actions["$n"] = @{ kind = "open" }
        Write-Host ("  [{0}]  Відкрити теку каталогу" -f $n)

        $ready = @($rows | Where-Object { $_.status -eq "scanned" -and -not ($_.PSObject.Properties.Name -contains 'state' -and $_.state -in @("scanning", "scanned")) } |
                           Sort-Object { [int]$_.seq_first })
        $n++; $actions["$n"] = @{ kind = "pdf"; ready = $ready }
        if ($ready.Count -gt 0) {
            Write-Host ("  [{0}]  Зібрати PDF   готових до збірки: {1}" -f `
                        $n, (($ready | ForEach-Object { $_.seq_first }) -join ', ')) -ForegroundColor Green
        } else {
            Write-Host ("  [{0}]  Зібрати PDF                     (готових номерів немає)" -f $n) -ForegroundColor DarkGray
        }

        $n++; $actions["$n"] = @{ kind = "endday" }
        Write-Host ("  [{0}]  Завершити день   (зберегти роботу: git + резерв на диск)" -f $n) -ForegroundColor Cyan

        Write-Host "  [Q]  Вихід"
        Write-Host "  $line" -ForegroundColor DarkGray
        Write-Host ""

        $choice = Read-Host "  Вибір"
        if ($choice -match '^[QqКк]') { break }
        if (-not $actions.ContainsKey($choice.Trim())) { continue }

        $a = $actions[$choice.Trim()]
        Write-Host ""
        switch ($a.kind) {
            "resume" { & "$PSScriptRoot\ns-scan.ps1" -Seq $a.seq }
            "accept" { & "$PSScriptRoot\ns-accept.ps1" -Seq $a.seq }
            "new"    { Invoke-NsNewIssue -Suggestion $sugg }
            "verify" { & "$PSScriptRoot\ns-verify.ps1" }
            "open"   { Start-Process explorer.exe $script:NS_MASTERS }
            "endday" { & "$PSScriptRoot\ns-endday.ps1" }
            "pdf"    {
                if ($a.ready.Count -gt 0) {
                    Write-Host ("  Готові до збірки: {0}" -f (($a.ready | ForEach-Object { $_.seq_first }) -join ', '))
                } else {
                    Write-Host "  Нових номерів для збірки немає — усі вже зібрані." -ForegroundColor Yellow
                }
                Write-Host "  Збірка триває близько 13 хвилин на номер." -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  [Enter]  зібрати нові"
                Write-Host "  номер    зібрати один (можна вже зібраний — перезбереться)"
                Write-Host "  R        ПЕРЕЗІБРАТИ ВСЕ наново — коли змінився сам конвеєр"
                $which = Read-Host "  Вибір"
                if ([string]::IsNullOrWhiteSpace($which)) {
                    if ($a.ready.Count -gt 0) { & "$PSScriptRoot\ns-issue.ps1" -All }
                    else { Write-Host "  Нічого збирати." -ForegroundColor Yellow }
                } elseif ($which -match '^[RrПп]') {
                    & "$PSScriptRoot\ns-issue.ps1" -Rebuild
                } elseif ($which -match '^\d+$') {
                    & "$PSScriptRoot\ns-issue.ps1" -Seq ([int]$which) -Force
                } else {
                    Write-Host "  Не зрозумів — скасовано." -ForegroundColor Yellow
                }
            }
        }
        Write-Host ""
        Read-Host "  [Enter] — до меню" | Out-Null
    }
}
catch {
    # Вікно запущене з ярлика: без цього повідомлення про помилку зникне
    # разом із вікном, і причина лишиться невідомою.
    Write-Host ""
    Write-Host "  ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  [Enter] — закрити" | Out-Null
}
