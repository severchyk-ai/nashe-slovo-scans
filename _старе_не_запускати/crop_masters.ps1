param(
    [Parameter(Mandatory = $true)][string]$InputDir  # folder of master TIFFs to crop in place
)

# One-off cleanup for masters scanned before the profile fix on 2026-08-28 (see CLAUDE.md):
# the scanner used to capture uncovered glass beyond the page edge as a near-black band.
# This crops that band directly out of the master TIFFs, in place, no backup (by operator
# request). Same detection as build_issue_pdf.ps1's Get-BandOffsets: collapse to a 1px strip
# on each axis and walk in from all four edges until several samples read as paper, not glass.
# Deskew is intentionally NOT applied here -- only the band is removed.

function Get-AxisOffsets {
    param([string]$Path, [string]$ResizeGeom, [string]$Coord, [int]$Length, [int]$Samples, [int]$Threshold = 150, [int]$MinRun = 3)

    $raw = & magick $Path -resize $ResizeGeom -colorspace Gray -depth 8 txt: 2>$null
    $vals = @()
    $pattern = if ($Coord -eq 'y') { '^0,(\d+):\s*\((\d+)' } else { '^(\d+),0:\s*\((\d+)' }
    foreach ($line in $raw) {
        if ($line -match $pattern) { $vals += [int]$Matches[2] }
    }
    if ($vals.Count -lt $Samples) { return @{ Start = 0; End = 0 } }

    $pxPerSample = $Length / $vals.Count

    $startIdx = 0
    for ($i = 0; $i -le $vals.Count - $MinRun; $i++) {
        $run = $vals[$i..($i + $MinRun - 1)]
        if (($run | Where-Object { $_ -lt $Threshold }).Count -eq 0) { $startIdx = $i; break }
    }

    $endIdx = 0
    for ($i = 0; $i -le $vals.Count - $MinRun; $i++) {
        $j = $vals.Count - 1 - $i
        $run = $vals[($j - $MinRun + 1)..$j]
        if (($run | Where-Object { $_ -lt $Threshold }).Count -eq 0) { $endIdx = $i; break }
    }

    $start = [math]::Max(0, [int](($startIdx - 1) * $pxPerSample))
    $end = [math]::Max(0, [int](($endIdx - 1) * $pxPerSample))
    return @{ Start = $start; End = $end }
}

function Get-BandOffsets {
    param([string]$Path, [int]$Width, [int]$Height, [int]$Samples = 850)
    $v = Get-AxisOffsets -Path $Path -ResizeGeom "1x$Samples!" -Coord 'y' -Length $Height -Samples $Samples
    $h = Get-AxisOffsets -Path $Path -ResizeGeom "${Samples}x1!" -Coord 'x' -Length $Width -Samples $Samples
    return @{ Top = $v.Start; Bottom = $v.End; Left = $h.Start; Right = $h.End }
}

$tifs = Get-ChildItem -Path $InputDir -File | Where-Object { $_.Extension -in ".tif", ".tiff" } | Sort-Object Name
if ($tifs.Count -eq 0) { Write-Output "No TIFF files in $InputDir"; exit 1 }

foreach ($t in $tifs) {
    $fmt = & magick identify -format "%w|%h" $t.FullName 2>$null
    $wh = $fmt -split '\|'
    $w = [int]$wh[0]; $h = [int]$wh[1]

    $band = Get-BandOffsets -Path $t.FullName -Width $w -Height $h
    if ($band.Top -eq 0 -and $band.Bottom -eq 0 -and $band.Left -eq 0 -and $band.Right -eq 0) {
        Write-Output ("  {0}: no band, unchanged" -f $t.Name)
        continue
    }

    $cropW = $w - $band.Left - $band.Right
    $cropH = $h - $band.Top - $band.Bottom
    & magick $t.FullName -crop "${cropW}x${cropH}+$($band.Left)+$($band.Top)" +repage -compress LZW $t.FullName
    Write-Output ("  {0}: {1}x{2} -> {3}x{4}  (top={5} bottom={6} left={7} right={8})" -f `
        $t.Name, $w, $h, $cropW, $cropH, $band.Top, $band.Bottom, $band.Left, $band.Right)
}
