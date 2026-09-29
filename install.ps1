# Loader for: irm <short url> | iex
# Saves the upgrade script and runs it as its own process, so its exit does not close this window.
# Workstations only: on a server or domain controller it stops before writing anything.
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -ErrorAction SilentlyContinue).ProductType -ne 'WinNT') {
    Write-Host 'REFUSED: this is not a Windows workstation. Nothing was changed, you can close this window.' -ForegroundColor Red
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $f = Join-Path $env:SystemDrive 'Win11Upgrade\Win11-Upgrade.ps1'
    New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
    Invoke-RestMethod 'https://raw.githubusercontent.com/Monstertov/windows-inplace-upgrade/main/Win11-Upgrade.ps1' -OutFile $f -UseBasicParsing
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f @args
}
