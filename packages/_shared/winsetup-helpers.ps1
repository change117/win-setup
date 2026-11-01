# Shared helpers for win-setup's own Chocolatey packages.
#
# install.ps1 and pkg.ps1 copy this file into every package's tools\ folder right
# before packing it, so each package's chocolateyInstall.ps1 can load it with:
#
#     . "$toolsDir\winsetup-helpers.ps1"
#
# Private GitHub repos: set a GitHub token once (User scope) before running win-setup:
#     [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'ghp_...', 'User')
# Public repos need nothing.

# Where Install-GitProject clones your projects. Change this one line to move them all
# (for example to 'D:\Projects', which survives a reinstall).
$WinSetupProjectsRoot = Join-Path $env:USERPROFILE 'Projects'

# Where Install-GitHubRelease / Install-PackageFiles put portable apps by default.
$WinSetupAppsRoot = Join-Path $env:LOCALAPPDATA 'Programs'

# This package's tools\ folder (this file sits in it).
$WinSetupToolsDir = $PSScriptRoot

function Get-WinSetupPackageName {
    if ($env:ChocolateyPackageName) { return $env:ChocolateyPackageName }
    return 'win-setup-package'
}

function Get-GitHubHeaders {
    $h = @{ 'User-Agent' = 'win-setup'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $h['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    return $h
}

function Get-GitHubReleaseAsset {
    <#
      Finds one file in a GitHub release.
      -Repo   'owner/name'
      -Asset  wildcard matched against the release's file names, e.g. '*win*x64*.zip'
      -Tag    'latest' (default) or a tag like 'v1.2.0'
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Asset,
        [string]$Tag = 'latest'
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $api = if ($Tag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" }
           else                   { "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
    try {
        $release = Invoke-RestMethod -Uri $api -Headers (Get-GitHubHeaders) -UseBasicParsing -ErrorAction Stop
    } catch {
        $hint = if ($env:GITHUB_TOKEN) { '' } else { ' If the repo is private, set GITHUB_TOKEN (see winsetup-helpers.ps1).' }
        throw "Could not read release '$Tag' of $Repo : $($_.Exception.Message).$hint"
    }
    $match = @($release.assets | Where-Object { $_.name -like $Asset })
    if ($match.Count -eq 0) {
        $names = ($release.assets | ForEach-Object { $_.name }) -join ', '
        throw "No file matching '$Asset' in $Repo release $($release.tag_name). Files there: $names"
    }
    if ($match.Count -gt 1) {
        Write-Warning "Several files match '$Asset'; using $($match[0].name). Make the pattern more specific to pick another."
    }
    $out = $match[0]
    Add-Member -InputObject $out -NotePropertyName tag_name -NotePropertyValue $release.tag_name -Force
    return $out
}

function Save-GitHubAsset {
    # Downloads a release asset. Public: direct link. Private: API link with the token,
    # then the signed redirect without it (GitHub's storage rejects the token).
    param([Parameter(Mandatory)]$Asset, [Parameter(Mandatory)][string]$OutFile)
    $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        if (-not $env:GITHUB_TOKEN) {
            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return
        }
        $req = [Net.HttpWebRequest]::Create($Asset.url)
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'win-setup'
        $req.Accept = 'application/octet-stream'
        $req.Headers.Add('Authorization', "Bearer $env:GITHUB_TOKEN")
        $resp = $req.GetResponse()
        try {
            $location = $resp.Headers['Location']
            if (-not $location) {
                $fs = [IO.File]::Create($OutFile)
                try { $resp.GetResponseStream().CopyTo($fs) } finally { $fs.Close() }
                return
            }
        } finally { $resp.Close() }
        Invoke-WebRequest -Uri $location -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    } finally { $ProgressPreference = $oldProgress }
}

function Install-GitHubRelease {
    <#
      Downloads a file from a GitHub release and installs it. Returns the install folder
      (zip / portable exe) or the downloaded file (installers).

        .zip              -> unzipped into -Destination
        .msi              -> silent install (/qn /norestart unless -SilentArgs given)
        .exe + SilentArgs -> run as an installer with those args (e.g. '/S', '/VERYSILENT')
        .exe (no args)    -> portable: copied into -Destination
        anything else     -> copied into -Destination

      -Destination defaults to %LOCALAPPDATA%\Programs\<package name>.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Asset,
        [string]$Tag = 'latest',
        [string]$Destination,
        [string]$SilentArgs,
        [int[]]$ValidExitCodes = @(0, 1641, 3010)
    )
    $pkg = Get-WinSetupPackageName
    if (-not $Destination) { $Destination = Join-Path $WinSetupAppsRoot $pkg }

    $a = Get-GitHubReleaseAsset -Repo $Repo -Asset $Asset -Tag $Tag
    Write-Host "  $Repo $($a.tag_name): $($a.name)"
    $tmp = Join-Path $env:TEMP "win-setup\$pkg"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $file = Join-Path $tmp $a.name
    Save-GitHubAsset -Asset $a -OutFile $file

    switch ([IO.Path]::GetExtension($file).ToLowerInvariant()) {
        '.zip' {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Get-ChocolateyUnzip -FileFullPath $file -Destination $Destination -PackageName $pkg | Out-Null
            return $Destination
        }
        '.msi' {
            $msiArgs = if ($SilentArgs) { $SilentArgs } else { '/qn /norestart' }
            Install-ChocolateyInstallPackage -PackageName $pkg -FileType 'msi' -File $file -SilentArgs $msiArgs -ValidExitCodes $ValidExitCodes
            return $file
        }
        '.exe' {
            if ($SilentArgs) {
                Install-ChocolateyInstallPackage -PackageName $pkg -FileType 'exe' -File $file -SilentArgs $SilentArgs -ValidExitCodes $ValidExitCodes
                return $file
            }
        }
    }
    # Portable exe or any other single file.
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path $file -Destination $Destination -Force
    return $Destination
}

function Invoke-Git {
    # Runs git without PowerShell treating its normal progress output (stderr) as an error.
    # Call as: Invoke-Git -GitArgs @('clone', $url, $dir)
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $auth = @()
    if ($env:GITHUB_TOKEN) {
        # Token is passed per command and never written into .git\config.
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:GITHUB_TOKEN"))
        $auth = @('-c', "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic")
    }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        & git @auth @GitArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

function Install-GitProject {
    <#
      Clones a GitHub repo into your projects folder, or pulls it if it is already there
      (e.g. it lives on a drive that survived the reinstall). Returns the folder.
        -Repo         'owner/name'
        -Destination  defaults to $WinSetupProjectsRoot\<name>
        -Branch       optional
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Destination,
        [string]$Branch
    )
    if (-not $Destination) { $Destination = Join-Path $WinSetupProjectsRoot ($Repo.Split('/')[-1]) }
    if (Get-Command Update-SessionEnvironment -ErrorAction SilentlyContinue) { Update-SessionEnvironment }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not installed. Keep Git in winutil.json, or add 'git' to choco-packages.txt."
    }

    if (Test-Path (Join-Path $Destination '.git')) {
        Write-Host "  $Destination already exists, pulling latest"
        $code = Invoke-Git -GitArgs @('-C', $Destination, 'pull', '--ff-only')
        if ($code -ne 0) { Write-Warning "git pull failed in $Destination (local changes?). Left as is." }
        return $Destination
    }
    if ((Test-Path $Destination) -and @(Get-ChildItem $Destination -Force).Count -gt 0) {
        throw "$Destination exists and is not a git clone. Move it or pick another -Destination."
    }

    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    $cloneArgs = @('clone')
    if ($Branch) { $cloneArgs += @('--branch', $Branch) }
    $cloneArgs += @("https://github.com/$Repo.git", $Destination)
    $code = Invoke-Git -GitArgs $cloneArgs
    if ($code -ne 0) {
        $hint = if ($env:GITHUB_TOKEN) { '' } else { ' If the repo is private, set GITHUB_TOKEN (see winsetup-helpers.ps1).' }
        throw "git clone of $Repo failed (exit $code).$hint"
    }
    return $Destination
}

function Invoke-InFolder {
    <#
      Runs setup commands inside a folder, exactly as you would type them:
          Invoke-InFolder $dir { npm install }
          Invoke-InFolder $dir { python -m pip install -r requirements.txt }
      Refreshes PATH first so tools installed earlier in the run are found.
      Stops the package with an error if the last command fails.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Script)
    if (Get-Command Update-SessionEnvironment -ErrorAction SilentlyContinue) { Update-SessionEnvironment }
    Push-Location $Path
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        & $Script 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE) { throw "Setup command in $Path failed with exit code $LASTEXITCODE" }
    } finally {
        $ErrorActionPreference = $old
        Pop-Location
    }
}

function Install-PackageFiles {
    <#
      Copies everything in this package's tools\files\ folder to -Destination
      (default %LOCALAPPDATA%\Programs\<package name>). Returns the folder.
    #>
    param([string]$Destination)
    $src = Join-Path $WinSetupToolsDir 'files'
    if (-not (Test-Path $src)) { throw "No files folder in the package: $src" }
    if (-not $Destination) { $Destination = Join-Path $WinSetupAppsRoot (Get-WinSetupPackageName) }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $Destination -Recurse -Force
    return $Destination
}

function New-StartMenuShortcut {
    <#
      Adds a Start Menu shortcut (all users). -Desktop also puts one on your desktop.
          New-StartMenuShortcut -Name 'My App' -Target "$dir\MyApp.exe"
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '',
        [string]$WorkingDirectory,
        [switch]$Desktop
    )
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path $Target -Parent }
    $places = @([Environment]::GetFolderPath('CommonPrograms'))
    if ($Desktop) { $places += [Environment]::GetFolderPath('Desktop') }
    foreach ($dir in $places) {
        Install-ChocolateyShortcut -ShortcutFilePath (Join-Path $dir "$Name.lnk") -TargetPath $Target `
            -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    }
}
