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

# Self-update (GitHub Releases). Bump $AppVersion on every release - build.bat reads it for the EXE version.
$AppVersion = '1.0.0'
$UpdateRepo = 'iMeshall/MeshalBox'

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

# Compiled EXE: no admin manifest (so no UAC shield on the icon) - ask for elevation here instead.
if ($IsCompiledExe -and (-not $isAdmin) -and (-not $NoElevate)) {
    try {
        $self    = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $argList = "-Language $Language"
        if ($AppsFile) { $argList += " -AppsFile `"$AppsFile`"" }
        Start-Process -FilePath $self -ArgumentList $argList -Verb RunAs
        exit
    }
    catch {
        # UAC was declined: continue without admin rights (a warning is shown in the app).
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ----------------------------------------------------------------------------
# 1. Data classes (INotifyPropertyChanged so the grid updates live)
# ----------------------------------------------------------------------------
if (-not ('MeshalApp' -as [type])) {
    Add-Type -Language CSharp -ReferencedAssemblies System.dll, System.Drawing.dll -TypeDefinition @'
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
    public string DescEn { get; set; }
    public string DescAr { get; set; }
    private string _tip;
    public string Tip { get { return _tip; } set { _tip = value; Raise("Tip"); } }
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

public static class MeshalImg
{
    // Estimates the REAL resolution of a picture. A small icon that was only enlarged has soft edges
    // (each edge is spread over several pixels); a native icon has crisp edges. Returns <= the pixel width.
    public static int EffectiveWidth(string path)
    {
        using (System.IO.FileStream fs = System.IO.File.OpenRead(path))
        using (System.Drawing.Image src = System.Drawing.Image.FromStream(fs, false, false))
        {
            int w = src.Width, h = src.Height;
            if (w <= 48 || h <= 48) return w;
            using (System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            {
                using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) { g.Clear(System.Drawing.Color.White); g.DrawImage(src, 0, 0, w, h); }
                System.Drawing.Imaging.BitmapData d = bmp.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                int stride = d.Stride;
                byte[] buf = new byte[stride * h];
                Marshal.Copy(d.Scan0, buf, 0, buf.Length);
                bmp.UnlockBits(d);

                int[] lum = new int[w * h];
                int lo = 255, hi = 0;
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int o = y * stride + x * 4;
                        int l = (buf[o + 2] * 299 + buf[o + 1] * 587 + buf[o] * 114) / 1000;
                        lum[y * w + x] = l;
                        if (l < lo) lo = l;
                        if (l > hi) hi = l;
                    }
                int contrast = hi - lo;
                if (contrast < 70) return w;          // too flat to judge (e.g. white logo on transparent)

                int[] hist = new int[256];
                long n = 0;
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int i = y * w + x;
                        if (x + 1 < w) { hist[Math.Abs(lum[i] - lum[i + 1])]++; n++; }
                        if (y + 1 < h) { hist[Math.Abs(lum[i] - lum[i + w])]++; n++; }
                    }
                long want = (long)(n * 0.003);
                if (want < 20) want = 20;
                long acc = 0; int J = 1;
                for (int v = 255; v >= 1; v--) { acc += hist[v]; if (acc >= want) { J = v; break; } }
                double ratio = (J * 1.5) / contrast;   // 1.0 = native/crisp, 0.25 = enlarged about 4x
                if (ratio > 1.0) ratio = 1.0;
                return (int)(w * ratio);
            }
        }
    }
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
        updBtn        = 'Update available'
        updTip        = 'A new version of MeshalBox is available'
        updTitle      = 'Update MeshalBox'
        updHead       = 'A new version of MeshalBox is available.'
        updVer        = 'Current version: {0}   >>   New version: {1}'
        updNotes      = 'What''s new:'
        updNoNotes    = 'No release notes were provided.'
        updAsk        = 'Do you want to update to the new version now? MeshalBox will close and reopen automatically.'
        updAskSrc     = 'Do you want to open the download page of the new version?'
        updBusy       = 'Please wait until the current operation finishes, then try again.'
        updDownloading = 'Downloading the update...'
        updFail       = 'The update failed:{0}{1}'
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
        cat_Peripherals = 'Peripherals'; cat_Installed = 'Installed'
        upgradeAll    = [string][char]0x21BB + '  Upgrade all'
        uninstallBtn  = [char]::ConvertFromUtf32(0x1F5D1) + '  Uninstall'
        st_uninstalling = [string][char]0x23F3 + ' Removing...'
        st_removed    = [string][char]0x2714 + ' Uninstalled'
        noInstalledSel = 'Select installed apps first (the ones with the green "Installed" badge).'
        confirmUninst = '{0} app(s) will be REMOVED from this PC. Continue?'
        confirmUninstTitle = 'Confirm uninstall'
        startUninst   = 'Starting removal of {0} app(s)...'
        uninstNow     = 'Uninstalling: {0}  ({1}/{2})'
        finishedUninst = 'Finished: {0} removed, {1} failed, {2} cancelled.'
        confirmUpgrade = 'Upgrade every app on this PC that has an update available?'
        confirmUpgradeTitle = 'Confirm upgrade'
        startUpgrade  = 'Checking for updates and upgrading all apps...'
        upgradingNow  = 'Upgrading all apps... please wait'
        upDone        = 'Upgrade finished: {0} app(s) updated.'
        upFinished    = 'Upgrade finished.'
        upNone        = 'Everything is already up to date.'
        upFailed      = 'Upgrade finished with some errors. Check the log.'
        upCancelled   = 'Upgrade stopped.'
        st_queued     = [string][char]0x23F3 + ' Queued'
        st_installing = [string][char]0x2B07 + ' Installing...'
        st_done       = [string][char]0x2714 + ' Installed'
        st_already    = [string][char]0x2714 + ' Already installed'
        st_installed  = [string][char]0x2714 + ' Installed'
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
        cancelling    = 'Stopping the installation...'
        scanStart     = 'Checking which apps are already installed on this PC...'
        scanDone      = 'Detected {0} installed app(s).'
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
        updBtn        = 'يتوفر تحديث'
        updTip        = 'يتوفر إصدار جديد من MeshalBox'
        updTitle      = 'تحديث MeshalBox'
        updHead       = 'يتوفر إصدار جديد من MeshalBox.'
        updVer        = 'الإصدار الحالي: {0}   >>   الإصدار الجديد: {1}'
        updNotes      = 'ما الجديد:'
        updNoNotes    = 'لا توجد ملاحظات لهذا الإصدار.'
        updAsk        = 'هل تريد التحديث إلى الإصدار الجديد الآن؟ سيُغلق MeshalBox ثم يُعاد فتحه تلقائيًا.'
        updAskSrc     = 'هل تريد فتح صفحة تحميل الإصدار الجديد؟'
        updBusy       = 'يرجى الانتظار حتى تنتهي العملية الحالية ثم أعد المحاولة.'
        updDownloading = 'جارٍ تحميل التحديث...'
        updFail       = 'فشل التحديث:{0}{1}'
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
        cat_Peripherals = 'الملحقات'; cat_Installed = 'المثبّتة'
        upgradeAll    = [string][char]0x21BB + '  تحديث الكل'
        uninstallBtn  = [char]::ConvertFromUtf32(0x1F5D1) + '  إزالة'
        st_uninstalling = [string][char]0x23F3 + ' جارٍ الإزالة...'
        st_removed    = [string][char]0x2714 + ' تمت الإزالة'
        noInstalledSel = 'اختر أولًا برامج مثبّتة (التي عليها علامة "مثبّت" الخضراء).'
        confirmUninst = 'سيتم حذف {0} برنامج من هذا الجهاز. هل تريد المتابعة؟'
        confirmUninstTitle = 'تأكيد الإزالة'
        startUninst   = 'بدء إزالة {0} برنامج...'
        uninstNow     = 'جارٍ إزالة: {0}  ({1}/{2})'
        finishedUninst = 'اكتمل: {0} تمت إزالته، {1} فشل، {2} أُلغي.'
        confirmUpgrade = 'سيتم تحديث كل البرامج على هذا الجهاز التي يتوفر لها تحديث. هل تريد المتابعة؟'
        confirmUpgradeTitle = 'تأكيد التحديث'
        startUpgrade  = 'جارٍ البحث عن التحديثات وتحديث كل البرامج...'
        upgradingNow  = 'جارٍ تحديث كل البرامج... الرجاء الانتظار'
        upDone        = 'اكتمل التحديث: تم تحديث {0} برنامج.'
        upFinished    = 'اكتمل التحديث.'
        upNone        = 'كل البرامج محدّثة بالفعل.'
        upFailed      = 'اكتمل التحديث مع بعض الأخطاء. راجع السجل.'
        upCancelled   = 'تم إيقاف التحديث.'
        st_queued     = [string][char]0x23F3 + ' في الانتظار'
        st_installing = [string][char]0x2B07 + ' جارٍ التثبيت...'
        st_done       = [string][char]0x2714 + ' تم التثبيت'
        st_already    = [string][char]0x2714 + ' مثبّت مسبقًا'
        st_installed  = [string][char]0x2714 + ' مثبّت'
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
        cancelling    = 'جارٍ إيقاف التثبيت...'
        scanStart     = 'جارٍ فحص البرامج المثبّتة مسبقًا على جهازك...'
        scanDone      = 'تم التعرّف على {0} برنامج مثبّت.'
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
$CategoryOrder = @('All', 'Selected', 'Installed', 'Browsers', 'Gaming', 'Peripherals', 'Communication', 'Media', 'Development',
                   'Utilities', 'Security', 'Productivity', 'Design', 'Cloud', 'Runtimes',
                   'ProTools', 'Microsoft', 'Selfhosted', 'Store')
$CategoryGlyph = @{
    All = [char]::ConvertFromUtf32(0x1F5C2); Selected = [string][char]0x2705; Installed = [char]::ConvertFromUtf32(0x1F4E6)
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
    All = '#E5E7EB'; Selected = '#4ADE80'; Installed = '#A78BFA'; Browsers = '#60A5FA'; Gaming = '#C084FC'; Peripherals = '#F9A8D4'
    Communication = '#34D399'; Media = '#F472B6'; Development = '#38BDF8'; Utilities = '#FBBF24'
    Security = '#F87171'; Productivity = '#A3E635'; Design = '#FB923C'; Cloud = '#7DD3FC'
    Runtimes = '#CBD5E1'
    ProTools = '#FCA5A5'; Microsoft = '#93C5FD'; Selfhosted = '#86EFAC'; Store = '#FDE68A'
}

# Darker versions of the same colours so the icons stay readable on the light background
$CategoryColorLight = @{
    All = '#6B7280'; Selected = '#16A34A'; Installed = '#7C3AED'; Browsers = '#2563EB'; Gaming = '#9333EA'; Peripherals = '#DB2777'
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
    $a.DescEn = if ($e.desc) { [string]$e.desc } else { '' }
    $a.DescAr = if ($e.descAr) { [string]$e.descAr } else { $a.DescEn }
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
# Logo logic v5: sharpness-aware downloader -> drop every cached logo once so blurry ones are replaced by sharp ones
try {
    $iconMarker5 = Join-Path $IconCache '.logic_v5'
    if (-not (Test-Path $iconMarker5)) {
        Get-ChildItem -Path $IconCache -Include '*.png', '*.miss' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Set-Content -Path $iconMarker5 -Value ''
    }
} catch { }
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
            <Border x:Name="bd" Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1.5" CornerRadius="12" Padding="0,10,0,10">
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
                    RenderTransformOrigin="0.5,0.5" ToolTipService.InitialShowDelay="350" ToolTipService.ShowDuration="30000">
              <Border.ToolTip>
                <ToolTip Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1.5" Padding="12,9" MaxWidth="340">
                  <TextBlock Text="{Binding Tip}" TextWrapping="Wrap" FontSize="13" LineHeight="19" Foreground="{DynamicResource TextPrimary}"/>
                </ToolTip>
              </Border.ToolTip>
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
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_uninstalling"><Setter Property="Background" Value="{DynamicResource StInfoBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_removed"><Setter Property="Background" Value="{DynamicResource StOkBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_manual"><Setter Property="Background" Value="{DynamicResource StInfoBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_done"><Setter Property="Background" Value="{DynamicResource StOkBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_already"><Setter Property="Background" Value="{DynamicResource StOkBg}"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_installed"><Setter Property="Background" Value="{DynamicResource StOkBg}"/></DataTrigger>
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
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_uninstalling"><Setter Property="Foreground" Value="{DynamicResource StInfoFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_removed"><Setter Property="Foreground" Value="{DynamicResource StOkFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_manual"><Setter Property="Foreground" Value="{DynamicResource StInfoFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_done"><Setter Property="Foreground" Value="{DynamicResource StOkFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_already"><Setter Property="Foreground" Value="{DynamicResource StOkFg}"/></DataTrigger>
                            <DataTrigger Binding="{Binding StatusKey}" Value="st_installed"><Setter Property="Foreground" Value="{DynamicResource StOkFg}"/></DataTrigger>
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
            <TextBox x:Name="txtSearch" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center" TextWrapping="NoWrap" AcceptsReturn="False"/>
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource TextMuted}"
                       IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="15,0,0,0"/>
            <TextBlock x:Name="txtPlaceholder" IsHitTestVisible="False" Foreground="{DynamicResource TextMuted}" FontSize="14"
                       VerticalAlignment="Center" Margin="44,0,16,0"/>
            <Button x:Name="btnClearSearch" Style="{StaticResource IconBtn}" HorizontalAlignment="Right"
                    VerticalAlignment="Center" Margin="0,0,9,0" Visibility="Collapsed"/>
          </Grid>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnUpdate" Style="{StaticResource BtnPrimary}" Padding="14,9" FontSize="13" Visibility="Collapsed"/>
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
            <Button x:Name="btnUpgrade" Style="{StaticResource Btn}"/>
            <Button x:Name="btnUninstall" Style="{StaticResource Btn}"/>
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
                'btnClear', 'txtCatTitle', 'txtCatCount', 'icApps', 'txtEmpty', 'txtSelected', 'pbar', 'txtProgress', 'btnCancel', 'btnInstall', 'btnUpgrade', 'btnUninstall', 'txtLog', 'btnLog', 'txtPercent', 'btnClearSearch', 'btnTheme', 'btnUpdate') {
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
        elseif ($cat -eq 'Installed') { if (-not $script:InstalledIds.ContainsKey($a.Id)) { continue } }
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

function Update-InstalledCount {
    if ($script:CatMap.ContainsKey('Installed')) { $script:CatMap['Installed'].Count = $script:InstalledIds.Count }
}

function Set-InstalledFlag {
    param([string]$Id, [bool]$Value)
    if ($Value) { $script:InstalledIds[$Id] = $true } else { [void]$script:InstalledIds.Remove($Id) }
    Update-InstalledCount
    if ($script:Cat -eq 'Installed') { Refresh-Grid }
}

function Update-Selection {
    $n = @($script:Apps | Where-Object { $_.IsSelected }).Count
    $ni = @($script:Apps | Where-Object { $_.IsSelected -and $script:InstalledIds.ContainsKey($_.Id) }).Count
    $script:btnUpgrade.IsEnabled = (-not $script:Busy)
    $script:btnUninstall.IsEnabled = ($ni -gt 0) -and (-not $script:Busy)
    if ($ni -gt 0) { $script:btnUninstall.Content = ('{0} ({1})' -f $script:T.uninstallBtn, $ni) } else { $script:btnUninstall.Content = $script:T.uninstallBtn }
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
    $script:btnUpdate.Content = ([string][char]0x2191 + ' ' + $t.updBtn)
    $script:btnUpdate.ToolTip = $t.updTip
    Update-ThemeButton
    $script:btnSelectVisible.Content = $t.selectVisible
    $script:btnClear.Content  = $t.clearAll
    $script:btnInstall.Content = $t.install
    $script:btnCancel.Content = $t.cancel
    $script:btnUpgrade.Content = $t.upgradeAll
    $script:txtEmpty.Text     = [char]::ConvertFromUtf32(0x1F50D) + "`n" + $t.noResults
    $script:btnClearSearch.ToolTip = $t.clearAll
    Set-LogVisible ($script:txtLog.Visibility -eq 'Visible')
    if (-not $script:Busy) { $script:txtProgress.Text = $t.ready }

    foreach ($a in $script:Apps) {
        if ($script:Lang -eq 'ar') { $a.DisplayName = $a.NameAr; $a.Tip = $a.DescAr } else { $a.DisplayName = $a.NameEn; $a.Tip = $a.DescEn }
        if (-not $a.Tip) { $a.Tip = $a.DisplayName + '  (' + $a.Id + ')' }
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

        # real (not enlarged) resolution of the picture - an upscaled 32px favicon counts as ~32, not 256
        function Get-ImgWidth([string]$path) {
            try { return [int][MeshalImg]::EffectiveWidth($path) }
            catch {
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
        }

        $name = ($key -replace '[^a-zA-Z0-9\.\-]', '_') + '.png'
        $file = Join-Path $dir $name
        if (Test-Path $file) { return }

        $st = @{ best = 0; responded = $false; n = 0 }

        # Download one candidate; keep it if it is the sharpest image so far.
        # $direct = the file comes from the app's own website: even a 16px icon is genuine there.
        # Favicon services return a generic 16px globe for unknown sites, so they must be >= 20px.
        function Try-Url([string]$u, [bool]$direct = $false) {
            if ($st.best -ge 96) { return }
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
            if ($st.best -lt 96) { foreach ($u in (Get-PageIcons $h)) { Try-Url $u $true } }
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
    param($sync, $apps, $desktop, $mode)
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

        function Get-StoreApps {
            try { return @(Get-StartApps | Where-Object { $_.AppID -match '!' }) } catch { return @() }
        }
        function Get-StoreAppIds {
            $h = @{}
            foreach ($x in (Get-StoreApps)) { $h[[string]$x.AppID] = $true }
            return $h
        }

        # Store apps have no icon file: take the logo from the app package and convert it to a .ico
        function New-StoreAppIcon([string]$appId) {
            try {
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                $pfn = ($appId -split '!')[0]
                $global:IconWhy = 'package not found: ' + $pfn
                $pkg = Get-AppxPackage -PackageFamilyName $pfn -ErrorAction Stop | Select-Object -First 1
                if (-not $pkg -or -not $pkg.InstallLocation) { return $null }
                $global:InstallDir = [string]$pkg.InstallLocation
                $global:IconWhy = 'cannot read manifest in ' + $pkg.InstallLocation
                $manifest = Get-Content -LiteralPath (Join-Path $pkg.InstallLocation 'AppxManifest.xml') -Raw -ErrorAction Stop
                $global:AppExe = $null
                if ($manifest -match 'Executable="([^"]+)"') { $global:AppExe = Join-Path $pkg.InstallLocation ($Matches[1] -replace '/', '\') }
                $logo = $null
                foreach ($attr in @('Square44x44Logo', 'Square150x150Logo', 'Logo')) {
                    if ($manifest -match ($attr + '="([^"]+)"')) { $logo = $Matches[1]; break }
                }
                if (-not $logo) { $global:IconWhy = 'no logo entry in manifest'; return $null }
                $rel  = $logo -replace '/', '\'
                $dir  = Split-Path -Parent (Join-Path $pkg.InstallLocation $rel)
                $base = [System.IO.Path]::GetFileNameWithoutExtension($rel)
                $global:IconWhy = 'cannot list logo folder ' + $dir
                $files = @(Get-ChildItem -LiteralPath $dir -Filter ($base + '*.png') -ErrorAction Stop)
                if ($files.Count -eq 0) { $global:IconWhy = 'no png for ' + $base; return $null }
                $global:IconWhy = 'cannot convert logo to ico'
                $best = $null; $bestW = 0
                foreach ($f in $files) {
                    if ($f.Name -match 'lightunplated|contrast|devicefamily-colorfulunplated') { continue }
                    try {
                        $im = [System.Drawing.Image]::FromFile($f.FullName)
                        $w = $im.Width; $im.Dispose()
                        $pref = 0; if ($f.Name -match 'targetsize|unplated') { $pref = 1 }
                        $score = $w + ($pref * 1000)
                        if ($score -gt $bestW) { $bestW = $score; $best = $f.FullName }
                    } catch { }
                }
                if (-not $best) { return $null }
                $src = [System.Drawing.Image]::FromFile($best)
                $bmp = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.Clear([System.Drawing.Color]::Transparent)
                $scale = [math]::Min(256.0 / $src.Width, 256.0 / $src.Height)
                $w2 = [int]($src.Width * $scale); $h2 = [int]($src.Height * $scale)
                $g.DrawImage($src, [int]((256 - $w2) / 2), [int]((256 - $h2) / 2), $w2, $h2)
                $g.Dispose(); $src.Dispose()
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
                $png = $ms.ToArray(); $ms.Dispose()

                $icoDir = Join-Path $env:LOCALAPPDATA 'MeshalBox\icons'
                [void][System.IO.Directory]::CreateDirectory($icoDir)
                $icoPath = Join-Path $icoDir (($pfn -replace '[^\w\.\-]', '_') + '.ico')
                $fs = [System.IO.File]::Create($icoPath)
                $bw = New-Object System.IO.BinaryWriter($fs)
                $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)          # ICONDIR
                $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)   # 256x256, no palette
                $bw.Write([uint16]1); $bw.Write([uint16]32)
                $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
                $bw.Write($png)
                $bw.Flush(); $bw.Close(); $fs.Close()
                $global:IconWhy = 'ok'
                return $icoPath
            } catch { $global:IconWhy += ' (' + $_.Exception.Message + ')'; return $null }
        }

        function Update-ShellIcons {
            try {
                if (-not ('MB.ShellNotify' -as [type])) {
                    Add-Type -Namespace MB -Name ShellNotify -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);'
                }
                [MB.ShellNotify]::SHChangeNotify(0x08000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
            } catch { }
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
                        $sa = $null
                        $tries = 1; if ($app.Source -eq 'msstore') { $tries = 10 }   # the Store needs a few seconds to register a new app
                        for ($t = 0; $t -lt $tries -and -not $sa; $t++) {
                            if ($t -gt 0) { Start-Sleep -Seconds 2 }
                            $all = @(Get-StoreApps)
                            # 1) by name: exact, or "ChatGPT" vs "ChatGPT Desktop"
                            foreach ($x in $all) {
                                $n = Get-Norm $x.Name
                                foreach ($c in $names) {
                                    if ($n -eq $c -or ($n.Length -ge 4 -and $c.Length -ge 5 -and ($c.StartsWith($n) -or $n.StartsWith($c)))) { $sa = $x; break }
                                }
                                if ($sa) { break }
                            }
                            # 2) a Store app that did not exist before this install
                            if (-not $sa -and $app.Source -eq 'msstore') {
                                $fresh = @($all | Where-Object { -not $beforeSA.ContainsKey([string]$_.AppID) })
                                if ($fresh.Count -eq 1) { $sa = $fresh[0] }
                            }
                        }
                        if ($sa) {
                            $fn = ($sa.Name -replace '[\\/:*?"<>|]', '_') + '.lnk'
                            $dest = Join-Path $desktop $fn
                            $destPub = ''; if ($publicDesktop) { $destPub = Join-Path $publicDesktop $fn }
                            $appUri = 'shell:AppsFolder\' + [string]$sa.AppID
                            $ws = New-Object -ComObject WScript.Shell
                            $changed = $false
                            # Native Store-app shortcut: TargetPath = shell:AppsFolder\<AppID> (same thing Explorer creates).
                            # Windows then takes the app's own icon automatically. The old "explorer.exe + arguments" form always shows a folder icon.
                            foreach ($d2 in @($dest, $destPub)) {
                                if ($d2 -and (Test-Path -LiteralPath $d2)) {
                                    try {
                                        $old = $ws.CreateShortcut($d2)
                                        if ($old.TargetPath -like '*explorer.exe' -and $old.Arguments -like 'shell:AppsFolder*') { Remove-Item -LiteralPath $d2 -Force -ErrorAction Stop }
                                    } catch { }
                                }
                            }
                            if (-not (Test-Path -LiteralPath $dest) -and -not ($destPub -and (Test-Path -LiteralPath $destPub))) {
                                $ok = $false
                                try {
                                    $lnk = $ws.CreateShortcut($dest)
                                    $lnk.TargetPath = $appUri
                                    $lnk.Save()
                                    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { $ok = $true }
                                } catch { $sync.Queue.Enqueue("log|$($app.Id)|Native shortcut failed: $($_.Exception.Message)") }
                                if (-not $ok) {
                                    # fallback: explorer.exe + the app's own logo as icon
                                    $global:IconWhy = ''; $global:AppExe = $null
                                    $ico = New-StoreAppIcon ([string]$sa.AppID)
                                    $iconLoc = ''
                                    if ($ico) { $iconLoc = $ico + ',0' }
                                    elseif ($global:AppExe -and (Test-Path -LiteralPath $global:AppExe)) { $iconLoc = $global:AppExe + ',0' }
                                    if (-not $iconLoc) { $sync.Queue.Enqueue("log|$($app.Id)|Icon not found: $($global:IconWhy)") }
                                    $lnk = $ws.CreateShortcut($dest)
                                    $lnk.TargetPath = 'explorer.exe'
                                    $lnk.Arguments = $appUri
                                    if ($iconLoc) { $lnk.IconLocation = $iconLoc }
                                    $lnk.Save()
                                }
                                $made.Add($sa.Name); $changed = $true
                            }
                            if ($changed) { Update-ShellIcons }
                        }
                    } catch { }
                }
            }
            catch { }
            return $made.ToArray()
        }
        # ---------------------------------------------------------------------------------

        # ---- helpers: stop a process together with everything it started ----------------
        function Stop-Tree([int]$ProcId) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'taskkill.exe'; $psi.Arguments = "/PID $ProcId /T /F"
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $k = [System.Diagnostics.Process]::Start($psi); [void]$k.WaitForExit(5000)
            } catch { }
        }

        # ---- helpers: real download progress (0..1) from a winget output line -----------
        function Get-Frac([string]$line) {
            $inv = [Globalization.CultureInfo]::InvariantCulture
            if ($line -match '(\d+(?:[\.,]\d+)?)\s*(KB|MB|GB)\s*/\s*(\d+(?:[\.,]\d+)?)\s*(KB|MB|GB)') {
                $mul = @{ KB = 1.0; MB = 1024.0; GB = 1048576.0 }
                $c = [double]::Parse(($Matches[1] -replace ',', '.'), $inv) * $mul[$Matches[2].ToUpper()]
                $t = [double]::Parse(($Matches[3] -replace ',', '.'), $inv) * $mul[$Matches[4].ToUpper()]
                if ($t -gt 0) { return [math]::Min(1.0, $c / $t) }
            }
            elseif ($line -match '(?<![\d\.])(\d{1,3})\s*%') { return [math]::Min(1.0, [int]$Matches[1] / 100.0) }
            return -1.0
        }

        function Send-WingetLine([string]$id, [string]$raw) {
            $line = $raw.Trim()
            if ($line.Length -eq 0) { return }
            $f = Get-Frac $line
            if ($line -match '(?i)verified installer hash|starting package install') { $f = 1.0 }
            if ($f -ge 0) { $sync.Queue.Enqueue("prog|$id|" + ([double]$f).ToString([Globalization.CultureInfo]::InvariantCulture)) }
            if ($line.Length -gt 3 -and $line -notmatch '[\u2588\u2592\u2591]' -and $line -notmatch '^\d[\d\.]*\s*(KB|MB|GB)\s*/' -and $line -notmatch '^[-\\|/\s]+$') {
                $sync.Queue.Enqueue("log|$id|$line")
            }
        }

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
            try {
                $req = [Net.HttpWebRequest]::Create($url); $req.UserAgent = $ua; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
                $resp = $req.GetResponse(); $total = $resp.ContentLength
                $inS = $resp.GetResponseStream(); $outS = [System.IO.File]::Create($exe)
                try {
                    $buf = New-Object byte[] 81920; $got = 0; $last = 0.0
                    while (($n = $inS.Read($buf, 0, $buf.Length)) -gt 0) {
                        if ($sync.Cancel) { throw 'cancelled' }
                        $outS.Write($buf, 0, $n); $got += $n
                        if ($total -gt 0) {
                            $fr = $got / $total
                            if (($fr - $last) -ge 0.01) { $last = $fr; $q.Enqueue("prog|$id|" + ([double]$fr).ToString([Globalization.CultureInfo]::InvariantCulture)) }
                        }
                    }
                } finally { $outS.Close(); $inS.Close(); $resp.Close() }
                $q.Enqueue("prog|$id|1")
            }
            catch {
                Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
                if (-not $sync.Cancel) { $q.Enqueue("log|$id|Download failed: $($_.Exception.Message)") }
                return $null
            }

            $q.Enqueue("log|$id|Installing silently...")
            $proc = Start-Process -FilePath $exe -ArgumentList '-s -noreboot -noeula -nofinish -nosplash' -PassThru
            $null = $proc.Handle
            while (-not $proc.HasExited) {
                if ($sync.Cancel) { Stop-Tree $proc.Id; break }
                Start-Sleep -Milliseconds 200
            }
            $proc.WaitForExit()
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
            return [int]$proc.ExitCode
        }
        # ---------------------------------------------------------------------------------

        function Send-UpgradeLine([string]$raw) {
            $line = $raw.Trim()
            if ($line.Length -eq 0) { return }
            if ($line -match '^\((\d+)/(\d+)\)\s') {
                $n1 = [int]$Matches[1]; $m1 = [int]$Matches[2]
                if ($m1 -gt 0) { $sync.Queue.Enqueue('upprog|all|' + (([double]($n1 - 1) / $m1)).ToString([Globalization.CultureInfo]::InvariantCulture)) }
            }
            if ($line -match '(?i)successfully installed') { $global:UpCount++ }
            if ($line.Length -gt 3 -and $line -notmatch '[\u2588\u2592\u2591]' -and $line -notmatch '^\d[\d\.]*\s*(KB|MB|GB)\s*/' -and $line -notmatch '^[-\\|/\s]+$') {
                $sync.Queue.Enqueue("log|all|$line")
            }
        }

        function Send-Line([string]$lineMode, [string]$lineId, [string]$raw) {
            if ($lineMode -eq 'upgrade') { Send-UpgradeLine $raw } else { Send-WingetLine $lineId $raw }
        }

        # runs one winget command (output captured through a temp file so Stop can kill it at any moment)
        function Run-Winget([string]$wcmd, [string]$lineId, [string]$lineMode, [bool]$limited = $false) {
            $code = -1
            $logFile = Join-Path $env:TEMP ('meshalbox_' + [guid]::NewGuid().ToString('N') + '.log')
            $codeFile = $logFile + '.code'
            $batFile = $logFile + '.cmd'
            $taskName = 'MeshalBox_' + [guid]::NewGuid().ToString('N')
            $p = $null
            try {
                if ($limited) {
                    # Run winget WITHOUT administrator rights (needed to remove apps installed for the current user only).
                    # A scheduled task with RunLevel Limited starts a normal, non-elevated process in the user's session.
                    $bat = "@echo off`r`n" + $wcmd + ' > "' + $logFile + '" 2>&1' + "`r`n" + 'echo %errorlevel% > "' + $codeFile + '"' + "`r`n"
                    [System.IO.File]::WriteAllText($batFile, $bat, (New-Object System.Text.UTF8Encoding($false)))
                    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    $act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument ('--headless cmd.exe /d /c "' + $batFile + '"')
                    $prn = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
                    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
                    [void](Register-ScheduledTask -TaskName $taskName -Action $act -Principal $prn -Settings $set -Force)
                    Start-ScheduledTask -TaskName $taskName
                }
                else {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $env:ComSpec
                    $psi.Arguments = '/d /c "' + $wcmd + ' > "' + $logFile + '" 2>&1"'
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow = $true
                    $p = [System.Diagnostics.Process]::Start($psi)
                    $sync.Proc = $p
                }
                $dec = [System.Text.Encoding]::UTF8.GetDecoder()
                $pos = 0L
                $sb = New-Object System.Text.StringBuilder
                while ($true) {
                    if ($limited) {
                        $exited = Test-Path -LiteralPath $codeFile
                        if (-not $exited) {
                            $ti = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                            if ($sync.Cancel) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue; $exited = $true }
                            elseif ($ti -and $ti.State -ne 'Running' -and $ti.State -ne 'Queued') { Start-Sleep -Milliseconds 400; $exited = $true }
                        }
                    }
                    else {
                        if ($sync.Cancel -and -not $p.HasExited) { Stop-Tree $p.Id }
                        $exited = $p.HasExited
                    }
                    try {
                        if (Test-Path -LiteralPath $logFile) {
                            $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite,Delete')
                            try {
                                if ($fs.Length -gt $pos) {
                                    [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
                                    $bytes = New-Object byte[] ([int]($fs.Length - $pos))
                                    $n = $fs.Read($bytes, 0, $bytes.Length)
                                    $pos += $n
                                    $chars = New-Object char[] ($n + 4)
                                    $cn = $dec.GetChars($bytes, 0, $n, $chars, 0)
                                    for ($i = 0; $i -lt $cn; $i++) {
                                        $ch = $chars[$i]
                                        if ($ch -eq [char]13 -or $ch -eq [char]10) {
                                            if ($sb.Length -gt 0) { Send-Line $lineMode $lineId $sb.ToString(); [void]$sb.Clear() }
                                        }
                                        else { [void]$sb.Append($ch) }
                                    }
                                }
                            } finally { $fs.Close() }
                        }
                    } catch { }
                    if ($exited) { break }
                    Start-Sleep -Milliseconds 150
                }
                if ($sb.Length -gt 0) { Send-Line $lineMode $lineId $sb.ToString() }
                if ($limited) {
                    $code = -1
                    try { if (Test-Path -LiteralPath $codeFile) { $code = [int](([System.IO.File]::ReadAllText($codeFile)).Trim()) } } catch { }
                }
                else {
                    $p.WaitForExit()
                    $code = $p.ExitCode
                }
            }
            catch {
                $sync.Queue.Enqueue("log|$lineId|$($_.Exception.Message)")
                $code = -1
            }
            finally {
                $sync.Proc = $null
                if ($limited) { try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { } }
                Remove-Item -LiteralPath $logFile, $codeFile, $batFile -Force -ErrorAction SilentlyContinue
            }

            return [int]$code
        }

        # ---- Upgrade everything that has an update ----------------------------------------
        if ($mode -eq 'upgradeall') {
            $global:UpCount = 0
            $sync.Queue.Enqueue('ustart|all|')
            $code = Run-Winget 'winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' 'all' 'upgrade'
            if ($sync.Cancel -and (@(0, -1978335189) -notcontains $code)) { $code = -999 }
            $sync.Queue.Enqueue("upcount|all|$($global:UpCount)")
            $sync.Queue.Enqueue("done|all|$code")
            return
        }

        foreach ($app in $apps) {
            if ($sync.Cancel) { $sync.Queue.Enqueue("skip|$($app.Id)|"); continue }

            # ---- Uninstall mode ----
            if ($mode -eq 'uninstall') {
                if ($app.Source -eq 'web') { $sync.Queue.Enqueue("log|$($app.Id)|Cannot remove automatically - uninstall it from Windows Settings."); $sync.Queue.Enqueue("skip|$($app.Id)|"); continue }
                $sync.Queue.Enqueue("start|$($app.Id)|")
                if ($app.Source -eq 'nvapp') { $ucmd = 'winget uninstall --name "NVIDIA app" --silent --accept-source-agreements --disable-interactivity' }
                else {
                    $ucmd = 'winget uninstall --id ' + $app.Id + ' --exact --silent --accept-source-agreements --disable-interactivity'
                    if ($app.Source -eq 'msstore') { $ucmd += ' --source msstore' }
                }
                $code = Run-Winget $ucmd $app.Id 'install'
                # user-scope package + elevated session -> winget refuses (0x8A15007D-style error); retry without admin rights
                if (($code -eq -1978335107) -and -not $sync.Cancel) {
                    $sync.Queue.Enqueue("log|$($app.Id)|User-scope app - retrying the removal without administrator rights...")
                    $code = Run-Winget $ucmd $app.Id 'install' $true
                }
                if ($sync.Cancel -and (@(0, 3010, -1978334967) -notcontains $code)) { $sync.Queue.Enqueue("skip|$($app.Id)|"); continue }
                $sync.Queue.Enqueue("done|$($app.Id)|$code")
                continue
            }
            if ($app.Source -eq 'nvapp') {
                $sync.Queue.Enqueue("start|$($app.Id)|")
                $before = Get-StartLnks
                $beforeSA = Get-StoreAppIds
                $code = -1
                try { $res = Install-NvidiaApp $app; if ($null -eq $res) { $code = $null } else { $code = [int]$res } }
                catch { $sync.Queue.Enqueue("log|$($app.Id)|$($_.Exception.Message)"); $code = -1 }
                if ($sync.Cancel -and (@(0, 3010, -1978335135) -notcontains $code)) { $sync.Queue.Enqueue("skip|$($app.Id)|"); continue }
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
            $beforeSA = Get-StoreAppIds
            $wcmd = 'winget install --id ' + $app.Id + ' --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
            if ($app.Source) { $wcmd += ' --source ' + $app.Source }
            $code = Run-Winget $wcmd $app.Id 'install'

            # Stop was pressed while this app was running -> report it as cancelled (unless it had already succeeded)
            if ($sync.Cancel -and (@(0, 3010, -1978334967, -1978335135, -1978335189) -notcontains $code)) {
                $sync.Queue.Enqueue("skip|$($app.Id)|"); continue
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

function Stop-Tree {
    param([int]$ProcId)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'taskkill.exe'; $psi.Arguments = "/PID $ProcId /T /F"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $k = [System.Diagnostics.Process]::Start($psi); [void]$k.WaitForExit(5000)
    } catch { }
}

# Overall bar = finished apps + how far the running app is (real download % when winget reports it, otherwise a smooth estimate)
$script:AppFrac   = 0.0
$script:AppActive = $false
$script:Mode      = 'install'
function Update-Bar {
    $r = $script:Res
    if (-not $r -or $r.total -lt 1) { return }
    $v = 100.0 * ($r.done + $script:AppFrac) / $r.total
    if ($v -gt 100) { $v = 100 }
    if ($v -gt $script:pbar.Value) { $script:pbar.Value = $v }
}

# ---- Detect programs that are already installed on this PC ---------------------------
$script:InstalledIds = @{}
$script:ScanBusy = $false
$scanWorker = {
    param($apps, $result)
    $found = New-Object 'System.Collections.Generic.List[string]'
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        $text = ''
        try { $text = (& winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-String) } catch { }

        # names of everything registered in "Programs and Features" (machine + current user)
        $names = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            try {
                foreach ($it in @(Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue)) {
                    if ($it.DisplayName) { [void]$names.Add((([string]$it.DisplayName).ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '')) }
                }
            } catch { }
        }

        foreach ($a in $apps) {
            $hit = $false
            if ($text) {
                $rx = '(?i)(?<![\w\.\-])' + [regex]::Escape($a.Id) + '(?:\.(?:x86|x64|arm64))?(?![\w\.\-])'
                if ($text -match $rx) { $hit = $true }
            }
            if (-not $hit) {
                $nm = ([string]$a.Name).ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', ''
                if ($nm.Length -ge 3) {
                    if ($names.Contains($nm)) { $hit = $true }
                    elseif ($a.Source -eq 'nvapp') {
                        # NVIDIA App is not in winget; its Programs-and-Features entry may carry a version/suffix
                        foreach ($n in $names) { if ($n.StartsWith('nvidiaapp')) { $hit = $true; break } }
                    }
                    else {
                        # "AppName 1.2.3" -> name followed only by a version number
                        foreach ($n in $names) { if ($n.StartsWith($nm) -and ($n.Substring($nm.Length) -match '^\d+$')) { $hit = $true; break } }
                    }
                }
            }
            if ($hit) { $found.Add($a.Id) }
        }
    }
    catch { }
    finally {
        $result.Ids  = $found.ToArray()
        $result.Done = $true
    }
}

function Mark-Installed {
    foreach ($a in $script:Apps) {
        if ($script:InstalledIds.ContainsKey($a.Id) -and (-not $a.StatusKey)) { Set-Status $a 'st_installed' }
    }
}

function Start-InstalledScan {
    if ($script:ScanBusy) { return }
    $script:ScanBusy = $true
    Write-Log $script:T.scanStart
    $script:ScanResult = [hashtable]::Synchronized(@{ Done = $false; Ids = @() })
    $list = @($script:Apps | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.NameEn; Source = $_.Source } })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($scanWorker).AddArgument($list).AddArgument($script:ScanResult)
    $script:ScanHandle = $ps.BeginInvoke()
    $script:ScanPs = $ps
    $script:ScanRs = $rs
    $script:ScanTimer.Start()
}

function Finish-InstalledScan {
    $script:ScanTimer.Stop()
    $set = @{}
    foreach ($i in @($script:ScanResult.Ids)) { $set[[string]$i] = $true }
    $script:InstalledIds = $set
    Mark-Installed
    Update-InstalledCount
    Update-Selection
    if ($script:Cat -eq 'Installed') { Refresh-Grid }
    Write-Log ($script:T.scanDone -f $set.Count)
    try { $script:ScanPs.EndInvoke($script:ScanHandle) } catch { }
    try { $script:ScanPs.Dispose(); $script:ScanRs.Dispose() } catch { }
    $script:ScanBusy = $false
}

function Finish-Install {
    $script:InstallTimer.Stop()
    $script:Busy = $false
    $script:btnCancel.Visibility = 'Collapsed'
    $script:btnCancel.IsEnabled = $true
    $r = $script:Res
    if ($script:Mode -eq 'upgradeall') {
        if ($r.cancel -gt 0) { $summary = $script:T.upCancelled }
        elseif ($r.fail -gt 0) { $summary = $script:T.upFailed }
        elseif ($r.ok -gt 0) { $summary = $script:T.upDone -f $r.ok }
        elseif ($r.already -gt 0) { $summary = $script:T.upNone }
        else { $summary = $script:T.upFinished }
    }
    elseif ($script:Mode -eq 'uninstall') { $summary = $script:T.finishedUninst -f $r.ok, $r.fail, $r.cancel }
    else { $summary = $script:T.finished -f $r.ok, $r.already, $r.fail, $r.cancel, $r.manual }
    $script:AppActive = $false
    $script:AppFrac = 0.0
    $script:txtProgress.Text = $summary
    Write-Log $summary
    if ($r.fail -gt 0) { Set-LogVisible $true }
    try { $script:WorkerPs.EndInvoke($script:WorkerHandle) } catch { }
    try { $script:WorkerPs.Dispose(); $script:WorkerRs.Dispose() } catch { }
    Update-Selection
    $icon = 'Information'; if ($r.fail -gt 0) { $icon = 'Warning' }
    $script:FinishMsg = @{ Text = $summary; Icon = $icon }
    if ($script:Sync -and $script:Sync.Cancel) {
        # stopped by the user: clear the bar right away
        $script:pbar.Value = 0
        [void](Show-Msg $summary $script:T.title 'OK' $icon)
    }
    else {
        # show a full bar for a moment, then reset it to 0% and show the summary
        $script:pbar.Value = 100
        $script:ResetTimer.Start()
    }
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
                $script:AppFrac = 0.0; $script:AppActive = $true
                if ($script:Mode -eq 'uninstall') {
                    Set-Status $item 'st_uninstalling'
                    $script:txtProgress.Text = ($script:T.uninstNow -f $item.DisplayName, ($r.done + 1), $r.total)
                }
                else {
                    Set-Status $item 'st_installing'
                    $script:txtProgress.Text = ($script:T.installingNow -f $item.DisplayName, ($r.done + 1), $r.total)
                }
                Write-Log ('>> ' + $item.NameEn + '  (' + $id + ')')
            }
            'manual' {
                Set-Status $item 'st_manual'
                $r.manual++; $r.done++
                $script:AppActive = $false; $script:AppFrac = 0.0; Update-Bar
                Write-Log ($script:T.manualLog -f $id)
                Clear-Finished $item
            }
            'prog' {
                try {
                    $f = [double]::Parse($txt, [Globalization.CultureInfo]::InvariantCulture)
                    if ((0.8 * $f) -gt $script:AppFrac) { $script:AppFrac = 0.8 * $f }
                } catch { }
            }
            'ustart' {
                $script:AppFrac = 0.0; $script:AppActive = $true
                $script:txtProgress.Text = $script:T.upgradingNow
            }
            'upprog' {
                try {
                    $f = [double]::Parse($txt, [Globalization.CultureInfo]::InvariantCulture)
                    if ((0.95 * $f) -gt $script:AppFrac) { $script:AppFrac = 0.95 * $f }
                } catch { }
            }
            'upcount' { try { $r.ok = [int]$txt } catch { } }
            'shortcut' { Write-Log ($script:T.shortcutLog -f $txt) }
            'log' { Write-Log ('     ' + $txt) -Plain }
            'skip' {
                # cancelled: no badge on the card (back to its normal state, or "Installed" if it was already on the PC)
                if ($item) { if ($script:InstalledIds.ContainsKey($item.Id)) { Set-Status $item 'st_installed' } else { Set-Status $item '' } }
                $r.cancel++; $r.done++
                $script:AppActive = $false; $script:AppFrac = 0.0; Update-Bar
            }
            'done' {
                $code = [int]$txt
                if ($script:Mode -eq 'upgradeall') {
                    if ($code -eq 0) { }
                    elseif ($code -eq -1978335189) { $r.already++ }
                    elseif ($code -eq -999) { $r.cancel++ }
                    else { $r.fail++ }
                    $r.done++
                    $script:AppActive = $false; $script:AppFrac = 1.0; Update-Bar
                }
                elseif ($script:Mode -eq 'uninstall') {
                    if (@(0, 3010, -1978334967) -contains $code) {
                        Set-Status $item 'st_removed'; $r.ok++
                        Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' - removed')
                        Set-InstalledFlag $item.Id $false
                    }
                    else {
                        Set-Status $item 'st_failed'; $r.fail++
                        Write-Log ([string][char]0x2716 + ' ' + $item.NameEn + ' - ' + ($script:T.failedCode -f $code))
                    }
                    $r.done++
                    $script:AppActive = $false; $script:AppFrac = 0.0; Update-Bar
                    if ($item -and $item.StatusKey -eq 'st_removed') { Clear-Finished $item }
                }
                else {
                switch ($code) {
                    0            { Set-Status $item 'st_done';    $r.ok++;      Write-Log ([string][char]0x2714 + ' ' + $item.NameEn) }
                    -1978335135  { Set-Status $item 'st_already'; $r.already++; Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' (already installed)') }
                    -1978335189  { Set-Status $item 'st_already'; $r.already++; Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' (already up to date)') }
                    -1978334967  { Set-Status $item 'st_done';    $r.ok++;      Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' - ' + $script:T.reboot) }
                    3010         { Set-Status $item 'st_done';    $r.ok++;      Write-Log ([string][char]0x2714 + ' ' + $item.NameEn + ' - ' + $script:T.reboot) }
                    default      { Set-Status $item 'st_failed';  $r.fail++;    Write-Log ([string][char]0x2716 + ' ' + $item.NameEn + ' - ' + ($script:T.failedCode -f $code)) }
                }
                $r.done++
                $script:AppActive = $false; $script:AppFrac = 0.0; Update-Bar
                # installed / already installed -> remove it from the selected list (failed ones stay so you can retry)
                if ($item -and ($item.StatusKey -eq 'st_done' -or $item.StatusKey -eq 'st_already')) { Set-InstalledFlag $item.Id $true; Clear-Finished $item }
                }
            }
            'finished' { Finish-Install }
        }
    }
    # smooth movement while an app is installing (never goes backwards, never reaches the next app's share)
    if ($script:Busy -and $script:AppActive) {
        $k = 0.012; if ($script:Mode -eq 'upgradeall') { $k = 0.003 }
        $script:AppFrac += (0.95 - $script:AppFrac) * $k
        Update-Bar
    }
}

function Start-Work {
    param([string]$Mode, $Sel)
    $script:Mode = $Mode
    $script:Busy = $true
    $total = 1
    if ($Mode -ne 'upgradeall') { $total = @($Sel).Count }
    $script:Res = @{ ok = 0; already = 0; fail = 0; cancel = 0; manual = 0; done = 0; total = $total }
    $script:ResetTimer.Stop()
    $script:AppFrac = 0.0; $script:AppActive = $false
    $script:pbar.Value = 0
    $script:btnInstall.IsEnabled = $false
    $script:btnUninstall.IsEnabled = $false
    $script:btnUpgrade.IsEnabled = $false
    $script:btnCancel.Visibility = 'Visible'
    if ($Mode -ne 'upgradeall') { foreach ($a in $Sel) { Set-Status $a 'st_queued' } }
    if ($Mode -eq 'install') { Write-Log ($script:T.startLog -f $total) }
    elseif ($Mode -eq 'uninstall') { Write-Log ($script:T.startUninst -f $total) }
    else { Write-Log $script:T.startUpgrade; $script:txtProgress.Text = $script:T.upgradingNow }

    $script:Sync = [hashtable]::Synchronized(@{ Cancel = $false; Proc = $null })
    $script:Sync.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

    $list = @()
    if ($Mode -ne 'upgradeall') { $list = @($Sel | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.NameEn; Source = $_.Source } }) }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker).AddArgument($script:Sync).AddArgument($list).AddArgument([Environment]::GetFolderPath('Desktop')).AddArgument($Mode)
    $script:WorkerHandle = $ps.BeginInvoke()
    $script:WorkerPs = $ps
    $script:WorkerRs = $rs
    $script:InstallTimer.Start()
}

function Start-Install {
    $sel = @($script:Apps | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { [void](Show-Msg $script:T.noSel); return }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [void](Show-Msg $script:T.noWinget $script:T.title 'OK' 'Error'); return
    }
    $answer = Show-Msg ($script:T.confirmMsg -f $sel.Count) $script:T.confirmTitle 'YesNo' 'Question'
    if ($answer -ne 'Yes') { return }
    Start-Work 'install' $sel
}

function Start-Uninstall {
    $sel = @($script:Apps | Where-Object { $_.IsSelected -and $script:InstalledIds.ContainsKey($_.Id) })
    if ($sel.Count -eq 0) { [void](Show-Msg $script:T.noInstalledSel); return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [void](Show-Msg $script:T.noWinget $script:T.title 'OK' 'Error'); return
    }
    $answer = Show-Msg ($script:T.confirmUninst -f $sel.Count) $script:T.confirmUninstTitle 'YesNo' 'Warning'
    if ($answer -ne 'Yes') { return }
    Start-Work 'uninstall' $sel
}

function Start-UpgradeAll {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [void](Show-Msg $script:T.noWinget $script:T.title 'OK' 'Error'); return
    }
    $answer = Show-Msg $script:T.confirmUpgrade $script:T.confirmUpgradeTitle 'YesNo' 'Question'
    if ($answer -ne 'Yes') { return }
    Start-Work 'upgradeall' @()
}

# ----------------------------------------------------------------------------
# 9. Events
# ----------------------------------------------------------------------------
$script:InstallTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:InstallTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:InstallTimer.Add_Tick({ Process-Queue })

$script:ResetTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ResetTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$script:ResetTimer.Add_Tick({
        $script:ResetTimer.Stop()
        if ($script:Busy) { return }          # a new installation already started
        $script:pbar.Value = 0                # bar goes back to 0%
        if ($script:FinishMsg) {
            $m = $script:FinishMsg; $script:FinishMsg = $null
            [void](Show-Msg $m.Text $script:T.title 'OK' $m.Icon)
        }
    })

$script:ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ScanTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:ScanTimer.Add_Tick({ if ($script:ScanResult.Done) { Finish-InstalledScan } })

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

# keep the caret at the start of the box while it is empty
$txtSearch.Add_GotKeyboardFocus({
        if ($script:txtSearch.Text.Length -eq 0) {
            $script:txtSearch.Dispatcher.BeginInvoke([Action]{ $script:txtSearch.CaretIndex = 0; $script:txtSearch.ScrollToHome() }, [System.Windows.Threading.DispatcherPriority]::Input) | Out-Null
        }
    })
$txtSearch.Add_PreviewMouseLeftButtonUp({
        if ($script:txtSearch.Text.Length -eq 0) { $script:txtSearch.CaretIndex = 0 }
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
$btnUninstall.Add_Click({ Start-Uninstall })
$btnUpgrade.Add_Click({ Start-UpgradeAll })

# Ctrl+F jumps to the search box
$window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $script:txtSearch.Focus() | Out-Null; $script:txtSearch.SelectAll(); $e.Handled = $true
        }
    })

$btnCancel.Add_Click({
        if ($script:Sync) {
            $script:Sync.Cancel = $true
            # kill the running winget / installer right now (and everything it started)
            try { $pr = $script:Sync.Proc; if ($pr -and -not $pr.HasExited) { Stop-Tree $pr.Id } } catch { }
        }
        $script:btnCancel.IsEnabled = $false
        Write-Log $script:T.cancelling
    })

# ----------------------------------------------------------------------------
# 9b. Self-update from GitHub Releases
# ----------------------------------------------------------------------------
$script:UpdateInfo = $null

function ConvertTo-VersionObject {
    param([string]$Text)
    try {
        $m = [regex]::Match($Text, '\d+(\.\d+){0,3}')
        if (-not $m.Success) { return $null }
        $v = $m.Value
        while (($v -split '\.').Count -lt 4) { $v += '.0' }
        return [version]$v
    }
    catch { return $null }
}

function Format-ReleaseNotes {
    param([string]$Md)
    if ([string]::IsNullOrWhiteSpace($Md)) { return $script:T.updNoNotes }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Md -split "`r?`n")) {
        $l = $raw.TrimEnd()
        if ($l -match '^\s*\*\*Full Changelog\*\*') { continue }
        if ($l -match '^\s*[-*+]\s+(.*)$') { $l = [string][char]0x2022 + ' ' + $Matches[1] }
        $l = $l -replace '^\s*#{1,6}\s*', ''
        $l = $l -replace '\*\*|__|`', ''
        $out.Add($l)
    }
    $txt = ((($out -join "`n") -replace "(\n){3,}", "`n`n")).Trim()
    if ($txt.Length -gt 1500) { $txt = $txt.Substring(0, 1500).TrimEnd() + '...' }
    if (-not $txt) { return $script:T.updNoNotes }
    return $txt
}

function Start-UpdateCheck {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($repo)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $ProgressPreference = 'SilentlyContinue'
                $h = @{ 'User-Agent' = 'MeshalBox-Updater'; 'Accept' = 'application/vnd.github+json' }
                $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $h -TimeoutSec 12
                $a = @($r.assets | Where-Object { $_.name -eq 'MeshalBox.exe' }) | Select-Object -First 1
                $url = ''; $size = [long]0; $dig = ''
                if ($a) { $url = [string]$a.browser_download_url; $size = [long]$a.size; if ($a.digest) { $dig = [string]$a.digest } }
                [pscustomobject]@{ Ok = $true; Tag = [string]$r.tag_name; Notes = [string]$r.body; Page = [string]$r.html_url; Url = $url; Size = $size; Digest = $dig }
            }
            catch { [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
        }).AddArgument($script:UpdateRepo)
    $script:UpdCheck = @{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Ticks = 0 }

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:UpdCheckTimer = $t
    $t.Add_Tick({
            $c = $script:UpdCheck
            $c.Ticks++
            if (-not $c.Handle.IsCompleted -and $c.Ticks -lt 80) { return }
            $script:UpdCheckTimer.Stop()
            $res = $null
            try { if ($c.Handle.IsCompleted) { $res = @($c.Ps.EndInvoke($c.Handle)) | Select-Object -First 1 } } catch { }
            try { $c.Ps.Dispose(); $c.Rs.Dispose() } catch { }
            if ($res -and $res.Ok) {
                $remote = ConvertTo-VersionObject $res.Tag
                $local  = ConvertTo-VersionObject $script:AppVersion
                if ($remote -and $local -and $remote -gt $local) {
                    $script:UpdateInfo = $res
                    $script:btnUpdate.Visibility = 'Visible'
                    Write-Log ($script:T.updHead + ' ' + $res.Tag)
                }
            }
        })
    $t.Start()
}

function Start-UpdateDownload {
    param($U)
    $script:Busy = $true
    Update-Selection
    $script:btnUpdate.IsEnabled = $false
    $script:txtProgress.Text = $script:T.updDownloading

    $dir  = Join-Path ([IO.Path]::GetTempPath()) 'MeshalBox_update'
    $dest = Join-Path $dir 'MeshalBox_new.exe'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($url, $dir, $dest)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $ProgressPreference = 'SilentlyContinue'
                if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                if (Test-Path $dest) { Remove-Item $dest -Force }
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -Headers @{ 'User-Agent' = 'MeshalBox-Updater' } -TimeoutSec 300
                [pscustomobject]@{ Ok = $true }
            }
            catch { [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
        }).AddArgument($U.Url).AddArgument($dir).AddArgument($dest)
    $script:UpdDl = @{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Dest = $dest; Dir = $dir; Info = $U }

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:UpdDlTimer = $t
    $t.Add_Tick({
            $d = $script:UpdDl
            if (-not $d.Handle.IsCompleted) { return }
            $script:UpdDlTimer.Stop()
            $res = $null
            try { $res = @($d.Ps.EndInvoke($d.Handle)) | Select-Object -First 1 } catch { }
            try { $d.Ps.Dispose(); $d.Rs.Dispose() } catch { }

            $err = ''
            if (-not $res -or -not $res.Ok) { if ($res) { $err = $res.Error } else { $err = 'download failed' } }
            else {
                try {
                    $f = Get-Item -LiteralPath $d.Dest -ErrorAction Stop
                    if ($f.Length -lt 50000) { $err = 'file too small' }
                    elseif ($d.Info.Size -gt 0 -and $f.Length -ne $d.Info.Size) { $err = 'size mismatch' }
                    else {
                        $head = New-Object byte[] 2
                        $fs = [IO.File]::OpenRead($d.Dest); try { [void]$fs.Read($head, 0, 2) } finally { $fs.Dispose() }
                        if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { $err = 'not an executable file' }
                    }
                    if (-not $err -and $d.Info.Digest -match '^sha256:([0-9a-fA-F]{64})$') {
                        $hash = (Get-FileHash -LiteralPath $d.Dest -Algorithm SHA256).Hash
                        if ($hash -ne $Matches[1]) { $err = 'checksum mismatch' }
                    }
                }
                catch { $err = $_.Exception.Message }
            }

            if ($err) {
                try { Remove-Item -LiteralPath $d.Dest -Force -ErrorAction SilentlyContinue } catch { }
                $script:Busy = $false
                Update-Selection
                $script:btnUpdate.IsEnabled = $true
                $script:txtProgress.Text = $script:T.ready
                [void](Show-Msg ($script:T.updFail -f "`n", $err) $script:T.updTitle 'OK' 'Error')
                return
            }
            Apply-Update $d.Dest $d.Dir
        })
    $t.Start()
}

function Apply-Update {
    param([string]$NewExe, [string]$Dir)
    try {
        $self = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $bat  = Join-Path $Dir 'apply_update.cmd'
        $lines = @(
            '@echo off',
            'chcp 65001 >nul',
            ('set "NEW={0}"' -f $NewExe),
            ('set "OLD={0}"' -f $self),
            'set /a N=0',
            ':retry',
            'move /y "%NEW%" "%OLD%" >nul 2>&1',
            'if not errorlevel 1 goto done',
            'set /a N+=1',
            'if %N% GEQ 40 goto done',
            'ping -n 2 127.0.0.1 >nul',
            'goto retry',
            ':done',
            'start "" "%OLD%"',
            '(goto) 2>nul & del "%~f0"'
        )
        [IO.File]::WriteAllText($bat, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""{0}""' -f $bat) -WindowStyle Hidden
        $script:Busy = $false
        $window.Close()
    }
    catch {
        $script:Busy = $false
        Update-Selection
        $script:btnUpdate.IsEnabled = $true
        $script:txtProgress.Text = $script:T.ready
        [void](Show-Msg ($script:T.updFail -f "`n", $_.Exception.Message) $script:T.updTitle 'OK' 'Error')
    }
}

function Invoke-UpdateClick {
    $u = $script:UpdateInfo
    if (-not $u) { return }
    if ($script:Busy) { [void](Show-Msg $script:T.updBusy $script:T.updTitle 'OK' 'Information'); return }

    $canAuto = $script:IsCompiledExe -and $u.Url -and ($u.Url -like ('https://github.com/{0}/releases/download/*' -f $script:UpdateRepo))
    if ($canAuto) { $ask = $script:T.updAsk } else { $ask = $script:T.updAskSrc }
    $newVer = $u.Tag -replace '^[vV]', ''
    $msg = $script:T.updHead + "`n`n" + ($script:T.updVer -f $script:AppVersion, $newVer) + "`n`n" +
    $script:T.updNotes + "`n" + (Format-ReleaseNotes $u.Notes) + "`n`n" + $ask
    $ans = Show-Msg $msg $script:T.updTitle 'YesNo' 'Question'
    if ($ans -ne 'Yes') { return }

    if ($canAuto) { Start-UpdateDownload $u }
    else {
        $page = $u.Page
        if (-not $page) { $page = 'https://github.com/{0}/releases/latest' -f $script:UpdateRepo }
        try { Start-Process $page } catch { }
    }
}

$script:IsCompiledExe = $IsCompiledExe
$script:AppVersion    = $AppVersion
$script:UpdateRepo    = $UpdateRepo
$script:btnUpdate.Add_Click({ Invoke-UpdateClick })

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
            Start-InstalledScan
            $wg = Get-Command winget -ErrorAction SilentlyContinue
            if ($wg) { Write-Log ($script:T.wingetOk -f $wg.Source) } else { Write-Log $script:T.noWinget }
            if (-not $script:IsAdminNow) { Write-Log $script:T.adminWarn }
            try { Start-UpdateCheck } catch { }
        })

    [void]$window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Fatal error:`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)", 'MeshalBox', 'OK', 'Error')
}
