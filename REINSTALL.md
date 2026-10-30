# Fresh reinstall checklist

Written 2026-10-30 for this exact PC. Do the steps in order. Nothing here is optional unless it says so.

**This PC:** MSI MAG X870E TOMAHAWK WIFI, Ryzen 7 9850X3D, RTX 5080, Windows 11 Pro 26H2 (Retail digital licence), wired Ethernet.
**Drives:** Windows is on the **Samsung SSD 9100 PRO 2TB** (C:). The **Samsung 990 PRO 2TB** (E:) and **WD 1TB** (D:) are data drives and must not be touched. None are BitLocker-encrypted.
**Install media:** a Rufus-made Windows 11 USB with the sign-in bypass, so there is no Microsoft account step.

---

## Part 1. Before you wipe (at the current desktop)

1. **Back up anything on C: you want to keep.** Everything under `C:\Users\onlin` goes away: Desktop, Documents, Downloads, Pictures, Videos, game saves that are not cloud-synced, browser passwords if not synced. Copy to D:, E:, or a USB stick. D: and E: survive the reinstall.
2. **Keep the Ethernet cable plugged in.** The script needs internet.
3. **Open this page on your phone:** `https://github.com/change117/win-setup/blob/main/REINSTALL.md` so you can read it while the PC is down.

Activation needs nothing from you. The Retail licence is a digital licence tied to this hardware, so a fresh install activates on its own once it is online, local account or not.

## Part 2. Wipe and reinstall from the Rufus USB

1. Plug in the Rufus USB. Power on and tap **F11** at the MSI logo. Pick the entry that starts with **UEFI:** and names your USB stick.
2. Windows Setup: language → **Install Windows 11** → tick the box → **I don't have a product key** → **Windows 11 Pro** → accept → when it asks where to install:
3. Press **Shift + F10** to open a command prompt and type these one at a time:
   ```
   diskpart
   list disk
   ```
   You will see two 1863 GB disks and one 931 GB disk. Run `select disk N` then `detail disk` on a 1863 GB disk until the model shown is **Samsung SSD 9100 PRO**. That is the Windows disk. With it selected:
   ```
   clean
   exit
   exit
   ```
   `clean` removes every partition on that disk only. For a zero-fill wipe use `clean all` instead (several hours on 2 TB).
4. Back in Setup click **Refresh**, select the **Unallocated Space** on that same disk, click **Next**. Leave the other two disks alone.
5. The PC restarts a few times. With the Rufus bypass you land on a desktop with your local admin account. Done with Part 2.

**If the USB will not boot** (fallback, no USB needed): at the current desktop, Settings → System → Recovery → **Reset this PC** → **Remove everything** → **Cloud download** → **Change settings** → **Only the drive where Windows is installed** (this protects D: and E:) → Reset. You will get a normal Microsoft-account sign-in screen afterwards; use the account you use today.

## Part 3. At the fresh desktop

1. Optional, your habit: Start → type **UAC** → open it → drag the slider to **Never notify** → OK. With this the whole chain below runs with zero prompts. Without it you click **Yes** once.
2. Right-click Start → **Terminal** (or **Windows PowerShell**). Paste and press Enter:
   ```powershell
   irm is.gd/win117 | iex
   ```
   If is.gd is ever down, this does the same thing:
   ```powershell
   irm https://raw.githubusercontent.com/change117/win-setup/main/install.ps1 | iex
   ```
3. Click **Yes** on the UAC prompt if one appears. A new **Administrator** window opens. **Walk away.** From here it is automatic:
   - **Windows Update** installs every pending update and driver (board, chipset, network, base GPU and iGPU). About 5 to 15 minutes.
   - If a restart is needed, it **restarts by itself** (30-second countdown) and continues about 20 seconds after the desktop is back. If you see a sign-in screen, sign in; that is the only thing you might have to do. It checks Windows Update again and repeats, up to 3 restarts.
   - Then it installs Chocolatey, the **NVIDIA Game Ready driver** (screen may flicker or go black for a few seconds), **NVIDIA App**, **AMD Chipset drivers**, then runs **WinUtil** for the 31 apps. Visual Studio 2026 is the big one. Expect **30 to 60 minutes**.
   - It prints a **Summary**, then **restarts one last time** (60-second countdown).
4. After that final restart, everything is installed. Check `Desktop\win-setup.log` if you want the details. What the Summary should say:
   - Windows Update, Chocolatey, winget, NVIDIA Game Ready driver, NVIDIA App, AMD Ryzen Chipset Drivers, WinUtil: **OK**
   - AMD Adrenalin: **MANUAL**. Ignore it. It is the Ryzen's built-in graphics; Windows Update already installed its driver and you have the RTX 5080.
5. Sign in to Steam, Epic, Chrome, Claude, and the rest. That is the only manual part.

## If something goes wrong

- **It restarted but nothing happened after log-on:** wait a full minute (it waits for the network). If still nothing, paste the one-liner again. It picks up where it left off; progress is saved in the registry.
- **Re-running is always safe.** Finished items are skipped. After the first full completion it no longer restarts on its own.
- **Only WinUtil failed** (its row says FAIL or WARN): run just that part:
  ```powershell
  & ([ScriptBlock]::Create((irm https://christitus.com/win))) -Config https://raw.githubusercontent.com/change117/win-setup/main/winutil.json
  ```
- **A specific WinUtil app failed:** open WinUtil normally (`irm https://christitus.com/win | iex`), tick that app, Install. WinUtil's own log is in `%LOCALAPPDATA%\winutil`.
- **No internet on the fresh desktop:** use the board's Wi-Fi, or tether your phone over USB. The script waits up to 3 minutes for a connection at every start.
- **You want to stop the chain:** press Ctrl+C in the Administrator window during a countdown. To make sure it does not resume at next log-on, run `Unregister-ScheduledTask win-setup-resume -Confirm:$false` in an admin PowerShell.

---

## Context for the next Claude Code session

Everything Claude knew about this project was on C: and is gone after the wipe. This section replaces it.

- Repo: `https://github.com/change117/win-setup`, GitHub user `change117`. Clone it; don't work from a scratch folder. GitHub CLI will need installing (`winget install GitHub.cli`) and `gh auth login --web` again. Watch for the right GitHub account in the browser; the owner has more than one.
- The short link `is.gd/win117` is permanent and cannot be edited or deleted, so never rename the repo, the branch, or `install.ps1`.
- `winutil.json` **must be UTF-8**. WinUtil's Export writes UTF-16, which fails to load from a URL. Re-save as UTF-8 before committing a new export.
- The script is phase-aware. State lives in `HKLM\SOFTWARE\win-setup` (`Phase` = Update/Install/Done, `UpdateRounds`, `Completed`). The restart hand-off is a scheduled task `win-setup-resume` (at log-on, RunLevel Highest, 20 s delay) that the script deletes when it resumes. Windows Update uses the built-in `Microsoft.Update.Session` COM API, no modules. Feature updates (next Windows version) are deliberately skipped.
- Verified 2026-10-29/30: Chocolatey has `nvidia-display-driver` (strips extras, DCH, Game Ready), `nvidia-app` and `amd-ryzen-chipset`; winget has no NVIDIA App or AMD chipset package; no Adrenalin package exists anywhere. The Windows Update phase installed 10 updates (4 software, 6 drivers) in 4 min with 0 failures on this box. State registry, resume task and switch forwarding tested elevated.
- The Ryzen 7 9850X3D's integrated Radeon (PCI vendor 1002, device 13C0) shows as "Microsoft Basic Display Adapter" until a driver loads, which is why the AMD-GPU branch fires on this machine. That is correct, not a bug.
- The owner sets UAC to "Never notify" by hand right after install and is fine with that trade-off. Not automated on purpose.
- The owner wants to extend this further (more apps, more automation). Package lists `choco-packages.txt` and `winget-packages.txt` are intentionally empty so far.
