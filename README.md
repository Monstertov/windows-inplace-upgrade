# windows-inplace-upgrade

<p align="center">
  <a href="https://learn.microsoft.com/powershell/" target="_blank"><img src="https://custom-icon-badges.demolab.com/badge/PowerShell-012456?logo=powershell&logoColor=white" alt="PowerShell" /></a>
  <img src="https://img.shields.io/badge/Windows-10%20to%2011-0078D4?logo=windows11&logoColor=white" alt="Windows 10 to 11" />
  <img src="https://img.shields.io/badge/upgrade-in--place-2ea44f" alt="In-place upgrade" />
</p>

**[Quick start](#quick-start)** · **[Usage](#usage)** · **[Options](#optional-parameters)** · **[Window](#-window-optional)** · **[Requirements](#requirements)** · **[What it does](#what-it-does)** · **[Progress](#follow-the-progress)** · **[If something fails](#if-something-fails)** · **[Bug report](#bug-report)** · **[After](#after-the-upgrade)**

One command upgrades a Windows 10 PC to Windows 11 **in place**, unattended. Start it in the evening from an
elevated PowerShell or your RMM and check the PC the next morning. Apps, files and settings stay.

It gets the install media from Microsoft, reboots by itself and carries on after every reboot without anyone
signing in. It also works on PCs that Windows 11 rejects (old CPU, no TPM 2.0, Legacy BIOS, Secure Boot off).
If it cannot finish, `C:\Win11Upgrade\REPORT.txt` on the PC says why.

> [!CAUTION]
> **The PC reboots by itself, without asking.** Save your work first and run it outside working hours, or use
> `-Window` ([see below](#-window-optional)) to choose when setup and reboots may happen.

> [!CAUTION]
> **Run it once per PC. Never put it in a recurring job or scheduled task** (RMM or otherwise): every run
> starts a new upgrade attempt.

> [!WARNING]
> Upgrading hardware that Windows 11 does not officially support (the bypass) is **not supported by
> Microsoft**. Such a PC may not get all updates. Make a backup first, on every PC.

## Quick start

On each PC, in PowerShell **as Administrator** (or from an RMM as SYSTEM):

**1. Check the PC (optional, changes nothing).** The `VERDICT:` line says `READY`, `BYPASS` (works, with the
unsupported hardware bypass), `BLOCKED` (cannot work, the blockers follow on that line) or `ALREADY_WIN11`.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1))) -CheckOnly
```

**2. Start the upgrade for tonight.** The download starts right away, setup and the reboots wait for the window
(here 20:00 to 06:00, the PC's own clock). Wait for the green line, then close the window.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1))) -Window 20:00-06:00
```

Leave the PC switched on, and not asleep, overnight. Nobody needs to sign in.

**3. Next morning, check the result.** `winver` shows Windows 11, and `C:\Win11Upgrade\upgrade.log` has a line
starting with `DONE:` near the bottom. Still Windows 10? Open `C:\Win11Upgrade\REPORT.txt`: it says why and what
to do. No `REPORT.txt` means it did not give up: it is still busy or waiting for the next window, the log says which.

That is all. The sections below explain every option, what happens on the PC and what to do when something fails.

<sub>[back to top](#windows-inplace-upgrade)</sub>

## Usage

Administrator or SYSTEM (for example from an RMM) is required.

**Run in PowerShell, as Administrator** (not cmd.exe: `irm` only exists in PowerShell, from cmd type `powershell` first):

```powershell
irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1 | iex
```

Wait for the green line, then close the window. The upgrade continues in the background.
It takes about 45 to 90 minutes, depending on the PC and the internet speed. The PC restarts at least once.

> [!IMPORTANT]
> **Still Windows 10 afterwards? Open `C:\Win11Upgrade\REPORT.txt` on that PC.** The script writes it when it
> gives up or cannot start: why it stopped, what that means and what to do. See [If something fails](#if-something-fails).

### Optional parameters

All options are optional. `-Window` has its [own section](#-window-optional).

Parameters go behind the command, in this form:

**Run in PowerShell, as Administrator:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1))) -CheckOnly
```

| Parameter | What it does |
|---|---|
| `-CheckOnly` | Only checks if the PC can upgrade and changes nothing. |

### `-Window` (optional)

`-Window` is optional. Without it the upgrade starts right away and reboots whenever it needs to. Add it when
the PC is in use during the day and setup and the reboots should wait for a quiet period.

Format: `HH:mm-HH:mm`, 24-hour clock, start then end. The window may cross midnight.

**The time is the local system time of the PC** the script runs on (its own clock and time zone, not your
time zone and not the server's). A PC set to a different time zone than you expect opens its window at that PC's
local time.

What waits for the window: starting setup and every reboot. What does not: the checks, cleanup and the
download start right away, so setup can begin the moment the window opens. The window is remembered across
reboots. An invalid value is refused before anything is changed.

**Reboots never start outside the window, and not in its last 45 minutes.** After the script restarts the PC,
Windows restarts it a few more times by itself to finish the upgrade (about 10 minutes on fast PCs, longer on slow
ones). The 45 minutes are for that, so it is done before the window closes. In a window shorter than 45 minutes,
reboots only start at the beginning of the window.

**When setup finishes too late**, for example at 02:30 in a `20:00-03:00` window, the PC is not restarted. It stays
on with Windows 10, can be used normally, and the script restarts it at the start of the next window to finish the
upgrade. Restarting the PC yourself in the meantime finishes it too; that restart then takes as long as the
upgrade's own restarts (10 minutes or more).

The window decides when setup may **start**. It is not a deadline: nobody can say how long an upgrade takes on a
given PC. On two fast PCs setup took 35 to 45 minutes and the whole run about an hour, but a slow disk, an old CPU or
a pending update round makes it take much longer. Setup that starts inside the window keeps running past its end,
so the PC can be busy (not restarting) after the window closes. On a very slow PC, Windows' own restarts can also
take longer than 45 minutes. So choose a window that opens early enough, and do not use a short window to guarantee
the PC is free by a certain time.

**Run in PowerShell, as Administrator:**

```powershell
# overnight, crosses midnight: 20:00 until 03:00 the next morning
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1))) -Window 20:00-03:00

# same day: 01:00 until 05:00
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1))) -Window 01:00-05:00

# lunch break
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/install.ps1))) -Window 12:00-13:00
```

<sub>[back to top](#windows-inplace-upgrade)</sub>

## Requirements

- Windows 10, 64-bit, Home, Pro or Education (Enterprise is not in Microsoft's public ISO).
- Administrator or SYSTEM.
- At least 30 GB free on the system drive, and internet access to `github.com` and `microsoft.com`.
- Windows language Dutch or English (nl, en-US, en-GB). Other languages stop with a clear message.
- Windows Server and domain controllers are refused before anything is changed.

<sub>[back to top](#windows-inplace-upgrade)</sub>

## What it does

1. Checks the PC (Windows build, CPU, TPM, firmware, RAM, disk, and the boot layout of the system disk: EFI partition, boot configuration, cloned-disk leftovers) and stops early if it can never work. See [Requirements](#requirements).
2. Frees disk space if needed: old system temp files and update caches only. Nothing of yours is deleted.
3. Downloads the official Windows 11 ISO for your language straight from Microsoft and checks Microsoft's SHA256.
   When Microsoft's ISO download does not work (it breaks now and then, for example on the day a new version comes
   out), it uses the catalog of Microsoft's Media Creation Tool instead: it downloads the Windows image (ESD) for your
   language and edition from Microsoft's update servers, checks its SHA256 and builds the setup media with DISM, which is
   part of Windows. That catalog always has the newest release, so this way the PC may get a newer version than the ISO.
4. Runs `setup.exe /auto upgrade`, an in-place upgrade that keeps apps, files and settings. If keeping them is
   not possible, setup stops and changes nothing. It never does a clean install.
5. Reboots and finishes the upgrade. If setup fails or rolls back, it repairs Windows (DISM, sfc) and tries
   again, up to 3 attempts.
6. Removes its own scheduled task and the downloaded media when Windows 11 is running or when it gives up.

Nothing is sent anywhere. Everything stays on the PC, only downloads from GitHub and Microsoft happen.
The script updates itself from this repository every time it starts.

<sub>[back to top](#windows-inplace-upgrade)</sub>

## Follow the progress

Everything is written to one log:

**Run in PowerShell, as Administrator:**

```powershell
Get-Content C:\Win11Upgrade\upgrade.log -Tail 40 -Wait
```

More checks, all read-only:

**Run in PowerShell, as Administrator:**

```powershell
Get-ScheduledTask -TaskName Win11-Upgrade                        # Running = the upgrade is active
(Get-ItemProperty HKLM:\SYSTEM\Setup\MoSetup\Volatile).SetupProgress   # setup percentage, only while setup runs
Get-Content C:\Win11Upgrade\state.json                           # phase and attempts
```

During the download and setup the log gets a line every 5 minutes. After a reboot the first line can take
a minute or two.

<sub>[back to top](#windows-inplace-upgrade)</sub>

## If something fails

> [!IMPORTANT]
> **Start with `C:\Win11Upgrade\REPORT.txt`.** It says why the upgrade stopped, what that means and what to do,
> with the PC's details and where the logs are. Next to it is `C:\Win11Upgrade\bugreport.zip` for a [bug report](#bug-report).

A log line starting with `FAILED:` names the reason, followed by where to look. Then:

1. Read `C:\Win11Upgrade\upgrade.log` from the bottom. It holds the setup error code, the last lines of
   setup's error log, apps or drivers that block the upgrade, and the result of Microsoft's SetupDiag.
2. Fix the cause ([see the table](#error-table)), then run the command again. A new run starts 3 fresh attempts.

<a id="error-table"></a>

| Log says | Meaning | What to do |
|---|---|---|
| `Blocking: ...` or `0xC1900208` | An app or driver blocks the upgrade. Nothing is uninstalled for you. | Update or uninstall the named app or driver, run again. |
| `0xC190020E`, `0x80070070` | Not enough disk space. | Free space (30 GB or more), run again. |
| `0xC1900204`, `0xC1900215` | The install media has no image for this edition and language. | Not fixable by retrying. Only Dutch and English are supported. |
| `Install media not ready` | Neither the ISO nor the Media Creation Tool catalog gave a download, the download broke, or building the media failed. | Check the internet and that `microsoft.com` is reachable. For a DISM error, see `C:\Windows\Logs\DISM\dism.log`. It retries 12 times, waiting 1, 2, 5, 10 and 15 minutes at first, then 30 minutes. Microsoft limits repeated requests from one address, so many PCs behind one IP can slow each other down. |
| `Blocked: ...` | This PC can never run Windows 11 (32-bit, CPU without SSE4.2, Enterprise edition, not Windows 10). | Nothing to fix. |
| `Setup rolled back` | Windows 11 was installed but did not start, Windows 10 came back with everything as before. | Read the SetupDiag lines in the [log](#follow-the-progress) and run again. |
| `BOOT WARNING: ...` or `0xC1900104` | The boot layout of the disk is off: EFI partition missing, too full or not FAT32, boot files on another disk, disk style does not match the firmware. Typical after cloning a disk. | Fix the partition layout (for example free space on the EFI partition, or remove the old cloned disk), run again. |

Setup's own logs, for deeper digging ([where to follow the log](#follow-the-progress)):

| Location | Holds |
|---|---|
| `C:\Win11Upgrade\logs\` | Logs copied by setup, and `SetupDiagResults.xml`. |
| `C:\$WINDOWS.~BT\Sources\Panther\` | `setupact.log`, `setuperr.log`, `CompatData*.xml` (compatibility blocks). |
| `C:\$WINDOWS.~BT\Sources\Rollback\` | Logs of a rolled back upgrade. |
| `C:\Windows\Panther\` | Logs after a successful upgrade. |

<sub>[back to top](#windows-inplace-upgrade)</sub>

## Bug report

Think the script did something wrong, or `REPORT.txt` does not explain it? [Open an issue](https://github.com/Monstertov/windows-inplace-upgrade/issues/new)
and attach `C:\Win11Upgrade\bugreport.zip` from that PC. The script makes it when it stops. It holds:

- `REPORT.txt`: why it stopped and the PC's details
- `upgrade.log`: everything the script did, with times
- `state.json`: phase and attempts
- `setuperr.log`, `rollback-setuperr.log`, `CompatData*.xml`, `SetupDiagResults.xml`: setup's errors, blocks and Microsoft's diagnosis

These files contain the PC name and hardware details. Look through them before you share them.
If the zip is missing, attach `REPORT.txt` and `upgrade.log` instead. In the issue, also say how you ran the command
(PowerShell as Administrator, RMM as SYSTEM, with or without `-Window`).

Sometimes more is needed: `setupact.log` in `C:\$WINDOWS.~BT\Sources\Panther` (large, zip it first) or
`C:\Windows\Logs\DISM\dism.log` for a DISM error. The issue will say so.

<sub>[back to top](#windows-inplace-upgrade)</sub>

## After the upgrade

The log stays in `C:\Win11Upgrade`. The old Windows stays in `C:\Windows.old` for 10 days, so you can go back
through Settings > System > Recovery. You can delete `C:\Win11Upgrade` when you no longer need the log (and `REPORT.txt`, if a run stopped).

To stop a run that has not reached setup yet, remove its task and folder:

**Run in PowerShell, as Administrator:**

```powershell
Unregister-ScheduledTask -TaskName Win11-Upgrade -Confirm:$false
Remove-Item C:\Win11Upgrade -Recurse -Force
```

Do not do this while setup is running.

<sub>[back to top](#windows-inplace-upgrade)</sub>

## Shoutout

The Microsoft ISO lookup follows the flow of [Fido](https://github.com/pbatard/Fido) by Pete Batard. The Media Creation
Tool catalog query is the same one [download-windows-esd](https://github.com/mattieb/download-windows-esd) uses.
This project is not affiliated with Microsoft. Use it at your own risk.

<sub>[back to top](#windows-inplace-upgrade)</sub>
