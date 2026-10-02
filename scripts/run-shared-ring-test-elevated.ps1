$ErrorActionPreference = 'Continue'
$workspace = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $workspace 'artifacts\shared-ring-test-elevated.log'
$exe = Join-Path $workspace 'build\bin\Release\wslpart-ARM64.exe'
$volume = '\\?\Volume{2a2ea915-6b3d-4f9c-9760-7078235ac4d0}\'

& $exe attach -v $volume --readonly --expected-start-sector 3775834112 `
    --transport shared-ring --shared-ring-test *>&1 |
    Tee-Object -FilePath $logPath
$exitCode = if ($?) { 0 } else { 1 }
('wrapper_exit=' + $exitCode) | Out-File -FilePath $logPath -Append
exit $exitCode
