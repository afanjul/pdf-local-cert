# Windows shell (C# / WinUI 3)

Native Windows 10 (17763+) / 11 shell for PDF Local Cert, at feature parity with the
macOS app: open/view a PDF, place visible signatures, pick a certificate from the Windows
certificate store, sign (PAdES B-B / B-T with a TSA), and verify.

It drives the **same** shared Rust core as the Apple shell, spawning `pdflocalcert-core.exe`
via `System.Diagnostics.Process` and talking the line-delimited JSON protocol in
[`../protocol`](../protocol). The private key never leaves the Windows cert store — the
shell only signs the core-provided digest via CNG (external-signer pattern).

See `openspec/changes/windows-port/` for the full design. Scaffolded in Phase 4.
