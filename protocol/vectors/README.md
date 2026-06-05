# Conformance vectors

Golden fixtures the core is asserted against on every platform. Driven by
[`core/tests/conformance.rs`](../../core/tests/conformance.rs) (`cargo test -p
bureaucratpdf-core --test conformance`), run in CI on macos-latest and
windows-latest so the two shells cannot silently desync.

## Files

| File | Purpose |
|------|---------|
| `ping.json` | Golden `ping` request → exact expected response. |
| `test-signer.der` | Throwaway self-signed RSA cert, **public DER only** (no private key). Used as the `cert_chain` for the `prepare` shape check — `prepare` needs only the public cert + the PDF, no secret. |
| `sample-unsigned.pdf` | A small unsigned PDF for the `prepare` and `verify`-unsigned checks. |

## Checks

- **`ping`** — exact response match: `{"status":"ok","pong":true}`.
- **`prepare`** — response shape: `status == "need_signature"`, fields `handle`,
  `digest` (valid base64), `sig_alg ∈ {rsa-pkcs1-sha256, ecdsa-sha256}`.
- **`verify` (unsigned)** — `status == "error"`, `code == "NO_SIGNATURE"` (the
  core's contract for a PDF with no signature; the shell shows "no signature found").
- **bad op** — `status == "error"` with a `code`.

## Follow-ups (need signed material)

- A **signed** sample PDF → `verify` returns `valid:true` with signer/issuer CN,
  `pades_level`, `byte_range_covers_whole_file`. Generate once via the
  `prepare → sign(OpenSSL key) → finalize` path, then commit the signed PDF.
- An **ECDSA r‖s → DER** vector: a known raw P1363 signature and its expected DER
  `SEQUENCE`, asserting the Windows-side conversion (CNG returns raw r‖s; the
  core's CMS expects DER). Lives with the Windows shell's signing tests too.
