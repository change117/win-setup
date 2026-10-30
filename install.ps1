<#
.SYNOPSIS
    win-setup: one-liner bootstrap that reinstalls everything on a fresh Windows PC.

.DESCRIPTION
    Run from any PowerShell window on a freshly installed Windows desktop:

        irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1 | iex

    What it does, in order:
      1. Relaunches itself as Administrator if needed.
      2. Installs Chocolatey (if missing) and makes sure winget works.
      3. Detects your GPU/CPU and installs the matching driver software
         (NVIDIA App, AMD Ryzen Chipset drivers, AMD Adrenalin).
      4. Installs every package listed in choco-packages.txt and winget-packages.txt.
      5. Runs Chris Titus WinUtil headless with winutil.json so all your WinUtil apps install.
      6. Prints a summary and the path to the log file on your Desktop.

    To pass switches, use this form instead of the plain one-liner:

        & ([ScriptBlock]::Create((irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1))) -SkipWinUtil

.PARAMETER SkipWinUtil
    Do not run WinUtil at the end.
.PARAMETER SkipChoco
    Do not install the Chocolatey package list (Chocolatey itself is still installed).
.PARAMETER SkipWinget
    Do not install the winget package list.
.PARAMETER SkipDrivers
    Do not install NVIDIA / AMD driver software.
.PARAMETER OpenWinUtilGui
    Launch the normal WinUtil GUI instead of running it headless with winutil.json.
#>
[CmdletBinding()]
param(
    [switch]$SkipWinUtil,
    [switch]$SkipChoco,
    [switch]$SkipWinget,
    [switch]$SkipDrivers,
    [switch]$OpenWinUtilGui
)

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
$RepoRaw      = 'https://raw.githubusercontent.com/change117/win-setup/main'
$ScriptUrl    = "$RepoRaw/install.ps1"
$WinUtilConf  = "$RepoRaw/winutil.json"
$ChocoListUrl = "$RepoRaw/choco-packages.txt"
$WingetListUrl = "$RepoRaw/winget-packages.txt"
$WinUtilUrl   = 'https://christitus.com/win'

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Name, [string]$Status, [string]$Note = '') {
    $script:Results.Add([pscustomobject]@{ Item = $Name; Status = $Status; Note = $Note })
    $color = switch ($Status) { 'OK' { 'Green' } 'SKIP' { 'DarkGray' } 'MANUAL' { 'Yellow' } default { 'Red' } }
    Write-Host ("    [{0}] {1} {2}" -f $Status, $Name, $Note) -ForegroundColor $color
}

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user;$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

function ConvertTo-PackageList([string]$Raw) {
    # One package ID per line, '#' starts a comment, blank lines ignored.
    $ids = foreach ($line in ($Raw -split "`r?`n")) {
        $clean = ($line -split '#', 2)[0].Trim()
        if ($clean) { $clean }
    }
    return @($ids)
}

function Get-RemoteList([string]$Url) {
    try {
        $raw = Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warning "Could not download $Url : $($_.Exception.Message)"
        return @()
    }
    return ConvertTo-PackageList ([string]$raw)
}

# ----------------------------------------------------------------------------
# Package manager bootstrap
# ----------------------------------------------------------------------------
function Test-Choco  { [bool](Get-Command choco  -ErrorAction SilentlyContinue) }
function Test-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }

function Install-Chocolatey {
    if (Test-Choco) { Add-Result 'Chocolatey' 'OK' 'already installed'; return $true }
    Write-Host '    Installing Chocolatey...'
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) | Out-Host
    } catch {
        Add-Result 'Chocolatey' 'FAIL' $_.Exception.Message
        return $false
    }
    Update-PathFromRegistry
    if (-not $env:ChocolateyInstall) { $env:ChocolateyInstall = "$env:ProgramData\chocolatey" }
    $env:Path = "$env:ChocolateyInstall\bin;$env:Path"
    if (Test-Choco) {
        & choco feature enable -n allowGlobalConfirmation --limit-output | Out-Null
        Add-Result 'Chocolatey' 'OK' 'installed'
        return $true
    }
    Add-Result 'Chocolatey' 'FAIL' 'choco.exe not found after install'
    return $false
}

function Install-Winget {
    Update-PathFromRegistry
    if (Test-Winget) { Add-Result 'winget' 'OK' 'already installed'; return $true }
    Write-Host '    winget not found. Trying Repair-WinGetPackageManager (Microsoft.WinGet.Client)...'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Latest -Force -ErrorAction Stop | Out-Host
    } catch {
        Write-Warning "Repair-WinGetPackageManager failed: $($_.Exception.Message)"
    }
    Update-PathFromRegistry
    if (Test-Winget) { Add-Result 'winget' 'OK' 'installed/repaired'; return $true }
    Add-Result 'winget' 'FAIL' 'not available; winget packages will be skipped (WinUtil will try to install it too)'
    return $false
}

# ----------------------------------------------------------------------------
# Install primitives
# ----------------------------------------------------------------------------
function Install-WingetId([string]$Id) {
    if (-not (Test-Winget)) { return $false }
    Write-Host "    winget install $Id"
    & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
    $code = $LASTEXITCODE
    # 0 = ok, -1978334623 = already installed, -1978335189 = no applicable upgrade
    return ($code -in 0, -1978334623, -1978335189)
}

function Install-ChocoId([string]$Id) {
    if (-not (Test-Choco)) { return $false }
    Write-Host "    choco install $Id"
    & choco install $Id -y --no-progress | Out-Host
    $code = $LASTEXITCODE
    # 0 = ok, 1641 = reboot initiated, 3010 = reboot required
    return ($code -in 0, 1641, 3010)
}

function Install-WithFallback {
    param(
        [string]$Name,
        [string[]]$WingetIds = @(),
        [string[]]$ChocoIds = @(),
        [string]$FallbackUrl
    )
    foreach ($id in $WingetIds) {
        if (Install-WingetId $id) { Add-Result $Name 'OK' "via winget $id"; return }
    }
    foreach ($id in $ChocoIds) {
        if (Install-ChocoId $id) { Add-Result $Name 'OK' "via choco $id"; return }
    }
    Write-Warning "$Name could not be installed from winget or Chocolatey. Opening the download page."
    if ($FallbackUrl) { Start-Process $FallbackUrl }
    Add-Result $Name 'MANUAL' "download from $FallbackUrl"
}

# ----------------------------------------------------------------------------
# Hardware detection + drivers
# ----------------------------------------------------------------------------
function Get-HardwareInfo {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $gpuIds   = @($gpus | ForEach-Object { $_.PNPDeviceID })
    $gpuNames = @($gpus | ForEach-Object { $_.Name })
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpuText = "$($cpu.Manufacturer) $($cpu.Name)"

    # PCI vendor IDs work even when Windows only shows "Microsoft Basic Display Adapter".
    [pscustomobject]@{
        GpuNames     = $gpuNames
        CpuName      = $cpuText.Trim()
        HasNvidiaGpu = [bool](($gpuIds -match 'VEN_10DE') -or ($gpuNames -match 'NVIDIA|GeForce'))
        HasAmdGpu    = [bool](($gpuIds -match 'VEN_1002') -or ($gpuNames -match 'AMD|Radeon'))
        HasAmdCpu    = [bool]($cpuText -match 'AMD|Ryzen')
        HasIntelCpu  = [bool]($cpuText -match 'Intel')
    }
}

function Install-Drivers {
    $hw = Get-HardwareInfo
    Write-Host "    CPU : $($hw.CpuName)"
    Write-Host "    GPU : $($hw.GpuNames -join ', ')"

    if ($hw.HasNvidiaGpu) {
        Install-WithFallback -Name 'NVIDIA App' `
            -WingetIds @('Nvidia.NvidiaApp', 'Nvidia.NVIDIAApp') `
            -ChocoIds  @('nvidia-app') `
            -FallbackUrl 'https://www.nvidia.com/en-us/software/nvidia-app/'
    } else {
        Add-Result 'NVIDIA App' 'SKIP' 'no NVIDIA GPU detected'
    }

    if ($hw.HasAmdCpu) {
        Install-WithFallback -Name 'AMD Ryzen Chipset Drivers' `
            -ChocoIds  @('amd-ryzen-chipset') `
            -FallbackUrl 'https://www.amd.com/en/support/download/drivers.html'
    } else {
        Add-Result 'AMD Ryzen Chipset Drivers' 'SKIP' 'no AMD CPU detected'
    }

    if ($hw.HasAmdGpu) {
        Install-WithFallback -Name 'AMD Adrenalin' `
            -WingetIds @('AMD.AMDSoftwareAdrenalinEdition') `
            -ChocoIds  @('amd-radeon-software', 'amd-adrenalin') `
            -FallbackUrl 'https://www.amd.com/en/support/download/drivers.html'
    } else {
        Add-Result 'AMD Adrenalin' 'SKIP' 'no AMD GPU detected (Adrenalin needs a Radeon GPU)'
    }
}

# ----------------------------------------------------------------------------
# Package lists
# ----------------------------------------------------------------------------
function Install-ChocoList {
    $ids = Get-RemoteList $ChocoListUrl
    if ($ids.Count -eq 0) { Add-Result 'Chocolatey list' 'SKIP' 'no packages listed'; return }
    if (-not (Test-Choco)) { Add-Result 'Chocolatey list' 'FAIL' 'choco not available'; return }
    Write-Host "    $($ids.Count) package(s): $($ids -join ', ')"
    foreach ($id in $ids) {
        if (Install-ChocoId $id) { Add-Result "choco: $id" 'OK' } else { Add-Result "choco: $id" 'FAIL' "exit code $LASTEXITCODE" }
    }
}

function Install-WingetList {
    $ids = Get-RemoteList $WingetListUrl
    if ($ids.Count -eq 0) { Add-Result 'winget list' 'SKIP' 'no packages listed'; return }
    if (-not (Test-Winget)) { Add-Result 'winget list' 'FAIL' 'winget not available'; return }
    Write-Host "    $($ids.Count) package(s): $($ids -join ', ')"
    foreach ($id in $ids) {
        if (Install-WingetId $id) { Add-Result "winget: $id" 'OK' } else { Add-Result "winget: $id" 'FAIL' "exit code $LASTEXITCODE" }
    }
}

# ----------------------------------------------------------------------------
# WinUtil
# ----------------------------------------------------------------------------
function Invoke-WinUtil {
    # Runs in a child PowerShell so WinUtil's own exit/transcript handling cannot interrupt this script.
    if ($OpenWinUtilGui) {
        Write-Host '    Launching WinUtil GUI (not waiting for it)...'
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "irm $WinUtilUrl | iex"
        Add-Result 'WinUtil' 'MANUAL' 'GUI opened; import winutil.json via the gear icon > Import if you want your list'
        return
    }

    Write-Host "    Running WinUtil headless with $WinUtilConf"
    Write-Host '    This installs all apps in winutil.json. It can take a while.'
    $cmd = "& ([ScriptBlock]::Create((irm '$WinUtilUrl'))) -Config '$WinUtilConf'; exit `$LASTEXITCODE"
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd -NoNewWindow -Wait -PassThru
    switch ($p.ExitCode) {
        0       { Add-Result 'WinUtil' 'OK'   'all selections completed' }
        2       { Add-Result 'WinUtil' 'FAIL' 'config loaded no selections (check winutil.json)' }
        default { Add-Result 'WinUtil' 'WARN' "finished with exit code $($p.ExitCode); see WinUtil log in $env:LOCALAPPDATA\winutil" }
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    Write-Host 'win-setup needs Administrator rights. Relaunching elevated...' -ForegroundColor Yellow
    $switches = @()
    foreach ($key in $PSBoundParameters.Keys) {
        if ($PSBoundParameters[$key] -is [switch] -and $PSBoundParameters[$key].IsPresent) { $switches += "-$key" }
    }
    $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
             "& ([ScriptBlock]::Create((irm '$ScriptUrl'))) $($switches -join ' ')"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $encoded
    } catch {
        Write-Host 'Elevation was cancelled. Nothing was changed.' -ForegroundColor Red
    }
    return
}

Set-ExecutionPolicy Bypass -Scope Process -Force
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = $env:USERPROFILE }
$LogPath = Join-Path $desktop 'win-setup.log'
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { Write-Warning "Could not start transcript: $($_.Exception.Message)" }

$started = Get-Date
Write-Host ''
Write-Host '############################################' -ForegroundColor Magenta
Write-Host '#  win-setup  -  change117/win-setup       #' -ForegroundColor Magenta
Write-Host '############################################' -ForegroundColor Magenta
Write-Host "Started : $started"
Write-Host "Log     : $LogPath"

try {
    Write-Step 'Package managers'
    Install-Chocolatey | Out-Null
    Install-Winget     | Out-Null

    Write-Step 'Driver software (hardware detected)'
    if ($SkipDrivers) { Add-Result 'Drivers' 'SKIP' '-SkipDrivers' } else { Install-Drivers }

    Write-Step 'Chocolatey packages (choco-packages.txt)'
    if ($SkipChoco) { Add-Result 'Chocolatey list' 'SKIP' '-SkipChoco' } else { Install-ChocoList }

    Write-Step 'winget packages (winget-packages.txt)'
    if ($SkipWinget) { Add-Result 'winget list' 'SKIP' '-SkipWinget' } else { Install-WingetList }

    Write-Step 'Chris Titus WinUtil (winutil.json)'
    if ($SkipWinUtil) { Add-Result 'WinUtil' 'SKIP' '-SkipWinUtil' } else { Invoke-WinUtil }
}
finally {
    Write-Step 'Summary'
    $script:Results | Format-Table -AutoSize | Out-String | Write-Host
    $failed = @($script:Results | Where-Object { $_.Status -in 'FAIL', 'WARN', 'MANUAL' })
    $elapsed = (Get-Date) - $started
    Write-Host ("Finished in {0:hh\:mm\:ss}. Log: {1}" -f $elapsed, $LogPath)
    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) item(s) need attention (see table above)." -ForegroundColor Yellow
    } else {
        Write-Host 'Everything completed.' -ForegroundColor Green
    }
    Write-Host 'Reboot recommended so driver installs finish.' -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch { }
}
