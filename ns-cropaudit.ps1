# Огляд майстрів на вади автоматичної обрізки сканера.
#
#   .\ns-cropaudit.ps1              усі номери
#   .\ns-cropaudit.ps1 -Year 2001
#   .\ns-cropaudit.ps1 -Tol 3.0     допуск відхилення від медіани номера, мм
#
# До 16.09.2026 драйвер стояв на «Automatic Multiple» (Avision Capture Tools),
# і сканер обтинав аркуш на свій розсуд; профіль NAPS2 цього не перекривав.
# Відомі наслідки: 2266 стор. 8 і 2267 стор. 4 розрізано на два кадри, а
# повторний скан 2266 стор. 8 утратив 15 мм верху, бо чорна смуга заголовка
# злилася з чорною кришкою.
#
# Ознака — РОЗМІР аркуша проти інших сторінок ТОГО САМОГО номера: сторінки
# одного номера обрізані в друкарні однаково (2285: 297,4-299,1 x 417,8-418,6),
# тож обрізка, що відтяла зайве, робить сторінку помітно меншою за сусідні.
# Не проти сталого еталона: розмір аркуша різниться між номерами (2266 —
# 413,6-415,6 мм заввишки, 2267 — 417,2-418,4).
#
# Позначки:
#   КАДРИ   у TIF не один кадр — сторінку розрізано
#   МЕНША   ширина чи висота менша за медіану номера більше ніж на -Tol мм
#   БІЛЬША  більша за медіану більше ніж на 2x-Tol — у кадр потрапило скло/кришка
#   МЕЖА    рівно на межі області A3 (297,0 або 420,1) — аркуш міг виходити за неї
#
# ⚠︎ Чого цей огляд НЕ бачить: обрізки, яка зрізала однаково всі сторінки
# номера (медіана зсунеться разом із ними), і зрізаного вмісту на аркуші
# нормального розміру. Тому позначене — дивитися очима, а непозначене — не
# вважати доведено цілим.
#
# Контроль: відкладені в _catalog\removed скани з відомою вадою мусять
# позначитися. Якщо ні — вимір нічого не бачить, і скрипт відмовляється
# видавати висновок.

param([int]$Year = 0, [double]$Tol = 3.0)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$controls = @(
    @{ file = "2266_2001-01-07_p08_replaced_20260916-190630.tif"; want = "КАДРИ"; what = "розрізаний на 2 кадри (11.09)" },
    @{ file = "2266_2001-01-07_p08_replaced_20260916-191750.tif"; want = "МЕНША"; what = "зрізано 15 мм верху (16.09)" }
)

function Get-Dims([string]$Path) {
    $fr = @(& magick identify -ping -format "%w|%h|%x`n" $Path 2>$null | Where-Object { $_ })
    if ($fr.Count -eq 0) { return $null }
    $a = $fr[0] -split '\|'; $dpi = [double]$a[2]; if ($dpi -le 0) { $dpi = 400 }
    # для кількох кадрів розмір — найбільшого, щоб МЕНША теж спрацювала
    $best = $fr | ForEach-Object { $b = $_ -split '\|'; [pscustomobject]@{ w = [int]$b[0]; h = [int]$b[1] } } |
            Sort-Object { $_.w * $_.h } -Descending | Select-Object -First 1
    [pscustomobject]@{
        frames = $fr.Count
        wmm = [math]::Round($best.w / $dpi * 25.4, 1)
        hmm = [math]::Round($best.h / $dpi * 25.4, 1)
    }
}
function Get-Med($xs) { $s = @($xs | Sort-Object); if (-not $s.Count) { return $null }; $s[[int]($s.Count / 2)] }

function Get-Flags($d, $medW, $medH) {
    $f = @()
    if ($d.frames -ne 1) { $f += "КАДРИ($($d.frames))" }
    $dw = $d.wmm - $medW; $dh = $d.hmm - $medH
    if ($dw -lt -$Tol -or $dh -lt -$Tol) { $f += ("МЕНША(ш{0:+0.0;-0.0} в{1:+0.0;-0.0})" -f $dw, $dh) }
    if ($dw -gt 2*$Tol -or $dh -gt 2*$Tol) { $f += ("БІЛЬША(ш{0:+0.0;-0.0} в{1:+0.0;-0.0})" -f $dw, $dh) }
    if ([math]::Abs($d.wmm - 297.0) -le 0.1 -or [math]::Abs($d.hmm - 420.1) -le 0.1) { $f += "МЕЖА" }
    return $f
}

# --- збір розмірів по номерах
$issues = @(Get-ChildItem -Path $script:NS_MASTERS -Directory -Recurse -Depth 1 |
            Where-Object { Test-Path (Join-Path $_.FullName "_manifest.json") } | Sort-Object Name)
if ($Year) { $issues = @($issues | Where-Object { $_.Parent.Name -eq "$Year" }) }

$medians = @{}
$rows = @()
foreach ($dir in $issues) {
    $man = Read-NsManifest -IssueDir $dir.FullName
    $pages = @()
    foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
        $full = Join-Path $dir.FullName $p.file
        if (-not (Test-Path $full)) { continue }
        $d = Get-Dims $full
        if ($d) { $pages += [pscustomobject]@{ seq = [int]$man.seq_first; n = [int]$p.n; file = $p.file; d = $d; scanned = $p.scanned_at } }
    }
    # медіана лише по книжкових однокадрових: розрізані й альбомні зсунули б її
    $norm = @($pages | Where-Object { $_.d.frames -eq 1 -and $_.d.hmm -gt $_.d.wmm })
    if ($norm.Count -lt 3) { continue }
    $mw = Get-Med $norm.d.wmm; $mh = Get-Med $norm.d.hmm
    $medians[[int]$man.seq_first] = @($mw, $mh)
    foreach ($pg in $pages) {
        $rows += [pscustomobject]@{ seq = $pg.seq; n = $pg.n; file = $pg.file; wmm = $pg.d.wmm; hmm = $pg.d.hmm
                                    frames = $pg.d.frames; medW = $mw; medH = $mh; scanned = $pg.scanned
                                    flags = @(Get-Flags $pg.d $mw $mh) }
    }
}

# --- контроль
Write-Host ""
Write-Host "Контроль (відомі вади з _catalog\removed)" -ForegroundColor Cyan
$ctlOk = $true
foreach ($c in $controls) {
    $path = Join-Path (Join-Path $script:CATALOG "removed") $c.file
    $seq = [int]($c.file -split '_')[0]
    if (-not (Test-Path $path) -or -not $medians.ContainsKey($seq)) {
        Write-Host "  немає зразка або медіани номера: $($c.file)" -ForegroundColor Red; $ctlOk = $false; continue
    }
    $d = Get-Dims $path
    $fl = @(Get-Flags $d $medians[$seq][0] $medians[$seq][1])
    $hit = @($fl | Where-Object { $_ -like "$($c.want)*" }).Count -gt 0
    $color = if ($hit) { "Green" } else { "Red" }
    Write-Host ("  {0}  {1} x {2} мм, {3} кадр.  -> {4}   ({5})" -f $(if ($hit) {"ok"} else {"!!"}), $d.wmm, $d.hmm, $d.frames, ($fl -join " "), $c.what) -ForegroundColor $color
    if (-not $hit) { $ctlOk = $false }
}
if (-not $ctlOk) {
    Write-Host ""
    Write-Host "Контроль НЕ пройдено — вимір не бачить відомої вади, висновку не видаю." -ForegroundColor Red
    exit 2
}

# --- результат
$flagged = @($rows | Where-Object { $_.flags.Count -gt 0 })
Write-Host ""
Write-Host ("Перевірено: {0} номерів, {1} сторінок. Допуск {2} мм від медіани номера." -f $medians.Count, $rows.Count, $Tol) -ForegroundColor Cyan
if ($flagged.Count -eq 0) {
    Write-Host "Позначених сторінок немає." -ForegroundColor Green
    exit 0
}
Write-Host ""
Write-Host ("  {0,-5} {1,4} {2,15} {3,15}  {4}" -f "номер", "стор", "розмір, мм", "медіана номера", "позначки")
foreach ($r in $flagged) {
    $color = if (@($r.flags | Where-Object { $_ -like "КАДРИ*" -or $_ -like "МЕНША*" }).Count) { "Yellow" } else { "Gray" }
    Write-Host ("  {0,-5} {1,4} {2,15} {3,15}  {4}" -f $r.seq, $r.n, ("{0}x{1}" -f $r.wmm, $r.hmm),
        ("{0}x{1}" -f $r.medW, $r.medH), ($r.flags -join " ")) -ForegroundColor $color
}
$byKind = @{}
foreach ($r in $flagged) { foreach ($f in $r.flags) { $k = ($f -split '\(')[0]; $byKind[$k] = 1 + [int]$byKind[$k] } }
Write-Host ""
Write-Host ("Позначено сторінок: {0}   ({1})" -f $flagged.Count, (($byKind.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Value)" }) -join ", "))
exit 1
