# Перевірки щойно відсканованої сторінки — ОКРЕМИМ ПРОЦЕСОМ, у фоні.
#
#   .\ns-livecheck.ps1 -Seq 2332 -Page 7
#
# Навіщо окремо: показ сторінки на другому моніторі має бути миттєвим
# (Show-NsLiveFast, ~0,7 с), а перевірки коштують ще кілька секунд — розмір,
# кадри, смуга кришки, звірка з усіма вже знятими сторінками. Поки вони йдуть,
# оператор уже дивиться на сторінку й може класти наступний аркуш
# (прохання оператора 23.09.2026).
#
# Результат дописується в той самий NS_WORK\_live\state.json: поле warnings і
# checking=false. Якщо оператор уже відсканував наступну сторінку, запис
# пропускається — тривоги від старої сторінки не мають перебивати нову.

param([Parameter(Mandatory = $true)][int]$Seq, [Parameter(Mandatory = $true)][int]$Page)

. "$PSScriptRoot\ns-lib.ps1"

$issueDir = Find-NsIssueDir -Seq $Seq
if (-not $issueDir) { exit 1 }
$man = Read-NsManifest -IssueDir $issueDir
$entry = @($man.pages | Where-Object { [int]$_.n -eq $Page })
if ($entry.Count -ne 1) { exit 1 }
$tif = Join-Path $issueDir $entry[0].file
if (-not (Test-Path $tif)) { exit 1 }
$insert = if ($man.PSObject.Properties.Name -contains 'insert_pages') { $man.insert_pages } else { "" }

$warn = @(Update-NsLive -Tif $tif -Seq $man.seq_first -Page $Page -Expected $man.pages_expected `
                        -IssueDir $issueDir -Insert $insert -NoPreview)

# не перебивати вже показану НАСТУПНУ сторінку
$sp = Join-Path $script:NS_LIVE "state.json"
if (Test-Path $sp) {
    try {
        $st = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$st.page -ne $Page) { exit 0 }
    } catch { }
}
exit 0
