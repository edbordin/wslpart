[CmdletBinding()]
param(
    [ValidateRange(1, 4)]
    [int]$SizeGiB = 2,
    [string]$OutputDirectory,
    [string]$FileName = 'm1.rawdisk'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\artifacts\m1'
}
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $OutputDirectory $FileName))
$outputParent = Split-Path -Parent $outputPath
$sizeBytes = [int64]$SizeGiB * 1GB
$blockCount = [int64]$SizeGiB * 2MB

New-Item -ItemType Directory -Force -Path $outputParent | Out-Null

if (Test-Path $outputPath) {
    $existingLength = (Get-Item -LiteralPath $outputPath).Length
    if ($existingLength -ne $sizeBytes) {
        throw "Refusing to resize existing backing file '$outputPath' from $existingLength to $sizeBytes bytes. Remove it intentionally or choose another path."
    }
} else {
    $stream = [System.IO.File]::Open($outputPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.SetLength($sizeBytes)
    } finally {
        $stream.Dispose()
    }
}

Write-Host "Prepared nonzero backing file: $outputPath" -ForegroundColor Green
Write-Host "Size: $sizeBytes bytes ($SizeGiB GiB)"
Write-Host ""
Write-Host "Start the stock WinSpd rawdisk sample with:"
Write-Host ("  rawdisk-ARM64.exe -f `"{0}`" -c {1} -l 512 -W 1 -C 1 -U 0" -f $outputPath, $blockCount)
Write-Host ""
Write-Host "The file is intentionally nonzero so the stock sample does not synthesize a GPT/MBR."
Write-Host "For the first attachment test, keep the sample running and use:"
Write-Host "  Get-Disk"
Write-Host "  wsl.exe --mount \\.\PHYSICALDRIVE<N> --bare"
