# PDF Local Cert

Native macOS app to digitally sign PDFs with the X.509 certificates already in
your Keychain (FNMT, DNIe, qualified eIDAS) — no Java, no Adobe, no AutoFirma.
Output is PAdES B-T (RFC 3161 timestamp). The private key never leaves the
Keychain.

> Renamed from *FirmaFast*. Specs in [`docs/`](docs/).

## Architecture

| Part | Path | Role |
|------|------|------|
| SwiftUI shell | `Sources/PDFLocalCert/` | UI, PDFKit render, Keychain enum, `SecKeyCreateSignature`, save, verifier |
| Rust sidecar | `core/` | PDF byte-range surgery, CMS/PAdES assembly, RFC 3161 TSA, verification |

The shell never exports the key: the core returns the SignedAttributes to sign,
the shell signs them via the Keychain, the core splices the CMS into the PDF
(external/callback-signer pattern).

## Build

```sh
bash scripts/build.sh          # ad-hoc signed → build/PDF Local Cert.app
SIGN_ID="Apple Development: Your Name (TEAMID)" bash scripts/build.sh
```

> **Note:** invoke cargo by absolute path with the git index protocol — the rtk
> hook otherwise sandboxes cargo and breaks crates.io. `build.sh` handles this
> via `CARGO=/opt/homebrew/bin/cargo` + `CARGO_NET_GIT_FETCH_WITH_CLI=true`.

## Run

```sh
open build/PDF Local Cert.app
```

Drag a PDF in, pick a certificate, choose invisible or visible signature,
optionally enable a timestamp (B-T), then **Firmar y guardar**. The **Verificar**
tab validates any signed PDF.

## Test the signing pipeline (no Keychain required)

```sh
python3 /tmp/make_pdf.py          # writes /tmp/test-unsigned.pdf
python3 /tmp/test_pipeline.py     # prepare → openssl-sign → finalize → verify
```

Validated end-to-end: PAdES **B-B** and **B-T**, with cryptographic RSA
verification (`valid=true, crypto=ok`).

## Status

- **Phase 0 + 1: done & Adobe-validated** — single-PDF sign (invisible + default visible),
  PAdES B-T with timestamp, save, standalone verifier. Real FNMT/UANATACA certs produce
  signatures Acrobat reports as **valid** (EUTL trust).
- Phases 2–4 (draw box, appearance presets, batch/multi-box/QR badge): pending.

**Resuming work?** Read [`docs/PROGRESS.md`](docs/PROGRESS.md) first, then
[`docs/TASK_CHECKLIST.md`](docs/TASK_CHECKLIST.md).
