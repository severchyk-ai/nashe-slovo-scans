param(
    [Parameter(Mandatory = $true)][string]$InputDir,   # folder with the 400 dpi TIFF masters of one issue
    [Parameter(Mandatory = $true)][string]$Issue,      # continuous issue number, e.g. 2214 -- becomes 2214.pdf
    [string]$OutputDir,                                # defaults to the parent of InputDir
    [int]$Dpi = 300,                                   # matches the 1956-1999 archive
    [int]$Quality = 67,                                # measured from 2183.pdf
    [switch]$NoOcr,                                    # skip the invisible text layer
    [switch]$NoDescreen,                               # keep the printing raster visible in the PDF
    [switch]$NoCrop,                                   # keep the scanner's uncovered-glass band
    [switch]$NoDeskew,                                 # keep the page tilt as scanned
    [switch]$NoHueFix,                                 # keep the scanner's raw ~3-degree hue offset
    [switch]$NoPad,                                    # keep each page at its own trimmed size
    [string]$PageOrder                                 # reorder pages in the PDF only, e.g. a pull-out
                                                         # insert bound out of reading order: "1,2,3,4,8,6,7,5".
                                                         # 1-based, comma-separated, refers to the sorted
                                                         # master list. Master TIFFs and their filenames are
                                                         # never reordered -- they stay in scanned order.
)

$TESSERACT = "C:\Program Files\Tesseract-OCR\tesseract.exe"
$TESSDATA  = "C:\Users\sever\Documents\Scans\tessdata"

if (-not $OutputDir) { $OutputDir = Split-Path -Parent $InputDir }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

$tifs = Get-ChildItem -Path $InputDir -File |
        Where-Object { $_.Extension -in ".tif", ".tiff" } |
        Sort-Object Name

if ($tifs.Count -eq 0) { Write-Output "No TIFF files in $InputDir"; exit 1 }

if ($PageOrder) {
    $order = $PageOrder -split ',' | ForEach-Object { [int]$_.Trim() }
    if ($order.Count -ne $tifs.Count -or (($order | Sort-Object) -join ',') -ne ((1..$tifs.Count) -join ',')) {
        Write-Output "-PageOrder must list each of 1..$($tifs.Count) exactly once."
        exit 1
    }
    $tifs = $order | ForEach-Object { $tifs[$_ - 1] }
    Write-Output ("Issue $Issue : $($tifs.Count) page(s), PDF order overridden to " + ($order -join ','))
} else {
    Write-Output "Issue $Issue : $($tifs.Count) page(s) -> $Dpi dpi, JPEG q$Quality"
}

# Access copies go through a scratch folder; the masters are never touched.
$work = Join-Path $env:TEMP ("nspdf_" + $Issue)
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

# The scanner bed is longer than the newspaper page on the edge away from the mechanical stop,
# leaving a near-black strip on some pages (roughly half, still true even with the driver's
# "Automatic Multiple" cropping -- see CLAUDE.md). A plain "-trim" can't remove it: trim assumes
# a symmetric frame from one corner color, but this border sits on only one edge while the other
# three already touch real content, and one stray bright pixel at the edge defeats it entirely.
# This instead collapses the image to a 1px strip per axis (one fast resize, not a per-row loop)
# and walks in from each edge until several consecutive samples read as paper, not glass. All four
# edges are checked on every page because a 90-degree auto-rotation (calendar inserts) can move
# the band from top/bottom to left/right.
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

    # Back off by one sample so the crop line sits inside the band, not on its edge.
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

Write-Output "Pass 1/2: crop, deskew, resample"

# Phase 1 writes a lossless PNG per page (crop + deskew + resample only) so its exact
# post-correction dimensions can be measured before anything is padded or JPEG-encoded.
$pages = @()
$i = 0
foreach ($t in $tifs) {
    $i++
    $png = Join-Path $work ("p{0:D4}.png" -f $i)

    $fmt = & magick identify -format "%w|%h" $t.FullName 2>$null
    $wh = $fmt -split '\|'
    $w = [int]$wh[0]; $h = [int]$wh[1]

    $ops = @()
    if (-not $NoCrop) {
        $band = Get-BandOffsets -Path $t.FullName -Width $w -Height $h
        if ($band.Top -gt 0 -or $band.Bottom -gt 0 -or $band.Left -gt 0 -or $band.Right -gt 0) {
            $cropW = $w - $band.Left - $band.Right
            $cropH = $h - $band.Top - $band.Bottom
            $ops += @("-crop", "${cropW}x${cropH}+$($band.Left)+$($band.Top)", "+repage")
        }
    }
    if (-not $NoDeskew) { $ops += @("-background", "white", "-deskew", "40%", "+repage") }

    # Hue/saturation correction: the scanner's "Color Matching: None" (see CLAUDE.md) captures the
    # fullest, least-processed signal, but that means no ICC color management either -- the
    # masthead blue reads about 3 degrees off-hue and visibly less saturated than the 1999 print
    # reference. -modulate adjusts hue and saturation in true HSL space, so it leaves near-neutral
    # pixels (body text) untouched -- confirmed identical, down to the pixel, on a black-text sample
    # before and after, at both this hue and saturation setting. This is unlike the driver's own
    # Color Balance sliders, which visibly tinted black text magenta for the same correction and
    # were rejected for that reason. 100,150,102 measured within ~1 degree of hue and ~2 points of
    # saturation of the reference on the masthead.
    if (-not $NoHueFix) { $ops += @("-modulate", "100,150,102") }

    # Descreening softens the printing raster the 400 dpi master faithfully recorded: it makes
    # photographs match the 1956-1999 archive's raster and improves OCR by removing halftone dots
    # that otherwise get mistaken for letter detail. Belongs here, not baked into the master.
    # Blur radius kept light (1.0, not the 2.2 tried earlier): 2.2 fully smooths halftone dots but
    # measurably softens body text, which is the overwhelming majority of page content; 1.0 leaves
    # faint residual dot texture in photos but keeps letterforms sharp.
    # -resample uses the stored DPI, so 400 -> 300 is a true resize, not a metadata edit.
    if ($NoDescreen) {
        & magick $t.FullName @ops -resample $Dpi $png
    } else {
        & magick $t.FullName @ops -resample $Dpi -gaussian-blur 0x1.0 -unsharp 0x1.5+1.2+0.02 $png
    }
    if (-not (Test-Path $png)) { Write-Output "  FAILED on $($t.Name)"; exit 1 }

    $fmt2 = & magick identify -format "%w|%h" $png 2>$null
    $wh2 = $fmt2 -split '\|'
    $pages += [pscustomobject]@{ Index = $i; Name = $t.Name; Path = $png; W = [int]$wh2[0]; H = [int]$wh2[1] }
}

Write-Output "Pass 2/2: pad to a common page size, encode"

# Pages come out at slightly different sizes even after the crop above: the driver's own
# edge-finding varies with the paper stock, and the band depth (if any) varies per page. Left
# alone, every other page looks a different size in a PDF viewer. Padding to one shared canvas,
# centered on white, fixes that without cropping content away. Landscape calendar inserts
# (deliberately rotated so their text reads sideways) get their own shared size rather than being
# forced into the portrait canvas.
$list = @()
if ($NoPad) {
    foreach ($p in $pages) {
        $jpg = Join-Path $work ("f{0:D4}.jpg" -f $p.Index)
        & magick $p.Path -quality $Quality $jpg
        $list += $jpg
        Write-Output ("  {0,3}. {1} -> {2:N1} MB" -f $p.Index, $p.Name, ((Get-Item $jpg).Length / 1MB))
    }
} else {
    $portrait = $pages | Where-Object { $_.W -le $_.H }
    $landscape = $pages | Where-Object { $_.W -gt $_.H }
    $pW = 0; $pH = 0; $lW = 0; $lH = 0
    if ($portrait) {
        $pW = ($portrait.W | Measure-Object -Maximum).Maximum
        $pH = ($portrait.H | Measure-Object -Maximum).Maximum
    }
    if ($landscape) {
        $lW = ($landscape.W | Measure-Object -Maximum).Maximum
        $lH = ($landscape.H | Measure-Object -Maximum).Maximum
    }
    foreach ($p in $pages) {
        $jpg = Join-Path $work ("f{0:D4}.jpg" -f $p.Index)
        if ($p.W -gt $p.H) { $tw = $lW; $th = $lH } else { $tw = $pW; $th = $pH }
        & magick $p.Path -gravity center -background white -extent "${tw}x${th}" -quality $Quality $jpg
        if (-not (Test-Path $jpg)) { Write-Output "  FAILED padding $($p.Name)"; exit 1 }
        $list += $jpg
        Write-Output ("  {0,3}. {1} -> {2}x{3} padded to {4}x{5} -> {6:N1} MB" -f $p.Index, $p.Name, $p.W, $p.H, $tw, $th, ((Get-Item $jpg).Length / 1MB))
    }
}

$pdfBase = Join-Path $OutputDir $Issue

if ($NoOcr) {
    & magick $list "$pdfBase.pdf"
} else {
    # Tesseract takes a file listing images, one per line, and emits one multi-page PDF
    # with an invisible text layer over the images.
    $listFile = Join-Path $work "pages.txt"
    $list | Set-Content -Path $listFile -Encoding ASCII
    & $TESSERACT $listFile $pdfBase --tessdata-dir $TESSDATA -l ukr+pol pdf
}

Remove-Item $work -Recurse -Force

if (-not (Test-Path "$pdfBase.pdf")) {
    Write-Output "PDF was not produced."
    exit 1
}

$mb = (Get-Item "$pdfBase.pdf").Length / 1MB
Write-Output ("Done: {0}.pdf  ({1:N1} MB)" -f $pdfBase, $mb)

# Checksums over the masters and the delivered PDF. Storage rot is silent; without a
# recorded hash there is no way to prove years later that a file is still the one made today.
$sumFile = Join-Path $InputDir "SHA256SUMS.txt"
$lines = @()
foreach ($t in ($tifs | Sort-Object Name)) {
    $h = (Get-FileHash -Algorithm SHA256 -Path $t.FullName).Hash.ToLower()
    $lines += "$h  $($t.Name)"
}
$pdfHash = (Get-FileHash -Algorithm SHA256 -Path "$pdfBase.pdf").Hash.ToLower()
$lines += "$pdfHash  ..\$Issue.pdf"
$lines | Set-Content -Path $sumFile -Encoding ASCII
Write-Output ("Checksums: {0} ({1} entries)" -f $sumFile, $lines.Count)
