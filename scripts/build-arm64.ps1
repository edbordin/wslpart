[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
# Some managed launch environments provide both PATH and Path in the native
# environment block. .NET Framework treats them as duplicate keys when MSBuild
# starts cl.exe, so normalize to one entry before launching the toolchain.
$normalizedPath = $env:Path
[Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
[Environment]::SetEnvironmentVariable('Path', $normalizedPath, 'Process')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devShell = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Launch-VsDevShell.ps1'

if (-not (Test-Path -LiteralPath $devShell)) {
    throw "Visual Studio developer shell not found: $devShell"
}

Push-Location $repoRoot
try {
    & $devShell -Arch arm64 -HostArch amd64

    $projects = @(
        'build\translation_tests.vcxproj',
        'build\wslpart.vcxproj',
        'build\rawread.vcxproj'
    )
    foreach ($project in $projects) {
        & msbuild (Join-Path $repoRoot $project) /m `
            "/p:Configuration=$Configuration" /p:Platform=ARM64 /v:minimal
        if ($LASTEXITCODE -ne 0) {
            throw "MSBuild failed for $project with exit code $LASTEXITCODE"
        }
    }

    & (Join-Path $repoRoot "build\bin\$Configuration\translation-tests-ARM64.exe")
    if ($LASTEXITCODE -ne 0) {
        throw "Translation tests failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
