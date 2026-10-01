$ErrorActionPreference = 'Continue'
$workspace = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $workspace 'artifacts\stop-shared-ring-elevated.log'
$script = Join-Path $PSScriptRoot 'stop-shared-ring-proxy-elevated.ps1'
try {
    & $script *>&1 | Tee-Object -FilePath $logPath
    $exitCode = if ($?) { 0 } else { 1 }
}
catch {
    $_ | Out-File -FilePath $logPath -Append
    $exitCode = 1
}
('wrapper_exit=' + $exitCode) | Out-File -FilePath $logPath -Append
exit $exitCode
