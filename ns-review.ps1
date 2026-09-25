# Огляд номерів після обробки (станції 3 і 3a конвеєра, КОНВЕЄР.md).
#
#   .\ns-review.ps1                     меню огляду: черга номерів у стані review / fix
#   .\ns-review.ps1 -Status             скільки номерів у якому стані (одним рядком)
#   .\ns-review.ps1 -List               черга з позначеними сторінками, без запитів
#   .\ns-review.ps1 -Seq 2320 -Accept   прийняти номер (review/fix -> ready)
#   .\ns-review.ps1 -Seq 2320 -Note "стор. 5: зріз зліва замалий"   -> fix (нотатка «поправити»)
#   .\ns-review.ps1 -Fixes              для Claude: нотатки з черги fix
#   .\ns-review.ps1 -Seq 2320 -Fixed "page_edge 5L7"   Claude виправив -> знову review
#
# Огляд: оператор дивиться PDF без OCR (його готує ns-prepare) і список позначених сторінок.
#   A — прийняти (ready: іде на збирання), N — нотатка текстом (fix: чекає Claude), Enter — назад.
# Нотатки лежать у маніфесті (review_notes), кожна зміна стану — у state_log. Майстри не чіпаються.

param(
    [int]$Seq = 0,
    [switch]$Accept,
    [string]$Note,
    [switch]$Fixes,
    [string]$Fixed,
    [switch]$Status,
    [switch]$List,
    [switch]$NoOpen
)

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$line = "-" * 74

function Get-ReviewQueue {
    @(Read-NsRegistry | Where-Object { $_.PSObject.Properties.Name -contains 'state' -and $_.state -in @("review", "fix") } |
        Sort-Object { [int]$_.seq_first })
}

function Get-ReviewInfo {
    <#  Що знаємо про номер: PDF, позначені сторінки (з prepare.json), нотатки. #>
    param([int]$SeqNo)
    $dir = Find-NsIssueDir -Seq $SeqNo
    if (-not $dir) { return $null }
    $man = Read-NsManifest -IssueDir $dir
    $pj = Join-Path $script:NS_WORK "$SeqNo\prepare.json"
    $prep = $null
    if (Test-Path $pj) { try { $prep = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $pdf = ""
    if ($prep -and $prep.preview_pdf -and (Test-Path $prep.preview_pdf)) { $pdf = [string]$prep.preview_pdf }
    else {
        $c = @(Get-ChildItem $script:NS_WORK -Filter "${SeqNo}_vyglyad_*.pdf" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1)
        if ($c.Count) { $pdf = $c[0].FullName }
    }
    $flags = @()
    if ($prep) {
        foreach ($w in @($prep.edge_watch)) { if ($w) { $flags += ("край (нагляд): " + $w) } }
        if ($prep.spine) {
            foreach ($p in @($prep.spine.pages)) {
                foreach ($f in @($p.flags)) { if ($f) { $flags += ("стор. {0}: {1}" -f $p.n, $f) } }
            }
        }
        if ($prep.holes -and $prep.holes.pages_with_left) { foreach ($h in @($prep.holes.pages_with_left)) { $flags += ("дірка лишилась, стор. " + $h) } }
        foreach ($u in @($prep.render_not_unified)) { if ($u) { $flags += ("не зведено до спільного розміру: " + $u) } }
        foreach ($u in @($prep.frame_uneven)) { if ($u) { $flags += ("нерівна рамка: " + $u) } }
    }
    $notes = @()
    if ($man.PSObject.Properties.Name -contains 'review_notes') { $notes = @($man.review_notes) }
    [pscustomobject]@{ Seq = $SeqNo; Dir = $dir; Manifest = $man; Prep = $prep; Pdf = $pdf; Flags = $flags; Notes = $notes; State = (Get-NsIssueState $man) }
}

function Set-ReviewDecision {
    param($Info, [string]$To, [string]$NoteText, [string]$Who)
    $m = $Info.Manifest
    if ($NoteText) {
        $arr = @($Info.Notes) + [pscustomobject]@{ at = (Get-Date).ToString("s"); by = $Who; state = $To; text = $NoteText }
        $m | Add-Member -NotePropertyName review_notes -NotePropertyValue $arr -Force
    }
    Set-NsIssueState -IssueDir $Info.Dir -Manifest $m -State $To -Note $(if ($NoteText) { "$Who`: $NoteText" } else { $Who })
}

function Show-Info {
    param($Info)
    Write-Host ""
    Write-Host ("  НОМЕР {0}  ({1}, {2} стор.)  стан: {3}" -f $Info.Seq, $Info.Manifest.date, @($Info.Manifest.pages).Count, $Info.State) -ForegroundColor Cyan
    if ($Info.Pdf) { Write-Host ("  PDF без OCR: {0}" -f $Info.Pdf) } else { Write-Host "  PDF без OCR: НЕМАЄ (запусти ns-prepare -Seq $($Info.Seq))" -ForegroundColor Yellow }
    if ($Info.Prep -and $Info.Prep.edge) { Write-Host ("  page_edge  : {0}" -f $Info.Prep.edge) -ForegroundColor DarkGray }
    if ($Info.Prep -and $Info.Prep.holes) {
        Write-Host ("  дірки      : зарощено {0} із {1}" -f $Info.Prep.holes.filled, $Info.Prep.holes.expected) -ForegroundColor DarkGray
    }
    if ($Info.Flags.Count) {
        Write-Host "  ПОЗНАЧЕНО:" -ForegroundColor Yellow
        foreach ($f in $Info.Flags) { Write-Host ("    - " + $f) -ForegroundColor Yellow }
    } else {
        Write-Host "  Позначок немає." -ForegroundColor Green
    }
    if ($Info.Notes.Count) {
        Write-Host "  НОТАТКИ:" -ForegroundColor Magenta
        foreach ($n in $Info.Notes) { Write-Host ("    {0} [{1} -> {2}] {3}" -f ([string]$n.at).Substring(0, 16).Replace("T", " "), $n.by, $n.state, $n.text) -ForegroundColor Magenta }
    }
}

# ------------------------------------------------------------------ режими без запитів
if ($Status) {
    $rows = @(Read-NsRegistry)
    $parts = @()
    foreach ($s in $script:NS_STATES) {
        $c = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'state' -and $_.state -eq $s }).Count
        if ($c -gt 0) { $parts += ("{0} {1}" -f $s, $c) }
    }
    $none = @($rows | Where-Object { -not ($_.PSObject.Properties.Name -contains 'state') -or -not $_.state }).Count
    if ($none) { $parts += "без стану $none" }
    Write-Host ("Конвеєр: " + ($parts -join " · "))
    exit 0
}

if ($Fixes) {
    $q = @(Read-NsRegistry | Where-Object { $_.PSObject.Properties.Name -contains 'state' -and $_.state -eq "fix" } | Sort-Object { [int]$_.seq_first })
    if ($q.Count -eq 0) { Write-Host "Черга «поправити» порожня."; exit 0 }
    foreach ($r in $q) {
        $i = Get-ReviewInfo -SeqNo ([int]$r.seq_first)
        Write-Host ("== {0} ({1}) — нотатки оператора:" -f $i.Seq, $i.Manifest.date)
        foreach ($n in @($i.Notes | Where-Object { $_.state -eq "fix" })) { Write-Host ("   [{0}] {1}" -f ([string]$n.at).Substring(0, 16).Replace("T", " "), $n.text) }
        if ($i.Manifest.PSObject.Properties.Name -contains 'page_edge') { Write-Host ("   page_edge зараз: {0}" -f $i.Manifest.page_edge) }
    }
    exit 0
}

if ($Seq -gt 0 -and ($Accept -or $Note -or $Fixed)) {
    $i = Get-ReviewInfo -SeqNo $Seq
    if (-not $i) { Write-Host "Номер $Seq не знайдено." -ForegroundColor Red; exit 1 }
    if ($Accept) {
        Set-ReviewDecision -Info $i -To "ready" -NoteText $Note -Who "оператор"
        Write-Host "$Seq -> ready (прийнято)." -ForegroundColor Green
    } elseif ($Note) {
        Set-ReviewDecision -Info $i -To "fix" -NoteText $Note -Who "оператор"
        Write-Host "$Seq -> fix. Нотатка записана." -ForegroundColor Yellow
    } else {
        if ($i.State -ne "fix") { Write-Host "$Seq у стані '$($i.State)', не fix — все одно повертаю на огляд." -ForegroundColor Yellow }
        Set-ReviewDecision -Info $i -To "review" -NoteText $Fixed -Who "Claude"
        Write-Host "$Seq -> review (поправлено)." -ForegroundColor Green
    }
    exit 0
}

$queue = Get-ReviewQueue
if ($List) {
    if ($queue.Count -eq 0) { Write-Host "Черга огляду порожня."; exit 0 }
    foreach ($r in $queue) { Show-Info (Get-ReviewInfo -SeqNo ([int]$r.seq_first)) }
    exit 0
}

# ------------------------------------------------------------------ інтерактивний огляд
while ($true) {
    $queue = Get-ReviewQueue
    Write-Host ""
    Write-Host "  ОГЛЯД" -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor DarkGray
    if ($queue.Count -eq 0) { Write-Host "  Черга порожня: номерів на огляді немає." -ForegroundColor Green; break }
    $i = 0; $map = @{}
    foreach ($r in $queue) {
        $i++; $map["$i"] = [int]$r.seq_first
        $inf = Get-ReviewInfo -SeqNo ([int]$r.seq_first)
        $col = if ($inf.State -eq "fix") { "Magenta" } else { "Yellow" }
        Write-Host ("  [{0}]  {1}  {2}  {3} стор.  {4}  позначок: {5}{6}" -f $i, $inf.Seq, $inf.Manifest.date, @($inf.Manifest.pages).Count,
                    $(if ($inf.State -eq "fix") { "ЧЕКАЄ CLAUDE" } else { "на огляді" }), $inf.Flags.Count,
                    $(if (-not $inf.Pdf) { "  (немає PDF!)" } else { "" })) -ForegroundColor $col
    }
    Write-Host "  [Q]  Назад"
    Write-Host "  $line" -ForegroundColor DarkGray
    $ch = Read-Host "  Вибір"
    if ($ch -match '^[QqКк]' -or [string]::IsNullOrWhiteSpace($ch)) { break }
    if (-not $map.ContainsKey($ch.Trim())) { continue }
    $inf = Get-ReviewInfo -SeqNo $map[$ch.Trim()]
    Show-Info $inf
    if ($inf.Pdf -and -not $NoOpen) { Start-Process $inf.Pdf }
    Write-Host ""
    Write-Host "  [A] прийняти   [N] поправити (нотатка)   [Enter] назад, нічого не міняти"
    $d = Read-Host "  Рішення"
    if ($d -match '^[AaАа]') {
        Set-ReviewDecision -Info $inf -To "ready" -NoteText "" -Who "оператор"
        Write-Host ("  {0} прийнято -> ready." -f $inf.Seq) -ForegroundColor Green
    } elseif ($d -match '^[NnНн]') {
        $t = Read-Host "  Що поправити (текстом: сторінка, край, скільки)"
        if ([string]::IsNullOrWhiteSpace($t)) { Write-Host "  Порожню нотатку не записую — нічого не змінено." -ForegroundColor Yellow }
        else {
            Set-ReviewDecision -Info $inf -To "fix" -NoteText $t.Trim() -Who "оператор"
            Write-Host ("  {0} -> fix. Нотатку передано в чергу «поправити»." -f $inf.Seq) -ForegroundColor Yellow
        }
    }
}
exit 0
