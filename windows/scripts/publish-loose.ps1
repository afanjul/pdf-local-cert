<#
.SYNOPSIS
  Dev loop: publish the WinUI app as a loose, runnable .exe (no MSIX pack/install).

.DESCRIPTION
  Publishes self-contained with WindowsPackageType=None -- the loose/dev layout whose
  WinAppSDK bootstrapper locates the runtime at launch, so the .exe runs directly from
  the publish folder with no install. This is the fast inner loop for iterating on app
  behaviour (e.g. the signature placement work): edit -> publish -> run the .exe.

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
    "-p:WindowsPackageType=None"
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
