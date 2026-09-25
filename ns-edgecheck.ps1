# Діагностика рішення про зріз краю: профіль фарби по глибині й що вирішив
# Get-NsEdgeCut для кожного краю сторінки (на файлах prep, до зрізу).
#
#   .\ns-edgecheck.ps1 -Seq 2294 -Pages "1,10"
#   .\ns-edgecheck.ps1 -Seq 2294            усі сторінки
#
# Рядок профілю — частка ТЕМНОЇ фарби (Ink) і будь-якої фарби (Frac), %, по
# міліметру вглиб від краю: так видно, де кінчаються дірки і де починається друк.

param([Parameter(Mandatory = $true)][int]$Seq, [string]$Pages = "", [double]$ShowMm = 16, [switch]$Brief, [switch]$Sheet)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

# Смуга краю для аркуша нагляду: край аркуша ЗГОРИ, глибина вниз (4 пікс./мм,
# 0-22 мм), довжина краю розрізана навпіл і складена у два ряди; лінії на 2, 4,
# 6 і 8 мм — можливі глибини зрізу.
function Save-EdgeStrip {
    param([string]$Tif, [string]$Side, [string]$Label)
    $wh = (& magick identify -ping -format "%w|%h" "$Tif[0]" 2>$null) -split '\|'; $W = [int]$wh[0]; $H = [int]$wh[1]
    $d = [int](22 / 25.4 * 400)
    $spec = @{ Left = @("${d}x$H+0+0", "-rotate", "90"); Right = @("${d}x$H+$($W-$d)+0", "-rotate", "-90")
               Top = @("${W}x$d+0+0", "-strip"); Bottom = @("${W}x$d+0+$($H-$d)", "-flip") }[$Side]
    $k = 4.0 * 25.4 / 400
    $base = Join-Path $tmpDir ([guid]::NewGuid().ToString("N"))
    & magick "$Tif[0]" -alpha off -crop $spec[0] +repage $spec[1] $spec[2] -resize ("{0}%" -f [int](100 * $k)) "$base.png" 2>$null
    $sw = [int](& magick identify -format "%w" "$base.png"); $half = [int]($sw / 2)
    $draw = @()
    foreach ($mm in 2, 4, 6, 8, 12) { $y = $mm * 4; $col = @{2="#00a0ff";4="#00c000";6="#ff9900";8="#ff0000";12="#c000c0"}[$mm]
        $draw += @("-stroke", $col, "-draw", "line 0,$y $half,$y") }
    $parts = @()
    foreach ($i in 0, 1) {
        $pp = "$base.$i.png"
        & magick "$base.png" -crop "${half}x88+$($i*$half)+0" +repage @draw -stroke none -fill black -pointsize 9 `
                 -annotate +2+10 "2" -annotate +2+18 "4" -annotate +2+26 "6" -annotate +2+34 "8" -annotate +2+50 "12" -bordercolor gray -border 1 $pp 2>$null
        $parts += $pp
    }
    $o = "$base.row.png"
    & magick $parts -append -gravity north -background white -splice 0x16 -pointsize 12 -fill black -annotate +0+1 $Label $o 2>$null
    return $o
}

$prep = Join-Path (Join-Path $script:NS_WORK "$Seq") "prep"
$script:issueYear = 0
$idir = Find-NsIssueDir -Seq $Seq
$rotMap = @{}; $edgeMap = @{}
if ($idir) {
    $imf = Read-NsManifest -IssueDir $idir
    $script:issueYear = [int]$imf.year
    if ($imf.PSObject.Properties.Name -contains 'page_rotate' -and $imf.page_rotate) {
        foreach ($pair in ($imf.page_rotate -split ',')) { if ($pair.Trim() -match '^(\d+)\s*:\s*(\d+)$') { $rotMap[[int]$Matches[1]] = [int]$Matches[2] } }
    }
    if ($imf.PSObject.Properties.Name -contains 'page_edge' -and $imf.page_edge) {
        foreach ($tok in ($imf.page_edge -split '[,\s]+')) { if ($tok -match '^(\d+)([LRTBlrtb])([\d.]+)$') { $edgeMap["{0}{1}" -f [int]$Matches[1], $Matches[2].ToUpper()] = [double]$Matches[3] } }
    }
}
$tifs = @(Get-ChildItem $prep -Filter "p*.tif" -File | Sort-Object Name)
if ($Pages) {
    $want = @($Pages -split '[,;]' | ForEach-Object { "p{0:D2}.tif" -f [int]$_ })
    $tifs = @($tifs | Where-Object { $want -contains $_.Name })
}
$sheetRows = @()
$tmpDir = Join-Path $script:NS_WORK "edgesheet\_tmp"
if ($Sheet) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
foreach ($t in $tifs) {
    $prof = Get-NsEdgeProfile -Path $t.FullName
    $spine = Get-NsSpineRule -Year ([int]$script:issueYear) -PageNo ([int]$t.BaseName.Substring(1))
    $spArgs = @{}
    if ($spine) { $spArgs = @{ SpineSide = $spine.Side; SpineCleanMm = $spine.CleanMm; SpineHoleMaxMm = $spine.HoleMaxMm } }
    # правило зовнішнього боку (25.09.2026) — як у ns-prep; корінець із page_edge маніфеста
    $pn = [int]$t.BaseName.Substring(1)
    $spSide = Get-NsSpineSide -PageNo $pn -Rotate $(if ($rotMap.ContainsKey($pn)) { $rotMap[$pn] } else { 0 })
    if ($spSide) {
        $spArgs.OuterSide = @{ Left = "Right"; Right = "Left"; Top = "Bottom"; Bottom = "Top" }[$spSide]
        $key = "{0}{1}" -f $pn, $spSide.Substring(0, 1)
        if ($edgeMap.ContainsKey($key)) { $spArgs.SpineCutMm = $edgeMap[$key] }
    }
    $cut = Get-NsEdgeCut -EdgeProfile $prof @spArgs
    Write-Host ""
    Write-Host "== $Seq $($t.BaseName)" -ForegroundColor Cyan
    foreach ($side in "Left", "Right", "Top", "Bottom") {
        $c = $cut[$side]
        $flag = if ($c.Review) { "  << НАГЛЯД" } else { "" }
        if ($Sheet -and $c.Review) { $sheetRows += Save-EdgeStrip -Tif $t.FullName -Side $side -Label ("{0}/{1} {2}: {3}" -f $Seq, [int]$t.BaseName.Substring(1), $side, $c.Why) }
        Write-Host ("  {0,-6} зріз {1,4} мм, запас {2,4}  {3}{4}" -f $side, $c.Cut, $c.Free, $c.Why, $flag)
        $loc = Get-NsEdgeLocal -EdgeProfile $prof -Side $side
        if ($loc.ContentMm -ge 0) { Write-Host ("         найближчий друк {0} мм углиб, {1} мм уздовж краю" -f $loc.ContentMm, $loc.BestAtMm) -ForegroundColor DarkGray }
        if ($loc.Values.Count -and -not $Brief) { Write-Host ("         друк по відрізках, мм: " + (($loc.Values | Select-Object -First 12) -join " ")) -ForegroundColor DarkGray }
        if ($Brief) { continue }
        $ink = $prof["${side}Ink"]; $fr = $prof[$side]
        $a = @(); $b = @()
        for ($mm = 0; $mm -lt $ShowMm; $mm++) {
            $i = [int]($mm / 0.5); $j = $i + 1
            $a += "{0,3}" -f [int](100 * [math]::Max($ink[$i], $ink[$j]))
            $b += "{0,3}" -f [int](100 * [math]::Max($fr[$i], $fr[$j]))
        }
        Write-Host ("         мм  " + ((0..($ShowMm - 1) | ForEach-Object { "{0,3}" -f $_ }) -join ""))
        Write-Host ("         Ink " + ($a -join "")) -ForegroundColor DarkGray
        Write-Host ("         Frac" + ($b -join "")) -ForegroundColor DarkGray
    }
}

if ($Sheet) {
    if ($sheetRows.Count -eq 0) { Write-Host "Позначених сторін немає — аркуш не потрібен." }
    else {
        $f = Join-Path (Join-Path $script:NS_WORK "edgesheet") ("{0}.png" -f $Seq)
        & magick $sheetRows -background white -append $f 2>$null
        Write-Host "Аркуш нагляду: $f  (лінії: блакитна 2 мм, зелена 4, помаранчева 6, червона 8)"
    }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
