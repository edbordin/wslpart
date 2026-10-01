#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$PublishedName = 'oem8.inf',
    [string]$DeviceInstanceId = 'ROOT\SCSIADAPTER\0000'
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$packageDirectory = Join-Path $workspace 'third_party\winspd\build\VStudio\build\Release'
$infPath = Join-Path $packageDirectory 'winspd-ARM64.inf'
$builtSysPath = Join-Path $packageDirectory 'winspd-ARM64.sys'
$catalogPath = Join-Path $packageDirectory 'winspd-arm64.cat'
$loadedSysPath = Join-Path $env:SystemRoot 'System32\drivers\winspd-arm64.sys'

foreach ($path in @($infPath, $builtSysPath, $catalogPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required build artifact was not found: $path"
    }
}

Write-Host "Stopping WinSpd..."
$service = Get-Service -Name WinSpd
if ($service.Status -ne 'Stopped') {
    try {
        Stop-Service -Name WinSpd -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }
    catch {
        Write-Host "WinSpd is a PnP Storport driver; service stop was not accepted."
    }
}

if ((Get-Service -Name WinSpd).Status -ne 'Stopped') {
    Write-Host "Disabling PnP device $DeviceInstanceId..."
    & pnputil.exe /disable-device $DeviceInstanceId | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "PnP device disable failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Removing published driver package $PublishedName..."
& pnputil.exe /delete-driver $PublishedName /uninstall /force | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "pnputil driver removal failed with exit code $LASTEXITCODE."
}

Write-Host "Installing $infPath..."
& pnputil.exe /add-driver $infPath /install | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "pnputil driver installation failed with exit code $LASTEXITCODE."
}

Write-Host "Enabling PnP device $DeviceInstanceId..."
& pnputil.exe /enable-device $DeviceInstanceId | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "PnP device enable failed with exit code $LASTEXITCODE."
}

$service = Get-Service -Name WinSpd
if ($service.Status -ne 'Running') {
    Write-Host "Starting WinSpd..."
    Start-Service -Name WinSpd
    (Get-Service -Name WinSpd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
}

$builtHash = (Get-FileHash -LiteralPath $builtSysPath -Algorithm SHA256).Hash
$loadedHash = (Get-FileHash -LiteralPath $loadedSysPath -Algorithm SHA256).Hash

Write-Host "Built SYS SHA256:  $builtHash"
Write-Host "Loaded SYS SHA256: $loadedHash"

if ($builtHash -ne $loadedHash) {
    throw "WinSpd is running, but the loaded SYS does not match the rebuilt artifact."
}

Write-Host 'WinSpd ARM64 driver replacement verified.'
