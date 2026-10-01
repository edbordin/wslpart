# Windows prerequisites

For the ARM64 source-build path on this laptop, run the following from an
elevated PowerShell. WinSpd uses Visual Studio/MSBuild projects; CMake and WiX
are not required yet.

```powershell
winget source update

$vsOverride = '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --add Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre --add Component.Microsoft.Windows.DriverKit.BuildTools --includeRecommended'
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget `
  --accept-source-agreements --accept-package-agreements `
  --override $vsOverride

winget install --id Microsoft.WindowsSDK.10.0.26100 --exact --source winget `
  --accept-source-agreements --accept-package-agreements

winget install --id Microsoft.WindowsWDK.10.0.26100 --exact --source winget `
  --accept-source-agreements --accept-package-agreements
```

If the WDK files are already installed but MSBuild reports that
`WindowsKernelModeDriver10.0` cannot be found, add the missing Visual Studio
integration component with:

```powershell
$vsPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
$vsSetup = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe'
& $vsSetup modify --installPath $vsPath `
  --add Component.Microsoft.Windows.DriverKit.BuildTools `
  --add Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre `
  --passive --norestart
```

The WDK is needed because the ARM64 Storport driver must be built from source.
The 10.0.26100 WDK is the VS 2022-compatible choice; the newer 10.0.28000
WDK is intended for the newer VS 2026 toolchain.

Do not install the old WinSpd MSI on this ARM64 machine. We will build WinSpd
from source and first add an ARM64 configuration to its existing projects.

After installation, open a new PowerShell and verify the tools:

```powershell
winget list --id Microsoft.VisualStudio.2022.BuildTools --exact
winget list --id Microsoft.WindowsSDK.10.0.26100 --exact
winget list --id Microsoft.WindowsWDK.10.0.26100 --exact
```

The WinSpd source checkout is already present at `third_party\winspd`. A
binary MSI is not sufficient for this ARM64 path because the existing release
does not provide an identified native ARM64 driver.

Optional later dependency: install CMake for the `wslpart` userspace tool if
we choose CMake as its build system:

```powershell
winget install --id Kitware.CMake --exact --source winget `
  --accept-source-agreements --accept-package-agreements
```
