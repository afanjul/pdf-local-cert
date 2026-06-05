# Windows release & code-signing

This is the Windows analog of the macOS Developer ID / notarization track. It covers
the dev (self-signed sideload) path used in CI today and the production Authenticode
(OV/EV) path required before any public release. Microsoft Store submission is left as
a later decision (see the bottom of this doc).

## Why signing matters here

An unsigned MSIX cannot be installed by end users at all (App Installer refuses it),
and a self-signed one installs only after the user manually trusts the certificate.
A production Authenticode certificate is what removes the SmartScreen "unknown
publisher" warning and lets the package install without a trust dance — exactly the
role Developer ID + notarization plays for the `.app`.

The signing subject (`CN=...`) **must match** the `Publisher` in
`BureaucratPdf.App/Package.appxmanifest`'s `<Identity>` element, or signing fails with
`error 0x8007000B` (the package identity does not match the signing certificate).

Increment the patch component in that same `<Identity Version>` for every packaged
test iteration (for example, `1.0.14.0` → `1.0.15.0`). This keeps App Installer
upgrades deterministic and makes the build visible in the app footer.

## Dev / sideload path (self-signed) — what CI does today

The `windows-app` CI job builds an MSIX and signs it with a throwaway self-signed cert
so the artifact is structurally complete and installable on a machine that trusts the
cert. Reproduce locally on a Windows host:

```powershell
# 1. Create a self-signed code-signing cert whose subject matches the manifest Publisher.
$cert = New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject "CN=Bureaucrat PDF (Dev)" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -KeyUsage DigitalSignature `
  -FriendlyName "Bureaucrat PDF Dev Signing"

# 2. Export it (the .pfx is what signtool consumes; the .cer is what users trust).
$pwd = ConvertTo-SecureString -String "devsign" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath plc-dev.pfx -Password $pwd | Out-Null
Export-Certificate   -Cert $cert -FilePath plc-dev.cer | Out-Null

# 3. Sign the MSIX (signtool ships with the Windows SDK).
signtool sign /fd SHA256 /a /f plc-dev.pfx /p devsign BureaucratPdf.msix
```

### Trust-the-cert install step (document this for testers)

On the target machine, import the public cert into the machine's Trusted People store
**before** double-clicking the MSIX, otherwise App Installer reports the package as
untrusted:

```powershell
# Run elevated. LocalMachine\TrustedPeople is the store App Installer checks.
Import-Certificate -FilePath plc-dev.cer `
  -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

Then install: double-click `BureaucratPdf.msix` (App Installer) or
`Add-AppxPackage .\BureaucratPdf.msix`.

## Production path (Authenticode OV/EV)

1. **Acquire a certificate.** Buy an **OV** (organization-validated) or **EV**
   (extended-validation) code-signing certificate from a public CA (DigiCert, Sectigo,
   GlobalSign, etc.). EV builds SmartScreen reputation immediately and is typically
   issued on a hardware token / HSM (FIPS 140-2); OV is cheaper but accrues SmartScreen
   reputation more slowly. For a signing product like this, EV is the recommended track.
2. **Set the manifest identity to the real publisher.** Update `<Identity Publisher=...>`
   in `Package.appxmanifest` to the certificate's exact subject DN (e.g.
   `CN=Palbin SL, O=Palbin SL, L=..., S=..., C=ES`). The `Name`/`Version` stay as-is.
3. **Sign with the production cert** (token-backed certs are selected by thumbprint, not
   a `.pfx`):
   ```powershell
   signtool sign /fd SHA256 /sha1 <THUMBPRINT> `
     /tr http://timestamp.digicert.com /td SHA256 `
     BureaucratPdf.msix
   ```
   The `/tr` RFC 3161 timestamp is mandatory — without it the signature expires when the
   certificate does (same rule the core enforces for PAdES B-T).
4. **Keep the signing material off the build host.** In CI, EV signing runs through the
   CA's cloud-HSM signer (e.g. DigiCert KeyLocker / Azure Trusted Signing) — never commit
   a `.pfx` or token PIN to the repo or to GitHub secrets in plaintext form.
5. **Verify before publishing:**
   ```powershell
   signtool verify /pa /v BureaucratPdf.msix
   Get-AppxPackageManifest .\BureaucratPdf.msix   # sanity-check identity + dependencies
   ```

## Microsoft Store (deferred)

The Store re-signs submissions with its own certificate, so the `<Identity>` Publisher
must be switched to the Partner Center-assigned value (`CN=<StorePublisherId>`) for a
Store build. v1 ships via signed-MSIX sideload first; revisit Store submission once the
sideload track is stable. Keep the sideload manifest and a Store manifest variant
separate so the identity swap is a build-time choice, not a manual edit.
