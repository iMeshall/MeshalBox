<#
.SYNOPSIS
    MeshalBox - a bilingual (English / العربية) bulk software installer built on winget.

.DESCRIPTION
    - Browse apps in a categorized grid with logos (cards).
    - Tick as many apps as you like, then install them all in one go.
    - Switch between English and Arabic at any time (button in the top-right corner).
      The Arabic mode also flips the whole layout to right-to-left.
    - Uses winget under the hood, so every app is installed from its official source.

.PARAMETER Language
    'en', 'ar' or 'auto' (default). 'auto' uses your last choice, then the system language.
    (The dark / light theme is switched with the sun button in the header and is remembered.)

.PARAMETER AppsFile
    Path to the applications catalog (default: applications.json next to the script).

.PARAMETER NoElevate
    Do not try to relaunch as Administrator.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\MeshalBox.ps1
    powershell -ExecutionPolicy Bypass -File .\MeshalBox.ps1 -Language ar

.NOTES
    Requirements: Windows 10/11, Windows PowerShell 5.1 (or PowerShell 7 on Windows),
    winget (App Installer from the Microsoft Store). Internet access is required for
    installs and to fetch the logos (they are cached in %LOCALAPPDATA%\MeshalBox).
    Save this file as UTF-8 WITH BOM so Arabic text displays correctly in Windows PowerShell 5.1.
#>
param(
    [ValidateSet('auto', 'en', 'ar')][string]$Language = 'auto',
    [switch]$NoElevate,
    [string]$AppsFile = ''
)

$ErrorActionPreference = 'Stop'

# These two placeholders are filled in by build.bat when compiling the portable EXE
# (the catalog is embedded and the self-relaunch is skipped; the EXE asks for admin itself).
$IsCompiledExe       = '__IS_EXE__' -eq 'yes'
$EmbeddedCatalogB64  = '__EMBED_CATALOG__'

# ----------------------------------------------------------------------------
# 0. Make sure we run in STA (required by WPF) and with Administrator rights
# ----------------------------------------------------------------------------
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($PSCommandPath -and (-not $IsCompiledExe) -and ((-not $isSta) -or ((-not $isAdmin) -and (-not $NoElevate)))) {
    try {
        $exe     = (Get-Process -Id $PID).Path
        $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -Language $Language"
        if ($AppsFile) { $argList += " -AppsFile `"$AppsFile`"" }
        if ($NoElevate) { $argList += ' -NoElevate' }
        if ($isAdmin)   { Start-Process -FilePath $exe -ArgumentList $argList }
        else            { Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs }
        exit
    }
    catch {
        # UAC was declined (or relaunch failed): continue in the current session.
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ----------------------------------------------------------------------------
# 1. Data classes (INotifyPropertyChanged so the grid updates live)
# ----------------------------------------------------------------------------
if (-not ('MeshalApp' -as [type])) {
    Add-Type -Language CSharp -ReferencedAssemblies System.dll -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public class MeshalApp : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string name)
    {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }

    public string Id { get; set; }
    public string NameEn { get; set; }
    public string NameAr { get; set; }
    public string Category { get; set; }
    public string Domain { get; set; }
    public string Source { get; set; }
    public string Initial { get; set; }
    public string Color { get; set; }
    public string IconKey { get; set; }      // cache key of the logo (website domain, or "icon-<name>")
    public string IconHost { get; set; }     // website to take the logo from
    public string IconSlug { get; set; }     // name in the open app-icon sets
    public bool IconExplicit { get; set; }   // icon name given in applications.json (tried first)
    private string _statusKey;
    public string StatusKey { get { return _statusKey; } set { _statusKey = value; Raise("StatusKey"); } }

    private string _displayName;
    public string DisplayName { get { return _displayName; } set { _displayName = value; Raise("DisplayName"); } }

    private string _status;
    public string Status { get { return _status; } set { _status = value; Raise("Status"); } }

    private bool _isSelected;
    public bool IsSelected { get { return _isSelected; } set { _isSelected = value; Raise("IsSelected"); } }

    private object _icon;
    public object Icon { get { return _icon; } set { _icon = value; Raise("Icon"); Raise("HasIcon"); } }
    public bool HasIcon { get { return _icon != null; } }

    private double _iconSize = 44;
    public double IconSize { get { return _iconSize; } set { _iconSize = value; Raise("IconSize"); } }
}

public class MeshalWebClient : System.Net.WebClient
{
    protected override System.Net.WebRequest GetWebRequest(Uri address)
    {
        System.Net.WebRequest r = base.GetWebRequest(address);
        r.Timeout = 6000;
        return r;
    }
}

public class MeshalCat : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string name)
    {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }

    public string Key { get; set; }
    public string Glyph { get; set; }
    private string _color;
    public string Color { get { return _color; } set { _color = value; Raise("Color"); } }

    private string _name;
    public string Name { get { return _name; } set { _name = value; Raise("Name"); } }

    private int _count;
    public int Count { get { return _count; } set { _count = value; Raise("Count"); } }
}

public static class MeshalDwm
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private static int ToColorRef(int r, int g, int b) { return r | (g << 8) | (b << 16); }

    public static void Apply(IntPtr hwnd, bool dark)
    {
        int useDark = dark ? 1 : 0;
        // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Win10 20H1+/Win11), 19 = older Win10 builds
        if (DwmSetWindowAttribute(hwnd, 20, ref useDark, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref useDark, 4);

        int caption = dark ? ToColorRef(0x12, 0x14, 0x1A) : ToColorRef(0xF3, 0xF5, 0xF9);   // = window background
        int text    = dark ? ToColorRef(0xE6, 0xE9, 0xF0) : ToColorRef(0x1A, 0x1F, 0x2B);   // title text
        int border  = dark ? ToColorRef(0x22, 0x26, 0x2F) : ToColorRef(0xE1, 0xE5, 0xEC);   // = panel borders
        DwmSetWindowAttribute(hwnd, 35, ref caption, 4);  // DWMWA_CAPTION_COLOR (Win11)
        DwmSetWindowAttribute(hwnd, 36, ref text, 4);     // DWMWA_TEXT_COLOR    (Win11)
        DwmSetWindowAttribute(hwnd, 34, ref border, 4);   // DWMWA_BORDER_COLOR  (Win11)
    }
}
'@
}

# ----------------------------------------------------------------------------
# 2. Translations  (add another language by adding another key here)
# ----------------------------------------------------------------------------
$Strings = @{
    en = @{
        title         = 'MeshalBox'
        subtitle      = 'Install many programs in one go'
        search        = 'Search apps...'
        langBtn       = 'العربية'
        themeToLight  = 'Switch to light mode'
        themeToDark   = 'Switch to dark mode'
        selectVisible = 'Select shown'
        clearAll      = 'Clear selection'
        install       = [string][char]0x2B07 + '  Install selected'
        cancel        = 'Stop'
        selected      = 'Selected: {0}'
        ready         = 'Ready'
        noResults     = 'No matching apps.'
        appsCount     = '{0} apps'
        cat_All = 'All apps'; cat_Selected = 'Selected'; cat_Browsers = 'Browsers'; cat_Gaming = 'Gaming'
        cat_Communication = 'Communication'; cat_Media = 'Media'; cat_Development = 'Development'
        cat_Utilities = 'Utilities'; cat_Security = 'Security'; cat_Productivity = 'Productivity'
        cat_Design = 'Design'; cat_Cloud = 'Cloud'; cat_Runtimes = 'Runtimes'
        cat_ProTools = 'Pro Tools'; cat_Microsoft = 'Microsoft'; cat_Selfhosted = 'Self-hosted'; cat_Store = 'Store Apps'
        cat_Peripherals = 'Peripherals'
        st_queued     = [string][char]0x23F3 + ' Queued'
        st_installing = [string][char]0x2B07 + ' Installing...'
        st_done       = [string][char]0x2714 + ' Installed'
        st_already    = [string][char]0x2714 + ' Already installed'
        st_failed     = [string][char]0x2716 + ' Failed'
        st_cancelled  = [string][char]0x23F9 + ' Cancelled'
        st_manual     = [char]::ConvertFromUtf32(0x1F310) + ' Download page opened'
        noSel         = 'Please select at least one app.'
        confirmTitle  = 'Confirm installation'
        confirmMsg    = '{0} app(s) will be installed. Continue?'
        noWinget      = 'winget was not found. Install "App Installer" from the Microsoft Store, then try again.'
        adminWarn     = 'Note: not running as Administrator. You may see extra permission prompts during installs.'
        wingetOk      = 'winget detected: {0}'
        startLog      = 'Starting installation of {0} app(s)...'
        finished      = 'Finished: {0} installed, {1} already installed, {2} failed, {3} cancelled, {4} opened for manual install.'
        manualLog     = 'Not available in winget - official download page opened: {0}'
        cancelling    = 'Stopping after the current app...'
        busyClose     = 'An installation is running. Stop it first, then close the window.'
        installingNow = 'Installing: {0}  ({1}/{2})'
        reboot        = 'A restart may be required.'
        failedCode    = 'Failed (exit code {0})'
        logTitle      = 'Log'
        shortcutLog   = 'Desktop shortcut created: {0}'
        logosLog      = 'Logos loaded: {0} of {1}. Without logo:'
    }
    ar = @{
        title         = 'MeshalBox'
        subtitle      = 'ثبّت عدة برامج دفعة واحدة'
        search        = 'ابحث عن برنامج...'
        langBtn       = 'English'
        themeToLight  = 'التبديل إلى الوضع الفاتح'
        themeToDark   = 'التبديل إلى الوضع الداكن'
        selectVisible = 'تحديد المعروض'
        clearAll      = 'إلغاء التحديد'
        install       = [string][char]0x2B07 + '  تثبيت المحدد'
        cancel        = 'إيقاف'
        selected      = 'المحدد: {0}'
        ready         = 'جاهز'
        noResults     = 'لا توجد برامج مطابقة.'
        appsCount     = '{0} برنامج'
        cat_All = 'كل البرامج'; cat_Selected = 'المحدد'; cat_Browsers = 'المتصفحات'; cat_Gaming = 'الألعاب'
        cat_Communication = 'التواصل'; cat_Media = 'الوسائط'; cat_Development = 'البرمجة'
        cat_Utilities = 'الأدوات'; cat_Security = 'الأمان'; cat_Productivity = 'الإنتاجية'
        cat_Design = 'التصميم'; cat_Cloud = 'السحابة'; cat_Runtimes = 'المكتبات'
        cat_ProTools = 'أدوات احترافية'; cat_Microsoft = 'مايكروسوفت'; cat_Selfhosted = 'استضافة ذاتية'; cat_Store = 'تطبيقات المتجر'
        cat_Peripherals = 'الملحقات'
        st_queued     = [string][char]0x23F3 + ' في الانتظار'
        st_installing = [string][char]0x2B07 + ' جارٍ التثبيت...'
        st_done       = [string][char]0x2714 + ' تم التثبيت'
        st_already    = [string][char]0x2714 + ' مثبّت مسبقًا'
        st_failed     = [string][char]0x2716 + ' فشل'
        st_cancelled  = [string][char]0x23F9 + ' أُلغي'
        st_manual     = [char]::ConvertFromUtf32(0x1F310) + ' فُتحت صفحة التحميل'
        noSel         = 'اختر برنامجًا واحدًا على الأقل.'
        confirmTitle  = 'تأكيد التثبيت'
        confirmMsg    = 'سيتم تثبيت {0} برنامج. هل تريد المتابعة؟'
        noWinget      = 'لم يتم العثور على winget. ثبّت "App Installer" من متجر Microsoft ثم أعد المحاولة.'
        adminWarn     = 'تنبيه: السكربت لا يعمل بصلاحيات المسؤول، وقد تظهر نوافذ طلب صلاحيات إضافية أثناء التثبيت.'
        wingetOk      = 'تم العثور على winget: {0}'
        startLog      = 'بدء تثبيت {0} برنامج...'
        finished      = 'اكتمل: {0} تم تثبيته، {1} مثبّت مسبقًا، {2} فشل، {3} أُلغي، {4} فُتحت صفحة تحميله للتثبيت اليدوي.'
        manualLog     = 'غير متوفر في winget - تم فتح صفحة التحميل الرسمية: {0}'
        cancelling    = 'جارٍ الإيقاف بعد البرنامج الحالي...'
        busyClose     = 'هناك عملية تثبيت جارية. أوقفها أولًا ثم أغلق النافذة.'
        installingNow = 'جارٍ تثبيت: {0}  ({1}/{2})'
        reboot        = 'قد تحتاج إلى إعادة تشغيل الجهاز.'
        failedCode    = 'فشل (رمز الخروج {0})'
        logTitle      = 'السجل'
        shortcutLog   = 'تم إنشاء اختصار على سطح المكتب: {0}'
        logosLog      = 'الشعارات المحمّلة: {0} من {1}. بدون شعار:'
    }
}

# ----------------------------------------------------------------------------
# 3. Application catalog  (loaded from applications.json)
#    Add your own apps by adding an entry to applications.json:
#    { "id": "Publisher.App", "en": "Name", "ar": "الاسم", "category": "Utilities", "domain": "site.com" }
#    (add  "source": "msstore"  for Store apps).  Find ids with:  winget search <name>
# ----------------------------------------------------------------------------
$CategoryOrder = @('All', 'Selected', 'Browsers', 'Gaming', 'Peripherals', 'Communication', 'Media', 'Development',
                   'Utilities', 'Security', 'Productivity', 'Design', 'Cloud', 'Runtimes',
                   'ProTools', 'Microsoft', 'Selfhosted', 'Store')
$CategoryGlyph = @{
    All = [char]::ConvertFromUtf32(0x1F5C2); Selected = [string][char]0x2705
    Browsers = [char]::ConvertFromUtf32(0x1F310); Gaming = [char]::ConvertFromUtf32(0x1F3AE)
    Peripherals = [char]::ConvertFromUtf32(0x1F5B1)
    Communication = [char]::ConvertFromUtf32(0x1F4AC); Media = [char]::ConvertFromUtf32(0x1F3AC)
    Development = [char]::ConvertFromUtf32(0x1F4BB); Utilities = [char]::ConvertFromUtf32(0x1F6E0)
    Security = [char]::ConvertFromUtf32(0x1F6E1); Productivity = [char]::ConvertFromUtf32(0x1F4C4)
    Design = [char]::ConvertFromUtf32(0x1F3A8); Cloud = [string][char]0x2601
    Runtimes = [string][char]0x2699
    ProTools = [char]::ConvertFromUtf32(0x1F9F0); Microsoft = [char]::ConvertFromUtf32(0x1F537)
    Selfhosted = [char]::ConvertFromUtf32(0x1F5A5); Store = [char]::ConvertFromUtf32(0x1F6D2)
}

# Bright colours so the (monochrome) emoji glyphs are clearly visible on the dark background
$CategoryColor = @{
    All = '#E5E7EB'; Selected = '#4ADE80'; Browsers = '#60A5FA'; Gaming = '#C084FC'; Peripherals = '#F9A8D4'
    Communication = '#34D399'; Media = '#F472B6'; Development = '#38BDF8'; Utilities = '#FBBF24'
    Security = '#F87171'; Productivity = '#A3E635'; Design = '#FB923C'; Cloud = '#7DD3FC'
    Runtimes = '#CBD5E1'
    ProTools = '#FCA5A5'; Microsoft = '#93C5FD'; Selfhosted = '#86EFAC'; Store = '#FDE68A'
}

# Darker versions of the same colours so the icons stay readable on the light background
$CategoryColorLight = @{
    All = '#6B7280'; Selected = '#16A34A'; Browsers = '#2563EB'; Gaming = '#9333EA'; Peripherals = '#DB2777'
    Communication = '#059669'; Media = '#BE185D'; Development = '#0284C7'; Utilities = '#D97706'
    Security = '#DC2626'; Productivity = '#65A30D'; Design = '#EA580C'; Cloud = '#0891B2'
    Runtimes = '#64748B'
    ProTools = '#E11D48'; Microsoft = '#1D4ED8'; Selfhosted = '#15803D'; Store = '#CA8A04'
}

$script:Apps = New-Object System.Collections.Generic.List[MeshalApp]
$script:ById = @{}
$palette = @('#3B82F6', '#8B5CF6', '#EC4899', '#F59E0B', '#10B981', '#06B6D4', '#EF4444', '#6366F1', '#14B8A6', '#F97316')

# Catalog source: embedded copy (portable EXE) or applications.json next to the script (or -AppsFile).
$catalog = $null
if ($EmbeddedCatalogB64.Length -gt 100) {
    try { $catalog = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EmbeddedCatalogB64)) | ConvertFrom-Json } catch { $catalog = $null }
}
if (-not $catalog) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    if (-not $AppsFile) { $AppsFile = Join-Path $scriptDir 'applications.json' }
    if (-not (Test-Path -LiteralPath $AppsFile)) {
        [void][System.Windows.MessageBox]::Show("applications.json was not found next to the script:`n$AppsFile`n`nلم يتم العثور على ملف applications.json بجانب البرنامج.", 'MeshalBox', 'OK', 'Error')
        exit 1
    }
    try {
        $catalog = Get-Content -LiteralPath $AppsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        [void][System.Windows.MessageBox]::Show("Could not read applications.json:`n$($_.Exception.Message)", 'MeshalBox', 'OK', 'Error')
        exit 1
    }
}

$StoreGlyph = @{
    '9WZDNCRFHVN5' = 0x1F9EE; '9WZDNCRFJBBG' = 0x1F4F7; '9WZDNCRFJ3PR' = 0x23F0;  '9N8MHTPHNGVV' = 0x1F6E0; '9NBLGGH4R32N' = 0x1F4AC
    '9PKDZBMV1H3T' = 0x2753;  '9WZDNCRFJ3PT' = 0x1F3B5; '9NTXGKQ8P7N0' = 0x1F4F1; '9WZDNCRFJ3P2' = 0x1F3AC; '9MSMLRH6LZF3' = 0x1F4DD
    '9PCFS5B6T72H' = 0x1F3A8; '9NMPJ99VJBWV' = 0x1F4F2; '9WZDNCRFJBH4' = 0x1F5BC; '9P7BP5VNWKX5' = 0x1F91D; '9MZ95KL8MR0L' = 0x2702
    '9WZDNCRFHWD2' = 0x1F0CF; '9WZDNCRFHWKN' = 0x1F399; '9PC1H9VN18CM' = 0x1F680; '9NBLGGH4QGHW' = 0x1F5D2
}
$domCount = @{}
foreach ($e in $catalog.apps) { if ($e.domain) { $domCount[[string]$e.domain]++ } }
function Get-IconSlug([string]$Name) {
    return (($Name.ToLowerInvariant() -replace '\+', 'plus' -replace '[^a-z0-9]+', '-').Trim('-'))
}
foreach ($e in $catalog.apps) {
    if (-not $e.id -or -not $e.en) { continue }
    if ($script:ById.ContainsKey([string]$e.id)) { continue }   # never list the same program twice
    $a = New-Object MeshalApp
    $a.Id = [string]$e.id; $a.NameEn = [string]$e.en
    $a.NameAr = if ($e.ar) { [string]$e.ar } else { [string]$e.en }
    $a.Category = [string]$e.category; $a.Domain = [string]$e.domain
    $a.Source = if ($e.source) { [string]$e.source } else { '' }
    $a.Initial = $a.NameEn.Substring(0, 1).ToUpper()
    if ((-not $a.Domain) -and $StoreGlyph.ContainsKey($a.Id)) { $a.Initial = [char]::ConvertFromUtf32([int]$StoreGlyph[$a.Id]) }
    $sum = 0; foreach ($ch in $a.Id.ToCharArray()) { $sum += [int]$ch }
    $a.Color = $palette[$sum % $palette.Count]
    # Logo source: icon name from the catalog, else the app's website, else (no website) a guess from the app name
    $a.IconHost = $a.Domain
    if ($e.icon) { $a.IconSlug = [string]$e.icon; $a.IconExplicit = $true; $a.IconKey = 'icon-' + $a.IconSlug }
    else {
        if ($a.Source -ne 'msstore') { if ((-not $a.Domain) -or ($domCount[$a.Domain] -eq 1)) { $a.IconSlug = Get-IconSlug $a.NameEn } }
        if ($a.Domain) { $a.IconKey = $a.Domain }
        elseif ($a.IconSlug) { $a.IconKey = 'icon-' + $a.IconSlug }
    }
    $script:Apps.Add($a)
    $script:ById[$a.Id] = $a
}


# ----------------------------------------------------------------------------
# 4. Settings, paths, language
# ----------------------------------------------------------------------------
$SettingsDir  = Join-Path $env:APPDATA 'MeshalBox'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$IconCache    = Join-Path $env:LOCALAPPDATA 'MeshalBox\icons_v2'
# One-time migration from the old name (PSPackageManager) so logos/settings are kept
try {
    $oldLocal = Join-Path $env:LOCALAPPDATA 'PSPackageManager'
    $oldRoam  = Join-Path $env:APPDATA 'PSPackageManager'
    $newLocal = Join-Path $env:LOCALAPPDATA 'MeshalBox'
    $newRoam  = Join-Path $env:APPDATA 'MeshalBox'
    if ((Test-Path $oldLocal) -and -not (Test-Path $newLocal)) { Move-Item $oldLocal $newLocal -Force }
    if ((Test-Path $oldRoam)  -and -not (Test-Path $newRoam))  { Move-Item $oldRoam  $newRoam  -Force }
} catch { }
try { Remove-Item (Join-Path $env:LOCALAPPDATA 'MeshalBox\icons') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
foreach ($d in @($SettingsDir, $IconCache)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
# Logo logic v4: forget the old "no logo found" marks once, so the improved downloader retries those apps
try {
    $iconMarker = Join-Path $IconCache '.logic_v4'
    if (-not (Test-Path $iconMarker)) {
        Get-ChildItem -Path $IconCache -Filter '*.miss' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Set-Content -Path $iconMarker -Value ''
    }
} catch { }

function Save-Settings {
    try { @{ lang = $script:Lang; theme = $script:Theme } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
}

$script:Lang = 'en'
if ($Language -ne 'auto') {
    $script:Lang = $Language
}
else {
    $saved = $null
    try { if (Test-Path $SettingsFile) { $saved = (Get-Content $SettingsFile -Raw | ConvertFrom-Json).lang } } catch { }
    if ($saved -in @('en', 'ar')) { $script:Lang = $saved }
    elseif ((Get-UICulture).TwoLetterISOLanguageName -eq 'ar') { $script:Lang = 'ar' }
}
$script:T = $Strings[$script:Lang]

# Theme: 'dark' (default) or 'light' - remembered between runs
$script:Theme = 'dark'
try {
    if (Test-Path $SettingsFile) {
        $savedTheme = (Get-Content $SettingsFile -Raw | ConvertFrom-Json).theme
        if ($savedTheme -in @('dark', 'light')) { $script:Theme = $savedTheme }
    }
} catch { }

# ----------------------------------------------------------------------------
# 5. XAML user interface
# ----------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1240" Height="820" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource BgWindow}"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>

    <LinearGradientBrush x:Key="AccentBrush" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#3B82F6" Offset="0"/>
      <GradientStop Color="#7C5CFF" Offset="1"/>
    </LinearGradientBrush>

    <!-- Slim dark scrollbar -->
    <Style x:Key="ScrollPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" CornerRadius="4" Background="{DynamicResource ThumbBg}" Margin="2,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="{DynamicResource ThumbHover}"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#3B82F6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ScrollPage}"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ScrollPage}"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Rounded button -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}"
                    BorderBrush="{DynamicResource BtnBorder}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,11"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect Color="#5B6CFF" Opacity="0.45" BlurRadius="20" ShadowDepth="0"/></Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Effect" Value="{x:Null}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#DC2626"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>

    <!-- Search box -->
    <Style x:Key="SearchBox" TargetType="TextBox">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="40,10,38,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1.5" CornerRadius="12" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource InputBorderHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3B82F6"/><Setter TargetName="bd" Property="Background" Value="{DynamicResource InputBgFocus}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextSec}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Width="24" Height="24" CornerRadius="12" Background="Transparent">
              <TextBlock Text="&#x2715;" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Edge}"/><Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Category list item -->
    <Style x:Key="MeshalCat" TargetType="ListBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid Margin="0,1">
              <Border x:Name="bd" CornerRadius="10" Padding="14,8,12,8" Background="Transparent">
                <ContentPresenter/>
              </Border>
              <Border x:Name="bar" Width="3" Height="20" CornerRadius="2" Background="{StaticResource AccentBrush}"
                      HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource CatHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource CatSelected}"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- App card (a CheckBox dressed as a card: click anywhere to select) -->
    <Style x:Key="Card" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="card" Background="{DynamicResource CardBg}" Width="156" Height="170" Margin="7" CornerRadius="16"
                    BorderBrush="{DynamicResource Edge}" BorderThickness="1.5" Padding="8"
                    RenderTransformOrigin="0.5,0.5" ToolTip="{Binding Id}">
              <Border.RenderTransform><ScaleTransform x:Name="zoom" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <Grid>
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                  <Grid Width="60" Height="60" HorizontalAlignment="Center" Margin="0,6,0,9">
                    <Border CornerRadius="16" Background="{Binding Color}">
                      <Border.Style>
                        <Style TargetType="Border">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding HasIcon}" Value="True"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Border.Style>
                      <TextBlock Text="{Binding Initial}" Foreground="White" FontSize="27" FontWeight="Bold"
                                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <Border CornerRadius="16" Background="{DynamicResource LogoBg}" Padding="7">
                      <Border.Style>
                        <Style TargetType="Border">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding HasIcon}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Border.Style>
                      <Image Source="{Binding Icon}" Width="{Binding IconSize}" Height="{Binding IconSize}" Stretch="Uniform"
                             HorizontalAlignment="Center" VerticalAlignment="Center"
                             RenderOptions.BitmapScalingMode="HighQuality"/>
                    </Border>
                  </Grid>
                  <TextBlock Text="{Binding DisplayName}" Foreground="{DynamicResource TextPrimary}" FontSize="14" FontWeight="SemiBold"
                             TextAlignment="Center" TextWrapping="Wrap" MaxHeight="40" TextTrimming="CharacterEllipsis"/>
                  <Border CornerRadius="9" Padding="9,2" Margin="0,5,0,0" HorizontalAlignment="Center" MaxWidth="136">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Setter Property="Background" Value="Transparent"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_queued"><Setter Property="Background" Value="{DynamicResource Edge}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_installing"><Setter Property="Background" Value="{DynamicResource StInfoBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_manual"><Setter Property="Background" Value="{DynamicResource StInfoBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_done"><Setter Property="Background" Value="{DynamicResource StOkBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_already"><Setter Property="Background" Value="{DynamicResource StOkBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_failed"><Setter Property="Background" Value="{DynamicResource StErrBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_cancelled"><Setter Property="Background" Value="{DynamicResource StWarnBg}"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Border.Style>
                    <TextBlock Text="{Binding Status}" FontSize="12" TextAlignment="Center" TextTrimming="CharacterEllipsis">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Foreground" Value="{DynamicResource TextSec2}"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_installing"><Setter Property="Foreground" Value="{DynamicResource StInfoFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_manual"><Setter Property="Foreground" Value="{DynamicResource StInfoFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_done"><Setter Property="Foreground" Value="{DynamicResource StOkFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_already"><Setter Property="Foreground" Value="{DynamicResource StOkFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_failed"><Setter Property="Foreground" Value="{DynamicResource StErrFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_cancelled"><Setter Property="Foreground" Value="{DynamicResource StWarnFg}"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                  </Border>
                </StackPanel>
                <Border x:Name="tick" Width="22" Height="22" CornerRadius="11" Background="#00000000"
                        BorderBrush="{DynamicResource TickBorder}" BorderThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Top">
                  <TextBlock x:Name="mark" Text="&#x2713;" Foreground="White" FontSize="13" FontWeight="Bold"
                             HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="card" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/>
                <Setter TargetName="tick" Property="BorderBrush" Value="{DynamicResource TickHover}"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="zoom" Storyboard.TargetProperty="ScaleX" To="1.04" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="zoom" Storyboard.TargetProperty="ScaleY" To="1.04" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="zoom" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="zoom" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="card" Property="Background" Value="{DynamicResource CardChecked}"/>
                <Setter TargetName="card" Property="BorderBrush" Value="#3B82F6"/>
                <Setter TargetName="tick" Property="Background" Value="#3B82F6"/>
                <Setter TargetName="tick" Property="BorderBrush" Value="#3B82F6"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Rounded progress bar -->
    <Style x:Key="Prog" TargetType="ProgressBar">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="4" Background="{DynamicResource Edge}"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" HorizontalAlignment="Left" Background="{StaticResource AccentBrush}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Grid Grid.Row="0">
      <Border Padding="24,16" Background="{DynamicResource HeaderBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <Image x:Name="imgLogo" Width="48" Height="48" Margin="0,0,14,0" RenderOptions.BitmapScalingMode="HighQuality"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="txtTitle" FontSize="23" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
              <TextBlock x:Name="txtSubtitle" FontSize="12" Foreground="{DynamicResource TextSec}"/>
            </StackPanel>
          </StackPanel>
          <Grid Grid.Column="1" Margin="34,0" VerticalAlignment="Center" MaxWidth="560">
            <TextBox x:Name="txtSearch" Style="{StaticResource SearchBox}"/>
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource TextMuted}"
                       IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="15,0,0,0"/>
            <TextBlock x:Name="txtPlaceholder" IsHitTestVisible="False" Foreground="{DynamicResource TextMuted}" FontSize="14"
                       VerticalAlignment="Center" Margin="42,0,16,0"/>
            <Button x:Name="btnClearSearch" Style="{StaticResource IconBtn}" HorizontalAlignment="Right"
                    VerticalAlignment="Center" Margin="0,0,9,0" Visibility="Collapsed"/>
          </Grid>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnTheme" Style="{StaticResource Btn}" FontFamily="Segoe MDL2 Assets" FontSize="17"
                    Padding="0,9" MinWidth="46" Foreground="{DynamicResource ThemeIcon}"/>
            <Button x:Name="btnLang" Style="{StaticResource Btn}" FontWeight="SemiBold" MinWidth="110"/>
          </StackPanel>
        </Grid>
      </Border>
      <Rectangle Height="2" VerticalAlignment="Bottom" Fill="{StaticResource AccentBrush}" Opacity="0.85"/>
    </Grid>

    <!-- Body -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="262"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{DynamicResource BgPanel}" Padding="10,14" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,1,0">
        <ListBox x:Name="lstCats" Background="Transparent" BorderThickness="0"
                 ItemContainerStyle="{StaticResource MeshalCat}" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
          <ListBox.ItemTemplate>
            <DataTemplate>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="34"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="{Binding Glyph}" Foreground="{Binding Color}" FontSize="18" FontFamily="Segoe UI Emoji, Segoe UI Symbol" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="{Binding Name}" Foreground="{DynamicResource TextPrimary}" FontSize="14" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <Border Grid.Column="2" CornerRadius="9" Background="{DynamicResource BadgeBg}" Padding="8,1" VerticalAlignment="Center" MinWidth="26">
                  <TextBlock Text="{Binding Count}" Foreground="{DynamicResource TextSoft}" FontSize="11" TextAlignment="Center"/>
                </Border>
              </Grid>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>
      </Border>

      <Grid Grid.Column="1" Margin="18,16,6,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="6,0,12,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="txtCatTitle" FontSize="21" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
            <Border CornerRadius="10" Background="{DynamicResource BadgeBg2}" Padding="10,2" Margin="12,2,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="txtCatCount" Foreground="{DynamicResource TextSec2}" FontSize="12"/>
            </Border>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnSelectVisible" Style="{StaticResource Btn}" Margin="0,0,6,0"/>
            <Button x:Name="btnClear" Style="{StaticResource Btn}" Margin="0"/>
          </StackPanel>
        </Grid>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <ItemsControl x:Name="icApps">
            <ItemsControl.ItemsPanel>
              <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
            </ItemsControl.ItemsPanel>
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <CheckBox Style="{StaticResource Card}" IsChecked="{Binding IsSelected, Mode=TwoWay}"/>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </ScrollViewer>
        <TextBlock x:Name="txtEmpty" Grid.Row="1" Foreground="{DynamicResource TextMuted}" FontSize="16" TextAlignment="Center"
                   HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
    </Grid>

    <!-- Footer -->
    <Border Grid.Row="2" Background="{DynamicResource BgPanel}" Padding="22,14" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,24,0">
            <TextBlock x:Name="txtSelected" Foreground="{DynamicResource TextPrimary}" FontSize="14" FontWeight="SemiBold"/>
            <Grid Margin="0,7,0,5">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ProgressBar x:Name="pbar" Style="{StaticResource Prog}" Height="8" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtPercent" Grid.Column="1" Margin="10,0,0,0" Foreground="{DynamicResource TextSoft}" FontSize="12" FontWeight="SemiBold"
                         FlowDirection="LeftToRight" VerticalAlignment="Center" MinWidth="36" TextAlignment="Right"/>
            </Grid>
            <TextBlock x:Name="txtProgress" Foreground="{DynamicResource TextSec2}" FontSize="12" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnLog" Style="{StaticResource Btn}"/>
            <Button x:Name="btnCancel" Style="{StaticResource BtnDanger}" Visibility="Collapsed"/>
            <Button x:Name="btnInstall" Style="{StaticResource BtnPrimary}" FontSize="15"/>
          </StackPanel>
        </Grid>
        <TextBox x:Name="txtLog" Grid.Row="1" Height="110" Margin="0,12,0,0" IsReadOnly="True" Visibility="Collapsed" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" FlowDirection="LeftToRight"
                 Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogFg}" BorderBrush="{DynamicResource Line}" Padding="10"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'imgLogo', 'txtTitle', 'txtSubtitle', 'txtSearch', 'txtPlaceholder', 'btnLang', 'lstCats', 'btnSelectVisible',
                'btnClear', 'txtCatTitle', 'txtCatCount', 'icApps', 'txtEmpty', 'txtSelected', 'pbar', 'txtProgress', 'btnCancel', 'btnInstall', 'txtLog', 'btnLog', 'txtPercent', 'btnClearSearch', 'btnTheme') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# ----------------------------------------------------------------------------
# 6. Helper functions
# ----------------------------------------------------------------------------
# App logo (embedded PNG) used in the header and as the window icon.
$LogoBase64 = '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'
try {
    $logoBytes = [Convert]::FromBase64String($LogoBase64)
    $logoStream = New-Object System.IO.MemoryStream(, $logoBytes)
    $logoBmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $logoBmp.BeginInit(); $logoBmp.CacheOption = 'OnLoad'; $logoBmp.StreamSource = $logoStream; $logoBmp.EndInit(); $logoBmp.Freeze()
    $script:imgLogo.Source = $logoBmp
    $window.Icon = $logoBmp
}
catch { }

# Themed title bar (dark or light, follows the theme button instead of the default Windows title bar).
# Works on Windows 10 (dark mode) and Windows 11 (custom caption / text / border colours).
try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $script:Hwnd = $helper.EnsureHandle()    # the title bar colours are applied by Set-Theme
}
catch { }

$script:Cat     = 'All'
$script:Busy    = $false
$script:Sync    = $null
$script:CatMap  = @{}

# ----------------------------------------------------------------------------
# Themes  (dark = the original look, light = new).  Every colour used by the XAML is a
# {DynamicResource Key}; Set-Theme just swaps the brushes, so the whole UI updates live.
# A value that is an array of two colours becomes a gradient.
# ----------------------------------------------------------------------------
$Themes = @{
    dark = @{
        BgWindow = '#12141A'; BgPanel = '#161922'; Line = '#22262F'
        HeaderBg = @('#1B1F2B', '#161922'); CardBg = @('#232736', '#1B1E29')
        TextPrimary = '#FFFFFF'; TextSec = '#8B93A3'; TextSec2 = '#9AA3B2'; TextMuted = '#6B7280'; TextSoft = '#C5CBD6'; LogFg = '#B8C0CC'
        BtnBg = '#272B38'; BtnBorder = '#33384A'; HoverBorder = '#4B6FB5'
        InputBg = '#1B1E28'; InputBgFocus = '#1F2330'; InputBorderHover = '#3A4056'; Edge = '#2A2E3B'
        CatHover = '#1E222D'; CatSelected = '#222B44'; CardChecked = '#1F2B47'; LogoBg = '#F4F6FA'
        TickBorder = '#4B5263'; TickHover = '#8AA4D6'; BadgeBg = '#262A38'; BadgeBg2 = '#222633'
        ThumbBg = '#3A4052'; ThumbHover = '#566079'; LogBg = '#0E1014'
        StInfoBg = '#1E3560'; StOkBg = '#17382A'; StErrBg = '#43201F'; StWarnBg = '#3A3220'
        StInfoFg = '#8DB8FF'; StOkFg = '#4ADE80'; StErrFg = '#F87171'; StWarnFg = '#FBBF24'
        ThemeIcon = '#FBBF24'
    }
    light = @{
        BgWindow = '#F3F5F9'; BgPanel = '#FFFFFF'; Line = '#E1E5EC'
        HeaderBg = @('#FFFFFF', '#F6F8FC'); CardBg = @('#FFFFFF', '#F6F8FC')
        TextPrimary = '#1A1F2B'; TextSec = '#5B6472'; TextSec2 = '#5B6472'; TextMuted = '#8A93A3'; TextSoft = '#4A5262'; LogFg = '#2B3342'
        BtnBg = '#FFFFFF'; BtnBorder = '#D3D9E3'; HoverBorder = '#5B86D6'
        InputBg = '#FFFFFF'; InputBgFocus = '#FFFFFF'; InputBorderHover = '#B5BDCC'; Edge = '#DCE1EA'
        CatHover = '#EEF1F6'; CatSelected = '#E3EBFB'; CardChecked = '#E3EDFF'; LogoBg = '#EEF1F6'
        TickBorder = '#B5BDCC'; TickHover = '#5B86D6'; BadgeBg = '#E8ECF3'; BadgeBg2 = '#E8ECF3'
        ThumbBg = '#C3CAD6'; ThumbHover = '#A3ADBD'; LogBg = '#FFFFFF'
        StInfoBg = '#DCE8FF'; StOkBg = '#D9F5E4'; StErrBg = '#FDE0E0'; StWarnBg = '#FBEFCF'
        StInfoFg = '#1D5FD6'; StOkFg = '#15803D'; StErrFg = '#C62828'; StWarnFg = '#A16207'
        ThemeIcon = '#4F46E5'
    }
}
$GradientDir = @{ HeaderBg = @(0, 0, 1, 0); CardBg = @(0, 0, 0, 1) }

function New-ThemeBrush {
    param([string]$Key, $Value)
    if ($Value -is [array]) {
        $d = $GradientDir[$Key]
        $g = New-Object System.Windows.Media.LinearGradientBrush
        $g.StartPoint = New-Object System.Windows.Point($d[0], $d[1])
        $g.EndPoint   = New-Object System.Windows.Point($d[2], $d[3])
        $c1 = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Value[0])
        $c2 = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Value[1])
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c1, 0.0)))
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c2, 1.0)))
        $g.Freeze()
        return $g
    }
    $c = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString([string]$Value)
    $b = New-Object System.Windows.Media.SolidColorBrush($c)
    $b.Freeze()
    return $b
}

function Update-ThemeButton {
    # dark mode shows a sun (click = go light), light mode shows a moon (click = go dark)
    if ($script:Theme -eq 'dark') { $script:btnTheme.Content = [string][char]0xE706; $script:btnTheme.ToolTip = $script:T.themeToLight }
    else                          { $script:btnTheme.Content = [string][char]0xE708; $script:btnTheme.ToolTip = $script:T.themeToDark }
}

function Set-Theme {
    param([ValidateSet('dark', 'light')][string]$Name)
    $script:Theme = $Name
    $pal = $Themes[$Name]
    foreach ($k in @($pal.Keys)) {
        # explicit [Brush] cast: unwraps the PowerShell PSObject wrapper (WPF rejects a wrapped value for Foreground/Background)
        [System.Windows.Media.Brush]$brush = New-ThemeBrush $k $pal[$k]
        $window.Resources[$k] = $brush
    }

    # category icon colours (plain strings bound in the list, so they are set per theme)
    if ($Name -eq 'dark') { $cc = $CategoryColor } else { $cc = $CategoryColorLight }
    foreach ($key in $CategoryOrder) { if ($script:CatMap.ContainsKey($key)) { $script:CatMap[$key].Color = $cc[$key] } }

    try { if ($script:Hwnd) { [MeshalDwm]::Apply($script:Hwnd, ($Name -eq 'dark')) } } catch { }
    Update-ThemeButton
}

function Show-Msg {
    param([string]$Text, [string]$Caption = $script:T.title, [string]$Buttons = 'OK', [string]$Icon = 'Information')
    $opt = [System.Windows.MessageBoxOptions]::None
    if ($script:Lang -eq 'ar') { $opt = [System.Windows.MessageBoxOptions]'RtlReading,RightAlign' }
    [System.Windows.MessageBox]::Show($window, $Text, $Caption, $Buttons, $Icon, 'None', $opt)
}

function Write-Log {
    param([string]$Text, [switch]$Plain)
    if ($Plain) { $line = $Text } else { $line = ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text) }
    $script:txtLog.AppendText($line + "`r`n")
    $script:txtLog.ScrollToEnd()
}

function Set-Status {
    param([MeshalApp]$Item, [string]$Key)
    $Item.StatusKey = $Key
    if ($Key) { $Item.Status = $script:T[$Key] } else { $Item.Status = '' }
}

function Test-Match {
    param([MeshalApp]$A, [string]$Q)
    if ([string]::IsNullOrWhiteSpace($Q)) { return $true }
    $ic = [StringComparison]::OrdinalIgnoreCase
    return ($A.NameEn.IndexOf($Q, $ic) -ge 0) -or ($A.NameAr.IndexOf($Q, $ic) -ge 0) -or ($A.Id.IndexOf($Q, $ic) -ge 0)
}

function Add-GridBatch {
    param([int]$Count)
    $end = [math]::Min($script:GridPos + $Count, $script:CurrentList.Count)
    while ($script:GridPos -lt $end) { $script:GridItems.Add($script:CurrentList[$script:GridPos]); $script:GridPos++ }
}

function Refresh-Grid {
    $q = $script:txtSearch.Text.Trim()
    $cat = $script:Cat
    $hasQ = -not [string]::IsNullOrWhiteSpace($q)
    $ic = [StringComparison]::OrdinalIgnoreCase
    $list = New-Object 'System.Collections.Generic.List[MeshalApp]'
    foreach ($a in $script:Apps) {
        if ($cat -eq 'Selected') { if (-not $a.IsSelected) { continue } }
        elseif ($cat -ne 'All' -and $a.Category -ne $cat) { continue }
        if ($hasQ -and -not (($a.NameEn.IndexOf($q, $ic) -ge 0) -or ($a.NameAr.IndexOf($q, $ic) -ge 0) -or ($a.Id.IndexOf($q, $ic) -ge 0))) { continue }
        $list.Add($a)
    }
    $script:CurrentList = $list
    $script:GridTimer.Stop()
    $script:GridItems.Clear()
    $script:GridPos = 0
    Add-GridBatch 36                                   # first screen appears immediately
    if ($script:GridPos -lt $list.Count) { $script:GridTimer.Start() }   # the rest streams in without freezing the UI
    $script:txtCatTitle.Text = [string]$script:T["cat_$($script:Cat)"]
    $script:txtCatCount.Text = ($script:T.appsCount -f $list.Count)
    if ($list.Count -eq 0) { $script:txtEmpty.Visibility = 'Visible' } else { $script:txtEmpty.Visibility = 'Collapsed' }
}

function Update-Selection {
    $n = @($script:Apps | Where-Object { $_.IsSelected }).Count
    $script:txtSelected.Text = ($script:T.selected -f $n)
    $script:CatMap['Selected'].Count = $n
    $script:btnInstall.IsEnabled = ($n -gt 0) -and (-not $script:Busy)
    if ($n -gt 0) { $script:btnInstall.Content = ('{0} ({1})' -f $script:T.install, $n) } else { $script:btnInstall.Content = $script:T.install }
}

function Initialize-Categories {
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[MeshalCat]
    foreach ($key in $CategoryOrder) {
        $c = New-Object MeshalCat
        $c.Key = $key
        $c.Glyph = [string]$CategoryGlyph[$key]
        $c.Color = $CategoryColor[$key]
        if ($key -eq 'All') { $c.Count = $script:Apps.Count }
        elseif ($key -eq 'Selected') { $c.Count = 0 }
        else { $c.Count = @($script:Apps | Where-Object { $_.Category -eq $key }).Count }
        $script:CatMap[$key] = $c
        $items.Add($c)
    }
    $script:lstCats.ItemsSource = $items
}

function Set-LogVisible {
    param([bool]$Show)
    if ($Show) { $script:txtLog.Visibility = 'Visible'; $arrow = [string][char]0x25B2 }
    else       { $script:txtLog.Visibility = 'Collapsed'; $arrow = [string][char]0x25BC }
    $script:btnLog.Content = ($script:T.logTitle + ' ' + $arrow)
}

function Apply-Language {
    $script:T = $Strings[$script:Lang]
    $t = $script:T
    if ($script:Lang -eq 'ar') { $window.FlowDirection = 'RightToLeft' } else { $window.FlowDirection = 'LeftToRight' }
    $window.Title             = $t.title
    $script:txtTitle.Text     = $t.title
    $script:txtSubtitle.Text  = $t.subtitle
    $script:txtPlaceholder.Text = $t.search
    $script:btnLang.Content   = $t.langBtn
    Update-ThemeButton
    $script:btnSelectVisible.Content = $t.selectVisible
    $script:btnClear.Content  = $t.clearAll
    $script:btnInstall.Content = $t.install
    $script:btnCancel.Content = $t.cancel
    $script:txtEmpty.Text     = [char]::ConvertFromUtf32(0x1F50D) + "`n" + $t.noResults
    $script:btnClearSearch.ToolTip = $t.clearAll
    Set-LogVisible ($script:txtLog.Visibility -eq 'Visible')
    if (-not $script:Busy) { $script:txtProgress.Text = $t.ready }

    foreach ($a in $script:Apps) {
        if ($script:Lang -eq 'ar') { $a.DisplayName = $a.NameAr } else { $a.DisplayName = $a.NameEn }
        if ($a.StatusKey) { $a.Status = $t[$a.StatusKey] }
    }
    foreach ($key in $CategoryOrder) { $script:CatMap[$key].Name = $t["cat_$key"] }

    Update-Selection
    Save-Settings
}

function Load-Icon {
    param([string]$Path)
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = 'OnLoad'
    $bi.CreateOptions = 'IgnoreColorProfile'
    $bi.UriSource = New-Object System.Uri($Path)
    $bi.EndInit()
    $bi.Freeze()
    return $bi
}

function Get-IconName { param([string]$Domain) ($Domain -replace '[^a-zA-Z0-9\.\-]', '_') + '.png' }
function Get-IconPath { param([string]$Domain) Join-Path $IconCache (Get-IconName $Domain) }

$script:IconTodo = $null
function Load-CachedIcons {
    # Only apps that still have no logo are checked on every call (not all 300+).
    if ($null -eq $script:IconTodo) {
        $script:IconTodo = New-Object 'System.Collections.Generic.List[MeshalApp]'
        foreach ($a in $script:Apps) { if ($a.IconKey -and -not $a.HasIcon) { $script:IconTodo.Add($a) } }
    }
    if ($script:IconTodo.Count -eq 0) { return 0 }
    $files = @{}
    try { foreach ($f in [System.IO.Directory]::GetFiles($IconCache, '*.png')) { $files[[System.IO.Path]::GetFileName($f)] = $f } } catch { }
    for ($i = $script:IconTodo.Count - 1; $i -ge 0; $i--) {
        $a = $script:IconTodo[$i]
        $p = $files[(Get-IconName $a.IconKey)]
        if ($p) {
            try {
                $bmp = Load-Icon $p
                $a.IconSize = [math]::Min(44, [math]::Max(26, $bmp.PixelWidth * 1.5))
                $a.Icon = $bmp
                $script:IconTodo.RemoveAt($i)
            }
            catch { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
    }
    return $script:IconTodo.Count
}

# ----------------------------------------------------------------------------
# 7. Logo downloader (background runspace + UI timer that picks up finished files)
# ----------------------------------------------------------------------------
$script:IconTicks = 0
$script:IconKnown = @{}      # domains already loaded or confirmed missing (skip re-checking every tick)
function Start-IconDownloads {
    # One job per logo key (website domain or icon name). Keys that failed recently are skipped (negative cache, 7 days).
    $todo = @{}
    foreach ($a in $script:Apps) {
        if ($a.HasIcon -or -not $a.IconKey) { continue }
        if ($todo.ContainsKey($a.IconKey)) { continue }
        $miss = (Get-IconPath $a.IconKey) + '.miss'
        if ((Test-Path $miss) -and ((Get-Item $miss).LastWriteTime -gt (Get-Date).AddDays(-7))) { continue }
        $todo[$a.IconKey] = @{ Host = $a.IconHost; Slug = $a.IconSlug; Explicit = [bool]$a.IconExplicit }
    }
    if ($todo.Count -eq 0) { return }

    $dlScript = {
        param($key, $hostName, $slug, $explicit, $dir)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13' }
        catch { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { } }
        try { [Net.ServicePointManager]::DefaultConnectionLimit = 64 } catch { }
        Add-Type -AssemblyName System.Drawing

        # MeshalWebClient (6 s timeout) is defined once in section 1 and shared by all workers.
        $wc = New-Object MeshalWebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
        $wc.Headers.Add('Accept', 'image/png,image/*;q=0.9,*/*;q=0.8')
        $wc.Headers.Add('Accept-Language', 'en-US,en;q=0.9')

        function Get-ImgWidth([string]$path) {
            try {
                $fs = [System.IO.File]::OpenRead($path)
                try {
                    $img = [System.Drawing.Image]::FromStream($fs, $false, $false)
                    try { return [int]$img.Width } finally { $img.Dispose() }
                }
                finally { $fs.Dispose() }
            }
            catch { return 0 }
        }

        $name = ($key -replace '[^a-zA-Z0-9\.\-]', '_') + '.png'
        $file = Join-Path $dir $name
        if (Test-Path $file) { return }

        $st = @{ best = 0; responded = $false; n = 0 }

        # Download one candidate; keep it if it is the sharpest image so far.
        # $direct = the file comes from the app's own website: even a 16px icon is genuine there.
        # Favicon services return a generic 16px globe for unknown sites, so they must be >= 20px.
        function Try-Url([string]$u, [bool]$direct = $false) {
            if ($st.best -ge 128) { return }
            $minW = 20; if ($direct) { $minW = 16 }
            $st.n++
            $tmp = "$file.$($st.n).tmp"
            try {
                $wc.DownloadFile($u, $tmp)
                $st.responded = $true
                $w = 0
                if ((Get-Item $tmp).Length -gt 150) { $w = Get-ImgWidth $tmp }
                if ($w -ge $minW -and $w -gt $st.best) { Copy-Item $tmp "$file.best" -Force; $st.best = $w }
            }
            catch {
                # a server answer (404...) means the network works; no answer at all means offline
                $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
                if (($ex -is [System.Net.WebException]) -and $ex.Response) { $st.responded = $true }
            }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }

        # sub.example.com -> example.com (not for shared hosting domains such as github.io)
        function Get-RootDomain([string]$h) {
            $p = $h.Split('.')
            if ($p.Count -le 2) { return $h }
            $tail = ($p[-2..-1] -join '.')
            if (@('github.io', 'gitlab.io', 'vercel.app', 'netlify.app', 'pages.dev', 'web.app', 'readthedocs.io', 'herokuapp.com') -contains $tail) { return $h }
            if ($p[-1].Length -eq 2 -and (@('co', 'com', 'org', 'net', 'gov', 'ac', 'ne', 'or') -contains $p[-2])) {
                if ($p.Count -le 3) { return $h }
                return ($p[-3..-1] -join '.')
            }
            return $tail
        }

        # Read the icon links declared in the site's own home page (apple-touch-icon / icon), biggest first.
        function Get-PageIcons([string]$h) {
            $found = @()
            try {
                $base = New-Object System.Uri("https://$h/")
                $html = $wc.DownloadString($base)
                $st.responded = $true
                $items = @()
                foreach ($m in [regex]::Matches($html, '<link\b[^>]*>', 'IgnoreCase')) {
                    $t = $m.Value
                    if ($t -notmatch 'rel\s*=\s*["'']?[^"''>]*icon') { continue }
                    if ($t -match 'href\s*=\s*["'']([^"'']+)["'']') { $href = $Matches[1] } else { continue }
                    if ($href -match '^data:' -or $href -match '\.svg(\?|$)') { continue }
                    $sz = 0
                    if ($t -match 'sizes\s*=\s*["'']?(\d+)x\d+') { $sz = [int]$Matches[1] }
                    if ($t -match 'apple-touch') { $sz += 1000 }
                    try { $abs = (New-Object System.Uri($base, $href)).AbsoluteUri } catch { continue }
                    $items += [pscustomobject]@{ U = $abs; S = $sz }
                }
                $found = @($items | Sort-Object S -Descending | Select-Object -First 3 | ForEach-Object { $_.U })
            }
            catch {
                $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
                if (($ex -is [System.Net.WebException]) -and $ex.Response) { $st.responded = $true }
            }
            return $found
        }

        $hosts = New-Object System.Collections.Generic.List[string]
        if ($hostName) {
            $hosts.Add($hostName)
            $root = Get-RootDomain $hostName
            if ($root -and $root -ne $hostName) { $hosts.Add($root) }
            if ($hostName.Split('.').Count -eq 2) { $hosts.Add('www.' + $hostName) }
        }
        $slugUrls = @()
        if ($slug) {
            $slugUrls = @(
                "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/$slug.png",
                "https://cdn.jsdelivr.net/gh/selfhst/icons/png/$slug.png",
                "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/$slug.png"
            )
        }

        # 1) icon name given in the catalog -> real app logo from the open icon sets
        if ($explicit) { foreach ($u in $slugUrls) { Try-Url $u } }
        # 2) fast favicon service
        if ($hosts.Count -gt 0) { Try-Url ("https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://" + $hosts[0] + "&size=256") }
        # 3) icon sets by app name (apps without an explicit icon name)
        if (-not $explicit) { foreach ($u in $slugUrls) { Try-Url $u } }
        # 4) slower fallbacks, for the site and then its main domain
        foreach ($h in $hosts) {
            Try-Url "https://www.google.com/s2/favicons?domain=$h&sz=256"
            if ($st.best -lt 128) { foreach ($u in (Get-PageIcons $h)) { Try-Url $u $true } }
            Try-Url "https://$h/apple-touch-icon.png" $true
            Try-Url "https://icon.horse/icon/$h"
            Try-Url "https://favicone.com/$h?s=256"
            Try-Url "https://favicon.im/$h?larger=true"
            Try-Url "https://icons.duckduckgo.com/ip3/$h.ico"
            Try-Url "https://$h/favicon.ico" $true
        }

        # Tiny images from favicon services are generic globes (rejected above); keep the letter tile if nothing real was found.
        if ($st.best -ge 16) { Move-Item "$file.best" $file -Force }
        elseif ($st.responded) { Set-Content -Path "$file.miss" -Value '' -ErrorAction SilentlyContinue }   # never cache a "miss" caused by being offline
        Remove-Item "$file.best" -Force -ErrorAction SilentlyContinue
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, 16)
    $pool.ApartmentState = 'MTA'
    $pool.Open()
    $script:IconPool = $pool
    $script:IconJobs = New-Object System.Collections.Generic.List[object]
    foreach ($k in $todo.Keys) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($dlScript).AddArgument($k).AddArgument($todo[$k].Host).AddArgument($todo[$k].Slug).AddArgument($todo[$k].Explicit).AddArgument($IconCache)
        $script:IconJobs.Add(@{ Ps = $ps; Handle = $ps.BeginInvoke() })
    }

    $script:IconTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:IconTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $script:IconTimer.Add_Tick({
            $script:IconTicks++
            [void](Load-CachedIcons)
            $pending = @($script:IconJobs | Where-Object { -not $_.Handle.IsCompleted }).Count
            if ($pending -eq 0 -or $script:IconTicks -gt 1200) {
                $script:IconTimer.Stop()
                $left = Load-CachedIcons
                $withLogo = @($script:Apps | Where-Object { $_.IconKey }).Count
                $names = ''
                if ($left -gt 0) { $names = ' ' + (($script:IconTodo | Select-Object -First 12 | ForEach-Object { $_.NameEn }) -join ', ') }
                Write-Log (($script:T.logosLog -f ($withLogo - $left), $withLogo) + $names)
                # full list of apps that still have no logo (so they can be fixed one by one)
                try {
                    $rep = @($script:IconTodo | ForEach-Object { '{0}   [{1}]' -f $_.NameEn, $_.IconKey })
                    Set-Content -Path (Join-Path $script:SettingsDir 'logo_report.txt') -Value $rep -Encoding UTF8
                } catch { }
                foreach ($j in $script:IconJobs) { try { $j.Ps.EndInvoke($j.Handle) } catch { }; $j.Ps.Dispose() }
                try { $script:IconPool.Close(); $script:IconPool.Dispose() } catch { }
            }
        })
    $script:IconTimer.Start()
}

# ----------------------------------------------------------------------------
# 8. Installation engine (runs winget in a background runspace, UI polls a queue)
# ----------------------------------------------------------------------------
$worker = {
    param($sync, $apps, $desktop)
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

        # ---- helpers: put a desktop shortcut for every installed app --------------------
        $startDirs = @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
        )
        $publicDesktop = ''
        try { $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory') } catch { }
        $skipRx = '(?i)uninstall|readme|read me|help|documentation|manual|release notes|website|web site|license|changelog|faq|tutorial'

        function Get-StartLnks {
            $h = @{}
            foreach ($d in $startDirs) {
                if (Test-Path -LiteralPath $d) {
                    try {
                        foreach ($f in [System.IO.Directory]::EnumerateFiles($d, '*.lnk', [System.IO.SearchOption]::AllDirectories)) { $h[$f] = $true }
                    } catch { }
                }
            }
            return $h
        }

        function Get-Norm([string]$s) { return (([string]$s).ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '') }

        function Test-NameHit([string]$lnkPath, $names, [bool]$strict) {
            $n = Get-Norm ([System.IO.Path]::GetFileNameWithoutExtension($lnkPath))
            if ($n.Length -lt 2) { return $false }
            foreach ($c in $names) {
                if ($strict) { if ($n -eq $c -or ($c.Length -ge 5 -and $n.StartsWith($c))) { return $true } }
                else { if ($n.Contains($c) -or ($n.Length -ge 4 -and $c.Contains($n))) { return $true } }
            }
            return $false
        }

        function New-DesktopShortcuts($app, $before) {
            $made = New-Object System.Collections.Generic.List[string]
            try {
                if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { return }
                $nl = New-Object System.Collections.Generic.List[string]
                $nl.Add((Get-Norm $app.Name))
                if ($app.Source -ne 'msstore') {
                    $parts = @($app.Id -split '\.')
                    if ($parts.Count -gt 1) {
                        $nl.Add((Get-Norm $parts[$parts.Count - 1]))
                        $nl.Add((Get-Norm (($parts[1..($parts.Count - 1)]) -join '')))
                    }
                }
                $names = @($nl | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
                if ($names.Count -eq 0) { return }

                $after = Get-StartLnks
                $new = @($after.Keys | Where-Object { (-not $before.ContainsKey($_)) -and ([System.IO.Path]::GetFileNameWithoutExtension($_) -notmatch $skipRx) })
                $pick = @()
                if ($new.Count -gt 0) {
                    $pick = @($new | Where-Object { Test-NameHit $_ $names $false })
                    if ($pick.Count -eq 0 -and $new.Count -le 2) { $pick = $new }
                }
                if ($pick.Count -eq 0) {
                    # nothing new (e.g. app was already installed): look for an exact-name Start Menu shortcut
                    $pick = @($after.Keys | Where-Object { ([System.IO.Path]::GetFileNameWithoutExtension($_) -notmatch $skipRx) -and (Test-NameHit $_ $names $true) })
                }

                $existed = $false
                foreach ($f in $pick) {
                    $leaf = [System.IO.Path]::GetFileName($f)
                    $dest = Join-Path $desktop $leaf
                    if ((Test-Path -LiteralPath $dest) -or ($publicDesktop -and (Test-Path -LiteralPath (Join-Path $publicDesktop $leaf)))) { $existed = $true; continue }
                    try { Copy-Item -LiteralPath $f -Destination $dest -Force; $made.Add([System.IO.Path]::GetFileNameWithoutExtension($leaf)) } catch { }
                }

                # Microsoft Store (UWP) apps have no .lnk file: create one that launches them
                if ($made.Count -eq 0 -and -not $existed) {
                    try {
                        $sa = Get-StartApps | Where-Object { ((Get-Norm $_.Name) -eq $names[0]) -and ($_.AppID -match '!') } | Select-Object -First 1
                        if ($sa) {
                            $fn = ($sa.Name -replace '[\\/:*?"<>|]', '_') + '.lnk'
                            $dest = Join-Path $desktop $fn
                            if (-not (Test-Path -LiteralPath $dest)) {
                                $ws = New-Object -ComObject WScript.Shell
                                $lnk = $ws.CreateShortcut($dest)
                                $lnk.TargetPath = 'explorer.exe'
                                $lnk.Arguments = 'shell:AppsFolder\' + $sa.AppID
                                $lnk.Save()
                                $made.Add($sa.Name)
                            }
                        }
                    } catch { }
                }
            }
            catch { }
            return $made.ToArray()
        }
        # ---------------------------------------------------------------------------------

        # ---- NVIDIA App is not in winget: fetch the latest official installer and run it silently ----
        function Install-NvidiaApp($app) {
            $q  = $sync.Queue
            $id = $app.Id
            $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
            $ProgressPreference = 'SilentlyContinue'

            # already installed?
            foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                try { if (Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'NVIDIA app*' }) { return -1978335135 } } catch { }
            }

            # newest installer link published on NVIDIA's own download pages
            $url = $null
            foreach ($page in @('https://www.nvidia.com/en-us/software/nvidia-app/', 'https://www.nvidia.com/en-us/software/nvidia-app-enterprise/')) {
                try {
                    $html  = (Invoke-WebRequest -Uri $page -UseBasicParsing -UserAgent $ua -TimeoutSec 30).Content
                    $links = @([regex]::Matches($html, 'https://us\.download\.nvidia\.com/nvapp/client/[\d\.]+/NVIDIA_app_v[\d\.]+\.exe') | ForEach-Object { $_.Value } | Select-Object -Unique)
                    if ($links.Count -gt 0) {
                        $url = $links | Sort-Object { [version]($_ -replace '^.*/NVIDIA_app_v([\d\.]+)\.exe$', '$1') } -Descending | Select-Object -First 1
                        break
                    }
                } catch { }
            }
            if (-not $url) {
                $url = 'https://us.download.nvidia.com/nvapp/client/11.0.2.341/NVIDIA_app_v11.0.2.341.exe'   # last known version
                $q.Enqueue("log|$id|Could not read the latest version from nvidia.com - using the last known installer.")
            }

            $q.Enqueue("log|$id|Downloading: $url")
            $exe = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($url))
            try { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing -UserAgent $ua -TimeoutSec 1800 }
            catch { $q.Enqueue("log|$id|Download failed: $($_.Exception.Message)"); return $null }

            $q.Enqueue("log|$id|Installing silently...")
            $proc = Start-Process -FilePath $exe -ArgumentList '-s -noreboot -noeula -nofinish -nosplash' -Wait -PassThru
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
            return [int]$proc.ExitCode
        }
        # ---------------------------------------------------------------------------------

        foreach ($app in $apps) {
            if ($sync.Cancel) { $sync.Queue.Enqueue("skip|$($app.Id)|"); continue }
            if ($app.Source -eq 'nvapp') {
                $sync.Queue.Enqueue("start|$($app.Id)|")
                $before = Get-StartLnks
                $code = -1
                try { $res = Install-NvidiaApp $app; if ($null -eq $res) { $code = $null } else { $code = [int]$res } }
                catch { $sync.Queue.Enqueue("log|$($app.Id)|$($_.Exception.Message)"); $code = -1 }
                if ($null -eq $code) {
                    # could not download automatically: fall back to opening the official page
                    try { Start-Process 'https://www.nvidia.com/en-us/software/nvidia-app/' } catch { }
                    $sync.Queue.Enqueue("manual|$($app.Id)|")
                    continue
                }
                if (@(0, 3010, -1978335135) -contains $code) {
                    try {
                        if ($code -ne -1978335135) { Start-Sleep -Milliseconds 1500 }
                        $made = @(New-DesktopShortcuts $app $before)
                        if ($made.Count -gt 0) { $sync.Queue.Enqueue("shortcut|$($app.Id)|$($made -join ', ')") }
                    } catch { }
                }
                $sync.Queue.Enqueue("done|$($app.Id)|$code")
                continue
            }
            if ($app.Source -eq 'web') {
                try { Start-Process $app.Id; $sync.Queue.Enqueue("manual|$($app.Id)|") }
                catch { $sync.Queue.Enqueue("log|$($app.Id)|$($_.Exception.Message)"); $sync.Queue.Enqueue("done|$($app.Id)|-1") }
                continue
            }
            $sync.Queue.Enqueue("start|$($app.Id)|")
            $code = -1
            $before = Get-StartLnks
            try {
                $wargs = @('install', '--id', $app.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                if ($app.Source) { $wargs += @('--source', $app.Source) }
                & winget @wargs 2>&1 |
                    ForEach-Object {
                        $line = ("$_").Trim()
                        if ($line.Length -gt 3 -and $line -notmatch '[\u2588\u2592\u2591]' -and $line -notmatch '^\d[\d\.]*\s*(KB|MB|GB)\s*/' -and $line -notmatch '^[-\\|/\s]+$') {
                            $sync.Queue.Enqueue("log|$($app.Id)|$line")
                        }
                    }
                $code = $LASTEXITCODE
            }
            catch {
                $sync.Queue.Enqueue("log|$($app.Id)|$($_.Exception.Message)")
                $code = -1
            }

            # Installed (or already installed) -> make sure the app has a shortcut on the desktop
            if (@(0, 3010, -1978334967, -1978335135, -1978335189) -contains $code) {
                try {
                    if ($code -ne -1978335135 -and $code -ne -1978335189) { Start-Sleep -Milliseconds 1500 }
                    $made = @(New-DesktopShortcuts $app $before)
                    if ($made.Count -gt 0) { $sync.Queue.Enqueue("shortcut|$($app.Id)|$($made -join ', ')") }
                } catch { }
            }
            $sync.Queue.Enqueue("done|$($app.Id)|$code")
        }
    }
    finally {
        $sync.Queue.Enqueue('finished||')
    }
}

function Finish-Install {
    $script:InstallTimer.Stop()
    $script:Busy = $false
    $script:btnCancel.Visibility = 'Collapsed'
    $script:btnCancel.IsEnabled = $true
    $r = $script:Res
    $summary = $script:T.finished -f $r.ok, $r.already, $r.fail, $r.cancel, $r.manual
    $script:txtProgress.Text = $summary
    $script:pbar.Value = 100
    Write-Log $summary
    if ($r.fail -gt 0) { Set-LogVisible $true }
    try { $script:WorkerPs.EndInvoke($script:WorkerHandle) } catch { }
    try { $script:WorkerPs.Dispose(); $script:WorkerRs.Dispose() } catch { }
    Update-Selection
    $icon = 'Information'; if ($r.fail -gt 0) { $icon = 'Warning' }
    [void](Show-Msg $summary $script:T.title 'OK' $icon)
}

function Clear-Finished {
    param([MeshalApp]$Item)
    if (-not $Item) { return }
    $Item.IsSelected = $false
    Update-Selection
    if ($script:Cat -eq 'Selected') { Refresh-Grid }
}

function Process-Queue {
    $msg = $null
    while ($script:Sync.Queue.TryDequeue([ref]$msg)) {
        $p    = ([string]$msg) -split '\|', 3
        $type = $p[0]
        $id   = $p[1]
        $txt  = ''
        if ($p.Count -gt 2) { $txt = $p[2] }
        $item = $null
        if ($id -and $script:ById.ContainsKey($id)) { $item = $script:ById[$id] }
        $r = $script:Res

        switch ($type) {
            'start' {
                Set-Status $item 'st_installing'
                $script:txtProgress.Text = ($script:T.installingNow -f $item.DisplayName, ($r.done + 1), $r.total)
                Write-Log ('>> ' + $item.NameEn + '  (' + $id + ')')
            }
            'manual' {
                Set-Status $item 'st_manual'
                $r.manual++; $r.done++
                $script:pbar.Value = [math]::Round(100 * $r.done / $r.total)
                Write-Log ($script:T.manualLog -f $id)
                Clear-Finished $item
            }
            'shortcut' { Write-Log ($script:T.shortcutLog -f $txt) }
            'log' { Write-Log ('     ' + $txt) -Plain }
            'skip' {
                Set-Status $item 'st_cancelled'
                $r.cancel++; $r.done++
                $script:pbar.Value = [math]::Round(100 * $r.done / $r.total)
            }
            'done' {
                $code = [int]$txt
                switch ($code) {
                    0            { Set-Status $item 'st_done';    $r.ok++;      Write-Log ([string][char]0x2714 + ' ' + $item.NameEn) }
                    -1978335135  { Set-Status $item 'st_already'; $r.already++; Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' (already installed)') }
                    -1978335189  { Set-Status $item 'st_already'; $r.already++; Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' (already up to date)') }
                    -1978334967  { Set-Status $item 'st_done';    $r.ok++;      Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' - ' + $script:T.reboot) }
                    3010         { Set-Status $item 'st_done';    $r.ok++;      Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' - ' + $script:T.reboot) }
                    default      { Set-Status $item 'st_failed';  $r.fail++;    Write-Log ([string][char]0x2716 + ' ' + $item.NameEn + ' - ' + ($script:T.failedCode -f $code)) }
                }
                $r.done++
                $script:pbar.Value = [math]::Round(100 * $r.done / $r.total)
                # installed / already installed -> remove it from the selected list (failed ones stay so you can retry)
                if ($item -and ($item.StatusKey -eq 'st_done' -or $item.StatusKey -eq 'st_already')) { Clear-Finished $item }
            }
            'finished' { Finish-Install }
        }
    }
}

function Start-Install {
    $sel = @($script:Apps | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { [void](Show-Msg $script:T.noSel); return }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [void](Show-Msg $script:T.noWinget $script:T.title 'OK' 'Error'); return
    }
    $answer = Show-Msg ($script:T.confirmMsg -f $sel.Count) $script:T.confirmTitle 'YesNo' 'Question'
    if ($answer -ne 'Yes') { return }

    $script:Busy = $true
    $script:Res = @{ ok = 0; already = 0; fail = 0; cancel = 0; manual = 0; done = 0; total = $sel.Count }
    $script:pbar.Value = 0
    $script:btnInstall.IsEnabled = $false
    $script:btnCancel.Visibility = 'Visible'
    foreach ($a in $sel) { Set-Status $a 'st_queued' }
    Write-Log ($script:T.startLog -f $sel.Count)

    $script:Sync = [hashtable]::Synchronized(@{ Cancel = $false })
    $script:Sync.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

    $list = @($sel | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.NameEn; Source = $_.Source } })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker).AddArgument($script:Sync).AddArgument($list).AddArgument([Environment]::GetFolderPath('Desktop'))
    $script:WorkerHandle = $ps.BeginInvoke()
    $script:WorkerPs = $ps
    $script:WorkerRs = $rs
    $script:InstallTimer.Start()
}

# ----------------------------------------------------------------------------
# 9. Events
# ----------------------------------------------------------------------------
$script:InstallTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:InstallTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:InstallTimer.Add_Tick({ Process-Queue })

# Grid state: cards are added in small batches; search waits 180 ms after the last key press.
$script:GridItems   = New-Object 'System.Collections.ObjectModel.ObservableCollection[MeshalApp]'
$script:CurrentList = New-Object 'System.Collections.Generic.List[MeshalApp]'
$script:GridPos     = 0
$icApps.ItemsSource = $script:GridItems
$script:GridTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:GridTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$script:GridTimer.Add_Tick({
        Add-GridBatch 30
        if ($script:GridPos -ge $script:CurrentList.Count) { $script:GridTimer.Stop() }
    })
$script:SearchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:SearchTimer.Add_Tick({ $script:SearchTimer.Stop(); Refresh-Grid })

$btnLang.Add_Click({
        if ($script:Lang -eq 'en') { $script:Lang = 'ar' } else { $script:Lang = 'en' }
        Apply-Language
        $script:txtCatTitle.Text = [string]$script:T["cat_$($script:Cat)"]
        $script:txtCatCount.Text = ($script:T.appsCount -f $script:CurrentList.Count)
    })

$btnTheme.Add_Click({
        if ($script:Theme -eq 'dark') { Set-Theme 'light' } else { Set-Theme 'dark' }
        Save-Settings
    })

$lstCats.Add_SelectionChanged({
        $sel = $script:lstCats.SelectedItem
        if ($sel) { $script:Cat = $sel.Key; Refresh-Grid }
    })

$txtSearch.Add_TextChanged({
        if ($script:txtSearch.Text.Length -gt 0) { $script:txtPlaceholder.Visibility = 'Collapsed' } else { $script:txtPlaceholder.Visibility = 'Visible' }
        if ($script:txtSearch.Text.Length -gt 0) { $script:btnClearSearch.Visibility = 'Visible' } else { $script:btnClearSearch.Visibility = 'Collapsed' }
        $script:SearchTimer.Stop(); $script:SearchTimer.Start()
    })

$btnClearSearch.Add_Click({ $script:txtSearch.Clear(); $script:txtSearch.Focus() | Out-Null })
$btnLog.Add_Click({ Set-LogVisible ($script:txtLog.Visibility -ne 'Visible') })
$pbar.Add_ValueChanged({
        if ($script:pbar.Value -le 0) { $script:txtPercent.Text = '' } else { $script:txtPercent.Text = ('{0}%' -f [int][math]::Round($script:pbar.Value)) }
    })

$icApps.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [System.Windows.RoutedEventHandler]{ Update-Selection })

$btnSelectVisible.Add_Click({
        foreach ($i in $script:CurrentList) { $i.IsSelected = $true }
        Update-Selection
    })

$btnClear.Add_Click({
        foreach ($a in $script:Apps) { $a.IsSelected = $false }
        Update-Selection
        if ($script:Cat -eq 'Selected') { Refresh-Grid }
    })

$btnInstall.Add_Click({ Start-Install })

# Ctrl+F jumps to the search box
$window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $script:txtSearch.Focus() | Out-Null; $script:txtSearch.SelectAll(); $e.Handled = $true
        }
    })

$btnCancel.Add_Click({
        if ($script:Sync) { $script:Sync.Cancel = $true }
        $script:btnCancel.IsEnabled = $false
        Write-Log $script:T.cancelling
    })

$window.Add_Closing({
        param($s, $e)
        if ($script:Busy) {
            [void](Show-Msg $script:T.busyClose $script:T.title 'OK' 'Warning')
            $e.Cancel = $true
        }
    })

# ----------------------------------------------------------------------------
# 10. Start
# ----------------------------------------------------------------------------
try {
    Initialize-Categories
    Set-Theme $script:Theme
    Apply-Language
    $lstCats.SelectedIndex = 0
    $script:IsAdminNow = $isAdmin

    $window.Add_ContentRendered({
            if ($script:Started) { return }
            $script:Started = $true
            [void](Load-CachedIcons)
            Start-IconDownloads
            $wg = Get-Command winget -ErrorAction SilentlyContinue
            if ($wg) { Write-Log ($script:T.wingetOk -f $wg.Source) } else { Write-Log $script:T.noWinget }
            if (-not $script:IsAdminNow) { Write-Log $script:T.adminWarn }
        })

    [void]$window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Fatal error:`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)", 'MeshalBox', 'OK', 'Error')
}
