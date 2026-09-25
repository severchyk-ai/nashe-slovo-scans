# Створити (або перестворити) ярлик «Наше слово» на робочому столі.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File ns-shortcut.ps1
#   ...  -AsAdmin        додати вимогу прав адміністратора
#
# Ярлик веде на powershell.exe з -ExecutionPolicy Bypass, тому окремий .bat
# не потрібен: політика виконання обходиться прямо в аргументах.
#
# Прав адміністратора конвеєр не потребує — запис іде тільки в C:\NS_MASTERS,
# C:\NS_WORK і C:\NS_PDF, усі три створені й заповнені без адміна. -AsAdmin
# лишено на випадок, якщо тека каталогу колись переїде в захищене місце.

param([switch]$AsAdmin, [string]$Name = "Наше слово")

$script  = Join-Path $PSScriptRoot "ns-menu.ps1"
if (-not (Test-Path $script)) { Write-Host "Немає $script" -ForegroundColor Red; exit 1 }

$desktop = [Environment]::GetFolderPath("Desktop")
$lnk     = Join-Path $desktop "$Name.lnk"

$ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"

# Ярлик пишеться через IShellLinkW — Unicode-інтерфейс оболонки Windows.
# Раніше тут був WScript.Shell, і він переганяв рядки в системну ANSI-кодову
# сторінку (1252, без кирилиці): опис ярлика на 16.09.2026 виявився записаним
# як «?????????? ?? ?????», а зберегти ярлик у «OneDrive\Робочий стіл» він не
# міг узагалі. Складаємо ярлик у латинському шляху, переносимо .NET — це
# лишилося заради прапорця -AsAdmin, який правиться в байтах нижче.
if (-not ("NsShellLink" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f, int cch, IntPtr pfd, uint flags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetHotkey(out short k);
    void SetHotkey(short k);
    void GetShowCmd(out int c);
    void SetShowCmd(int c);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int cch, out int i);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string s, int i);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string s, int r);
    void Resolve(IntPtr hwnd, int flags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string s);
}

[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
class CShellLink { }

public static class NsShellLink {
    public static void Save(string lnk, string target, string args, string workDir,
                            string desc, string icon, int iconIndex, int showCmd) {
        IShellLinkW l = (IShellLinkW)new CShellLink();
        l.SetPath(target); l.SetArguments(args); l.SetWorkingDirectory(workDir);
        l.SetDescription(desc); l.SetIconLocation(icon, iconIndex); l.SetShowCmd(showCmd);
        ((IPersistFile)l).Save(lnk, true);
    }
    // Прочитати назад: target | args | workDir | desc | icon,index
    public static string[] Read(string lnk) {
        IShellLinkW l = (IShellLinkW)new CShellLink();
        ((IPersistFile)l).Load(lnk, 0);
        var t = new StringBuilder(1024); var a = new StringBuilder(4096); var w = new StringBuilder(1024);
        var d = new StringBuilder(1024); var i = new StringBuilder(1024); int ii;
        l.GetPath(t, t.Capacity, IntPtr.Zero, 0x4);   // SLGP_RAWPATH
        l.GetArguments(a, a.Capacity); l.GetWorkingDirectory(w, w.Capacity);
        l.GetDescription(d, d.Capacity); l.GetIconLocation(i, i.Capacity, out ii);
        return new string[] { t.ToString(), a.ToString(), w.ToString(), d.ToString(), i.ToString() + "," + ii };
    }
}
'@
}

$staging = Join-Path $env:TEMP ("ns-lnk-" + [guid]::NewGuid().ToString("N") + ".lnk")

$want = @(
    $ps,
    "-NoProfile -ExecutionPolicy Bypass -File `"$script`"",
    $PSScriptRoot,
    "Сканування та каталогізація архіву «Наше слово»",
    # Іконка сканера з системної бібліотеки — щоб ярлик було видно серед інших.
    "$env:WINDIR\System32\imageres.dll,68"
)
[NsShellLink]::Save($staging, $want[0], $want[1], $want[2], $want[3],
                    "$env:WINDIR\System32\imageres.dll", 68, 1)

if (-not (Test-Path -LiteralPath $staging)) {
    Write-Host "Не вдалося створити ярлик." -ForegroundColor Red; exit 1
}

# Не вірити, що записалося як задумано: прочитати назад і звірити кожне поле.
# Саме так і знайшлися знаки питання в описі — ярлик «створювався» без помилок.
$got = [NsShellLink]::Read($staging)
$names = @("програма", "аргументи", "робоча тека", "опис", "іконка")
$bad = @()
for ($i = 0; $i -lt $want.Count; $i++) {
    if ($got[$i] -ne $want[$i]) { $bad += "$($names[$i]): записано «$($got[$i])», мало бути «$($want[$i])»" }
}
if ($bad.Count) {
    Remove-Item -LiteralPath $staging -Force
    Write-Host "Ярлик записався не так:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

if ($AsAdmin) {
    # Прапорець «запускати від імені адміністратора» живе в 21-му байті
    # структури .lnk (біт 0x20). Через WScript.Shell його не виставити.
    $bytes = [IO.File]::ReadAllBytes($staging)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($staging, $bytes)
}

Move-Item -LiteralPath $staging -Destination $lnk -Force

Write-Host "Ярлик створено: $lnk" -ForegroundColor Green
if ($AsAdmin) { Write-Host "  з вимогою прав адміністратора" -ForegroundColor Yellow }
