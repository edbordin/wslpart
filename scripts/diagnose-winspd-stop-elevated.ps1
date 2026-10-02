$log = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\winspd-stop-diagnostic.log'
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
"admin=$(([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))" | Out-File $log
"--- sc queryex ---" | Out-File $log -Append
sc.exe queryex WinSpd | Out-File $log -Append
"--- sc stop ---" | Out-File $log -Append
sc.exe stop WinSpd | Out-File $log -Append
"--- sc queryex after stop ---" | Out-File $log -Append
sc.exe queryex WinSpd | Out-File $log -Append
"--- pnp device ---" | Out-File $log -Append
pnputil.exe /enum-devices /instanceid ROOT\SCSIADAPTER\0000 /drivers | Out-File $log -Append
