# Разовий перенос уже відсканованих номерів зі старої пласкої схеми
#   Scans_NS_new\2214\2214_01.tif
# у структуру каталогу
#   C:\NS_MASTERS\2000\2214_2000-01-02\2214_2000-01-02_p01.tif  + маніфест + реєстр
#
# Копіює, не переміщує: оригінали лишаються, поки не звіримо хеші.
#   .\ns-migrate.ps1            — показати, що буде зроблено, нічого не змінюючи
#   .\ns-migrate.ps1 -Apply     — виконати

param(
    [switch]$Apply,
    [string]$SourceRoot = "C:\Users\sever\Documents\Scans_NS_new"
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

# Метадані підтверджені оператором 2026-09-04 (OCR шапок + тижнева прогресія).
$ISSUES = @(
    @{ seq = 2214; date = "2000-01-02"; no = 1  }
    @{ seq = 2215; date = "2000-01-09"; no = 2  }
    @{ seq = 2216; date = "2000-01-16"; no = 3  }
    @{ seq = 2217; date = "2000-01-23"; no = 4  }
    @{ seq = 2218; date = "2000-01-30"; no = 5  }
    @{ seq = 2219; date = "2000-02-06"; no = 6  }
    @{ seq = 2220; date = "2000-02-13"; no = 7  }
    @{ seq = 2221; date = "2000-02-20"; no = 8  }
    @{ seq = 2222; date = "2000-02-27"; no = 9  }
    @{ seq = 2223; date = "2000-03-05"; no = 10 }
    @{ seq = 2224; date = "2000-03-12"; no = 11 }
    @{ seq = 2225; date = "2000-03-19"; no = 12 }
    @{ seq = 2226; date = "2000-03-26"; no = 13 }
    @{ seq = 2227; date = "2000-04-02"; no = 14 }
    @{ seq = 2228; date = "2000-04-09"; no = 15 }
    @{ seq = 2229; date = "2000-04-16"; no = 16 }
    @{ seq = 2230; date = "2000-04-23"; no = 17 }
)

$SOURCE_VOLUME = "розшитий річник 2000"
$OPERATOR      = "sever"

if (-not $Apply) {
    Write-Host "`nПРОБНИЙ ЗАПУСК — нічого не змінюється. Для виконання: -Apply`n" -ForegroundColor Yellow
} else {
    Initialize-NsStore
}

$totalPages = 0; $totalBytes = 0; $problems = @()

foreach ($iss in $ISSUES) {
    $seq = $iss.seq; $date = $iss.date
    $src = Join-Path $SourceRoot "$seq"

    if (-not (Test-Path $src)) {
        $problems += "$seq : немає теки-джерела $src"
        continue
    }
    $files = @(Get-ChildItem -Path $src -Filter "*.tif" -File | Sort-Object Name)
    if ($files.Count -eq 0) { $problems += "$seq : у теці немає .tif"; continue }

    $dst = Get-NsIssueDir -SeqFirst $seq -Date $date

    # Інваріант: нічого не перезаписувати. Колізія = зупинка, не тихе злиття.
    if ((Test-Path $dst) -and @(Get-ChildItem $dst -Filter "*.tif" -File).Count -gt 0) {
        $problems += "$seq : призначення вже містить файли — пропущено ($dst)"
        continue
    }

    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    Write-Host ("{0}  {1}  {2} стор  {3,7:N0} МБ  -> {4}" -f `
        $seq, $date, $files.Count, ($bytes / 1MB), $dst)

    if (-not $Apply) { $totalPages += $files.Count; $totalBytes += $bytes; continue }

    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    $man = New-NsManifest -SeqFirst $seq -SeqLast $seq -Date $date -NoInYear $iss.no `
                          -PagesExpected 10 -Source $SOURCE_VOLUME -Operator $OPERATOR
    $man.scan_date = (Get-Item $files[0].FullName).LastWriteTime.ToString("yyyy-MM-dd")
    $man.status = "scanning"
    Write-NsManifest -IssueDir $dst -Manifest $man

    $n = 0; $bad = 0
    foreach ($f in $files) {
        $n++
        $name = Get-NsPageName -SeqFirst $seq -Date $date -Page $n
        $target = Join-Path $dst $name
        Copy-Item -Path $f.FullName -Destination $target
        # звірка копії з оригіналом перед тим, як визнати сторінку прийнятою
        if ((Get-NsHash $f.FullName) -ne (Get-NsHash $target)) {
            $problems += "$seq стор $n : хеш копії не збігається з оригіналом"
            $bad++
            continue
        }
        $null = Add-NsPage -IssueDir $dst -Manifest $man -PageNo $n -FileName $name
    }

    $man.status = if ($bad -eq 0 -and $n -eq $man.pages_expected) { "scanned" } else { "qc_flagged" }
    Write-NsManifest -IssueDir $dst -Manifest $man
    Set-NsRegistryRow -Manifest $man -Status $man.status -Bytes $bytes

    # контрольні суми в окремий файл каталогу
    if (@($man.pages).Count -gt 0) {
        $sumFile = Join-Path $script:CHECKSUMS "$seq.sha256"
        $lines = @(foreach ($p in $man.pages) { "$($p.sha256)  $($p.file)" })
        [IO.File]::WriteAllLines($sumFile, $lines, [Text.UTF8Encoding]::new($false))
    }

    $totalPages += $n; $totalBytes += $bytes
}

Write-Host ""
Write-Host ("Разом: {0} номерів, {1} сторінок, {2:N1} ГБ" -f `
    $ISSUES.Count, $totalPages, ($totalBytes / 1GB))

if ($problems.Count -gt 0) {
    Write-Host "`nПроблеми:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
} elseif ($Apply) {
    Write-Host "Помилок немає." -ForegroundColor Green
    $gaps = Test-NsSeqContinuity
    if ($gaps.Count -gt 0) {
        Write-Host "`nБезперервність номерів:" -ForegroundColor Yellow
        $gaps | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    } else {
        Write-Host "Безперервність номерів: розривів немає." -ForegroundColor Green
    }
    Write-Host "`nОригінали в $SourceRoot не змінені — видаляти лише після твоєї перевірки."
}
