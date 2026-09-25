param(
    [Parameter(Mandatory = $true)][string]$InputDir,
    [switch]$Fix,                        # also rotate pages that need it
    [double]$MinSizeMB = 8.0,            # below this a page is almost certainly blank or a failed scan
    [double]$MinRotateConfidence = 12.0  # never auto-rotate on a weaker reading than this
)

$TESSERACT = "C:\Program Files\Tesseract-OCR\tesseract.exe"
$TESSDATA  = "C:\Users\sever\Documents\Scans\tessdata"
$fso = New-Object -ComObject Scripting.FileSystemObject

$tifs = Get-ChildItem -Path $InputDir -File |
        Where-Object { $_.Extension -in ".tif", ".tiff" } |
        Sort-Object Name

if ($tifs.Count -eq 0) { Write-Output "No TIFF files in $InputDir"; exit 1 }

Write-Output ("Checking {0} page(s) in {1}" -f $tifs.Count, $InputDir)
Write-Output ""

$problems = 0
$rotated  = 0

foreach ($t in $tifs) {
    $flags = @()

    # --- format: must stay a lossless 24-bit 400 dpi master ---
    $fmt = & magick identify -format "%[compression]|%[resolution.x]|%[depth]|%[channels]|%w|%h" $t.FullName 2>$null
    $p = $fmt -split '\|'
    $compression = $p[0]; $dpi = [math]::Round([double]$p[1]); $depth = [int]$p[2]
    $channels = $p[3];    $w = [int]$p[4];  $h = [int]$p[5]

    if ($compression -ne "LZW")        { $flags += "compression=$compression (not LZW)" }
    if ($dpi -ne 400)                  { $flags += "dpi=$dpi" }
    if ($depth -ne 8)                  { $flags += "depth=$depth" }
    if ($channels -notmatch "^srgb")   { $flags += "channels=$channels" }

    # --- size: a lid left open, or a scan that never reached the page ---
    $mb = [math]::Round($t.Length / 1MB, 1)
    if ($mb -lt $MinSizeMB) { $flags += "size=${mb}MB" }

    # --- blank page: almost uniform brightness across the whole sheet ---
    $mean = [double](& magick $t.FullName -colorspace Gray -format "%[fx:mean*255]" info: 2>$null)
    if ($mean -gt 244) { $flags += ("blank? mean={0:N0}" -f $mean) }

    # No automatic check for a clipped right edge. Three were tried and all failed: paper and
    # backing sit at nearly the same tone once exposure is correct, so neither edge brightness
    # nor ink density separates a cut page from an intact one -- a deliberately chopped test
    # file measured *brighter* at the edge than the intact original. This one stays with the
    # operator: a person sees a word cut in half instantly. See the per-issue visual check.

    # --- orientation ---
    $short = $fso.GetFile($t.FullName).ShortPath
    $osd = & $TESSERACT $short stdout --tessdata-dir $TESSDATA --psm 0 2>$null
    $rline = $osd | Select-String "^Rotate:"
    $deg = 0
    if ($rline) { $deg = [int]($rline.ToString() -replace "Rotate:\s*", "") }

    $cline = $osd | Select-String "^Orientation confidence:"
    $conf = 0.0
    if ($cline) { $conf = [double]($cline.ToString() -replace "Orientation confidence:\s*", "") }

    if ($deg -ne 0) {
        if (-not $Fix) {
            $flags += ("needs rotate {0}deg (conf {1:N1})" -f $deg, $conf)
        }
        elseif ($conf -lt $MinRotateConfidence) {
            # A wrong rotation is worse than none: it silently turns a good master upside down,
            # and nothing downstream will notice. Below this confidence the page goes to a human.
            $flags += ("orientation unclear: {0}deg at conf {1:N1} -- NOT rotated" -f $deg, $conf)
        }
        else {
            & magick $t.FullName -rotate $deg -compress LZW $t.FullName
            $rotated++
            $flags += ("ROTATED {0}deg (conf {1:N1})" -f $deg, $conf)
        }
    }

    if ($flags.Count -eq 0) {
        Write-Output ("  OK    {0,-26} {1}x{2}  {3}MB" -f $t.Name, $w, $h, $mb)
    } else {
        $problems++
        Write-Output ("  CHECK {0,-26} {1}" -f $t.Name, ($flags -join "; "))
    }
}

Write-Output ""
if ($Fix -and $rotated -gt 0) { Write-Output "$rotated page(s) rotated." }
if ($problems -eq 0) {
    Write-Output "All $($tifs.Count) page(s) pass."
} else {
    Write-Output "$problems of $($tifs.Count) page(s) need a look."
    exit 1
}
