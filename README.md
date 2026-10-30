# win-setup

One command that puts everything back on a freshly installed Windows PC.

**Doing a full wipe and reinstall? Follow [REINSTALL.md](REINSTALL.md) step by step.**

## The one-liner

Open **PowerShell** (normal, not admin; it elevates itself) and paste:

```powershell
irm is.gd/win117 | iex
```

`is.gd/win117` is a permanent 301 redirect to the raw script. If the shortener is ever down, the long form does the same thing:

```powershell
irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1 | iex
```

Accept the UAC prompt. Then walk away. It will:

1. Install **Chocolatey** and make sure **winget** works.
2. Detect your hardware and install **NVIDIA App** (NVIDIA GPU) and **AMD Ryzen Chipset drivers** (AMD CPU) from Chocolatey. If an AMD GPU is present it opens the **AMD Adrenalin** download page, since no package manager carries Adrenalin. A Ryzen CPU's integrated Radeon counts as an AMD GPU here; its driver is optional when you have a dedicated card, and Windows Update installs one anyway.
3. Install everything in [`choco-packages.txt`](choco-packages.txt) and [`winget-packages.txt`](winget-packages.txt).
4. Run **Chris Titus WinUtil** headless with [`winutil.json`](winutil.json), which installs all the apps you selected there (Firefox, Chrome, Brave, VS Code, Git, Node, Steam, Epic, Blender, VLC, 7-Zip, ...).
5. Print a summary. A full log is saved to `Desktop\win-setup.log`.

Reboot when it is done so the driver installs finish.

## Options

To pass switches you need this form:

```powershell
& ([ScriptBlock]::Create((irm is.gd/win117))) -SkipWinUtil
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
- Tested 2026-10-29 on a Ryzen 7 9850X3D + RTX 5080 box: 1 min 34 s with WinUtil skipped, NVIDIA App and AMD Chipset Software installed, Adrenalin flagged MANUAL for the iGPU.
- `winutil.json` must stay UTF-8. WinUtil's own Export writes UTF-16, which fails to load from a URL, so re-save it as UTF-8 (VS Code: click the encoding in the status bar → Save with Encoding → UTF-8) before committing a new export.
- Needs Windows 10/11 with Windows PowerShell 5.1 (built in). No prerequisites.
- Everything in this repo is just package names, nothing private.
- The short link cannot be edited or deleted by anyone (is.gd policy), so it will always point at this repo's `main/install.ps1`. Changing the script means pushing to this repo, never touching the link.
