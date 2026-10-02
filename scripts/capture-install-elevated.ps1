$ErrorActionPreference = 'Continue'
$workspace = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $workspace 'artifacts\install-elevated.log'
$installer = Join-Path $PSScriptRoot 'install-winspd-arm64.ps1'

try {
    & $installer *>&1 | Tee-Object -FilePath $logPath
    $exitCode = if ($?) { 0 } else { 1 }
}
catch {
    $_ | Out-File -FilePath $logPath -Append
    $exitCode = 1
}

('wrapper_exit=' + $exitCode) | Out-File -FilePath $logPath -Append
exit $exitCode
