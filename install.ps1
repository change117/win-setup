<#
.SYNOPSIS
    win-setup: one-liner bootstrap that reinstalls everything on a fresh Windows PC.

.DESCRIPTION
    Run from any PowerShell window on a freshly installed Windows desktop:

        irm is.gd/win117 | iex

    (is.gd/win117 is a permanent redirect to
     https://raw.githubusercontent.com/change117/win-setup/main/install.ps1)

    On a fresh install it runs as an unattended chain. Paste it once and walk away:

      1. Relaunches itself as Administrator if needed.
      2. Windows Update: installs every pending update AND driver (the base GPU, iGPU,
         chipset, network and board drivers). If a restart is needed it schedules itself
         to continue after you log back in, restarts, and repeats until nothing is left
         (max 3 restarts).
      3. Installs Chocolatey and makes sure winget works.
      4. Detects your GPU/CPU and installs the matching driver software:
         NVIDIA Game Ready driver + NVIDIA App, AMD Ryzen Chipset drivers.
      5. Installs every package listed in choco-packages.txt and winget-packages.txt.
      6. Runs Chris Titus WinUtil headless with winutil.json so all your WinUtil apps install.
      7. Builds your own Chocolatey packages from the packages\ folder (your programs,
         GitHub apps, project setups) into a local feed and installs them.
      8. Prints a summary, writes a log to your Desktop, and restarts one last time.

    Windows Update and the automatic restarts only happen on the first run on a PC
    (or with -Fresh). Later runs just install packages, so re-running to add apps is quick
    and does not reboot.

    To pass switches, use this form instead of the plain one-liner:

        & ([ScriptBlock]::Create((irm is.gd/win117))) -SkipWinUtil

.PARAMETER SkipWindowsUpdate
    Do not run Windows Update (also disables the automatic restarts).
.PARAMETER SkipWinUtil
    Do not run WinUtil at the end.
.PARAMETER SkipChoco
    Do not install the Chocolatey package list (Chocolatey itself is still installed).
.PARAMETER SkipWinget
    Do not install the winget package list.
.PARAMETER SkipDrivers
    Do not install NVIDIA / AMD driver software.
.PARAMETER SkipCustom
    Do not build and install your own packages from the packages\ folder.
.PARAMETER NoReboot
    Never restart automatically. Windows Update still runs, but if it needs a restart the
    chain stops and tells you to restart and re-run.
.PARAMETER Fresh
    Run the full chain (Windows Update + restarts) even if win-setup has completed on
    this PC before.
.PARAMETER OpenWinUtilGui
    Launch the normal WinUtil GUI instead of running it headless with winutil.json.
#>
[CmdletBinding()]
param(
    [switch]$SkipWindowsUpdate,
    [switch]$SkipWinUtil,
    [switch]$SkipChoco,
    [switch]$SkipWinget,
    [switch]$SkipDrivers,
    [switch]$SkipCustom,
    [switch]$NoReboot,
    [switch]$Fresh,
    [switch]$OpenWinUtilGui
)

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
$RepoRaw       = 'https://raw.githubusercontent.com/change117/win-setup/main'
$ScriptUrl     = "$RepoRaw/install.ps1"
$WinUtilConf   = "$RepoRaw/winutil.json"
$ChocoListUrl  = "$RepoRaw/choco-packages.txt"
$WingetListUrl = "$RepoRaw/winget-packages.txt"
$WinUtilUrl    = 'https://christitus.com/win'
$RepoZipUrl    = 'https://github.com/change117/win-setup/archive/refs/heads/main.zip'
$CustomFeed    = "$env:ProgramData\win-setup\feed"   # local Chocolatey source for your own packages
$CustomSource  = 'win-setup'

$StateKey        = 'HKLM:\SOFTWARE\win-setup'
$ResumeTaskName  = 'win-setup-resume'
$MaxUpdateRounds = 3          # each round may end in one restart

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
    $color = switch ($Status) { 'OK' { 'Green' } 'SKIP' { 'DarkGray' } 'MANUAL' { 'Yellow' } 'WARN' { 'Yellow' } default { 'Red' } }
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

function Wait-ForInternet([int]$TimeoutSeconds = 180) {
    # After a restart the network can take a moment. Do not start installing before it is up.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri 'https://raw.githubusercontent.com' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Write-Host '    Waiting for internet...'
            Start-Sleep -Seconds 5
        }
    }
    Write-Warning 'No internet after waiting. Continuing anyway; downloads will probably fail.'
    return $false
}

# ----------------------------------------------------------------------------
# State (survives restarts) + resume task
# ----------------------------------------------------------------------------
function Get-State {
    $s = [pscustomobject]@{ Phase = ''; UpdateRounds = 0; Completed = 0 }
    if (Test-Path $StateKey) {
        $p = Get-ItemProperty $StateKey
        if ($p.Phase)        { $s.Phase        = [string]$p.Phase }
        if ($p.UpdateRounds) { $s.UpdateRounds = [int]$p.UpdateRounds }
        if ($p.Completed)    { $s.Completed    = [int]$p.Completed }
    }
    return $s
}

function Set-State([string]$Name, $Value) {
    if (-not (Test-Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
    New-ItemProperty -Path $StateKey -Name $Name -Value $Value -Force | Out-Null
}

function Reset-State {
    if (Test-Path $StateKey) { Remove-Item $StateKey -Recurse -Force }
}

function Get-SwitchArgs {
    # The switches this run was started with, minus -Fresh (which must not repeat after a restart).
    $out = @()
    foreach ($key in $script:BoundSwitches) { if ($key -ne 'Fresh') { $out += "-$key" } }
    return ($out -join ' ')
}

function Register-ResumeTask {
    # Runs this same script, elevated, the next time this user logs on. Waits for the
    # network before downloading. Deleted again by the script as soon as it starts.
    $switches = Get-SwitchArgs
    $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
             "`$s = `$null; while (-not `$s) { try { `$s = irm '$ScriptUrl' } catch { Start-Sleep 10 } }; " +
             "& ([ScriptBlock]::Create(`$s)) $switches"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $user = "$env:USERDOMAIN\$env:USERNAME"

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand $encoded"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT20S'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    Scheduled '$ResumeTaskName' to continue after the next log-on."
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false
        Write-Host "    Removed resume task '$ResumeTaskName' (continuing from where we left off)."
    }
}

function Test-PendingReboot {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

function Invoke-Reboot([string]$Message, [int]$Seconds = 30) {
    Write-Host ''
    Write-Host $Message -ForegroundColor Yellow
    Write-Host "Restarting in $Seconds seconds. Press Ctrl+C to cancel." -ForegroundColor Yellow
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host -NoNewline "`r    $i  "
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    Restart-Computer -Force
}

# ----------------------------------------------------------------------------
# Windows Update (built-in COM API, no modules needed)
# ----------------------------------------------------------------------------
function Invoke-WindowsUpdatePhase {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'win-setup'
    $searcher = $session.CreateUpdateSearcher()
    $installed = 0; $failed = 0; $reboot = $false

    for ($pass = 1; $pass -le 3; $pass++) {
        Write-Host "    Searching for updates and drivers (pass $pass)..."
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($type in 'Software', 'Driver') {
            try {
                $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='$type'")
            } catch {
                Write-Warning "    Search for $type updates failed: $($_.Exception.Message)"
                continue
            }
            foreach ($u in $res.Updates) {
                # A feature update (next Windows version) can take an hour and reboot on its own schedule. Leave it to Windows.
                if ($u.Title -match 'Feature update|Upgrade to Windows') { Write-Host "    skipping: $($u.Title)"; continue }
                if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
                [void]$coll.Add($u)
            }
        }
        if ($coll.Count -eq 0) { Write-Host '    Nothing left to install.'; break }

        Write-Host "    $($coll.Count) update(s):"
        foreach ($u in $coll) { Write-Host "      - $($u.Title)" }

        Write-Host '    Downloading...'
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $coll
        try { $dl.Download() | Out-Null } catch { Write-Warning "    Download error: $($_.Exception.Message)" }

        $ready = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $coll) {
            if ($u.IsDownloaded) { [void]$ready.Add($u) } else { $failed++; Write-Warning "    not downloaded: $($u.Title)" }
        }
        if ($ready.Count -eq 0) { break }

        Write-Host "    Installing $($ready.Count) update(s)..."
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $ready
        $inst.ForceQuiet = $true
        try {
            $ir = $inst.Install()
        } catch {
            Write-Warning "    Install error: $($_.Exception.Message)"
            $failed += $ready.Count
            break
        }
        for ($i = 0; $i -lt $ready.Count; $i++) {
            $code = $ir.GetUpdateResult($i).ResultCode   # 2 = succeeded, 3 = succeeded with errors
            if ($code -in 2, 3) { $installed++ } else { $failed++; Write-Warning "    failed (code $code): $($ready.Item($i).Title)" }
        }
        if ($ir.RebootRequired) { $reboot = $true; break }
    }

    [pscustomobject]@{ Installed = $installed; Failed = $failed; RebootRequired = ($reboot -or (Test-PendingReboot)) }
}

function Wait-WindowsUpdateIdle([int]$TimeoutMinutes = 15) {
    # Do not start our own driver installers while Windows Update is still installing something.
    try {
        $installer = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller()
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $waited = $false
        while ($installer.IsBusy -and (Get-Date) -lt $deadline) {
            Write-Host '    Windows Update is busy in the background, waiting for it to finish...'
            $waited = $true
            Start-Sleep -Seconds 15
        }
        if ($waited) { Write-Host '    Windows Update is idle.' }
    } catch { }
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
    Write-Warning "$Name could not be installed from winget or Chocolatey."
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
        # Latest Game Ready driver first (Windows Update's copy is older), then the NVIDIA App.
        Install-WithFallback -Name 'NVIDIA Game Ready driver' `
            -ChocoIds  @('nvidia-display-driver') `
            -FallbackUrl 'https://www.nvidia.com/drivers/'
        Install-WithFallback -Name 'NVIDIA App' `
            -WingetIds @('Nvidia.NvidiaApp', 'Nvidia.NVIDIAApp') `
            -ChocoIds  @('nvidia-app') `
            -FallbackUrl 'https://www.nvidia.com/en-us/software/nvidia-app/'
    } else {
        Add-Result 'NVIDIA Game Ready driver' 'SKIP' 'no NVIDIA GPU detected'
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
        # No winget or Chocolatey package exists for AMD Adrenalin (checked 2026-10-29).
        # A Ryzen CPU's integrated Radeon shows up as "Microsoft Basic Display Adapter"
        # (vendor 1002) until a driver is installed, so this fires even with an NVIDIA card.
        # Windows Update (phase 1) supplies the iGPU driver; Adrenalin is optional then.
        $amdUrl = 'https://www.amd.com/en/support/download/drivers.html'
        $isIgpuOnly = -not ($hw.GpuNames -match 'Radeon RX|Radeon Pro|Radeon VII')
        $note = if ($isIgpuOnly) { "Ryzen integrated graphics; optional. Windows Update installs its driver. Adrenalin: $amdUrl" }
                else             { "no package source exists; download from $amdUrl" }
        Add-Result 'AMD Adrenalin' 'MANUAL' $note
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
# Your own packages (packages\<name>\, built into a local feed)
# ----------------------------------------------------------------------------
function Build-CustomPackages([string]$PackagesDir, [string]$OutDir) {
    # Packs every packages\<name>\<name>.nuspec. Folders starting with _ are skipped
    # (_shared, _templates). Returns the package IDs that packed.
    $helpers = Join-Path $PackagesDir '_shared\winsetup-helpers.ps1'
    $built = @()
    foreach ($dir in Get-ChildItem -Path $PackagesDir -Directory | Where-Object { $_.Name -notlike '_*' }) {
        $nuspec = Get-ChildItem -Path $dir.FullName -Filter '*.nuspec' | Select-Object -First 1
        if (-not $nuspec) { Add-Result "custom: $($dir.Name)" 'FAIL' 'no .nuspec in folder'; continue }
        $id = [string]([xml](Get-Content -Path $nuspec.FullName -Raw)).package.metadata.id
        $tools = Join-Path $dir.FullName 'tools'
        if ((Test-Path $helpers) -and (Test-Path $tools)) { Copy-Item -Path $helpers -Destination $tools -Force }
        & choco pack $nuspec.FullName --out="$OutDir" --limit-output | Out-Host
        if ($LASTEXITCODE -ne 0) { Add-Result "custom: $id" 'FAIL' "choco pack failed (exit $LASTEXITCODE)"; continue }
        $built += $id
    }
    return $built
}

function Install-CustomPackages {
    if (-not (Test-Choco)) { Add-Result 'Custom packages' 'FAIL' 'choco not available'; return }

    # Get the packages\ folder: download the repo as a zip (no git needed on a fresh PC).
    $work = Join-Path $env:TEMP 'win-setup-src'
    if (Test-Path $work) { Remove-Item -Path $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'repo.zip'
    try {
        Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $work -Force
    } catch {
        Add-Result 'Custom packages' 'FAIL' "could not download repo: $($_.Exception.Message)"
        return
    }
    $repoDir = Get-ChildItem -Path $work -Directory | Select-Object -First 1
    $pkgDir  = if ($repoDir) { Join-Path $repoDir.FullName 'packages' }
    if (-not $pkgDir -or -not (Test-Path $pkgDir)) { Add-Result 'Custom packages' 'SKIP' 'no packages folder in repo'; return }

    # Rebuild the local feed from scratch so it always matches the repo.
    New-Item -ItemType Directory -Path $CustomFeed -Force | Out-Null
    Get-ChildItem -Path $CustomFeed -Filter '*.nupkg' | Remove-Item -Force
    $ids = @(Build-CustomPackages -PackagesDir $pkgDir -OutDir $CustomFeed)
    if ($ids.Count -eq 0) { Add-Result 'Custom packages' 'SKIP' 'none in packages\ yet'; return }

    # Register the feed (priority 1 = checked before the community repo). It stays
    # registered, so 'choco upgrade all' later includes your packages too.
    & choco source add -n="$CustomSource" -s="$CustomFeed" --priority=1 --limit-output | Out-Null

    Write-Host "    $($ids.Count) package(s): $($ids -join ', ')"
    foreach ($id in $ids) {
        # upgrade = install if missing, update if the version in the repo went up.
        Write-Host "    choco upgrade $id"
        & choco upgrade $id -y --no-progress | Out-Host
        $code = $LASTEXITCODE
        if ($code -in 0, 1641, 3010) { Add-Result "custom: $id" 'OK' } else { Add-Result "custom: $id" 'FAIL' "exit code $code" }
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
$script:BoundSwitches = @($PSBoundParameters.Keys | Where-Object { $PSBoundParameters[$_] -is [switch] -and $PSBoundParameters[$_].IsPresent })

if (-not (Test-IsAdmin)) {
    Write-Host 'win-setup needs Administrator rights. Relaunching elevated...' -ForegroundColor Yellow
    $switches = ($script:BoundSwitches | ForEach-Object { "-$_" }) -join ' '
    $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
             "& ([ScriptBlock]::Create((irm '$ScriptUrl'))) $switches"
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

Unregister-ResumeTask
if ($Fresh) { Reset-State }
$state = Get-State
# The full chain (Windows Update + automatic restarts) runs on the first run on a PC, or with -Fresh.
$chain = (-not $SkipWindowsUpdate) -and ($Fresh -or $state.Completed -ne 1)
$script:RebootMessage = $null
$script:RebootDelay   = 30
$runInstall = $true

try {
    Write-Step 'Network'
    Wait-ForInternet | Out-Null

    if ($chain -and $state.Phase -ne 'Install') {
        $round = $state.UpdateRounds + 1
        Write-Step "Windows Update (round $round of $MaxUpdateRounds)"
        Set-State 'UpdateRounds' $round
        Set-State 'Phase' 'Update'
        $wu = Invoke-WindowsUpdatePhase
        $summary = "installed $($wu.Installed)" + $(if ($wu.Failed) { ", $($wu.Failed) failed" })
        if ($wu.RebootRequired) {
            if ($NoReboot) {
                Set-State 'Phase' 'Install'
                Add-Result 'Windows Update' 'WARN' "$summary; restart needed but -NoReboot given. Restart, then re-run."
                $runInstall = $false
            } elseif ($round -lt $MaxUpdateRounds) {
                Register-ResumeTask
                Add-Result 'Windows Update' 'OK' "$summary; restarting, then checking again"
                $script:RebootMessage = 'Windows Update needs a restart. win-setup will continue by itself about 20 seconds after you log back in.'
                $runInstall = $false
            } else {
                Set-State 'Phase' 'Install'
                Add-Result 'Windows Update' 'WARN' "$summary; still wants a restart after $MaxUpdateRounds rounds, continuing anyway"
            }
        } else {
            Set-State 'Phase' 'Install'
            Add-Result 'Windows Update' 'OK' "$summary; up to date"
        }
    } elseif ($SkipWindowsUpdate) {
        Write-Step 'Windows Update'
        Add-Result 'Windows Update' 'SKIP' '-SkipWindowsUpdate'
    } elseif (-not $chain) {
        Write-Step 'Windows Update'
        Add-Result 'Windows Update' 'SKIP' 'win-setup already completed on this PC once (use -Fresh to run the full chain again)'
    }

    if ($runInstall) {
        Write-Step 'Package managers'
        Wait-WindowsUpdateIdle
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

        # Last, so Git/Node/Python etc. from the steps above are already installed.
        Write-Step 'Your own packages (packages folder)'
        if ($SkipCustom) { Add-Result 'Custom packages' 'SKIP' '-SkipCustom' } else { Install-CustomPackages }

        Set-State 'Phase' 'Done'
        Set-State 'Completed' 1
        Set-State 'LastCompleted' (Get-Date).ToString('s')
        if ($chain -and -not $NoReboot) {
            $script:RebootMessage = 'All done. Restarting once more so the driver installs finish.'
            $script:RebootDelay   = 60
        }
    }
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
    if (-not $script:RebootMessage -and $runInstall) {
        Write-Host 'Reboot recommended so driver installs finish.' -ForegroundColor Yellow
    }
    try { Stop-Transcript | Out-Null } catch { }
}

if ($script:RebootMessage) { Invoke-Reboot -Message $script:RebootMessage -Seconds $script:RebootDelay }
