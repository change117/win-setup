$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$toolsDir\winsetup-helpers.ps1"

# 1. Clone the repo into your projects folder (or pull it if it is already there).
#    Projects folder is set at the top of packages\_shared\winsetup-helpers.ps1.
$dir = Install-GitProject -Repo 'OWNER/REPO'

# 2. Setup steps, run inside the project folder. Same commands you would type by hand.
#    Keep the ones you need, delete the rest.
# Invoke-InFolder $dir { npm install }
# Invoke-InFolder $dir { python -m pip install -r requirements.txt }
# Invoke-InFolder $dir { dotnet build -c Release }
# Invoke-InFolder $dir { .\setup.ps1 }

# 3. Optional extras:
# Install-ChocolateyPath $dir -PathType Machine
# New-StartMenuShortcut -Name '__ID__' -Target "$dir\start.bat" -Desktop
