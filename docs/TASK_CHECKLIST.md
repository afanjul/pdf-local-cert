# Bureaucrat PDF — Per-Phase Task Checklist

> Buildable task breakdown derived from `IMPLEMENTATION_SPEC.md`. Each task: owner-sized, testable. Story-point refs (`S#`) map to PRD §5.2.
>
> **Version:** 1.1 · **Updated:** 2026-05-29

Legend: `[x]` done · `[ ]` todo · `🔴` blocker/gate · `⚠` high-risk · `🔒` security-critical

## Current status (2026-05-29)

**Phase 0 + Phase 1: functionally DONE and verified.** Real qualified cert (UANATACA, FNMT) signs PDFs that **Adobe Acrobat reports as valid** (PAdES B-T, EUTL trust, embedded timestamp). See `docs/PROGRESS.md` for the resume guide.

**Phase 2 (draw signature box): DONE.** `CoordinateMapper` (unit-tested, 10/10) + `SignatureBoxOverlay` + page picker; drawn rect maps to PDF user space and lands exactly on `/Rect`.

**Phase 3 (appearance + presets + paywall): DONE (local).** Swift-rendered appearance (text/image/QR) embedded as Image XObject+SMask; presets in App Support; Keychain license + paywall (Stripe server deferred).

**Phase 4 (batch + QR + multi-box): DONE.** Batch queue (Pro), QR badge (local token), multi-box = one signature with N widgets ("firmar en todas las páginas"). All paths pyHanko ENTIRE_FILE; single/invisible path unchanged. **Deferred (need backend/hardware): Stripe, QR cloud record, DNIe/smartcard, multi-signer sequential, B-LT/LTA, notarization.**

Deviations from the original plan (intentional, for solo speed):
- Build is **SwiftPM executable + assembled `.app`** (`scripts/build.sh`), not an Xcode `.xcodeproj`/workspace.
- Sidecar is **arm64 only** so far (not yet universal2 `lipo`).
- Code signing is **ad-hoc**; not yet Developer-ID signed or notarized.
- Trust roots: rely on the OS/validator's trust (Adobe EUTL). No bundled LOTL/TSL snapshot yet.
- No CI, no TestFlight/beta yet.

---

## Phase 0 — Spike (1–2 wk)

**Exit gate 🔴:** valid PAdES B-T PDF produced via callback signer; `.app` notarizes; Rust-vs-pyHanko decision recorded.

### 0.1 Project skeleton
- [x] SwiftPM executable `BureaucratPdf`, macOS 14, Swift 6 strict concurrency. *(not an .xcodeproj)*
- [x] Bundle ID `dev.warelabs.bureaucratpdf`; display name set. Icon: placeholder/none yet.
- [x] Init Rust crate `bureaucratpdf-core`.
- [ ] universal2 build (`aarch64` + `x86_64` → `lipo`) — **arm64 only so far**.
- [x] Wire core into `.app/Contents/Helpers/` (via `scripts/build.sh`, not an Xcode phase).
- [ ] Git repo, `.gitignore`, CI stub — **not done**.

### 0.2 Callback-signer round-trip 🔒
- [x] `SecItemCopyMatching(kSecClassIdentity)` enumeration (`IdentityStore`).
- [x] `SecKeyCreateSignature` wrapper (`CallbackSigner`) — RSA + ECDSA message algs.
- [x] Core `prepare`: incremental update, `/Contents` placeholder, `/ByteRange`, `SignedAttributes`, return TBS.
- [x] Core `finalize`: inject signature → detached CMS → patch bytes.
- [x] End-to-end: shell signs digest from core, core emits signed PDF. 🔴 ✓

### 0.3 PAdES B-T + TSA
- [x] CMS `SignedData` with ESS `signing-certificate-v2` (hand-rolled DER, `cms.rs`).
- [x] RFC 3161 client (`tsa.rs`): token from DigiCert TSA, embedded as unsigned attr.
- [x] Validate output: **Adobe Acrobat reports valid B-T** + **pyHanko `coverage=ENTIRE_FILE, valid`**. 🔴 ✓ *(EU DSS demo not used)*

### 0.4 Packaging
- [~] Ad-hoc signed + hardened-runtime entitlements file present. **Developer-ID signing not done.**
- [ ] Notarize + staple; Gatekeeper on clean VM — **not done** (waiting on paid Developer ID certs).

### 0.5 Decision
- [x] **Rust PAdES path works** — hand-rolled DER/CMS + lopdf. No pyHanko fallback needed (pyHanko kept only as a verification oracle).

---

## Phase 1 — MVP (4–8 wk)

**Exit gate 🔴:** ≥98% sign success on FNMT soft certs; <1% crash; public beta.

### 1.1 PDF view (S1, 3pt)
- [x] Drag-drop `.pdf` (`DropSupport`, via `fileURL` type id) + file-open panel.
- [x] `PDFViewerView` (PDFKit `NSViewRepresentable`): render, zoom, scroll.
- [~] Page count via PDFKit; explicit bottom page-nav bar not built (PDFKit scroll only).
- [x] Reject encrypted/corrupt PDF → `BAD_PDF` / `PDF_ENCRYPTED`.

### 1.2 Certificate list (S2, 5pt)
- [x] `IdentityStore`: enumerate Keychain identities.
- [x] `CertificateInfo`: CN, issuer, validity, key-usage filter (`digitalSignature`/`nonRepudiation`), + full chain via `SecTrustCopyCertificateChain`. ⚠✓
- [x] Sidebar cert picker; expired greyed; default-select valid signer.

### 1.3 Invisible sign (S3, S7, S8) 🔒
- [x] `SigningCoordinator`: prepare → SecKey sign → finalize.
- [x] `CoreClient`: subprocess + JSON line protocol, file-path state.
- [x] Invisible PAdES B-T. Key never leaves Keychain (callback signer). 🔒✓
- [x] Trusted timestamp embedded (B-T).

### 1.4 Default visible sign (S4, 3pt)
- [x] Core renders default appearance (name/reason/location) bottom-right page 1.
- [x] `/AP` Form XObject appearance stream (`appearance_xobject`).

### 1.5 Save (S5, 2pt)
- [x] `NSSavePanel`; default name `{orig}-firmado.pdf`; original untouched.

### 1.6 Errors (S6, 3pt)
- [x] `SigningError` enum → taxonomy; ES strings (EN partial).
- [x] Surface expired cert, locked key, TSA timeout (B-B fallback), bad/encrypted PDF.
- [x] Core error codes propagate; core stderr logged.

### 1.7 Verifier (S9, 5pt)
- [ ] Bundle eIDAS trust roots (EU LOTL / Spanish TSL) — **not done** (no trust-chain check yet).
- [x] Core `verify`: signer (matched by issuer+serial), issuer, B-B/B-T, digest match, RSA crypto verify, `/Contents` boundary check, covers-whole.
- [x] `VerifierView`: drop zone → green/red card. Cross-checked vs Adobe-signed & broken references.

### 1.8 Quality
- [x] Test cert fixture + pipeline harness (`/tmp/test_pipeline.py`); pyHanko oracle (`/tmp/pyhanko_validate.py`).
- [ ] In-repo automated test/CI, sign-success metrics, crash reporting — **not done**.
- [ ] TestFlight/beta — **not done**.

**Hard-won Adobe PAdES fixes applied this build (see memory `bureaucrat-pdf-build`):**
- [x] `/ByteRange` integers without leading zeros (space-padded region).
- [x] `/ByteRange` gap excludes BOTH `<` `>` of `/Contents` (the `/Contents illegal data` cause).
- [x] `/M` signing time + `/Name` in Sig dict.
- [x] Verifier selects signer cert by issuer+serial (not first cert — was hitting OCSP responder cert).

---

## Phase 2 — Place (3–4 wk)

**Exit gate:** signature lands within ±2pt of drawn rect; mapper tests pass.

### 2.1 Coordinate mapper ⚠ (S12, 8pt) — DONE
- [x] `CoordinateMapper`: view ↔ normalized displayed ↔ PDF user space. Pure-logic lib `Sources/BureaucratPdfKit/`.
- [x] Handle `/Rotate` 0/90/180/270 + cropBox origin.
- [x] Normalize rect to 0–1 displayed-page fraction; map to user-space `/Rect`.
- [x] **Unit tests:** `Tests/BureaucratPdfKitTests/` — rotation × zoom (25%–400%) grid, round-trip, corner-landing, cropBox offset. 10/10 pass. 🔴 ✓

### 2.2 Draw rectangle (S10, 8pt) — DONE
- [x] `SignatureBoxOverlay`: draw / move / 4-corner resize over rendered page.
- [x] Min-size clamp (24pt); rect clamped to page bounds.
- [~] Snap-to-margin guides — not added (deferred, low value).

### 2.3 Page pick (S11, 3pt) — DONE
- [x] `SignaturePlacementView`: page prev/next nav while placing.
- [x] Pass drawn rect → core in user space (`AppModel.resolvedPlacement` via `CoordinateMapper`).
- [x] Verified: `/Rect` lands exactly on the placement (±2pt acceptance met; pyHanko coverage=ENTIRE_FILE, no regression).

---

## Phase 3 — Appearance (4–6 wk) → launch paid 🔴 — DONE (local)

**Exit gate:** preview matches output; presets persist; paywall gates draw-box + presets. ✓ (Stripe server deferred.)

### 3.1 Configurable box (S13, 8pt) — DONE
- [x] `AppearanceConfig`: toggles name / reason / location / date / custom label + image + QR + border + transparent bg.
- [x] Handwritten-image import (PNG/JPEG via `NSOpenPanel`).
- [x] Appearance composed in Swift (`AppearanceRenderer`) → flattened RGBA → core embeds as Image XObject + grayscale SMask + Form `/AP` (`sign.rs` `build_appearance`/`image_stream`/`form_image_xobject`, FlateDecode). Orientation + alpha verified.
- [x] Live preview = the same render (preview == output by construction); shown in sidebar AND as the drawn-box fill.

### 3.2 Presets (S14, 5pt) — DONE
- [x] `AppearancePreset` persisted as JSON under Application Support (`PresetStore`).
- [x] Save / name / load / delete (`PresetBar`).

### 3.3 Licensing + paywall (S18, S19 — 3+5pt) — DONE (local)
- [x] `LicenseManager`: token in **Keychain** 🔒 (`LicenseKeychain`); monthly free sign-count (UserDefaults).
- [~] Stripe + license server: **deferred** (no external infra). `validate(_:)` is the single seam; offline format check `PDFS-XXXX-XXXX-XXXX`.
- [x] `PaywallView`: feature list, quota message, license-key entry.
- [x] Free tier: invisible + default visible only (quota \(10/mo)). Pro: draw-box, custom appearance, presets, QR, all-pages, batch.

---

## Phase 4 — Scale signing (4–6 wk)

**Exit gate:** team plan live; gestoría pilots.

### 4.1 Multi-box (S15, 8pt) — DONE (single-signer)
- [x] Multiple placements per document: core builds one signature field with N widget Kids (`sign.rs` multi branch, guarded so single/invisible path stays byte-identical — pyHanko ENTIRE_FILE confirmed both). UI: "Firmar en todas las páginas" replicates the drawn box on every page (per-page `CoordinateMapper`).
- [ ] Sequential signing where existing sig locks doc (multi-*signer*) — **deferred** (B-LT/re-sign territory).

### 4.2 Batch (S16, 8pt) — DONE
- [x] `BatchQueue` (`Batch.swift`): multi-select + folder drop (`DropSupport.loadPDFs`).
- [x] Sign all (default placement + current appearance); per-file status icon + message + summary.
- [x] Partial-failure handling (per-item failed state); outputs `<name>-firmado.pdf` beside source. Pro-gated.

### 4.3 QR badge (S17, 5pt) — DONE (local embed)
- [~] Verifier serverless endpoint + token mint: **stubbed** (token = per-sign UUID; URL `verify.bureaucratpdf.app/v/{token}`; no cloud write).
- [x] Embed QR in appearance (CoreImage `CIQRCodeGenerator`, composited by `AppearanceRenderer`).
- [ ] Cloud record `{sig_hash, signing_time, token}` — **deferred** (needs backend). 🔒

### 4.4 Smartcard / DNIe (S20, 8pt) ⚠ — deferred (needs hardware)
- [ ] CryptoTokenKit PIV path → Keychain identity, or PKCS#11 module loader.
- [ ] `PINPromptView`; locked-card handling (`KEY_LOCKED`).
- [ ] Test on physical DNIe (manual).

### 4.5 Team licensing — deferred (needs backend)
- [ ] Multi-seat; admin assignment.

---

## Phase 5+ — Platform (post-funding)

- [ ] Windows shell.
- [ ] Per-doc-type templates.
- [ ] Client archive + audit trail.
- [ ] B-LT / B-LTA (DSS dict, OCSP/CRL, doc-timestamp).
- [ ] Integrations: A3, Sage Despachos, Holded, AEAT Sede.
- [ ] EU-wide cert packs.
- [ ] EU Digital Identity Wallet as new signer backend.

---

## Cross-cutting (every phase)

- [ ] ES + EN localization for new strings.
- [ ] CI: build, test, lint, sign, notarize, staple.
- [ ] Telemetry: anonymous, opt-out, no filenames/doc content. 🔒
- [ ] Sparkle appcast updated per release.
- [ ] Third-party PAdES validation in CI (EU DSS golden files).
