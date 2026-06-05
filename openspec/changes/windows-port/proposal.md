## Why

PDF Local Cert is today a macOS-only app that signs PDFs (PAdES B-T) with X.509 certificates from the system Keychain (FNMT, DNIe, eIDAS). The Spanish/EU market for these certificates is overwhelmingly on Windows, so the addressable user base is far larger there. The app's architecture — a thin native UI shell over a shared Rust core that talks a language-agnostic JSON protocol, with the private key never leaving the system crypto store (external-signer pattern) — makes a native Windows port cheap: only the UI and the one small system-crypto touchpoint are platform-specific. This change ports the app to Windows 10+ as a second native shell while keeping a single repository and a single shared core.

## What Changes

- Restructure the repo into a cross-platform monorepo: shared `core/` (Rust) + `apple/` (existing SwiftUI shell, moved) + `windows/` (new C#/WinUI 3 shell) + `protocol/` (shared JSON schema and conformance test vectors). **BREAKING** to local paths/build scripts, not to end users.
- Add a native **Windows shell** in C# + WinUI 3 (Fluent Design): open/view PDF, place visible signatures, pick a certificate, sign (B-B / B-T with TSA), and verify — feature-parity with the macOS UI.
- Add **Windows system-crypto** support: enumerate signing identities from the Windows certificate store and sign the core-provided `SignedAttributes` digest via CNG (`RSACng`/`ECDsaCng`), the external-signer analog of `SecKeyCreateSignature`. Key never leaves the store. (Physical DNIe smartcard via PKCS#11/CSP is explicitly deferred to a later phase.)
- Make the **Rust core cross-platform**: build the sidecar as `pdflocalcert-core.exe` for `x86_64-pc-windows-msvc` (cross-compiled from macOS via cargo-xwin and built natively in CI), with the JSON stdin/stdout protocol unchanged. The Windows shell spawns it via `System.Diagnostics.Process`, exactly as the Swift shell spawns it via `Process()`.
- Add a **protocol conformance** artifact: golden request/response vectors both shells run against the core, so the two shells cannot silently desync.
- Add **Windows packaging + CI**: MSIX package, Authenticode signing, and a GitHub Actions matrix (macos-latest + windows-latest) building both shells and the core from the same commit.
- Use a **single `main` branch** with platform directories side by side (no long-lived per-platform branches); the current `windows-port` branch is the integration branch for the restructure and merges into `main`.

## Capabilities

### New Capabilities
- `cross-platform-core`: The Rust core builds and ships for both macOS and Windows from one source tree, speaking an identical JSON protocol verified by shared conformance vectors.
- `windows-crypto`: Windows certificate-store identity enumeration and CNG-based external signing of the core's `SignedAttributes` digest (RSA PKCS#1 v1.5 SHA-256 and ECDSA P-256 SHA-256), with the private key never leaving the store.
- `windows-shell`: A native Windows 10+ C#/WinUI 3 application providing open/view/place/sign/verify and settings/license flows at parity with the macOS shell, packaged as a signed MSIX.

### Modified Capabilities
<!-- No existing specs in openspec/specs/; the macOS behavior is implemented but never captured as a spec, so there are no requirement deltas to record here. -->

## Impact

- **New code**: `windows/` (C#/WinUI 3 project), `protocol/` (JSON schema + test vectors), `.github/workflows/` (CI matrix), Windows packaging manifest + signing scripts.
- **Moved code**: existing `Sources/`, `Tests/`, `Package.swift`, `Resources/`, `scripts/build.sh` relocate under `apple/`; `CoordinateMapper` logic is a candidate to migrate down into the Rust core over time so both shells share it.
- **Unchanged**: the Rust core's signing/verifying logic and the line-delimited JSON protocol (`prepare`/`finalize`/`verify`/`ping`).
- **Dependencies**: add Rust target `x86_64-pc-windows-msvc` + cargo-xwin (macOS cross-build); add .NET 8 SDK + Windows App SDK / WinUI 3, `Windows.Data.Pdf` (built-in, render-only), and CNG APIs (`System.Security.Cryptography`) on Windows.
- **Crypto touchpoints to re-implement on Windows**: `IdentityStore.swift` → Windows cert-store enumeration; `CallbackSigner`/`SigningCoordinator.swift` → CNG `SignHash`; `LicenseManager.swift` Keychain store → DPAPI/registry-backed token store.
- **Tooling/runtime**: Windows builds run both locally (Parallels Win11 VM over the shared repo dir) and in CI; end users need Windows 10 build 17763+ with the Windows App SDK runtime (bundled by MSIX).
