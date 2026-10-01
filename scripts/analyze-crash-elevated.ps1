$ErrorActionPreference = 'Continue'
$workspace = Split-Path -Parent $PSScriptRoot
$cdb = 'C:\Program Files\WindowsApps\Microsoft.WinDbg_1.2606.22001.0_arm64__8wekyb3d8bbwe\arm64\cdb.exe'
$dump = 'C:\Windows\Minidump\093026-17062-01.dmp'
$symbols = Join-Path $workspace 'artifacts\symbols'
$log = Join-Path $workspace 'artifacts\cdb-crash-analysis.txt'
$driverSymbols = Join-Path $workspace 'third_party\winspd\build\VStudio\build\Release'
New-Item -ItemType Directory -Path $symbols -Force | Out-Null
& $cdb -z $dump -y "$driverSymbols;srv*$symbols*https://msdl.microsoft.com/download/symbols" `
    -logo $log -c '!analyze -v; lmvm winspd_arm64; .trap fffff605`7a8a0f30; r; !pte ffff9704`facf2000; !address ffff9704`facf2000; ub @pc; u @pc L32; kv; q'
exit $LASTEXITCODE
