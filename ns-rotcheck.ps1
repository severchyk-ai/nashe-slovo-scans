# Який кут повороту потрібен сторінці: пробуємо 0/90/180/270 і дивимося, де
# текст РОЗПІЗНАЄТЬСЯ. OSD (Tesseract --psm 0) на вкладках часто не певний:
# у 2323 «Світанок» він радив кути з упевненістю 0,5-10 при порозі 12, і
# сторінки лишилися лежати боком, хоча кут був правильний.
#
#   .\ns-rotcheck.ps1 -Seq 2323 -Pages "6,7,8,9"
#   .\ns-rotcheck.ps1 -Seq 2323                 усі сторінки номера
#
# Працює на майстрах (до обробки), на зменшеній до 150 dpi копії — цього
# досить, щоб порахувати слова. Рахуються слова щонайменше з 4 літер, у яких
# лише українські/польські літери: так відкидається сміття з боку лежачого
# тексту. Кут із найбільшою кількістю таких слів і є правильний; якщо різниця
# менша за третину — кажемо «непевно» і лишаємо рішення операторові.

param([Parameter(Mandatory = $true)][int]$Seq, [string]$Pages = "")

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole
Initialize-NsOcrEnv

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$want = @()
if ($Pages) { $want = @($Pages -split '[,;]' | ForEach-Object { [int]$_.Trim() }) }

$T = Join-Path $env:TEMP ("ns_rot_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $T -Force | Out-Null
$rx = [regex]'^[А-ЯҐЄІЇа-яґєіїA-Za-zĄĆĘŁŃÓŚŹŻąćęłńóśźż]{4,}$'
try {
    foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
        $n = [int]$p.n
        if ($want.Count -and $want -notcontains $n) { continue }
        $src = Join-Path $issueDir $p.file
        $counts = @{}
        foreach ($deg in 0, 90, 180, 270) {
            $img = Join-Path $T ("r{0}.png" -f $deg)
            & magick "$src[0]" -resample 150 -colorspace Gray -rotate $deg $img 2>$null
            $txt = & $script:TESSERACT $img stdout --tessdata-dir $script:TESSDATA -l ukr+pol --psm 3 2>$null
            $w = @(($txt -join " ") -split '\s+' | Where-Object { $rx.IsMatch($_) })
            $counts[$deg] = $w.Count
        }
        $best = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $second = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -Skip 1 -First 1)
        $sure = if ($second.Value -eq 0) { $best.Value -gt 20 } else { ($best.Value / [double]$second.Value) -ge 1.5 }
        $line = "  p{0:D2}  0°={1,5}  90°={2,5}  180°={3,5}  270°={4,5}  ->  {5}°" -f `
                $n, $counts[0], $counts[90], $counts[180], $counts[270], $best.Key
        if (-not $sure) { $line += "   НЕПЕВНО — дивитися очима" }
        Write-Host $line -ForegroundColor $(if ($sure) { "Green" } else { "Yellow" })
    }
} finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "Записати кути: .\ns-prep.ps1 -Seq $Seq -RotatePages `"6:90,7:270`" -Force" -ForegroundColor Cyan
