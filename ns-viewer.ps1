# Вікно перегляду щойно відсканованої сторінки на другому моніторі.
# Запускає його ns-scan.ps1 сам; окремо — лише для перевірки:
#
#   .\ns-viewer.ps1                 показати те, що зараз у NS_WORK\_live
#   .\ns-viewer.ps1 -Screen 2       на іншому екрані (номер зі списку -ListScreens)
#   .\ns-viewer.ps1 -ListScreens
#
# Вікно НЕ забирає фокус (WS_EX_NOACTIVATE): Enter у консолі сканування
# далі йде в консоль. Читає NS_WORK\_live\state.json раз на 0,4 с; закривається,
# коли ns-scan пише status=done або коли процес ns-scan зникає. Esc — закрити.
# Екран за умовчанням — вертикальний (висота > ширини), інакше будь-який
# неосновний; якщо другого екрана немає — вікно не відкривається. Нижні
# NS_CONSOLE_RESERVE пікселів лишаються під консоль (ns-scan переносить її туди).

param([int]$ParentPid = 0, [int]$Screen = -1, [switch]$ListScreens)

. "$PSScriptRoot\ns-lib.ps1"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$screens = [System.Windows.Forms.Screen]::AllScreens
if ($ListScreens) {
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $s = $screens[$i]
        "{0}: {1}  {2}x{3} at {4},{5}{6}" -f $i, $s.DeviceName, $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $(if ($s.Primary) { "  (основний)" } else { "" })
    }
    exit 0
}
$scr = $null
if ($Screen -ge 0 -and $Screen -lt $screens.Count) { $scr = $screens[$Screen] }
if (-not $scr) { $scr = Get-NsViewerScreen }
if (-not $scr) { exit 0 }
# нижня смуга екрана лишається під консоль сканування (оператор тримає її на
# тому ж X24ih; 21.09.2026) — вікно перегляду її не перекриває
$area = $scr.WorkingArea
$area = New-Object System.Drawing.Rectangle $area.X, $area.Y, $area.Width, ($area.Height - $script:NS_CONSOLE_RESERVE)

if (-not ("NsNoActivateForm" -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Windows.Forms;
public class NsNoActivateForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000; return cp; }
    }
}
"@
}

$dark = [System.Drawing.Color]::FromArgb(28, 28, 28)
$f = New-Object NsNoActivateForm
$f.Text = "Наше слово — скан"
$f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.Bounds = $area
$f.BackColor = $dark; $f.KeyPreview = $true

$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Top'; $status.Height = 56; $status.TextAlign = 'MiddleCenter'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$status.ForeColor = 'White'; $status.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$status.Text = "Очікую першу сторінку…"

$expect = New-Object System.Windows.Forms.Label
$expect.Dock = 'Bottom'; $expect.Height = 40; $expect.TextAlign = 'MiddleCenter'
$expect.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$expect.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 120); $expect.BackColor = $dark

$warnLbl = New-Object System.Windows.Forms.Label
$warnLbl.Dock = 'Bottom'; $warnLbl.Height = 52; $warnLbl.TextAlign = 'MiddleCenter'
$warnLbl.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$warnLbl.ForeColor = 'White'; $warnLbl.BackColor = $dark

$page = New-Object System.Windows.Forms.PictureBox
$page.Dock = 'Fill'; $page.SizeMode = 'Zoom'; $page.BackColor = $dark

$f.Controls.Add($page); $f.Controls.Add($expect); $f.Controls.Add($warnLbl); $f.Controls.Add($status)

# зображення читаються з байтів: файл не блокується, ns-scan може його переписати
function Set-Img($box, [string]$path) {
    $old = $box.Image
    if (Test-Path $path) {
        try {
            $ms = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
            $box.Image = [System.Drawing.Image]::FromStream($ms)
        } catch { $box.Image = $null }
    } else { $box.Image = $null }
    if ($old) { $old.Dispose() }
}

$stateFile = Join-Path $script:NS_LIVE "state.json"
$script:lastTs = ""
$script:started = Get-Date
$f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $f.Close() } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    if ($ParentPid -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { $f.Close(); return }
    if (-not (Test-Path $stateFile)) { return }
    # читаємо з дозволом на одночасний запис і заміну: інакше ns-scan не може
    # підмінити state.json і сканування отримує помилку (23.09.2026)
    try {
        $fsr = [IO.File]::Open($stateFile, 'Open', 'Read', 'ReadWrite, Delete')
        $sr = New-Object IO.StreamReader($fsr, [Text.UTF8Encoding]::new($false))
        $json = $sr.ReadToEnd(); $sr.Close(); $fsr.Close()
        $st = $json | ConvertFrom-Json
    } catch { return }
    if ($st.ts -eq $script:lastTs) { return }
    $script:lastTs = $st.ts
    # «done», записане ДО запуску вікна, — залишок минулого сканування, не нам
    # (21.09.2026: так вікно закривалося, не встигши відкритися)
    if ($st.status -eq "done") {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse([string]$st.ts, [ref]$when) -and $when -lt $script:started) { return }
        $f.Close(); return
    }
    if ($st.status -eq "scanning") {
        $status.BackColor = [System.Drawing.Color]::FromArgb(200, 120, 0)
        $status.Text = "Сканую сторінку $($st.next)…"
        return
    }
    $status.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $status.Text = "{0} · стор. {1} з {2} · {3} · {4} кадр" -f $st.seq, $st.page, $st.expected, $st.dims, $st.frames
    $expect.Text = $st.expect
    Set-Img $page (Join-Path $script:NS_LIVE "preview.jpg")
    $w = @($st.warnings)
    if ($st.checking) {
        # показ уже є, перевірки ще йдуть (ns-livecheck у фоні)
        $warnLbl.Height = 52
        $warnLbl.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
        $warnLbl.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        $warnLbl.Text = "Перевіряю…"
    } elseif ($w.Count -eq 0) {
        $warnLbl.Height = 52
        $warnLbl.BackColor = [System.Drawing.Color]::FromArgb(30, 110, 50); $warnLbl.Text = "Технічно гаразд (розмір, кадри, дубль) — номер у підвалі звір із підказкою"
    } else {
        $isErr = @($w | Where-Object { $_.lvl -eq "err" }).Count -gt 0
        $warnLbl.BackColor = if ($isErr) { [System.Drawing.Color]::FromArgb(170, 30, 30) } else { [System.Drawing.Color]::FromArgb(170, 130, 0) }
        $warnLbl.Height = 40 + 30 * ($w.Count + 1)   # тривога — смуга росте, сторінка трохи менша
        $warnLbl.Font = New-Object System.Drawing.Font('Segoe UI', $(if ($w.Count -gt 2) { 12 } else { 15 }), [System.Drawing.FontStyle]::Bold)
        $warnLbl.Text = (@($w | ForEach-Object { $_.text }) -join "`n") + "`n[R] у консолі — перезняти цю сторінку"
    }
})
$timer.Start()
[System.Windows.Forms.Application]::Run($f)
