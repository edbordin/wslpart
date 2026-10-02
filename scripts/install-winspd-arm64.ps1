#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$DeviceInstanceId = 'ROOT\SCSIADAPTER\0000'
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$packageDirectory = Join-Path $workspace 'third_party\winspd\build\VStudio\build\Release'
$infPath = Join-Path $packageDirectory 'winspd-ARM64.inf'
$builtSysPath = Join-Path $packageDirectory 'winspd-ARM64.sys'
$catalogPath = Join-Path $packageDirectory 'winspd-arm64.cat'
$installedSysPath = Join-Path $env:SystemRoot 'System32\drivers\winspd-arm64.sys'
$restartRequired = $false

foreach ($path in @($infPath, $builtSysPath, $catalogPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required build artifact was not found: $path"
    }
}

Write-Host "Installing $infPath..."
& pnputil.exe /add-driver $infPath /install | Out-Host
if ($LASTEXITCODE -eq 3010) {
    $restartRequired = $true
}
elseif ($LASTEXITCODE -ne 0) {
    throw "pnputil driver installation failed with exit code $LASTEXITCODE."
}

$device = Get-PnpDevice -InstanceId $DeviceInstanceId -ErrorAction Stop
if ($device.Status -ne 'OK') {
    throw "WinSpd adapter is not healthy after package installation: $($device.Status)."
}
$service = Get-Service -Name WinSpd
if ($service.Status -ne 'Running') {
    Write-Host "Starting WinSpd..."
    Start-Service -Name WinSpd
    (Get-Service -Name WinSpd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
}

$builtHash = (Get-FileHash -LiteralPath $builtSysPath -Algorithm SHA256).Hash
$installedHash = (Get-FileHash -LiteralPath $installedSysPath -Algorithm SHA256).Hash

Write-Host "Built SYS SHA256:  $builtHash"
Write-Host "Installed SYS SHA256: $installedHash"

if ($builtHash -ne $installedHash) {
    throw "The installed SYS does not match the rebuilt artifact."
}

if ($restartRequired) {
    Write-Host 'Windows requires a restart to finish activating the new driver package.'
}
else {
    Write-Host 'WinSpd ARM64 driver package installed and adapter is running.'
}
