# Етап 7 — перевірки якості зібраного номера.
#
#   .\ns-qc.ps1 -Seq 2231
#   .\ns-qc.ps1 -All
#
# Працює лише з тим, що зберігається назавжди: майстри, готовий PDF і текст
# OCR (NS_WORK\<номер>\ocr.txt). Проміжні теки prep/render ns-issue прибирає,
# тож спиратися на них не можна.
#
# Перевірки 1–4 (кількість сторінок, дублікати, розриви нумерації, безперервність
# номерів) живуть у ns-verify.ps1 — там, де й звірка хешів. Тут 5–8.

param([int]$Seq, [switch]$All)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

if (-not $Seq -and -not $All) { Write-Host "Вкажи -Seq <номер> або -All." -ForegroundColor Red; exit 1 }

$targets = if ($All) {
    @(Read-NsRegistry | Where-Object { $_.status -eq "delivered" } |
      Sort-Object { [int]$_.seq_first } | ForEach-Object { [int]$_.seq_first })
} else { @($Seq) }

if ($targets.Count -eq 0) { Write-Host "Немає зібраних номерів." -ForegroundColor Yellow; exit 0 }

$allFlags = @()

foreach ($s in $targets) {
    $issueDir = Find-NsIssueDir -Seq $s
    if (-not $issueDir) { Write-Host "Номер $s не знайдено." -ForegroundColor Red; continue }
    $man = Read-NsManifest -IssueDir $issueDir
    $flags = @()

    Write-Host ""
    Write-Host "Номер $s  ($($man.date), № $($man.issue_no_in_year))" -ForegroundColor Cyan

    # --- #5: порожня або майже порожня сторінка ----------------------------
    # Ознака помилки оператора: аркуш не долягав, кришка накрила порожнє скло,
    # сторінку відскановано двічі як чисту. Рахуємо на зменшеній копії — повний
    # файл на 50 МБ заради середнього й розкиду гнати немає сенсу.
    foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
        $f = Join-Path $issueDir $p.file
        # Кілька кадрів в одному TIF — не порожня сторінка, а розрізаний скан;
        # і замір нижче на ньому дає злиплі числа «0.2505520.65486».
        $fc = Get-NsFrameCount -Path $f
        if ($fc -ne 1) { $flags += "стор. $($p.n): майстер містить $fc кадрів замість одного — сторінку розрізано при скануванні, пересканувати"; continue }
        $st = & magick $f -resize 300x -colorspace Gray -format "%[fx:mean]|%[fx:standard_deviation]" info: 2>$null
        $parts = "$st" -split '\|'
        if ($parts.Count -lt 2) { continue }
        $mean = [double]$parts[0]; $sd = [double]$parts[1]
        if ($sd -lt 0.03) {
            $flags += "#5 стор. $($p.n): майже порожня (розкид $([math]::Round($sd,4)), яскравість $([math]::Round($mean,3)))"
        }
    }

    # --- PDF на місці й з правильною кількістю сторінок --------------------
    $name = if ($man.seq_last -ne $man.seq_first) { "$($man.seq_first)-$($man.seq_last)" } else { "$($man.seq_first)" }
    $pdf = Join-Path (Join-Path $script:NS_PDF "$($man.year)") "$name.pdf"
    if (-not (Test-Path $pdf)) {
        $flags += "PDF не зібрано"
    } else {
        $n = & python -c "import pikepdf,sys; sys.stdout.write(str(len(pikepdf.open(r'$pdf').pages)))" 2>$null
        if ("$n" -ne "$(@($man.pages).Count)") {
            $flags += "у PDF $n сторінок, у маніфесті $(@($man.pages).Count)"
        }
        # хеш PDF мав бути записаний під час збірки — стежимо, щоб файл не
        # підмінили й не перезібрали повз каталог
        if ($man.PSObject.Properties.Name -contains 'pdf_sha256' -and $man.pdf_sha256) {
            if ((Get-NsHash $pdf) -ne $man.pdf_sha256) {
                $flags += "PDF змінився після збірки (хеш не збігається з маніфестом)"
            }
        }
        $mb = (Get-Item $pdf).Length / 1MB
        $perPage = $mb / [math]::Max(1, @($man.pages).Count)
        if ($perPage -lt $script:PDF_MB_PER_PAGE_MIN -or $perPage -gt $script:PDF_MB_PER_PAGE_MAX) {
            $flags += ("{0:N2} МБ/стор. поза орієнтиром архіву {1}-{2}" -f `
                       $perPage, $script:PDF_MB_PER_PAGE_MIN, $script:PDF_MB_PER_PAGE_MAX)
        }
    }

    # --- #6 і #7: якість OCR і звірка номера з шапки -----------------------
    $ocr = Get-NsOcrPath -IssueDir $issueDir
    if (-not (Test-Path $ocr)) {
        $flags += "немає тексту OCR — номер зібрано з -NoOcr?"
    } else {
        $txt = [IO.File]::ReadAllText($ocr, [Text.UTF8Encoding]::new($false))

        # #6. Помилку OCR видно без читання очима: слово, у якому змішані
        # кирилиця й латиниця, або суцільно латинське слово з самих лише
        # літер-двійників. Сам підрахунок — Get-NsOcrStats у ns-lib.
        $os = Get-NsOcrStats -Text $txt
        Write-Host ("  OCR: {0} слів, підозрілих {1} ({2:N2} %)" -f $os.Words, $os.Suspicious, $os.Pct)
        if ($os.Pct -gt 2.0) { $flags += ("#6 частка підозрілих слів {0:N2} % (поріг 2 %)" -f $os.Pct) }
        if ($os.Words -lt 2000) { $flags += "#6 лише $($os.Words) слів на весь номер — текстовий шар підозріло бідний" }

        # Порожня сторінка ловиться порівнянням із СУСІДАМИ, а не абсолютним
        # числом: газетна сторінка має 1300-2200 слів, але календарна вкладка
        # чи шпальта самих фотографій законно мають десятки. Поріг у 15 % від
        # медіани по номеру відрізняє «мало тексту, бо графіка» від
        # «не розпізналося зовсім».
        # Це не помилка, а привід глянути: у 2214 так знайшлася календарна
        # вкладка на стор. 5-6, і вона виявилася справжнім вмістом.
        $pageWords = @(($txt -split "`f") | ForEach-Object {
                          @([regex]::Matches($_, '[^\W\d_]{2,}')).Count })
        $pageWords = @($pageWords | Select-Object -First (@($man.pages).Count))
        if ($pageWords.Count -ge 5) {
            $sorted = @($pageWords | Sort-Object)
            $med = $sorted[[int]($sorted.Count / 2)]
            $thin = @()
            for ($i = 0; $i -lt $pageWords.Count; $i++) {
                if ($med -gt 0 -and $pageWords[$i] -lt $med * 0.15) {
                    $thin += "стор. $($i+1) — $($pageWords[$i])"
                }
            }
            if ($thin.Count -gt 0) {
                $flags += ("#6 майже без тексту при медіані {0} слів: {1} (вкладка або шпальта фотографій?)" -f `
                           $med, ($thin -join "; "))
            }
        }

        # #7. Наскрізний номер друкується в шапці першої сторінки. Якщо він
        # там є — метадані номера підтверджені самим виданням, а не лише
        # арифметикою від попереднього номера.
        $firstPage = ($txt -split "`f")[0]
        $seqSeen = $firstPage -match [regex]::Escape("$($man.seq_first)")

        # Запасний шлях: у звичайному тексті сторінки рядок із номером часом
        # губиться — на 2239, 2243, 2245 і 2246 решта шапки (ISSN, індекс,
        # «УКРАЇНСЬКИЙ ТИЖНЕВИК») розпізналася, а сам рядок «РІК XLV № 26
        # (2239) ВАРШАВА...» ні. Тоді розпізнаємо окремо верхню чверть
        # сторінки, збільшену до 130 %, у режимі колонки (--psm 4). На всіх
        # чотирьох це відновило номер.
        # Вузька смуга під шапкою тут НЕ годиться: верстка різниться від
        # номера до номера, і смуга просто не влучає.
        if (-not $seqSeen) {
            $p1 = @($man.pages | Sort-Object { [int]$_.n })[0]
            if ($p1) {
                Initialize-NsOcrEnv
                $src = Join-Path $issueDir $p1.file
                $wh = (& magick identify -format "%w|%h" $src 2>$null) -split '\|'
                if ($wh.Count -ge 2) {
                    $top = Join-Path $env:TEMP ("ns_mh_{0}.png" -f $s)
                    & magick $src -crop "$($wh[0])x$([int]([int]$wh[1] * 0.25))+0+0" +repage `
                             -colorspace Gray -resize 130% $top 2>$null | Out-Null
                    if (Test-Path $top) {
                        $mh = & $script:TESSERACT $top stdout --tessdata-dir $script:TESSDATA `
                                    -l ukr+pol --psm 4 2>$null
                        if (("$mh" -join " ") -match [regex]::Escape("$($man.seq_first)")) { $seqSeen = $true }
                        Remove-Item $top -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        # Другий рівноправний шлях: ДАТА на 1-й сторінці. З номера 2254
        # (08.10.2000) газета змінила верстку — шапка з «№ 41 [2254] РІК XLV»
        # лягла дрібним шрифтом на сіру растрову плашку, і розпізнавання її не
        # бере ні в тексті сторінки, ні окремим кадром на 300 %. А от дата в
        # підвалі 1-ї сторінки читається чисто: «8 października 2000».
        # Дата так само зберігається в каталозі й так само надрукована самим
        # виданням, тож підтверджує метадані не гірше за наскрізний номер.
        # Шукаємо обома мовами: газета українсько-польська.
        $dateSeen = $false
        if (-not $seqSeen -and $man.date -match '^(\d{4})-(\d{2})-(\d{2})$') {
            $yr = $Matches[1]; $mo = [int]$Matches[2]; $dy = [int]$Matches[3]
            $ua = @("січня","лютого","березня","квітня","травня","червня",
                    "липня","серпня","вересня","жовтня","листопада","грудня")
            $pl = @("stycznia","lutego","marca","kwietnia","maja","czerwca",
                    "lipca","sierpnia","września","października","listopada","grudnia")
            foreach ($mn in @($ua[$mo-1], $pl[$mo-1])) {
                if ($firstPage -match ("{0}\s*{1}\s*{2}" -f $dy, [regex]::Escape($mn), $yr)) {
                    $dateSeen = $true; break
                }
            }
        }

        if ($seqSeen) {
            Write-Host "  шапка підтверджує наскрізний номер $($man.seq_first)" -ForegroundColor Green
        } elseif ($dateSeen) {
            Write-Host "  1-ша сторінка підтверджує дату $($man.date)" -ForegroundColor Green
        } else {
            $flags += "#7 на 1-й сторінці не видно ні наскрізного номера $($man.seq_first), ні дати $($man.date)"
        }
    }

    # --- #9: відтінок паперу проти решти річника ---------------------------
    # Ловить номер, знятий за інших умов АБО надрукований на іншому папері.
    # Діагностична ознака — саме ВІДТІНОК (B-R), а не світлота: світлота
    # законно гуляє від номера до номера (більше фотографій — темніша
    # сторінка), а відтінок паперу тримається дуже щільно: на 19 номерах
    # у 18 з них B-R лежить у +2,8...+4,1.
    #
    # ⚠︎ ПРО ПРИЧИНУ НЕ ЗДОГАДУВАТИСЯ. Спершу тут стояло «імовірно знято на
    # непрогрітій лампі» — єдиний номер, що спрацював (2214), справді був
    # першим за день. Але перевірка показала інше: у 2214 папір світліший
    # (0,937 проти 0,873), а фарба МЕНШ світла, ніж у сусідів. Якби дрейфував
    # сенсор, папір і фарба зсунулися б в один бік; тут зріс контраст, а це
    # ознака іншого паперу. Оператор підтвердив: новорічний номер надруковано
    # на цупкішому глянцевому папері.
    # Окремий дослід (2253 і 2254, холодний старт і 16 хв простою) не виявив
    # дрейфу взагалі: зсув 0,8 одиниці, тобто в межах шуму.
    # Тому повідомлення лише КОНСТАТУЄ відмінність і перелічує можливі
    # причини, а висновок робить людина.
    #
    # Поріг 2,5 одиниці від медіани по річнику відділяє це від природного
    # розкиду з великим запасом.
    $issueCast = Get-NsIssueCast -IssueDir $issueDir -Manifest $man
    if ($null -ne $issueCast) {
        $peers = @()
        foreach ($row in (Read-NsRegistry | Where-Object { $_.year -eq $man.year -and [int]$_.seq_first -ne [int]$man.seq_first })) {
            $pd = Find-NsIssueDir -Seq ([int]$row.seq_first)
            if (-not $pd) { continue }
            $pm = Read-NsManifest -IssueDir $pd
            # СЕРЕДИННА сторінка, не перша. На 1-й сторінці шапка з великим
            # синім логотипом, а з жовтня 2000 ще й сині плашки на пів сторінки —
            # вони зміщують вимір паперу й роблять медіану по річнику нестійкою.
            # Через це перевірка хибно спрацьовувала на 2215 і 2216.
            $ps = @($pm.pages | Sort-Object { [int]$_.n })
            if ($ps.Count -eq 0) { continue }
            $one = $ps[[int]($ps.Count / 2)]
            $pc = Get-NsPaperColor -Path (Join-Path $pd $one.file) -Sample 64
            if ($pc) { $peers += ($pc[2] - $pc[0]) }
        }
        if ($peers.Count -ge 5) {
            $ps = @($peers | Sort-Object); $med = $ps[[int]($ps.Count/2)]
            $dev = [math]::Abs($issueCast - $med)
            Write-Host ("  відтінок паперу B-R {0:N1} (медіана по річнику {1:N1})" -f $issueCast, $med)
            if ($dev -gt 2.5) {
                $flags += ("#9 відтінок паперу {0:N1} проти {1:N1} по річнику — інший папір, інша фарба або інші умови зйомки; глянути й вирішити" -f $issueCast, $med)
            }
        }
    }

    # --- #8: відхилення ширини від медіани ---------------------------------
    $ws = @()
    foreach ($p in ($man.pages | Sort-Object { [int]$_.n })) {
        if ((Get-NsFrameCount -Path (Join-Path $issueDir $p.file)) -ne 1) { continue }   # уже позначено вище
        $w = & magick identify -format "%w" (Join-Path $issueDir $p.file) 2>$null
        if ($w) { $ws += [pscustomobject]@{ n = [int]$p.n; w = [int]$w } }
    }
    if ($ws.Count -ge 3) {
        $sorted = @($ws.w | Sort-Object)
        $median = $sorted[[int]($sorted.Count / 2)]
        foreach ($r in $ws) {
            $dev = [math]::Abs($r.w - $median) / $median * 100
            if ($dev -gt 3) { $flags += ("#8 стор. {0}: ширина {1} px проти медіани {2} — {3:N1} %" -f $r.n, $r.w, $median, $dev) }
        }
    }

    if ($flags.Count -eq 0) {
        Write-Host "  усі перевірки пройдено" -ForegroundColor Green
    } else {
        foreach ($f in $flags) { Write-Host "  ! $f" -ForegroundColor Yellow }
        $allFlags += $flags | ForEach-Object { "$s : $_" }
    }
}

Write-Host ""
if ($allFlags.Count -eq 0) {
    Write-Host "Зауважень немає." -ForegroundColor Green
    exit 0
}
Write-Host "Зауважень: $($allFlags.Count)" -ForegroundColor Yellow
exit 1
