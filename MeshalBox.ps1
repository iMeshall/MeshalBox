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
        title         = 'MeshalBox'
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
        cat_Peripherals = 'Peripheral Software'
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
        title         = 'MeshalBox'
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
        cat_Peripherals = 'برامج الملحقات'
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

foreach ($e in $catalog.apps) {
    if (-not $e.id -or -not $e.en) { continue }
    if ($script:ById.ContainsKey([string]$e.id)) { continue }   # never list the same program twice
    $a = New-Object MeshalApp
    $a.Id = [string]$e.id; $a.NameEn = [string]$e.en
    $a.NameAr = if ($e.ar) { [string]$e.ar } else { [string]$e.en }
    $a.Category = [string]$e.category; $a.Domain = [string]$e.domain
    $a.Source = if ($e.source) { [string]$e.source } else { '' }
    $a.Initial = $a.NameEn.Substring(0, 1).ToUpper()
    $sum = 0; foreach ($ch in $a.Id.ToCharArray()) { $sum += [int]$ch }
    $a.Color = $palette[$sum % $palette.Count]
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
    <Style x:Key="MeshalCat" TargetType="ListBoxItem">
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
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Image x:Name="imgLogo" Width="46" Height="46" Margin="0,0,12,0" RenderOptions.BitmapScalingMode="HighQuality"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="txtTitle" FontSize="22" FontWeight="Bold" Foreground="White"/>
            <TextBlock x:Name="txtSubtitle" FontSize="12" Foreground="#8B93A3"/>
          </StackPanel>
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
foreach ($n in 'imgLogo', 'txtTitle', 'txtSubtitle', 'txtSearch', 'txtPlaceholder', 'btnLang', 'lstCats', 'btnSelectVisible',
                'btnClear', 'icApps', 'txtEmpty', 'txtSelected', 'pbar', 'txtProgress', 'btnCancel', 'btnInstall', 'txtLog') {
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

function Refresh-Grid {
    $q = $script:txtSearch.Text.Trim()
    $list = @($script:Apps | Where-Object {
            (($script:Cat -eq 'All') -or
             ($script:Cat -eq 'Selected' -and $_.IsSelected) -or
             ($_.Category -eq $script:Cat)) -and (Test-Match $_ $q)
        })
    $script:icApps.ItemsSource = [MeshalApp[]]$list
    if ($list.Count -eq 0) { $script:txtEmpty.Visibility = 'Visible' } else { $script:txtEmpty.Visibility = 'Collapsed' }
}

function Update-Selection {
    $n = @($script:Apps | Where-Object { $_.IsSelected }).Count
    $script:txtSelected.Text = ($script:T.selected -f $n)
    $script:CatMap['Selected'].Count = $n
    $script:btnInstall.IsEnabled = ($n -gt 0) -and (-not $script:Busy)
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

function Apply-Language {
    $script:T = $Strings[$script:Lang]
    $t = $script:T
    if ($script:Lang -eq 'ar') { $window.FlowDirection = 'RightToLeft' } else { $window.FlowDirection = 'LeftToRight' }
    $window.Title             = $t.title
    $script:txtTitle.Text     = $t.title
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
    $files = @{}
    try { foreach ($f in [System.IO.Directory]::GetFiles($IconCache, '*.png')) { $files[[System.IO.Path]::GetFileName($f)] = $f } } catch { }
    foreach ($a in $script:Apps) {
        if ($a.HasIcon) { $loaded++; continue }
        if (-not $a.Domain) { $loaded++; continue }
        $p = $files[[System.IO.Path]::GetFileName((Get-IconPath $a.Domain))]
        if ($p) {
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
$script:IconKnown = @{}      # domains already loaded or confirmed missing (skip re-checking every tick)
function Start-IconDownloads {
    # Skip domains that failed recently (negative cache, 7 days) so they are not retried on every launch.
    $missing = @($script:Apps | Where-Object { (-not $_.HasIcon) -and $_.Domain } | ForEach-Object { $_.Domain } | Sort-Object -Unique | Where-Object {
            $miss = (Get-IconPath $_) + '.miss'
            -not ((Test-Path $miss) -and ((Get-Item $miss).LastWriteTime -gt (Get-Date).AddDays(-7)))
        })
    if ($missing.Count -eq 0) { return }

    # One small job per domain, executed by a pool of parallel workers.
    $dlScript = {
        param($d, $dir)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        try { [Net.ServicePointManager]::DefaultConnectionLimit = 64 } catch { }
        Add-Type -AssemblyName System.Drawing

        # MeshalWebClient (6 s timeout) is defined once in section 1 and shared by all workers.
        $wc = New-Object MeshalWebClient
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

        $name = ($d -replace '[^a-zA-Z0-9\.\-]', '_') + '.png'
        $file = Join-Path $dir $name
        if (Test-Path $file) { return }

        # Fast, reliable source first; only try the slower fallbacks when the result is not sharp.
        $urls = @(
            "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://$d&size=256",
            "https://www.google.com/s2/favicons?domain=$d&sz=256",
            "https://$d/apple-touch-icon.png",
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
        else { Set-Content -Path "$file.miss" -Value '' -ErrorAction SilentlyContinue }
        Remove-Item "$file.best" -Force -ErrorAction SilentlyContinue
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, 12)
    $pool.ApartmentState = 'MTA'
    $pool.Open()
    $script:IconPool = $pool
    $script:IconJobs = New-Object System.Collections.Generic.List[object]
    foreach ($d in $missing) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($dlScript).AddArgument($d).AddArgument($IconCache)
        $script:IconJobs.Add(@{ Ps = $ps; Handle = $ps.BeginInvoke() })
    }

    $script:IconTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:IconTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $script:IconTimer.Add_Tick({
            $script:IconTicks++
            [void](Load-CachedIcons)
            $pending = @($script:IconJobs | Where-Object { -not $_.Handle.IsCompleted }).Count
            if ($pending -eq 0 -or $script:IconTicks -gt 400) {
                $script:IconTimer.Stop()
                [void](Load-CachedIcons)
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
    param($sync, $apps)
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
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
    [void][System.Windows.MessageBox]::Show("Fatal error:`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)", 'MeshalBox', 'OK', 'Error')
}
