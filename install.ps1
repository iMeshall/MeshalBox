# MeshalBox launcher
# Run this in PowerShell (it downloads the latest MeshalBox, then opens it as Administrator):
#
#   irm https://raw.githubusercontent.com/iMeshall/MeshalBox/main/install.ps1 | iex
#
# What it does: downloads the repository ZIP from GitHub into %LOCALAPPDATA%\MeshalBox\app,
# then starts MeshalBox.ps1 with Administrator rights. Nothing else is installed.

function Start-MeshalBoxLauncher {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $repo   = 'iMeshall/MeshalBox'
    $branch = 'main'

    if ($env:OS -ne 'Windows_NT') {
        Write-Host 'MeshalBox only runs on Windows 10 / 11.' -ForegroundColor Red
        return
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $appDir = Join-Path $env:LOCALAPPDATA 'MeshalBox\app'
    $script = Join-Path $appDir 'MeshalBox.ps1'
    $work   = Join-Path $env:TEMP ('MeshalBox_' + [guid]::NewGuid().ToString('N'))

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
        $null = Get-Content -LiteralPath $srcCatalog -Raw -Encoding UTF8 | ConvertFrom-Json

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
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    # start it with Windows PowerShell 5.1 (STA, no console window), as Administrator
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -NoUpdateCheck' -f $script
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    try {
        if ($isAdmin) { Start-Process -FilePath $psExe -ArgumentList $argLine }
        else          { Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs }
        Write-Host 'MeshalBox is starting...' -ForegroundColor Green
    }
    catch {
        Write-Host 'Administrator permission was not granted, so MeshalBox did not start.' -ForegroundColor Yellow
    }
}

Start-MeshalBoxLauncher
