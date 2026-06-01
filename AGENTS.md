# AGENTS.md — PDF Local Cert

Canonical agent guide for this repo. Read this first.

## What this is

Local-only PDF digital signing (PAdES B-B / B-T) with the private key never leaving
the OS keystore. A shared **Rust core** does the PDF/PAdES work and exposes a
line-delimited JSON protocol over stdio; native shells drive it as a subprocess and
sign the core-provided digest through the platform key API (external-signer pattern).

## Layout

| Dir | What |
|---|---|
| `core/` | Shared Rust core. Builds `pdflocalcert-core` (the protocol binary, `.exe` on Windows). |
| `protocol/` | Line-delimited JSON protocol spec the shells and core speak. |
| `apple/` | macOS/iOS shell (Swift). Signs via SecKey/Keychain. |
| `windows/` | Windows shell (C# / WinUI 3). Signs via CNG + Windows cert store. See `windows/README.md`, `windows/RELEASE.md`. |
| `samples/` | Test PDFs (e.g. `contract-sample.pdf`, MediaBox `[0 0 595.28 841.89]`). |
| `openspec/` | Design docs. Windows port: `openspec/changes/windows-port/`. |

## Build environments

The Rust core builds on any host. The **WinUI 3 shell cannot build on macOS** — it
needs a Windows host with the Windows App SDK. Use the SSH hosts below.

### Windows hosts (SSH)

Both configured in `~/.ssh/config`, both auth with `~/.ssh/plc_win_vm`.
**Default remote shell is PowerShell** (not bash) — write commands as
`ssh winvm 'powershell -NoProfile -c "..."'`. Chain with `;` not `&&`/`||`
(PowerShell rejects `||` as a statement separator).

| Host | IP | Arch | dotnet | Notes |
|---|---|---|---|---|
| `winvm` | 10.211.55.3 | **ARM64** | 8.0.421 | Active test box. Home `C:\Users\aleksdj`. |
| `winx64` | 192.168.100.42 | **AMD64/x64** | — not installed | Brand-new install; bare. Needs .NET 8 SDK + repo before it can build. |

`$HOME` on the remotes is `C:\Users\aleksdj`. Clone/sync the repo there before building.

## Build & run

### Rust core
```bash
cd core && cargo build --release   # see memory note re: cargo network quirk
```

### Windows shell (on a Windows host over SSH)
Three projects under `windows/`: `PdfLocalCert.Core` (UI-free logic, unit-tested on any
host), `PdfLocalCert.App` (WinUI 3 shell), `PdfLocalCert.Core.Tests`.

Two publish layouts — **the `WindowsPackageType` flag is opposite for each, do not mix:**

- **Loose dev .exe** (fast inner loop, no install):
  ```powershell
  pwsh windows/scripts/publish-loose.ps1 -Run
  ```
  Publishes `WindowsPackageType=None`; the WinAppSDK bootstrapper resolves the runtime
  at launch so the `.exe` runs directly from the publish folder.

- **MSIX package** (ship/install test):
  ```powershell
  pwsh windows/scripts/pack-msix.ps1 -PublishDir <dir>
  ```
  Payload MUST be published `WindowsPackageType=MSIX`. A `None`-typed payload inside an
  MSIX **silently exits at launch** (packaged app gets its runtime from the dependency
  graph, not the bootstrapper). See header of `pack-msix.ps1`.

## Conventions

- Commit/PR text: normal prose, Conventional Commits. (Chat may be terse; commits are not.)
- Don't commit build artifacts under `*/bin/`.
- Stale `windows/PdfLocalCert.App/bin/.../win-x64/*.exe` on the Mac is a leftover sync,
  not a local build — macOS can't compile the WinUI shell.
