# PDF без OCR для огляду оператором з готового render + перевірки рамки й полів.
#
#   .\ns-preview.ps1 -Seq 2296
#
# Для ручних номерів (новий дизайн, посторінкові вказівки оператора): після ns-prep і
# ns-render. Робить те саме, що крок 6 ns-prepare, окремо:
#   ns-framecheck.py і ns-margins.py на C:\NS_WORK\<N>\render (числа — у вивід),
#   PDF C:\NS_WORK\<N>_vyglyad_<ДД.ММ>.pdf (img2pdf, без перекодування JPEG).
# Наявний PDF з тим самим іменем не перезаписується — новий дістає суфікс _2, _3 …
# Нічого, крім цього PDF, не пише.

#   .\ns-preview.ps1 -Seq 9287 -Pages "2,8" -Name 2287_zrazok_q55   зразок із вибраних сторінок (ім'я файлу — Name)

param([Parameter(Mandatory = $true)][int]$Seq, [string]$Pages = "", [string]$Name = "")

. "$PSScriptRoot\ns-lib.ps1"
Initialize-NsConsole

$render = Join-Path (Join-Path $script:NS_WORK "$Seq") "render"
if (-not (Test-Path (Join-Path $render "p01.jpg"))) { Write-Host "Немає render для $Seq." -ForegroundColor Red; exit 1 }
$py = if ($script:PYTHON) { $script:PYTHON } else { "python" }

Write-Host "Рамка:" -ForegroundColor Cyan
& $py (Join-Path $PSScriptRoot "ns-framecheck.py") $render | Select-Object -Last 1 | ForEach-Object { Write-Host "  $_" }
Write-Host "Поля друку (зовні - корінь):" -ForegroundColor Cyan
& $py (Join-Path $PSScriptRoot "ns-margins.py") $render | Where-Object { $_ -match '<<<|^сторінок' } | ForEach-Object { Write-Host "  $_" }

$base = if ($Name) { $Name } else { "{0}_vyglyad_{1}" -f $Seq, (Get-Date).ToString("dd.MM") }
$pdf = Join-Path $script:NS_WORK "$base.pdf"
$k = 2
while (Test-Path $pdf) { $pdf = Join-Path $script:NS_WORK ("{0}_{1}.pdf" -f $base, $k); $k++ }
$env:NS_PDF_OUT = $pdf; $env:NS_PDF_SRC = $render
$env:NS_PDF_PAGES = (@($Pages -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { "p{0:D2}.jpg" -f [int]$_ }) -join ",")
$r = & $py -c "import img2pdf,glob,os; sel=[x for x in os.environ.get('NS_PDF_PAGES','').split(',') if x]; fs=sorted(glob.glob(os.path.join(os.environ['NS_PDF_SRC'],'p*.jpg'))); fs=[f for f in fs if not sel or os.path.basename(f) in sel]; open(os.environ['NS_PDF_OUT'],'wb').write(img2pdf.convert(fs)); print(len(fs), os.path.getsize(os.environ['NS_PDF_OUT']))" 2>&1
if (-not (Test-Path $pdf)) { Write-Host "PDF не зроблено: $r" -ForegroundColor Red; exit 1 }
Write-Host ("PDF без OCR: {0} (сторінок і байтів: {1})" -f $pdf, $r) -ForegroundColor Green
