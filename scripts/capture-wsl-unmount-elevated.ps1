#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$PhysicalDrive = '\\.\PHYSICALDRIVE1'
)
$ErrorActionPreference = 'Continue'
$workspace = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $workspace 'artifacts\wsl-unmount-elevated.log'
& wsl.exe --unmount $PhysicalDrive *>&1 | Tee-Object -FilePath $logPath
$exitCode = $LASTEXITCODE
('exit_code=' + $exitCode) | Tee-Object -FilePath $logPath -Append
exit $exitCode
