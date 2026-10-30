# win-setup

One command that puts everything back on a freshly installed Windows PC.

## The one-liner

Open **PowerShell** (normal, not admin; it elevates itself) and paste:

```powershell
irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1 | iex
```

Accept the UAC prompt. Then walk away. It will:

1. Install **Chocolatey** and make sure **winget** works.
2. Detect your hardware and install **NVIDIA App** (NVIDIA GPU), **AMD Ryzen Chipset drivers** (AMD CPU) and **AMD Adrenalin** (AMD GPU). If a package source fails it opens the vendor download page instead.
3. Install everything in [`choco-packages.txt`](choco-packages.txt) and [`winget-packages.txt`](winget-packages.txt).
4. Run **Chris Titus WinUtil** headless with [`winutil.json`](winutil.json), which installs all the apps you selected there (Firefox, Chrome, Brave, VS Code, Git, Node, Steam, Epic, Blender, VLC, 7-Zip, ...).
5. Print a summary. A full log is saved to `Desktop\win-setup.log`.

Reboot when it is done so the driver installs finish.

## Options

To pass switches you need the long form:

```powershell
& ([ScriptBlock]::Create((irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1))) -SkipWinUtil
```

| Switch | Effect |
|---|---|
| `-SkipWinUtil` | Don't run WinUtil at the end |
| `-SkipChoco` | Don't install the Chocolatey list (Chocolatey itself is still set up) |
| `-SkipWinget` | Don't install the winget list |
| `-SkipDrivers` | Don't install NVIDIA / AMD driver software |
| `-OpenWinUtilGui` | Open the normal WinUtil window instead of running it headless |

Switches can be combined.

## Adding or removing apps

Edit the files right here on GitHub (pencil icon), commit, done. The one-liner never changes.

- **Chocolatey app** → add its ID on its own line in `choco-packages.txt`. Find IDs at <https://community.chocolatey.org/packages> or `choco search <name>`.
- **winget app** → add its exact ID in `winget-packages.txt`. Find IDs with `winget search <name>`.
- **WinUtil selection changed** → in WinUtil click the gear icon → **Export**, then replace `winutil.json` with the new file.

Lines starting with `#` are comments, so you can park apps you don't want right now.

## Just want WinUtil with your selection?

```powershell
& ([ScriptBlock]::Create((irm https://christitus.com/win))) -Config https://raw.githubusercontent.com/change117/win-setup/main/winutil.json
```

## Notes

- Re-running is safe. Already-installed packages are skipped or upgraded.
- Needs Windows 10/11 with Windows PowerShell 5.1 (built in). No prerequisites.
- Everything in this repo is just package names, nothing private.
