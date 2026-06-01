<#
.SYNOPSIS
  Phase 5.2: pack the published WinUI app into a signed MSIX for local sideload.

.DESCRIPTION
  Generates placeholder tile/logo assets if absent, copies the manifest, packs the
  MSIX with makeappx, creates a dev self-signed code-signing cert (subject must match
  the manifest <Identity Publisher>), and signs with signtool. makeappx/signtool come
  from the Microsoft.Windows.SDK.BuildTools NuGet package the app already references,
  so no full Windows SDK install is required.

  Tooling paths and the production Authenticode path are documented in windows/RELEASE.md.

.PARAMETER PublishDir
  The self-contained publish output. IMPORTANT: it MUST be published with
  WindowsPackageType=MSIX, e.g.

    dotnet publish windows/PdfLocalCert.App -c Release -r win-x64 `
      --self-contained true -p:WindowsPackageType=MSIX -o <PublishDir>

  A payload built with WindowsPackageType=None (the loose/dev layout) calls the
  WinAppSDK bootstrapper to find the runtime; inside an MSIX that is wrong (the
  package gets its runtime from the dependency graph) and the app SILENTLY EXITS
  at launch with no crash dialog. Always repackage from an MSIX-typed payload.

.PARAMETER OutFile
  Path of the .msix to produce.

.EXAMPLE
  pwsh windows/scripts/pack-msix.ps1 -PublishDir C:\plc-app -OutFile C:\plc\PdfLocalCert.msix
#>
param(
    [Parameter(Mandatory = $true)] [string] $PublishDir,
    [string] $OutFile = "$PSScriptRoot\..\..\build\PdfLocalCert.msix",
    [string] $CertSubject = "CN=PDF Local Cert (Dev)",
    [string] $PfxPassword = "devsign"
)

$ErrorActionPreference = "Stop"

# --- locate makeappx + signtool in the BuildTools NuGet package -------------
function Find-SdkTool([string] $name) {
    $root = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.windows.sdk.buildtools"
    $tool = Get-ChildItem $root -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\" } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $tool) { throw "$name not found under $root (build the app once to restore BuildTools)" }
    return $tool.FullName
}
$makeappx = Find-SdkTool "makeappx.exe"
$signtool = Find-SdkTool "signtool.exe"
Write-Host "makeappx: $makeappx"
Write-Host "signtool: $signtool"

if (-not (Test-Path $PublishDir)) { throw "PublishDir not found: $PublishDir" }
$manifestSrc = Join-Path $PSScriptRoot "..\PdfLocalCert.App\Package.appxmanifest"
if (-not (Test-Path $manifestSrc)) { throw "manifest not found: $manifestSrc" }

# --- placeholder assets (real icons are a later design task) ----------------
# makeappx requires every image the manifest references to exist. Generate flat
# brand-color PNGs at the required sizes so the package is structurally valid.
function New-PlaceholderPng([string] $path, [int] $w, [int] $h) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(0, 120, 212)) # Windows accent blue
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$imagesDir = Join-Path $PublishDir "Images"
New-Item -ItemType Directory -Force $imagesDir | Out-Null
$assets = @{
    "StoreLogo.png"        = @(50, 50)
    "Square44x44Logo.png"  = @(44, 44)
    "Square71x71Logo.png"  = @(71, 71)
    "SmallTile.png"        = @(71, 71)
    "Square150x150Logo.png" = @(150, 150)
    "Wide310x150Logo.png"  = @(310, 150)
    "LargeTile.png"        = @(310, 310)
    "Square310x310Logo.png" = @(310, 310)
    "SplashScreen.png"     = @(620, 300)
}
foreach ($name in $assets.Keys) {
    $p = Join-Path $imagesDir $name
    if (-not (Test-Path $p)) { New-PlaceholderPng $p $assets[$name][0] $assets[$name][1] }
}
Write-Host "assets: $($assets.Count) placeholder logos in $imagesDir"

# --- manifest at package root -----------------------------------------------
Copy-Item $manifestSrc (Join-Path $PublishDir "AppxManifest.xml") -Force

# --- pack --------------------------------------------------------------------
New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
& $makeappx pack /d $PublishDir /p $OutFile /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed ($LASTEXITCODE)" }
Write-Host "packed: $OutFile"

# --- dev self-signed cert (subject must match manifest Publisher) -----------
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject `
        -CertStoreLocation "Cert:\CurrentUser\My" -KeyUsage DigitalSignature `
        -FriendlyName "PDF Local Cert Dev Signing"
    Write-Host "created dev cert: $($cert.Thumbprint)"
} else {
    Write-Host "reusing dev cert: $($cert.Thumbprint)"
}
$cerPath = [System.IO.Path]::ChangeExtension($OutFile, ".cer")
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

# --- sign --------------------------------------------------------------------
& $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /tr http://timestamp.digicert.com /td SHA256 $OutFile
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed ($LASTEXITCODE)" }

& $signtool verify /pa /v $OutFile
if ($LASTEXITCODE -ne 0) {
    # A dev self-signed cert legitimately fails /pa chain validation until it is
    # imported into LocalMachine\TrustedPeople (the elevated install step below).
    # The signature itself is applied; this is not a packaging failure.
    Write-Warning "signtool verify /pa did not pass -- expected for a self-signed dev cert until trusted (see install step)."
}

Write-Host ""
Write-Host "DONE."
Write-Host "  MSIX:        $OutFile"
Write-Host "  Public cert: $cerPath"
Write-Host ""
Write-Host "To install on a target (one-time trust, run elevated):"
Write-Host "  Import-Certificate -FilePath '$cerPath' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
Write-Host "  Add-AppxPackage '$OutFile'"
