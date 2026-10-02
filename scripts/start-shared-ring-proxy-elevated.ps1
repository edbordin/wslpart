$workspace = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $workspace 'build\bin\Release\wslpart-ARM64.exe'
$log = Join-Path $workspace 'artifacts\shared-ring-proxy.log'
$err = Join-Path $workspace 'artifacts\shared-ring-proxy.err.log'
$debug = Join-Path $workspace 'artifacts\shared-ring-proxy.debug.log'
$state = Join-Path $workspace 'artifacts\shared-ring-proxy.state.json'
$eventName = 'WslPartSharedRingTestStop'
$volume = '\\?\Volume{2a2ea915-6b3d-4f9c-9760-7078235ac4d0}\'

Remove-Item -LiteralPath $log,$err,$debug,$state -Force -ErrorAction SilentlyContinue
$arguments = @(
    'attach', '-v', $volume, '--readonly',
    '--expected-start-sector', '3775834112',
    '--transport', 'shared-ring',
    '--dispatcher-threads', '2',
    '--debug-log', $debug,
    '--shutdown-event', $eventName
)
$process = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden `
    -RedirectStandardOutput $log -RedirectStandardError $err -PassThru
@{
    Pid = $process.Id
    EventName = $eventName
} | ConvertTo-Json | Set-Content -LiteralPath $state
Write-Output ('proxy_pid=' + $process.Id)
