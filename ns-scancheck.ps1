# Якість майстрів номера проти сусідніх номерів — після нової машини, зміни
# драйвера, налаштувань у Avision Capture Tools чи профілю NAPS2.
#
#   .\ns-scancheck.ps1 -Seq 2286                   проти 3 попередніх номерів
#   .\ns-scancheck.ps1 -Seq 2286 -Compare 2227,2285
#   .\ns-scancheck.ps1 -Seq 2286 -Extra "C:\....tif;C:\....tif"   ще й окремі файли
#
# Нічого не змінює. Що міряє, на кожну сторінку:
#   мм        розмір аркуша за 400 dpi
#   МБ        розмір файлу
#   шпиль %   частка найчисельнішого рівня яскравості серед світлих (>=128).
#             Це підпис тонової кривої драйвера: «Color Matching» Document /
#             Photo / Mix давали 42-83 %, None — близько 5 % (CLAUDE.md,
#             «Чому Color Matching: None»). Головна ознака, що драйвер
#             налаштовано інакше.
#   білі %    частка пікселів на 254-255 — вибиті світла
#   чорні %   частка на 0-1 — забиті тіні
#   папір     95-й перцентиль по каналах (Get-NsPaperColor), і його B-R
#   фарба     рівень, темніший за який 2 % пікселів
# Гістограма на -sample (найближчий піксель), НЕ на -resize: усереднення при
# зменшенні розмазало б шпиль, і вимір не побачив би саме того, що шукає.

# Списки — рядком: `powershell -File` передає «2285,2284» одним аргументом,
# і [int[]] на ньому падає. Номери через кому, файли через крапку з комою.
param([int]$Seq, [string]$Compare = "", [string]$Extra = "")
$cmpSeqs = @($Compare -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$extraFiles = @($Extra -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (-not $Seq) { Write-Host "Вкажи -Seq <номер>." -ForegroundColor Red; exit 2 }

function Measure-Master([string]$Path) {
    $fc = Get-NsFrameCount -Path $Path
    $wh = (& magick identify -ping -format "%w|%h|%x`n" "$Path[0]" 2>$null | Select-Object -First 1) -split '\|'
    $dpi = [double]$wh[2]; if ($dpi -le 0) { $dpi = 400 }
    $hist = & magick "$Path[0]" -sample 50% -colorspace Gray -depth 8 -format "%c" histogram:info:- 2>$null
    $cnt = New-Object 'long[]' 256
    foreach ($line in $hist) {
        if ($line -match '^\s*(\d+):\s*\(\s*(\d+)') { $cnt[[int]$Matches[2]] += [long]$Matches[1] }
    }
    $total = ($cnt | Measure-Object -Sum).Sum
    if (-not $total) { return $null }
    $hi = 0L; $peak = 0L
    for ($v = 128; $v -le 255; $v++) { $hi += $cnt[$v]; if ($cnt[$v] -gt $peak) { $peak = $cnt[$v] } }
    $acc = 0L; $ink = 0
    for ($v = 0; $v -le 255; $v++) { $acc += $cnt[$v]; if ($acc -ge 0.02 * $total) { $ink = $v; break } }
    $pc = Get-NsPaperColor -Path $Path -Sample 400
    [pscustomobject]@{
        frames = $fc
        wmm    = [math]::Round([int]$wh[0] / $dpi * 25.4, 1)
        hmm    = [math]::Round([int]$wh[1] / $dpi * 25.4, 1)
        mb     = [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
        peak   = if ($hi) { 100.0 * $peak / $hi } else { 0 }
        white  = 100.0 * ($cnt[254] + $cnt[255]) / $total
        black  = 100.0 * ($cnt[0] + $cnt[1]) / $total
        paper  = if ($pc) { "{0}/{1}/{2}" -f $pc[0], $pc[1], $pc[2] } else { "-" }
        cast   = if ($pc) { $pc[2] - $pc[0] } else { $null }
        ink    = $ink
    }
}

function Show-Header {
    Write-Host ("  {0,-30} {1,5} {2,13} {3,6} {4,8} {5,7} {6,7} {7,12} {8,5} {9,6}" -f `
        "сторінка", "кадр", "мм", "МБ", "шпиль %", "білі %", "чорні %", "папір RGB", "B-R", "фарба")
}
function Show-Row([string]$Label, $m) {
    $warn = ($m.frames -ne 1)
    $line = "  {0,-30} {1,5} {2,13} {3,6:N1} {4,8:N1} {5,7:N2} {6,7:N2} {7,12} {8,5} {9,6}" -f `
        $Label, $m.frames, ("{0}x{1}" -f $m.wmm, $m.hmm), $m.mb, $m.peak, $m.white, $m.black, $m.paper, $m.cast, $m.ink
    if ($warn) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
}
function Get-Median($xs) {
    $s = @($xs | Where-Object { $null -ne $_ } | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    return $s[[int]($s.Count / 2)]
}
function Show-Summary([string]$Label, $ms) {
    $ms = @($ms | Where-Object { $_ })
    Write-Host ("  {0,-30} {1,5} {2,13} {3,6:N1} {4,8:N1} {5,7:N2} {6,7:N2} {7,12} {8,5} {9,6}" -f `
        $Label, "", "", (Get-Median $ms.mb), (Get-Median $ms.peak), (Get-Median $ms.white),
        (Get-Median $ms.black), "", (Get-Median $ms.cast), (Get-Median $ms.ink)) -ForegroundColor Cyan
}

function Measure-Issue([int]$S) {
    $dir = Find-NsIssueDir -Seq $S
    if (-not $dir) { Write-Host "  номер $S не знайдено" -ForegroundColor Yellow; return @() }
    $man = Read-NsManifest -IssueDir $dir
    Write-Host ""
    Write-Host ("Номер {0} ({1}), знято {2}" -f $S, $man.date, $man.scan_date) -ForegroundColor Cyan
    Show-Header
    $res = @()
    foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
        $f = Join-Path $dir $p.file
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Host ("  {0,-30} НЕМАЄ ФАЙЛУ, хоча є в маніфесті" -f $p.file) -ForegroundColor Yellow
            continue
        }
        $m = Measure-Master $f
        if ($m) { Show-Row $p.file.Substring($p.file.Length - 7) $m; $res += $m }
    }
    Show-Summary "медіана" $res
    return $res
}

# --- перевірюваний номер
$target = Measure-Issue $Seq

# --- номери для порівняння: вказані або 3 попередні з реєстру
if ($cmpSeqs.Count -eq 0) {
    $cmpSeqs = @(Read-NsRegistry | ForEach-Object { [int]$_.seq_first } |
                 Where-Object { $_ -lt $Seq } | Sort-Object -Descending | Select-Object -First 3)
}
$others = @()
foreach ($c in $cmpSeqs) { $others += Measure-Issue $c }

# --- окремі файли
if ($extraFiles.Count) {
    Write-Host ""
    Write-Host "Окремі файли" -ForegroundColor Cyan
    Show-Header
    foreach ($x in $extraFiles) {
        if (-not (Test-Path -LiteralPath $x)) { Write-Host "  немає: $x" -ForegroundColor Yellow; continue }
        $m = Measure-Master $x
        if ($m) { Show-Row ([IO.Path]::GetFileName($x)) $m }
    }
}

Write-Host ""
Write-Host "Підсумок" -ForegroundColor Cyan
Show-Header
Show-Summary "номер $Seq" $target
Show-Summary ("порівняння ({0})" -f ($cmpSeqs -join ", ")) $others
