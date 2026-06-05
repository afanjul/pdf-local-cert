## Context

Bureaucrat PDF is a macOS app with a deliberately portable architecture:

- **Rust core** (`core/`, `bureaucratpdf-core`): does all PDF surgery (incremental update, `/ByteRange`, `/Contents` placeholder), CMS assembly, RFC 3161 timestamping, and verification. It speaks a **line-delimited JSON protocol** on stdin/stdout (`prepare` → `finalize` → `verify` → `ping`). Pure cross-platform Rust crates (lopdf, cms, x509-cert, rsa, sha2, ureq, flate2) — no Apple dependency.
- **SwiftUI shell** (`Sources/BureaucratPdf`): UI + the one platform-specific responsibility — talking to the system crypto store. It spawns the core via `Process()`/`Pipe` (`CoreClient.swift`), enumerates Keychain identities (`IdentityStore.swift`), and signs the core-provided `SignedAttributes` digest with `SecKeyCreateSignature` (`CallbackSigner` in `SigningCoordinator.swift`). The private key never leaves the Keychain — the **external-signer pattern**.
- **Pure-logic kit** (`BureaucratPdfKit`): `CoordinateMapper` geometry, unit-tested in isolation.

The external-signer design means the system-crypto surface is tiny: the core hands back a digest, the shell signs it, the core splices the CMS. Everything platform-specific is the UI plus that one signing callback. This is exactly what makes a second native shell cheap.

Constraints: solo/indie maintainer; one repository; macOS behavior must not regress; a Parallels Win11 VM with a shared repo dir is available for local Windows builds; the EU/Spanish certificate ecosystem is mostly RSA soft-certs in the OS store, with DNIe on physical smartcards.

## Goals / Non-Goals

**Goals:**
- Native Windows 10+ shell (C#/WinUI 3, Fluent) with parity to the macOS UI: open, view, place visible signature(s), pick certificate, sign B-B/B-T, verify, settings/license.
- One shared Rust core compiled for both platforms from one source tree; identical JSON protocol guaranteed by shared conformance vectors.
- Windows system-crypto via CNG external-signer; private key never leaves the store.
- Single `main` branch, platform directories side by side; CI matrix builds both from the same commit.
- Signed MSIX distribution for Windows.

**Non-Goals:**
- Physical DNIe smartcard (PKCS#11/CSP) support in v1 — deferred to a later phase.
- iOS/Android (architecturally impractical — sandboxed Keychain, no fork/exec).
- Rewriting the Rust core's signing logic or changing the JSON protocol shape.
- A shared cross-platform UI framework (we deliberately keep two native UIs).
- Microsoft Store submission in v1 (MSIX sideload + Authenticode first; Store can follow).

## Decisions

### D1 — Monorepo, single `main`, platform directories (not per-platform branches)
Restructure to `core/`, `apple/`, `windows/`, `protocol/`, `scripts/`, `.github/`. Both shells build from the same commit; the shared core lives once. The current `windows-port` branch is the restructure integration branch and merges into `main` when the layout + CI are green.
- **Why over two long-lived branches:** divergent platform branches force core fixes to be cherry-picked both ways — merge hell for a solo dev. A monorepo keeps the core honest (one copy) and the protocol shared. Industry precedent: 1Password/Signal/Dropbox use shared-core + native-UI-per-platform.
- **Alternative considered:** two repos (core as a submodule/release artifact). Rejected — submodule friction and version-skew risk outweigh isolation benefits for a single maintainer.
- **Cost:** a one-time path move for the Apple shell; build scripts and `Package.swift` paths update accordingly.

### D2 — C# + WinUI 3 (Windows App SDK) for the Windows UI
WinUI 3 is the direct analog of SwiftUI: C#≈Swift, XAML≈View DSL, Fluent≈HIG. Targets Windows 10 17763+ and 11 with a modern look.
- **Alternatives:** WPF (older look, viable fallback), WinForms (legacy), Electron/Tauri (non-native, contradicts the project's native ethos), Swift-on-Windows (no production UI framework). Rejected for either dated UX or non-native feel.
- **Risk hedge:** if WinUI 3 tooling proves painful, WPF is a drop-in fallback for the same C# logic and CNG/Process code — only the view layer changes.

### D3 — Keep the sidecar (subprocess + JSON), do NOT switch Windows to in-process FFI
Windows allows `CreateProcess`, so the existing `Process()`+pipe model ports directly to `System.Diagnostics.Process` with redirected stdin/stdout. The same `bureaucratpdf-core.exe` is driven byte-for-byte like the macOS build drives it.
- **Why over FFI/static lib:** the subprocess boundary is the cheapest way to reuse the core unchanged and isolate crashes; FFI would mean a C ABI and per-platform linking with no parity payoff. (FFI was only forced on iOS, which bans fork/exec — not relevant here.)
- **Trade-off:** process spawn per request (already the macOS behavior); negligible for a desktop signing flow.

### D4 — Windows crypto: CNG external-signer in v1, PKCS#11 DNIe deferred
Enumerate identities with `X509Store(StoreName.My, CurrentUser/LocalMachine)`; for the chosen cert get the private key via `GetRSAPrivateKey()`/`GetECDsaPrivateKey()` (CNG-backed) and sign the digest with `SignHash(digest, SHA256, Pkcs1)` / ECDsa `SignHash`. This mirrors `SecKeyCreateSignature` exactly — the core's `sig_alg` field (`rsa-pkcs1-sha256` | `ecdsa-sha256`) selects the path. Build the cert chain with `X509Chain` (plus a normalized-DN manual walk mirroring `IdentityStore.buildChainByDN`, since FNMT/UANATACA intermediates don't always link via the OS trust engine).
- **Why defer PKCS#11:** soft-certs in the CNG store cover FNMT/eIDAS — the bulk of users — with zero hardware test rigs. DNIe needs a physical card and a CSP/PKCS#11 module per reader; isolate it to a later phase so v1 ships.
- **Important:** the core already returns the digest to sign and the algorithm; the Windows side only needs the ~30-line signing callback + enumeration, same as the Swift side.

### D5 — `Windows.Data.Pdf` for rendering (render-only)
Built-in WinRT API (Win10+), renders pages to bitmaps for the viewer and the placement overlay. No third-party native dependency, no licensing. Signing is in the core, so the shell only needs page images + click-to-place geometry.
- **Alternative:** PDFium (NuGet) — richer but adds a native dep and bundle weight; unnecessary for render-only. Kept as a fallback if `Windows.Data.Pdf` fidelity is insufficient.
- **Geometry parity:** reuse `CoordinateMapper`'s math (screen↔PDF user-space, page rotation, DPI). Port it to C# now; longer-term migrate it into the Rust core so both shells share one implementation (anti-desync).

### D6 — Cross-compile the core from macOS + build natively in CI
Local: `cargo-xwin` builds `x86_64-pc-windows-msvc` from the Mac for fast iteration; the WinUI shell builds in the Parallels VM over the shared dir. CI: `windows-latest` builds the core natively + the MSIX, `macos-latest` builds the `.app` — both from the same commit, both run the protocol conformance vectors.
- **Why both VM + CI:** VM gives interactive UI testing and fast loops; CI gates merges and produces reproducible signed artifacts. Cross-compile alone can't run/test the UI; CI alone is too slow to iterate.

### D7 — `protocol/` conformance vectors as anti-desync insurance
A `protocol/` dir holds the JSON request/response schema and golden vectors (e.g. a `ping`, a `prepare` request → expected `need_signature` response shape, a `verify` fixture). Both shells (and the core) assert against them in CI. Prevents the two UIs from drifting apart in how they call the core.

### D8 — License/settings storage per platform
macOS uses a Keychain generic-password (`LicenseManager.swift`). Windows v1 stores the license token via DPAPI (`ProtectedData`, CurrentUser scope) or registry; settings via `ApplicationData`/`LocalSettings`. Behavior (free/pro tiers, sign-count gating) is identical; only the storage backend differs. Pushing license-validation logic into the core later would unify it, but is out of scope here.

## Risks / Trade-offs

- **CNG ↔ SecKey signature-format mismatch (ECDSA)** → SecKey returns ECDSA as a DER-encoded `SEQUENCE`; CNG `ECDsaCng.SignHash` returns raw r‖s (IEEE P1363). The core's CMS assembly expects DER for ECDSA. Mitigation: encode r‖s → DER on the Windows side (or have the core accept both and normalize); cover with a conformance vector. RSA PKCS#1 v1.5 is identical on both, so most certs are unaffected.
- **WinUI 3 deployment/runtime friction** → Windows App SDK runtime dependency, packaging quirks. Mitigation: MSIX bundles the runtime; WPF is the documented fallback (D2).
- **`Windows.Data.Pdf` rendering fidelity vs PDFKit** → minor visual differences in the preview. Mitigation: placement math is authoritative via `CoordinateMapper`, not pixels; PDFium fallback (D5) if needed.
- **Cert-chain building differs from macOS trust engine** → Windows `X509Chain` may also stop at the leaf for reissued FNMT intermediates. Mitigation: port the normalized-DN manual walk from `IdentityStore.buildChainByDN`; embed full chain in CMS so Adobe builds a path (the exact bug that walk fixes on mac).
- **Monorepo restructure breaks paths/scripts** → `Package.swift`, `build.sh`, CI, and the dev fallback path in `CoreClient.swift` (`core/target/release/...`) all reference current locations. Mitigation: do the move as one mechanical commit, update all path references, verify the macOS build is byte-equivalent before adding Windows.
- **Authenticode signing cost/setup** → Windows code-signing cert (OV/EV) needed to avoid SmartScreen warnings. Mitigation: ad-hoc/self-signed for dev + sideload; acquire a signing cert before public release (parallels the mac Developer ID/notarization track).
- **Protocol drift between shells** → two UIs calling the core independently. Mitigation: D7 conformance vectors in CI on both platforms.

## Migration Plan

1. **Restructure** on the `windows-port` branch: move Apple shell into `apple/`, keep `core/`, add `protocol/`; fix all path references; prove the macOS `.app` still builds and runs. Merge to `main` (platform layout only, no behavior change).
2. **Cross-platform core**: add the Windows target + cargo-xwin; produce `bureaucratpdf-core.exe`; add `protocol/` vectors; CI runs them on both OSes.
3. **Windows crypto spike**: standalone C# console that enumerates the cert store, drives the core over stdio for a real `prepare`→CNG-sign→`finalize` on a test PDF — de-risks D4/the ECDSA format issue before any UI.
4. **Windows shell**: build the WinUI 3 app feature-by-feature (open/view → place → pick cert → sign → verify → settings/license).
5. **Package + CI**: MSIX, Authenticode (dev cert), GitHub Actions matrix gating merges.
- **Rollback:** every step is additive after step 1; the macOS app is untouched. If the Windows track stalls, `main` still ships macOS. Worst case the Windows shell is abandoned without affecting the core or Apple build.

## Open Questions

- ECDSA on Windows: normalize r‖s→DER in the shell, or extend the core to accept raw and normalize centrally? (Leaning shell-side to keep the core's contract stable; revisit if a second consumer appears.)
- Should `CoordinateMapper` migrate into the Rust core during this change or after the Windows shell ships? (Plan: port to C# now for speed, schedule the core migration as a follow-up to avoid blocking the port.)
- MSIX sideload vs. Microsoft Store for v1 distribution (Store deferred; confirm before release).
- Minimum Windows build target: 10 17763 (1809) vs a higher floor for newer WinUI/`Windows.Data.Pdf` features?
