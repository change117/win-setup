$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$toolsDir\winsetup-helpers.ps1"

# 1. Copies everything in this package's tools\files\ folder to
#    %LOCALAPPDATA%\Programs\__ID__  (pass -Destination 'C:\Somewhere' to change).
#    This repo is PUBLIC: only put files here you are fine with anyone seeing.
$dir = Install-PackageFiles

# 2. Optional extras:
# Install-ChocolateyPath $dir -PathType Machine
# New-StartMenuShortcut -Name '__ID__' -Target "$dir\__ID__.exe"
