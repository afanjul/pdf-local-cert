<#
.SYNOPSIS
  Phase 5.3: trust + install the signed MSIX on a target machine, for the
  open -> sign -> verify smoke test.

.DESCRIPTION
  Imports the dev public certificate into LocalMachine\TrustedPeople (so App
  Installer accepts the self-signed package), installs the MSIX, and prints the
  installed package identity. MUST be run elevated (the TrustedPeople store and
  Add-AppxPackage trust require admin).

  For a production Authenticode (OV/EV) build the cert-import step is unnecessary
  (the chain is publicly trusted) -- see windows/RELEASE.md.

.PARAMETER Msix
  Path to the signed .msix (default: ..\build\PdfLocalCert.msix, i.e. windows\build).

.PARAMETER Cer
  Path to the exported public cert (default: same basename as the MSIX, .cer).

.EXAMPLE
  # Run in an elevated PowerShell:
  pwsh windows/scripts/install-msix.ps1 -Msix C:\plc\PdfLocalCert.msix
#>
param(
    [string] $Msix = "$PSScriptRoot\..\build\PdfLocalCert.msix",
    [string] $Cer
)

$ErrorActionPreference = "Stop"

if (-not $Cer) { $Cer = [System.IO.Path]::ChangeExtension($Msix, ".cer") }

# --- elevation check --------------------------------------------------------
$admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    throw "Run this in an ELEVATED PowerShell (Run as administrator) -- trusting the cert needs admin."
}

if (-not (Test-Path $Msix)) { throw "MSIX not found: $Msix (run pack-msix.ps1 first)" }
if (-not (Test-Path $Cer))  { throw "Public cert not found: $Cer" }

# --- trust the dev cert -----------------------------------------------------
Write-Host "Importing $Cer into LocalMachine\TrustedPeople ..."
Import-Certificate -FilePath $Cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null

# --- install (reinstall-safe) -----------------------------------------------
$pkgName = "Palbin.PDFLocalCert"
$existing = Get-AppxPackage -Name $pkgName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing install ($($existing.Version)) ..."
    Remove-AppxPackage -Package $existing.PackageFullName
}

Write-Host "Installing $Msix ..."
Add-AppxPackage -Path $Msix

$pkg = Get-AppxPackage -Name $pkgName
Write-Host ""
Write-Host "Installed:"
Write-Host "  $($pkg.PackageFullName)"
Write-Host "  Architecture: $($pkg.Architecture)"
Write-Host ""
Write-Host "Launch from the Start menu (PDF Local Cert), then smoke-test:"
Write-Host "  1. Open a PDF      2. Sign (pick a cert)      3. Verify"
Write-Host ""
Write-Host "To uninstall:"
Write-Host "  Get-AppxPackage -Name $pkgName | Remove-AppxPackage"
