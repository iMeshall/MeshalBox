<#
.SYNOPSIS
    PS Package Manager - a bilingual (English / العربية) bulk software installer built on winget.

.DESCRIPTION
    - Browse apps in a categorized grid with logos (cards).
    - Tick as many apps as you like, then install them all in one go.
    - Switch between English and Arabic at any time (button in the top-right corner).
      The Arabic mode also flips the whole layout to right-to-left.
    - Uses winget under the hood, so every app is installed from its official source.

.PARAMETER Language
    'en', 'ar' or 'auto' (default). 'auto' uses your last choice, then the system language.

.PARAMETER NoElevate
    Do not try to relaunch as Administrator.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\PSPackageManager.ps1
    powershell -ExecutionPolicy Bypass -File .\PSPackageManager.ps1 -Language ar

.NOTES
    Requirements: Windows 10/11, Windows PowerShell 5.1 (or PowerShell 7 on Windows),
    winget (App Installer from the Microsoft Store). Internet access is required for
    installs and to fetch the logos (they are cached in %LOCALAPPDATA%\PSPackageManager).
    Save this file as UTF-8 WITH BOM so Arabic text displays correctly in Windows PowerShell 5.1.
#>
param(
    [ValidateSet('auto', 'en', 'ar')][string]$Language = 'auto',
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# 0. Make sure we run in STA (required by WPF) and with Administrator rights
# ----------------------------------------------------------------------------
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($PSCommandPath -and ((-not $isSta) -or ((-not $isAdmin) -and (-not $NoElevate)))) {
    try {
        $exe     = (Get-Process -Id $PID).Path
        $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -Language $Language"
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
if (-not ('PkgAppItem3' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;

public class PkgAppItem3 : INotifyPropertyChanged
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
    public string StatusKey { get; set; }

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

public class PkgCatItem3 : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string name)
    {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }

    public string Key { get; set; }
    public string Glyph { get; set; }
    public string Color { get; set; }

    private string _name;
    public string Name { get { return _name; } set { _name = value; Raise("Name"); } }

    private int _count;
    public int Count { get { return _count; } set { _count = value; Raise("Count"); } }
}
'@
}

# ----------------------------------------------------------------------------
# 2. Translations  (add another language by adding another key here)
# ----------------------------------------------------------------------------
$Strings = @{
    en = @{
        title         = 'PS Package Manager'
        subtitle      = 'Install many programs in one go'
        search        = 'Search apps...'
        langBtn       = 'العربية'
        selectVisible = 'Select shown'
        clearAll      = 'Clear selection'
        install       = 'Install selected'
        cancel        = 'Stop'
        selected      = 'Selected: {0}'
        ready         = 'Ready'
        noResults     = 'No matching apps.'
        cat_All = 'All apps'; cat_Selected = 'Selected'; cat_Browsers = 'Browsers'; cat_Gaming = 'Gaming'
        cat_Communication = 'Communication'; cat_Media = 'Media'; cat_Development = 'Development'
        cat_Utilities = 'Utilities'; cat_Security = 'Security & Network'; cat_Productivity = 'Productivity'
        cat_Design = 'Design & Creative'; cat_Cloud = 'Cloud Storage'; cat_Runtimes = 'Runtimes'
        cat_ProTools = 'Pro Tools'; cat_Microsoft = 'Microsoft Tools'; cat_Selfhosted = 'Self-hosted'; cat_Store = 'Microsoft Store Apps'
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
    }
    ar = @{
        title         = 'مدير البرامج'
        subtitle      = 'ثبّت عدة برامج دفعة واحدة'
        search        = 'ابحث عن برنامج...'
        langBtn       = 'English'
        selectVisible = 'تحديد المعروض'
        clearAll      = 'إلغاء التحديد'
        install       = 'تثبيت المحدد'
        cancel        = 'إيقاف'
        selected      = 'المحدد: {0}'
        ready         = 'جاهز'
        noResults     = 'لا توجد برامج مطابقة.'
        cat_All = 'كل البرامج'; cat_Selected = 'المحدد'; cat_Browsers = 'المتصفحات'; cat_Gaming = 'الألعاب'
        cat_Communication = 'التواصل'; cat_Media = 'الوسائط'; cat_Development = 'البرمجة والتطوير'
        cat_Utilities = 'الأدوات'; cat_Security = 'الأمان والشبكات'; cat_Productivity = 'الإنتاجية والمكتب'
        cat_Design = 'التصميم والإبداع'; cat_Cloud = 'التخزين السحابي'; cat_Runtimes = 'مكتبات التشغيل'
        cat_ProTools = 'أدوات احترافية'; cat_Microsoft = 'أدوات مايكروسوفت'; cat_Selfhosted = 'الاستضافة الذاتية'; cat_Store = 'تطبيقات متجر مايكروسوفت'
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
    }
}

# ----------------------------------------------------------------------------
# 3. Application catalog  (winget id, English name, Arabic name, category, logo domain)
#    Add your own apps by adding one line:  Add-App 'Publisher.App' 'Name' 'الاسم' 'Category' 'site.com'
#    Find ids with:  winget search <name>
# ----------------------------------------------------------------------------
$CategoryOrder = @('All', 'Selected', 'Browsers', 'Gaming', 'Communication', 'Media', 'Development',
                   'Utilities', 'Security', 'Productivity', 'Design', 'Cloud', 'Runtimes',
                   'ProTools', 'Microsoft', 'Selfhosted', 'Store')
$CategoryGlyph = @{
    All = [char]::ConvertFromUtf32(0x1F5C2); Selected = [string][char]0x2705
    Browsers = [char]::ConvertFromUtf32(0x1F310); Gaming = [char]::ConvertFromUtf32(0x1F3AE)
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
    All = '#E5E7EB'; Selected = '#4ADE80'; Browsers = '#60A5FA'; Gaming = '#C084FC'
    Communication = '#34D399'; Media = '#F472B6'; Development = '#38BDF8'; Utilities = '#FBBF24'
    Security = '#F87171'; Productivity = '#A3E635'; Design = '#FB923C'; Cloud = '#7DD3FC'
    Runtimes = '#CBD5E1'
    ProTools = '#FCA5A5'; Microsoft = '#93C5FD'; Selfhosted = '#86EFAC'; Store = '#FDE68A'
}

$script:Apps = New-Object System.Collections.Generic.List[PkgAppItem3]
$script:ById = @{}
$palette = @('#3B82F6', '#8B5CF6', '#EC4899', '#F59E0B', '#10B981', '#06B6D4', '#EF4444', '#6366F1', '#14B8A6', '#F97316')

function Add-App {
    param([string]$Id, [string]$En, [string]$Ar, [string]$Cat, [string]$Domain, [string]$Source = '')
    if (-not $Ar) { $Ar = $En }
    $a = New-Object PkgAppItem3
    $a.Id = $Id; $a.NameEn = $En; $a.NameAr = $Ar; $a.Category = $Cat; $a.Domain = $Domain; $a.Source = $Source
    $a.Initial = $En.Substring(0, 1).ToUpper()
    $sum = 0; foreach ($ch in $Id.ToCharArray()) { $sum += [int]$ch }
    $a.Color = $palette[$sum % $palette.Count]
    $script:Apps.Add($a)
    $script:ById[$Id] = $a
}

# Browsers
Add-App 'Google.Chrome'            'Google Chrome'   'جوجل كروم'          'Browsers' 'chrome.com'
Add-App 'Mozilla.Firefox'          'Firefox'         'فايرفوكس'           'Browsers' 'firefox.com'
Add-App 'Microsoft.Edge'           'Microsoft Edge'  'مايكروسوفت إيدج'    'Browsers' 'microsoftedge.microsoft.com'
Add-App 'Brave.Brave'              'Brave'           'بريف'               'Browsers' 'brave.com'
Add-App 'Opera.Opera'              'Opera'           'أوبرا'              'Browsers' 'opera.com'
Add-App 'Vivaldi.Vivaldi'          'Vivaldi'         'فيفالدي'            'Browsers' 'vivaldi.com'
Add-App 'TorProject.TorBrowser'    'Tor Browser'     'متصفح تور'          'Browsers' 'torproject.org'

# Gaming
Add-App 'Valve.Steam'                          'Steam'                'ستيم'                 'Gaming' 'steampowered.com'
Add-App 'EpicGames.EpicGamesLauncher'          'Epic Games Launcher'  'إيبك جيمز'            'Gaming' 'epicgames.com'
Add-App 'GOG.Galaxy'                           'GOG Galaxy'           'جي أو جي جالاكسي'     'Gaming' 'gog.com'
Add-App 'ElectronicArts.EADesktop'             'EA app'               'تطبيق EA'             'Gaming' 'ea.com'
Add-App 'Ubisoft.Connect'                      'Ubisoft Connect'      'يوبيسوفت كونكت'       'Gaming' 'ubisoft.com'
Add-App 'RockstarGames.Launcher'               'Rockstar Games Launcher' 'مشغّل روكستار'    'Gaming' 'rockstargames.com'
Add-App 'Blizzard.BattleNet'                   'Battle.net'           'باتل نت'              'Gaming' 'battle.net'
Add-App 'Mojang.MinecraftLauncher'             'Minecraft Launcher'   'مشغّل ماين كرافت'      'Gaming' 'minecraft.net'
Add-App 'Playnite.Playnite'                    'Playnite'             'بلاي نايت'            'Gaming' 'playnite.link'
Add-App 'HeroicGamesLauncher.HeroicGamesLauncher' 'Heroic Games Launcher' 'هيروك'            'Gaming' 'heroicgameslauncher.com'
Add-App 'ItchIo.Itch'                          'itch.io'              'إيتش آيو'             'Gaming' 'itch.io'
Add-App 'Libretro.RetroArch'                   'RetroArch'            'ريترو آرك'            'Gaming' 'retroarch.com'
Add-App 'https://www.nvidia.com/en-us/software/nvidia-app/' 'NVIDIA App' 'تطبيق NVIDIA' 'Gaming' 'nvidia.com' 'web'
Add-App 'Overwolf.Overwolf'                    'Overwolf'             'أوفروولف'             'Gaming' 'overwolf.com'
Add-App 'MoonlightGameStreamingProject.Moonlight' 'Moonlight'         'مون لايت'             'Gaming' 'moonlight-stream.org'
Add-App 'Parsec.Parsec'                        'Parsec'               'بارسك'                'Gaming' 'parsec.app'
Add-App 'Guru3D.Afterburner'                   'MSI Afterburner'      'إم إس آي أفتربيرنر'    'Gaming' 'msi.com'

# Communication
Add-App 'Discord.Discord'                 'Discord'      'ديسكورد'          'Communication' 'discord.com'
Add-App 'Telegram.TelegramDesktop'        'Telegram'     'تيليجرام'         'Communication' 'telegram.org'
Add-App 'Zoom.Zoom'                       'Zoom'         'زووم'             'Communication' 'zoom.us'
Add-App 'Microsoft.Teams'                 'Microsoft Teams' 'مايكروسوفت تيمز' 'Communication' 'teams.microsoft.com'
Add-App 'SlackTechnologies.Slack'         'Slack'        'سلاك'             'Communication' 'slack.com'
Add-App 'OpenWhisperSystems.Signal'       'Signal'       'سيجنال'           'Communication' 'signal.org'
Add-App 'Mozilla.Thunderbird'             'Thunderbird'  'ثندربيرد'         'Communication' 'thunderbird.net'

# Media
Add-App 'VideoLAN.VLC'                    'VLC media player' 'مشغّل VLC'     'Media' 'videolan.org'
Add-App 'OBSProject.OBSStudio'            'OBS Studio'   'أو بي إس ستوديو'  'Media' 'obsproject.com'
Add-App 'Spotify.Spotify'                 'Spotify'      'سبوتيفاي'         'Media' 'spotify.com'
Add-App 'Audacity.Audacity'               'Audacity'     'أوداسيتي'         'Media' 'audacityteam.org'
Add-App 'HandBrake.HandBrake'             'HandBrake'    'هاند بريك'        'Media' 'handbrake.fr'
Add-App 'XBMCFoundation.Kodi'             'Kodi'         'كودي'             'Media' 'kodi.tv'
Add-App 'Daum.PotPlayer'                  'PotPlayer'    'بوت بلاير'        'Media' 'potplayer.daum.net'
Add-App 'CodecGuide.K-LiteCodecPack.Standard' 'K-Lite Codec Pack' 'حزمة الترميز K-Lite' 'Media' 'codecguide.com'
Add-App 'Gyan.FFmpeg'                     'FFmpeg'       'إف إف إم بيج'     'Media' 'ffmpeg.org'
Add-App 'Apple.iTunes'                    'iTunes'       'آي تيونز'         'Media' 'apple.com'
Add-App 'PeterPawlowski.foobar2000'       'foobar2000'   'فوبار 2000'       'Media' 'foobar2000.org'

# Development
Add-App 'Microsoft.VisualStudioCode'      'Visual Studio Code' 'فيجوال ستوديو كود' 'Development' 'code.visualstudio.com'
Add-App 'Microsoft.VisualStudio.2022.Community' 'Visual Studio 2022' 'فيجوال ستوديو 2022' 'Development' 'visualstudio.microsoft.com'
Add-App 'Git.Git'                         'Git'          'جيت'              'Development' 'git-scm.com'
Add-App 'GitHub.GitHubDesktop'            'GitHub Desktop' 'جيت هب ديسكتوب' 'Development' 'desktop.github.com'
Add-App 'OpenJS.NodeJS.LTS'               'Node.js LTS'  'نود جي إس'        'Development' 'nodejs.org'
Add-App 'EclipseAdoptium.Temurin.21.JDK'  'Java JDK 21'  'جافا JDK 21'      'Development' 'adoptium.net'
Add-App 'Notepad++.Notepad++'             'Notepad++'    'نوتباد++'         'Development' 'notepad-plus-plus.org'
Add-App 'SublimeHQ.SublimeText.4'         'Sublime Text' 'سبلايم تكست'      'Development' 'sublimetext.com'
Add-App 'Docker.DockerDesktop'            'Docker Desktop' 'دوكر ديسكتوب'   'Development' 'docker.com'
Add-App 'JetBrains.IntelliJIDEA.Community' 'IntelliJ IDEA CE' 'إنتليج آيديا' 'Development' 'jetbrains.com'
Add-App 'Google.AndroidStudio'            'Android Studio' 'أندرويد ستوديو' 'Development' 'developer.android.com'
Add-App 'Unity.UnityHub'                  'Unity Hub'    'يونيتي هب'        'Development' 'unity.com'
Add-App 'Microsoft.WindowsTerminal'       'Windows Terminal' 'طرفية ويندوز' 'Development' 'microsoft.com'
Add-App 'Microsoft.PowerShell'            'PowerShell 7' 'باورشل 7'         'Development' 'microsoft.com'
Add-App 'Postman.Postman'                 'Postman'      'بوستمان'          'Development' 'postman.com'
Add-App 'WinSCP.WinSCP'                   'WinSCP'       'وين إس سي بي'     'Development' 'winscp.net'
Add-App 'PuTTY.PuTTY'                     'PuTTY'        'باتي'             'Development' 'putty.org'

# Utilities
Add-App '7zip.7zip'                       '7-Zip'        'سفن زيب'          'Utilities' '7-zip.org'
Add-App 'RARLab.WinRAR'                   'WinRAR'       'وين رار'          'Utilities' 'win-rar.com'
Add-App 'Microsoft.PowerToys'             'PowerToys'    'باور توايز'       'Utilities' 'microsoft.com'
Add-App 'voidtools.Everything'            'Everything'   'إيفري ثينج'       'Utilities' 'voidtools.com'
Add-App 'Flow-Launcher.Flow-Launcher'     'Flow Launcher' 'فلو لانشر'       'Utilities' 'flowlauncher.com'
Add-App 'ShareX.ShareX'                   'ShareX'       'شير إكس'          'Utilities' 'getsharex.com'
Add-App 'CPUID.CPU-Z'                     'CPU-Z'        'سي بي يو زد'      'Utilities' 'cpuid.com'
Add-App 'TechPowerUp.GPU-Z'               'GPU-Z'        'جي بي يو زد'      'Utilities' 'techpowerup.com'
Add-App 'REALiX.HWiNFO'                   'HWiNFO'       'إتش دبليو إنفو'   'Utilities' 'hwinfo.com'
Add-App 'CrystalDewWorld.CrystalDiskInfo' 'CrystalDiskInfo' 'كريستال ديسك إنفو' 'Utilities' 'crystalmark.info'
Add-App 'Wagnardsoft.DisplayDriverUninstaller' 'Display Driver Uninstaller' 'أداة إزالة تعريفات الشاشة' 'Utilities' 'wagnardsoft.com'
Add-App 'Piriform.CCleaner'               'CCleaner'     'سي كلينر'         'Utilities' 'ccleaner.com'
Add-App 'WinDirStat.WinDirStat'           'WinDirStat'   'وين دير ستات'     'Utilities' 'windirstat.net'
Add-App 'Rufus.Rufus'                     'Rufus'        'روفوس'            'Utilities' 'rufus.ie'
Add-App 'Balena.Etcher'                   'balenaEtcher' 'بالينا إتشر'      'Utilities' 'etcher.balena.io'
Add-App 'Ventoy.Ventoy'                   'Ventoy'       'فينتوي'           'Utilities' 'ventoy.net'
Add-App 'TeamViewer.TeamViewer'           'TeamViewer'   'تيم فيور'         'Utilities' 'teamviewer.com'
Add-App 'qBittorrent.qBittorrent'         'qBittorrent'  'كيو بت تورنت'     'Utilities' 'qbittorrent.org'
Add-App 'AutoHotkey.AutoHotkey'           'AutoHotkey'   'أوتو هوت كي'     'Utilities' 'autohotkey.com'

# Security & Network
Add-App 'Malwarebytes.Malwarebytes'       'Malwarebytes' 'مالوير بايتس'     'Security' 'malwarebytes.com'
Add-App 'Bitwarden.Bitwarden'             'Bitwarden'    'بيتواردن'         'Security' 'bitwarden.com'
Add-App 'KeePassXCTeam.KeePassXC'         'KeePassXC'    'كي باس إكس سي'    'Security' 'keepassxc.org'
Add-App 'IDRIX.VeraCrypt'                 'VeraCrypt'    'فيرا كريبت'       'Security' 'veracrypt.fr'
Add-App 'WireGuard.WireGuard'             'WireGuard'    'وايرجارد'         'Security' 'wireguard.com'
Add-App 'Cloudflare.Warp'                 'Cloudflare WARP' 'كلاودفلير وارب' 'Security' 'cloudflare.com'
Add-App 'NordVPN.NordVPN'                 'NordVPN'      'نورد في بي إن'    'Security' 'nordvpn.com'
Add-App 'WiresharkFoundation.Wireshark'   'Wireshark'    'وايرشارك'         'Security' 'wireshark.org'
Add-App 'Insecure.Nmap'                   'Nmap'         'إن ماب'           'Security' 'nmap.org'

# Productivity
Add-App 'TheDocumentFoundation.LibreOffice' 'LibreOffice' 'ليبر أوفيس'      'Productivity' 'libreoffice.org'
Add-App 'ONLYOFFICE.DesktopEditors'       'ONLYOFFICE'   'أونلي أوفيس'      'Productivity' 'onlyoffice.com'
Add-App 'Adobe.Acrobat.Reader.64-bit'     'Adobe Acrobat Reader' 'أدوبي أكروبات ريدر' 'Productivity' 'adobe.com'
Add-App 'SumatraPDF.SumatraPDF'           'SumatraPDF'   'سوماترا PDF'      'Productivity' 'sumatrapdfreader.org'
Add-App 'Foxit.FoxitReader'               'Foxit Reader' 'فوكسيت ريدر'      'Productivity' 'foxit.com'
Add-App 'Notion.Notion'                   'Notion'       'نوشن'             'Productivity' 'notion.so'
Add-App 'Obsidian.Obsidian'               'Obsidian'     'أوبسيديان'        'Productivity' 'obsidian.md'
Add-App 'Joplin.Joplin'                   'Joplin'       'جوبلين'           'Productivity' 'joplinapp.org'
Add-App 'calibre.calibre'                 'calibre'      'كاليبر'           'Productivity' 'calibre-ebook.com'

# Design & Creative
Add-App 'Inkscape.Inkscape'               'Inkscape'     'إنكسكيب'          'Design' 'inkscape.org'
Add-App 'KDE.Krita'                       'Krita'        'كريتا'            'Design' 'krita.org'
Add-App 'BlenderFoundation.Blender'       'Blender'      'بلندر'            'Design' 'blender.org'
Add-App 'dotPDN.PaintDotNet'              'Paint.NET'    'بينت دوت نت'      'Design' 'getpaint.net'
Add-App 'IrfanSkiljan.IrfanView'          'IrfanView'    'إرفان فيو'        'Design' 'irfanview.com'
Add-App 'darktable.darktable'             'darktable'    'دارك تيبل'        'Design' 'darktable.org'
Add-App 'Figma.Figma'                     'Figma'        'فيجما'            'Design' 'figma.com'
Add-App 'BlackmagicDesign.DaVinciResolve' 'DaVinci Resolve' 'دافنشي ريزولف' 'Design' 'blackmagicdesign.com'
Add-App 'Meltytech.Shotcut'               'Shotcut'      'شوت كت'           'Design' 'shotcut.org'
Add-App 'KDE.Kdenlive'                    'Kdenlive'     'كدن لايف'         'Design' 'kdenlive.org'

# Cloud Storage
Add-App 'Dropbox.Dropbox'                 'Dropbox'      'دروب بوكس'        'Cloud' 'dropbox.com'
Add-App 'Google.GoogleDrive'              'Google Drive' 'جوجل درايف'       'Cloud' 'drive.google.com'
Add-App 'Microsoft.OneDrive'              'OneDrive'     'ون درايف'         'Cloud' 'onedrive.live.com'
Add-App 'Mega.MEGASync'                   'MEGAsync'     'ميجا سينك'        'Cloud' 'mega.io'
Add-App 'Syncthing.Syncthing'             'Syncthing'    'سينك ثينج'        'Cloud' 'syncthing.net'
Add-App 'Nextcloud.NextcloudDesktop'      'Nextcloud'    'نيكست كلاود'      'Cloud' 'nextcloud.com'

# Runtimes
Add-App 'Microsoft.VCRedist.2015+.x64'    'Visual C++ Redist x64' 'مكتبات Visual C++ (64)' 'Runtimes' 'microsoft.com'
Add-App 'Microsoft.VCRedist.2015+.x86'    'Visual C++ Redist x86' 'مكتبات Visual C++ (32)' 'Runtimes' 'microsoft.com'
Add-App 'Microsoft.DotNet.DesktopRuntime.8' '.NET Desktop Runtime 8' 'بيئة .NET 8' 'Runtimes' 'dotnet.microsoft.com'
Add-App 'Microsoft.DirectX'               'DirectX Runtime' 'مكتبات DirectX'  'Runtimes' 'microsoft.com'
Add-App 'Oracle.JavaRuntimeEnvironment'   'Java Runtime (JRE)' 'بيئة جافا JRE' 'Runtimes' 'java.com'
Add-App 'Microsoft.EdgeWebView2Runtime'   'WebView2 Runtime' 'بيئة WebView2'  'Runtimes' 'microsoft.com'

# More apps - Browsers
Add-App 'Hibbiki.Chromium' 'Chromium' 'كروميوم' 'Browsers' 'chromium.org'
Add-App 'Mozilla.Firefox.ESR' 'Firefox ESR' 'فايرفوكس ESR' 'Browsers' 'mozilla.org'
Add-App 'Ablaze.Floorp' 'Floorp' 'فلورب' 'Browsers' 'floorp.app'
Add-App 'ImputNet.Helium' 'Helium' 'هيليوم' 'Browsers' 'helium.computer'
Add-App 'LibreWolf.LibreWolf' 'LibreWolf' 'ليبر وولف' 'Browsers' 'librewolf.net'
Add-App 'MullvadVPN.MullvadBrowser' 'Mullvad Browser' 'متصفح مولفاد' 'Browsers' 'mullvad.net'
Add-App 'eloston.ungoogled-chromium' 'Ungoogled Chromium' 'أنجوجلد كروميوم' 'Browsers' ''
Add-App 'Waterfox.Waterfox' 'Waterfox' 'ووترفوكس' 'Browsers' 'waterfox.net'
Add-App 'Zen-Team.Zen-Browser' 'Zen Browser' 'متصفح زين' 'Browsers' 'zen-browser.app'

# More apps - Gaming
Add-App 'Cemu.Cemu' 'Cemu' 'سيمو' 'Gaming' 'cemu.info'
Add-App 'Overwolf.CurseForge' 'CurseForge' 'كيرس فورج' 'Gaming' 'overwolf.com'
Add-App 'ES-DE.EmulationStation-DE' 'EmulationStation Desktop Edition' 'إميوليشن ستيشن' 'Gaming' 'es-de.org'
Add-App 'Nvidia.GeForceNow' 'GeForce NOW' 'جيفورس ناو' 'Gaming' 'nvidia.com'
Add-App 'Modrinth.ModrinthApp' 'Modrinth App' 'مودرينث' 'Gaming' 'modrinth.com'
Add-App 'PrismLauncher.PrismLauncher' 'Prism Launcher' 'بريزم لانشر' 'Gaming' 'prismlauncher.org'
Add-App 'Roblox.Roblox' 'Roblox' 'روبلوكس' 'Gaming' 'roblox.com'
Add-App 'VirtualDesktop.Streamer' 'Virtual Desktop Streamer' 'فيرتشوال ديسكتوب ستريمر' 'Gaming' 'vrdesktop.net'

# More apps - Communication
Add-App 'Betterbird.Betterbird' 'Betterbird' 'بيتربيرد' 'Communication' 'betterbird.eu'
Add-App 'ChatterinoTeam.Chatterino' 'Chatterino' 'تشاتيرينو' 'Communication' 'chatterino.com'
Add-App 'SpikeHD.Dorion' 'Dorion' 'دوريون' 'Communication' 'spikehd.dev'
Add-App 'Element.Element' 'Element' 'إلمنت' 'Communication' 'element.io'
Add-App 'Proton.ProtonMail' 'Proton Mail' 'بروتون ميل' 'Communication' 'proton.me'
Add-App 'Tox.qTox' 'QTox' 'كيو توكس' 'Communication' 'qtox.github.io'
Add-App 'TeamSpeakSystems.TeamSpeakClient' 'TeamSpeak 3' 'تيم سبيك 3' 'Communication' 'teamspeak.com'
Add-App 'TeamSpeakSystems.TeamSpeakClient.Beta.6' 'TeamSpeak 6' 'تيم سبيك 6' 'Communication' 'teamspeak.com'
Add-App 'Vencord.Vesktop' 'Vesktop' 'فيسكتوب' 'Communication' 'vesktop.dev'
Add-App 'Rakuten.Viber' 'Viber' 'فايبر' 'Communication' 'viber.com'
Add-App '9NKSQGP7F2NH' 'WhatsApp Desktop' 'واتساب' 'Communication' 'whatsapp.com' 'msstore'

# More apps - Media
Add-App 'AIMP.AIMP' 'AIMP' 'مشغّل AIMP' 'Media' 'aimp.ru'
Add-App 'File-New-Project.EarTrumpet' 'EarTrumpet' 'إير ترمبت' 'Media' 'eartrumpet.app'
Add-App 'AdrienAllard.FileConverter' 'File Converter' 'محوّل الملفات' 'Media' 'file-converter.io'
Add-App 'GIMP.GIMP.3' 'GIMP' 'جيمب 3' 'Media' 'gimp.org'
Add-App 'DuongDieuPhap.ImageGlass' 'ImageGlass' 'عارض ImageGlass' 'Media' 'imageglass.org'
Add-App 'clsid2.mpc-hc' 'Media Player Classic - Home Cinema' 'مشغّل MPC-HC' 'Media' 'mpc-hc.org'
Add-App 'mpc-qt.mpc-qt' 'mpc-qt' 'مشغّل mpc-qt' 'Media' 'mpc-qt.github.io'
Add-App 'shinchiro.mpv' 'mpv' 'مشغّل mpv' 'Media' 'mpv.io'
Add-App 'nomacs.nomacs' 'nomacs' 'نوماكس' 'Media' 'nomacs.org'

# More apps - Development
Add-App 'Amazon.Corretto.21.JDK' 'Amazon Corretto 21' 'أمازون كوريتو 21' 'Development' 'aws.amazon.com'
Add-App 'Amazon.Corretto.25.JDK' 'Amazon Corretto 25' 'أمازون كوريتو 25' 'Development' 'aws.amazon.com'
Add-App 'Amazon.Corretto.8.JDK' 'Amazon Corretto 8' 'أمازون كوريتو 8' 'Development' 'aws.amazon.com'
Add-App 'Bruno.Bruno' 'Bruno' 'برونو' 'Development' 'usebruno.com'
Add-App '9NT1R1C2HH7J' 'ChatGPT Desktop' 'تشات جي بي تي' 'Development' 'openai.com' 'msstore'
Add-App 'Anthropic.ClaudeCode' 'Claude Code' 'كلود كود' 'Development' 'code.claude.com'
Add-App 'Anthropic.Claude' 'Claude Desktop' 'كلود (سطح المكتب)' 'Development' 'claude.ai'
Add-App 'Kitware.CMake' 'CMake' 'سي ميك' 'Development' 'cmake.org'
Add-App 'OpenAI.Codex' 'Codex' 'كوديكس' 'Development' 'developers.openai.com'
Add-App 'Anysphere.Cursor' 'Cursor' 'كيرسر' 'Development' 'cursor.com'
Add-App 'Schniz.fnm' 'Fast Node Manager' 'مدير نود السريع' 'Development' ''
Add-App 'GitExtensionsTeam.GitExtensions' 'Git Extensions' 'جيت إكستنشنز' 'Development' 'gitextensions.github.io'
Add-App 'GitHub.cli' 'GitHub CLI' 'جيت هب CLI' 'Development' 'cli.github.com'
Add-App 'GoLang.Go' 'Go' 'لغة جو (Go)' 'Development' 'go.dev'
Add-App 'JetBrains.Toolbox' 'Jetbrains Toolbox' 'جيت براينز تولبوكس' 'Development' 'jetbrains.com'
Add-App 'JesseDuffield.lazygit' 'Lazygit' 'ليزي جيت' 'Development' ''
Add-App 'rjpcomputing.luaforwindows' 'Lua' 'لوا' 'Development' ''
Add-App 'Neovim.Neovim' 'Neovim' 'نيوفيم' 'Development' 'neovim.io'
Add-App 'OpenJS.NodeJS' 'NodeJS' 'نود جي إس (الأحدث)' 'Development' 'nodejs.org'
Add-App 'JanDeDobbeleer.OhMyPosh' 'Oh My Posh' 'أوه ماي بوش' 'Development' 'ohmyposh.dev'
Add-App 'pnpm.pnpm' 'pnpm' 'بي إن بي إم' 'Development' 'pnpm.io'
Add-App 'Python.Python.3.14' 'Python3' 'بايثون 3.14' 'Development' 'python.org'
Add-App 'RubyInstallerTeam.Ruby.4.0' 'Ruby' 'روبي' 'Development' 'rubyinstaller.org'
Add-App 'Rustlang.Rust.MSVC' 'Rust' 'راست' 'Development' 'rust-lang.org'
Add-App 'Starship.Starship' 'Starship' 'ستارشيب' 'Development' 'starship.rs'
Add-App 'WinsiderSS.SystemInformer' 'System Informer' 'سيستم إنفورمر' 'Development' 'systeminformer.com'
Add-App 'astral-sh.uv' 'uv' 'يو في (uv)' 'Development' 'docs.astral.sh'
Add-App 'Hashicorp.Vagrant' 'Vagrant' 'فاجرانت' 'Development' 'developer.hashicorp.com'
Add-App 'Microsoft.VisualStudio.Community' 'Visual Studio 2026' 'فيجوال ستوديو 2026' 'Development' 'visualstudio.microsoft.com'
Add-App 'VSCodium.VSCodium' 'VS Codium' 'في إس كوديوم' 'Development' 'vscodium.com'
Add-App 'Yarn.Yarn' 'Yarn' 'يارن' 'Development' 'yarnpkg.com'
Add-App 'ZedIndustries.Zed' 'Zed' 'زد' 'Development' 'zed.dev'

# More apps - Utilities
Add-App 'AgileBits.1Password' '1Password' 'ون باسوورد' 'Utilities' '1password.com'
Add-App 'amir1376.ABDownloadManager' 'AB Download Manager' 'مدير التحميل AB' 'Utilities' 'abdownloadmanager.com'
Add-App 'AnyDesk.AnyDesk' 'AnyDesk' 'أني ديسك' 'Utilities' 'anydesk.com'
Add-App 'Blur009.BlurAutoClicker' 'BlurAutoClicker' 'النقر التلقائي Blur' 'Utilities' 'blur009.vercel.app'
Add-App 'Klocman.BulkCrapUninstaller' 'Bulk Crap Uninstaller' 'أداة إزالة البرامج BCU' 'Utilities' 'bcuninstaller.com'
Add-App 'CrystalDewWorld.CrystalDiskMark' 'Crystal Disk Mark' 'كريستال ديسك مارك' 'Utilities' 'crystalmark.info'
Add-App 'Deskflow.Deskflow' 'Deskflow' 'ديسك فلو' 'Utilities' ''
Add-App 'ente-io.auth-desktop' 'Ente Auth' 'إنتي أوث' 'Utilities' 'ente.io'
Add-App 'flux.flux' 'F.lux' 'إف لكس' 'Utilities' 'justgetflux.com'
Add-App 'FilesCommunity.Files' 'Files' 'فايلز' 'Utilities' 'files.community'
Add-App 'glzr-io.glazewm' 'GlazeWM' 'جليز دبليو إم' 'Utilities' ''
Add-App 'Hugo.Hugo.Extended' 'Hugo' 'هوغو' 'Utilities' 'gohugo.io'
Add-App 'MHNexus.HxD' 'HxD Hex Editor' 'محرر HxD' 'Utilities' 'mh-nexus.de'
Add-App 'Tonec.InternetDownloadManager' 'Internet Download Manager' 'إنترنت داونلود مانجر' 'Utilities' 'internetdownloadmanager.com'
Add-App 'sylikc.JPEGView' 'JPEG View' 'عارض JPEG' 'Utilities' ''
Add-App 'MiniTool.PartitionWizard.Free' 'MiniTool Partition Wizard' 'ميني تول لإدارة الأقراص' 'Utilities' 'partitionwizard.com'
Add-App 'rcmaehl.MSEdgeRedirect' 'MSEdgeRedirect' 'MSEdgeRedirect' 'Utilities' ''
Add-App 'M2Team.NanaZip' 'NanaZip' 'نانا زيب' 'Utilities' 'nanazip.org'
Add-App 'Nilesoft.Shell' 'Nilesoft Shell' 'نايل سوفت شل' 'Utilities' 'nilesoft.org'
Add-App 'TechPowerUp.NVCleanstall' 'NVCleanstall' 'إن في كلين ستول' 'Utilities' 'techpowerup.com'
Add-App 'xM4ddy.OFGB' 'OFGB' 'OFGB' 'Utilities' ''
Add-App 'OPAutoClicker.OPAutoClicker' 'OPAutoClicker' 'OP Auto Clicker' 'Utilities' 'opautoclicker.com'
Add-App 'OpenRGB.OpenRGB' 'OpenRGB' 'أوبن آر جي بي' 'Utilities' 'openrgb.org'
Add-App 'Oracle.VirtualBox' 'Oracle VirtualBox' 'فيرتشوال بوكس' 'Utilities' 'virtualbox.org'
Add-App 'Giorgiotani.Peazip' 'PeaZip' 'بي زيب' 'Utilities' 'peazip.github.io'
Add-App 'Fleex255.PolicyPlus' 'Policy Plus' 'بوليسي بلس' 'Utilities' ''
Add-App 'BitSum.ProcessLasso' 'Process Lasso' 'بروسس لاسو' 'Utilities' 'bitsum.com'
Add-App 'Proton.ProtonAuthenticator' 'Proton Authenticator' 'مصادق بروتون' 'Utilities' 'proton.me'
Add-App 'Proton.ProtonDrive' 'Proton Drive' 'بروتون درايف' 'Utilities' 'proton.me'
Add-App 'Proton.ProtonPass' 'Proton Pass' 'بروتون باس' 'Utilities' 'proton.me'
Add-App 'RevoUninstaller.RevoUninstaller' 'Revo Uninstaller' 'ريفو أنإنستالر' 'Utilities' 'revouninstaller.com'
Add-App 'WhirlwindFX.SignalRgb' 'SignalRGB' 'سيجنال آر جي بي' 'Utilities' 'signalrgb.com'
Add-App 'GlennDelahoy.SnappyDriverInstallerOrigin' 'Snappy Driver Installer Origin' 'منزّل التعريفات Snappy' 'Utilities' 'glenn.delahoy.com'
Add-App 'StartIsBack.StartAllBack' 'StartAllBack' 'ستارت أول باك' 'Utilities' 'startallback.com'
Add-App 'Tailscale.Tailscale' 'Tailscale' 'تيل سكيل' 'Utilities' 'tailscale.com'
Add-App 'GlavSoft.TightVNC' 'TightVNC' 'تايت في إن سي' 'Utilities' 'tightvnc.com'
Add-App 'Ghisler.TotalCommander' 'Total Commander' 'توتال كوماندر' 'Utilities' 'ghisler.com'
Add-App 'CharlesMilette.TranslucentTB' 'TranslucentTB' 'شريط مهام شفاف' 'Utilities' 'translucenttb.github.io'
Add-App 'JAMSoftware.TreeSize.Free' 'TreeSize Free' 'تري سايز' 'Utilities' 'jam-software.com'
Add-App 'Devolutions.UniGetUI' 'UniGetUI' 'يوني جيت يو آي' 'Utilities' 'devolutions.net'
Add-App 'WiseCleaner.WiseProgramUninstaller' 'Wise Program Uninstaller' 'وايز لإزالة البرامج' 'Utilities' 'wisecleaner.com'
Add-App 'AntibodySoftware.WizTree' 'WizTree' 'ويز تري' 'Utilities' 'wiztreefree.com'

# More apps - Productivity
Add-App 'Cyanfish.NAPS2' 'NAPS2' 'ماسح الوثائق NAPS2' 'Productivity' 'naps2.com'
Add-App 'KDE.Okular' 'Okular' 'أوكولار' 'Productivity' 'okular.kde.org'
Add-App 'TrackerSoftware.PDF-XChangeEditor' 'PDF-XChange Editor' 'محرر PDF-XChange' 'Productivity' 'pdf-xchange.com'
Add-App 'geeksoftwareGmbH.PDF24Creator' 'PDF24 Creator' 'PDF24' 'Productivity' 'tools.pdf24.org'
Add-App 'PDFgear.PDFgear' 'PDFgear' 'بي دي إف جير' 'Productivity' 'pdfgear.com'
Add-App 'PDFsam.PDFsam' 'PDFsam Basic' 'PDFsam' 'Productivity' 'pdfsam.org'
Add-App 'pbek.QOwnNotes' 'QOwnNotes' 'كيو أون نوتس' 'Productivity' 'qownnotes.org'
Add-App 'Automattic.Simplenote' 'Simplenote' 'سيمبل نوت' 'Productivity' 'simplenote.com'
Add-App 'Xournal++.Xournal++' 'Xournal++' 'زورنال++' 'Productivity' 'xournalpp.github.io'
Add-App 'DigitalScholar.Zotero' 'Zotero' 'زوتيرو' 'Productivity' 'zotero.org'

# More apps - Pro Tools
Add-App 'Famatech.AdvancedIPScanner' 'Advanced IP Scanner' 'ماسح IP المتقدم' 'ProTools' 'advanced-ip-scanner.com'
Add-App 'angryziber.AngryIPScanner' 'Angry IP Scanner' 'أنجري آي بي سكانر' 'ProTools' 'angryip.org'
Add-App 'Maxon.CinebenchR23' 'Cinebench R23' 'سينيبنش R23' 'ProTools' 'maxon.net'
Add-App 'gerardog.gsudo' 'gsudo' 'جي سودو' 'ProTools' ''
Add-App 'CPUID.HWMonitor' 'HWMonitor' 'إتش دبليو مونيتور' 'ProTools' 'cpuid.com'
Add-App 'MullvadVPN.MullvadVPN' 'Mullvad VPN' 'مولفاد VPN' 'ProTools' 'mullvad.net'
Add-App 'OpenVPNTechnologies.OpenVPNConnect' 'OpenVPN Connect' 'أوبن في بي إن' 'ProTools' 'openvpn.net'
Add-App 'Proton.ProtonVPN' 'Proton VPN' 'بروتون VPN' 'ProTools' 'protonvpn.com'
Add-App 'Henry++.simplewall' 'Simplewall' 'سيمبل وول' 'ProTools' ''

# More apps - Microsoft Tools
Add-App 'Microsoft.DotNet.DesktopRuntime.10' '.NET Desktop Runtime 10' 'بيئة .NET 10' 'Microsoft' 'dotnet.microsoft.com'
Add-App 'Microsoft.DotNet.DesktopRuntime.6' '.NET Desktop Runtime 6' 'بيئة .NET 6' 'Microsoft' 'dotnet.microsoft.com'
Add-App 'Microsoft.DotNet.DesktopRuntime.9' '.NET Desktop Runtime 9' 'بيئة .NET 9' 'Microsoft' 'dotnet.microsoft.com'
Add-App 'Microsoft.Sysinternals.Autoruns' 'Autoruns' 'أوتورانز' 'Microsoft' 'learn.microsoft.com'
Add-App 'CodingWondersSoftware.DISMTools.Stable' 'DISMTools' 'أدوات DISM' 'Microsoft' ''
Add-App 'Nlitesoft.NTLite' 'NTLite' 'إن تي لايت' 'Microsoft' 'ntlite.com'
Add-App 'Microsoft.NuGet' 'NuGet' 'نوجيت' 'Microsoft' 'nuget.org'
Add-App 'Microsoft.Sysinternals.ProcessExplorer' 'Process Explorer' 'مستكشف العمليات' 'Microsoft' 'learn.microsoft.com'
Add-App 'Microsoft.Sysinternals.ProcessMonitor' 'Process Monitor' 'مراقب العمليات' 'Microsoft' 'docs.microsoft.com'
Add-App 'Microsoft.Sysinternals.RDCMan' 'RDCMan' 'مدير سطح المكتب البعيد' 'Microsoft' 'learn.microsoft.com'
Add-App 'Microsoft.Sysinternals.TCPView' 'TCPView' 'TCPView' 'Microsoft' 'docs.microsoft.com'

# More apps - Self-hosted Tools
Add-App 'Jellyfin.JellyfinMediaPlayer' 'Jellyfin Media Player' 'مشغّل جيليفين' 'Selfhosted' 'jellyfin.org'
Add-App 'Jellyfin.Server' 'Jellyfin Server' 'خادم جيليفين' 'Selfhosted' 'jellyfin.org'
Add-App 'LocalSend.LocalSend' 'LocalSend' 'لوكال سيند' 'Selfhosted' 'localsend.org'
Add-App 'Netbird.Netbird' 'NetBird' 'نت بيرد' 'Selfhosted' 'netbird.io'
Add-App 'Plex.Plex' 'Plex Desktop' 'بليكس' 'Selfhosted' 'plex.tv'
Add-App 'Plex.PlexMediaServer' 'Plex Media Server' 'خادم بليكس' 'Selfhosted' 'plex.tv'
Add-App 'LizardByte.Sunshine' 'Sunshine/GameStream Server' 'سنشاين (خادم البث)' 'Selfhosted' 'app.lizardbyte.dev'
Add-App 'GermanCoding.SyncTrayzor' 'SyncTrayzor' 'سينك تريزور' 'Selfhosted' ''

# Microsoft Store apps (installed with: winget install <StoreId> --source msstore)
Add-App '9NZBF4GT040C' 'Bing Search' 'بحث Bing' 'Store' 'bing.com' 'msstore'
Add-App '9WZDNCRFHVN5' 'Calculator' 'الآلة الحاسبة' 'Store' '' 'msstore'
Add-App '9WZDNCRFJBBG' 'Camera' 'الكاميرا' 'Store' '' 'msstore'
Add-App '9P1J8S7CCWWT' 'Clipchamp' 'كليب تشامب' 'Store' 'clipchamp.com' 'msstore'
Add-App '9WZDNCRFJ3PR' 'Clock' 'الساعة' 'Store' '' 'msstore'
Add-App '9NHT9RB2F4HD' 'Copilot' 'كوبايلوت' 'Store' 'copilot.microsoft.com' 'msstore'
Add-App '9N8MHTPHNGVV' 'Dev Home' 'مركز المطوّر Dev Home' 'Store' '' 'msstore'
Add-App '9NBLGGH4R32N' 'Feedback Hub' 'مركز الملاحظات' 'Store' '' 'msstore'
Add-App '9PKDZBMV1H3T' 'Get Help' 'الحصول على مساعدة' 'Store' '' 'msstore'
Add-App '9WZDNCRFJ3PT' 'Media Player' 'مشغّل الوسائط' 'Store' '' 'msstore'
Add-App '9WZDNCRD29V9' 'Microsoft 365' 'مايكروسوفت 365' 'Store' 'microsoft365.com' 'msstore'
Add-App '9NTXGKQ8P7N0' 'Mobile Devices' 'الأجهزة المحمولة' 'Store' '' 'msstore'
Add-App '9WZDNCRFJ3P2' 'Movies & TV' 'الأفلام والتلفزيون' 'Store' '' 'msstore'
Add-App '9WZDNCRFHVFW' 'News' 'الأخبار' 'Store' 'bing.com' 'msstore'
Add-App '9MSMLRH6LZF3' 'Notepad' 'المفكرة' 'Store' '' 'msstore'
Add-App '9NRX63209R7B' 'Outlook for Windows' 'Outlook لنظام ويندوز' 'Store' 'outlook.live.com' 'msstore'
Add-App '9PCFS5B6T72H' 'Paint' 'الرسام (Paint)' 'Store' '' 'msstore'
Add-App '9NMPJ99VJBWV' 'Phone Link' 'رابط الهاتف' 'Store' '' 'msstore'
Add-App '9WZDNCRFJBH4' 'Photos' 'الصور' 'Store' '' 'msstore'
Add-App '9NFTCH6J7FHV' 'Power Automate' 'باور أوتوميت' 'Store' 'powerautomate.microsoft.com' 'msstore'
Add-App '9P7BP5VNWKX5' 'Quick Assist' 'المساعدة السريعة' 'Store' '' 'msstore'
Add-App '9MZ95KL8MR0L' 'Snipping Tool' 'أداة القصاصة' 'Store' '' 'msstore'
Add-App '9WZDNCRFHWD2' 'Solitaire Collection' 'مجموعة سوليتير' 'Store' '' 'msstore'
Add-App '9WZDNCRFHWKN' 'Sound Recorder' 'مسجّل الصوت' 'Store' '' 'msstore'
Add-App '9PC1H9VN18CM' 'Start Experiences App' 'تجارب البداية (الأدوات)' 'Store' '' 'msstore'
Add-App '9NBLGGH4QGHW' 'Sticky Notes' 'الملاحظات اللاصقة' 'Store' '' 'msstore'
Add-App 'XP8BT8DW290MPQ' 'Teams (Store)' 'مايكروسوفت تيمز (المتجر)' 'Store' 'teams.microsoft.com' 'msstore'
Add-App '9NBLGGH5R558' 'To Do' 'المهام (To Do)' 'Store' 'todo.microsoft.com' 'msstore'
Add-App '9WZDNCRFJ3Q2' 'Weather' 'الطقس' 'Store' 'bing.com' 'msstore'
Add-App '9MV0B5HZVK9Z' 'Xbox App' 'تطبيق Xbox' 'Store' 'xbox.com' 'msstore'
Add-App '9NZKPSTSNW4P' 'Xbox Game Bar' 'شريط ألعاب Xbox' 'Store' 'xbox.com' 'msstore'
Add-App '9WZDNCRD1HKW' 'Xbox Identity Provider' 'موفّر هوية Xbox' 'Store' 'xbox.com' 'msstore'

# ----------------------------------------------------------------------------
# 4. Settings, paths, language
# ----------------------------------------------------------------------------
$SettingsDir  = Join-Path $env:APPDATA 'PSPackageManager'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$IconCache    = Join-Path $env:LOCALAPPDATA 'PSPackageManager\icons_v2'
try { Remove-Item (Join-Path $env:LOCALAPPDATA 'PSPackageManager\icons') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
foreach ($d in @($SettingsDir, $IconCache)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Save-Settings {
    try { @{ lang = $script:Lang } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
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

# ----------------------------------------------------------------------------
# 5. XAML user interface
# ----------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1200" Height="800" MinWidth="920" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#14161C"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>

    <!-- Rounded button -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2B2F3D"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#3B82F6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,10"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#DC2626"/>
    </Style>

    <!-- Search box -->
    <Style x:Key="SearchBox" TargetType="TextBox">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="#1E212B" BorderBrush="#2A2E3B" BorderThickness="1.5" CornerRadius="10" Padding="14,9">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3B82F6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Category list item -->
    <Style x:Key="PkgCatItem3" TargetType="ListBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" CornerRadius="9" Padding="12,7" Margin="0,1" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1E212B"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#27324D"/></Trigger>
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
            <Border x:Name="card" Width="150" Height="158" Margin="6" CornerRadius="14"
                    Background="#1E212B" BorderBrush="#2A2E3B" BorderThickness="1.5" Padding="8"
                    ToolTip="{Binding Id}">
              <Grid>
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                  <Grid Width="58" Height="58" HorizontalAlignment="Center" Margin="0,6,0,8">
                    <Border CornerRadius="15" Background="{Binding Color}">
                      <Border.Style>
                        <Style TargetType="Border">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding HasIcon}" Value="True"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Border.Style>
                      <TextBlock Text="{Binding Initial}" Foreground="White" FontSize="26" FontWeight="Bold"
                                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <Border CornerRadius="15" Background="#F4F6FA" Padding="7">
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
                  <TextBlock Text="{Binding DisplayName}" Foreground="White" FontSize="13" FontWeight="SemiBold"
                             TextAlignment="Center" TextWrapping="Wrap" MaxHeight="36" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Status}" Foreground="#9AA3B2" FontSize="11" TextAlignment="Center"
                             Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <Border x:Name="tick" Width="22" Height="22" CornerRadius="11" Background="#00000000"
                        BorderBrush="#4B5263" BorderThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Top">
                  <TextBlock x:Name="mark" Text="✓" Foreground="White" FontSize="13" FontWeight="Bold"
                             HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="card" Property="BorderBrush" Value="#4B6FB5"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="card" Property="Background" Value="#1F2B47"/>
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
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#181B23" Padding="22,14" BorderBrush="#22262F" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock x:Name="txtTitle" FontSize="22" FontWeight="Bold" Foreground="White"/>
          <TextBlock x:Name="txtSubtitle" FontSize="12" Foreground="#8B93A3"/>
        </StackPanel>
        <Grid Grid.Column="1" Margin="30,0" VerticalAlignment="Center" MaxWidth="540">
          <TextBox x:Name="txtSearch" Style="{StaticResource SearchBox}"/>
          <TextBlock x:Name="txtPlaceholder" IsHitTestVisible="False" Foreground="#6B7280" FontSize="14"
                     VerticalAlignment="Center" Margin="16,0"/>
        </Grid>
        <Button x:Name="btnLang" Grid.Column="2" Style="{StaticResource Btn}" FontWeight="SemiBold" MinWidth="110"/>
      </Grid>
    </Border>

    <!-- Body -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="240"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#181B23" Padding="10,12" BorderBrush="#22262F" BorderThickness="0,0,1,0">
        <ListBox x:Name="lstCats" Background="Transparent" BorderThickness="0"
                 ItemContainerStyle="{StaticResource PkgCatItem3}" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
          <ListBox.ItemTemplate>
            <DataTemplate>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="34"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="{Binding Glyph}" Foreground="{Binding Color}" FontSize="18" FontFamily="Segoe UI Emoji, Segoe UI Symbol" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="{Binding Name}" Foreground="White" FontSize="14" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <Border Grid.Column="2" CornerRadius="9" Background="#2A2E3B" Padding="8,1" VerticalAlignment="Center">
                  <TextBlock Text="{Binding Count}" Foreground="#C5CBD6" FontSize="11"/>
                </Border>
              </Grid>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>
      </Border>

      <Grid Grid.Column="1" Margin="14,12,8,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
          <Button x:Name="btnSelectVisible" Style="{StaticResource Btn}" Margin="0,0,6,0"/>
          <Button x:Name="btnClear" Style="{StaticResource Btn}"/>
        </StackPanel>
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
        <TextBlock x:Name="txtEmpty" Grid.Row="1" Foreground="#6B7280" FontSize="16"
                   HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
    </Grid>

    <!-- Footer -->
    <Border Grid.Row="2" Background="#181B23" Padding="20,12" BorderBrush="#22262F" BorderThickness="0,1,0,0">
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
          <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,20,0">
            <TextBlock x:Name="txtSelected" Foreground="White" FontSize="14" FontWeight="SemiBold"/>
            <ProgressBar x:Name="pbar" Height="8" Minimum="0" Maximum="100" Value="0" Margin="0,6,0,4"
                         Foreground="#3B82F6" Background="#2A2E3B" BorderThickness="0"/>
            <TextBlock x:Name="txtProgress" Foreground="#9AA3B2" FontSize="12" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnCancel" Style="{StaticResource BtnDanger}" Visibility="Collapsed"/>
            <Button x:Name="btnInstall" Style="{StaticResource BtnPrimary}" FontSize="15"/>
          </StackPanel>
        </Grid>
        <TextBox x:Name="txtLog" Grid.Row="1" Height="110" Margin="0,10,0,0" IsReadOnly="True" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" FlowDirection="LeftToRight"
                 Background="#0E1014" Foreground="#B8C0CC" BorderBrush="#22262F" Padding="8"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'txtTitle', 'txtSubtitle', 'txtSearch', 'txtPlaceholder', 'btnLang', 'lstCats', 'btnSelectVisible',
                'btnClear', 'icApps', 'txtEmpty', 'txtSelected', 'pbar', 'txtProgress', 'btnCancel', 'btnInstall', 'txtLog') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# ----------------------------------------------------------------------------
# 6. Helper functions
# ----------------------------------------------------------------------------
$script:Cat     = 'All'
$script:Busy    = $false
$script:Sync    = $null
$script:CatMap  = @{}

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
    param([PkgAppItem3]$Item, [string]$Key)
    $Item.StatusKey = $Key
    if ($Key) { $Item.Status = $script:T[$Key] } else { $Item.Status = '' }
}

function Test-Match {
    param([PkgAppItem3]$A, [string]$Q)
    if ([string]::IsNullOrWhiteSpace($Q)) { return $true }
    $ic = [StringComparison]::OrdinalIgnoreCase
    return ($A.NameEn.IndexOf($Q, $ic) -ge 0) -or ($A.NameAr.IndexOf($Q, $ic) -ge 0) -or ($A.Id.IndexOf($Q, $ic) -ge 0)
}

function Refresh-Grid {
    $q = $script:txtSearch.Text.Trim()
    $list = @($script:Apps | Where-Object {
            (($script:Cat -eq 'All') -or
             ($script:Cat -eq 'Selected' -and $_.IsSelected) -or
             ($_.Category -eq $script:Cat)) -and (Test-Match $_ $q)
        })
    $script:icApps.ItemsSource = [PkgAppItem3[]]$list
    if ($list.Count -eq 0) { $script:txtEmpty.Visibility = 'Visible' } else { $script:txtEmpty.Visibility = 'Collapsed' }
}

function Update-Selection {
    $n = @($script:Apps | Where-Object { $_.IsSelected }).Count
    $script:txtSelected.Text = ($script:T.selected -f $n)
    $script:CatMap['Selected'].Count = $n
    $script:btnInstall.IsEnabled = ($n -gt 0) -and (-not $script:Busy)
}

function Initialize-Categories {
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[PkgCatItem3]
    foreach ($key in $CategoryOrder) {
        $c = New-Object PkgCatItem3
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

function Apply-Language {
    $script:T = $Strings[$script:Lang]
    $t = $script:T
    if ($script:Lang -eq 'ar') { $window.FlowDirection = 'RightToLeft' } else { $window.FlowDirection = 'LeftToRight' }
    $window.Title             = $t.title
    $script:txtTitle.Text     = [char]::ConvertFromUtf32(0x1F4E6) + ' ' + $t.title
    $script:txtSubtitle.Text  = $t.subtitle
    $script:txtPlaceholder.Text = $t.search
    $script:btnLang.Content   = $t.langBtn
    $script:btnSelectVisible.Content = $t.selectVisible
    $script:btnClear.Content  = $t.clearAll
    $script:btnInstall.Content = $t.install
    $script:btnCancel.Content = $t.cancel
    $script:txtEmpty.Text     = $t.noResults
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

function Get-IconPath { param([string]$Domain) Join-Path $IconCache (($Domain -replace '[^a-zA-Z0-9\.\-]', '_') + '.png') }

function Load-CachedIcons {
    $loaded = 0
    foreach ($a in $script:Apps) {
        if ($a.HasIcon) { $loaded++; continue }
        if (-not $a.Domain) { $loaded++; continue }
        $p = Get-IconPath $a.Domain
        if (Test-Path $p) {
            try { $bmp = Load-Icon $p; $a.IconSize = [math]::Min(44, [math]::Max(26, $bmp.PixelWidth * 1.5)); $a.Icon = $bmp; $loaded++ }
            catch { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
    }
    return $loaded
}

# ----------------------------------------------------------------------------
# 7. Logo downloader (background runspace + UI timer that picks up finished files)
# ----------------------------------------------------------------------------
$script:IconTicks = 0
function Start-IconDownloads {
    $missing = @($script:Apps | Where-Object { (-not $_.HasIcon) -and $_.Domain } | ForEach-Object { $_.Domain } | Sort-Object -Unique)
    if ($missing.Count -eq 0) { return }

    $dlScript = {
        param($domains, $dir)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        Add-Type -AssemblyName System.Drawing
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')

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

        foreach ($d in $domains) {
            $name = ($d -replace '[^a-zA-Z0-9\.\-]', '_') + '.png'
            $file = Join-Path $dir $name
            if (Test-Path $file) { continue }

            # Highest quality sources first; we stop as soon as we get a sharp (>=128px) image.
            $urls = @(
                "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://$d&size=256",
                "https://$d/apple-touch-icon.png",
                "https://www.$d/apple-touch-icon.png",
                "https://www.google.com/s2/favicons?domain=$d&sz=256",
                "https://icons.duckduckgo.com/ip3/$d.ico"
            )
            $bestW = 0
            $i = 0
            foreach ($u in $urls) {
                $i++
                $tmp = "$file.$i.tmp"
                try {
                    $wc.DownloadFile($u, $tmp)
                    $w = 0
                    if ((Get-Item $tmp).Length -gt 150) { $w = Get-ImgWidth $tmp }
                    if ($w -gt $bestW) { Copy-Item $tmp "$file.best" -Force; $bestW = $w }
                }
                catch { }
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                if ($bestW -ge 128) { break }
            }
            # Images under 32px are almost always blurry/generic globes: keep the letter tile instead.
            if ($bestW -ge 32) { Move-Item "$file.best" $file -Force }
            Remove-Item "$file.best" -Force -ErrorAction SilentlyContinue
        }
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($dlScript).AddArgument($missing).AddArgument($IconCache)
    $script:IconHandle = $ps.BeginInvoke()
    $script:IconPs = $ps
    $script:IconRs = $rs

    $script:IconTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:IconTimer.Interval = [TimeSpan]::FromMilliseconds(900)
    $script:IconTimer.Add_Tick({
            $script:IconTicks++
            $loaded = Load-CachedIcons
            $finished = $script:IconHandle.IsCompleted
            if ($finished -or $loaded -ge $script:Apps.Count -or $script:IconTicks -gt 240) {
                $script:IconTimer.Stop()
                if ($finished) {
                    Load-CachedIcons | Out-Null
                    try { $script:IconPs.EndInvoke($script:IconHandle) } catch { }
                    $script:IconPs.Dispose(); $script:IconRs.Dispose()
                }
            }
        })
    $script:IconTimer.Start()
}

# ----------------------------------------------------------------------------
# 8. Installation engine (runs winget in a background runspace, UI polls a queue)
# ----------------------------------------------------------------------------
$worker = {
    param($sync, $apps)
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        foreach ($app in $apps) {
            if ($sync.Cancel) { $sync.Queue.Enqueue("skip|$($app.Id)|"); continue }
            if ($app.Source -eq 'web') {
                try { Start-Process $app.Id; $sync.Queue.Enqueue("manual|$($app.Id)|") }
                catch { $sync.Queue.Enqueue("log|$($app.Id)|$($_.Exception.Message)"); $sync.Queue.Enqueue("done|$($app.Id)|-1") }
                continue
            }
            $sync.Queue.Enqueue("start|$($app.Id)|")
            $code = -1
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
    try { $script:WorkerPs.EndInvoke($script:WorkerHandle) } catch { }
    try { $script:WorkerPs.Dispose(); $script:WorkerRs.Dispose() } catch { }
    Update-Selection
    $icon = 'Information'; if ($r.fail -gt 0) { $icon = 'Warning' }
    [void](Show-Msg $summary $script:T.title 'OK' $icon)
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
            }
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
    [void]$ps.AddScript($worker).AddArgument($script:Sync).AddArgument($list)
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

$btnLang.Add_Click({
        if ($script:Lang -eq 'en') { $script:Lang = 'ar' } else { $script:Lang = 'en' }
        Apply-Language
        Refresh-Grid
    })

$lstCats.Add_SelectionChanged({
        $sel = $script:lstCats.SelectedItem
        if ($sel) { $script:Cat = $sel.Key; Refresh-Grid }
    })

$txtSearch.Add_TextChanged({
        if ($script:txtSearch.Text.Length -gt 0) { $script:txtPlaceholder.Visibility = 'Collapsed' } else { $script:txtPlaceholder.Visibility = 'Visible' }
        Refresh-Grid
    })

$icApps.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [System.Windows.RoutedEventHandler]{ Update-Selection })

$btnSelectVisible.Add_Click({
        foreach ($i in $script:icApps.ItemsSource) { $i.IsSelected = $true }
        Update-Selection
    })

$btnClear.Add_Click({
        foreach ($a in $script:Apps) { $a.IsSelected = $false }
        Update-Selection
        if ($script:Cat -eq 'Selected') { Refresh-Grid }
    })

$btnInstall.Add_Click({ Start-Install })

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
    Apply-Language
    $lstCats.SelectedIndex = 0
    [void](Load-CachedIcons)
    Start-IconDownloads

    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if ($wg) { Write-Log ($script:T.wingetOk -f $wg.Source) } else { Write-Log $script:T.noWinget }
    if (-not $isAdmin) { Write-Log $script:T.adminWarn }

    [void]$window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Fatal error:`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)", 'PS Package Manager', 'OK', 'Error')
}