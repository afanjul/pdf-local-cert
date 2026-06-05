# Bureaucrat PDF — Implementation Specifications

> Native macOS app for signing PDFs with X.509 certificates from the system Keychain (FNMT, DNIe, qualified eIDAS). Output: eIDAS-valid PAdES B-T with RFC 3161 timestamp. Private keys never leave the Keychain.
>
> **Status:** Engineering spec · **Version:** 1.0 · **Date:** 2026-05-28
> **Renamed from:** FirmaFast → **Bureaucrat PDF**

---

## 0. Naming & Identity

| Item | Value |
|------|-------|
| Product name | Bureaucrat PDF |
| Bundle identifier | `com.palbin.bureaucratpdf` |
| Display name | Bureaucrat PDF |
| Sidecar binary | `bureaucratpdf-core` |
| Verifier domain | `verify.bureaucratpdf.app` (placeholder) |
| Min macOS | 14.0 (Sonoma) — PDFKit + Security.framework maturity |
| Language | Swift 6 (strict concurrency), Rust (sidecar) |

Rename checklist (from FirmaFast): bundle ID, `Info.plist` `CFBundleName`/`CFBundleDisplayName`, Xcode scheme/target names, app icon assets, marketing copy, verifier URLs, Stripe product names, signing-core CLI name, all user-facing strings (ES/EN), Sparkle/appcast feed URL.

---

## 1. System Architecture

### 1.1 Component map

```
┌─────────────────────────────────────────────────────────┐
│  Bureaucrat PDF.app (notarized, hardened runtime)            │
│                                                          │
│  ┌────────────────────────┐   ┌──────────────────────┐  │
│  │  Native shell (Swift)  │   │  Signing core (Rust) │  │
│  │                        │   │  bureaucratpdf-core      │  │
│  │  • SwiftUI views       │   │  (bundled CLI)       │  │
│  │  • PDFKit render/draw  │◄─►│                      │  │
│  │  • Keychain enum       │   │  • PDF byte-range     │  │
│  │  • SecKeyCreateSig     │   │  • CMS/PAdES assembly │  │
│  │  • CryptoTokenKit/P11  │   │  • RFC 3161 TSA       │  │
│  │  • Coordinate mapping  │   │  • Appearance render  │  │
│  │  • License/billing     │   │  • Verifier engine    │  │
│  └────────────────────────┘   └──────────────────────┘  │
│         Contents/MacOS/Bureaucrat PDF                        │
│         Contents/Helpers/bureaucratpdf-core                  │
└─────────────────────────────────────────────────────────┘
                          │ (verifier funnel only)
                          ▼
        ┌──────────────────────────────────┐
        │  verify.bureaucratpdf.app (static +   │
        │  serverless verify fn)            │
        └──────────────────────────────────┘
        ┌──────────────────────────────────┐
        │  license.bureaucratpdf.app (Stripe +  │
        │  light license server)            │
        └──────────────────────────────────┘
```

### 1.2 Responsibility split

**Shell owns:** all UI, PDF rendering/drawing, Keychain identity enumeration, the actual private-key signature operation (`SecKeyCreateSignature` / PKCS#11), file I/O, save dialogs, licensing state, telemetry.

**Core owns:** PDF parsing, incremental-update byte-range computation, the digest to be signed, CMS `SignedData` assembly, TSA request/response (RFC 3161), DSS/VRI dictionary for LTV, visible-appearance stream generation, and the standalone verification engine.

**Critical invariant:** the core never sees or requests the private key. It produces a digest + signing attributes; the shell signs those bytes via the Keychain; the signed bytes return to the core for CMS finalization. This is the **external/callback-signer** pattern (mirrors pyHanko's `ExternalSigner`).

### 1.3 Shell ↔ core protocol

Local subprocess invocation (`Process`/`posix_spawn`) over a length-prefixed JSON line protocol on stdin/stdout. Binary payloads (PDF bytes, digests, signatures) are passed by **temp file path in a per-op sandboxed temp dir**, not inlined, to avoid base64 bloat on large PDFs.

Two-phase signing handshake:

```
Phase A — PREPARE
  shell → core:  { op:"prepare", pdf:"/tmp/x/in.pdf",
                   cert_chain:["DER…b64"], placements:[…],
                   reason, location, name, tsa_url, pades_level:"B-T" }
  core  → shell: { status:"need_signature", digest:"b64-sha256",
                   sig_alg:"rsa-pkcs1-sha256" | "ecdsa-sha256",
                   handle:"opaque-session-id" }

Phase B — FINALIZE
  shell signs digest via SecKeyCreateSignature
  shell → core:  { op:"finalize", handle:"…", signature:"b64" }
  core  → shell: { status:"ok", out:"/tmp/x/out.pdf",
                   timestamp:"2026-…", signer_cn:"…" }
```

Errors: `{ status:"error", code:"TSA_TIMEOUT"|"BAD_PDF"|"CERT_NOT_TRUSTED"|…, message:"…" }`. All codes enumerated in §7.

---

## 2. Signing Pipeline (security-critical)

### 2.1 PAdES B-T flow

1. **Shell** loads PDF, resolves chosen identity (`SecIdentityRef`), extracts the full cert chain (signer + intermediates) as DER.
2. **Shell** spawns core `prepare` with the chain, placement geometry, and signing metadata.
3. **Core** opens PDF, reserves a `/Contents` placeholder of fixed size (e.g. 32 KB hex) inside a new signature dictionary, writes an **incremental update**, computes the `/ByteRange`, builds the CMS `SignedAttributes` (content-type, message-digest = SHA-256 of byte-range, signing-certificate-v2 ESS, signing-time), and returns the digest of those `SignedAttributes`.
4. **Shell** signs that digest with `SecKeyCreateSignature` using `.rsaSignatureMessagePKCS1v15SHA256` or `.ecdsaSignatureMessageX962SHA256` per key type. *(Key never leaves Keychain/secure enclave/card.)*
5. **Shell** returns raw signature to core (`finalize`).
6. **Core** assembles CMS `SignedData` (detached), sends it to the TSA (RFC 3161) and embeds the timestamp token as an **unsigned attribute** (`id-aa-signatureTimeStampToken`) → this is the **-T** in B-T.
7. **Core** injects the DER CMS into the reserved `/Contents`, patches `/ByteRange`, writes final bytes.
8. **Shell** presents save dialog (or writes to batch output dir).

### 2.2 PAdES levels — roadmap

| Level | Phase | Adds |
|-------|-------|------|
| B-B | spike | basic CMS signature, ESS signing-cert-v2 |
| **B-T** | **Phase 1** | RFC 3161 trusted timestamp (required baseline) |
| B-LT | Phase 4–5 | DSS dictionary with OCSP/CRL revocation data |
| B-LTA | Phase 5 | document timestamp over DSS (long-term archival) |

### 2.3 Algorithms

- Digest: **SHA-256** (SHA-384/512 selectable later).
- RSA: PKCS#1 v1.5 (RSA-PSS optional later).
- ECDSA: P-256/P-384 (X9.62).
- TSA digest: SHA-256.
- All ASN.1/DER strict; reject MD5/SHA-1 signing.

### 2.4 Key-access matrix

| Cert source | Enumeration | Signing API | Phase |
|-------------|-------------|-------------|-------|
| Software cert in Keychain (FNMT file-installed) | `SecItemCopyMatching(kSecClassIdentity)` | `SecKeyCreateSignature` | 1 |
| DNIe / smartcard | CryptoTokenKit PIV driver → Keychain *or* PKCS#11 module | `SecKeyCreateSignature` (CTK) or `C_Sign` (PKCS#11) | story 20 / Phase 2–3 |

Filter identities by Key Usage `digitalSignature` or `nonRepudiation` (parse cert extension; do not rely on label).

---

## 3. Module Breakdown (Swift shell)

```
BureaucratPdf/
├── App/
│   ├── BureaucratPdfApp.swift           # @main, scene, window
│   └── AppState.swift               # @Observable root state
├── PDF/
│   ├── PDFViewerView.swift          # PDFKit NSViewRepresentable
│   ├── DropZoneView.swift           # drag-drop target
│   ├── SignatureBoxOverlay.swift    # draw/move/resize rect
│   └── CoordinateMapper.swift       # view↔page↔PDF user space  ⚠ unit-tested
├── Certificates/
│   ├── IdentityStore.swift          # Keychain enumeration
│   ├── CertificateInfo.swift        # CN/issuer/validity/keyusage parse
│   └── CallbackSigner.swift         # SecKeyCreateSignature wrapper
├── Smartcard/
│   ├── PKCS11Module.swift           # libpkcs11 loader (DNIe)
│   └── PINPromptView.swift
├── SigningCore/
│   ├── CoreClient.swift             # subprocess + JSON protocol
│   ├── PrepareRequest.swift / FinalizeRequest.swift
│   └── SigningCoordinator.swift     # orchestrates prepare→sign→finalize
├── Appearance/
│   ├── AppearanceConfig.swift       # what shows in box
│   ├── AppearancePreset.swift       # named, persisted
│   └── AppearancePreviewView.swift
├── Verifier/
│   ├── VerifierView.swift
│   └── VerificationResult.swift
├── Licensing/
│   ├── LicenseManager.swift         # Keychain token, sign-count
│   └── PaywallView.swift
├── Batch/
│   ├── BatchQueue.swift
│   └── BatchProgressView.swift
└── Common/
    ├── Errors.swift                 # SigningError enum
    └── Telemetry.swift
```

### 3.1 Coordinate mapping (highest-risk module)

`CoordinateMapper` converts between three spaces: **view points** (PDFView, zoom-dependent), **PDFKit page space** (`PDFPage.bounds(for:)`), and **PDF user space** (origin bottom-left, points, rotation-aware). Must handle page `/Rotate` (0/90/180/270) and `displayBox` `.cropBox`. The signature rectangle the user draws is captured in **page space**, normalized to a 0–1 fraction of cropBox, stored as `{page, x, y, w, h, rotation}`, then converted to PDF user-space rect when handed to the core. Isolate, fully unit-test (story 12, 8 pts).

---

## 4. Signing Core (Rust sidecar)

### 4.1 Crate layout

```
bureaucratpdf-core/
├── src/
│   ├── main.rs              # JSON line protocol over stdin/stdout
│   ├── protocol.rs          # serde request/response types
│   ├── pdf/
│   │   ├── incremental.rs    # byte-range, /Contents placeholder
│   │   ├── sigdict.rs        # signature dict, /ByteRange patch
│   │   └── appearance.rs     # /AP stream (text, image, QR)
│   ├── cms/
│   │   ├── signed_data.rs     # detached CMS, SignedAttributes
│   │   └── ess.rs             # signing-certificate-v2
│   ├── tsa.rs                # RFC 3161 request/response
│   ├── dss.rs                # B-LT/B-LTA (later)
│   └── verify.rs            # PAdES verification engine
├── Cargo.toml
└── build: aarch64 + x86_64 → universal2, statically linked
```

### 4.2 Crate selection (spike week 1 — decision gate)

Evaluate, in order of preference:
- **lopdf** (PDF read/write/incremental) + **rasn**/**cms** + **rsa**/**p256**/**sha2** for CMS, + custom RFC 3161 client.
- If Rust PAdES path proves immature within the 1–2 wk spike, **fallback to pyHanko** (`ExternalSigner`) bundled via a statically-linked Python (or a thin Go wrapper). Risk noted in PRD §10. Decide at end of Phase 0.

### 4.3 Verification engine (`verify.rs`)

Used by both the in-app verifier and the serverless web endpoint (compiled to a separate target / WASM). Checks: signature integrity over `/ByteRange`, cert chain to a trusted eIDAS root (bundle EU LOTL/Spanish TSL roots), validity window, key usage, timestamp token validity, and reports PAdES level (B-B/B-T/B-LT/B-LTA). Returns structured `VerificationResult` (signer CN, issuer, signing time, TSA, trust status, level, modifications-after-signing flag).

---

## 5. Build Phases — Acceptance Criteria

### Phase 0 — Spike (1–2 wk)
**Goal:** de-risk crypto + packaging before any UI.
- [ ] `SecKeyCreateSignature` round-trip: shell signs a digest from the core, core finalizes a valid CMS.
- [ ] Produced PDF validates as **PAdES B-T** in a third-party validator (e.g. EU DSS demo, Adobe Reader "valid signature").
- [ ] RFC 3161 timestamp embedded and verified.
- [ ] `.app` with bundled Rust sidecar **notarizes** and passes Gatekeeper on a clean machine.
- [ ] Rust-vs-pyHanko decision recorded.

### Phase 1 — MVP (4–8 wk)
- [ ] Drag-drop single PDF; PDFKit renders all pages, zoom, page nav.
- [ ] Identity list shows CN, issuer, validity, expiry; expired certs greyed with reason.
- [ ] Sign **invisible** signature → save → valid B-T.
- [ ] Sign **default-placed visible** signature (bottom-right of page 1) → valid B-T.
- [ ] Save dialog writes signed PDF; original untouched.
- [ ] Graceful errors: expired cert, locked card/wrong PIN, TSA unreachable, malformed PDF (story 6).
- [ ] Standalone verifier tab: drop signed PDF → valid/invalid + signer + time + level.
- [ ] **≥98% signing success on FNMT software certs; <1% crash rate.**

### Phase 2 — Place (3–4 wk)
- [ ] Draw rectangle on rendered page (move/resize handles).
- [ ] Page picker; multi-page documents.
- [ ] `CoordinateMapper` unit tests pass for rotation 0/90/180/270 and zoom 25%–400%.
- [ ] Signature lands within ±2pt of drawn rect in output PDF.

### Phase 3 — Appearance (4–6 wk) → **launch paid tier**
- [ ] Box content toggles: handwritten image, name, reason, location, date, custom label.
- [ ] Live appearance preview matches rendered output.
- [ ] Save/load named presets (persisted, see §6).
- [ ] Paywall gates draw-box + presets; free tier = invisible + default visible only.

### Phase 4 — Scale signing (4–6 wk)
- [ ] Multiple signature boxes per document (sequential signing where required).
- [ ] Batch: drop folder / multi-select → sign all (invisible or default placement) with progress + per-file result.
- [ ] QR verify-badge embedded in appearance, links to `verify.bureaucratpdf.app/v/{token}`.
- [ ] Team/multi-seat licensing.

### Phase 5+ — Platform
Windows shell, per-doc templates, client archive + audit trail, integrations (A3, Sage Despachos, Holded, AEAT), EU-wide cert packs, B-LT/B-LTA, EU Digital Identity Wallet as a new signer backend.

---

## 6. Data Model & Persistence

**Local only by default.** No document content leaves the device.

| Entity | Store | Notes |
|--------|-------|-------|
| AppearancePreset | App Support JSON (or SwiftData) | name, fields enabled, image data, font, label text |
| RecentFiles | UserDefaults (security-scoped bookmarks) | path + bookmark |
| License token | **Keychain** | JWT/opaque; never UserDefaults |
| Sign count (free tier) | UserDefaults + server reconcile | monthly counter, reset date |
| Telemetry | local buffer → batched anonymous events | no doc content, no PII |

**Cloud (verifier only):** optional minimal record per badge — `{ sig_hash, signing_time, public_verify_token }`. No document, no PII beyond what signer opts to expose. Badge token treated as non-sensitive.

---

## 7. Error Taxonomy

Every failure maps to a code, an ES + EN user message, and a recovery hint.

| Code | Cause | User message (ES) | Recovery |
|------|-------|-------------------|----------|
| `CERT_EXPIRED` | signer cert past validity | "El certificado ha caducado." | renew at FNMT |
| `CERT_NOT_TRUSTED` | chain to no trusted root | "Cadena de certificación no confiable." | install intermediates |
| `KEY_LOCKED` | card/Keychain locked, wrong PIN | "PIN incorrecto o tarjeta bloqueada." | re-enter PIN |
| `NO_SIGNING_KEYUSAGE` | cert lacks digitalSignature/nonRepudiation | "El certificado no permite firmar." | choose another |
| `TSA_TIMEOUT` | TSA unreachable | "No se pudo obtener el sello de tiempo." | retry / change TSA |
| `BAD_PDF` | parse/encrypted/corrupt | "El PDF no se pudo procesar." | — |
| `PDF_ENCRYPTED` | password-protected | "El PDF está protegido." | remove password |
| `ALREADY_SIGNED_LOCKED` | existing sig forbids changes | "El documento no admite más firmas." | — |
| `LICENSE_LIMIT` | free tier monthly cap hit | "Has alcanzado el límite mensual." | upgrade |
| `CORE_CRASH` | sidecar abnormal exit | "Error interno de firma." | report |

No silent failures. Signing core errors propagate verbatim to logs (quoted exact), translated for UI.

---

## 8. Security Requirements

- Private key **never** serialized to disk; no in-memory PFX. Callback signer only.
- Hardened runtime + notarization; minimal entitlements (no `com.apple.security.app-sandbox` initially if it blocks PKCS#11; revisit for MAS).
- Required entitlements: Keychain access groups, smartcard/CryptoTokenKit. **Not** network for shell except TSA + license + telemetry (justify each).
- Sidecar runs with same hardened runtime; temp files in per-op dir, `chmod 600`, deleted on completion (also on crash via cleanup at next launch).
- TSA over HTTPS, pinned CA set; validate timestamp token signature.
- Verifier endpoint stores no document content; rate-limited; tokens opaque & non-guessable.
- All crypto via vetted crates / Security.framework — no hand-rolled primitives.
- Telemetry: opt-out, anonymous, never includes filenames or doc content.

---

## 9. Tech Stack Summary

| Layer | Choice |
|-------|--------|
| UI | Swift 6 + SwiftUI + PDFKit |
| Cert/sign | Security.framework (`SecItemCopyMatching`, `SecKeyCreateSignature`); CryptoTokenKit / PKCS#11 for DNIe |
| Signing core | Rust universal2 static sidecar (pyHanko fallback) |
| Shell↔core | subprocess + length-prefixed JSON, file-path payloads, callback hash-sign |
| Verifier web | static site + serverless fn (shared Rust/WASM verify engine) |
| Billing | Stripe + light license server (Keychain-stored token) |
| Updates | Sparkle (Developer ID build) |
| Distribution | Developer ID + notarization; MAS later if sandbox permits card access |
| CI | GitHub Actions: build, test, lint, sign, notarize, staple |

---

## 10. Testing Strategy

- **Unit:** `CoordinateMapper` (rotation×zoom matrix), `CertificateInfo` parsing, error mapping, protocol serde.
- **Core integration:** golden-file PDFs → assert PAdES B-T validity via external validator (EU DSS) in CI.
- **Cert fixtures:** test FNMT-style soft cert + self-signed chains; mock TSA server for deterministic timestamps.
- **Snapshot:** appearance rendering (text/image/QR) pixel-diff.
- **E2E manual:** real DNIe + real FNMT cert on physical machine (cannot automate smartcard).
- **Notarization smoke:** every release build runs on a clean VM through Gatekeeper.
- Quality gate (Phase 1): ≥98% sign success across cert fixtures, <1% crash.

---

## 11. Open Decisions (resolve in spike)

1. Rust PAdES crate maturity vs pyHanko fallback — **Phase 0 gate**.
2. TSA provider(s): FNMT TSA, freeTSA, or commercial; configurable list.
3. eIDAS trust roots bundling: ship EU LOTL/Spanish TSL snapshot + auto-update mechanism.
4. Sandbox vs PKCS#11: confirm whether MAS sandbox can reach DNIe driver; if not, Developer ID only.
5. License enforcement: offline grace period length, sign-count reconciliation cadence.
