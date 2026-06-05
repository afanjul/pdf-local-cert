<#
.SYNOPSIS
  Create a self-signed signing certificate in the current user's personal store so
  the app has an identity to pick when testing the sign flow.

.DESCRIPTION
  This is a TEST signing identity (CurrentUser\My, with a private key), NOT the
  Authenticode cert used to sign the MSIX. Signatures it produces are
  cryptographically valid but won't chain to a trusted root, so Adobe/VALIDe will
  flag the signer as untrusted — expected for local testing.

  No elevation needed: it writes to the per-user store only.

.PARAMETER Name
  Common name for the certificate subject. Default "PLC Test RSA".

.PARAMETER Algorithm
  RSA (default) or ECDSA (P-256).

.PARAMETER Years
  Validity in years from now. Default 3.

.EXAMPLE
  .\make-test-cert.ps1
  .\make-test-cert.ps1 -Name "PLC Test ECDSA" -Algorithm ECDSA
#>
[CmdletBinding()]
param(
    [string]$Name = "PLC Test RSA",
    [ValidateSet("RSA", "ECDSA")] [string]$Algorithm = "RSA",
    [int]$Years = 3
)

$ErrorActionPreference = "Stop"

$common = @{
    Type              = "Custom"
    Subject           = "CN=$Name, O=PDF Local Cert, C=ES"
    KeyUsage          = "DigitalSignature"
    KeyUsageProperty  = "Sign"
    KeyExportPolicy   = "Exportable"
    CertStoreLocation = "Cert:\CurrentUser\My"
    NotAfter          = (Get-Date).AddYears($Years)
}

if ($Algorithm -eq "ECDSA") {
    $cert = New-SelfSignedCertificate @common -KeyAlgorithm ECDSA_nistP256
} else {
    $cert = New-SelfSignedCertificate @common -KeyAlgorithm RSA -KeyLength 2048
}

Write-Host "Created test signing certificate:" -ForegroundColor Green
$cert | Select-Object Subject, NotAfter, HasPrivateKey, Thumbprint | Format-List
Write-Host "Open the app -> certificate picker; '$Name' should be selectable." -ForegroundColor Cyan
Write-Host "To remove later:" -ForegroundColor DarkGray
Write-Host "  Remove-Item Cert:\CurrentUser\My\$($cert.Thumbprint)" -ForegroundColor DarkGray
