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

Three projects, tied together by `PdfLocalCert.sln`:

| Project | What |
|---|---|
| `PdfLocalCert.Core` | UI-free shared logic (CoreClient, CoordinateMapper, signing services). net8.0, unit-tested on any host. |
| `PdfLocalCert.App` | WinUI 3 desktop shell. Ships as `PdfLocalCert.exe`. |
| `PdfLocalCert.Core.Tests` | Unit tests for Core. Run on any host. |

Unit tests run anywhere:

```powershell
dotnet test windows\PdfLocalCert.Core.Tests
```

The app runs via the **MSIX package** — the supported dev *and* ship path. We do **not**
use a loose unpackaged `.exe`: on the ARM test box (x64 under emulation) it crashes at
startup activating the Windows App Runtime DDLM (`0xc000027b` in `combase.dll`) unless
the x64 DDLM is provisioned, and a self-contained build can't even be produced from the
`\\Mac\Home` share because `mt.exe` rejects UNC paths (`c1010070`). A packaged app gets
its runtime from the MSIX dependency graph, sidestepping both. Build → pack → install:

```powershell
# 1. publish the payload — MUST be WindowsPackageType=MSIX (a None-typed payload
#    silently exits inside a package; see scripts\pack-msix.ps1 header)
dotnet publish windows\PdfLocalCert.App -c Release -r win-x64 `
  --self-contained true -p:WindowsPackageType=MSIX -o <payload>

# 2. pack + dev self-sign  ->  windows\build\PdfLocalCert.msix
& windows\scripts\pack-msix.ps1 -PublishDir <payload>

# 3. install (elevated; one-time cert trust) then launch from the Start menu
& windows\scripts\install-msix.ps1
```

> Build over SSH from the `\\Mac\Home` share via a `subst` drive letter — many SDK tools
> (`mt.exe`) choke on UNC working dirs. See `AGENTS.md`.

## Phase 3 crypto spike — findings (validated on Win11 VM)

A throwaway spike (removed after its logic was promoted into `PdfLocalCert.Core`; see
git history `a99dc4a`) drove a real `prepare → CNG sign → finalize → verify` round-trip
against the cross-compiled core. All paths passed: RSA and ECDSA signing, leaf-first
chain assembly, and a B-T timestamp from a live RFC 3161 TSA (DigiCert). These findings
are baked into the `CoreClient` / signer and kept here as rationale:

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

Environment notes: the VM is Windows 11 **ARM64**; the app + core both run as **x64**
under emulation (the shipping target).
