[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$keyDirectory = Join-Path $workspace '.local-signing'
$pfxPath = Join-Path $keyDirectory 'winspd-shared-ring-test-signing.pfx'

if (-not (Test-Path -LiteralPath $pfxPath -PathType Leaf)) {
    throw "Signing key backup file not found: $pfxPath"
}

$certificate = Import-PfxCertificate `
    -FilePath $pfxPath `
    -CertStoreLocation Cert:\CurrentUser\My `
    -Password (New-Object System.Security.SecureString) `
    -Exportable

if ($null -eq $certificate -or -not $certificate.HasPrivateKey) {
    throw 'Restored certificate does not have an accessible private key.'
}

Write-Host "Restored certificate thumbprint: $($certificate.Thumbprint)"
