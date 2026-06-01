<#
.SYNOPSIS
  Dev loop: publish the WinUI app as a loose, runnable .exe (no MSIX pack/install).

.DESCRIPTION
  Publishes a loose, install-free .exe for the fast inner loop (edit -> publish -> run):
    WindowsPackageType=None          unpackaged desktop app
    WindowsAppSDKSelfContained=true  bundle the WinAppSDK runtime INTO the publish
                                     folder

  WindowsAppSDKSelfContained=true is load-bearing. Without it the unpackaged app is
  framework-dependent and runs the WinAppSDK DeploymentManager auto-initializer at
  startup, which WinRT-activates a class that is not registered for an unpackaged
  process here (x64-on-ARM emulation, no registered DDLM) and crashes before any
  window with:
    TypeInitializationException -> COMException 0x80040154 REGDB_E_CLASSNOTREG
    at WindowsAppRuntime.DeploymentManagerCS.AutoInitialize
  Self-contained removes the auto-initializer entirely (the runtime ships in-folder),
  so the .exe launches with no installed runtime and no deployment step.

  NOTE the asymmetry with pack-msix.ps1: a loose payload uses WindowsPackageType=None,
  but an MSIX payload MUST use WindowsPackageType=MSIX (a packaged app gets its runtime
  from the dependency graph; the bootstrapper path makes it SILENTLY EXIT inside a
  package). Never feed this loose output to makeappx -- repack from an MSIX-typed
  publish instead. See pack-msix.ps1.

.PARAMETER OutDir
  Publish output directory. Defaults to the standard bin/Release RID path.

.PARAMETER Rid
  Runtime identifier. win-x64 (default) or win-arm64.

.PARAMETER Run
  Launch the published .exe after publishing.

.EXAMPLE
  pwsh windows/scripts/publish-loose.ps1 -Run
#>
param(
    [string] $Rid = "win-x64",
    [string] $OutDir,
    [switch] $Run
)

$ErrorActionPreference = "Stop"

$proj = Join-Path $PSScriptRoot "..\PdfLocalCert.App"

$publishArgs = @(
    "publish", $proj,
    "-c", "Release",
    "-r", $Rid,
    "--self-contained", "true",
    "-p:WindowsPackageType=None",
    "-p:WindowsAppSDKSelfContained=true"
)
if ($OutDir) { $publishArgs += @("-o", $OutDir) }

& dotnet @publishArgs
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

# resolve where the .exe landed
if ($OutDir) {
    $exe = Join-Path $OutDir "PdfLocalCert.App.exe"
} else {
    $exe = Get-ChildItem (Join-Path $proj "bin\Release") -Recurse -Filter "PdfLocalCert.App.exe" |
        Where-Object { $_.FullName -match "\\$Rid\\" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object FullName
}

Write-Host ""
Write-Host "DONE."
Write-Host "  EXE: $exe"

if ($Run) {
    if (-not (Test-Path $exe)) { throw "published exe not found: $exe" }
    Write-Host "launching..."
    & $exe
}
