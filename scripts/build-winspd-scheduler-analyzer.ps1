param([string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/trace-tools'))
$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -property installationPath
if (-not $installation) { throw 'Visual Studio Build Tools were not found.' }
$private = Join-Path $installation 'Common7/IDE/PrivateAssemblies'
$msbuild = Join-Path $installation 'MSBuild/Current/Bin'
$null = New-Item -ItemType Directory -Force $OutputDirectory
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
foreach ($file in @('Microsoft.Diagnostics.Tracing.TraceEvent.dll','Microsoft.Diagnostics.FastSerialization.dll','Dia2Lib.dll','TraceReloggerLib.dll')) {
    Copy-Item -LiteralPath (Join-Path $private $file) -Destination $output
}
$bindings = foreach ($file in @('System.Reflection.Metadata','System.Collections.Immutable','System.Memory','System.Runtime.CompilerServices.Unsafe')) {
    $source = Join-Path $msbuild ($file+'.dll')
    Copy-Item -LiteralPath $source -Destination $output
    $assembly = [Reflection.AssemblyName]::GetAssemblyName($source)
    $token = -join ($assembly.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') })
    '<dependentAssembly><assemblyIdentity name="'+$file+'" publicKeyToken="'+$token+'" culture="neutral"/><bindingRedirect oldVersion="0.0.0.0-'+$assembly.Version+'" newVersion="'+$assembly.Version+'"/></dependentAssembly>'
}
$null = New-Item -ItemType Directory -Force (Join-Path $output 'amd64')
Copy-Item -LiteralPath (Join-Path $private 'amd64/msdia140.dll') -Destination (Join-Path $output 'amd64')
$exe = Join-Path $output 'SchedulerSummary.exe'
'<configuration><runtime><assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">'+($bindings -join '')+'</assemblyBinding></runtime></configuration>' | Set-Content -LiteralPath ($exe+'.config')
$facade = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/netstandard.dll'
& (Join-Path $msbuild 'Roslyn/csc.exe') /nologo /target:exe /platform:x64 "/out:$exe" /r:System.Web.Extensions.dll /r:System.Net.Http.dll "/r:$facade" "/r:$output/Microsoft.Diagnostics.Tracing.TraceEvent.dll" "/r:$output/Microsoft.Diagnostics.FastSerialization.dll" (Join-Path $PSScriptRoot 'Summarize-WinSpdScheduler.cs')
if ($LASTEXITCODE -ne 0) { throw 'Scheduler analyzer compilation failed.' }
Write-Output $exe
