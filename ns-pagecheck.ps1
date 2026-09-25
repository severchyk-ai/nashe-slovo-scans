# Аркуші для звірки друкованого номера сторінки з номером файлу — ОЧИМА.
#
#   .\ns-pagecheck.ps1 -Year 2001            аркуші на весь рік
#   .\ns-pagecheck.ps1 -Seq 2290             один номер
#   .\ns-pagecheck.ps1 -Year 2001 -PerSheet 8
#
# Для кожної сторінки вирізаються нижні кути (70 x 28 мм) — там друкується номер
# (у 2001 р.: парні зліва «8 НАШЕ СЛОВО № …», непарні справа «… 2001.1.14 9»).
# Рядок аркуша = номер газети, клітинка = файл fN; у клітинці fN має бути видно
# друковане N. Аркуші — у NS_WORK\pagecheck\.
#
# Чому очима, а не OCR: розпізнавання номера сторінки пробували двічі (2000 р. —
# 89-92 %, 18.09.2026 на 2266/2267 — дата «7 січня» читалась як номер 7, половина
# номерів не знаходилась). Людина (чи Claude на аркуші) читає ці цифри без помилок,
# а один аркуш на 10 номерів — це кілька хвилин.

# Режим -Band: замість кутів — УСЯ нижня смуга сторінки (за умовчанням 30 мм),
# одна сторінка на рядок, окремий аркуш на номер. Потрібен там, де підвал
# зверстано інакше й цифра не попадає в кут (номери з рукописним логотипом:
# 2266, 2280, 2294) або кут зайнятий рекламою (2289 стор. 9).
#
#   .\ns-pagecheck.ps1 -Seq 2294 -Band

# Коли звірка знайшла розбіжність (сторінка лежить не у своєму файлі), порядок
# для PDF записується в маніфест — майстри та їхні імена НЕ перейменовуються:
#
#   .\ns-pagecheck.ps1 -Seq 2314 -SetOrder "1,2,3,5,4,6,7,8,9,10"
#
# Число на позиції K — це номер ФАЙЛУ, який має стати K-ю сторінкою PDF.

param([int]$Year = 0, [int]$Seq = 0, [int]$PerSheet = 10, [switch]$Band, [double]$BandMm = 30,
      [string]$SetOrder = "")

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$dirs = @(Get-ChildItem -Path $script:NS_MASTERS -Directory -Recurse -Depth 1 |
          Where-Object { Test-Path (Join-Path $_.FullName "_manifest.json") } | Sort-Object Name)
if ($Seq)  { $dirs = @($dirs | Where-Object { $_.Name -like "${Seq}_*" }) }
if ($Year) { $dirs = @($dirs | Where-Object { $_.Parent.Name -eq "$Year" }) }
if ($dirs.Count -eq 0) { Write-Host "Немає номерів." -ForegroundColor Yellow; exit 1 }

if ($SetOrder) {
    if (-not $Seq) { Write-Host "-SetOrder потребує -Seq." -ForegroundColor Red; exit 1 }
    $d = $dirs[0]
    $man = Read-NsManifest -IssueDir $d.FullName
    $n = @($man.pages).Count
    $ord = @($SetOrder -split ',' | ForEach-Object { [int]$_.Trim() })
    if ($ord.Count -ne $n -or (($ord | Sort-Object) -join ',') -ne ((1..$n) -join ',')) {
        Write-Host "-SetOrder має містити кожне число з 1..$n рівно раз." -ForegroundColor Red; exit 1
    }
    $was = if ($man.PSObject.Properties.Name -contains 'page_order') { $man.page_order } else { "(не було)" }
    $man | Add-Member -NotePropertyName page_order -NotePropertyValue ($ord -join ',') -Force
    Write-NsManifest -IssueDir $d.FullName -Manifest $man
    Write-Host "$($man.seq_first): порядок сторінок у маніфесті $was -> $($ord -join ',')" -ForegroundColor Green
    Write-Host "Майстри не перейменовано. Перезібрати номер: ns-issue.ps1 -Seq $Seq"
    exit 0
}

$out = Join-Path $script:NS_WORK "pagecheck"
$tmpDir = Join-Path $out "_tmp"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$rows = @(); $sheet = 0; $made = @()
function Flush-Sheet {
    if ($script:rows.Count -eq 0) { return }
    $script:sheet++
    $name = if ($Seq) { "$Seq.png" } else { "{0}_{1:D2}.png" -f $Year, $script:sheet }
    $f = Join-Path $out $name
    & magick @($script:rows) -background white -append $f 2>$null
    $script:made += $f; $script:rows = @()
}

if ($Band) {
    # Аркуш на кілька номерів: на рік ставити -PerSheet 2 (два номери на
    # зображення), інакше картинка виходить зависока й цифри нечитабельні.
    $per = if ($Seq) { 1 } else { [Math]::Max(1, [Math]::Min($PerSheet, 2)) }
    $strips = @(); $n2 = 0; $first = ""
    foreach ($d in $dirs) {
        $man = Read-NsManifest -IssueDir $d.FullName
        if (-not $first) { $first = $man.seq_first }
        foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
            $f = Join-Path $d.FullName $p.file
            $wh = (& magick identify -ping -format "%w|%h" "$f[0]" 2>$null) -split '\|'; $W = [int]$wh[0]; $H = [int]$wh[1]
            $bh = [int]($BandMm / 25.4 * 400)
            $s = Join-Path $tmpDir ("s{0}_{1:D2}.png" -f $man.seq_first, [int]$p.n)
            & magick "$f[0]" -crop "${W}x$bh+0+$($H - $bh)" +repage -resize 950x `
                     -gravity west -background white -splice 78x0 -pointsize 15 `
                     -annotate +2+0 ("{0} f{1}" -f $man.seq_first, [int]$p.n) -bordercolor gray -border 1 $s 2>$null
            $strips += $s
        }
        $n2++
        if ($n2 -ge $per) {
            $o = Join-Path $out ("band_{0}.png" -f $first)
            & magick @strips -background white -append $o 2>$null
            $made += $o; $strips = @(); $n2 = 0; $first = ""
        }
    }
    if ($strips.Count) {
        $o = Join-Path $out ("band_{0}.png" -f $first)
        & magick @strips -background white -append $o 2>$null; $made += $o
    }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Нижні смуги сторінок:"
    $made | ForEach-Object { Write-Host "  $_" }
    exit 0
}

foreach ($d in $dirs) {
    $man = Read-NsManifest -IssueDir $d.FullName
    $cells = @()
    foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
        $f = Join-Path $d.FullName $p.file
        $wh = (& magick identify -ping -format "%w|%h" "$f[0]" 2>$null) -split '\|'; $W = [int]$wh[0]; $H = [int]$wh[1]
        $dpi = 400
        # лише кут із номером: 26 x 17 мм, показані вчетверо більшими —
        # на ширшій вирізці (70 x 28 мм) цифри були надто дрібні, щоб читати впевнено
        $cw = [int](26 / 25.4 * $dpi); $ch = [int](17 / 25.4 * $dpi)
        $l = Join-Path $tmpDir "l.png"; $r = Join-Path $tmpDir "r.png"; $c = Join-Path $tmpDir ("c{0:D2}.png" -f [int]$p.n)
        & magick "$f[0]" -crop "${cw}x$ch+0+$($H - $ch)" +repage -resize "104x68!" $l 2>$null
        & magick "$f[0]" -crop "${cw}x$ch+$($W - $cw)+$($H - $ch)" +repage -resize "104x68!" $r 2>$null
        & magick $l $r -background red -splice 2x0 +append -gravity north -background white -splice 0x12 `
                 -pointsize 11 -annotate +0+0 ("f{0}" -f [int]$p.n) -bordercolor gray -border 2 $c 2>$null
        $cells += $c
    }
    $row = Join-Path $tmpDir ("row{0}.png" -f $man.seq_first)
    & magick @cells +append -gravity west -background white -splice 42x0 -pointsize 14 -annotate +2+0 "$($man.seq_first)" $row 2>$null
    $rows += $row
    if ($rows.Count -ge $PerSheet) { Flush-Sheet }
}
Flush-Sheet
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Аркуші для звірки номерів сторінок:"
$made | ForEach-Object { Write-Host "  $_" }
