# Windows shell (C# / WinUI 3)

Native Windows 10 (17763+) / 11 shell for PDF Local Cert, at feature parity with the
macOS app: open/view a PDF, place visible signatures, pick a certificate from the Windows
certificate store, sign (PAdES B-B / B-T with a TSA), and verify.

It drives the **same** shared Rust core as the Apple shell, spawning `pdflocalcert-core.exe`
via `System.Diagnostics.Process` and talking the line-delimited JSON protocol in
[`../protocol`](../protocol). The private key never leaves the Windows cert store — the
shell only signs the core-provided digest via CNG (external-signer pattern).

See `openspec/changes/windows-port/` for the full design. Scaffolded in Phase 4.

## Build & run (dev)

The app is three projects under `windows/`:

| Project | What |
|---|---|
| `PdfLocalCert.Core` | UI-free shared logic (CoreClient, CoordinateMapper, signing services). net8.0, unit-tested on any host. |
| `PdfLocalCert.App` | WinUI 3 desktop shell. |
| `spike` | Throwaway Phase 3 CLI over the shared services (headless integration test). |

```powershell
# Unit tests (any host):
dotnet test windows\PdfLocalCert.Core.Tests

# Run the app (dev): publish self-contained, drop the core beside it, launch.
dotnet publish windows\PdfLocalCert.App -c Release -r win-x64 --self-contained true -o C:\plc-app
copy core\target\x86_64-pc-windows-msvc\release\pdflocalcert-core.exe C:\plc-app\
# then double-click C:\plc-app\PdfLocalCert.App.exe (launch from the desktop, not SSH)
```

### Runtime prerequisite (one-time, until the MSIX in Phase 5)

The app bundles the **.NET** runtime (self-contained) — no .NET install needed.
It is **framework-dependent on the Windows App SDK**, so the machine needs the
WinAppSDK 1.7 runtime + its **x64 DDLM** provisioned once:

```powershell
# official redist — installs the framework AND the x64 DDLM the unpackaged app needs
windowsappruntimeinstall-x64.exe   # from https://aka.ms/windowsappsdk/1.7/latest/
```

Without the DDLM the app shows "Required components of the Windows App Runtime are
missing" or exits at startup (0xc000027b in combase.dll). The Phase 5 MSIX package
declares this dependency so end users never run the redist manually.

## Phase 3 crypto spike — findings (validated on Win11 VM)

The throwaway spike under [`spike/`](spike) drove a real `prepare → CNG sign →
finalize → verify` round-trip against the cross-compiled core. All paths pass:
RSA and ECDSA signing, leaf-first chain assembly, and a B-T timestamp from a live
RFC 3161 TSA (DigiCert). Carry these into the Phase 4 `CoreClient` / signer:

1. **The protocol `digest` field is the full SignedAttributes DER, not a hash.**
   `core/src/sign.rs` puts the TBS bytes there and the macOS shell signs with
   *message* algorithms (hash-then-sign). On Windows use **`SignData`**, never
   `SignHash` — `SignHash` would treat the ~135 DER bytes as a SHA-256 digest and
   silently emit an invalid signature.

2. **ECDSA must be a DER `SEQUENCE{r,s}`, not raw P1363.** The core's CMS expects
   `ecdsa-with-SHA256` in DER. .NET defaults to raw r‖s, so pass
   `DSASignatureFormat.Rfc3279DerSequence` to `SignData`. (Native in .NET 8 — no
   manual conversion needed, but the format flag is mandatory.)

3. **`finalize` recovers prepare's state via `$PDFLOCALCERT_WORK`.** Each request
   is a fresh process; set that env var to the per-sign work dir on every spawn
   (mirrors the macOS `CoreClient`), or finalize returns `state not found`.

4. **The core's `verify` is RSA-only for the crypto check** (`verify.rs:68` calls
   `rsa_verify` only); ECDSA reports `crypto=structural-only` and is still marked
   `valid`. So "core says valid" is not crypto proof for ECDSA — the spike adds an
   independent `VerifyData`-against-public-key self-check. (Pre-existing core gap,
   not introduced by the port; tracked for a later core fix.)

5. **TLS works on Windows.** The core's `ureq`+rustls+webpki-roots stack reached
   the TSA over HTTPS with no system trust/SChannel dependency — confirms the
   Phase 2 dependency audit end to end.

Environment notes: the VM is Windows 11 **ARM64**; the spike + core both run as
**x64** under emulation (the shipping target). .NET 8 SDK was installed to
`C:\dotnet` (set `DOTNET_ROOT` + PATH); run the spike via `dotnet plc-spike.dll`.
