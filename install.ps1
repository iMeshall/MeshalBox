# MeshalBox launcher
# Run this in PowerShell (it downloads the latest MeshalBox, then opens it as Administrator):
#
#   irm https://raw.githubusercontent.com/iMeshall/MeshalBox/main/install.ps1 | iex
#
# What it does: downloads the repository ZIP from GitHub into %LOCALAPPDATA%\MeshalBox\app,
# then starts MeshalBox.ps1 with Administrator rights. Nothing else is installed.

function Invoke-MeshalBoxLauncher {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $repo   = 'iMeshall/MeshalBox'
    $branch = 'main'

    if ($env:OS -ne 'Windows_NT') {
        Write-Host 'MeshalBox only runs on Windows 10 / 11.' -ForegroundColor Red
        return
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # Use the full (long) path of the profile folder: %TEMP% can be an 8.3 short path like C:\Users\5207~1
    # when the user name has Arabic / special characters, and that breaks Remove-Item and Expand-Archive.
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $local) { $local = $env:LOCALAPPDATA }
    $appDir = Join-Path $local 'MeshalBox\app'
    $script = Join-Path $appDir 'MeshalBox.ps1'
    $work   = Join-Path $local ('MeshalBox\tmp_' + [guid]::NewGuid().ToString('N'))

    Write-Host 'MeshalBox: getting the latest version...' -ForegroundColor Cyan
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $work 'src.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

        $src = Get-ChildItem -LiteralPath $work -Directory | Select-Object -First 1
        $srcScript = Join-Path $src.FullName 'MeshalBox.ps1'
        $srcCatalog = Join-Path $src.FullName 'applications.json'
        if (-not (Test-Path -LiteralPath $srcScript) -or -not (Test-Path -LiteralPath $srcCatalog)) {
            throw 'The download is missing MeshalBox.ps1 or applications.json.'
        }
        # make sure the catalog is valid before replacing the working copy
        $catText = Get-Content -LiteralPath $srcCatalog -Raw -Encoding UTF8
        try { $null = $catText | ConvertFrom-Json }
        catch {
            $head = $catText.Substring(0, [Math]::Min(60, $catText.Length)) -replace '\s+', ' '
            throw ('applications.json on GitHub is not valid JSON. It starts with: "' + $head + '"')
        }

        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        # Windows PowerShell 5.1 needs UTF-8 WITH BOM to read the Arabic text correctly
        $text = [IO.File]::ReadAllText($srcScript, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($script, $text, (New-Object Text.UTF8Encoding($true)))
        Copy-Item -LiteralPath $srcCatalog -Destination (Join-Path $appDir 'applications.json') -Force

        $logosOld = Join-Path $appDir 'logos'
        $logosNew = Join-Path $src.FullName 'logos'
        if (Test-Path -LiteralPath $logosOld) { Remove-Item -LiteralPath $logosOld -Recurse -Force }
        if (Test-Path -LiteralPath $logosNew) { Copy-Item -LiteralPath $logosNew -Destination $logosOld -Recurse -Force }
        Get-ChildItem -LiteralPath $appDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    }
    catch {
        if ((Test-Path -LiteralPath $script) -and (Test-Path -LiteralPath (Join-Path $appDir 'applications.json'))) {
            Write-Host ('Could not download the latest version (' + $_.Exception.Message + '). Using the last downloaded copy.') -ForegroundColor Yellow
        }
        else {
            Write-Host ('Could not download MeshalBox: ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host 'Check your internet connection and try again.' -ForegroundColor Red
            return
        }
    }
    finally {
        try { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }

    # start it with Windows PowerShell 5.1 (STA, no console window), as Administrator
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -NoUpdateCheck' -f $script
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $proc = $null
    try {
        if ($isAdmin) { $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -PassThru }
        else          { $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs -PassThru }
    }
    catch {
        Write-Host 'Administrator permission was not granted, so MeshalBox did not start.' -ForegroundColor Yellow
        return
    }
    Write-Host 'MeshalBox is running - close its window to finish.' -ForegroundColor Green

    # keep this console open until MeshalBox is closed, then say goodbye
    try { if ($proc) { $proc.WaitForExit() } } catch { return }
    Write-Host ''
    Write-Host '  MeshalBox closed. Thanks for using MeshalBox - see you next time!' -ForegroundColor Cyan
    Write-Host ''
}

function Start-MeshalBoxLauncher {
    # the banner uses block characters: switch the console to UTF-8 while we run, then restore it
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
        $banner = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('4paI4paI4paI4pWXICAg4paI4paI4paI4pWX4paI4paI4paI4paI4paI4paI4paI4pWX4paI4paI4paI4paI4paI4paI4paI4pWX4paI4paI4pWXICDilojilojilZcg4paI4paI4paI4paI4paI4pWXIOKWiOKWiOKVlyAgICAg4paI4paI4paI4paI4paI4paI4pWXICDilojilojilojilojilojilojilZcg4paI4paI4pWXICDilojilojilZcK4paI4paI4paI4paI4pWXIOKWiOKWiOKWiOKWiOKVkeKWiOKWiOKVlOKVkOKVkOKVkOKVkOKVneKWiOKWiOKVlOKVkOKVkOKVkOKVkOKVneKWiOKWiOKVkSAg4paI4paI4pWR4paI4paI4pWU4pWQ4pWQ4paI4paI4pWX4paI4paI4pWRICAgICDilojilojilZTilZDilZDilojilojilZfilojilojilZTilZDilZDilZDilojilojilZfilZrilojilojilZfilojilojilZTilZ0K4paI4paI4pWU4paI4paI4paI4paI4pWU4paI4paI4pWR4paI4paI4paI4paI4paI4pWXICDilojilojilojilojilojilojilojilZfilojilojilojilojilojilojilojilZHilojilojilojilojilojilojilojilZHilojilojilZEgICAgIOKWiOKWiOKWiOKWiOKWiOKWiOKVlOKVneKWiOKWiOKVkSAgIOKWiOKWiOKVkSDilZrilojilojilojilZTilZ0gCuKWiOKWiOKVkeKVmuKWiOKWiOKVlOKVneKWiOKWiOKVkeKWiOKWiOKVlOKVkOKVkOKVnSAg4pWa4pWQ4pWQ4pWQ4pWQ4paI4paI4pWR4paI4paI4pWU4pWQ4pWQ4paI4paI4pWR4paI4paI4pWU4pWQ4pWQ4paI4paI4pWR4paI4paI4pWRICAgICDilojilojilZTilZDilZDilojilojilZfilojilojilZEgICDilojilojilZEg4paI4paI4pWU4paI4paI4pWXIArilojilojilZEg4pWa4pWQ4pWdIOKWiOKWiOKVkeKWiOKWiOKWiOKWiOKWiOKWiOKWiOKVl+KWiOKWiOKWiOKWiOKWiOKWiOKWiOKVkeKWiOKWiOKVkSAg4paI4paI4pWR4paI4paI4pWRICDilojilojilZHilojilojilojilojilojilojilojilZfilojilojilojilojilojilojilZTilZ3ilZrilojilojilojilojilojilojilZTilZ3ilojilojilZTilZ0g4paI4paI4pWXCuKVmuKVkOKVnSAgICAg4pWa4pWQ4pWd4pWa4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWd4pWa4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWd4pWa4pWQ4pWdICDilZrilZDilZ3ilZrilZDilZ0gIOKVmuKVkOKVneKVmuKVkOKVkOKVkOKVkOKVkOKVkOKVneKVmuKVkOKVkOKVkOKVkOKVkOKVnSAg4pWa4pWQ4pWQ4pWQ4pWQ4pWQ4pWdIOKVmuKVkOKVnSAg4pWa4pWQ4pWd'))
        Write-Host ''
        Write-Host $banner -ForegroundColor Cyan
        Write-Host ''
    } catch { }
    try { Invoke-MeshalBoxLauncher }
    finally { try { if ($prevEnc) { [Console]::OutputEncoding = $prevEnc } } catch { } }
}

Start-MeshalBoxLauncher
