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
    (The dark / light theme is switched with the theme button in the header and is remembered.)

.PARAMETER AppsFile
    Path to the applications catalog (default: applications.json next to the script).

.PARAMETER NoElevate
    Do not try to relaunch as Administrator.

.PARAMETER NoUpdateCheck
    Skip the "new version" check (used by the one-line launcher install.ps1, which always fetches the latest files).

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
    [switch]$NoUpdateCheck,
    [string]$AppsFile = ''
)

$ErrorActionPreference = 'Stop'

# These placeholders are filled in by build.bat when compiling the portable EXE
# (the catalog is embedded and the self-relaunch is skipped; the EXE asks for admin itself).
$IsCompiledExe       = '__IS_EXE__' -eq 'yes'
$EmbeddedCatalogB64  = '__EMBED_CATALOG__'
$EmbeddedLogosB64    = '__EMBED_LOGOS__'     # zip of logos\*.png, embedded by build.bat
# Apps whose logo tile is always black (or white) no matter what the automatic check says
$TileOverride = @{ 'Valve.Steam' = 'black' }

# Self-update (GitHub Releases). Bump $AppVersion on every release - build.bat reads it for the EXE version.
$AppVersion = '1.0.0'
$UpdateRepo = 'iMeshall/MeshalBox'

# Set to $true to show a small "Preview" tag next to the app name in the header.
$ShowPreviewBadge = $false

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
        if ($NoUpdateCheck) { $argList += ' -NoUpdateCheck' }
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
    # full paths: Add-Type cannot find the WPF assemblies by short name
    $wpfRefs = @('System.dll', 'System.Drawing.dll',
                 [System.Windows.Media.Imaging.BitmapSource].Assembly.Location,
                 [System.Windows.DependencyObject].Assembly.Location)
    Add-Type -Language CSharp -ReferencedAssemblies $wpfRefs -TypeDefinition @'
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
    private string _categoryName;
    public string CategoryName { get { return _categoryName; } set { _categoryName = value; Raise("CategoryName"); } }
    public string Domain { get; set; }
    public string Source { get; set; }
    public bool Lingers { get; set; }        // installer/uninstaller keeps running after it is done (e.g. Riot Client) -> finish by checking the real state
    public string Initial { get; set; }
    public string Color { get; set; }
    public string Pkg { get; set; }          // Microsoft Store package name (the logo is read from the installed package)
    public string IconKey { get; set; }      // cache key of the logo (website domain, or "icon-<name>")
    public string IconHost { get; set; }     // website to take the logo from
    public string IconSlug { get; set; }     // name in the open app-icon sets
    public bool IconExplicit { get; set; }   // icon name given in applications.json (tried first)
    public bool IconMono { get; set; }       // the current logo is black/white/grey -> look for a coloured original
    private string _statusKey;
    public string StatusKey { get { return _statusKey; } set { _statusKey = value; Raise("StatusKey"); } }

    private string _displayName;
    public string DisplayName { get { return _displayName; } set { _displayName = value; Raise("DisplayName"); } }

    private string _status;
    public string Status { get { return _status; } set { _status = value; Raise("Status"); } }

    private bool _isSelected;
    public bool IsSelected { get { return _isSelected; } set { _isSelected = value; Raise("IsSelected"); } }

    private object _icon;
    public object Icon { get { return _icon; } set { _icon = value; UpdateTile(); Raise("Icon"); Raise("HasIcon"); } }
    private string _tileForce = "";          // "black" or "white" = fixed tile colour for this app, "" = decide from the logo
    public string TileForce { get { return _tileForce; } set { _tileForce = value ?? ""; UpdateTile(); } }
    private void UpdateTile()
    {
        if (_tileForce == "black") TileBg = "#000000";
        else if (_tileForce == "white") TileBg = "#FFFFFF";
        else TileBg = MeshalImg.IsDarkLogo(_icon) ? "#FFFFFF" : "#000000";
    }
    private string _tileBg = "#000000";   // black tile behind the logo; white when the logo itself is dark
    public string TileBg { get { return _tileBg; } set { _tileBg = value; Raise("TileBg"); } }
    public bool HasIcon { get { return _icon != null; } }

    private double _iconSize = 32;
    public double IconSize { get { return _iconSize; } set { _iconSize = value; Raise("IconSize"); } }
}

public static class MeshalImg
{
    // true when most of the visible pixels of the logo are dark (it would vanish on a black tile)
    public static bool IsDarkLogo(object o)
    {
        try
        {
            System.Windows.Media.Imaging.BitmapSource src = o as System.Windows.Media.Imaging.BitmapSource;
            if (src == null) return false;
            System.Windows.Media.Imaging.FormatConvertedBitmap fc = new System.Windows.Media.Imaging.FormatConvertedBitmap(src, System.Windows.Media.PixelFormats.Bgra32, null, 0);
            int w = fc.PixelWidth, h = fc.PixelHeight;
            if (w < 1 || h < 1) return false;
            int stride = w * 4;
            byte[] buf = new byte[stride * h];
            fc.CopyPixels(buf, stride, 0);
            int step = Math.Max(1, (int)Math.Sqrt((double)w * h / 4096.0));
            long n = 0, dark = 0;
            for (int y = 0; y < h; y += step)
                for (int x = 0; x < w; x += step)
                {
                    int i = y * stride + x * 4;
                    if (buf[i + 3] < 128) continue;
                    double l = (0.114 * buf[i] + 0.587 * buf[i + 1] + 0.299 * buf[i + 2]) / 255.0;
                    int mx = Math.Max(buf[i], Math.Max(buf[i + 1], buf[i + 2])), mn = Math.Min(buf[i], Math.Min(buf[i + 1], buf[i + 2]));
                    n++;
                    // vanishes on a black tile: nearly black, or dark AND grey. Dark but coloured (purple, navy...) stays visible.
                    if (l < 0.12 || (l < 0.30 && (mx - mn) < 35)) dark++;
                }
            return n >= 10 && dark * 100 > n * 60;
        }
        catch { return false; }
    }

    // Share of the visible (non-white, non-black) pixels that carry real colour. ~0 = black/white/grey logo, > 0.15 = coloured logo.
    public static double Colorfulness(byte[] data)
    {
        using (System.IO.MemoryStream ms = new System.IO.MemoryStream(data)) return Colorfulness(ms);
    }
    public static double Colorfulness(string path)
    {
        using (System.IO.FileStream fs = System.IO.File.OpenRead(path)) return Colorfulness(fs);
    }
    public static double Colorfulness(System.IO.Stream st)
    {
        using (System.Drawing.Image src = System.Drawing.Image.FromStream(st, false, false))
        using (System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(64, 64, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
        {
            using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(src, 0, 0, 64, 64);
            }
            int n = 0, c = 0;
            for (int y = 0; y < 64; y++)
                for (int x = 0; x < 64; x++)
                {
                    System.Drawing.Color px = bmp.GetPixel(x, y);
                    if (px.A < 128) continue;
                    float b = px.GetBrightness();
                    if (b < 0.12f || b > 0.93f) continue;
                    n++;
                    if (px.GetSaturation() > 0.35f) c++;
                }
            return n < 20 ? 0.0 : (double)c / n;
        }
    }

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

public class MeshalRow
{
    public string Key { get; set; }
    public string Desc { get; set; }
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

        int caption = dark ? ToColorRef(0x09, 0x09, 0x0B) : ToColorRef(0xF6, 0xF6, 0xF7);   // = window background
        int text    = dark ? ToColorRef(0xE6, 0xE6, 0xE9) : ToColorRef(0x11, 0x11, 0x14);   // title text
        int border  = dark ? ToColorRef(0x1C, 0x1C, 0x21) : ToColorRef(0xE4, 0xE4, 0xE7);   // = panel borders
        DwmSetWindowAttribute(hwnd, 35, ref caption, 4);  // DWMWA_CAPTION_COLOR (Win11)
        DwmSetWindowAttribute(hwnd, 36, ref text, 4);     // DWMWA_TEXT_COLOR    (Win11)
        DwmSetWindowAttribute(hwnd, 34, ref border, 4);   // DWMWA_BORDER_COLOR  (Win11)
    }

    private static int HexRef(string h)
    {
        h = h.TrimStart('#');
        return ToColorRef(Convert.ToInt32(h.Substring(0, 2), 16), Convert.ToInt32(h.Substring(2, 2), 16), Convert.ToInt32(h.Substring(4, 2), 16));
    }

    // same as above, but the title bar + window border follow the colour palette
    public static void Apply(IntPtr hwnd, bool dark, string captionHex, string borderHex)
    {
        Apply(hwnd, dark);
        try
        {
            int caption = HexRef(captionHex), border = HexRef(borderHex);
            DwmSetWindowAttribute(hwnd, 35, ref caption, 4);
            DwmSetWindowAttribute(hwnd, 34, ref border, 4);
        }
        catch { }
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
        appearance    = 'APPEARANCE'
        modeDark      = 'Dark'
        modeLight     = 'Light'
        atmosphere    = 'COLORS'
        refreshTip    = 'Rescan this PC'
        preview       = 'Preview'
        menuExport    = 'Export selection'
        menuImport    = 'Import selection'
        menuRescan    = 'Rescan this PC'
        menuShortcuts = 'Keyboard shortcuts'
        menuAbout     = 'About'
        moreTip       = 'More'
        viewGrid      = 'Grid view'
        viewList      = 'List view'
        shortcutsText = "Ctrl+K  /  Ctrl+F    Search`nEsc    Clear the search`nF5    Rescan installed apps`nCtrl+S    Export selection`nCtrl+O    Import selection"
        aboutText     = "MeshalBox  v{0}`nInstall many programs in one go, using winget.`n`nhttps://github.com/{1}"
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
        clearAll      = 'Clear'
        clearSel      = 'Clear selection'
        clearSearch   = 'Clear search'
        install       = 'Install'
        installNone   = 'Install apps'
        allInstalled  = 'all already installed'
        selectedNone  = 'No apps selected. Click a card to select it.'
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
        uninstallBtn  = 'Uninstall'
        st_uninstalling = [string][char]0x2715 + ' Removing...'
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
        st_queued     = [string][char]0x25CB + ' Queued'
        st_installing = [string][char]0x2B07 + ' Installing...'
        st_done       = [string][char]0x2714 + ' Installed'
        st_already    = [string][char]0x2714 + ' Already installed'
        st_installed  = [string][char]0x2714 + ' Installed'
        st_failed     = [string][char]0x2716 + ' Failed'
        st_cancelled  = [string][char]0x25A0 + ' Cancelled'
        st_manual     = [string][char]0x2197 + ' Download page opened'
        noSel         = 'Please select at least one app.'
        confirmTitle  = 'Confirm installation'
        confirmMsg    = '{0} app(s) will be installed. Continue?'
        confirmMore   = '...and {0} more'
        tipInstallNone   = 'Select at least one app to enable installation.'
        tipUninstallNone = 'Select apps that show the green "Installed" badge to enable removal.'
        emptyHint     = 'Try another name, or press Esc to clear the search.'
        emptySelected = 'Nothing selected yet. Click any app card and it will appear here.'
        emptyInstalled = 'None of the catalog apps were detected on this PC. Press F5 to re-scan.'
        catSkipped    = 'Skipped {0} invalid entries in applications.json.'
        exportTitle   = 'Save selection'
        importTitle   = 'Load selection'
        exportDone    = 'Saved {0} to: {1}'
        importDone    = 'Selected {0} from the file.'
        importMiss    = 'Selected {0} from the file. {1} not found in the catalog.'
        importFail    = 'Could not read that file. Use a selection file saved by MeshalBox.'
        exportNone    = 'Nothing is selected yet - tick some apps first.'
        noWinget      = 'winget was not found. Install "App Installer" from the Microsoft Store, then try again.'
        adminWarn     = 'Note: not running as Administrator. You may see extra permission prompts during installs.'
        wingetOk      = 'winget detected: {0}'
        startLog      = 'Starting installation of {0} app(s)...'
        finished      = 'Finished: {0} installed, {1} already installed, {2} failed, {3} cancelled, {4} opened for manual install.'
        manualLog     = 'Not available in winget - official download page opened: {0}'
        cancelling    = 'Stopping the installation...'
        scanStart     = 'Checking which apps are installed...'
        scanDone      = 'Detected {0} installed app(s).'
        busyClose     = 'An installation is running. Stop it first, then close the window.'
        installingNow = 'Installing: {0}  ({1}/{2})'
        reboot        = 'A restart may be required.'
        failedCode    = 'Failed (exit code {0})'
        logTitle      = 'Log'
        shortcutLog   = 'Desktop shortcut created: {0}'
        logosLog      = 'Logos loaded: {0} of {1}. Without logo:'
        undo          = 'Undo'
        dismiss       = 'Dismiss'
        showLog       = 'Show log'
        clearedN      = 'Cleared the selection ({0})'
        btnCancel2    = 'Cancel'
        btnClose      = 'Close'
        noWingetAct   = 'Get App Installer'
        dlgInstallTitle = 'Install {0}?'
        dlgInstallBody  = 'They install one after another. You can stop at any time.'
        btnInstallN   = 'Install {0}'
        dlgUninstTitle  = 'Uninstall {0}?'
        dlgUninstBody   = 'This removes them from this PC. You can install them again later.'
        btnUninstN    = 'Uninstall {0}'
        dlgUpgTitle   = 'Upgrade all apps?'
        dlgUpgBody    = 'Every app on this PC that has an update will be upgraded, including apps that are not in MeshalBox.'
        btnUpgAll     = 'Upgrade all'
        updNow        = 'Update and restart'
        updLater      = 'Not now'
        updOpen       = 'Open download page'
        closeTitle    = 'Installation in progress'
        closeBody     = 'Closing now stops it, and the app being installed right now may be left incomplete.'
        btnKeep       = 'Keep going'
        btnStopClose  = 'Stop and close'
        closeUpdTitle = 'Update in progress'
        closeUpd      = 'The update is downloading. Wait a moment, then close the window.'
        aboutVersion  = 'Version {0}'
        aboutDesc     = 'Install many programs in one go, using winget.'
        aboutOpen     = 'Open GitHub page'
        shortcutRows  = @('Ctrl+K / Ctrl+F|Search apps', 'Esc|Clear the search, or close a menu', 'F5|Rescan this PC', 'Ctrl+S|Export selection', 'Ctrl+O|Import selection', 'Tab|Jump between sidebar, apps and actions', 'Arrow keys|Move between apps', 'Space|Select or unselect the focused app')
        emptyNoMatch  = 'No apps match "{0}"'
        emptyInCat    = 'Searching only in {0}.'
        emptyTip      = 'Check the spelling or try a shorter name.'
        actSearchAll  = 'Search all apps'
        emptySel2     = 'Nothing selected yet'
        emptySelHint  = 'Click an app card to add it here.'
        actBrowse     = 'Browse all apps'
        emptyScan     = 'Checking this PC...'
        emptyScanHint = 'Installed apps will appear here in a moment.'
        emptyInst     = 'No MeshalBox apps found on this PC'
        emptyInstHint = 'Install some, or rescan if you installed something recently.'
        actRescan     = 'Rescan this PC'
        resInstalled  = '{0} installed'
        resAlready    = '{0} already installed'
        resFailed     = '{0} failed'
        resCancelled  = '{0} cancelled'
        resManual     = '{0} opened for manual install'
        resRemoved    = '{0} removed'
    }
    ar = @{
        title         = 'MeshalBox'
        subtitle      = 'ثبّت عدة برامج دفعة واحدة'
        search        = 'ابحث عن برنامج...'
        langBtn       = 'English'
        themeToLight  = 'التبديل إلى الوضع الفاتح'
        themeToDark   = 'التبديل إلى الوضع الداكن'
        appearance    = 'المظهر'
        modeDark      = 'داكن'
        modeLight     = 'فاتح'
        atmosphere    = 'الألوان'
        refreshTip    = 'إعادة فحص الجهاز'
        preview       = 'معاينة'
        menuExport    = 'تصدير التحديد'
        menuImport    = 'استيراد التحديد'
        menuRescan    = 'إعادة فحص الجهاز'
        menuShortcuts = 'اختصارات لوحة المفاتيح'
        menuAbout     = 'حول البرنامج'
        moreTip       = 'المزيد'
        viewGrid      = 'عرض شبكي'
        viewList      = 'عرض قائمة'
        shortcutsText = "Ctrl+K  /  Ctrl+F    بحث`nEsc    مسح البحث`nF5    إعادة فحص البرامج المثبّتة`nCtrl+S    تصدير التحديد`nCtrl+O    استيراد التحديد"
        aboutText     = "MeshalBox  v{0}`nثبّت عدة برامج دفعة واحدة باستخدام winget.`n`nhttps://github.com/{1}"
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
        clearAll      = 'مسح'
        clearSel      = 'إلغاء التحديد'
        clearSearch   = 'مسح البحث'
        install       = 'تثبيت'
        installNone   = 'تثبيت البرامج'
        allInstalled  = 'كلها مثبّتة بالفعل'
        selectedNone  = 'لم تحدد أي برنامج. اضغط على بطاقة لتحديدها.'
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
        uninstallBtn  = 'إزالة'
        st_uninstalling = [string][char]0x2715 + ' جارٍ الإزالة...'
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
        st_queued     = [string][char]0x25CB + ' في الانتظار'
        st_installing = [string][char]0x2B07 + ' جارٍ التثبيت...'
        st_done       = [string][char]0x2714 + ' تم التثبيت'
        st_already    = [string][char]0x2714 + ' مثبّت مسبقًا'
        st_installed  = [string][char]0x2714 + ' مثبّت'
        st_failed     = [string][char]0x2716 + ' فشل'
        st_cancelled  = [string][char]0x25A0 + ' أُلغي'
        st_manual     = [string][char]0x2197 + ' فُتحت صفحة التحميل'
        noSel         = 'اختر برنامجًا واحدًا على الأقل.'
        confirmTitle  = 'تأكيد التثبيت'
        confirmMsg    = 'سيتم تثبيت {0} برنامج. هل تريد المتابعة؟'
        confirmMore   = '...و{0} أخرى'
        tipInstallNone   = 'حدّد برنامجًا واحدًا على الأقل لتفعيل التثبيت.'
        tipUninstallNone = 'حدّد برامج عليها علامة "مثبّت" الخضراء لتفعيل الإزالة.'
        emptyHint     = 'جرّب اسمًا آخر، أو اضغط Esc لمسح البحث.'
        emptySelected = 'لم تحدد شيئًا بعد. اضغط على أي بطاقة برنامج لتظهر هنا.'
        emptyInstalled = 'لم يتم رصد أي برنامج من الكتالوج على هذا الجهاز. اضغط F5 لإعادة الفحص.'
        catSkipped    = 'تم تجاهل {0} عنصر غير صالح في ملف applications.json.'
        exportTitle   = 'حفظ التحديد'
        importTitle   = 'تحميل تحديد'
        exportDone    = 'تم حفظ {0} في: {1}'
        importDone    = 'تم تحديد {0} من الملف.'
        importMiss    = 'تم تحديد {0} من الملف. {1} غير موجود في الكتالوج.'
        importFail    = 'تعذّرت قراءة الملف. استخدم ملف تحديد محفوظًا من MeshalBox.'
        exportNone    = 'لم تحدد أي برنامج بعد - حدّد بعض البرامج أولًا.'
        noWinget      = 'لم يتم العثور على winget. ثبّت "App Installer" من متجر Microsoft ثم أعد المحاولة.'
        adminWarn     = 'تنبيه: السكربت لا يعمل بصلاحيات المسؤول، وقد تظهر نوافذ طلب صلاحيات إضافية أثناء التثبيت.'
        wingetOk      = 'تم العثور على winget: {0}'
        startLog      = 'بدء تثبيت {0} برنامج...'
        finished      = 'اكتمل: {0} تم تثبيته، {1} مثبّت مسبقًا، {2} فشل، {3} أُلغي، {4} فُتحت صفحة تحميله للتثبيت اليدوي.'
        manualLog     = 'غير متوفر في winget - تم فتح صفحة التحميل الرسمية: {0}'
        cancelling    = 'جارٍ إيقاف التثبيت...'
        scanStart     = 'جارٍ فحص البرامج المثبّتة...'
        scanDone      = 'تم التعرّف على {0} برنامج مثبّت.'
        busyClose     = 'هناك عملية تثبيت جارية. أوقفها أولًا ثم أغلق النافذة.'
        installingNow = 'جارٍ تثبيت: {0}  ({1}/{2})'
        reboot        = 'قد تحتاج إلى إعادة تشغيل الجهاز.'
        failedCode    = 'فشل (رمز الخروج {0})'
        logTitle      = 'السجل'
        shortcutLog   = 'تم إنشاء اختصار على سطح المكتب: {0}'
        logosLog      = 'الشعارات المحمّلة: {0} من {1}. بدون شعار:'
        undo          = 'تراجع'
        dismiss       = 'إخفاء'
        showLog       = 'عرض السجل'
        clearedN      = 'تم إلغاء التحديد ({0})'
        btnCancel2    = 'إلغاء'
        btnClose      = 'إغلاق'
        noWingetAct   = 'احصل على App Installer'
        dlgInstallTitle = 'تثبيت {0}؟'
        dlgInstallBody  = 'سيتم تثبيتها واحدًا تلو الآخر. يمكنك الإيقاف في أي وقت.'
        btnInstallN   = 'تثبيت {0}'
        dlgUninstTitle  = 'إزالة {0}؟'
        dlgUninstBody   = 'ستُزال من هذا الجهاز. يمكنك تثبيتها مجددًا لاحقًا.'
        btnUninstN    = 'إزالة {0}'
        dlgUpgTitle   = 'تحديث كل البرامج؟'
        dlgUpgBody    = 'سيتم تحديث كل برنامج على هذا الجهاز له تحديث، بما فيها البرامج غير الموجودة في MeshalBox.'
        btnUpgAll     = 'تحديث الكل'
        updNow        = 'تحديث وإعادة فتح'
        updLater      = 'ليس الآن'
        updOpen       = 'فتح صفحة التحميل'
        closeTitle    = 'التثبيت جارٍ'
        closeBody     = 'الإغلاق الآن سيوقفه، وقد يبقى البرنامج الجاري تثبيته غير مكتمل.'
        btnKeep       = 'متابعة العملية'
        btnStopClose  = 'إيقاف وإغلاق'
        closeUpdTitle = 'التحديث جارٍ'
        closeUpd      = 'جارٍ تحميل التحديث. انتظر قليلًا ثم أغلق النافذة.'
        aboutVersion  = 'الإصدار {0}'
        aboutDesc     = 'ثبّت عدة برامج دفعة واحدة باستخدام winget.'
        aboutOpen     = 'فتح صفحة GitHub'
        shortcutRows  = @('Ctrl+K / Ctrl+F|بحث عن برنامج', 'Esc|مسح البحث أو إغلاق قائمة', 'F5|إعادة فحص الجهاز', 'Ctrl+S|تصدير التحديد', 'Ctrl+O|استيراد التحديد', 'Tab|الانتقال بين القائمة الجانبية والبرامج والأزرار', 'مفاتيح الأسهم|التنقل بين البرامج', 'Space|تحديد البرنامج المُركَّز عليه أو إلغاء تحديده')
        emptyNoMatch  = 'لا توجد برامج تطابق "{0}"'
        emptyInCat    = 'البحث داخل «{0}» فقط.'
        emptyTip      = 'تحقق من الإملاء أو جرّب اسمًا أقصر.'
        actSearchAll  = 'ابحث في كل البرامج'
        emptySel2     = 'لم تحدد شيئًا بعد'
        emptySelHint  = 'اضغط على بطاقة برنامج لتظهر هنا.'
        actBrowse     = 'تصفّح كل البرامج'
        emptyScan     = 'جارٍ فحص هذا الجهاز...'
        emptyScanHint = 'ستظهر البرامج المثبّتة هنا بعد لحظات.'
        emptyInst     = 'لم يُعثر على برامج MeshalBox على هذا الجهاز'
        emptyInstHint = 'ثبّت بعضها، أو أعد الفحص إن ثبّتّ شيئًا مؤخرًا.'
        actRescan     = 'إعادة فحص الجهاز'
        resInstalled  = 'تم تثبيت {0}'
        resAlready    = '{0} مثبّت مسبقًا'
        resFailed     = 'فشل {0}'
        resCancelled  = 'أُلغي {0}'
        resManual     = 'فُتحت صفحة تحميل {0}'
        resRemoved    = 'تمت إزالة {0}'
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
    # Monochrome Segoe Fluent / MDL2 icon glyphs (same colour as the text, no coloured emoji)
    All = [string][char]0xE8A9; Selected = [string][char]0xE73E; Installed = [string][char]0xE7B8
    Browsers = [string][char]0xE774; Gaming = [string][char]0xE7FC
    Peripherals = [string][char]0xE765
    Communication = [string][char]0xE8F2; Media = [string][char]0xE714
    Development = [string][char]0xE943; Utilities = [string][char]0xE90F
    Security = [string][char]0xEA18; Productivity = [string][char]0xE8A5
    Design = [string][char]0xE70F; Cloud = [string][char]0xE753
    Runtimes = [string][char]0xE950
    ProTools = [string][char]0xE90F; Microsoft = [string][char]0xE737
    Selfhosted = [string][char]0xEDA2; Store = [string][char]0xE719
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
$script:CatalogSkipped = 0
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
    # Safety: ids are placed into a cmd.exe command line, so only allow winget-style ids (or https links for 'web' entries)
    if ([string]$e.source -eq 'web') { if ([string]$e.id -notmatch '^https://[^\s"&|<>^]+$') { $script:CatalogSkipped++; continue } }
    elseif ([string]$e.id -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-_+]*$') { $script:CatalogSkipped++; continue }
    if ($script:ById.ContainsKey([string]$e.id)) { continue }   # never list the same program twice
    $a = New-Object MeshalApp
    $a.Id = [string]$e.id; $a.NameEn = [string]$e.en
    $a.NameAr = if ($e.ar) { [string]$e.ar } else { [string]$e.en }
    $a.Category = [string]$e.category; $a.Domain = [string]$e.domain
    $a.DescEn = if ($e.desc) { [string]$e.desc } else { '' }
    $a.DescAr = if ($e.descAr) { [string]$e.descAr } else { $a.DescEn }
    $a.Source = if ($e.source) { [string]$e.source } else { '' }
    if ($e.pkg) { $a.Pkg = [string]$e.pkg }
    if ($e.lingers -eq $true) { $a.Lingers = $true }
    if ($TileOverride.ContainsKey($a.Id)) { $a.TileForce = $TileOverride[$a.Id] }
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
$IconCache    = Join-Path $env:LOCALAPPDATA 'MeshalBox\icons_v3'
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

$script:DebugLogFile = Join-Path $SettingsDir 'meshalbox.log'
function Write-DebugLog {
    param([string]$Text)
    try {
        if ((Test-Path $script:DebugLogFile) -and ((Get-Item $script:DebugLogFile).Length -gt 512KB)) { Move-Item $script:DebugLogFile ($script:DebugLogFile + '.old') -Force }
        Add-Content -Path $script:DebugLogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -Encoding UTF8
    } catch { }
}

function Save-Settings {
    try { $v = $script:ViewMode; if (-not $v) { $v = $script:SavedView }; @{ lang = $script:Lang; theme = $script:Theme; palette = $script:Palette; view = $v } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
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

$script:Palette = 'classic'     # default colour palette
try {
    if (Test-Path $SettingsFile) {
        $savedPal = (Get-Content $SettingsFile -Raw | ConvertFrom-Json).palette
        if ($savedPal) { $script:Palette = [string]$savedPal }   # validated in Get-ThemeTable
    }
} catch { }

$script:SavedView = 'grid'
try {
    if (Test-Path $SettingsFile) {
        $sv = (Get-Content $SettingsFile -Raw | ConvertFrom-Json).view
        if ($sv -in @('grid', 'list')) { $script:SavedView = $sv }
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
        FontFamily="Segoe UI Variable Text, Segoe UI" TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>

    <LinearGradientBrush x:Key="AccentBrush" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#2563EB" Offset="0"/>
      <GradientStop Color="#6A48E0" Offset="1"/>
    </LinearGradientBrush>

    <!-- Keyboard-only focus rings (FocusVisualStyle is not shown after a mouse click). FocusRing is theme-aware. -->
    <Style x:Key="FocusRingBtn">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate><Rectangle Margin="-3" RadiusX="13" RadiusY="13" Stroke="{DynamicResource FocusRing}" StrokeThickness="2" IsHitTestVisible="False"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FocusRingCard">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate><Rectangle Margin="4" RadiusX="19" RadiusY="19" Stroke="{DynamicResource FocusRing}" StrokeThickness="2" IsHitTestVisible="False"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

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
            <Border x:Name="t" CornerRadius="2" Background="{DynamicResource ThumbBg}" Margin="2,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="{DynamicResource ThumbHover}"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="{DynamicResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
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
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
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
    <Style x:Key="LangBtn" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="19" Padding="18,7"
                    BorderBrush="{DynamicResource BtnBorder}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,11"/>
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
            <Border x:Name="bd" Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" CornerRadius="10" Padding="0,10,0,10">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource InputBorderHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="bd" Property="Background" Value="{DynamicResource InputBgFocus}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextSec}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Width="28" Height="28" CornerRadius="14" Background="Transparent">
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
              <Border x:Name="bd" CornerRadius="9" Padding="11,7,11,7" Margin="7,0,0,0" Background="Transparent" BorderBrush="Transparent" BorderThickness="1">
                <ContentPresenter/>
              </Border>
              <!-- selected marker: a small bar on the edge that grows in -->
              <Border x:Name="ind" Width="3" Height="20" CornerRadius="2" Background="{DynamicResource Accent}"
                      HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0" Opacity="0" IsHitTestVisible="False"
                      RenderTransformOrigin="0.5,0.5">
                <Border.RenderTransform><ScaleTransform x:Name="indScale" ScaleY="0.3"/></Border.RenderTransform>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource CatHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource CatSelected}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="ind" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="indScale" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="ind" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.10"/>
                      <DoubleAnimation Storyboard.TargetName="indScale" Storyboard.TargetProperty="ScaleY" To="0.3" Duration="0:0:0.10"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- App card (a CheckBox dressed as a card: click anywhere to select) -->
    <Style x:Key="Card" TargetType="CheckBox">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingCard}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="card" Background="{DynamicResource CardBg}" Width="{DynamicResource CardW}" Height="170" Margin="6" CornerRadius="14"
                    BorderBrush="{DynamicResource Edge}" BorderThickness="1" Padding="16,14,14,12">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0">
                  <Grid Width="48" Height="48" HorizontalAlignment="Left" VerticalAlignment="Top">
                    <Border CornerRadius="12" Background="{Binding Color}">
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
                    <Border CornerRadius="12" Background="{Binding TileBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" Padding="7">
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
                  <Border x:Name="tick" Width="24" Height="24" CornerRadius="12" Background="#00000000"
                          BorderBrush="{DynamicResource TickBorder}" BorderThickness="1.5" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Ellipse x:Name="mark" Width="12" Height="12" Fill="{DynamicResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                  </Border>
                </Grid>
                <TextBlock Grid.Row="1" Text="{Binding DisplayName}" Foreground="{DynamicResource TextPrimary}" FontSize="14.5" FontWeight="SemiBold"
                           Margin="0,12,0,0" TextTrimming="CharacterEllipsis"/>
                <!-- Description lives inside the card (no hover tooltip) -->
                <TextBlock Grid.Row="2" Text="{Binding Tip}" Foreground="{DynamicResource TextSec2}" FontSize="12.5" LineHeight="17"
                           LineStackingStrategy="BlockLineHeight" TextWrapping="Wrap" TextTrimming="CharacterEllipsis"
                           MaxHeight="34" Margin="0,4,0,0"/>
                <Grid Grid.Row="4" Margin="0,6,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="{Binding CategoryName}" Foreground="{DynamicResource TextMuted}" FontSize="12.5"
                             VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                  <StackPanel Grid.Column="1">
                    <Border CornerRadius="9" Padding="0,2" Margin="8,0,0,0" HorizontalAlignment="Right" VerticalAlignment="Center" MaxWidth="110">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Setter Property="Background" Value="Transparent"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_queued"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_installing"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_uninstalling"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_removed"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_manual"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_done"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_already"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_installed"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_failed"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                          <DataTrigger Binding="{Binding StatusKey}" Value="st_cancelled"><Setter Property="Background" Value="Transparent"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Border.Style>
                    <TextBlock Text="{Binding Status}" FontSize="12.5" FontWeight="SemiBold" TextAlignment="Center" TextTrimming="CharacterEllipsis">
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
                </Grid>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="card" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/>
                <Setter TargetName="tick" Property="BorderBrush" Value="{DynamicResource TickHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="card" Property="Background" Value="{DynamicResource CardChecked}"/>
                <Setter TargetName="card" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="tick" Property="BorderBrush" Value="{DynamicResource Accent}"/>
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
              <Border x:Name="PART_Track" Background="Transparent"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{DynamicResource Accent}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Item of the "more" menu -->
    <Style x:Key="MenuBtn" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="8" Padding="14,9" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource CatHover}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Appearance panel button (mode + colour choices); Tag="sel" marks the active one -->
    <Style x:Key="PalBtn" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="9" Padding="12,9" Background="{DynamicResource BtnBg}"
                    BorderBrush="{DynamicResource BtnBorder}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/></Trigger>
              <Trigger Property="Tag" Value="sel">
                <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="b" Property="Background" Value="{DynamicResource CardChecked}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Small view-switch button (grid / list) -->
    <Style x:Key="ViewBtn" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextSoft}"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Width="36" Height="34" CornerRadius="8" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Status text colours (shared by the list rows) -->
    <Style x:Key="StatusText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextSec2}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
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

    <!-- App row (list view): same CheckBox-as-card idea, one app per line -->
    <Style x:Key="CardRow" TargetType="CheckBox">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRingBtn}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="card" Background="{DynamicResource CardBg}" Width="{DynamicResource CardW}" Height="68" Margin="6,3" CornerRadius="12"
                    BorderBrush="{DynamicResource Edge}" BorderThickness="1" Padding="14,0,16,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="150"/>
                  <ColumnDefinition Width="110"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid Grid.Column="0" Width="42" Height="42" VerticalAlignment="Center" Margin="0,0,14,0">
                  <Border CornerRadius="10" Background="{Binding Color}">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Style.Triggers><DataTrigger Binding="{Binding HasIcon}" Value="True"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers>
                      </Style>
                    </Border.Style>
                    <TextBlock Text="{Binding Initial}" Foreground="White" FontSize="21" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <Border CornerRadius="10" Background="{Binding TileBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" Padding="4">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Style.Triggers><DataTrigger Binding="{Binding HasIcon}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers>
                      </Style>
                    </Border.Style>
                    <Image Source="{Binding Icon}" Width="{Binding IconSize}" Height="{Binding IconSize}" Stretch="Uniform"
                           HorizontalAlignment="Center" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"/>
                  </Border>
                </Grid>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0">
                  <TextBlock Text="{Binding DisplayName}" Foreground="{DynamicResource TextPrimary}" FontSize="14.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Tip}" Foreground="{DynamicResource TextSec2}" FontSize="12.5" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
                <TextBlock Grid.Column="2" Text="{Binding CategoryName}" Foreground="{DynamicResource TextMuted}" FontSize="12.5" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Column="3" Text="{Binding Status}" Style="{StaticResource StatusText}" VerticalAlignment="Center"/>
                <Border x:Name="tick" Grid.Column="4" Width="24" Height="24" CornerRadius="12" Background="#00000000"
                        BorderBrush="{DynamicResource TickBorder}" BorderThickness="1.5" VerticalAlignment="Center">
                  <Ellipse x:Name="mark" Width="12" Height="12" Fill="{DynamicResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="card" Property="BorderBrush" Value="{DynamicResource HoverBorder}"/>
                <Setter TargetName="tick" Property="BorderBrush" Value="{DynamicResource TickHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="card" Property="Background" Value="{DynamicResource CardChecked}"/>
                <Setter TargetName="card" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="tick" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="tplGrid">
      <CheckBox Style="{StaticResource Card}" IsChecked="{Binding IsSelected, Mode=TwoWay}"
                AutomationProperties.Name="{Binding DisplayName}" AutomationProperties.HelpText="{Binding Tip}"/>
    </DataTemplate>
    <DataTemplate x:Key="tplList">
      <CheckBox Style="{StaticResource CardRow}" IsChecked="{Binding IsSelected, Mode=TwoWay}"
                AutomationProperties.Name="{Binding DisplayName}" AutomationProperties.HelpText="{Binding Tip}"/>
    </DataTemplate>
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
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="txtTitle" FontSize="19" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
                <Border x:Name="bdPreview" CornerRadius="11" BorderBrush="{DynamicResource Edge}" BorderThickness="1" Padding="9,1,9,2" Margin="10,1,0,0" VerticalAlignment="Center">
                  <TextBlock x:Name="txtPreview" FontSize="11.5" Foreground="{DynamicResource TextSoft}"/>
                </Border>
              </StackPanel>
              <TextBlock x:Name="txtSubtitle" FontSize="12" Foreground="{DynamicResource TextSec}"/>
            </StackPanel>
          </StackPanel>
          <Grid Grid.Column="1" Margin="34,0" VerticalAlignment="Center" MaxWidth="560">
            <TextBox x:Name="txtSearch" Style="{StaticResource SearchBox}" VerticalContentAlignment="Center" TextWrapping="NoWrap" AcceptsReturn="False"/>
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource TextMuted}"
                       IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="15,0,0,0"/>
            <TextBlock x:Name="txtPlaceholder" IsHitTestVisible="False" Foreground="{DynamicResource TextMuted}" FontSize="14"
                       VerticalAlignment="Center" Margin="44,0,16,0"/>
            <Border x:Name="bdKbd" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" CornerRadius="6" Padding="7,2"
                    Background="{DynamicResource BadgeBg}" IsHitTestVisible="False">
              <TextBlock Text="Ctrl K" FontSize="11.5" Foreground="{DynamicResource TextSoft}" FlowDirection="LeftToRight"/>
            </Border>
            <Button x:Name="btnClearSearch" Style="{StaticResource IconBtn}" HorizontalAlignment="Right"
                    VerticalAlignment="Center" Margin="0,0,9,0" Visibility="Collapsed"/>
          </Grid>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnUpdate" Style="{StaticResource BtnPrimary}" Padding="14,9" FontSize="13" Visibility="Collapsed"/>
            <Button x:Name="btnTheme" Style="{StaticResource Btn}" Background="Transparent" Padding="0" Width="44" Height="42"
                    Foreground="{DynamicResource TextPrimary}">
              <Viewbox Width="18" Height="18" Stretch="Uniform">
                <Canvas Width="24" Height="24">
                  <Canvas x:Name="icoSun">
                    <Ellipse Canvas.Left="3" Canvas.Top="3" Width="18" Height="18" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.8"/>
                    <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" Data="M12,3 A9,9 0 0 1 12,21 Z"/>
                  </Canvas>
                  <Path x:Name="icoMoon" Visibility="Collapsed" Data="M0,0"/>
                </Canvas>
              </Viewbox>
            </Button>
            <Button x:Name="btnLang" Style="{StaticResource LangBtn}"/>
            <Button x:Name="btnMore" Style="{StaticResource Btn}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16"
                    Padding="0,9" MinWidth="46" Content="&#xE712;"/>
          </StackPanel>
        </Grid>
      </Border>
      
    </Grid>

    <!-- Body -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="248"/>
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
                <TextBlock Grid.Column="0" Text="{Binding Glyph}" Foreground="{DynamicResource TextSoft}" FontSize="16" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                <TextBlock Grid.Column="1" Text="{Binding Name}" Foreground="{DynamicResource TextPrimary}" FontSize="14" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Column="2" Text="{Binding Count}" Foreground="{DynamicResource TextMuted}" FontSize="12" VerticalAlignment="Center" Margin="8,0,2,0"/>
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
            <Border CornerRadius="10" BorderBrush="{DynamicResource BtnBorder}" BorderThickness="1" Background="{DynamicResource BtnBg}" Padding="2" Margin="0,0,8,0">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="btnViewGrid" Style="{StaticResource ViewBtn}" Content="&#xE80A;"/>
                <Button x:Name="btnViewList" Style="{StaticResource ViewBtn}" Content="&#xE8FD;"/>
              </StackPanel>
            </Border>
            <Button x:Name="btnSelectVisible" Style="{StaticResource Btn}" Margin="0,0,6,0"/>
            <Button x:Name="btnClear" Style="{StaticResource Btn}" Margin="0"/>
          </StackPanel>
        </Grid>
        <ScrollViewer x:Name="svApps" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <ItemsControl x:Name="icApps" KeyboardNavigation.TabNavigation="Once" KeyboardNavigation.DirectionalNavigation="Contained">
            <ItemsControl.ItemsPanel>
              <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
            </ItemsControl.ItemsPanel>
          </ItemsControl>
        </ScrollViewer>
        <StackPanel x:Name="emptyPanel" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="420" Visibility="Collapsed">
          <TextBlock x:Name="txtEmptyIcon" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="34" Foreground="{DynamicResource TextMuted}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="txtEmpty" Margin="0,14,0,0" Foreground="{DynamicResource TextPrimary}" FontSize="16" FontWeight="SemiBold" TextAlignment="Center" TextWrapping="Wrap"/>
          <TextBlock x:Name="txtEmptyHint" Margin="0,6,0,0" Foreground="{DynamicResource TextSec2}" FontSize="13" TextAlignment="Center" TextWrapping="Wrap"/>
          <Button x:Name="btnEmpty" Style="{StaticResource Btn}" Margin="0,16,0,0" HorizontalAlignment="Center" Visibility="Collapsed"/>
        </StackPanel>
      </Grid>
    </Grid>

    <!-- Footer -->
    <Border Grid.Row="2" Background="{DynamicResource BgPanel}" Padding="0" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0">
     <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <ProgressBar x:Name="pbar" Grid.Row="0" Style="{StaticResource Prog}" Height="3" Margin="0,-1,0,0" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Top"/>
      <Border x:Name="bdNotice" Grid.Row="1" Visibility="Collapsed" Margin="22,12,22,0" CornerRadius="10" Padding="14,8,8,8"
              Background="{DynamicResource BadgeBg}" BorderBrush="{DynamicResource Edge}" BorderThickness="1">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="icoNotice" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" VerticalAlignment="Center" Margin="0,0,12,0" Foreground="{DynamicResource TextSoft}"/>
          <TextBlock x:Name="txtNotice" Grid.Column="1" Foreground="{DynamicResource TextPrimary}" FontSize="13" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="56" VerticalAlignment="Center"/>
          <Button x:Name="btnNoticeAction" Grid.Column="2" Style="{StaticResource Btn}" Padding="12,5" Margin="12,0,4,0" Visibility="Collapsed"/>
          <Button x:Name="btnNoticeClose" Grid.Column="3" Style="{StaticResource IconBtn}" VerticalAlignment="Center"/>
        </Grid>
      </Border>
      <Grid Grid.Row="2" Margin="22,13,22,14">
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
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="txtSelected" Foreground="{DynamicResource TextPrimary}" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <ItemsControl x:Name="icSel" Margin="17,0,0,0" VerticalAlignment="Center" Focusable="False">
                <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Grid Width="30" Height="30" Margin="-9,0,0,0">
                      <Border CornerRadius="9" Background="{Binding Color}" BorderBrush="{DynamicResource BgPanel}" BorderThickness="2">
                        <TextBlock Text="{Binding Initial}" Foreground="White" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <Border CornerRadius="9" Background="{Binding TileBg}" BorderBrush="{DynamicResource BgPanel}" BorderThickness="2" Padding="4">
                        <Border.Style>
                          <Style TargetType="Border">
                            <Style.Triggers><DataTrigger Binding="{Binding HasIcon}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers>
                          </Style>
                        </Border.Style>
                        <Image Source="{Binding Icon}" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                      </Border>
                    </Grid>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
              <TextBlock x:Name="txtSelMore" Foreground="{DynamicResource TextSec2}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center" Margin="8,0,0,0" FlowDirection="LeftToRight"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
              <TextBlock x:Name="txtProgress" Foreground="{DynamicResource TextSec2}" FontSize="12" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="txtPercent" Margin="8,0,0,0" Foreground="{DynamicResource TextSoft}" FontSize="12" FontWeight="SemiBold" FlowDirection="LeftToRight"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnLog" Style="{StaticResource Btn}"/>
            <Button x:Name="btnCancel" Style="{StaticResource BtnDanger}" Visibility="Collapsed"/>
            <Button x:Name="btnUpgrade" Style="{StaticResource Btn}"/>
            <Border Width="1" Height="24" Margin="10,0,10,0" Background="{DynamicResource Line}" VerticalAlignment="Center"/>
            <Button x:Name="btnUninstall" Style="{StaticResource Btn}" Visibility="Collapsed"/>
            <Button x:Name="btnInstall" Style="{StaticResource BtnPrimary}" FontSize="15"/>
          </StackPanel>
        </Grid>
        <TextBox x:Name="txtLog" Grid.Row="1" Height="110" Margin="0,12,0,0" IsReadOnly="True" Visibility="Collapsed" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" FlowDirection="LeftToRight"
                 Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogFg}" BorderBrush="{DynamicResource Line}" Padding="10"/>
      </Grid>
     </Grid>
    </Border>

    <!-- Appearance panel (overlay: click outside closes it) -->
    <Grid x:Name="themeLayer" Grid.RowSpan="3" Background="#01000000" Visibility="Collapsed">
      <Border HorizontalAlignment="Right" VerticalAlignment="Top" Margin="24,74,24,0" Width="320" CornerRadius="14" Padding="14"
              Background="{DynamicResource BgPanel}" BorderBrush="{DynamicResource Edge}" BorderThickness="1">
        <Border.Effect><DropShadowEffect Color="#000000" Opacity="0.45" BlurRadius="24" ShadowDepth="6" Direction="270"/></Border.Effect>
        <StackPanel KeyboardNavigation.TabNavigation="Cycle">
          <TextBlock x:Name="txtAppearance" FontSize="12" FontWeight="Bold" Foreground="{DynamicResource TextSec}" Margin="2,0,0,10"/>
          <UniformGrid Columns="2">
            <Button x:Name="btnModeDark" Style="{StaticResource PalBtn}" Margin="0,0,4,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE708;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Margin="0,0,9,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtModeDark" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="btnModeLight" Style="{StaticResource PalBtn}" Margin="4,0,0,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE706;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Margin="0,0,9,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtModeLight" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </UniformGrid>
          <TextBlock x:Name="txtAtmosphere" FontSize="11.5" FontWeight="Bold" Foreground="{DynamicResource TextMuted}" Margin="2,18,0,8"/>
          <UniformGrid x:Name="palGrid" Columns="2"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- "More" menu (overlay: click outside closes it) -->
    <Grid x:Name="menuLayer" Grid.RowSpan="3" Background="#01000000" Visibility="Collapsed">
      <Border HorizontalAlignment="Right" VerticalAlignment="Top" Margin="24,74,24,0" Width="214" CornerRadius="12" Padding="6"
              Background="{DynamicResource BgPanel}" BorderBrush="{DynamicResource Edge}" BorderThickness="1">
        <Border.Effect><DropShadowEffect Color="#000000" Opacity="0.45" BlurRadius="24" ShadowDepth="6" Direction="270"/></Border.Effect>
        <StackPanel KeyboardNavigation.TabNavigation="Cycle">
          <Button x:Name="btnExport" Style="{StaticResource MenuBtn}"/>
          <Button x:Name="btnImport" Style="{StaticResource MenuBtn}"/>
          <Button x:Name="btnRefresh" Style="{StaticResource MenuBtn}"/>
          <Button x:Name="btnShortcuts" Style="{StaticResource MenuBtn}"/>
          <Button x:Name="btnAbout" Style="{StaticResource MenuBtn}"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'imgLogo', 'txtTitle', 'txtSubtitle', 'txtSearch', 'txtPlaceholder', 'btnLang', 'lstCats', 'btnSelectVisible',
                'btnClear', 'txtCatTitle', 'txtCatCount', 'icApps', 'svApps', 'txtEmpty', 'txtSelected', 'pbar', 'txtProgress', 'btnCancel', 'btnInstall', 'btnUpgrade', 'btnUninstall', 'txtLog', 'btnLog', 'txtPercent', 'btnClearSearch', 'btnTheme', 'btnUpdate', 'btnRefresh',
                'icSel', 'txtSelMore', 'txtPreview', 'bdKbd', 'btnMore', 'icoSun', 'icoMoon', 'menuLayer', 'themeLayer', 'txtAppearance', 'btnModeDark', 'btnModeLight', 'txtModeDark', 'txtModeLight', 'txtAtmosphere', 'palGrid', 'btnExport', 'btnImport', 'btnShortcuts', 'btnAbout', 'btnViewGrid', 'btnViewList') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}
foreach ($n in 'bdPreview', 'emptyPanel', 'txtEmptyIcon', 'txtEmptyHint', 'btnEmpty', 'bdNotice', 'icoNotice', 'txtNotice', 'btnNoticeAction', 'btnNoticeClose') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# ----------------------------------------------------------------------------
# 6. Helper functions
# ----------------------------------------------------------------------------
# App logo (embedded PNG) used in the header and as the window icon.
$LogoBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAXZklEQVR42u1df4wb1Z3/vDfjsdf2eje7Tthk0wINy8IC6kWklUmBhgAVbCZRaIPSilJKgcsFUUqKei1Nr1xzcKj8WhJoSWhBpIcKKYrUlI0i0WRTlfxwIuUoXBC6RfwIWVOl2WS9u/Z6djzz3v0Rj8/r9Y8Ze2ZsJzvSyCuvZ+bN+3y/3/f9/YCZ45w+iMvPIlu3biXPP/88mZn66cfatWv5HXfcwQEYZ8MfNBKJiLIsCzPwWjtkWRYikYgIgDaaBCCyLNMtW7bwzs5OZnwZi8XI6tWrO0VR/LyiKJ8jhMxmjLWm02mREMLPRZA550QQBF0Uxbiu68NNTU3HA4HAp9u2bRtqbm5muYwkyzLp7+9ndksGYjfw/f39uvHFtdde+zlVVa9Lp9NLJycnF2madqGu637OOYwzMxFnbkBI9m8bJ9kJ4Ka/PCFFf2f8r9hYCCGglBqfiiRJn/h8viM+n28gFAoN7Nq165NcyWAnIRC7xJUB/IoVK7z/+Mc/lqdSqe/our4knU43q6oKXdehaRr4mVnIvkDupJQjAM55VURiFzE4QVQZLCghhAiCAFEU4fF44PF4Jpqamv4aCAT+68orr/zjpk2bJvLnvJYEQGKxGOns7GSyLPtOnTp1p6Io96VSqR5FUaBpGhhjegZsSs6wAqlkIqud9Fpfb+VRZx7HGeecEEIEj8cDn8+HQCDwQUtLy/Pz58//zauvvprI6AdVKYzEDq6/5pprVo6Njf3H5OTk5RMTE9A0TSeEgBBCAZDcybM6kWcD8PlLgdXLGWOMcw5RFAW/349gMDjY0tLy72+99dar1UqDikYUiUTEaDSqXXnllXMIIc8kk8lvJZNJaJqmEUJoBvhpk3eugV9qza/wesYYY6Iois3NzWhtbf2j1+v9/r59+4YMTKyOUagU/KuuumqJqqr98Xj8mmQyqXPOQSkVMmJ+BnwT15cihCLXE0IIZYyxVCrFVFXt4Zx/6wtf+ML70Wj0f2VZFgYHB7ljBJAD/t3j4+Pb4vF4m6qqGqVUJDlvU43IP1fAL0QIhpJr4veEEEJVVdUURWnhnN/W3d09umfPnoMZIrCfAHLE/kMTExMbR0ZGCOecU0qFYi8/A76zR4404Jzzm7u6ujwDAwN7IpGIODQ0xGwjgFzwU6nUf46MjGiU0uxab9dEzIBfEREQQggmJiZ0zvmSiy++2BONRnebJQLBLPhf+tKX7lIUZWMGfKGQApnr3JkB31VrgRBCSCqV0jnnS7q6usYPHTq03wwR0HKmXjQa1a699tprUqnUlpGREX0GfGfBr2QuM78nhBBhZGREGxsbeyoSifRGo1Ft69atQqVmIAWAr3zlK7OSyeTfTp8+PV/XdVZI7M+A75xnsZw0KGQqEkJIR0fHqVAotHDfvn2xDM7MkgSQZZkAYIqi/HpsbGy+YeMXMExnwHfwHqWYq8j3VNd1NjIyEk4kEr8BwDNYmtcBDM/SokWLliuK8kgikdAopWIh8M9V8NwAv1IHkmEiUkov7u7u/nBgYOCdYj4CUixxQ5Zl6dixY++Mjo526brO87m/EcB3SiuvBfiFfAZl7s8EQSCzZ8+O9fT09PzhD39IFoob0AJavwCAxWKxO9Lp9MWaprEZ8OsDfCv6FiGEapqmJ5PJ+cePH78XAMtgW1ICEABYsmSJdPr06aPxeHwBY4znEkotwTd7DzvBNxvTr1NfASOEkHA4/PfW1tbuAwcOJHMijtMlQIZCuKIoy1RVvUjTNFYv4Jej/PwkEzP3yj/tNM3qxFFEdV1niqLMo5TeCoDnS4EpBLB9+3YGAJOTk99TFIXnKh21Ar+cFmxBJJY8jYwcuzjdafCtvHcqleKjo6PfA4BoNMqKLQEEAP/qV78678SJE4OJRCKQERWkFuBbNH1QKoNI13WoqmopSufxeCAIQt2Cb9FXwFtbW7WOjo7L9u3b90GG8RkAiLniPxqNaoqi3KDreoAxplNKBbfBtwP4XPAnJycxd+5crFy5EgsWLEBTU1NBaZYJZ2NychIfffQR/vSnP+H48eOQJMl0lK4W4JuJInLO9XQ67dF1/WYAH0QiEWpIgiwBhMNhDgC6rl+vaZqRiVJz8Cu9jwH+ypUrsXHjRsvc/OMf/xgPPfQQXnnlFXi93oqIwM1lpMz4SDqdhqIoSwFsWr16NY9Go9OtAFmWhWPHjv1PPB6/VNd1VmlOuh3JH9UuHcbn4OAgPB6PZR3GWDq6u7uhaRoopdVm87iyjOSPL3MdI4TQtra242vWrLn4hz/8oWIs+TRXGYzH43NVVb1A1/WK08VqCX7uJGiahiuuuAKiKGa5w8rJOYcgCLj66quhaZol5bCWCmSRfAzKGEM6nZ63c+fOC4AzdRpZ4Pv6+khm4s7nnDdlUreJ2+DbYWoZh67rmDdvXtWAdHR0WJIe9WA9FJrHTJaxwDm/EAB27979/wSwbds2kjH/Ppd5Wd1pKq02Z9CM+K9WizfMw1p5H22+H2OMIZlMng8ARn0mzXvh2U5n8lgV+dVo3054BN14llNOI8YYGGOzc7+bEuHTNK3FeBknlJ1KwK9FmpWZMTg5LifjGJTSlqIEwDkXnarWsTKJTnnjnMjtbwTOz8e4KAFYqdI9F8A3MyY7x+vGO1NKuemcwBnwzdnZuWZmvVcxW0oKPdfBL1bjUAhsq7qTW+CXu7dYT7Vydk+E4b2zg+MNZTCfEKothnGD83OJIePmt04Adjh5GpHzSy0BdieL1EKJpGcj+NXmH5T7Pn8JqFT8ux0sqogAZsCfGmnLXQYKEUKjcL4pAmi0NT+fQ+3w4TPGpoBshhDsTvN2kuipG1pzLdZ8J9vP5EcNq+kAUi0RVDuP1Mmwbi3Ad3sdzn8nN4nAjnmkbnHf2cD55SRCNUEhNwi30DXULdHfSKYe6r/BpH2+Eje4yI2oXkHqLuIIqpXbFXVY8UTdEP0ut00pKVJnwC9BAHblwbsc3izqhMk3AysZSzl3cqPXOlK7+tjVYk0tp3nngjfD+Q7pALVUhIpF5erFxGwEJTQ/JayitGe3X8aM372eibiexkYbbfDFwC80Lr/fX/XzgsHgNGXW7di/nZKnKgJwOznSCufnav+UUui6jssuu6yqySOE4NJLL4Wu69OWm3pJ/LB6uJYP4DT4RrDH0PRzuVNVVfj9fqxatarq6GBvby9CoRDGx8chSdK0EjGztQO1mr9yirroZsWuHeBzzpEpc4LX60Vzc/MU87W1tRULFy7ET3/6U/j9/qoJQJIkHD58GI899hiOHDmCeDwOxhgopUin00gmk1AUBaIoOmJG21ViX0x6io3A+bl/M8bQ3NyMF154AQsXLoQoitMkg92Zum1tbXjiiSeyz8/VCVKpFN555x3cd999OH36dEEicCJHwa7raCOAb0w2pRSqquLJJ5/E4sWL4fV6IQgCKKXZs9qgTLnKH0EQss8UBAHBYBBXX301Nm3ahHQ6XRemopXrRKC+TaVCGTcjIyOOlGNVmvFEKUU8HnetFA1u5AS6qdSY9StwzuHxeLBhw4YpJds1taMpBWMMGzZsgMfjmUaYbnZNr8jVXW9OkXLhZEEQEI/H8cADD9SNtFq/fj2GhoayvQgagfNdqwyqxtFRLMDj9Xrx+uuvY/Pmzbbk/lcz7t/97nd48cUX4fP5pvRNriRDqBY9l6ld6cVu9co1lDy/34+HH34YAwMDNSECQggOHDiAH/3oR/D7/VOsg3p2D4uiaK8n0Mnc+3L3aGpqwm233YYPP/zQVSIghODTTz/Frbfemu0iVkp6ORm3cCwp1M1AiJWE0lw7nxACQRCwdOlSJBIJV5RCQgiSySSuu+66KSHn/HE1ioeVNmIULHeyBUGAqqq46aabpuXwO3EwxrBq1Sokk8ms1l8ph9dD61laj9q+VWXR6/VicHAQa9ascZz7161bhyNHjmSVvkKxgUbpWu4aAdi5MUL+UpCrFO7YsQNPPvmkI1KAEILNmzfj97//fTbGkA+6W6Lf8azgRkl+KEQEjz/+OPr7+21VCimlGBgYwM9//vMp4FfTFKJerAVaD+BbzRzOn7xcIJqamnDPPffg3Xffta0/wAcffIBvf/vb8Hq90wjPjaQNJ3UG6mYHUCfTv3M/RVHEsmXLcPLkyaoTQkZHR3HjjTdmLY5iBFiLjqquSYBaDbacT70YEYiiCF3XcfPNN2ezeSrV+L/+9a9DUZRpGn+1S0C97LRCGxX8ckqhJEkYGhrC7bffXrHFce+99+Lo0aPw+Xy2rPu1qF8sFzWljQx+OSLw+XzYvXs3NmzYYAk0Qgg2btyI7du3Z/cXyAffDCFUm0Pphp+A1ktnDjMAVSIJ/H4/nnvuObz22mumlEJKKXbu3IlHH30UgUCgIOebyThqlH0NaT2IKWNCqw2oFLuv3+/HD37wAxw+fLgkERBCcPToUdx9993TxL7d5fFldvhwjXhoPeQCKIqCdDoNj8cDTdOQSqWqdiDlSwRJknDLLbcgFosVnHxCCIaHh9Hb25tN+SrE9VbFfv47GgqqoiiOdE13pEuYE12yjevS6TTWrl2LgwcP4v3338fhw4fx4IMPWtrkycxmSoIggHOOG264ARMTE9OIxYgnGCAVikyWawhVDExVVXHnnXdiz549ePvtt/GXv/wFa9euzeboOx1ltUQAbuTaGaJVVVX88pe/xM9+9jPMmzcPgiDgvPPOw4MPPojNmzdDVdWiHTlLcU4xO12SJMTjcXzta1/D8PBwlsNHR0exfPlyDA0NTdkkykqEr9B4jH2LfvGLX+CRRx5Bd3c3mpubsWDBAqxfvx5PPfVU9h2rnXdXM4KqzV4xtnTp6enBN7/5zWwmjXEyxrBs2TJEIpGsJLDaDrWQ6Oacw+v14uOPP8aiRYvw6KOP4rHHHsPChQvx7rvvFjX3ygV4ioGfTqfR1dWFu+66a4qOYwSRVq9ejYULF1Yk7eqyS5iVI51Oo7e3t6hSRgjB8uXLyyZ/mrUMcolAkiQwxvDss8/imWeeyRaZ2AE+8sqwZFnOPjd/HIQQ9Pb2VpXgWq20FmupAIZCoZK/yd3zp9JizNzJzv2klKKpqWnKJNqxM1i+D6Ojo6Pk9UbxqZvZwzWXAMbA8wsVq+18bdVhVKjVe6kATyXp3qXMzkLv5XbTCLFWqctmu3jmTlK1oddi9zAT3KnEK2roM3bXWNQ0H6Aa8K1qunaXo5cKI5fbEKLSMZQjdKsbWtptoYn1XN/uxPOq3QyrlileDZUPYJdfwc5GVGYnuZjkqWR9tiszySnCE92w+e0KaRYSz1aDSE5q21aXCjcVPtfyAaw0VrZDqtR7RzMzSmAt8wFEp6N8TmwIYUYSuL2NWzFvZDVKoBtLnljLWoBy4ptSCk3Tslxkxi9vV3eQaqWT4QrOr8WrNwVarAX1mV23Fy9ejEsuuQSfffZZUS+dHTa7U36O+fPnY+nSpZYloZvjF0tVjtayBSrnHIFAAPv27YOu67aaagaH5orfcgqrGZ9E/v2CwWBJqVUPm06Lbm+5ZsUbaPzWCTFaiw5nZpdINwNDYi0mtd5qDJx6fzPpZLXeOGoKARQTtU4NwKm+eqiTfYUbwWNKa8H5xkQlEgmcywfnHIqi1M+uYZRS5sYAOOcQRRE7d+5s6L17qnVpG3Ng5Cu6Mfe6rrOiBMA5H7NislRjLkmShPfeew+vv/56NgP3bD4KJaHu2LEDR44cyZadOZ4AeqaZ5mhRHcDj8ZysNlpm1jPIGIMkSbj//vtx7NgxfPe730VbW9tZCb5h7RidTk+cOIFt27bh6aefhsfjsdxjoFJpkSGAk9MIYPXq1TwajcLj8RzPDIC6UQiSITo8/vjj6OvrQyAQyPb4LxRRy0+qzG3UWCoLp5i5WehaM0CWe/9Sz1MUBRMTE5icnITP53Nzo0tCKUUgEPgUAMLhMM8SwLp16zgABIPBY5TSSUKIFwAHQNzoEWjU3yUSCYyPj9etWWjXcwVBmNLJ3Empa1xKCBEopUySpI8BYMuWLbyzszO7BHAAuOeee2Lr16//RBCEbsbYNAJwIjKYJ55c3Xgyvxm10w6wcoUlDpaLcUEQiCiKf/d6vZ8AQGdnJ88V9VyWZeGWW27RJUk6kqmMYU51+CqnIOWfpf5n5jTTbczMPUrd08y15Z7vYGyAi6KIpqamv73xxhsTGdynEACGh4dJZk0eyNdKnd7mvdQEVgO8HdcbZ75eUSkBWm0vY8fcM8a41+uF3+8fAIBIJEKnmYHRaJQBQEdHx5uCIKQIIWKGeFzZWLoewbfC5WYllxVXsY1SV/B4PHpbW9suANi+fXtWuk95eiwWo52dneyKK65489SpUzek02kGQKiVElUPjRTtGH8hHcDFZhu6x+Oh55133uH33nsvkmF6VtAR9I1vfIMCQCgUesnn85Fab4BQT9xfidivh/axjDH4/X4SDAZfzhf/0wggGo3qAIgkSTt8Pt8xQRCmUEsjbJRoRxZyra+30wcliiL1er0nL7/88tdyMC4aDOKRSETYu3dvKhQK9fn9fpIxBxsG/HP5ehTw+wcCARIOh3/14osvxiORiGho/0WjgRkKoT09Pb8NBAKfiKJYsRSYAb+mc8VEUaTBYPBEc3PzJgAkn/uLuXy5LMvkpZdeSra3t/9rc3Mz4ZwzF12WM+DbxP0tLS20ra3t3958880RWZZpPvejmIY/ODjIZVkW/vznPx+94IILFqmqekk6ndYJIbRWL2Rlz+BzHXzGmO73+8U5c+b8df/+/fe//fbbQn9/P7OUEtbf388BkFmzZv2zpml/U1V1tq7rrBwROAV+ISKYAb/gPRmllLS3t4/Nnz//e5Ik8Vgsxg3Xr5WMILZ161a6Z8+ev4dCoe/MmjWLZHQBXgvwq6kyPlfAzzjuWHt7O509e/bdb7zxxoeyLAudnZ1FdbiyC3skEhGj0aj25S9/+YHR0dG+4eFhjVIqOBkoqvfNFuoUfOi6ng6Hw56Ojo6HDx48uMHArtQ1Zb18Q0NDLBKJiIcOHTrQ3d3tYYwtSaVSOjkji0mj7TNwtnK+rutae3u7Z86cOc8dOnToJ2bAh1k3r0EEBw8e3N3V1eUhhCxJpVI8E2cmtXa5nkvWQoEaSM45Z+FwWJw3b95z0Wj0+7IsCwMDA6ZMd9N+/qGhIZ6RBLsvuuiicUrpTZOTk4QxplEbt+eYAd/8XsqMMV0QBBoOh2lHR8fDBw4c+ElfX5/w7LPPltTVKiIAQxLIsizs3bv3QE9Pz38TQpYyxkKqqmoZvzeZAd958Dnn3DD1wuHwSEdHx5379+//dV9fn7Bu3TrT4KPSNdxYXyKRyPmqqj43Ojoqj4+PQ9M0jVIqVLIszIBf+vpMthTXdV0XRVFsaWlBe3v7Hp/Pd+/+/fsHza75thAAAMiyLPT39+sAcNVVV90xPj7+cCKRuDCZTELXdT2zKlAzz6hXC6IeFL5MQgZnjHFBEIRgMIhAIDA0Z86cR956660t+Vi4RgB5fgS2YsWKlpMnT64dGxv7l2Qyeb6iKEYLVI1kjszzGsZ8rBEBZAHnnHNCiChJEpqamhAIBD5ra2t7Ye7cub/avn37MAASi8VIKTvfaQKYJg1WrFjRcurUqVWJROL2RCKxWNM0z+TkZLbRQ8aZxGb8+wV/TzLZuxBFET6fDx6PRw+FQodCodArCxYs2Pbyyy+frpbrbScA416RSETIXYeuv/76SyYmJm6cmJhYqqrqPymK8nnOOTU6fhTLnz9bHTVlKnaMk4uiOBQIBN4JhUJ7g8Hgm7t27Tqax2yWFD23CCB7T1mWaf4gn376ad/OnTsvSKVSF6bT6c9zzucQQlo456KmabwUEJIkmW4rWw+H0c/AxA4oRNM0nXM+KknSyUAgcFySpI+++MUvfvLEE09MFGAu3S7gXTlisRiNRCJiX1/f2VUH7uLcxWIxR/s5u1mRSWKxGFmzZg0xUtBnjqlHOBzmmYod3lCcPnM07vF/i999XxoTF+oAAAAASUVORK5CYII='
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

$script:SelItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[MeshalApp]'
$script:icSel.ItemsSource = $script:SelItems
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
        BgWindow = '#09090B'; BgPanel = '#0E0E11'; Line = '#1C1C21'
        HeaderBg = @('#0E0E11', '#0E0E11'); CardBg = @('#131317', '#131317')
        TextPrimary = '#F4F4F5'; TextSec = '#8B8B94'; TextSec2 = '#9A9AA3'; TextMuted = '#8A8A94'; TextSoft = '#C4C4CC'; LogFg = '#B8B8C0'
        BtnBg = '#131317'; BtnBorder = '#2A2A31'; HoverBorder = '#4A4A55'
        InputBg = '#101013'; InputBgFocus = '#131317'; InputBorderHover = '#3A3A44'; Edge = '#222227'
        CatHover = '#151519'; CatSelected = '#25252C'; CardChecked = '#18181D'; LogoBg = '#000000'
        TickBorder = '#80808C'; TickHover = '#9A9AA6'; BadgeBg = '#1D1D22'; BadgeBg2 = '#1A1A1F'
        ThumbBg = '#2E2E36'; ThumbHover = '#4A4A55'; LogBg = '#060607'
        StInfoBg = '#1E3560'; StOkBg = '#17382A'; StErrBg = '#43201F'; StWarnBg = '#3A3220'
        StInfoFg = '#8DB8FF'; StOkFg = '#4ADE80'; StErrFg = '#F87171'; StWarnFg = '#FBBF24'
        ThemeIcon = '#F4F4F5'; FocusRing = '#F4F4F5'; Accent = '#F4F4F5'; OnAccent = '#09090B'
    }
    light = @{
        BgWindow = '#F6F6F7'; BgPanel = '#FFFFFF'; Line = '#E4E4E7'
        HeaderBg = @('#FFFFFF', '#FFFFFF'); CardBg = @('#FFFFFF', '#FFFFFF')
        TextPrimary = '#111114'; TextSec = '#5F5F69'; TextSec2 = '#5F5F69'; TextMuted = '#63636D'; TextSoft = '#46464F'; LogFg = '#2B2B33'
        BtnBg = '#FFFFFF'; BtnBorder = '#D8D8DE'; HoverBorder = '#8A8A94'
        InputBg = '#FFFFFF'; InputBgFocus = '#FFFFFF'; InputBorderHover = '#B8B8C2'; Edge = '#E1E1E6'
        CatHover = '#F0F0F3'; CatSelected = '#E8E8EC'; CardChecked = '#F2F2F5'; LogoBg = '#000000'
        TickBorder = '#7B7B86'; TickHover = '#46464F'; BadgeBg = '#ECECF0'; BadgeBg2 = '#ECECF0'
        ThumbBg = '#C8C8D0'; ThumbHover = '#A4A4AE'; LogBg = '#FFFFFF'
        StInfoBg = '#DCE8FF'; StOkBg = '#D9F5E4'; StErrBg = '#FDE0E0'; StWarnBg = '#FBEFCF'
        StInfoFg = '#1D5FD6'; StOkFg = '#166534'; StErrFg = '#C62828'; StWarnFg = '#854D0E'
        ThemeIcon = '#111114'; FocusRing = '#111114'; Accent = '#111114'; OnAccent = '#FFFFFF'
    }
}
$GradientDir = @{ HeaderBg = @(0, 0, 1, 0); CardBg = @(0, 0, 0, 1) }

# ---- Colour palettes ("atmospheres"): they sit on top of the dark / light mode --------------
# W = window background (dark mode), Hi = tint used to build every other surface from W,
# AccentDark / AccentLight = highlight colour in dark / light mode. 'classic' is the default; 'mono' is the original grey look.
$Palettes = [ordered]@{
    classic = @{ En = 'Classic Black'; Ar = 'أسود كلاسيكي';  W = '#000000'; Hi = '#FFFFFF'; AccentDark = '#F4F4F5'; AccentLight = '#111114' }
    mono    = @{ En = 'Mono';          Ar = 'أحادي';         Keep = $true; W = '#09090B'; Hi = '#FFFFFF'; AccentDark = '#F4F4F5'; AccentLight = '#111114' }
    frost   = @{ En = 'Dark Frost';    Ar = 'جليد داكن';     W = '#080D12'; Hi = '#7DD3FC'; AccentDark = '#38BDF8'; AccentLight = '#0284C7' }
    navy    = @{ En = 'Midnight Navy'; Ar = 'أزرق ليلي';     W = '#070B16'; Hi = '#7C9CFF'; AccentDark = '#5B8CFF'; AccentLight = '#2563EB' }
    violet  = @{ En = 'Cyber Violet';  Ar = 'بنفسجي سايبر';  W = '#0C0813'; Hi = '#B79CFF'; AccentDark = '#A78BFA'; AccentLight = '#7C3AED' }
    red     = @{ En = 'Black & Red';   Ar = 'أسود وأحمر';    W = '#0B0708'; Hi = '#FF7A7A'; AccentDark = '#F43F5E'; AccentLight = '#DC2626' }
    emerald = @{ En = 'Emerald';       Ar = 'زمردي';         W = '#06100C'; Hi = '#6EE7B7'; AccentDark = '#34D399'; AccentLight = '#059669' }
    amber   = @{ En = 'Amber';         Ar = 'كهرماني';       W = '#0F0B05'; Hi = '#FCD34D'; AccentDark = '#FBBF24'; AccentLight = '#D97706' }
}

function Get-Mix {
    param([string]$A, [string]$B, [double]$T)
    $a = $A.TrimStart('#'); $b = $B.TrimStart('#')
    $out = '#'
    foreach ($i in 0, 2, 4) {
        $x = [Convert]::ToInt32($a.Substring($i, 2), 16); $y = [Convert]::ToInt32($b.Substring($i, 2), 16)
        $out += ([int][Math]::Round($x + ($y - $x) * $T)).ToString('X2')
    }
    return $out
}

function Get-OnColor {
    param([string]$Hex)    # readable text colour on top of an accent colour
    $h = $Hex.TrimStart('#')
    $l = (0.299 * [Convert]::ToInt32($h.Substring(0, 2), 16) + 0.587 * [Convert]::ToInt32($h.Substring(2, 2), 16) + 0.114 * [Convert]::ToInt32($h.Substring(4, 2), 16)) / 255.0
    if ($l -gt 0.55) { return '#09090B' } else { return '#FFFFFF' }
}

function Get-ThemeTable {
    param([string]$Mode, [string]$Key)
    $t = @{}
    foreach ($k in $Themes[$Mode].Keys) { $t[$k] = $Themes[$Mode][$k] }
    if (-not $Palettes.Contains($Key)) { $Key = 'classic' }
    $p = $Palettes[$Key]
    if ($Mode -eq 'dark') {
        $acc = $p.AccentDark
        if (-not $p.Keep) {
            $W = $p.W; $H = $p.Hi
            $t.BgWindow = $W
            $t.BgPanel = Get-Mix $W $H 0.035;   $t.Line = Get-Mix $W $H 0.10
            $c1 = Get-Mix $W $H 0.035;         $t.HeaderBg = @($c1, $c1)
            $c2 = Get-Mix $W $H 0.06;          $t.CardBg = @($c2, $c2)
            $t.BtnBg = $c2;                    $t.BtnBorder = Get-Mix $W $H 0.15;   $t.HoverBorder = Get-Mix $W $H 0.28
            $t.InputBg = Get-Mix $W $H 0.045;  $t.InputBgFocus = $c2;               $t.InputBorderHover = Get-Mix $W $H 0.20
            $t.Edge = Get-Mix $W $H 0.11
            $t.CatHover = Get-Mix $W $H 0.06;  $t.CatSelected = Get-Mix $W $H 0.13; $t.CardChecked = Get-Mix $W $H 0.075
            $t.BadgeBg = Get-Mix $W $H 0.11;   $t.BadgeBg2 = Get-Mix $W $H 0.09
            $t.ThumbBg = Get-Mix $W $H 0.16;   $t.ThumbHover = Get-Mix $W $H 0.28
            $t.LogBg = Get-Mix $W '#000000' 0.45
        }
    }
    else { $acc = $p.AccentLight }
    $t.Accent = $acc; $t.FocusRing = $acc; $t.OnAccent = Get-OnColor $acc
    return $t
}

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
    # one half-filled circle icon in both modes; the button opens the appearance panel
    $script:btnTheme.ToolTip = $script:T.appearance.Substring(0, 1) + $script:T.appearance.Substring(1).ToLower()
    [System.Windows.Automation.AutomationProperties]::SetName($script:btnTheme, [string]$script:btnTheme.ToolTip)
}

function Set-Theme {
    param([ValidateSet('dark', 'light')][string]$Name)
    $script:Theme = $Name
    $pal = Get-ThemeTable $Name $script:Palette
    foreach ($k in @($pal.Keys)) {
        # explicit [Brush] cast: unwraps the PowerShell PSObject wrapper (WPF rejects a wrapped value for Foreground/Background)
        [System.Windows.Media.Brush]$brush = New-ThemeBrush $k $pal[$k]
        $window.Resources[$k] = $brush
    }

    # category icon colours (plain strings bound in the list, so they are set per theme)
    if ($Name -eq 'dark') { $cc = $CategoryColor } else { $cc = $CategoryColorLight }
    foreach ($key in $CategoryOrder) { if ($script:CatMap.ContainsKey($key)) { $script:CatMap[$key].Color = $cc[$key] } }

    try { if ($script:Hwnd) { [MeshalDwm]::Apply($script:Hwnd, ($Name -eq 'dark'), [string]$pal.BgWindow, [string]$pal.Line) } } catch { }
    Update-ThemeButton
}

# ---- Plurals ("1 app", "3 apps", Arabic dual / few / many) -----------------------------
function Format-Apps {
    param([int]$N)
    if ($script:Lang -eq 'ar') {
        if ($N -eq 1) { return 'برنامج واحد' }
        if ($N -eq 2) { return 'برنامجان' }
        if ($N -ge 11) { return ('{0} برنامجًا' -f $N) }
        return ('{0} برامج' -f $N)
    }
    if ($N -eq 1) { return '1 app' }
    return ('{0} apps' -f $N)
}

function Get-ResultSummary {
    param($Parts)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Parts) {
        $c = [int]$p[1]
        if ($c -gt 0) {
            if ($script:Lang -eq 'ar') { $num = Format-Apps $c } else { $num = [string]$c }
            $out.Add(([string]$script:T[[string]$p[0]]) -f $num)
        }
    }
    if ($out.Count -eq 0) { return [string]$script:T.upFinished }
    if ($script:Lang -eq 'ar') { $sep = [string][char]0x060C + ' ' } else { $sep = ', ' }
    $s = $out -join $sep
    if ($script:Lang -ne 'ar') { $s = $s.Substring(0, 1).ToUpper() + $s.Substring(1) }
    return $s
}

# ---- Themed dialog (replaces the grey Windows MessageBox) -------------------------------
# Buttons: @{ Id; Text; Kind = normal|primary|danger; Cancel = <Esc picks this one>; Focus = <starts focused> }
# Rule: a dangerous action never has the initial focus - the safe button does.
$script:DlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False"
        SizeToContent="Height" Width="500" WindowStartupLocation="CenterOwner" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Ideal" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border Margin="20" Background="{DynamicResource BgPanel}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" CornerRadius="14" Padding="24,22,24,18">
    <Border.Effect><DropShadowEffect Color="#000000" Opacity="0.45" BlurRadius="24" ShadowDepth="6" Direction="270"/></Border.Effect>
    <StackPanel>
      <TextBlock x:Name="dTitle" FontSize="17" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock x:Name="dMsg" Margin="0,8,0,0" FontSize="13.5" LineHeight="20" LineStackingStrategy="BlockLineHeight"
                 Foreground="{DynamicResource TextSec2}" TextWrapping="Wrap" Visibility="Collapsed"/>
      <ScrollViewer x:Name="dScroll" Margin="0,14,0,0" MaxHeight="240" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed">
        <StackPanel>
          <ItemsControl x:Name="dItems" Focusable="False" Visibility="Collapsed">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Grid Margin="0,3">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid Width="28" Height="28">
                    <Border CornerRadius="8" Background="{Binding Color}">
                      <TextBlock Text="{Binding Initial}" Foreground="White" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <Border CornerRadius="8" Background="{Binding TileBg}" Padding="4">
                      <Border.Style>
                        <Style TargetType="Border">
                          <Style.Triggers><DataTrigger Binding="{Binding HasIcon}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers>
                        </Style>
                      </Border.Style>
                      <Image Source="{Binding Icon}" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                    </Border>
                  </Grid>
                  <TextBlock Grid.Column="1" Text="{Binding DisplayName}" Margin="12,0,0,0" VerticalAlignment="Center"
                             Foreground="{DynamicResource TextPrimary}" FontSize="13.5" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
          <ItemsControl x:Name="dRows" Focusable="False" Grid.IsSharedSizeScope="True" Visibility="Collapsed">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Grid Margin="0,4">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" SharedSizeGroup="k"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Border CornerRadius="6" Background="{DynamicResource BadgeBg}" Padding="8,3" Margin="0,0,16,0" HorizontalAlignment="Left" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Key}" FontSize="12.5" Foreground="{DynamicResource TextSoft}" FlowDirection="LeftToRight"/>
                  </Border>
                  <TextBlock Grid.Column="1" Text="{Binding Desc}" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="{DynamicResource TextPrimary}" FontSize="13.5"/>
                </Grid>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
          <TextBlock x:Name="dNotes" FontSize="13" LineHeight="19" LineStackingStrategy="BlockLineHeight" TextWrapping="Wrap"
                     Foreground="{DynamicResource TextSec2}" Visibility="Collapsed"/>
        </StackPanel>
      </ScrollViewer>
      <StackPanel x:Name="dButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,-4,0"/>
    </StackPanel>
  </Border>
</Window>
'@

function Show-Dialog {
    param(
        [string]$Title,
        [string]$Message = '',
        $Items = $null,
        $Rows = $null,
        [string]$Notes = '',
        $Buttons
    )
    $d = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$script:DlgXaml)))
    foreach ($k in @($window.Resources.Keys)) { $d.Resources[$k] = $window.Resources[$k] }   # same colours / button styles as the main window
    $d.Owner = $window
    $d.FlowDirection = $window.FlowDirection
    $d.Title = $Title
    [System.Windows.Automation.AutomationProperties]::SetName($d, $Title)
    $d.FindName('dTitle').Text = $Title
    if ($Message) { $m = $d.FindName('dMsg'); $m.Text = $Message; $m.Visibility = 'Visible' }
    $showScroll = $false
    if ($Items -and @($Items).Count -gt 0) { $c = $d.FindName('dItems'); $c.ItemsSource = @($Items); $c.Visibility = 'Visible'; $showScroll = $true }
    if ($Rows -and @($Rows).Count -gt 0)   { $c = $d.FindName('dRows');  $c.ItemsSource = @($Rows);  $c.Visibility = 'Visible'; $showScroll = $true }
    if ($Notes) { $n = $d.FindName('dNotes'); $n.Text = $Notes; $n.Visibility = 'Visible'; $showScroll = $true }
    if ($showScroll) { $d.FindName('dScroll').Visibility = 'Visible' }

    $panel = $d.FindName('dButtons')
    $script:DlgCancelId = ''
    $focusBtn = $null
    foreach ($b in @($Buttons)) {
        $btn = New-Object System.Windows.Controls.Button
        $key = 'Btn'; if ($b.Kind -eq 'primary') { $key = 'BtnPrimary' } elseif ($b.Kind -eq 'danger') { $key = 'BtnDanger' }
        $btn.Style = [System.Windows.Style]$d.Resources[$key]
        $btn.Content = [string]$b.Text
        $btn.Tag = [string]$b.Id
        $btn.Add_Click({ param($s, $e) $script:DlgResult = [string]$s.Tag; [System.Windows.Window]::GetWindow($s).Close() })
        [void]$panel.Children.Add($btn)
        if ($b.Cancel) { $script:DlgCancelId = [string]$b.Id }
        if ($b.Focus -or (-not $focusBtn)) { $focusBtn = $btn }
    }
    $script:DlgResult = $script:DlgCancelId        # Alt+F4 / Esc = the safe way out
    $fb = $focusBtn
    $d.Add_Loaded({ [void]$fb.Focus() }.GetNewClosure())
    $d.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $script:DlgResult = $script:DlgCancelId; $e.Handled = $true; $s.Close() } })
    [void]$d.ShowDialog()
    return $script:DlgResult
}

# Simple "message + Close" dialog (used for rare cases; everything routine uses Show-Notice instead)
function Show-Msg {
    param([string]$Text, [string]$Caption = $script:T.title, [string]$Buttons = 'OK', [string]$Icon = 'Information')
    [void](Show-Dialog -Title $Caption -Message $Text -Buttons @(@{ Id = 'close'; Text = $script:T.btnClose; Kind = 'primary'; Cancel = $true; Focus = $true }))
    return 'OK'
}

# ---- Inline notice (replaces "OK" pop-ups): at the bottom, never steals focus ----------------
$script:NoticeAction = $null
$script:NoticeAuto   = $false
$script:NoticeTimer  = New-Object System.Windows.Threading.DispatcherTimer
$script:NoticeTimer.Interval = [TimeSpan]::FromSeconds(12)
$script:NoticeTimer.Add_Tick({ $script:NoticeTimer.Stop(); Hide-Notice })

function Hide-Notice {
    $script:NoticeTimer.Stop()
    $script:NoticeAction = $null
    $script:bdNotice.Visibility = 'Collapsed'
}

function Show-Notice {
    param(
        [ValidateSet('ok', 'info', 'warn', 'err')][string]$Kind = 'info',
        [string]$Text,
        [string]$ActionText = '',
        [scriptblock]$Action = $null
    )
    $style = @{
        ok   = @('StOkBg', 'StOkFg', [string][char]0xE73E)
        info = @('StInfoBg', 'StInfoFg', [string][char]0xE946)
        warn = @('StWarnBg', 'StWarnFg', [string][char]0xE7BA)
        err  = @('StErrBg', 'StErrFg', [string][char]0xEA39)
    }[$Kind]
    $script:bdNotice.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $style[0])
    $script:icoNotice.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $style[1])
    $script:icoNotice.Text = $style[2]
    $script:txtNotice.Text = $Text
    $script:NoticeAction = $Action
    if ($ActionText) { $script:btnNoticeAction.Content = $ActionText; $script:btnNoticeAction.Visibility = 'Visible' }
    else { $script:btnNoticeAction.Visibility = 'Collapsed' }
    $script:bdNotice.Visibility = 'Visible'
    # success and info fade away after 12 s (paused while the mouse is over them); warnings and errors stay until dismissed
    $script:NoticeTimer.Stop()
    $script:NoticeAuto = ($Kind -eq 'ok' -or $Kind -eq 'info')
    if ($script:NoticeAuto) { $script:NoticeTimer.Start() }
    try {
        if ($Kind -eq 'err') { $live = [System.Windows.Automation.AutomationLiveSetting]::Assertive } else { $live = [System.Windows.Automation.AutomationLiveSetting]::Polite }
        [System.Windows.Automation.AutomationProperties]::SetLiveSetting($script:txtNotice, $live)
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($script:txtNotice)
        if ($peer) { $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged) }
    } catch { }
}

function Show-WingetMissing {
    Show-Notice -Kind err -Text $script:T.noWinget -ActionText $script:T.noWingetAct -Action { try { Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' } catch { } }
}

function Write-Log {
    param([string]$Text, [switch]$Plain)
    if ($Plain) { $line = $Text } else { $line = ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text) }
    Write-DebugLog $line
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

function Update-EmptyText {
    $t = $script:T
    $q = $script:txtSearch.Text.Trim()
    $icon = [string][char]0xE721; $msg = $t.noResults; $hint = ''; $act = ''; $tag = ''
    if ($q.Length -gt 0) {
        $msg = $t.emptyNoMatch -f $q
        if ($script:Cat -ne 'All') { $hint = $t.emptyInCat -f [string]$t["cat_$($script:Cat)"]; $act = $t.actSearchAll; $tag = 'allapps' }
        else { $hint = $t.emptyTip; $act = $t.clearSearch; $tag = 'clearsearch' }
    }
    elseif ($script:Cat -eq 'Selected') {
        $icon = [string][char]0xE73E; $msg = $t.emptySel2; $hint = $t.emptySelHint; $act = $t.actBrowse; $tag = 'allapps'
    }
    elseif ($script:Cat -eq 'Installed') {
        if ($script:ScanBusy) { $icon = [string][char]0xE895; $msg = $t.emptyScan; $hint = $t.emptyScanHint }
        else { $icon = [string][char]0xE7B8; $msg = $t.emptyInst; $hint = $t.emptyInstHint; $act = $t.actRescan; $tag = 'rescan' }
    }
    $script:txtEmptyIcon.Text = $icon
    $script:txtEmpty.Text = $msg
    $script:txtEmptyHint.Text = $hint
    $script:txtEmptyHint.Visibility = $(if ($hint) { 'Visible' } else { 'Collapsed' })
    $script:btnEmpty.Content = $act
    $script:btnEmpty.Tag = $tag
    $script:btnEmpty.Visibility = $(if ($act) { 'Visible' } else { 'Collapsed' })
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
    $script:txtCatCount.Text = (Format-Apps $list.Count)
    Update-EmptyText
    if ($list.Count -eq 0) { $script:emptyPanel.Visibility = 'Visible' } else { $script:emptyPanel.Visibility = 'Collapsed' }
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
    $t = $script:T
    $n = @($script:Apps | Where-Object { $_.IsSelected }).Count
    $ni = @($script:Apps | Where-Object { $_.IsSelected -and $script:InstalledIds.ContainsKey($_.Id) }).Count
    $script:btnUpgrade.IsEnabled = (-not $script:Busy)
    $script:btnRefresh.IsEnabled = (-not $script:Busy) -and (-not $script:ScanBusy)
    # Uninstall only appears once the selection contains something that can be uninstalled
    if ($ni -gt 0) { $script:btnUninstall.Visibility = 'Visible' } else { $script:btnUninstall.Visibility = 'Collapsed' }
    $script:btnUninstall.IsEnabled = ($ni -gt 0) -and (-not $script:Busy)
    if ($ni -gt 0) { $script:btnUninstall.Content = ($t.uninstallBtn + ' ' + (Format-Apps $ni)) } else { $script:btnUninstall.Content = $t.uninstallBtn }
    # the reason a button is off is written on screen (not only in a tooltip)
    $nNew = $n - $ni          # selected apps that are not on this PC yet (the only ones Install can add)
    if ($n -gt 0) {
        $script:txtSelected.Text = ($t.selected -f $n)
        if ($nNew -eq 0) { $script:txtSelected.Text += ' - ' + $t.allInstalled }
    } else { $script:txtSelected.Text = $t.selectedNone }
    $script:SelItems.Clear(); $shown = 0
    foreach ($sa in $script:Apps) { if ($sa.IsSelected) { if ($shown -lt 8) { $script:SelItems.Add($sa) }; $shown++ } }
    if ($n -gt 8) { $script:txtSelMore.Text = ('+{0}' -f ($n - 8)) } else { $script:txtSelMore.Text = '' }
    $script:CatMap['Selected'].Count = $n
    $script:btnInstall.IsEnabled = ($nNew -gt 0) -and (-not $script:Busy)
    if ($nNew -gt 0) { $script:btnInstall.Content = ($t.install + ' ' + (Format-Apps $nNew)) } else { $script:btnInstall.Content = $t.installNone }
    $script:btnClear.IsEnabled = ($n -gt 0) -and (-not $script:Busy)
    $script:btnInstall.ToolTip = $null
    $script:btnUninstall.ToolTip = $null
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
    $script:btnRefresh.ToolTip = $t.refreshTip
    $script:txtPreview.Text = $t.preview
    if ($ShowPreviewBadge) { $script:bdPreview.Visibility = 'Visible' } else { $script:bdPreview.Visibility = 'Collapsed' }
    $script:btnMore.ToolTip = $t.moreTip
    $script:txtAppearance.Text = $t.appearance
    $script:txtAtmosphere.Text = $t.atmosphere
    $script:txtModeDark.Text = $t.modeDark
    $script:txtModeLight.Text = $t.modeLight
    Build-PaletteButtons
    $script:btnExport.Content = $t.menuExport
    $script:btnImport.Content = $t.menuImport
    $script:btnRefresh.Content = $t.menuRescan
    $script:btnShortcuts.Content = $t.menuShortcuts
    $script:btnAbout.Content = $t.menuAbout
    $script:btnViewGrid.ToolTip = $t.viewGrid
    $script:btnViewList.ToolTip = $t.viewList
    Update-ThemeButton
    $script:btnSelectVisible.Content = $t.selectVisible
    $script:btnClear.Content  = $t.clearSel
    $script:btnInstall.Content = $t.install
    $script:btnCancel.Content = $t.cancel
    $script:btnUpgrade.Content = $t.upgradeAll
    Update-EmptyText
    $script:btnClearSearch.ToolTip = $t.clearSearch
    $script:btnNoticeClose.ToolTip = $t.dismiss
    Set-LogVisible ($script:txtLog.Visibility -eq 'Visible')
    if (-not $script:Busy) { $script:txtProgress.Text = $t.ready }
    # Screen-reader names (icon-only buttons would otherwise be announced as just a glyph)
    $ap = [System.Windows.Automation.AutomationProperties]
    $ap::SetName($script:txtSearch, $t.search)
    $ap::SetName($script:btnClearSearch, $t.clearSearch)
    $ap::SetName($script:btnNoticeClose, $t.dismiss)
    $ap::SetName($script:btnRefresh, $t.refreshTip)
    $ap::SetName($script:btnMore, $t.moreTip)
    $ap::SetName($script:btnLang, $t.langBtn)
    $ap::SetName($script:pbar, $t.title)
    $ap::SetName($script:txtLog, $t.logTitle)

    foreach ($a in $script:Apps) {
        if ($script:Lang -eq 'ar') { $a.DisplayName = $a.NameAr; $a.Tip = $a.DescAr } else { $a.DisplayName = $a.NameEn; $a.Tip = $a.DescEn }
        $a.CategoryName = [string]$t["cat_$($a.Category)"]
        if (-not $a.Tip) { $a.Tip = $a.DisplayName + '  (' + $a.Id + ')' }
        if ($a.StatusKey) { $a.Status = $t[$a.StatusKey] }
    }
    foreach ($key in $CategoryOrder) { $script:CatMap[$key].Name = $t["cat_$key"] }

    Update-Selection
    Save-Settings
}

# ----------------------------------------------------------------------------
# Bundled logo pack: every app ships with a reviewed, high-resolution logo (logos\<app id>.png).
# The pack is embedded in the EXE; loose files in a "logos" folder next to the program override it.
# ----------------------------------------------------------------------------
function Get-SafeLogoName { param([string]$Id) return [regex]::Replace($Id, '[^A-Za-z0-9._\-]', '_') }
$script:LogoBytes = @{}
function Import-LogoPack {
    $map = @{}
    if ($EmbeddedLogosB64.Length -gt 100) {
        try {
            Add-Type -AssemblyName System.IO.Compression
            $zms = New-Object System.IO.MemoryStream (, [Convert]::FromBase64String($EmbeddedLogosB64))
            $zip = New-Object System.IO.Compression.ZipArchive($zms, [System.IO.Compression.ZipArchiveMode]::Read)
            foreach ($en in $zip.Entries) {
                if ($en.Name -notlike '*.png') { continue }
                $st = $en.Open(); $buf = New-Object System.IO.MemoryStream
                try { $st.CopyTo($buf) } finally { $st.Dispose() }
                $map[[System.IO.Path]::GetFileNameWithoutExtension($en.Name)] = $buf.ToArray()
            }
            $zip.Dispose()
        }
        catch { Write-DebugLog ('logo pack: ' + $_.Exception.Message) }
    }
    $dirs = @()
    if ($PSScriptRoot) { $dirs += (Join-Path $PSScriptRoot 'logos') }
    try { $dirs += (Join-Path ([System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)) 'logos') } catch { }
    foreach ($dir in ($dirs | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in [System.IO.Directory]::GetFiles($dir, '*.png')) {
            try { $map[[System.IO.Path]::GetFileNameWithoutExtension($f)] = [System.IO.File]::ReadAllBytes($f) } catch { }
        }
    }
    $script:LogoBytes = $map
}

function Apply-BundledLogos {
    $n = 0
    foreach ($a in $script:Apps) {
        if ($a.HasIcon) { continue }
        $bytes = $script:LogoBytes[(Get-SafeLogoName $a.Id)]
        if (-not $bytes) { continue }
        try {
            $ms = New-Object System.IO.MemoryStream (, $bytes)
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.CreateOptions = 'IgnoreColorProfile'; $bi.StreamSource = $ms; $bi.EndInit(); $bi.Freeze()
            $a.IconSize = 32
            $a.Icon = $bi
            # black/white/grey logo -> a coloured original is fetched in the background (see Start-IconDownloads)
            try { if ([MeshalImg]::Colorfulness($bytes) -lt 0.10) { $a.IconMono = $true } } catch { }
            $n++
        }
        catch { Write-DebugLog ('bundled logo failed for ' + $a.Id + ': ' + $_.Exception.Message) }
    }
    return $n
}

# Microsoft Store apps that ship with Windows: take the real logo from the installed package (cached afterwards).
function Get-StoreLogoPng {
    param([string]$PkgName, [string]$OutFile)
    $pk = Get-AppxPackage -Name $PkgName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pk -or -not $pk.InstallLocation) { return $false }
    [xml]$mx = Get-Content -LiteralPath (Join-Path $pk.InstallLocation 'AppxManifest.xml') -Raw -ErrorAction Stop
    $ve = $mx.SelectNodes("//*[local-name()='VisualElements']") | Select-Object -First 1
    $rel = $null
    if ($ve) { foreach ($at in 'Square150x150Logo', 'Square44x44Logo') { if ($ve.GetAttribute($at)) { $rel = $ve.GetAttribute($at); break } } }
    if (-not $rel) { return $false }
    $full = Join-Path $pk.InstallLocation $rel
    $dir = Split-Path $full -Parent
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($full)
    $best = $null; $bestW = 0
    foreach ($f in [System.IO.Directory]::GetFiles($dir, $stem + '*.png')) {
        if ($f -match 'contrast-|altform-colorful|lightunplated') { continue }
        try {
            $bmp = Load-Icon $f
            if ($bmp.PixelWidth -gt $bestW -and $bmp.PixelWidth -le 1024) { $best = $f; $bestW = $bmp.PixelWidth }
        } catch { }
    }
    if (-not $best -or $bestW -lt 64) { return $false }
    Copy-Item -LiteralPath $best -Destination $OutFile -Force
    return $true
}

function Start-StoreLogos {
    foreach ($a in @($script:Apps | Where-Object { $_.Pkg -and -not $_.HasIcon })) {
        $file = Join-Path $IconCache ('store-' + (Get-SafeLogoName $a.Pkg) + '.png')
        $miss = $file + '.miss'
        if (-not (Test-Path $file)) {
            if ((Test-Path $miss) -and ((Get-Item $miss).LastWriteTime -gt (Get-Date).AddDays(-7))) { continue }
            try { if (-not (Get-StoreLogoPng $a.Pkg $file)) { Set-Content -Path $miss -Value '' } }
            catch { Write-DebugLog ('store logo ' + $a.Pkg + ': ' + $_.Exception.Message) }
        }
        if (Test-Path $file) {
            try { $a.IconSize = 32; $a.Icon = (Load-Icon $file) } catch { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        }
    }
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
    if ($null -eq $script:MonoTodo) {
        $script:MonoTodo = New-Object 'System.Collections.Generic.List[MeshalApp]'
        foreach ($a in $script:Apps) { if ($a.IconKey -and $a.HasIcon -and $a.IconMono) { $script:MonoTodo.Add($a) } }
    }
    if ($script:IconTodo.Count -eq 0 -and $script:MonoTodo.Count -eq 0) { return 0 }
    $files = @{}
    try { foreach ($f in [System.IO.Directory]::GetFiles($IconCache, '*.png')) { $files[[System.IO.Path]::GetFileName($f)] = $f } } catch { }
    for ($i = $script:IconTodo.Count - 1; $i -ge 0; $i--) {
        $a = $script:IconTodo[$i]
        $p = $files[(Get-IconName $a.IconKey)]
        if ($p) {
            try {
                $bmp = Load-Icon $p
                $a.IconSize = [math]::Min(32, [math]::Max(20, $bmp.PixelWidth * 1.5))
                $a.Icon = $bmp
                $script:IconTodo.RemoveAt($i)
            }
            catch { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
    }
    # apps that showed a black/white logo: use the coloured original as soon as it has been downloaded
    for ($i = $script:MonoTodo.Count - 1; $i -ge 0; $i--) {
        $a = $script:MonoTodo[$i]
        $p = $files[(Get-IconName ('color-' + $a.IconKey))]
        if ($p) {
            try {
                $bmp = Load-Icon $p
                $a.IconSize = [math]::Min(32, [math]::Max(20, $bmp.PixelWidth * 1.5))
                $a.Icon = $bmp
                $a.IconMono = $false
            }
            catch { Remove-Item $p -Force -ErrorAction SilentlyContinue }
            $script:MonoTodo.RemoveAt($i)
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
        if (-not $a.IconKey) { continue }
        # a black/white logo is replaced by a coloured one (stored as color-<key>.png); a missing logo is just downloaded
        $needColor = [bool]($a.HasIcon -and $a.IconMono)
        if ($a.HasIcon -and -not $needColor) { continue }
        $jobKey = $a.IconKey; if ($needColor) { $jobKey = 'color-' + $a.IconKey }
        if ($todo.ContainsKey($jobKey)) { continue }
        $miss = (Get-IconPath $jobKey) + '.miss'
        if ((Test-Path $miss) -and ((Get-Item $miss).LastWriteTime -gt (Get-Date).AddDays(-7))) { continue }
        $todo[$jobKey] = @{ Host = $a.IconHost; Slug = $a.IconSlug; Explicit = [bool]$a.IconExplicit; Color = $needColor }
    }
    if ($todo.Count -eq 0) { return }

    $dlScript = {
        param($key, $hostName, $slug, $explicit, $dir, $needColor)
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

        $st = @{ best = 0; responded = $false; n = 0; color = $false }

        # Download one candidate; keep it if it is the sharpest image so far.
        # $direct = the file comes from the app's own website: even a 16px icon is genuine there.
        # Favicon services return a generic 16px globe for unknown sites, so they must be >= 48px; a 16-24px icon would look blurry anyway.
        function Try-Url([string]$u, [bool]$direct = $false) {
            if ($st.best -ge 96 -and $st.color) { return }   # sharp AND coloured = done
            $minW = 48; if ($direct) { $minW = 32 }
            $st.n++
            $tmp = "$file.$($st.n).tmp"
            try {
                $wc.DownloadFile($u, $tmp)
                $st.responded = $true
                $w = 0
                if ((Get-Item $tmp).Length -gt 150) { $w = Get-ImgWidth $tmp }
                if ($w -ge $minW) {
                    # a coloured logo always beats a black/white one; among equals the sharper one wins
                    $isCol = $false
                    try { $isCol = ([MeshalImg]::Colorfulness($tmp) -ge 0.15) } catch { }
                    if ($needColor -and -not $isCol) { }
                    elseif (($isCol -and -not $st.color) -or (($isCol -eq $st.color) -and $w -gt $st.best)) {
                        Copy-Item $tmp "$file.best" -Force; $st.best = $w; $st.color = $isCol
                    }
                }
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
            Try-Url "https://icons.duckduckgo.com/ip3/$h.ico"
            Try-Url "https://$h/favicon.ico" $true
        }

        # Tiny images are generic globes / blurry favicons (rejected above); the letter tile is only the last resort.
        if ($st.best -ge 32) { Move-Item "$file.best" $file -Force }
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
        [void]$ps.AddScript($dlScript).AddArgument($k).AddArgument($todo[$k].Host).AddArgument($todo[$k].Slug).AddArgument($todo[$k].Explicit).AddArgument($IconCache).AddArgument($todo[$k].Color)
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

        # is this winget id installed right now?  (used for installers that never exit by themselves)
        function Test-WingetPresent([string]$id) {
            try {
                $null = & winget list --id $id --exact --accept-source-agreements --disable-interactivity 2>&1
                return ($LASTEXITCODE -eq 0)
            } catch { return $false }
        }

        # runs one winget command (output captured through a temp file so Stop can kill it at any moment)
        # $watchId/$watchWant ('present' after an install, 'absent' after an uninstall): for apps whose installer keeps
        # running after the work is done (Riot Client...) the real state is checked and the job is finished once it matches.
        function Run-Winget([string]$wcmd, [string]$lineId, [string]$lineMode, [bool]$limited = $false, [string]$watchId = '', [string]$watchWant = '') {
            $code = -1
            $lastOutAt = Get-Date; $lastProbeAt = Get-Date; $hits = 0; $assumed = $false
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
                $swRun = [System.Diagnostics.Stopwatch]::StartNew()
                $timedOut = $false
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
                        # a hung installer must not block the whole queue forever (45 min per app, 3 h for "upgrade all")
                        $maxMin = 45; if ($lineMode -eq 'upgrade') { $maxMin = 180 }
                        if ((-not $timedOut) -and (-not $p.HasExited) -and ($swRun.Elapsed.TotalMinutes -gt $maxMin)) {
                            $timedOut = $true
                            $sync.Queue.Enqueue("log|$lineId|Timed out after $maxMin minutes - stopping this installer.")
                            Stop-Tree $p.Id
                        }
                        $exited = $p.HasExited
                    }
                    try {
                        if (Test-Path -LiteralPath $logFile) {
                            $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite,Delete')
                            try {
                                if ($fs.Length -gt $pos) {
                                    $lastOutAt = Get-Date
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
                    # winget has been silent for a while: if the app is already in its final state, the installer is only lingering
                    if ((-not $exited) -and $watchId -and (-not $limited) -and (-not $sync.Cancel)) {
                        $now = Get-Date
                        if ((($now - $lastOutAt).TotalSeconds -ge 20) -and (($now - $lastProbeAt).TotalSeconds -ge 6)) {
                            if ((Test-WingetPresent $watchId) -eq ($watchWant -eq 'present')) { $hits++ } else { $hits = 0 }
                            $lastProbeAt = Get-Date
                            if ($hits -ge 2) {
                                $sync.Queue.Enqueue("log|$lineId|Finished - the installer is still open in the background, closing it.")
                                $assumed = $true
                                Stop-Tree $p.Id
                                $exited = $true
                            }
                        }
                    }
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
                    if ($assumed) { $code = 0 }
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
                $wId = ''; if ($app.Lingers) { $wId = $app.Id }
                $code = Run-Winget $ucmd $app.Id 'install' $false $wId 'absent'
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
            $wId = ''; if ($app.Lingers) { $wId = $app.Id }
            $code = Run-Winget $wcmd $app.Id 'install' $false $wId 'present'

            # Some packages (e.g. Battle.net) refuse to install unless an install location is given
            # (winget error 0x8A15005F = -1978335137): retry once with --location.
            if ($code -eq -1978335137 -and -not $sync.Cancel) {
                $pf = ${env:ProgramFiles(x86)}; if (-not $pf) { $pf = $env:ProgramFiles }
                $folder = switch ($app.Id) { 'Blizzard.BattleNet' { 'Battle.net' } default { ([string]$app.Name -replace '[\\/:*?"<>|]', '').Trim() } }
                if (-not $folder) { $folder = ($app.Id -replace '[^A-Za-z0-9._-]', '_') }
                $loc = Join-Path $pf $folder
                $sync.Queue.Enqueue("log|$($app.Id)|Retrying with install location: $loc")
                $code = Run-Winget ($wcmd + ' --location "' + $loc + '"') $app.Id 'install'
            }

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
    function Norm([string]$s) { return (($s.ToLowerInvariant() -replace '\+', 'plus') -replace '[^\p{L}\p{Nd}]', '') }
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        $text = ''
        try { $text = (& winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-String) } catch { }

        # names of everything registered in "Programs and Features" (machine + current user)
        $names = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'Registry::HKEY_USERS\S-1-5-21-*\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            try {
                foreach ($it in @(Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue)) {
                    if ($it.DisplayName) { [void]$names.Add((Norm ([string]$it.DisplayName))) }
                    $kn = [string]$it.PSChildName
                    if ($kn -and (-not $kn.StartsWith('{'))) { $k1 = Norm $kn; if ($k1.Length -ge 4) { [void]$names.Add($k1) } }
                }
            } catch { }
        }

        # names reported by winget itself (also covers Store apps and entries without a registry name)
        if ($text) {
            foreach ($ln in ($text -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($ln) -or $ln -match '^\s*(Name\s|-{3,})') { continue }
                $c0 = ($ln -split '\s{2,}')[0]
                if ($c0) {
                    $k0 = Norm $c0
                    if ($k0.Length -ge 3) { [void]$names.Add($k0) }
                }
            }
        }
        $result.Names = @($names | Sort-Object)

        foreach ($a in $apps) {
            $hit = $false
            if ($text) {
                $rx = '(?i)(?<![\w\.\-])' + [regex]::Escape($a.Id) + '(?:\.(?:x86|x64|arm64))?(?![\w\.\-])'
                if ($text -match $rx) { $hit = $true }
            }
            if (-not $hit) {
                # candidate names: the catalog name and the winget Id without its publisher (Discord.Discord.PTB -> discordptb)
                $keys = New-Object 'System.Collections.Generic.List[string]'
                $nm = Norm ([string]$a.Name)
                if ($nm.Length -ge 3) { $keys.Add($nm) }
                $parts = ([string]$a.Id) -split '\.'
                if ($parts.Count -ge 2) {
                    $tail = Norm (($parts | Select-Object -Skip 1) -join '')
                    if ($tail.Length -ge 4 -and (-not $keys.Contains($tail))) { $keys.Add($tail) }
                }
                if ($a.Source -eq 'nvapp') {
                    # NVIDIA App is not in winget; its Programs-and-Features entry may carry a version/suffix
                    foreach ($n in $names) { if ($n.StartsWith('nvidiaapp')) { $hit = $true; break } }
                }
                else {
                    foreach ($k in $keys) {
                        if ($names.Contains($k)) { $hit = $true; break }
                        foreach ($n in $names) {
                            if ($n.StartsWith($k)) {
                                # "AppName 1.2.3", "AppName Launcher", "AppName Desktop" ...
                                $rest = $n.Substring($k.Length)
                                if ($rest -match '^(\d+|(launcher|desktop|client|setup)\d*|(\d+bit)?(x64|x86|arm64)?)$') { $hit = $true; break }
                            }
                        }
                        if ($hit) { break }
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
    $script:btnRefresh.IsEnabled = $false
    Write-Log $script:T.scanStart
    if (-not $script:Busy) { $script:txtProgress.Text = $script:T.scanStart }
    if ($script:Cat -eq 'Installed') { Refresh-Grid }
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
    foreach ($a in $script:Apps) { if ($a.StatusKey -eq 'st_installed' -and (-not $set.ContainsKey($a.Id))) { Set-Status $a '' } }
    try { if ($script:ScanResult.Names) { Set-Content -Path (Join-Path $script:SettingsDir 'installed_names.txt') -Value @($script:ScanResult.Names) -Encoding UTF8 } } catch { }
    Mark-Installed
    Update-InstalledCount
    Update-Selection
    if ($script:Cat -eq 'Installed') { Refresh-Grid }
    Write-Log ($script:T.scanDone -f $set.Count)
    try { $script:ScanPs.EndInvoke($script:ScanHandle) } catch { }
    try { $script:ScanPs.Dispose(); $script:ScanRs.Dispose() } catch { }
    $script:ScanBusy = $false
    $script:btnRefresh.IsEnabled = (-not $script:Busy)
    if ((-not $script:Busy) -and ($script:txtProgress.Text -eq $script:T.scanStart)) { $script:txtProgress.Text = $script:T.ready }
    if ($script:Cat -eq 'Installed') { Refresh-Grid }
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
    elseif ($script:Mode -eq 'uninstall') { $summary = Get-ResultSummary @(@('resRemoved', $r.ok), @('resFailed', $r.fail), @('resCancelled', $r.cancel)) }
    else { $summary = Get-ResultSummary @(@('resInstalled', $r.ok), @('resAlready', $r.already), @('resFailed', $r.fail), @('resCancelled', $r.cancel), @('resManual', $r.manual)) }
    $script:AppActive = $false
    $script:AppFrac = 0.0
    $script:txtProgress.Text = $summary
    Write-Log $summary
    if ($r.fail -gt 0) { Set-LogVisible $true }
    try { $script:WorkerPs.EndInvoke($script:WorkerHandle) } catch { }
    try { $script:WorkerPs.Dispose(); $script:WorkerRs.Dispose() } catch { }
    Update-Selection
    if ($script:CloseAfter) { $script:CloseAfter = $false; $window.Close(); return }
    if ($r.fail -gt 0) { $kind = 'err' } else { $kind = 'ok' }
    $script:FinishMsg = @{ Text = $summary; Kind = $kind }
    if ($script:Sync -and $script:Sync.Cancel) {
        # stopped by the user: clear the bar right away
        $script:pbar.Value = 0
        $script:FinishMsg = $null
        Show-Notice -Kind info -Text $summary
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
    if ($Mode -ne 'upgradeall') { $list = @($Sel | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.NameEn; Source = $_.Source; Lingers = $_.Lingers } }) }

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
    # only apps that are not installed yet (installed ones are skipped)
    $sel = @($script:Apps | Where-Object { $_.IsSelected -and (-not $script:InstalledIds.ContainsKey($_.Id)) })
    $t = $script:T
    if ($sel.Count -eq 0) { Show-Notice -Kind warn -Text $t.selectedNone; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Show-WingetMissing; return }
    $n = Format-Apps $sel.Count
    $r = Show-Dialog -Title ($t.dlgInstallTitle -f $n) -Message $t.dlgInstallBody -Items $sel -Buttons @(
        @{ Id = 'cancel'; Text = $t.btnCancel2; Cancel = $true },
        @{ Id = 'go'; Text = ($t.btnInstallN -f $n); Kind = 'primary'; Focus = $true })
    if ($r -ne 'go') { return }
    Hide-Notice
    Start-Work 'install' $sel
}

function Start-Uninstall {
    $sel = @($script:Apps | Where-Object { $_.IsSelected -and $script:InstalledIds.ContainsKey($_.Id) })
    $t = $script:T
    if ($sel.Count -eq 0) { Show-Notice -Kind warn -Text $t.noInstalledSel; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Show-WingetMissing; return }
    $n = Format-Apps $sel.Count
    # dangerous action: the safe button (Cancel) has the initial focus
    $r = Show-Dialog -Title ($t.dlgUninstTitle -f $n) -Message $t.dlgUninstBody -Items $sel -Buttons @(
        @{ Id = 'cancel'; Text = $t.btnCancel2; Cancel = $true; Focus = $true },
        @{ Id = 'go'; Text = ($t.btnUninstN -f $n); Kind = 'danger' })
    if ($r -ne 'go') { return }
    Hide-Notice
    Start-Work 'uninstall' $sel
}

function Start-UpgradeAll {
    $t = $script:T
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Show-WingetMissing; return }
    $r = Show-Dialog -Title $t.dlgUpgTitle -Message $t.dlgUpgBody -Buttons @(
        @{ Id = 'cancel'; Text = $t.btnCancel2; Cancel = $true },
        @{ Id = 'go'; Text = $t.btnUpgAll; Kind = 'primary'; Focus = $true })
    if ($r -ne 'go') { return }
    Hide-Notice
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
            if ($m.Kind -eq 'err') { Show-Notice -Kind err -Text $m.Text -ActionText $script:T.showLog -Action { Set-LogVisible $true } }
            else { Show-Notice -Kind ok -Text $m.Text }
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

# Cards stretch so the row always fills the whole width (no empty strip on the right).
$window.Resources['CardW'] = [double]290
$script:LastCardW = 0.0
$script:ViewMode = 'grid'
function Set-ViewMode {
    param([ValidateSet('grid', 'list')][string]$Mode)
    $script:ViewMode = $Mode
    $on  = $window.Resources['CatSelected']
    if ($Mode -eq 'grid') {
        $script:icApps.ItemTemplate = [System.Windows.DataTemplate]$window.Resources['tplGrid']
        $script:btnViewGrid.Background = $on; $script:btnViewList.Background = [System.Windows.Media.Brushes]::Transparent
    }
    else {
        $script:icApps.ItemTemplate = [System.Windows.DataTemplate]$window.Resources['tplList']
        $script:btnViewList.Background = $on; $script:btnViewGrid.Background = [System.Windows.Media.Brushes]::Transparent
    }
    $script:LastCardW = 0.0
    Update-CardWidth
    try { $script:svApps.ScrollToTop() } catch { }
}
function Update-CardWidth {
    $avail = $svApps.ViewportWidth
    if ($avail -lt 100) { return }
    $minW = 290.0; $gap = 14.0
    if ($script:ViewMode -eq 'list') { $minW = 100000.0 }
    $cols = [Math]::Max(1, [int][Math]::Floor($avail / ($minW + $gap)))
    $w = [Math]::Floor($avail / $cols - $gap - 0.5)
    if ([Math]::Abs($w - $script:LastCardW) -ge 1) {
        $script:LastCardW = $w
        $window.Resources['CardW'] = [double]$w
    }
}
$svApps.Add_SizeChanged({ Update-CardWidth })
$svApps.Add_ScrollChanged({ param($sender, $e) if ($e.ViewportWidthChange -ne 0) { Update-CardWidth } })
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
        $script:txtCatCount.Text = (Format-Apps $script:CurrentList.Count)
    })

# ---- Appearance panel: dark / light mode + colour palettes -------------------------------
function Update-ThemePanel {
    if ($script:Theme -eq 'dark') { $script:btnModeDark.Tag = 'sel'; $script:btnModeLight.Tag = '' }
    else                          { $script:btnModeDark.Tag = '';    $script:btnModeLight.Tag = 'sel' }
    foreach ($c in $script:palGrid.Children) { if ([string]$c.DataContext -eq $script:Palette) { $c.Tag = 'sel' } else { $c.Tag = '' } }
}

$script:PalClick = {
    param($s, $e)
    $script:Palette = [string]$s.DataContext
    Set-Theme $script:Theme
    Save-Settings
    Set-ViewMode $script:ViewMode
    Update-ThemePanel
}

function Build-PaletteButtons {
    $script:palGrid.Children.Clear()
    $i = 0
    foreach ($key in $Palettes.Keys) {
        $p = $Palettes[$key]
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $window.FindResource('PalBtn')
        $btn.DataContext = $key
        if ($i % 2 -eq 0) { $btn.Margin = New-Object System.Windows.Thickness(0, 0, 4, 8) } else { $btn.Margin = New-Object System.Windows.Thickness(4, 0, 0, 8) }
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        # colour preview: a circle, left half = highlight colour, right half = background colour
        $sw = New-Object System.Windows.Controls.Grid
        $sw.Width = 18; $sw.Height = 18; $sw.FlowDirection = 'LeftToRight'
        $sw.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        $el = New-Object System.Windows.Shapes.Ellipse
        [System.Windows.Media.Brush]$bg = New-ThemeBrush 'x' $p.W
        [System.Windows.Media.Brush]$ln = New-ThemeBrush 'x' (Get-Mix $p.W $p.Hi 0.45)
        $el.Fill = $bg; $el.Stroke = $ln; $el.StrokeThickness = 1
        $half = New-Object System.Windows.Shapes.Path
        $half.Data = [System.Windows.Media.Geometry]::Parse('M9,0.5 A8.5,8.5 0 0 0 9,17.5 Z')
        [System.Windows.Media.Brush]$ac = New-ThemeBrush 'x' $p.AccentDark
        $half.Fill = $ac
        [void]$sw.Children.Add($el); [void]$sw.Children.Add($half)
        $tb = New-Object System.Windows.Controls.TextBlock
        if ($script:Lang -eq 'ar') { $tb.Text = $p.Ar } else { $tb.Text = $p.En }
        $tb.VerticalAlignment = 'Center'; $tb.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($sw); [void]$sp.Children.Add($tb)
        $btn.Content = $sp
        $btn.Add_Click($script:PalClick)
        [void]$script:palGrid.Children.Add($btn)
        $i++
    }
    Update-ThemePanel
}

function Close-ThemePanel { $script:themeLayer.Visibility = 'Collapsed'; [void]$script:btnTheme.Focus() }
$btnTheme.Add_Click({
        if ($script:themeLayer.Visibility -eq 'Visible') { Close-ThemePanel }
        else { $script:menuLayer.Visibility = 'Collapsed'; Update-ThemePanel; $script:themeLayer.Visibility = 'Visible'; [void]$script:btnModeDark.Focus() }
    })
$themeLayer.Add_MouseDown({
        param($s, $e)
        if ($e.OriginalSource -eq $script:themeLayer) { Close-ThemePanel }
    })
$btnModeDark.Add_Click({ Set-Theme 'dark'; Save-Settings; Set-ViewMode $script:ViewMode; Update-ThemePanel })
$btnModeLight.Add_Click({ Set-Theme 'light'; Save-Settings; Set-ViewMode $script:ViewMode; Update-ThemePanel })

$lstCats.Add_SelectionChanged({
        $sel = $script:lstCats.SelectedItem
        if ($sel) { $script:Cat = $sel.Key; Refresh-Grid }
    })

$txtSearch.Add_TextChanged({
        if ($script:txtSearch.Text.Length -gt 0) { $script:txtPlaceholder.Visibility = 'Collapsed' } else { $script:txtPlaceholder.Visibility = 'Visible' }
        if ($script:txtSearch.Text.Length -gt 0) { $script:btnClearSearch.Visibility = 'Visible'; $script:bdKbd.Visibility = 'Collapsed' } else { $script:btnClearSearch.Visibility = 'Collapsed'; $script:bdKbd.Visibility = 'Visible' }
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
        $ids = @($script:Apps | Where-Object { $_.IsSelected } | ForEach-Object { $_.Id })
        if ($ids.Count -eq 0) { return }
        foreach ($a in $script:Apps) { $a.IsSelected = $false }
        Update-Selection
        if ($script:Cat -eq 'Selected') { Refresh-Grid }
        # reversible, so no "are you sure": do it, then offer Undo
        $script:UndoIds = $ids
        $undo = {
            foreach ($id in $script:UndoIds) { if ($script:ById.ContainsKey($id)) { $script:ById[$id].IsSelected = $true } }
            Update-Selection
            if ($script:Cat -eq 'Selected') { Refresh-Grid }
        }
        Show-Notice -Kind info -Text ($script:T.clearedN -f (Format-Apps $ids.Count)) -ActionText $script:T.undo -Action $undo
    })

$btnRefresh.Add_Click({ Close-Menu; if ((-not $script:Busy) -and (-not $script:ScanBusy)) { Start-InstalledScan } })
$btnViewGrid.Add_Click({ Set-ViewMode 'grid'; Save-Settings })
$btnViewList.Add_Click({ Set-ViewMode 'list'; Save-Settings })
function Close-Menu { $script:menuLayer.Visibility = 'Collapsed'; [void]$script:btnMore.Focus() }
$btnMore.Add_Click({
        $script:themeLayer.Visibility = 'Collapsed'
        if ($script:menuLayer.Visibility -eq 'Visible') { Close-Menu } else { $script:menuLayer.Visibility = 'Visible'; [void]$script:btnExport.Focus() }
    })
$menuLayer.Add_MouseDown({
        param($s, $e)
        if ($e.OriginalSource -eq $script:menuLayer) { Close-Menu }
    })
$btnExport.Add_Click({ Close-Menu; Export-Selection })
$btnImport.Add_Click({ Close-Menu; Import-Selection })
$btnShortcuts.Add_Click({
        Close-Menu
        $rows = @(foreach ($line in $script:T.shortcutRows) { $p = ([string]$line).Split('|', 2); $o = New-Object MeshalRow; $o.Key = $p[0]; $o.Desc = $p[1]; $o })
        [void](Show-Dialog -Title $script:T.menuShortcuts -Rows $rows -Buttons @(@{ Id = 'close'; Text = $script:T.btnClose; Kind = 'primary'; Cancel = $true; Focus = $true }))
    })
$btnAbout.Add_Click({
        Close-Menu
        $r = Show-Dialog -Title $script:T.title -Message ($script:T.aboutVersion -f $script:AppVersion) -Notes $script:T.aboutDesc -Buttons @(
            @{ Id = 'close'; Text = $script:T.btnClose; Cancel = $true; Focus = $true },
            @{ Id = 'web'; Text = $script:T.aboutOpen; Kind = 'primary' })
        if ($r -eq 'web') { try { Start-Process ('https://github.com/{0}' -f $script:UpdateRepo) } catch { } }
    })
$btnInstall.Add_Click({ Start-Install })
$btnUninstall.Add_Click({ Start-Uninstall })
$btnUpgrade.Add_Click({ Start-UpgradeAll })
$btnNoticeClose.Add_Click({ Hide-Notice })
$btnNoticeAction.Add_Click({ $a = $script:NoticeAction; Hide-Notice; if ($a) { & $a } })
$bdNotice.Add_MouseEnter({ $script:NoticeTimer.Stop() })
$bdNotice.Add_MouseLeave({ if (($script:bdNotice.Visibility -eq 'Visible') -and $script:NoticeAuto) { $script:NoticeTimer.Stop(); $script:NoticeTimer.Start() } })
$btnEmpty.Add_Click({
        switch ([string]$script:btnEmpty.Tag) {
            'clearsearch' { $script:txtSearch.Clear(); [void]$script:txtSearch.Focus() }
            'allapps'     { $script:lstCats.SelectedIndex = 0 }
            'rescan'      { if ((-not $script:Busy) -and (-not $script:ScanBusy)) { Start-InstalledScan } }
        }
    })
try { [System.Windows.Automation.AutomationProperties]::SetLiveSetting($script:txtCatCount, [System.Windows.Automation.AutomationLiveSetting]::Polite) } catch { }

# Ctrl+F jumps to the search box
$window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $script:txtSearch.Focus() | Out-Null; $script:txtSearch.SelectAll(); $e.Handled = $true
        }
    })

function Export-Selection {
    $sel = @($script:Apps | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { Show-Notice -Kind info -Text $script:T.exportNone; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = $script:T.exportTitle; $dlg.Filter = 'MeshalBox selection (*.json)|*.json'; $dlg.FileName = 'meshalbox-selection.json'
    if ($dlg.ShowDialog($window) -ne $true) { return }
    try {
        $obj = [ordered]@{ app = 'MeshalBox'; version = $script:AppVersion; ids = @($sel | ForEach-Object { $_.Id }) }
        [IO.File]::WriteAllText($dlg.FileName, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        $m = $script:T.exportDone -f (Format-Apps $sel.Count), $dlg.FileName
        Write-Log $m
        Show-Notice -Kind ok -Text $m
    } catch { Show-Notice -Kind err -Text $_.Exception.Message }
}

function Import-Selection {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = $script:T.importTitle; $dlg.Filter = 'MeshalBox selection (*.json)|*.json'
    if ($dlg.ShowDialog($window) -ne $true) { return }
    try {
        $j = Get-Content -LiteralPath $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j.ids) { throw 'no ids' }
        $ok = 0; $miss = 0
        foreach ($id in @($j.ids)) {
            if ($script:ById.ContainsKey([string]$id)) { $script:ById[[string]$id].IsSelected = $true; $ok++ } else { $miss++ }
        }
        Update-Selection
        if ($script:Cat -eq 'Selected') { Refresh-Grid }
        if ($miss -gt 0) { $m = $script:T.importMiss -f (Format-Apps $ok), $miss } else { $m = $script:T.importDone -f (Format-Apps $ok) }
        Write-Log $m
        Show-Notice -Kind ok -Text $m
    } catch { Show-Notice -Kind warn -Text $script:T.importFail }
}

$window.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
        if ($e.Key -eq 'Escape' -and $script:themeLayer.Visibility -eq 'Visible') { Close-ThemePanel; $e.Handled = $true }
        elseif ($e.Key -eq 'Escape' -and $script:menuLayer.Visibility -eq 'Visible') { Close-Menu; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'K') { $script:txtSearch.Focus() | Out-Null; $script:txtSearch.SelectAll(); $e.Handled = $true }
        elseif ($e.Key -eq 'Escape' -and $script:txtSearch.Text.Length -gt 0) { $script:txtSearch.Clear(); $e.Handled = $true }
        elseif ($e.Key -eq 'F5' -and (-not $script:Busy) -and (-not $script:ScanBusy)) { Start-InstalledScan; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'S') { Export-Selection; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'O') { Import-Selection; $e.Handled = $true }
    })

function Stop-Work {
        if ($script:Sync) {
            $script:Sync.Cancel = $true
            # kill the running winget / installer right now (and everything it started)
            try { $pr = $script:Sync.Proc; if ($pr -and -not $pr.HasExited) { Stop-Tree $pr.Id } } catch { }
        }
        $script:btnCancel.IsEnabled = $false
        Write-Log $script:T.cancelling
}
$btnCancel.Add_Click({ Stop-Work })

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
                Show-Notice -Kind err -Text ($script:T.updFail -f ' ', $err)
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
        Show-Notice -Kind err -Text ($script:T.updFail -f ' ', $_.Exception.Message)
    }
}

function Invoke-UpdateClick {
    $u = $script:UpdateInfo
    if (-not $u) { return }
    if ($script:Busy) { Show-Notice -Kind warn -Text $script:T.updBusy; return }

    $canAuto = $script:IsCompiledExe -and $u.Url -and ($u.Digest -match '^sha256:[0-9a-fA-F]{64}$') -and ($u.Url -like ('https://github.com/{0}/releases/download/*' -f $script:UpdateRepo))
    $newVer = $u.Tag -replace '^[vV]', ''
    if ($canAuto) { $goText = $script:T.updNow } else { $goText = $script:T.updOpen }
    $ans = Show-Dialog -Title $script:T.updHead -Message ($script:T.updVer -f $script:AppVersion, $newVer) `
        -Notes ($script:T.updNotes + "`n" + (Format-ReleaseNotes $u.Notes)) -Buttons @(
        @{ Id = 'later'; Text = $script:T.updLater; Cancel = $true },
        @{ Id = 'go'; Text = $goText; Kind = 'primary'; Focus = $true })
    if ($ans -ne 'go') { return }

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
            $e.Cancel = $true
            if ($script:InstallTimer.IsEnabled) {
                $r = Show-Dialog -Title $script:T.closeTitle -Message $script:T.closeBody -Buttons @(
                    @{ Id = 'keep'; Text = $script:T.btnKeep; Cancel = $true; Focus = $true },
                    @{ Id = 'stop'; Text = $script:T.btnStopClose; Kind = 'danger' })
                if ($r -eq 'stop') { $script:CloseAfter = $true; Stop-Work }
            }
            else {
                [void](Show-Dialog -Title $script:T.closeUpdTitle -Message $script:T.closeUpd -Buttons @(@{ Id = 'ok'; Text = $script:T.btnClose; Kind = 'primary'; Cancel = $true; Focus = $true }))
            }
        }
    })

# ----------------------------------------------------------------------------
# 10. Start
# ----------------------------------------------------------------------------
try {
    Import-LogoPack
    [void](Apply-BundledLogos)
    Initialize-Categories
    Set-Theme $script:Theme
    Apply-Language
    Set-ViewMode $script:SavedView
    $lstCats.SelectedIndex = 0
    $script:IsAdminNow = $isAdmin

    # Slim scrollbars: force the width directly on every ScrollViewer's vertical bar (does not depend on style lookup)
    function Set-ThinScrollBars($node) {
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
        for ($i = 0; $i -lt $n; $i++) {
            $c = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)
            if ($c -is [System.Windows.Controls.ScrollViewer]) {
                try {
                    [void]$c.ApplyTemplate()
                    $sb = $c.Template.FindName('PART_VerticalScrollBar', $c)
                    if ($sb) { $sb.Width = 8; $sb.MinWidth = 0 }
                } catch { }
            }
            Set-ThinScrollBars $c
        }
    }
    $window.Add_ContentRendered({
            try { Set-ThinScrollBars $window } catch { }
            if ($script:Started) { return }
            $script:Started = $true
            try { Start-StoreLogos } catch { Write-DebugLog ('Start-StoreLogos: ' + $_.Exception.Message) }
            [void](Load-CachedIcons)
            Start-IconDownloads
            Start-InstalledScan
            $wg = Get-Command winget -ErrorAction SilentlyContinue
            if ($wg) { Write-Log ($script:T.wingetOk -f $wg.Source) } else { Write-Log $script:T.noWinget }
            if (-not $script:IsAdminNow) { Write-Log $script:T.adminWarn }
            if (-not $wg) { Show-WingetMissing } elseif (-not $script:IsAdminNow) { Show-Notice -Kind warn -Text $script:T.adminWarn }
            if ($script:CatalogSkipped -gt 0) { Write-Log ($script:T.catSkipped -f $script:CatalogSkipped) }
            if (-not $NoUpdateCheck) { try { Start-UpdateCheck } catch { } }
        })

    [void]$window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Fatal error:`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)", 'MeshalBox', 'OK', 'Error')
}
