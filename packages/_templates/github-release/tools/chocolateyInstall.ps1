$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$toolsDir\winsetup-helpers.ps1"

# 1. Which repo, and which file from its latest release (* is a wildcard).
#    Zip or portable exe: unpacked/copied to %LOCALAPPDATA%\Programs\__ID__
#    Installer exe: add -SilentArgs '/S' (NSIS) or '/VERYSILENT' (Inno Setup)
#    Msi: installs silently on its own
$dir = Install-GitHubRelease -Repo 'OWNER/REPO' -Asset '*win*x64*.zip'

# 2. Optional extras (remove the # to use):
# Install-ChocolateyPath $dir -PathType Machine                    # put it on PATH
# New-StartMenuShortcut -Name '__ID__' -Target "$dir\__ID__.exe"    # Start Menu (add -Desktop for desktop too)
