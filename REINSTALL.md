# Fresh reinstall checklist

Written 2026-10-29 for this exact PC. Do the steps in order. Nothing here is optional unless it says so.

**This PC:** MSI MAG X870E TOMAHAWK WIFI, Ryzen 7 9850X3D, RTX 5080, Windows 11 Pro 26H2 (Retail licence, Microsoft account), wired Ethernet.
**Drives:** Windows is on the **Samsung SSD 9100 PRO 2TB** (C:). The **Samsung 990 PRO 2TB** (E:) and **WD 1TB** (D:) are data drives and must not be touched. None are BitLocker-encrypted.

---

## Part 1. Before you wipe (at the current desktop)

1. **Back up anything on C: you want to keep.** Everything under `C:\Users\onlin` goes away: Desktop, Documents, Downloads, Pictures, Videos, game saves that are not cloud-synced, browser passwords if not synced. Copy to D:, E:, or a USB stick. D: and E: survive the reinstall.
2. **Confirm your Microsoft account email.** Settings → Accounts → Your info. Write the email down. You will sign in with it on the fresh install, and that is what re-activates Windows. Have its password and your phone (for the 2FA prompt) ready.
3. **Confirm activation.** Settings → System → Activation. It should say *Windows is activated with a digital license linked to your Microsoft account*. (Checked 2026-10-29: Retail licence, status Licensed.)
4. **Keep the Ethernet cable plugged in.** The script needs internet, and Windows 11 setup needs it too.
5. **Open this page on your phone:** `https://github.com/change117/win-setup/blob/main/REINSTALL.md` so you can read it while the PC is down.

## Part 2. Wipe and reinstall

Use Path A. Path B is only if A fails.

### Path A: Reset this PC (no USB needed)

1. Settings → System → Recovery → **Reset this PC** → **Reset PC**.
2. Choose **Remove everything**.
3. Choose **Cloud download** (fresh copy of Windows from Microsoft).
4. On the *Additional settings* screen click **Change settings** and set:
   - **Clean data? → Yes** for a secure wipe (this overwrites the whole 2 TB and can take several hours). Choose **No** if you just want a normal full reinstall; that takes about 20 minutes.
   - **Delete files from all drives? → No. Only the drive where Windows is installed.** This is the one that protects D: and E:.
5. Click **Confirm** → **Next** → **Reset**. The PC restarts several times. Leave it alone until it shows the blue region-selection screen.

### Path B: USB install (only if Path A fails)

You need an empty USB stick of 8 GB or more. It gets erased.

1. On any working Windows PC, go to `https://www.microsoft.com/software-download/windows11`, download **Windows 11 Installation Media**, run it, choose **USB flash drive**, pick the stick.
2. Plug the stick into this PC. Power on and tap **F11** at the MSI logo. Pick the entry that starts with **UEFI:** and names your USB stick.
3. Windows Setup: Language → **Install Windows 11** → tick the box → **I don't have a product key** → **Windows 11 Pro** → accept → when it asks where to install:
4. Press **Shift + F10** to open a command prompt and type these one at a time:
   ```
   diskpart
   list disk
   ```
   You will see two 1863 GB disks and one 931 GB disk. For each 1863 GB disk run `select disk N` then `detail disk` until the model shown is **Samsung SSD 9100 PRO**. That is the Windows disk. With it selected:
   ```
   clean
   exit
   exit
   ```
   `clean` removes all partitions on that disk only. (`clean all` zero-fills it instead, several hours.)
5. Back in Setup click **Refresh**, select the **Unallocated Space** on that same disk, click **Next**. Leave the other two disks alone.

## Part 3. First-boot setup screens

1. Region → keyboard → it connects over Ethernet by itself.
2. **Sign in with the Microsoft account from Part 1 step 2.** Not a new one.
3. When asked, choose **Set up as new device** (not restore from a backup, so the test is clean).
4. Decline the OneDrive, Microsoft 365, Game Pass and Xbox offers. Privacy toggles: your choice.
5. Wait for the desktop.

## Part 4. Install everything

1. **Windows Update first.** Settings → Windows Update → **Check for updates**. Install everything, **Restart**, check again. Repeat until it says you're up to date. This gets the base GPU, iGPU and chipset drivers installed before the script runs so the installers don't collide. Takes 10 to 20 minutes.
2. Right-click Start → **Terminal** (or **Windows PowerShell**). Paste and press Enter:
   ```powershell
   irm is.gd/win117 | iex
   ```
   If is.gd is ever down, this does the same thing:
   ```powershell
   irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1 | iex
   ```
3. Click **Yes** on the UAC prompt. A new **Administrator** window opens and runs everything. The first window can be closed. **Do not close the Administrator window.**
4. Wait. Chocolatey and the drivers take about 2 minutes. WinUtil then installs the 31 apps (Visual Studio 2026 is the big one). Expect **30 to 60 minutes** total. If a window asks you to install the **App Installer / winget** from the Store, click Install and let it continue.
5. When it finishes it prints a **Summary** table. What it should say:
   - Chocolatey, winget, NVIDIA App, AMD Ryzen Chipset Drivers: **OK**
   - AMD Adrenalin: **MANUAL**. Ignore it. It is the Ryzen's built-in graphics; Windows Update handles that driver and you have the RTX 5080.
   - WinUtil: **OK**
   A full log is at `Desktop\win-setup.log`.
6. **Restart** the PC.
7. Open **NVIDIA App** → **Drivers** → **Download** → **Express installation**. Windows Update's NVIDIA driver is older than the current Game Ready driver.
8. Sign in to Steam, Epic, Chrome, Claude, and the rest.

## If something goes wrong

- **Re-running is safe.** Paste the one-liner again; finished items are skipped.
- **Only WinUtil failed** (its row says FAIL or WARN): run just that part:
  ```powershell
  & ([ScriptBlock]::Create((irm https://christitus.com/win))) -Config https://raw.githubusercontent.com/change117/win-setup/main/winutil.json
  ```
- **A specific WinUtil app failed:** open WinUtil normally (`irm https://christitus.com/win | iex`), tick that app, Install. WinUtil's own log is in `%LOCALAPPDATA%\winutil`.
- **No internet on the fresh install:** use the board's Wi-Fi, or tether your phone over USB, then Windows Update will fetch the Ethernet driver.

---

## Context for the next Claude Code session

Everything Claude knew about this project was on C: and is gone after the wipe. This section replaces it.

- Repo: `https://github.com/change117/win-setup`, GitHub user `change117`. Clone it; don't work from a scratch folder. GitHub CLI will need installing (`winget install GitHub.cli`) and `gh auth login --web` again.
- The short link `is.gd/win117` is permanent and cannot be edited or deleted, so never rename the repo, the branch, or `install.ps1`.
- `winutil.json` **must be UTF-8**. WinUtil's Export writes UTF-16, which fails to load from a URL. Re-save as UTF-8 before committing a new export.
- Verified 2026-10-29: Chocolatey has `nvidia-app` and `amd-ryzen-chipset`; winget has no NVIDIA App or AMD chipset package; no Adrenalin package exists anywhere. The script's winget attempts for NVIDIA App are future-proofing and expected to print "No package found".
- The Ryzen 7 9850X3D's integrated Radeon (PCI vendor 1002, device 13C0) shows as "Microsoft Basic Display Adapter" until a driver loads, which is why the AMD-GPU branch fires on this machine. That is correct, not a bug.
- Dry run with `-SkipWinUtil` passed 2026-10-29 in 1 min 34 s. The full run with WinUtil was first exercised during this reinstall; check `Desktop\win-setup.log` for how it went.
- The owner wants to extend this further (more apps, more automation). Package lists `choco-packages.txt` and `winget-packages.txt` are intentionally empty so far.
