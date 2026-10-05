[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$keyDirectory = Join-Path $workspace '.local-signing'
$certificatePath = Join-Path $keyDirectory 'winspd-shared-ring-test-signing.cer'
$pfxPath = Join-Path $keyDirectory 'winspd-shared-ring-test-signing.pfx'
$subject = 'CN=WinSpd Shared Ring Test Signing'

New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null

$acl = Get-Acl -LiteralPath $keyDirectory
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) {
    [void]$acl.RemoveAccessRuleSpecific($rule)
}

$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($account in @($identity, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $account,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $keyDirectory -AclObject $acl

$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($null -eq $certificate) {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -FriendlyName 'WinSpd Shared Ring local test signer' `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(5)
}

if (-not $certificate.HasPrivateKey) {
    throw 'The selected signing certificate has no private key.'
}

Export-Certificate -Cert $certificate -FilePath $certificatePath -Type CERT -Force | Out-Null

if (-not (Test-Path -LiteralPath $pfxPath)) {
    $emptyPassword = New-Object System.Security.SecureString
    Export-PfxCertificate `
        -Cert $certificate `
        -FilePath $pfxPath `
        -Password $emptyPassword `
        -ChainOption EndEntityCertOnly | Out-Null
}

$pfxData = Get-PfxData -FilePath $pfxPath -Password (New-Object System.Security.SecureString)
$pfxCertificate = $pfxData.EndEntityCertificates |
    Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } |
    Select-Object -First 1

if ($null -eq $pfxCertificate) {
    throw 'The PFX backup does not contain the selected signing certificate.'
}

Write-Host "Signing certificate: $($certificate.Subject)"
Write-Host "Thumbprint: $($certificate.Thumbprint)"
Write-Host "Public certificate: $certificatePath"
Write-Host "Private-key backup: $pfxPath"
