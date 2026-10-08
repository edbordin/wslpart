#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$DeviceInstanceId = 'ROOT\SCSIADAPTER\0000',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$packageDirectory = Join-Path $workspace "third_party\winspd\build\VStudio\build\$Configuration"
$infPath = Join-Path $packageDirectory 'winspd-ARM64.inf'
$sysPath = Join-Path $packageDirectory 'winspd-ARM64.sys'
$dllPath = Join-Path $packageDirectory 'winspd-ARM64.dll'
$dllPackagePath = if (Test-Path -LiteralPath $dllPath -PathType Leaf) {
    $dllPath
} else {
    Join-Path $workspace 'third_party\winspd\build\VStudio\build\Release\winspd-ARM64.dll'
}
$catPath = Join-Path $packageDirectory 'winspd-arm64.cat'
$loadedSysPath = Join-Path $env:SystemRoot 'System32\drivers\winspd-arm64.sys'
$creator = Join-Path $PSScriptRoot 'new-winspd-test-signing-cert.ps1'

foreach ($path in @($infPath, $sysPath, $dllPackagePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required ARM64 package file was not found: $path"
    }
}
if ($dllPackagePath -ne $dllPath) {
    Copy-Item -LiteralPath $dllPackagePath -Destination $dllPath -Force
    $dllPackagePath = $dllPath
}

& $creator
$signingSubject = 'CN=WinSpd Shared Ring Test Signing'
$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $signingSubject -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($null -eq $certificate) {
    throw 'The local WinSpd test signing certificate was not created or has no private key.'
}

$thumbprint = $certificate.Thumbprint
$publicCertificatePath = Join-Path $workspace '.local-signing\winspd-shared-ring-test-signing.cer'
if (-not (Test-Path -LiteralPath $publicCertificatePath -PathType Leaf)) {
    throw "Public signing certificate was not exported: $publicCertificatePath"
}

foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPublisher')) {
    $present = Get-ChildItem $store | Where-Object { $_.Thumbprint -eq $thumbprint } | Select-Object -First 1
    if ($null -eq $present) {
        Import-Certificate -FilePath $publicCertificatePath -CertStoreLocation $store | Out-Null
    }
}

$kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$sdkVersion = Get-ChildItem -LiteralPath $kitRoot -Directory |
    Where-Object {
        $hasSignTool = Test-Path -LiteralPath (Join-Path $_.FullName 'x86\signtool.exe')
        $hasInf2Cat = Test-Path -LiteralPath (Join-Path $_.FullName 'x86\Inf2Cat.exe')
        $hasSignTool -and $hasInf2Cat
    } |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $sdkVersion) {
    throw 'Could not locate Windows SDK SignTool and Inf2Cat.'
}

$signtool = Join-Path $sdkVersion.FullName 'x86\signtool.exe'
$inf2cat = Join-Path $sdkVersion.FullName 'x86\Inf2Cat.exe'

Write-Host "Signing driver with $($certificate.Subject), $thumbprint"
& $signtool sign /ph /fd sha256 /sha1 $thumbprint $sysPath
if ($LASTEXITCODE -ne 0) {
    throw "Driver signing failed with exit code $LASTEXITCODE."
}

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('winspd-inf2cat-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    Copy-Item -LiteralPath $infPath, $sysPath, $dllPackagePath -Destination $tempDirectory

    & $inf2cat "/driver:$tempDirectory" /os:10_GE_ARM64,Server2025_ARM64 /uselocaltime
    if ($LASTEXITCODE -ne 0) {
        throw "Inf2Cat failed with exit code $LASTEXITCODE."
    }

    $generatedCatalog = Join-Path $tempDirectory 'winspd-arm64.cat'
    if (-not (Test-Path -LiteralPath $generatedCatalog -PathType Leaf)) {
        throw 'Inf2Cat did not produce winspd-arm64.cat.'
    }
    Copy-Item -LiteralPath $generatedCatalog -Destination $catPath -Force
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}

& $signtool sign /fd sha256 /sha1 $thumbprint $catPath
if ($LASTEXITCODE -ne 0) {
    throw "Catalog signing failed with exit code $LASTEXITCODE."
}

& $signtool verify /pa /c $catPath $sysPath
if ($LASTEXITCODE -ne 0) {
    throw 'Signed driver catalog verification failed.'
}

Write-Host "Adding and installing $infPath"
$driverVerLine = Select-String -LiteralPath $infPath -Pattern '^\s*DriverVer\s*=' |
    Select-Object -First 1
if ($null -eq $driverVerLine) {
    throw 'The INF has no DriverVer entry.'
}
$driverVersion = ($driverVerLine.Line -split ',', 2)[1].Trim()
$driverVersionPattern = 'Driver Version:.*' + [regex]::Escape($driverVersion)

$driverStoreOutput = @(& pnputil.exe /enum-drivers /class SCSIAdapter 2>&1)
$driverStoreBlocks = ($driverStoreOutput -join "`n") -split '(?=Published Name:)'
$deviceSelection = @(& pnputil.exe /enum-devices /instanceid $DeviceInstanceId /drivers 2>&1)
$activeInfLine = $deviceSelection | Where-Object { $_ -match '^\s*Driver Name:' } | Select-Object -First 1

foreach ($block in $driverStoreBlocks) {
    if ($block -notmatch 'Original Name:\s+winspd-arm64\.inf' -or
        $block -notmatch $driverVersionPattern -or
        $block -notmatch 'Signer Name:\s+Unknown') {
        continue
    }

    if ($block -notmatch 'Published Name:\s+(\S+)') {
        continue
    }

    $stalePublishedName = $Matches[1]
    if ($activeInfLine -match [regex]::Escape($stalePublishedName)) {
        throw "Refusing to remove active package $stalePublishedName."
    }

    Write-Host "Removing stale unsigned copy $stalePublishedName before restaging the signed package."
    $deleteOutput = @(& pnputil.exe /delete-driver $stalePublishedName 2>&1)
    $deleteExitCode = $LASTEXITCODE
    $deleteOutput | ForEach-Object { Write-Host $_ }
    if ($deleteExitCode -notin @(0, 3010)) {
        throw "Could not remove stale package $stalePublishedName (exit $deleteExitCode)."
    }
}

$pnputilOutput = @(& pnputil.exe /add-driver $infPath /install 2>&1)
$pnputilExitCode = $LASTEXITCODE
$pnputilOutput | ForEach-Object { Write-Host $_ }
if ($pnputilExitCode -notin @(0, 259, 3010)) {
    throw "PnPUtil failed with exit code $pnputilExitCode."
}

$restartOutput = @(& pnputil.exe /restart-device $DeviceInstanceId 2>&1)
$restartExitCode = $LASTEXITCODE
$restartOutput | ForEach-Object { Write-Host $_ }
if ($restartExitCode -notin @(0, 3010)) {
    throw "PnPUtil could not restart device $DeviceInstanceId (exit $restartExitCode)."
}

$device = Get-PnpDevice -InstanceId $DeviceInstanceId -ErrorAction Stop
$selection = @(& pnputil.exe /enum-devices /instanceid $DeviceInstanceId /drivers 2>&1)
$selectedInfLine = $selection | Where-Object { $_ -match '^\s*Driver Name:' } | Select-Object -First 1
$selectedVersionLine = $selection | Where-Object { $_ -match '^\s*Driver Version:' } | Select-Object -First 1
$activeHash = (Get-FileHash -LiteralPath $loadedSysPath -Algorithm SHA256).Hash
$builtHash = (Get-FileHash -LiteralPath $sysPath -Algorithm SHA256).Hash

Write-Host "Adapter status: $($device.Status)"
Write-Host "Selected package: $selectedInfLine"
Write-Host "Selected version: $selectedVersionLine"
Write-Host "Built SYS SHA256: $builtHash"
Write-Host "Loaded SYS SHA256: $activeHash"

if ($activeHash -eq $builtHash -and
    $selectedVersionLine -match $driverVersionPattern) {
    Write-Host "The SharedRing V4 $Configuration driver is active and matches the signed build."
}
elseif ($pnputilExitCode -eq 3010 -or ($pnputilOutput -join "`n") -match 'reboot|restart') {
    Write-Host 'The signed package is staged; restart Windows to activate it, then re-run the driver/hash check.'
}
else {
    throw 'Windows did not activate the signed V3 package. The active INF/version/hash above do not match the build.'
}
