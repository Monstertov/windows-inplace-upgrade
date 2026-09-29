<#
Windows 10 to 11 IN-PLACE upgrade, unattended. Keeps apps, files and settings. Never a clean install:
setup always runs with /auto upgrade, and if keeping apps and data is not possible, setup exits with an
error code and changes nothing (Microsoft Learn, Windows Setup command-line options, /Auto).

Run it elevated (Administrator or SYSTEM), no parameters needed:
  .\Win11-Upgrade.ps1
It copies the latest version of itself from GitHub to C:\Win11Upgrade, hands the work to a SYSTEM
scheduled task and returns. The task downloads the official ISO for the device language straight from
Microsoft, upgrades, reboots by itself (no confirmation), continues after every reboot, retries with
repairs when setup fails, and removes itself when Windows 11 is running or when it gives up.
Everything stays on this PC: the log is C:\Win11Upgrade\upgrade.log. Nothing is sent anywhere except the
downloads from GitHub and Microsoft.

Devices that fail the CPU/TPM/Secure Boot check get the undocumented "setup /product server" switch
plus the AllowUpgradesWithUnsupportedTPMOrCPU key. Unsupported by Microsoft.

Optional -Window "20:00-03:00" (local time of this PC, may cross midnight): checks, cleanup and the ISO download
start right away, but setup and every reboot wait until the window is open. Setup that has started is never
interrupted when the window ends.
#>
param(
    [switch]$CheckOnly,     # readiness check only, changes nothing
    [string]$Window,        # "HH:mm-HH:mm" in local PC time: setup and reboots only inside this window
    [switch]$Worker,        # internal: the scheduled task runs this
    [switch]$NoUpdate       # internal: skip the self-update
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar in 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RawUrl      = 'https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/Win11-Upgrade.ps1'
$SetupDiag   = 'https://go.microsoft.com/fwlink/?linkid=870142'
$TaskName    = 'Win11-Upgrade'
$MaxAttempts = 3       # setup runs, including runs after a rollback
$IsoRetries  = 12      # ISO lookup/download tries, 30 min apart

# Microsoft software-download API, same flow as Fido (github.com/pbatard/Fido).
$MsPage      = 'https://www.microsoft.com/en-us/software-download/windows11'
$MsApi       = 'https://www.microsoft.com/software-download-connector/api/'
$MsProfile   = '606624d44113'
$MsOrg       = 'y6jn8c31'
$MsInst      = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
$MsAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'
# Windows install language (culture) -> language name on Microsoft's download page. Only these are supported.
$IsoLangs    = @{ 'nl' = 'Dutch'; 'en-us' = 'English'; 'en' = 'English International' }

$dir       = Join-Path $env:SystemDrive 'Win11Upgrade'
$self      = Join-Path $dir 'Win11-Upgrade.ps1'
$iso       = Join-Path $dir 'win11.iso'
$logFile   = Join-Path $dir 'upgrade.log'
$stateFile = Join-Path $dir 'state.json'
$bt        = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources'

# Workstations only. WinNT = workstation, ServerNT = server, LanManNT = domain controller.
# Checked before anything is written, so running this on a server by accident changes nothing.
$productType = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -ErrorAction SilentlyContinue).ProductType
if ($productType -ne 'WinNT') {
    try { [Console]::ForegroundColor = 'Red' } catch { }
    [Console]::WriteLine("REFUSED: this is not a Windows workstation (product type '$productType'). Nothing was changed, you can close this window.")
    try { [Console]::ResetColor() } catch { }
    exit 1
}

# "20:00-03:00" -> start and end as time of day. Checked before anything is written.
function ConvertTo-WindowSpan([string]$text) {
    if ($text -notmatch '^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$') { throw "Window '$text' is not HH:mm-HH:mm, for example 20:00-03:00." }
    $h1 = [int]$Matches[1]; $m1 = [int]$Matches[2]; $h2 = [int]$Matches[3]; $m2 = [int]$Matches[4]
    if ($h1 -gt 23 -or $h2 -gt 23 -or $m1 -gt 59 -or $m2 -gt 59) { throw "Window '$text' has an impossible time." }
    $from = New-TimeSpan -Hours $h1 -Minutes $m1; $to = New-TimeSpan -Hours $h2 -Minutes $m2
    if ($from -eq $to) { throw "Window '$text' starts and ends at the same time." }
    [pscustomobject]@{ from = $from; to = $to; text = '{0:00}:{1:00}-{2:00}:{3:00}' -f $h1, $m1, $h2, $m2 }
}
if ($Window) {
    try { $Window = (ConvertTo-WindowSpan $Window).text }
    catch {
        try { [Console]::ForegroundColor = 'Red' } catch { }
        [Console]::WriteLine("REFUSED: $($_.Exception.Message) Nothing was changed, you can close this window.")
        try { [Console]::ResetColor() } catch { }
        exit 1
    }
}
New-Item -ItemType Directory -Force $dir | Out-Null

function Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
    Add-Content -Path $logFile -Value $line
    [Console]::WriteLine($line)
}

# Last line the person at the console sees: whether the window can be closed.
function Close-Console([bool]$ok, [string]$msg) {
    try { [Console]::ForegroundColor = if ($ok) { 'Green' } else { 'Red' } } catch { }
    Log $msg
    try { [Console]::ResetColor() } catch { }
    exit $(if ($ok) { 0 } else { 1 })
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Close-Console $false 'FAIL: run this as Administrator or SYSTEM. Nothing was changed, you can close this window.'
}

$version  = if ($PSCommandPath) { (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.Substring(0, 12) } else { 'inline' }

function New-State { [pscustomobject]@{ runId = [guid]::NewGuid().ToString(); phase = ''; attempts = 0; reboots = 0; isoFails = 0; forceBypass = $false; window = "$Window" } }
function Save-State { $state | ConvertTo-Json | Set-Content $stateFile }
$state = $null
try { $state = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { }
if (-not $state -or -not $Worker) { $state = New-State }
if ($state.window) { $Window = $state.window }   # the task and SetupComplete.cmd run without the parameter

# Local time of this PC. Empty window = always open.
function Test-WindowOpen {
    if (-not $Window) { return $true }
    $w = ConvertTo-WindowSpan $Window
    $now = (Get-Date).TimeOfDay
    if ($w.from -lt $w.to) { $now -ge $w.from -and $now -lt $w.to } else { $now -ge $w.from -or $now -lt $w.to }
}

# Blocks until the window is open. Called before setup and before every reboot, never during setup.
function Wait-Window([string]$before) {
    if (Test-WindowOpen) { return }
    Log "Waiting for the window $Window (PC time) before $before."
    while (-not (Test-WindowOpen)) { Start-Sleep -Seconds 30 }
    Log "Window $Window is open, continuing."
}

# Waits for a process and logs a line every 5 minutes, with the text $detail returns.
function Wait-WithProgress($p, [string]$stage, [scriptblock]$detail) {
    $null = $p.Handle   # without this, ExitCode stays empty in Windows PowerShell 5.1
    $t = Get-Date
    $ticks = 0
    while (-not $p.WaitForExit(60000)) {
        $ticks++
        if ($ticks % 5) { continue }
        $extra = ''
        if ($detail) { try { $extra = "$(& $detail)" } catch { } }
        Log ('{0}: running {1:N0} min{2}' -f $stage, ((Get-Date) - $t).TotalMinutes, $extra)
    }
    $p.ExitCode
}

function Invoke-Tool([string]$exe, [string]$arguments, [string]$stage) {
    Log "Running: $exe $arguments"
    $code = Wait-WithProgress (Start-Process $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru) $stage
    Log "  $exe exit $code"
}

# After a boot the network (Wi-Fi especially) can take a while. Wait up to 10 minutes.
function Wait-Network {
    for ($i = 0; $i -lt 20; $i++) {
        try { Invoke-WebRequest 'https://www.microsoft.com' -Method Head -TimeoutSec 15 -UseBasicParsing | Out-Null; return }
        catch { if ($_.Exception.Response) { return } }   # any HTTP answer means the network is up
        Start-Sleep -Seconds 30
    }
    Log 'No network after 10 minutes, continuing.'
}

# The last lines of setup's error logs, so the reason is in upgrade.log too.
function Write-SetupErrors {
    foreach ($err in "$bt\Panther\setuperr.log", "$bt\Rollback\setuperr.log") {
        if (Test-Path $err) {
            Log "Last lines of ${err}:"
            Get-Content $err -Tail 25 | ForEach-Object { Log "  $_" }
        }
    }
}

function Register-WorkerTask {
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Worker"
    $trigger  = New-ScheduledTaskTrigger -AtStartup   # runs at boot as SYSTEM, nobody needs to sign in
    $trigger.Delay = 'PT2M'
    $runAs    = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 72)   # a window can add most of a day of waiting
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $runAs -Settings $settings -Force | Out-Null
}

function Complete-Task { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

# Microsoft's SetupDiag reads setup's logs and names the root cause of a failed or rolled back upgrade.
function Invoke-SetupDiag {
    try {
        $exe = Join-Path $dir 'SetupDiag.exe'
        if (-not (Test-Path $exe)) { Invoke-WebRequest $SetupDiag -OutFile $exe -TimeoutSec 120 -UseBasicParsing }
        $sig = Get-AuthenticodeSignature $exe
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { Remove-Item $exe -Force; throw 'SetupDiag.exe signature not valid, deleted.' }
        New-Item -ItemType Directory -Force "$dir\logs" | Out-Null
        $out = "$dir\logs\SetupDiagResults.xml"
        Log 'Running SetupDiag.'
        Start-Process $exe -ArgumentList "/Output:`"$out`" /Format:xml" -Wait -WindowStyle Hidden
        $text = Get-Content $out -Raw -ErrorAction SilentlyContinue
        if ($text) { Log "SetupDiag: $($text.Substring(0, [math]::Min(1500, $text.Length)))" }
    } catch { Log "SetupDiag failed: $($_.Exception.Message)" }
}

# Apps and drivers that setup says block keeping them. Report only: nothing is ever uninstalled.
function Get-CompatBlocks {
    $blocks = @()
    Get-ChildItem "$bt\Panther" -Filter 'CompatData*.xml' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            ([xml](Get-Content $_.FullName -Raw)).SelectNodes("//*[CompatibilityInfo[@BlockingType='Hard']]") | ForEach-Object {
                $blocks += ('{0} {1}{2}' -f $_.LocalName, $_.GetAttribute('Name'), $_.GetAttribute('InfPath')).Trim()
            }
        } catch { }
    }
    $blocks | Select-Object -Unique
}

function Get-Readiness {
    $cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuild
    $cpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $sysVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $langCode = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language').InstallLanguage
    $tpm = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
    $secureBoot = $false
    try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
    # Windows 11 24H2 and later do not boot without SSE4.2/POPCNT, no bypass fixes that. PF_SSE4_2_INSTRUCTIONS_AVAILABLE = 38.
    if (-not ('Win11Up.Kernel32' -as [type])) { Add-Type -Namespace Win11Up -Name Kernel32 -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);' }

    $r = [ordered]@{
        edition = $cv.EditionID; displayVersion = $cv.DisplayVersion; build = $build; ubr = $cv.UBR
        lang = [Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($langCode, 16)).Name
        arch = $env:PROCESSOR_ARCHITECTURE; cpu = $cpu; cpuOk = 'check'; sse42 = [Win11Up.Kernel32]::IsProcessorFeaturePresent(38)
        tpm = if ($tpm) { ($tpm.SpecVersion -split ',')[0].Trim() } else { 'none' }
        firmware = $env:firmware_type; secureBoot = $secureBoot; ramGB = $ramGB
        diskGB = [math]::Round($sysVol.Size / 1GB); freeGB = [math]::Round($sysVol.FreeSpace / 1GB)
        pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
    # ponytail: Intel Core generation from the model number only, no full Microsoft CPU list.
    # Anything else reports 'check' and gets the bypass, which is harmless on supported CPUs.
    if ($cpu -match 'Core\(TM\) Ultra|Core Ultra') { $r.cpuOk = 'yes' }
    elseif ($cpu -match 'i[3579]-(\d{4,5})') {
        $num = $Matches[1]   # 6500T -> 6, 8250U -> 8, 1135G7 -> 11, 10210U -> 10
        $gen = if ($num.StartsWith('1')) { [int]$num.Substring(0, 2) } else { [int]$num.Substring(0, 1) }
        $r.cpuOk = if ($gen -ge 8) { 'yes' } else { 'no' }
    }
    $hw = @()
    if ($r.cpuOk -ne 'yes')     { $hw += "CPU($($r.cpuOk))" }
    if ($r.tpm -notlike '2*')   { $hw += "TPM($($r.tpm))" }
    if ($r.firmware -ne 'UEFI') { $hw += 'LegacyBIOS' }
    if (-not $secureBoot)       { $hw += 'SecureBootOff' }
    if ($ramGB -lt 4)           { $hw += 'RAM<4GB' }
    if ($r.diskGB -lt 64)       { $hw += 'Disk<64GB' }
    $bl = @()
    if ($r.arch -ne 'AMD64')                { $bl += "$($r.arch) Windows, only x64 is supported" }
    if (-not $r.sse42)                      { $bl += 'CPU without SSE4.2/POPCNT, Windows 11 24H2+ cannot run on it' }
    if ($cv.InstallationType -ne 'Client')  { $bl += "not a workstation ($($cv.InstallationType))" }
    if ($build -lt 10240)                   { $bl += 'not Windows 10' }
    if ($cv.EditionID -match 'Enterprise') { $bl += "$($cv.EditionID) edition, the official ISO has only Home, Pro and Education" }
    if ($r.freeGB -lt 30 -and -not (Test-Path $iso)) { $bl += "only $($r.freeGB) GB free, need 30" }
    $r.hwFails = $hw; $r.blockers = $bl
    $r.verdict = if ($build -ge 22000) { 'ALREADY_WIN11' } elseif ($bl) { 'BLOCKED' } elseif ($hw) { 'BYPASS' } else { 'READY' }

    Log "OS: $($r.edition) $($r.displayVersion) build $build.$($r.ubr), language $($r.lang)"
    Log "HW: $cpu | TPM $($r.tpm) | firmware $($r.firmware) | SecureBoot $secureBoot | RAM $ramGB GB | disk $($r.diskGB) GB, free $($r.freeGB) GB"
    Log "VERDICT: $($r.verdict) | hardware fails: $($hw -join ', ') | blockers: $($bl -join ', ')"
    $r
}

# Frees space without touching user data: old system temp files, the Windows Update download cache,
# the Delivery Optimization cache and superseded components.
function Invoke-DiskCleanup {
    Log 'Autoheal: freeing disk space (system temp, update caches, component store).'
    Get-ChildItem "$env:windir\Temp" -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-1) |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:windir\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
    Invoke-Tool dism.exe '/Online /Cleanup-Image /StartComponentCleanup /Quiet' 'cleanup: component store'
}

function Invoke-Repair {
    Log 'Autoheal: DISM /RestoreHealth and sfc /scannow.'
    Invoke-Tool dism.exe '/Online /Cleanup-Image /RestoreHealth /Quiet' 'repair: DISM RestoreHealth'
    Invoke-Tool sfc.exe '/scannow' 'repair: sfc'
}

function Restart-Now([string]$why) {
    Wait-Window 'the reboot'
    Log "Rebooting: $why"
    Restart-Computer -Force
    exit 0
}

# Done or given up: remove the task, the ISO and the post-upgrade hook. The log stays.
function Stop-Run([string]$result, [string]$why) {
    $state.phase = $result; Save-State
    Log "$($result.ToUpper()): $why"
    if ($result -eq 'failed') {
        Write-SetupErrors
        Log "Where to look: $logFile, the setup logs in $dir\logs and $bt\Panther (setuperr.log, setupact.log). Fix the cause, then run the command again to start over."
    }
    Remove-Item $iso, "$iso.sha256", "$dir\postoobe" -Recurse -Force -ErrorAction SilentlyContinue
    Complete-Task   # last: removing the task may end this run
    exit $(if ($result -eq 'done') { 0 } else { 1 })
}

# Asks Microsoft for the official ISO link (valid about 24 h) and its published SHA256 for one language name.
function Resolve-Iso([string]$name) {
    $web = New-Object Microsoft.PowerShell.Commands.WebRequestSession   # keeps the cookies between the calls
    function Get-Ms([string]$url, [hashtable]$headers = @{}) {
        Invoke-WebRequest $url -UserAgent $MsAgent -WebSession $web -Headers $headers -TimeoutSec 30 -UseBasicParsing
    }

    $page = (Get-Ms $MsPage).Content
    if ($page -notmatch '<option value="(\d+)">Windows 11 \(multi-edition ISO for x64') { throw 'Edition id not found on the Microsoft download page.' }
    $edition = $Matches[1]
    $sha = $null
    foreach ($m in [regex]::Matches($page, '<td>([^<]+) 64-bit</td><td>([A-F0-9]{64})</td>')) {
        if ($m.Groups[1].Value -in $name, ($name -replace '[()]', '')) { $sha = $m.Groups[2].Value }
    }
    if (-not $sha) { throw "No SHA256 for $name on the Microsoft download page." }

    # The session must be whitelisted before the API answers (see Fido).
    $sid = [guid]::NewGuid().ToString()
    $null = Get-Ms "https://vlscppe.microsoft.com/tags?org_id=$MsOrg&session_id=$sid"
    $js = (Get-Ms "https://ov-df.microsoft.com/mdt.js?instanceId=$MsInst&PageId=si&session_id=$sid").Content
    if ($js -cnotmatch '[?&]w=([A-F0-9]+)') { throw 'ov-df data not found.' }
    $w = $Matches[1]
    if ($js -cnotmatch 'rticks="\+?(\d+)') { throw 'ov-df data not found.' }
    $rt = $Matches[1]
    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $null = Get-Ms "https://ov-df.microsoft.com/?session_id=$sid&CustomerId=$MsInst&PageId=si&w=$w&mdt=$ms&rticks=$rt"

    $q = "profile=$MsProfile&friendlyFileName=undefined&Locale=en-US&sessionID=$sid"
    $skus = ((Get-Ms "${MsApi}getskuinformationbyproductedition?$q&productEditionId=$edition&SKU=undefined").Content | ConvertFrom-Json).Skus
    $sku = @($skus | Where-Object { $_.Language -eq $name })[0]
    if (-not $sku -or "$($sku.Id)" -notmatch '^\d+$') { throw "No SKU for $name." }

    $r = (Get-Ms "${MsApi}GetProductDownloadLinksBySku?$q&productEditionId=undefined&SKU=$($sku.Id)" @{ Referer = 'https://www.microsoft.com/software-download/windows11' }).Content | ConvertFrom-Json
    foreach ($o in $r.ProductDownloadOptions) {
        if (-not $o.Uri) { continue }
        $u = [uri]"$($o.Uri)"
        if ($u.Scheme -ne 'https' -or -not $u.Host.EndsWith('.microsoft.com') -or $u.AbsolutePath -notmatch '/([^/]+_x64[^/]*\.iso)$') { continue }
        return [pscustomobject]@{ url = "$($o.Uri)"; sha256 = $sha; file = $Matches[1] }
    }
    throw "No x64 ISO link in the answer from Microsoft.$(if ($r.Errors) { ' ' + ($r.Errors | ConvertTo-Json -Compress -Depth 3) })"
}

function Get-Iso([string]$lang) {
    # Official Microsoft ISO for the install language of this PC, with Microsoft's published SHA256.
    $name = $IsoLangs[$lang.ToLower()]
    if (-not $name) { $name = $IsoLangs[$lang.ToLower().Split('-')[0]] }
    if (-not $name) { throw "No Windows 11 ISO for language $lang." }   # fatal, see Invoke-Worker

    # A finished, verified ISO from an earlier run needs no new lookup (Microsoft limits repeated lookups).
    $saved = "$(Get-Content "$iso.sha256" -ErrorAction SilentlyContinue)"
    if ($saved -match '^[0-9A-F]{64}$' -and (Test-Path $iso) -and (Get-FileHash $iso -Algorithm SHA256).Hash -eq $saved) { Log 'ISO already present, hash OK.'; return }

    $info = Resolve-Iso $name
    Log "ISO: $($info.file) ($name)"
    $u = [uri]$info.url
    Log "ISO source: $($u.Scheme)://$($u.Host)$($u.AbsolutePath)"   # no query string or credentials in the log
    $want = "$($info.sha256)".ToUpper()
    if ($want -notmatch '^[0-9A-F]{64}$') { throw 'No valid SHA256 for the ISO.' }
    # A partial download of another ISO cannot be resumed.
    if ($saved -ne $want) { Remove-Item $iso -Force -ErrorAction SilentlyContinue }
    Set-Content "$iso.sha256" $want

    $t = Get-Date
    $total = 0
    try { $total = [int64](Invoke-WebRequest $info.url -Method Head -TimeoutSec 30 -UseBasicParsing).Headers['Content-Length'] } catch { }
    $start = if (Test-Path $iso) { (Get-Item $iso).Length } else { 0 }
    Log ('Downloading {0:N2} GB{1}.' -f ($total / 1GB), $(if ($start) { ', resuming at {0:N2} GB' -f ($start / 1GB) }))
    $curlErr = Join-Path $dir 'curl-error.txt'
    # curl.exe ships with Windows 10 1803+, resumes partial downloads, verifies the certificate.
    $curlArgs = "--location --fail --silent --show-error --retry 5 --retry-delay 30 --connect-timeout 30 --continue-at - --output `"$iso`" --stderr `"$curlErr`" `"$($info.url)`""
    $curlCode = Wait-WithProgress (Start-Process curl.exe -ArgumentList $curlArgs -WindowStyle Hidden -PassThru) 'download' {
        $have = if (Test-Path $iso) { (Get-Item $iso).Length } else { 0 }
        ', {0:N2} GB{1}' -f ($have / 1GB), $(if ($total) { ' ({0:N1}%)' -f (100 * $have / $total) })
    }
    if (Test-Path $curlErr) { Get-Content $curlErr | ForEach-Object { Log "curl: $_" } }
    if ($curlCode -eq 33 -or $curlCode -eq 36) { Remove-Item $iso -Force -ErrorAction SilentlyContinue }   # resume refused, start over next try
    if ($curlCode -ne 0) { throw "Download failed, curl exit code $curlCode." }
    Log ('Downloaded {0:N2} GB in {1:N0} min.' -f ((Get-Item $iso).Length / 1GB), ((Get-Date) - $t).TotalMinutes)
    if ((Get-FileHash $iso -Algorithm SHA256).Hash -ne $want) { Remove-Item $iso -Force; throw 'SHA256 mismatch, ISO deleted.' }
    Log 'Hash OK.'
}

function Invoke-Setup($ready, [bool]$bypass, [bool]$dynamicUpdate) {
    Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null   # stale mount from a killed run
    $drive = (Mount-DiskImage -ImagePath $iso -PassThru | Get-Volume).DriveLetter
    Log "ISO mounted on ${drive}:"
    try {
        # Stop before setup if the ISO cannot keep apps on this device (wrong language or edition).
        $wim = Get-ChildItem "${drive}:\sources\install.*" | Where-Object Extension -in '.wim', '.esd' | Select-Object -First 1
        $images = Get-WindowsImage -ImagePath $wim.FullName | ForEach-Object { Get-WindowsImage -ImagePath $wim.FullName -Index $_.ImageIndex }
        $images | ForEach-Object { Log "ISO image $($_.ImageIndex): $($_.EditionId) $($_.Version) $($_.Languages -join ',')" }
        if (-not ($images | Where-Object { $_.EditionId -eq $ready.edition -and $_.Languages -like "$($ready.lang)*" })) {
            Log "ISO has no $($ready.edition) image in $($ready.lang), an in-place upgrade would not keep apps."
            return 0xC1900204   # same code setup gives for this, handled as fatal below
        }
        if ($bypass) {
            New-Item 'HKLM:\SYSTEM\Setup\MoSetup' -Force | Out-Null
            Set-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup' -Name AllowUpgradesWithUnsupportedTPMOrCPU -Value 1 -Type DWord
        }
        # Runs after the upgrade, before the first logon, so the task is cleaned up even if it was not migrated.
        New-Item -ItemType Directory -Force "$dir\postoobe" | Out-Null
        Set-Content "$dir\postoobe\SetupComplete.cmd" "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Worker -NoUpdate" -Encoding ASCII

        # Always /auto upgrade: keep apps, files and settings, or fail without changes. Never clean or dataonly.
        $setupArgs = "/auto upgrade /quiet /eula accept /noreboot /compat ignorewarning /showoobe none /copylogs `"$dir\logs`" /postoobe `"$dir\postoobe`""
        $setupArgs += if ($dynamicUpdate) { ' /dynamicupdate enable' } else { ' /dynamicupdate disable' }
        if ($bypass) { $setupArgs = "/product server $setupArgs" }
        Log "Running: setup.exe $setupArgs"
        $t = Get-Date
        $exit = Wait-WithProgress (Start-Process "${drive}:\setup.exe" -ArgumentList $setupArgs -PassThru) 'setup' {
            $vol = Get-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' -ErrorAction SilentlyContinue
            if ($vol.SetupProgress) { ", $($vol.SetupProgress)%" }
        }
        Log ('Setup ran {0:N0} min, exit 0x{1:X8}.' -f ((Get-Date) - $t).TotalMinutes, $exit)
        $exit
    } finally {
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-PendingReboot($ready) {
    if (-not $ready.pendingReboot) { return }
    if ($state.reboots -lt 2) { $state.reboots++; Save-State; Restart-Now 'Windows has a pending reboot, setup needs a clean start.' }
    Log 'Reboot still pending after 2 reboots, continuing anyway.'
}

function Invoke-Worker {
    Wait-Network
    if ($state.phase -in 'done', 'failed') { Complete-Task; exit 0 }   # finished, only the task was left
    $ready = Get-Readiness

    if ($ready.verdict -eq 'ALREADY_WIN11') {
        Stop-Run 'done' "Windows 11 build $($ready.build) is running. Windows.old stays for rollback (10 days)."
    }
    if ($state.phase -eq 'setup-done') {
        # We rebooted into the upgrade and Windows 10 came back: setup rolled back.
        Invoke-SetupDiag
        Log 'Setup rolled back to Windows 10 after the reboot. Files and apps are as before.'
        $blocks = @(Get-CompatBlocks)
        if ($blocks) { Log "Blocking: $($blocks -join '; ')" }
        Write-SetupErrors
        $state.phase = ''; Save-State
        if ($state.attempts -ge $MaxAttempts) { Stop-Run 'failed' "Rolled back $($state.attempts) times, giving up." }
        Invoke-Repair
    }

    if ($ready.freeGB -lt 30 -and -not (Test-Path $iso)) {
        Invoke-DiskCleanup
        $ready = Get-Readiness
    }
    if ($ready.verdict -eq 'BLOCKED') { Stop-Run 'failed' "Blocked: $($ready.blockers -join ', ')" }

    # With a closed window the reboot waits until after the ISO download, so the download starts right away.
    $pendingDone = Test-WindowOpen
    if ($pendingDone) { Invoke-PendingReboot $ready }

    while ($true) {
        try { Get-Iso $ready.lang; break }
        catch {
            if ($_.Exception.Message -like 'No Windows 11 ISO for language*') { Stop-Run 'failed' $_.Exception.Message }
            $state.isoFails++; Save-State
            Log "ISO not ready ($($state.isoFails)/$IsoRetries): $($_.Exception.Message)"
            if ($state.isoFails -ge $IsoRetries) { Stop-Run 'failed' "Could not get the ISO: $($_.Exception.Message)" }
            Start-Sleep -Seconds 1800
        }
    }
    if (-not $pendingDone) { Invoke-PendingReboot $ready }

    while ($true) {
        Wait-Window 'starting setup'
        $state.attempts++; Save-State
        $bypass = $ready.verdict -eq 'BYPASS' -or $state.forceBypass
        Log "Setup attempt $($state.attempts) of $MaxAttempts$(if ($bypass) { ', with the unsupported hardware bypass' })."
        $exit = Invoke-Setup $ready $bypass ($state.attempts -gt 1)
        $code = '0x{0:X8}' -f $exit
        if ($exit -eq 0) {
            Wait-Window 'the reboot'   # before phase is set: a reboot while waiting must not look like a rollback
            $state.phase = 'setup-done'; Save-State
            Restart-Now 'Setup finished, the in-place upgrade completes during this reboot.'
        }

        # Codes from Microsoft Learn: Windows Setup command-line options and upgrade error codes.
        $known = @{
            '0xC1900204' = 'keep apps not possible, ISO language or edition does not match'
            '0xC1900215' = 'no matching image in the ISO'
            '0xC1900208' = 'an app or driver blocks the upgrade'
            '0xC1900200' = 'hardware not eligible, the bypass did not apply'
            '0xC1900202' = 'hardware not eligible, the bypass did not apply'
            '0xC190020E' = 'not enough disk space'
            '0x80070070' = 'not enough disk space'
            '0xC1900107' = 'cleanup of an earlier attempt is pending, needs a reboot'
        }
        $blocks = @(Get-CompatBlocks)
        Invoke-SetupDiag
        Log "Setup failed with $code ($($known[$code]))$(if ($blocks) { '. Blocking: ' + ($blocks -join '; ') }). Windows 10 stays as it was."
        Write-SetupErrors

        if ($code -in '0xC1900204', '0xC1900215') { Stop-Run 'failed' "Setup $code, $($known[$code])." }
        if ($state.attempts -ge $MaxAttempts) { Stop-Run 'failed' "Setup failed $($state.attempts) times, last $code." }
        switch ($code) {
            { $_ -in '0xC1900200', '0xC1900202' } { $state.forceBypass = $true; Save-State }
            { $_ -in '0xC190020E', '0x80070070' } { Invoke-DiskCleanup }
            '0xC1900107' { Restart-Now "Setup $code, cleanup of an earlier attempt needs a reboot." }
            default { Invoke-Repair }   # next run also uses dynamic update for newer compat fixes and drivers
        }
    }
}

# ---- Check only: report readiness, change nothing ----
if ($CheckOnly) {
    $ready = Get-Readiness
    Close-Console $true "Check done: $($ready.verdict). Nothing was changed, you can close this window."
}

# ---- Start: install the latest version and hand over to a background task ----
if (-not $Worker) {
    try { [Console]::ForegroundColor = 'Yellow' } catch { }
    Log 'Preparing the upgrade. Do NOT close this window yet, this takes a minute.'
    try { [Console]::ResetColor() } catch { }
    Log "==== Start on $env:COMPUTERNAME as $([Environment]::UserName), version $version ===="
    if ($Window) { Log "Window $Window (PC time): setup and reboots only start inside it." }
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName $TaskName }
            Close-Console $true "The upgrade is already running in the background. You can close this window. Log: $logFile"
        }
        try {
            Invoke-WebRequest $RawUrl -OutFile "$self.new" -TimeoutSec 60 -UseBasicParsing
            $errs = $null
            [void][Management.Automation.Language.Parser]::ParseFile("$self.new", [ref]$null, [ref]$errs)
            if ($errs) { throw 'downloaded script has errors' }
            Move-Item "$self.new" $self -Force
            Log 'Latest version installed from GitHub.'
        } catch {
            Remove-Item "$self.new" -ErrorAction SilentlyContinue
            if (-not $PSCommandPath) { throw "could not download the script: $($_.Exception.Message)" }
            if ($PSCommandPath -ne $self) { Copy-Item $PSCommandPath $self -Force }
            Log "GitHub not reachable ($($_.Exception.Message)), using this copy."
        }
        $ready = Get-Readiness
        if ($ready.verdict -eq 'ALREADY_WIN11') { Close-Console $true 'Windows 11 is already installed, nothing to do. You can close this window.' }
        if ($ready.verdict -eq 'BLOCKED' -and -not ($ready.blockers.Count -eq 1 -and $ready.blockers[0] -like 'only*free*')) {
            Close-Console $false "FAIL: this PC cannot upgrade: $($ready.blockers -join ', '). Nothing was changed, you can close this window."
        }
        Save-State
        Register-WorkerTask
        Start-ScheduledTask -TaskName $TaskName
        for ($i = 0; $i -lt 30 -and (Get-ScheduledTask -TaskName $TaskName).State -ne 'Running'; $i++) { Start-Sleep -Seconds 1 }
        if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            throw 'the background task did not start'
        }
    } catch {
        Close-Console $false "FAIL: $($_.Exception.Message). Nothing was changed, you can close this window. Log: $logFile"
    }
    Close-Console $true "Started. The upgrade now runs in the background and the PC reboots by itself when needed. You can close this window. Log: $logFile"
}

# ---- Worker (scheduled task) ----
if (-not $NoUpdate) {
    $before = if (Test-Path $self) { (Get-FileHash $self -Algorithm SHA256).Hash } else { '' }
    try {
        Invoke-WebRequest $RawUrl -OutFile "$self.new" -TimeoutSec 60 -UseBasicParsing
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile("$self.new", [ref]$null, [ref]$errs)
        if (-not $errs -and (Get-FileHash "$self.new" -Algorithm SHA256).Hash -ne $before) {
            Move-Item "$self.new" $self -Force
            Log 'Newer version from GitHub, restarting with it.'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self -Worker -NoUpdate
            exit $LASTEXITCODE
        }
    } catch { Log "Self-update skipped: $($_.Exception.Message)" }
    Remove-Item "$self.new" -ErrorAction SilentlyContinue
}

$mutex = New-Object Threading.Mutex($false, 'Global\Win11Upgrade')
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Log 'Another run is busy, exiting.'; exit 0 }

Log "==== Worker on $env:COMPUTERNAME, version $version, run $($state.runId), phase '$($state.phase)', attempts $($state.attempts) ===="
for ($try = 1; ; $try++) {
    try { Invoke-Worker; break }
    catch {
        Log "ERROR: $($_.Exception.Message)"
        Log "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
        Write-SetupErrors
        if ($try -ge 3) { Stop-Run 'failed' "Unexpected error 3 times: $($_.Exception.Message)" }
        Log 'Autoheal: trying again in 10 minutes.'
        Start-Sleep -Seconds 600
    }
}
