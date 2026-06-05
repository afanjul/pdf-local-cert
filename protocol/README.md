# Protocol — shared core contract

The Rust core (`core/`, shipped as `pdflocalcert-core` / `pdflocalcert-core.exe`) is
driven by every native shell over a **line-delimited JSON protocol** on stdin/stdout:
one JSON request object per line in, one JSON response object per line out. The core is
stateless across processes; a `handle` ties a `prepare` to its `finalize` within one run.

This directory is the **single source of truth** for that contract. Both the Apple
(`apple/`) and Windows (`windows/`) shells, plus CI, assert against the golden vectors
here so the two UIs cannot silently desync (see design D7).

## Operations

| op         | request fields                                             | response fields |
|------------|------------------------------------------------------------|-----------------|
| `ping`     | `{"op":"ping"}`                                             | `{"status":"ok","pong":true}` |
| `prepare`  | input PDF, signature rect/page, visible flag, signer meta  | `{"status":"need_signature","handle":…,"digest":…,"sig_alg":…}` |
| `finalize` | `handle`, the shell-produced `signature` (+ chain), TSA URL | `{"status":"ok","output":…}` |
| `verify`   | input PDF                                                   | `{"status":"ok","valid":…,"signer_cn":…,"issuer_cn":…,"signing_time":…,"has_timestamp":…,"pades_level":…,"byte_range_covers_whole_file":…}` |

### External-signer flow (`prepare` → sign → `finalize`)

1. Shell sends `prepare`; core does the PDF surgery (incremental update, `/ByteRange`,
   `/Contents` placeholder), builds `SignedAttributes`, and returns the **digest to sign**
   plus the required `sig_alg`.
2. `sig_alg` is one of:
   - `rsa-pkcs1-sha256` — sign with RSA PKCS#1 v1.5 over SHA-256. Identical bytes on
     macOS (`SecKeyCreateSignature`) and Windows (CNG `RSA.SignHash`).
   - `ecdsa-sha256` — ECDSA P-256 over SHA-256. **The CMS expects DER `SEQUENCE` (r,s).**
     macOS `SecKey` already returns DER; Windows CNG returns raw r‖s (IEEE P1363) and the
     shell MUST encode it to DER before `finalize`.
3. The shell signs the digest with the system crypto store (key never leaves the store),
   gathers the leaf-first cert chain, and sends `finalize`; the core splices the CMS into
   the placeholder and writes the signed PDF.

The private key never crosses this boundary — only the digest and the resulting signature.

## Conformance vectors

`vectors/` holds golden request/response pairs (`ping`, a `prepare` shape, a `verify`
fixture over a signed + an unsigned sample, and an ECDSA r‖s→DER case). The conformance
harness pipes each request through the core and asserts the response shape; CI runs it on
`macos-latest` and `windows-latest`. A protocol-breaking change fails the run on at least
one platform and blocks the merge.
