# Сканування номера з негайною реєстрацією кожної сторінки.
# Заміна scan_issue.bat: сканує І одразу вносить сторінку в каталог, тому
# окремий процес-сторож не потрібен.
#
#   .\ns-scan.ps1 -Seq 2231 -Date 2000-04-30 -NoInYear 18
#   .\ns-scan.ps1 -Seq 2231            — продовжити перерваний номер
#
# Enter = сканувати наступну сторінку, Q = завершити.
# На другому (вертикальному) моніторі відкривається ns-viewer.ps1: щойно
# відсканована сторінка, збільшений кут із номером і п'ять перевірок
# (розмір, кадри, порожній кадр, та сама сторінка ще раз, смуга кришки).
# Вимкнути: -NoView.
# Обрив живлення коштує щонайбільше однієї сторінки: сторінка вважається
# прийнятою лише після хешування, перейменування, read-only і запису в маніфест.

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [string]$Date,
    [int]$NoInYear,
    [int]$PagesExpected = 10,
    [int]$SeqLast,
    [string]$Source = "розшитий річник",
    [string]$Operator = "sever",
    [switch]$NoView,
    [switch]$NoAccept,           # не запускати приймання (ns-accept) після Q
    [string]$Insert              # сторінки вкладки зі своєю нумерацією: "9-14"
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (-not (Test-NsTools -Need scan)) { Write-Host "Бракує інструментів — зупинка." -ForegroundColor Red; exit 1 }
Initialize-NsStore

# --- знайти наявний номер або створити новий -------------------------------
$issueDir = $null
if ($Date) {
    $issueDir = Get-NsIssueDir -SeqFirst $Seq -Date $Date
} else {
    # дату не вказано — шукаємо вже створену теку цього номера
    $found = Get-ChildItem -Path $script:NS_MASTERS -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "${Seq}_*" }
    if ($found.Count -eq 1) {
        $issueDir = $found[0].FullName
    } elseif ($found.Count -gt 1) {
        Write-Host "Знайдено кілька тек для номера ${Seq}: $($found.Name -join ', ')" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "Номер $Seq ще не заведено. Вкажи -Date і -NoInYear." -ForegroundColor Red
        exit 1
    }
}

$man = Read-NsManifest -IssueDir $issueDir
if (-not $man) {
    if (-not $Date -or -not $NoInYear) {
        Write-Host "Новий номер потребує -Date РРРР-ММ-ДД і -NoInYear." -ForegroundColor Red
        exit 1
    }
    if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') {
        Write-Host "Дата має бути у форматі РРРР-ММ-ДД." -ForegroundColor Red; exit 1
    }
    if (-not $SeqLast) { $SeqLast = $Seq }      # одинарний номер = окремий випадок здвоєного
    New-Item -ItemType Directory -Path $issueDir -Force | Out-Null
    $man = New-NsManifest -SeqFirst $Seq -SeqLast $SeqLast -Date $Date -NoInYear $NoInYear `
                          -PagesExpected $PagesExpected -Source $Source -Operator $Operator
    $man.scan_date = (Get-Date).ToString("yyyy-MM-dd")
    $man.status = "scanning"
    Set-NsIssueState -IssueDir $issueDir -Manifest $man -State "scanning" -Note "заведено"
    Write-Host "Заведено номер $Seq ($Date, № $NoInYear у році)." -ForegroundColor Green
}

# Номер, що вже мав стан конвеєра (scanned/accepted), продовжують сканувати — стан знову scanning:
# інакше нічна зміна взяла б неповний номер.
if ((Get-NsIssueState $man) -in @("scanned", "accepted", "review", "fix", "ready")) {
    Set-NsIssueState -IssueDir $issueDir -Manifest $man -State "scanning" -Note "продовження сканування"
}

# --- відновлення: що вже надійно прийнято ----------------------------------
$durable = @($man.pages | Where-Object { Test-NsPageDurable -IssueDir $issueDir -PageEntry $_ })
if ($durable.Count -ne @($man.pages).Count) {
    Write-Host "УВАГА: у маніфесті $(@($man.pages).Count) сторінок, але надійних лише $($durable.Count)." -ForegroundColor Red
    Write-Host "Розберися вручну перед продовженням." -ForegroundColor Red
    exit 1
}
$orphans = @(Find-NsOrphans -IssueDir $issueDir -Manifest $man)
if ($orphans.Count -gt 0) {
    Write-Host "УВАГА: у теці є файли поза маніфестом (ймовірно обірваний запис):" -ForegroundColor Yellow
    $orphans | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Yellow }
    Write-Host "Вони НЕ підхоплюються автоматично. Прибери або перейменуй їх вручну." -ForegroundColor Yellow
}

if ($Insert) {
    $man | Add-Member -NotePropertyName insert_pages -NotePropertyValue $Insert -Force
    Write-NsManifest -IssueDir $issueDir -Manifest $man
    Write-Host "  вкладка зі своєю нумерацією: сторінки $Insert (записано в маніфест)" -ForegroundColor Yellow
}

$next = [int](Get-NsNextPage -Manifest $man)
$log  = Join-Path $issueDir "_scan.log"

Write-Host ""
Write-Host "  Номер   : $($man.seq_first)  ($($man.date), № $($man.issue_no_in_year) у році)"
Write-Host "  Тека    : $issueDir"
Write-Host "  Профіль : $script:NAPS2_PROFILE"
Write-Host "  Готово  : $($durable.Count) з $($man.pages_expected) сторінок"
Write-Host ""
# Попередження про прогрів лампи ПРИБРАНО 11.09.2026.
# Гіпотеза була: на холодному пуску колір паперу дрейфує перші ~15 хв.
# Спростовано двома дослідами. Останній: сканер вимкнено кнопкою на ніч
# (19 год), уранці ввімкнено й одразу, без очікування, знято 10 сторінок —
# відтінок B-R від першої ж сторінки +2, тобто рівноважне значення.
# Справжня причина відмінності номера 2214, з якої все почалося, — інший
# папір: новорічний номер надруковано на цупкішому глянцевому стоку
# (підтверджено виміром і оком оператора).
# Мітка last_scan лишається: вона нічого не коштує й може згодитися.

# --- живий перегляд на другому моніторі -----------------------------------
function Show-LiveWarnings($w) {
    foreach ($x in @($w)) {
        $col = if ($x.lvl -eq "err") { "Red" } else { "Yellow" }
        Write-Host "  [!] $($x.text)" -ForegroundColor $col
    }
}
if (-not $NoView) {
    Get-ChildItem $script:NS_LIVE -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if (-not (Move-NsConsoleBelowViewer)) {
        Write-Host "  (перегляд займе верх другого монітора — тримай це вікно в нижній смузі екрана)" -ForegroundColor DarkGray
    }
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", "`"$(Join-Path $PSScriptRoot 'ns-viewer.ps1')`"", "-ParentPid", "$PID")
    # працівник швидкого показу: живе, поки живе це вікно (ns-fastpreview.py)
    $fp = Join-Path $PSScriptRoot "ns-fastpreview.py"
    if ($script:PYTHON -and (Test-Path $fp)) {
        Start-Process -FilePath $script:PYTHON -WindowStyle Hidden -ArgumentList @("`"$fp`"", "`"$script:NS_LIVE`"", "$PID")
        $script:NS_FASTWORKER = $true
    }
    $pp = @($man.pages | Sort-Object { [int]$_.n })
    if ($pp.Count -gt 0) {
        # продовження номера: показати останню прийняту сторінку
        $lastP = $pp[-1]
        $prevF = if ($pp.Count -gt 1) { Join-Path $issueDir $pp[-2].file } else { "" }
        $null = Update-NsLive -Tif (Join-Path $issueDir $lastP.file) -Seq $man.seq_first -Page ([int]$lastP.n) `
                              -Expected $man.pages_expected -PrevTif $prevF -IssueDir $issueDir -Insert $(if ($man.PSObject.Properties.Name -contains 'insert_pages') { $man.insert_pages } else { '' })
    }
}

Write-Host "  Enter        — сканувати сторінку $next"
Write-Host "  R + Enter    — перезняти останню відскановану сторінку"
Write-Host "  V + Enter    — позначити сторінки вкладки зі своєю нумерацією"
Write-Host "  Q + Enter    — завершити номер"
Write-Host ""

# Відхилений скан НЕ знищується (24.09.2026: у 2355 зник кадр, який оператор бачив
# на екрані, а скрипт мовчки видалив його як «порожній/чорний» чи «розпався»).
# Тепер він іде в _rejected з причиною в імені й рядком у _scan.log.
function Move-NsRejected {
    param([string]$Path, [int]$Page, [string]$Reason)
    $rd = Join-Path $issueDir "_rejected"
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $dst = Join-Path $rd ("p{0:D2}_{1}_{2}.tif" -f $Page, (Get-Date -Format "HHmmss"), $Reason)
    Move-Item -Path $Path -Destination $dst -Force -ErrorAction SilentlyContinue
    Add-Content -Path $log -Value ("{0}  ВІДХИЛЕНО стор {1:D2}  {2}  -> {3}" -f (Get-Date).ToString("s"), $Page, $Reason, (Split-Path $dst -Leaf)) -Encoding UTF8
    Write-Host "      Файл збережено, не видалено: $dst" -ForegroundColor DarkYellow
}

while ($true) {
    # Без двокрапки в кінці: Read-Host додає свою.
    $last = $next - 1
    $prompt = if ($last -ge 1) { "  [Enter] сторінка $next   [R] перезняти стор. $last   [V] вкладка   [Q] завершити" } else { "  [Enter] сторінка $next   [V] вкладка   [Q] завершити" }
    $ans = Read-Host -Prompt $prompt
    if ($ans -match '^[QqКк]') { break }

    # R — перезняти останню сторінку (21.09.2026): оператор побачив тривогу чи
    # не той номер у куті на другому моніторі. Заміна — через ns-rescan: старий
    # майстер відкладається в _catalog\removed, у маніфесті поле replaced.
    # V — позначити вкладку зі своєю нумерацією просто під час сканування:
    # оператор бачить її аж тоді, коли до неї доходить (2332, «Світанок» 3-8).
    if ($ans -match '^[VvМм]') {
        $rng = Read-Host "  Сторінки вкладки (напр. 3-8; порожньо — прибрати позначку)"
        if ($rng.Trim()) {
            & (Join-Path $PSScriptRoot "ns-insert.ps1") -Seq $man.seq_first -Pages $rng.Trim()
        } else {
            & (Join-Path $PSScriptRoot "ns-insert.ps1") -Seq $man.seq_first -Clear
        }
        $man = Read-NsManifest -IssueDir $issueDir
        continue
    }

    if ($ans -match '^[RrРр]') {
        if ($last -lt 1) { continue }
        if (-not $NoView) { Set-NsLiveStatus -Status "scanning" -Page $last }
        & (Join-Path $PSScriptRoot "ns-rescan.ps1") -Seq $man.seq_first -Page $last -Reason "перезнято одразу під час сканування"
        $man = Read-NsManifest -IssueDir $issueDir
        if (-not $NoView) {
            $prevF = if ($last -gt 1) { Join-Path $issueDir (Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page ($last - 1)) } else { "" }
            $lw = Update-NsLive -Tif (Join-Path $issueDir (Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page $last)) `
                                -Seq $man.seq_first -Page $last -Expected $man.pages_expected -PrevTif $prevF -IssueDir $issueDir -Insert $(if ($man.PSObject.Properties.Name -contains 'insert_pages') { $man.insert_pages } else { '' })
            Show-LiveWarnings $lw
        }
        continue
    }

    $tmp = Join-Path $issueDir ("_incoming_p{0:D2}.tif" -f $next)
    if (Test-Path $tmp) { Remove-Item $tmp -Force }

    if (-not $NoView) { Set-NsLiveStatus -Status "scanning" -Page $next }
    & $script:NAPS2 -p $script:NAPS2_PROFILE -o $tmp --tiffcomp lzw 2>&1 | Out-Null
    if (-not $NoView -and -not (Test-Path $tmp)) { Set-NsLiveStatus -Status "ready" }

    if (-not (Test-Path $tmp)) {
        Write-Host "  [!] Скан не вдався (сканер міг заснути). Спробуй ще раз ту саму сторінку." -ForegroundColor Yellow
        continue
    }
    # ПОКАЗ ІДЕ ПЕРШИМ (23.09.2026, прохання оператора; з 24.09 — ще до перевірок
    # файла й кадрів, вони після): один запуск ImageMagick,
    # ~0,7 с — і сторінка вже на другому моніторі. Заразом він дає середнє й
    # розкид, тож порожній кадр відсіюється тут-таки, без другого декодування.
    $ins = if ($man.PSObject.Properties.Name -contains 'insert_pages') { $man.insert_pages } else { "" }
    $stat = $null
    if (-not $NoView) {
        $stat = Show-NsLiveFast -Tif $tmp -Seq $man.seq_first -Page $next -Expected $man.pages_expected -Insert $ins
    } else {
        $sv = (& magick "$tmp[0]" -resize 12% -colorspace Gray -format "%[fx:mean] %[fx:standard_deviation]" info: 2>$null) -split ' '
        if ($sv.Count -ge 2) { $stat = @{ Mean = [double]::Parse($sv[0], [Globalization.CultureInfo]::InvariantCulture)
                                          Sd   = [double]::Parse($sv[1], [Globalization.CultureInfo]::InvariantCulture) } }
    }
    # переконатися, що файл дописано і читається (-ping: лише заголовок; без нього
    # identify декодує 65 МБ, 0,6 с — 24.09.2026 заміряно)
    $probe = & magick identify -ping -format "%wx%h" $tmp 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $probe) {
        Write-Host "  [!] Файл пошкоджений або недописаний — сторінку не зараховано." -ForegroundColor Yellow
        Move-NsRejected -Path $tmp -Page $next -Reason "nechytnyy"
        continue
    }
    # Аркуш має лягти ОДНИМ кадром. Кілька кадрів — обрізка розрізала сторінку
    # на ділянки, і частина між ними може бути втрачена (див. Get-NsFrameCount).
    $frames = Get-NsFrameCount -Path $tmp
    if ($frames -ne 1) {
        Write-Host "  [!] Скан розпався на $frames окремих кадрів — обрізка сканера розрізала аркуш." -ForegroundColor Yellow
        Write-Host "      Сторінку не зараховано. Поправ аркуш і скануй ще раз; якщо повториться — сказати Claude." -ForegroundColor Yellow
        Move-NsRejected -Path $tmp -Page $next -Reason "kadry$frames"
        continue
    }

    # Порожній/чорний кадр НЕ зараховується: це скан порожнього скла (2332 —
    # зайвий кадр наприкінці номера). Ознака та сама, що в 2240/11.
    # 24.09.2026: темний кольоровий аркуш (обкладинка) має середнє < 0,35, але великий
    # розкид; порожнє скло — розкид ~0,016. Раніше «середнє < 0,35» саме по собі
    # відхиляло такий аркуш.
    if ($stat -and ($stat.Sd -lt 0.05 -or ($stat.Mean -lt 0.35 -and $stat.Sd -lt 0.08))) {
        Write-Host ("  [!] Порожній або чорний кадр (середнє {0:N2}, розкид {1:N2}) — сторінку НЕ зараховано." -f $stat.Mean, $stat.Sd) -ForegroundColor Red
        Write-Host "      Поклади аркуш і скануй цю ж сторінку ще раз. Якщо аркуш справді не порожній — скажи Claude, кадр збережено." -ForegroundColor Yellow
        Move-NsRejected -Path $tmp -Page $next -Reason (("porozhniy_mean{0:N2}_sd{1:N2}" -f $stat.Mean, $stat.Sd) -replace ",", ".")
        if (-not $NoView) { Set-NsLiveStatus -Status "ready" }
        continue
    }

    $name = Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page $next
    Move-Item -Path $tmp -Destination (Join-Path $issueDir $name) -Force
    $entry = Add-NsPage -IssueDir $issueDir -Manifest $man -PageNo $next -FileName $name

    # Реєстр оновлюємо на кожній сторінці, а не лише в кінці: перерваний скан
    # інакше лишає рядок із нулем сторінок, і зведення в меню бреше.
    Set-NsRegistryRow -Manifest $man -Status "scanning" `
                      -Bytes (@($man.pages) | Measure-Object -Property bytes -Sum).Sum
    Set-NsLastScanTime

    Add-Content -Path $log -Value ("{0}  стор {1:D2}  {2}  {3} байт  {4}" -f `
        $entry.scanned_at, $next, $probe, $entry.bytes, $entry.sha256) -Encoding UTF8

    Write-Host ("  збережено: {0}  ({1}, {2:N0} МБ)" -f $name, $probe, ($entry.bytes / 1MB)) -ForegroundColor Green
    if (-not $NoView) {
        # перевірки — ОКРЕМИМ ПРОЦЕСОМ: консоль одразу пропонує наступний скан,
        # а тривоги дописуються в перегляд за кілька секунд
        Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", "`"$(Join-Path $PSScriptRoot 'ns-livecheck.ps1')`"",
            "-Seq", "$($man.seq_first)", "-Page", "$next")
    }
    $next++
}

# --- завершення ------------------------------------------------------------
$count = @($man.pages).Count

# Нічого не відскановано — прибрати заготовку, щоб не лишати порожній номер
# у каталозі. Втрачати нічого: жодного файлу не створено.
if ($count -eq 0) {
    if (-not $NoView) { Set-NsLiveStatus -Status "done" }
    Remove-Item -Path $issueDir -Recurse -Force -ErrorAction SilentlyContinue
    $rows = @(Read-NsRegistry | Where-Object { [int]$_.seq_first -ne [int]$man.seq_first })
    Write-NsRegistry -Rows $rows
    Write-Host ""
    Write-Host "Жодної сторінки не відскановано — заготовку номера $($man.seq_first) прибрано." -ForegroundColor Yellow
    exit 0
}
$man.status = if ($count -eq $man.pages_expected) { "scanned" } else { "qc_flagged" }
Set-NsIssueState -IssueDir $issueDir -Manifest $man -State "scanned" -Note ("Q: {0} стор. із {1} заявлених" -f $count, $man.pages_expected)

if ($count -gt 0) {
    $sumFile = Join-Path $script:CHECKSUMS "$($man.seq_first).sha256"
    $lines = @(foreach ($p in $man.pages) { "$($p.sha256)  $($p.file)" })
    [IO.File]::WriteAllLines($sumFile, $lines, [Text.UTF8Encoding]::new($false))
}

# --- приймання (станція 1a): технічна перевірка, підвали всіх сторінок, Enter = прийнято ---
if (-not $NoAccept) {
    $acc = @{ Seq = [int]$man.seq_first }
    if ($NoView) { $acc.NoView = $true }
    & "$PSScriptRoot\ns-accept.ps1" @acc
    $man = Read-NsManifest -IssueDir $issueDir       # приймання могло змінити pages_expected, status, state
    $count = @($man.pages).Count
}
if (-not $NoView) { Set-NsLiveStatus -Status "done" }

Write-Host ""
if ($count -eq $man.pages_expected) {
    Write-Host "Номер $($man.seq_first) завершено: $count сторінок." -ForegroundColor Green
} else {
    Write-Host "Номер $($man.seq_first): $count сторінок, а очікувалось $($man.pages_expected) — позначено qc_flagged." -ForegroundColor Yellow
}
