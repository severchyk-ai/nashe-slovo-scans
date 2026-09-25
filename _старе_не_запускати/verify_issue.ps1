param(
    [Parameter(Mandatory = $true)][string]$InputDir   # issue folder containing SHA256SUMS.txt
)

$sumFile = Join-Path $InputDir "SHA256SUMS.txt"
if (-not (Test-Path $sumFile)) {
    Write-Output "No SHA256SUMS.txt in $InputDir - run build_issue_pdf.ps1 first."
    exit 1
}

$ok = 0; $bad = 0; $missing = 0

foreach ($line in Get-Content $sumFile) {
    if ($line -notmatch '^([0-9a-f]{64})\s\s(.+)$') { continue }
    $expected = $Matches[1]
    $rel      = $Matches[2]
    $path     = Join-Path $InputDir $rel

    if (-not (Test-Path $path)) {
        Write-Output ("  MISSING  {0}" -f $rel)
        $missing++
        continue
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
    if ($actual -eq $expected) {
        $ok++
    } else {
        Write-Output ("  CHANGED  {0}" -f $rel)
        $bad++
    }
}

Write-Output ""
Write-Output ("{0} unchanged, {1} changed, {2} missing." -f $ok, $bad, $missing)
if ($bad -gt 0 -or $missing -gt 0) { exit 1 }
Write-Output "Issue intact."
