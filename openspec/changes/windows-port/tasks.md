# Tasks — Windows Port

Phases are ordered by dependency. Phase 1 is a pure refactor (macOS must not regress) and merges to `main` before any Windows code. Phases 2–5 are additive. Phase 6 is deferred follow-up work.

## 1. Monorepo restructure (single `main`, platform dirs)

- [x] 1.1 Move the Apple shell into `apple/`: `Sources/` → `apple/Sources/`, `Tests/` → `apple/Tests/`, `Resources/` → `apple/Resources/`, `Package.swift` → `apple/Package.swift` (use `git mv` to preserve history)
- [x] 1.2 Move `scripts/build.sh` → `apple/scripts/build.sh` (or keep a top-level `scripts/` that calls into platform dirs); update all relative paths inside it (`.build/release/...`, `core/target/release/...`, `Resources/...`)
- [x] 1.3 Update `Package.swift` target `path:` values for the new `apple/Sources` / `apple/Tests` locations
- [x] 1.4 Update the dev-fallback core path in `CoreClient.swift` (`core/target/release/pdflocalcert-core`) to the new relative location
- [x] 1.5 Create the `protocol/` directory (placeholder README describing the JSON protocol contract) and a top-level layout note in `README.md` documenting `core/ apple/ windows/ protocol/`
- [x] 1.6 Rebuild the macOS `.app` via `apple/scripts/build.sh`, run it, and run `swift test` — confirm byte-for-byte behavior parity (sign + verify a sample PDF) with pre-move
- [ ] 1.7 Commit the restructure as one mechanical commit on `windows-port`; open PR and merge to `main` (layout only, no behavior change)

## 2. Cross-platform core + protocol conformance

- [x] 2.1 Add the Rust target: `rustup target add x86_64-pc-windows-msvc`; install `cargo-xwin`
- [x] 2.2 Cross-compile the core from macOS: `cargo xwin build --release --target x86_64-pc-windows-msvc`; confirm `pdflocalcert-core.exe` is produced
- [x] 2.3 Audit dependencies for Windows portability (ureq TLS/native-roots, lopdf, flate2) and fix any `cfg`/feature issues; ensure no `unix`-only code paths
- [x] 2.4 Build the core natively inside the Parallels Win11 VM (over the shared dir) and run `ping` to confirm the stdio loop works on Windows
- [x] 2.5 Author `protocol/` golden vectors: `ping`, a `prepare` request → expected `need_signature` response shape, and a `verify` fixture (signed + unsigned sample)
- [x] 2.6 Add a small conformance harness (script or Rust test) that pipes each vector through the core and asserts the response shape
- [x] 2.7 Add `.github/workflows/` CI: build core on `macos-latest` and `windows-latest`, run conformance vectors on both; gate merges on it

## 3. Windows crypto spike (de-risk before UI)

- [x] 3.1 Create a throwaway C# console project that opens `X509Store(StoreName.My, CurrentUser)` and lists certs with private keys (CN, issuer, not-after)
- [x] 3.2 Implement the CNG signing callback: `GetRSAPrivateKey().SignHash(digest, SHA256, Pkcs1)` and `GetECDsaPrivateKey().SignHash(...)`, selected by the core's `sig_alg`
- [x] 3.3 Verify the ECDSA format conversion: CNG returns raw r‖s (P1363); encode to the DER `SEQUENCE` the core's CMS expects, and add a conformance vector covering it
  - Conversion proven in the spike via `DSASignatureFormat.Rfc3279DerSequence` + an independent `VerifyData`-against-public-key self-check (71B DER SEQUENCE verifies). Standalone vector deferred to the Phase 4 Windows signing tests (already listed in `protocol/vectors/README.md` follow-ups) — it's a C#-side concern, the core only ever receives DER.
- [x] 3.4 Implement cert-chain assembly: `X509Chain` plus the normalized-DN manual walk ported from `IdentityStore.buildChainByDN` (leaf-first DER list); test against a reissued-intermediate cert if available
  - Implemented + exercised with self-signed certs (chain length 1). The multi-cert DN-walk path is untested until a real FNMT/UANATACA cert (with reissued intermediates) is available on the host machine.
- [x] 3.5 End-to-end spike: drive the cross-compiled `pdflocalcert-core.exe` from the console app — real `prepare` → CNG sign → `finalize` on a test PDF; open the output in Adobe to confirm a valid signature + full chain
  - Round-trip PASSES for RSA + ECDSA: core verify `crypto=ok` (RSA) / self-verify ok (ECDSA), `digest_match=true`, `covers_whole=true`, `contents_boundary=true`. Adobe visual confirmation is a manual step left to the user (signed PDFs are emitted in the temp work dir).
- [x] 3.6 Spike a B-T sign with a real RFC 3161 TSA URL to confirm timestamping works on Windows

## 4. Windows shell (C#/WinUI 3)

- [x] 4.1 Scaffold the WinUI 3 (Windows App SDK) project under `windows/`; target Windows 10 17763+; set up Fluent theming
- [x] 4.2 Port `CoreClient` to C#: spawn `pdflocalcert-core.exe` via `System.Diagnostics.Process` with redirected stdin/stdout, one request line / one response line, with package + dev-fallback path resolution
- [x] 4.3 Port `CoordinateMapper` math to C# (screen↔PDF user-space, page rotation, DPI); add unit tests mirroring `CoordinateMapperTests`
- [x] 4.4 Build the PDF viewer with `Windows.Data.Pdf` (render pages to bitmaps; scroll; file picker + drag-and-drop open)
- [x] 4.5 Build the signature-placement overlay (draw/move the box; convert to PDF user-space rect; invisible-signature option)
- [x] 4.6 Build the certificate picker backed by the Phase 3 enumeration; mark expired / non-signing identities
- [x] 4.7 Wire the sign flow: `prepare` → CNG sign → `finalize`; success/error surfacing; B-B and B-T (TSA URL) paths
- [x] 4.8 Build the verify view rendering the core's `verify` fields (valid, signer/issuer CN, signing time, has-timestamp, PAdES level, byte-range-covers-whole-file)
- [x] 4.9 Build settings (configurable signed-file suffix) + About/License surface; store the license token via DPAPI (`ProtectedData`, CurrentUser) and settings via `ApplicationData.LocalSettings`; implement free/pro tier gating + paywall surface
- [x] 4.10 Localize UI strings (mirror the en/es resources under `apple/Resources/*.lproj`)

## 5. Packaging, signing, CI for Windows

- [x] 5.1 Add an MSIX packaging project/manifest; bundle `pdflocalcert-core.exe` and the Windows App SDK runtime
- [x] 5.2 Generate a dev/self-signed Authenticode cert; sign the MSIX for local sideload; document the trust-the-cert install step
- [ ] 5.3 Install + smoke-test the MSIX on a clean Windows 10 17763 target (open → sign → verify) without a separate runtime install
- [x] 5.4 Extend CI: on `windows-latest`, build the WinUI shell + MSIX and publish it as a build artifact; keep `macos-latest` building the `.app`
- [x] 5.5 Document the release path for a production Authenticode (OV/EV) cert (parallel to the mac Developer ID/notarization track); Microsoft Store submission left as a later decision

## 6. Deferred follow-ups (not required for v1)

- [ ] 6.1 PKCS#11/CSP support for the physical DNIe smartcard on Windows (separate phase; needs a card + reader test rig)
- [ ] 6.2 Migrate `CoordinateMapper` from per-shell implementations into the Rust core so both shells share one geometry implementation (anti-desync)
- [ ] 6.3 Evaluate moving license-validation logic into the core to unify free/pro gating across platforms
- [ ] 6.4 Re-evaluate `Windows.Data.Pdf` rendering fidelity; switch to PDFium only if preview quality is insufficient

## 7. macOS UI/UX/feature parity (WinUI shell)

Goal: the Windows shell matches the macOS app's features, user flows, and UX —
same sections, same options, same sign/verify/batch processes. Decisions:
**phased, UI-first** delivery; **CommunityToolkit.Mvvm** with one shared
`AppViewModel` mirroring macOS `AppModel` (single source of truth). See
`design-ui-parity.md` for the full gap analysis and control mapping.

### 7.0 Foundation

- [ ] 7.0.1 Add `CommunityToolkit.Mvvm`, `CommunityToolkit.WinUI.Controls.Segmented`, and `CommunityToolkit.WinUI.Controls.SettingsControls` package refs to `PdfLocalCert.App`
- [ ] 7.0.2 Introduce `AppViewModel : ObservableObject` mirroring macOS `AppModel` (document, identities/selectedCert, visibleSignature, appearance, useTimestamp/tsaURL, signAllPages, zoom, status/error, license, batch, verifier collections); migrate `MainWindow` + dialogs to bind to it via `x:Bind`
- [ ] 7.0.3 Port the macOS section navigation: a `Segmented` Sign / Batch / Verify switcher in the title/command bar driving a content host (replaces the Verify-as-dialog model)

### 7.1 Sign tab parity

- [ ] 7.1.1 Empty-state drop zone (dashed target, icon, prompt, Open button) with file drag-drop onto the window; "New" (clear document) command mirroring macOS
- [ ] 7.1.2 Sidebar layout to match macOS: certificate picker + cert detail (issuer, validity, expired in red, non-signing-usage warning), visible-signature toggle + help text, timestamp toggle + TSA URL, inline Sign-and-save button with progress + inline status/error
- [ ] 7.1.3 Default the TSA URL to the qualified ACCV endpoint (`http://tss.accv.es:8318/tsa`) to match macOS (VALIDe-valid B-T), not DigiCert
- [ ] 7.1.4 `signAllPages` toggle (replicate the drawn box on every page) shown when visible signature is on
- [ ] 7.1.5 Zoom controls (1–4×, reset) over the page view, placement stays normalized

### 7.2 Visible-signature appearance editor (text-only first)

- [ ] 7.2.1 `Expander`-based single-open accordions — Content (name, label + custom label, date, reason, location), Style (border, transparent background, wrap text, font-size slider 6–16)
- [ ] 7.2.2 Live appearance preview pane that renders the same layout the core will embed (reuse the shared layout math); update on every option change
- [ ] 7.2.3 Presets bar: save / apply / delete named `AppearanceConfig` (persist via `ApplicationData.LocalSettings`/JSON), mirroring macOS `PresetStore`

### 7.3 Batch tab

- [ ] 7.3.1 Batch view: add/clear files, `ListView` of items with per-file status glyph (pending/signing/done/failed) + message, Sign-all button, summary line, Pro lock
- [ ] 7.3.2 Wire batch signing to the core with default placement per file, `<name><suffix>.pdf` output beside each source, collision-safe naming

### 7.4 Verify tab

- [ ] 7.4.1 Multi-file verify queue (`ListView`): drop/add files, per-file status icon + level badge, expandable rows showing each signature's full detail (valid, signer/issuer CN, level, timestamp)
- [ ] 7.4.2 Toolbar: re-verify all, clear, only-invalid filter, newest-first, progress bar + summary

### 7.5 Preferences parity

- [ ] 7.5.1 Replace the single Settings dialog with a tabbed/Nav Preferences surface: General (theme system/light/dark, language system/es/en, signed-suffix), License (tier/quota, activate/deactivate, buy link), About (icon, version, GitHub, open-source note)
- [ ] 7.5.2 Apply theme + language selection at runtime (`RequestedTheme`, `PrimaryLanguageOverride`); persist via `LocalSettings`

### 7.6 License-gating parity

- [ ] 7.6.1 Match macOS Pro gating: free tier = invisible + default visible only; custom placement / custom appearance / signAllPages / QR / batch require Pro; surface the paywall consistently across Sign and Batch

### 7.7 Full appearance (logo + QR) — protocol/core plumbing

- [ ] 7.7.1 Extend C# `PlacementSpec` (+ the `SigningService` JSON it emits) with `fontSize`, `wrap`, `textX`/`textW`, and an `images[]` of `PlacedImageSpec` (rgba/px/x/y/w/h), matching the fields the shared Rust core already accepts
- [ ] 7.7.2 Port the shared `SignatureComposer` layout (lines, font size, text rect, logo rect, QR rect) so the WinUI preview equals the embedded output exactly (anti-desync with macOS)
- [ ] 7.7.3 Image section in the appearance editor: import a handwritten/logo PNG (preview + remove) and a verification-QR toggle; rasterize + send as `PlacedImageSpec`
- [ ] 7.7.4 End-to-end: sign with logo + QR on Windows, open in Adobe, confirm valid signature and that on-screen preview matches the embedded appearance
