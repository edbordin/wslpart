#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $workspace 'artifacts\winspd-signed-install.log'
$installer = Join-Path $PSScriptRoot 'install-winspd-arm64-with-local-signer.ps1'

Start-Transcript -LiteralPath $logPath -Force | Out-Null
try {
    Write-Output ('Running as: ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    & $installer
    Stop-Transcript | Out-Null
}
catch {
    $_ | Format-List * -Force | Out-String | Write-Output
    Stop-Transcript | Out-Null
    exit 1
}

exit 0
