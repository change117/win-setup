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

Accept the UAC prompt. Then walk away. On a fresh PC it runs as one unattended chain:

1. **Windows Update**, including every driver Windows offers (board, chipset, network, base GPU and iGPU). If a restart is needed it schedules itself to continue, restarts, and checks again until nothing is left (at most 3 restarts). This is what keeps the vendor driver installers below from colliding with Windows' own.
2. Install **Chocolatey** and make sure **winget** works.
3. Detect your hardware and install the **NVIDIA Game Ready driver** + **NVIDIA App** (NVIDIA GPU) and **AMD Ryzen Chipset drivers** (AMD CPU) from Chocolatey. An AMD GPU is reported as MANUAL with the Adrenalin download link, since no package manager carries Adrenalin. A Ryzen CPU's integrated Radeon counts as an AMD GPU here; Windows Update already installed its driver in step 1, so Adrenalin is optional.
4. Install everything in [`choco-packages.txt`](choco-packages.txt) and [`winget-packages.txt`](winget-packages.txt).
5. Run **Chris Titus WinUtil** headless with [`winutil.json`](winutil.json), which installs all the apps you selected there (Firefox, Chrome, Brave, VS Code, Git, Node, Steam, Epic, Blender, VLC, 7-Zip, ...).
6. Build and install **your own packages** from [`packages/`](packages) (your programs, GitHub apps, project setups). See [Your own programs](#your-own-programs).
7. Print a summary, save a full log to `Desktop\win-setup.log`, and restart one last time.

If the PC restarts to a sign-in screen mid-chain, just sign in. The script continues on its own about 20 seconds later in a new Administrator window.

The Windows Update step and the automatic restarts only happen the **first** time win-setup completes on a PC. Running the one-liner again later just installs packages and never restarts, so adding apps is quick. Use `-Fresh` to force the full chain again.

## Options

To pass switches you need this form:

```powershell
& ([ScriptBlock]::Create((irm is.gd/win117))) -SkipWinUtil
```

| Switch | Effect |
|---|---|
| `-SkipWindowsUpdate` | Don't run Windows Update (also disables the automatic restarts) |
| `-NoReboot` | Never restart automatically; if Windows Update needs one, the chain stops and tells you |
| `-Fresh` | Run the full chain (Windows Update + restarts) even if win-setup already completed on this PC |
| `-SkipWinUtil` | Don't run WinUtil at the end |
| `-SkipChoco` | Don't install the Chocolatey list (Chocolatey itself is still set up) |
| `-SkipWinget` | Don't install the winget list |
| `-SkipDrivers` | Don't install NVIDIA / AMD driver software |
| `-SkipCustom` | Don't build/install your own packages from `packages/` |
| `-OpenWinUtilGui` | Open the normal WinUtil window instead of running it headless |

Switches can be combined.

## Adding or removing apps

Edit the files right here on GitHub (pencil icon), commit, done. The one-liner never changes.

- **Chocolatey app** → add its ID on its own line in `choco-packages.txt`. Find IDs at <https://community.chocolatey.org/packages> or `choco search <name>`.
- **winget app** → add its exact ID in `winget-packages.txt`. Find IDs with `winget search <name>`.
- **WinUtil selection changed** → in WinUtil click the gear icon → **Export**, then replace `winutil.json` with the new file.

Lines starting with `#` are comments, so you can park apps you don't want right now.

## Your own programs

Anything winget and the Chocolatey catalog don't have (programs you built, apps from GitHub, projects that need cloning and setup) goes in `packages/`. Each folder there is one Chocolatey package. win-setup builds them into a local feed on the PC (`C:\ProgramData\win-setup\feed`) and installs them last, after Git/Node/Python are in. No server, no cloud drive.

**Add one** (in a clone of this repo on your PC):

```powershell
.\pkg.ps1 new my-tool -Kind github-release   # app from a GitHub release (zip, exe, msi)
.\pkg.ps1 new my-proj -Kind git-project      # clone a repo + run its setup commands
.\pkg.ps1 new my-app  -Kind files            # files stored right here in the repo
```

1. Open `packages\<name>\tools\chocolateyInstall.ps1` and fill in the marked lines (repo name, file pattern, setup commands). Each template is commented.
2. `.\pkg.ps1 test <name>` in an **Admin** PowerShell builds and installs it on this PC.
3. Commit and push. Every win-setup run from now on installs it.

**Change one later:** edit it and bump `<version>` in its `.nuspec`. Re-running win-setup (or `choco upgrade all`) updates it.

**Remove one:** delete its folder. **Park one:** rename the folder to start with `_`.

Notes:
- Helpers you can use in any package: `Install-GitHubRelease`, `Install-GitProject`, `Invoke-InFolder`, `Install-PackageFiles`, `New-StartMenuShortcut`, plus Chocolatey's own (`Install-ChocolateyPath`, ...). All in [`packages/_shared/winsetup-helpers.ps1`](packages/_shared/winsetup-helpers.ps1).
- Projects clone to `%USERPROFILE%\Projects` by default. Change `$WinSetupProjectsRoot` at the top of that helpers file (e.g. to `D:\Projects`, which survives a wipe; existing clones are just pulled).
- **This repo is public.** Package scripts are fine to share; don't put private files in `files` packages. Private GitHub repos work if you set a token once before running win-setup: `[Environment]::SetEnvironmentVariable('GITHUB_TOKEN','<token>','User')`.
- If Windows blocks `.\pkg.ps1`, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once.

## Just want WinUtil with your selection?

```powershell
& ([ScriptBlock]::Create((irm https://christitus.com/win))) -Config https://raw.githubusercontent.com/change117/win-setup/main/winutil.json
```

## Notes

- Re-running is safe. Already-installed packages are skipped or upgraded, and after the first completed run it never restarts on its own.
- Progress survives restarts in the registry key `HKLM\SOFTWARE\win-setup` (`Phase`, `UpdateRounds`, `Completed`). The restart hand-off is a scheduled task named `win-setup-resume`, which the script deletes as soon as it continues. Delete both to make a PC look "fresh" again.
- Tested 2026-10-29/30 on a Ryzen 7 9850X3D + RTX 5080 box: drivers-only run 1 min 34 s, NVIDIA App and AMD Chipset Software installed, Adrenalin flagged MANUAL for the iGPU; Windows Update phase, state and resume task verified.
- `winutil.json` must stay UTF-8. WinUtil's own Export writes UTF-16, which fails to load from a URL, so re-save it as UTF-8 (VS Code: click the encoding in the status bar → Save with Encoding → UTF-8) before committing a new export.
- Needs Windows 10/11 with Windows PowerShell 5.1 (built in). No prerequisites.
- Everything in this repo is public: package names and install scripts, nothing private.
- The short link cannot be edited or deleted by anyone (is.gd policy), so it will always point at this repo's `main/install.ps1`. Changing the script means pushing to this repo, never touching the link.
