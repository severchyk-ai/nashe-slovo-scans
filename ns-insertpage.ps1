# Вставити пропущену сторінку в уже відсканований номер і зсунути наступні.
#
#   .\ns-insertpage.ps1 -Seq 2372 -Page 5 -Reason "п'яту пропустили при скануванні"
#   .\ns-insertpage.ps1 -Seq 2372 -Page 5 -DryRun        лише показати план зсуву
#   .\ns-insertpage.ps1 -Seq 2372 -Page 10 -FromFile "C:\NS_MASTERS\_catalog\removed\...tif"
#   .\ns-insertpage.ps1 -Seq 2372 -Recover       після обірваної вставки: імена за хешем назад
#
# Навіщо: оператор фізично пропустив аркуш при скануванні (не поклав його на
# скло), і все, що йшло після нього, лягло під ЧУЖИМИ номерами файлів — стор.
# «5» насправді містить друковану 6, «6» — друковану 7, і так до кінця.
# Дзеркало ns-droppage.ps1 (той прибирає зайву й зсуває наступні ВНИЗ; цей
# додає бракуючу й зсуває наступні ВГОРУ), з тим самим двофазним
# перейменуванням, щоб не зачепити ще не перенесений файл чужим ім'ям.
#
# 29.09.2026: номер 2372 виправляли вручну — п'ять окремих замін (ns-rescan)
# поспіль, бо заміна вміє тільки підмінити ІСНУЮЧУ сторінку, а не вставити
# нову й зсунути решту. Цей скрипт робить те саме одним викликом.
#
# Порядок: спершу сканується (або береться -FromFile) і перевіряється НОВА
# сторінка — якщо скан невдалий, ніщо в номері ще не займано; лише після
# цього зсуваються наступні файли (два проходи: спершу на тимчасові імена,
# тоді на остаточні, як у ns-droppage) і новий скан лягає на звільнене місце.
# Майстер не знищується: сторінки не видаляються, лише перейменовуються;
# у маніфесті шифрованих зсунутих сторінок лишається renamed_from.
# -Page може дорівнювати (кількість сторінок + 1) — це просто додавання в
# кінець, без жодного зсуву (те саме, що звичайне сканування наступної).

param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [int]$Page = 0,
    [string]$Reason = "вставлено пропущену сторінку",
    [string]$FromFile = "",
    [switch]$DryRun,
    [switch]$Recover
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir

# Сліди обірваної вставки (журнал, тимчасові імена, недокладений новий скан).
# Маніфест пишеться лише ПІСЛЯ зсуву, тож він — ціль відновлення: файли
# повертаються до його імен за хешем, а новий скан лягає в _rejected (не
# знищується). Якщо маніфест уже записано, а звірка впала, — та сама дія
# приводить диск до маніфесту.
$journal = Join-Path $issueDir "_insert.json"
$traces = @(Get-ChildItem -LiteralPath $issueDir -File |
    Where-Object { $_.Name -eq "_insert.json" -or $_.Name -like "*.ins_tmp" -or $_.Name -like "*.rst_tmp" -or $_.Name -like "_incoming_ins_*" })
if ($Recover) {
    if ($traces.Count -eq 0) { Write-Host "Слідів обірваної вставки в $Seq немає." -ForegroundColor Green }
    foreach ($t in $traces) { Write-Host "  слід: $($t.Name)" }
    $lost = @(Restore-NsNamesByHash -IssueDir $issueDir -Manifest $man)
    if ($lost.Count) { Write-Host "За хешем НЕ знайдено: $($lost -join ', ') — нічого далі не чіпаю." -ForegroundColor Red; exit 1 }
    $bad = 0
    foreach ($p in $man.pages) {
        Set-ItemProperty -LiteralPath (Join-Path $issueDir $p.file) -Name IsReadOnly -Value $true
        if (-not (Test-NsPageDurable -IssueDir $issueDir -PageEntry $p)) { $bad++; Write-Host "  ! $($p.file) не пройшла звірку" -ForegroundColor Red }
    }
    if ($bad) { exit 1 }
    $rej = Join-Path $issueDir "_rejected"
    foreach ($t in @(Get-ChildItem -LiteralPath $issueDir -File -Filter "_incoming_ins_*")) {
        New-Item -ItemType Directory -Path $rej -Force | Out-Null
        $to = Join-Path $rej ("{0}_{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $t.Name)
        Move-Item -LiteralPath $t.FullName -Destination $to
        Write-Host "  недокладений скан -> $to"
    }
    if (Test-Path $journal) { Remove-Item $journal -Force }
    Add-Content -Path (Join-Path $script:LOGS "insertpage.log") -Encoding UTF8 `
        -Value ("{0}  {1}  ВІДНОВЛЕНО після обірваної вставки ({2} сторінок за маніфестом)" -f (Get-Date).ToString("s"), $Seq, @($man.pages).Count)
    Write-Host ("Відновлено: {0} сторінок на своїх місцях за маніфестом, звірка чиста." -f @($man.pages).Count) -ForegroundColor Green
    exit 0
}
if ($traces.Count) {
    Write-Host "У номері $Seq сліди обірваної вставки: $(($traces | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
    Write-Host "Спершу: ns-insertpage.ps1 -Seq $Seq -Recover" -ForegroundColor Red
    exit 1
}
if ($Page -lt 1) { Write-Host "Потрібен -Page N (або -Recover)." -ForegroundColor Red; exit 1 }
$pages = @($man.pages | Sort-Object { [int]$_.n })
$cnt = $pages.Count
if ($Page -lt 1 -or $Page -gt $cnt + 1) {
    Write-Host "У номері $Seq зараз $cnt сторінок — вставити можна на позицію 1..$($cnt + 1)." -ForegroundColor Red
    exit 1
}

# insert_pages (межі вкладки) перераховується сам: вставка ДО вкладки чи на її
# перший аркуш зсуває обидві межі, всередині — розширює, після — не чіпає.
# Вставка на позицію першого аркуша вважається «перед вкладкою»; якщо аркуш
# насправді її — оператор виправить «V a-b» у вікні приймання (30.09.2026:
# без цього +N на номері з вкладкою відмовляв, а вкладки частіше за все
# позначають саме перед прийманням).
$newInsert = $null
if ($man.PSObject.Properties.Name -contains 'insert_pages' -and $man.insert_pages -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
    $if = [int]$Matches[1]; $it = [int]$Matches[2]
    if ($Page -le $if) { $if++; $it++ } elseif ($Page -le $it) { $it++ }
    $newInsert = "$if-$it"
}
foreach ($k in 'page_order', 'page_rotate', 'page_edge') {
    if ($man.PSObject.Properties.Name -contains $k -and $man.$k) {
        Write-Host "У маніфесті є '$k' ($($man.$k)) — він прив'язаний до номерів сторінок." -ForegroundColor Red
        Write-Host "Спершу вирішити, як його перерахувати після вставки сторінки." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Номер $Seq ($issueDir): $cnt сторінок"
Write-Host "Звіряю хеші перед зміною..."
foreach ($p in $pages) {
    $f = Join-Path $issueDir $p.file
    if (-not (Test-Path $f) -or (Get-NsHash $f) -ne $p.sha256) {
        Write-Host "  $($p.file): хеш не збігається з маніфестом — зупинка." -ForegroundColor Red; exit 1
    }
}

$plan = @()
for ($k = $cnt; $k -ge $Page; $k--) {
    $src = $pages[$k - 1]
    $dst = Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page ($k + 1)
    $plan += [pscustomobject]@{ n = $k + 1; from = $src.file; to = $dst }
}
$newName = Get-NsPageName -SeqFirst $man.seq_first -Date $man.date -Page $Page
Write-Host "  нова сторінка $Page`: $newName"
if ($newInsert -and $newInsert -ne $man.insert_pages) { Write-Host "  вкладка: $($man.insert_pages) -> $newInsert" }
foreach ($m in ($plan | Sort-Object n)) { Write-Host ("  {0} -> {1}" -f $m.from, $m.to) }
if ($DryRun) { Write-Host "DryRun: нічого не змінено."; exit 0 }

# --- 1. нова сторінка: сканується (або береться -FromFile) й перевіряється ПЕРШОЮ,
#        поки в номері ще нічого не займано ------------------------------------
if ($FromFile) {
    if (-not (Test-Path -LiteralPath $FromFile)) { Write-Host "Немає файлу $FromFile" -ForegroundColor Red; exit 1 }
} elseif (-not (Test-NsTools -Need scan)) { Write-Host "Бракує інструментів — зупинка." -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "Сканування нової сторінки $Page…" -ForegroundColor Cyan
if ($FromFile) { Write-Host "  джерело: $FromFile (без сканування)" }
else           { Write-Host "  профіль: $script:NAPS2_PROFILE" }

$tmp = Join-Path $issueDir ("_incoming_ins_p{0:D2}.tif" -f $Page)
if (Test-Path $tmp) { Remove-Item $tmp -Force }
if ($FromFile) {
    # КОПІЯ, не перенос: джерело (часто _catalog\removed) лишається на місці —
    # відкладений майстер не має зникати з архіву тому, що його вставили.
    Copy-Item -LiteralPath $FromFile -Destination $tmp
    Set-ItemProperty -LiteralPath $tmp -Name IsReadOnly -Value $false
} else {
    & $script:NAPS2 -p $script:NAPS2_PROFILE -o $tmp --tiffcomp lzw 2>&1 | Out-Null
}

function Stop-Insert([string]$Why) {
    Write-Host "  [!] $Why" -ForegroundColor Yellow
    Write-Host "  Номер НЕ змінено — жодна сторінка не зсунута." -ForegroundColor Yellow
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    exit 1
}

if (-not (Test-Path $tmp)) { Stop-Insert "Скан не вдався (сканер міг заснути) — повторити." }

$frames = Get-NsFrameCount -Path $tmp
if ($frames -ne 1) { Stop-Insert "Скан розпався на $frames кадрів — обрізка сканера знову розрізала аркуш." }

$wh = (& magick identify -ping -format "%w|%h|%x" $tmp 2>$null) -split '\|'
if ($wh.Count -lt 3) { Stop-Insert "Файл не читається." }
$dpi = [double]$wh[2]; if ($dpi -le 0) { $dpi = 400 }
$mmA = [int]$wh[0] / $dpi * 25.4; $mmB = [int]$wh[1] / $dpi * 25.4
$short = [math]::Min($mmA, $mmB); $long = [math]::Max($mmA, $mmB)
if ($short -lt 285 -or $short -gt 315 -or $long -lt 405 -or $long -gt 430) {
    Stop-Insert ("Розмір {0:N1} x {1:N1} мм не схожий на газетний аркуш (очікувано ~298 x 418)." -f $mmA, $mmB)
}
$probe = "{0}x{1}" -f $wh[0], $wh[1]
Write-Host ("  новий скан: {0}, {1:N1} x {2:N1} мм, один кадр" -f $probe, $mmA, $mmB) -ForegroundColor Green

# --- 2. зсув наступних сторінок ВГОРУ (двофазно, як ns-droppage) --------------
@{ page = $Page; plan = $plan; at = (Get-Date).ToString("s") } | ConvertTo-Json -Depth 5 |
    Set-Content -Path $journal -Encoding UTF8

# -ErrorAction Stop обов'язковий: без нього Rename-Item на заблокованому файлі
# (перегляд, антивірус, Провідник) лише пише помилку, скрипт іде далі й
# записує маніфест з іменами, яких на диску немає (30.09.2026, перегляд).
# При збої — одразу назад за хешем до НЕЗМІНЕНОГО маніфесту.
$newFull = Join-Path $issueDir $newName
try {
    foreach ($m in $plan) {
        $f = Join-Path $issueDir $m.from
        Set-ItemProperty -LiteralPath $f -Name IsReadOnly -Value $false -ErrorAction Stop
        Rename-Item -LiteralPath $f -NewName "$($m.from).ins_tmp" -ErrorAction Stop
    }
    foreach ($m in $plan) {
        Rename-Item -LiteralPath (Join-Path $issueDir "$($m.from).ins_tmp") -NewName $m.to -ErrorAction Stop
    }

    # --- 3. нова сторінка на звільнене місце ----------------------------------
    Move-Item -LiteralPath $tmp -Destination $newFull -ErrorAction Stop
    Set-ItemProperty -LiteralPath $newFull -Name IsReadOnly -Value $true -ErrorAction Stop
} catch {
    Write-Host "  [!] Зсув зупинився: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $newFull) {
        $h = Get-NsHash $newFull
        if (-not (@($man.pages | Where-Object { $_.sha256 -eq $h }))) {
            Set-ItemProperty -LiteralPath $newFull -Name IsReadOnly -Value $false
            Move-Item -LiteralPath $newFull -Destination $tmp
        }
    }
    try { $lost = @(Restore-NsNamesByHash -IssueDir $issueDir -Manifest $man) }
    catch { $lost = @("(відновлення впало: $($_.Exception.Message))") }
    if ($lost.Count) {
        Write-Host "  Імена НЕ відновлено: $($lost -join ', '). _insert.json лишаю; далі: ns-insertpage.ps1 -Seq $Seq -Recover" -ForegroundColor Red
        exit 1
    }
    foreach ($p in $man.pages) { Set-ItemProperty -LiteralPath (Join-Path $issueDir $p.file) -Name IsReadOnly -Value $true }
    Remove-Item $journal -Force
    Stop-Insert "Файли повернуто до імен з маніфесту за хешем."
}

$stamp = (Get-Date).ToString("s")
$newPages = @()
foreach ($p in $pages) {
    if ([int]$p.n -ge $Page) {
        $e = $p.PSObject.Copy()
        $mv = @($plan | Where-Object { $_.from -eq $p.file })[0]
        $e.n = $mv.n; $e.file = $mv.to
        $hist = @()
        if ($e.PSObject.Properties.Name -contains 'renamed_from') { $hist = @($e.renamed_from) }
        $hist += [pscustomobject]@{ file = $mv.from; at = $stamp; reason = "після вставки стор. $Page" }
        $e | Add-Member -NotePropertyName renamed_from -NotePropertyValue $hist -Force
        $newPages += $e
    } else {
        $newPages += $p
    }
}
$newEntry = [pscustomobject]@{
    n          = $Page
    file       = $newName
    sha256     = Get-NsHash $newFull
    bytes      = (Get-Item $newFull).Length
    scanned_at = $stamp
}
$newPages += $newEntry
$man.pages = @($newPages | Sort-Object { [int]$_.n })
$hist2 = @()
if ($man.PSObject.Properties.Name -contains 'inserted') { $hist2 = @($man.inserted) }
$hist2 += [pscustomobject]@{ page = $Page; file = $newName; sha256 = $newEntry.sha256; at = $stamp; reason = $Reason }
$man | Add-Member -NotePropertyName inserted -NotePropertyValue $hist2 -Force
if ($newInsert) { $man.insert_pages = $newInsert }
$man.status = if (@($man.pages).Count -eq [int]$man.pages_expected) { "scanned" } else { "qc_flagged" }
Write-NsManifest -IssueDir $issueDir -Manifest $man

$sumFile = Join-Path $script:CHECKSUMS "$($man.seq_first).sha256"
$lines = @(foreach ($p in $man.pages) { "$($p.sha256)  $($p.file)" })
[IO.File]::WriteAllLines($sumFile, $lines, [Text.UTF8Encoding]::new($false))

$bad = 0
foreach ($p in $man.pages) {
    # Зсунуті файли лишились без read-only після перейменування (він знятий,
    # щоб Rename-Item пройшов) — поставити назад ДО звірки, інакше
    # Test-NsPageDurable відмовляє все, що зсунуто (виявлено на піску 30.09.2026).
    $f = Join-Path $issueDir $p.file
    Set-ItemProperty -Path $f -Name IsReadOnly -Value $true
    if (-not (Test-NsPageDurable -IssueDir $issueDir -PageEntry $p)) { $bad++; Write-Host "  ! $($p.file) не пройшла звірку" -ForegroundColor Red }
}
if ($bad) { Write-Host "Після зміни $bad розбіжностей — _insert.json лишаю." -ForegroundColor Red; exit 1 }
Remove-Item $journal -Force

$bytesAll = [long](@($man.pages) | Measure-Object -Property bytes -Sum).Sum
Set-NsRegistryRow -Manifest $man -Status $man.status -Bytes $bytesAll
Set-NsLastScanTime

$work = Join-Path $script:NS_WORK "$Seq"
if (Test-Path $work) { Remove-Item $work -Recurse -Force; Write-Host "Прибрано застарілі похідні: $work" }

Add-Content -Path (Join-Path $issueDir "_scan.log") -Encoding UTF8 -Value (
    "{0}  стор {1:D2}  ВСТАВЛЕНО  {2}  {3} байт  {4}  (зсунуто {5}; {6})" -f `
    $stamp, $Page, $probe, $newEntry.bytes, $newEntry.sha256, $plan.Count, $Reason)
Add-Content -Path (Join-Path $script:LOGS "insertpage.log") -Encoding UTF8 `
    -Value ("{0}  {1}  стор {2}  зсунуто {3}  ({4})" -f $stamp, $Seq, $Page, $plan.Count, $Reason)

Write-Host ("Готово: сторінку {0} вставлено, {1} зсунуто, у номері {2} сторінок." -f $Page, $plan.Count, @($man.pages).Count) -ForegroundColor Green
