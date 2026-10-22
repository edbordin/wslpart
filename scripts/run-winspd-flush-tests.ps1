#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$PackageDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $PackageDirectory = Join-Path $workspace "third_party\winspd\build\VStudio\build\$Configuration"
}
$driverDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
$testDirectory = Join-Path $workspace "third_party\winspd\build\VStudio\testing\build\$Configuration"
$builtDriver = Join-Path $driverDirectory 'winspd-ARM64.sys'
$installedDriver = Join-Path $env:SystemRoot 'System32\drivers\winspd-arm64.sys'
$testExecutable = Join-Path $testDirectory 'winspd-tests-x64.exe'
$logDirectory = Join-Path $workspace 'artifacts'
$logPath = Join-Path $logDirectory "winspd-flush-tests-$Configuration.log"

foreach ($requiredFile in @($builtDriver, $installedDriver, $testExecutable,
        (Join-Path $driverDirectory 'winspd-x64.dll'))) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required artifact was not found: $requiredFile"
    }
}

$builtHash = (Get-FileHash -LiteralPath $builtDriver -Algorithm SHA256).Hash
$installedHash = (Get-FileHash -LiteralPath $installedDriver -Algorithm SHA256).Hash
if ($builtHash -ne $installedHash) {
    throw 'Install and activate the rebuilt driver before running the FLUSH regression tests. The installed SYS does not match the build.'
}

# A matching file on disk cannot establish which image is currently loaded.
# Activate the package (including any required reboot) before invoking this script.
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
"Driver SHA256: $builtHash" | Set-Content -LiteralPath $logPath -Encoding UTF8
$previousPath = $env:Path
Push-Location $workspace
try {
    # Load the DLL built alongside these tests rather than an installed older DLL.
    $env:Path = $driverDirectory + ';' + $previousPath
    # Redirect native streams directly: Windows PowerShell otherwise converts
    # routine stderr diagnostics to error records. Keep each stream readable.
    $stdoutPath = Join-Path $logDirectory "winspd-flush-tests-$Configuration.stdout.log"
    $stderrPath = Join-Path $logDirectory "winspd-flush-tests-$Configuration.stderr.log"
    $testProcess = Start-Process -FilePath $testExecutable -NoNewWindow -Wait -PassThru `
        -ArgumentList @('ioctl_ring_zero_count_flush10_test', 'ioctl_ring_zero_count_flush16_test') `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $testExitCode = $testProcess.ExitCode
    foreach ($streamPath in @($stdoutPath, $stderrPath)) {
        Get-Content -LiteralPath $streamPath | Add-Content -LiteralPath $logPath -Encoding UTF8
    }
    "Test exit code: $testExitCode" | Add-Content -LiteralPath $logPath -Encoding UTF8
    if ($testExitCode -ne 0) {
        throw "FLUSH regression tests failed with exit code $testExitCode. See $logPath"
    }
    $testLines = Get-Content -LiteralPath $stdoutPath
    foreach ($testName in @('ioctl_ring_zero_count_flush10_test', 'ioctl_ring_zero_count_flush16_test')) {
        if (-not ($testLines -match ('^' + [regex]::Escape($testName) + '.* OK '))) {
            throw "Expected FLUSH test did not pass or was not selected: $testName. See $logPath"
        }
    }
}
finally {
    $env:Path = $previousPath
    Pop-Location
}
