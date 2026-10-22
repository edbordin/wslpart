[CmdletBinding()]
param(
    [string]$DriverCertificateThumbprint,
    [string]$CatalogCertificateThumbprint,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$PackageDirectory
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $PackageDirectory = Join-Path $workspace "third_party\winspd\build\VStudio\build\$Configuration"
}
$packageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
$infPath = Join-Path $packageDirectory 'winspd-ARM64.inf'
$sysPath = Join-Path $packageDirectory 'winspd-ARM64.sys'
$dllPath = Join-Path $packageDirectory 'winspd-ARM64.dll'
$catPath = Join-Path $packageDirectory 'winspd-arm64.cat'

# A failed build can leave an older SYS beside a newly stamped INF. Reject the
# mixed package before signing; matching installed/built hashes cannot catch it.
$packageInf = Get-Content -LiteralPath $infPath -Raw
$packageVersion = [regex]::Match($packageInf, '(?im)^\s*DriverVer\s*=\s*[^,\r\n]+,\s*(\d+\.\d+\.\d+\.\d+)\s*$')
$binaryInfo = (Get-Item -LiteralPath $sysPath).VersionInfo
$binaryVersion = '{0}.{1}.{2}.{3}' -f $binaryInfo.FileMajorPart, $binaryInfo.FileMinorPart, $binaryInfo.FileBuildPart, $binaryInfo.FilePrivatePart
if (-not $packageVersion.Success -or [version]$packageVersion.Groups[1].Value -ne [version]$binaryVersion) {
    throw "INF/SYS version mismatch: INF=$($packageVersion.Groups[1].Value), SYS=$binaryVersion. Complete the driver build before signing."
}

$DefaultSigningSubject = 'CN=WinSpd Shared Ring Test Signing'
$DefaultSigningCertificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $DefaultSigningSubject -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($DriverCertificateThumbprint)) {
    if ($null -eq $DefaultSigningCertificate) {
        throw "No signing certificate found. Run scripts\new-winspd-test-signing-cert.ps1 first."
    }
    $DriverCertificateThumbprint = $DefaultSigningCertificate.Thumbprint
}

if ([string]::IsNullOrWhiteSpace($CatalogCertificateThumbprint)) {
    if ($null -eq $DefaultSigningCertificate) {
        throw "No signing certificate found. Run scripts\new-winspd-test-signing-cert.ps1 first."
    }
    $CatalogCertificateThumbprint = $DefaultSigningCertificate.Thumbprint
}

foreach ($path in @($infPath, $sysPath, $dllPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required build artifact was not found: $path"
    }
}

$kitRoots = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
) | Where-Object { Test-Path -LiteralPath $_ }

$signtool = $null
$inf2cat = $null
foreach ($root in $kitRoots) {
    $signtool = Get-ChildItem -LiteralPath $root -Directory |
        Sort-Object Name -Descending |
        ForEach-Object {
            $candidate = Join-Path $_.FullName 'x86\signtool.exe'
            if (Test-Path -LiteralPath $candidate) { $candidate }
        } | Select-Object -First 1
    $inf2cat = Get-ChildItem -LiteralPath $root -Directory |
        Sort-Object Name -Descending |
        ForEach-Object {
            $candidate = Join-Path $_.FullName 'x86\Inf2Cat.exe'
            if (Test-Path -LiteralPath $candidate) { $candidate }
        } | Select-Object -First 1
    if ($signtool -and $inf2cat) { break }
}
if (-not $signtool -or -not $inf2cat) {
    throw 'Could not locate the Windows SDK signtool.exe and Inf2Cat.exe.'
}

Write-Host "Signing driver: $sysPath"
& $signtool sign /ph /fd sha256 /sha1 $DriverCertificateThumbprint $sysPath
if ($LASTEXITCODE -ne 0) {
    throw "Driver signing failed with exit code $LASTEXITCODE."
}

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('wslpart-inf2cat-' +
    [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    Copy-Item -LiteralPath $infPath, $sysPath, $dllPath -Destination $tempDirectory

    Write-Host "Generating catalog with $inf2cat"
    & $inf2cat "/driver:$tempDirectory" /os:10_GE_ARM64,Server2025_ARM64 /uselocaltime
    if ($LASTEXITCODE -ne 0) {
        throw "Inf2Cat failed with exit code $LASTEXITCODE."
    }

    $generatedCatalog = Join-Path $tempDirectory 'winspd-arm64.cat'
    if (-not (Test-Path -LiteralPath $generatedCatalog -PathType Leaf)) {
        throw "Inf2Cat did not produce $generatedCatalog."
    }
    Copy-Item -LiteralPath $generatedCatalog -Destination $catPath -Force
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        $taskTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $resolvedTaskTemp = [IO.Path]::GetFullPath($tempDirectory)
        if ((Split-Path -Parent $resolvedTaskTemp) -ne $taskTempRoot -or
            (Split-Path -Leaf $resolvedTaskTemp) -notlike 'wslpart-inf2cat-*') {
            throw "Refusing to remove a signing temporary directory outside its expected root: $resolvedTaskTemp"
        }
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}

Write-Host "Signing catalog: $catPath"
& $signtool sign /fd sha256 /sha1 $CatalogCertificateThumbprint $catPath
if ($LASTEXITCODE -ne 0) {
    throw "Catalog signing failed with exit code $LASTEXITCODE."
}

& $signtool verify /pa /c $catPath $sysPath
if ($LASTEXITCODE -ne 0) {
    throw 'Catalog membership/signature verification failed.'
}

Write-Host ('SYS SHA256: ' + (Get-FileHash -LiteralPath $sysPath -Algorithm SHA256).Hash)
Write-Host ('CAT SHA256: ' + (Get-FileHash -LiteralPath $catPath -Algorithm SHA256).Hash)
Write-Host 'WinSpd ARM64 driver package signed and verified.'
