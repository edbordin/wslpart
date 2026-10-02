[CmdletBinding()]
param(
    [string]$WinSpdRoot = (Join-Path $PSScriptRoot '..\third_party\winspd')
)

$ErrorActionPreference = 'Continue'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

Write-Host "wslpart Milestone 1 prerequisite check" -ForegroundColor Cyan
Write-Host "Repository: $repoRoot"

function Show-CommandStatus([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-Host ("MISSING  {0}" -f $Name) -ForegroundColor Yellow
        return $false
    }

    Write-Host ("FOUND    {0} -> {1}" -f $Name, $command.Source) -ForegroundColor Green
    return $true
}

$requiredCommands = @('git', 'wsl.exe')
$buildCommands = @('cmake', 'msbuild', 'cl')
$allRequiredFound = $true

foreach ($name in $requiredCommands) {
    if (-not (Show-CommandStatus $name)) { $allRequiredFound = $false }
}

Write-Host ""
Write-Host "Build commands (at least MSBuild + cl, or an equivalent Visual Studio environment, are needed):"
foreach ($name in $buildCommands) { [void](Show-CommandStatus $name) }

Write-Host ""
if (Test-Path $WinSpdRoot) {
    Write-Host "FOUND    WinSpd source -> $((Resolve-Path $WinSpdRoot).Path)" -ForegroundColor Green
    $winspdRevision = git -C $WinSpdRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "         revision     -> $winspdRevision" }
} else {
    Write-Host "MISSING  WinSpd source -> $WinSpdRoot" -ForegroundColor Yellow
    $allRequiredFound = $false
}

Write-Host ""
Write-Host "WSL status:"
wsl.exe --status
Write-Host ""
Write-Host "WSL version:"
wsl.exe --version

Write-Host ""
if (-not $allRequiredFound) {
    Write-Host "Required baseline commands are missing; install them before running Milestone 1." -ForegroundColor Yellow
    exit 1
}

Write-Host "Baseline commands and source checkout are present." -ForegroundColor Green
