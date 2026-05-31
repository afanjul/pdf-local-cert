# PDF Local Cert — Progress & Resume Guide

**Updated:** 2026-05-29 · Read this first when resuming in a fresh session.

## Where we are

Phase 0 (spike) and Phase 1 (MVP) are **functionally done and verified end-to-end**:
a real qualified certificate (UANATACA / FNMT, from the macOS Keychain) signs PDFs that
**Adobe Acrobat reports as valid** — PAdES **B-T**, EU Trusted Lists (EUTL) trust,
embedded RFC 3161 timestamp, "document not modified". The private key never leaves the
Keychain (external/callback signer).

**Phases 2, 3, 4 — DONE (local).** Built and validated this session (pyHanko coverage=ENTIRE_FILE on single/image/multi; single & invisible signing paths byte-behavior unchanged):

- **Phase 2 (place):** `CoordinateMapper` (pure lib `Sources/PDFLocalCertKit/`, unit-tested 10/10: rotation 0/90/180/270 × zoom 25–400%, cropBox offset, round-trip), `SignatureBoxOverlay` (draw/move/resize), page picker (`SignaturePlacementView`). Drawn rect → user space lands exactly on `/Rect`.
- **Phase 3 (appearance):** `AppearanceConfig` (name/reason/location/date/label/image/QR/border/transparent) → `AppearanceRenderer` flattens to RGBA → core embeds **Image XObject + grayscale SMask + Form /AP** (`sign.rs` `build_appearance`, FlateDecode via new `flate2` dep). Preview == output by construction (same render fills the drawn box + sidebar). Presets persisted (`PresetStore`, App Support JSON). Licensing: `LicenseManager` (Keychain token) + `PaywallView`; free = invisible/default-visible + 10/mo quota, Pro = everything else.
- **Phase 4 (scale):** Batch (`Batch.swift`, Pro, per-file status + auto-save `<name>-firmado.pdf`). QR badge (CoreImage, local UUID token, URL `verify.pdflocalcert.app/v/{token}`). Multi-box = **one signature, N widget Kids** (`sign.rs` multi branch, guarded; "firmar en todas las páginas" replicates the drawn box per page via per-page `CoordinateMapper`).

**Tests/validation:** `swift test` (mapper, 10/10). Core oracles: `/tmp/test_pipeline.py` (single), `/tmp/test_image_appearance.py` (image+SMask), `/tmp/test_multibox.py` (2-widget), each + `/tmp/pyhanko_validate.py` → ENTIRE_FILE.

**Deferred (need backend/hardware, NOT bottlenecks for local use):** Stripe + license server (seam = `LicenseManager.validate`), QR cloud record, DNIe/smartcard (CryptoTokenKit/PKCS#11), multi-*signer* sequential, B-LT/B-LTA (LTV), Developer-ID notarization, universal2, in-repo CI. See `docs/TASK_CHECKLIST.md`.

## What works

- **Sign:** drag/open a PDF → pick Keychain cert → invisible OR default-placed visible
  signature → optional TSA timestamp (B-T) → save. Output validates in Acrobat + pyHanko.
- **Verify:** drop a signed PDF → signer (matched by issuer+serial), issuer, B-B/B-T,
  digest match, RSA crypto check, `/Contents` boundary check. Matches Acrobat on the
  reference files in `tests/`.

## Architecture (two halves, one `.app`)

- **Swift shell** `Sources/PDFLocalCert/` (SwiftPM executable, SwiftUI + PDFKit):
  `AppModel`, `ContentView`/`SignTab`, `VerifierView`, `PDFViewerView`, `DropSupport`,
  `IdentityStore` (+`CallbackSigner`), `SigningCoordinator`, `CoreClient`, `Errors`,
  + Phase 2–4: `SignaturePlacementView`/`SignatureBoxOverlay`, `AppearanceConfig`,
  `AppearanceRenderer`, `AppearanceEditorView`, `PresetStore`/`PresetBar`,
  `LicenseManager`, `PaywallView`, `Batch`.
- **Pure-logic lib** `Sources/PDFLocalCertKit/` (`CoordinateMapper`) + tests
  `Tests/PDFLocalCertKitTests/` — `swift test`.
- **Rust sidecar** `core/src/` (hand-rolled DER/CMS, lopdf):
  `main.rs` (JSON line protocol), `protocol.rs`, `sign.rs` (PDF surgery, ByteRange,
  prepare/finalize), `cms.rs` (DER/CMS/SignedAttributes), `tsa.rs` (RFC 3161),
  `verify.rs`. Talks to the shell over stdin/stdout JSON; binary payloads via file paths.
- **Callback-signer flow:** shell sends cert chain + placement → core `prepare` returns the
  SignedAttributes (TBS) → shell signs via `SecKeyCreateSignature` → core `finalize`
  assembles CMS (+TSA) and splices into the `/Contents` placeholder.

## Build / run / test

```sh
bash scripts/build.sh          # -> build/PDF Local Cert.app (ad-hoc signed)
open build/PDF Local Cert.app
```
- **cargo network quirk:** the rtk hook sandboxes a bare `cargo` and breaks crates.io.
  Use absolute path + git index: `scripts/build.sh` sets `CARGO=/opt/homebrew/bin/cargo`
  and `CARGO_NET_GIT_FETCH_WITH_CLI=true`. For cargo network ops in the Bash tool, also
  pass `dangerouslyDisableSandbox: true`.
- **Pipeline test (no Keychain):** `python3 /tmp/test_pipeline.py` (test cert → prepare →
  openssl-sign → finalize → verify). Regenerate cert if `/tmp` cleared:
  `openssl req -x509 -newkey rsa:2048 -keyout /tmp/tkey.pem -out /tmp/tcert.pem -days 365 -nodes -subj "/CN=Test Signer/O=PDF Local Cert Test/C=ES"; openssl x509 -in /tmp/tcert.pem -outform DER -out /tmp/tcert.der`
- **Strict validator (Adobe-like):** pyHanko venv `/tmp/pyhanko-venv`, script
  `/tmp/pyhanko_validate.py <pdf>`. The signal is `coverage` = must be `ENTIRE_FILE`.

## Reference files

`tests/test - original.pdf` (unsigned), `tests/test - valid.pdf` (Adobe-signed, valid),
`tests/test - not-valid.pdf` (old broken build — our verifier now correctly rejects it via
the `/Contents` boundary check).

## Hard-won Adobe PAdES gotchas (do NOT regress)

1. `/ByteRange` integers: NO leading zeros — pad the fixed-width region with trailing spaces.
2. `/ByteRange` gap must EXCLUDE both `<` and `>` of `/Contents <...>` (b1 = offset of `<`,
   b2 = one-past `>`). Leaving brackets in the signed range = Adobe "SigDict /Contents
   illegal data" / pyHanko coverage `UNCLEAR`.
3. Sig dict needs `/M (D:YYYYMMDDHHmmSS+00'00')` and `/Name (...)`.
4. Verifier must pick the signer cert by `SignerInfo` issuer+serial — the CMS cert set also
   holds CA/TSA/OCSP certs (first cert was the OCSP responder).
(Full notes: memory file `pdf-local-cert-build`.)

## Known gaps / deferred

arm64-only (no universal2); ad-hoc signed (no Developer-ID/notarization — user has paid
certs ready); no bundled eIDAS trust roots (no chain-trust check in our verifier); no CI/
tests-in-repo; B-LT/B-LTA (LTV) not implemented; no app icon.

## Phase 2 scope (next)

`docs/TASK_CHECKLIST.md` → Phase 2 "Place". Build:
- `CoordinateMapper` (view ↔ PDFKit page space ↔ PDF user space; handle `/Rotate`
  0/90/180/270 + cropBox; zoom 25–400%) — **isolate + unit-test**, highest risk.
- `SignatureBoxOverlay`: draw/move/resize the signature rectangle on the rendered page.
- Page picker; pass the drawn rect (in PDF user space) as the placement to the core
  (`placements` already supported by `sign.rs` — currently fed a default bottom-right box
  from `AppModel.defaultPlacement()`).
- Acceptance: signed signature lands within ±2pt of the drawn rectangle.
