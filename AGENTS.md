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
| `winx64` | 192.168.100.42 | **AMD64/x64** | — not installed | Separate **zvm** VM (not Parallels). Brand-new/bare. No shared folder; needs .NET 8 SDK + a repo clone (or a share set up) before it can build. |

`$HOME` on the remotes is `C:\Users\aleksdj`.

**`winvm` sees this repo directly** via a Parallels shared folder — the Mac home is
mounted at `\\Mac\Home`, so this repo is live at `\\Mac\Home\apps\pdf-local-cert`
(no clone/sync; same bytes as the Mac working tree, including uncommitted edits).
`winx64` has no such share — it needs a real clone before it can build.

Driving PowerShell over SSH: prefer `-EncodedCommand` (base64 of UTF-16LE) to dodge
bash→ssh→PowerShell quote mangling:
```bash
ENC=$(printf '%s' "$PS_SCRIPT" | iconv -t UTF-16LE | base64)
ssh winvm "powershell -NoProfile -EncodedCommand $ENC"
```

## Who runs what — test handoff

The agent **builds** on the Windows hosts over SSH (headless: `dotnet`/`pwsh` only).
The agent **cannot** see a GUI, drive the WinUI window, click, draw, or eyeball a
rendered PDF. So:

> **Any visual / interactive / "run the app and look" test is run by the USER.**
> The agent writes **explicit, numbered, copy-pasteable steps** and the exact
> observations to report back; the user runs them on the Windows box and reports
> results. The agent never claims a GUI behaviour was verified unless the user
> reported it.

Agent does headlessly over SSH: builds, unit tests (`dotnet test`), publish, MSIX
pack/sign, file/cert inspection. Everything that needs a screen or a human judgement
(launch, placement, sign-dialog flow, "where did the signature land") → hand to user
with steps + expected/observe checklist.

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
  # winvm has only Windows PowerShell (no pwsh) — invoke the script with &, not pwsh:
  & windows\scripts\publish-loose.ps1          # win-x64; x64-on-ARM emulation on winvm
  ```
  Publishes `WindowsPackageType=None` + `WindowsAppSDKSelfContained=true`. The
  self-contained flag is required: a framework-dependent unpackaged build runs the
  WinAppSDK DeploymentManager auto-initializer at startup and crashes here with
  `REGDB_E_CLASSNOTREG` before any window. Self-contained bundles the runtime in-folder
  and removes the auto-init. **x64 only** — we do not build arm64 (it ran fine under
  x64 emulation; arm64 was a wrong turn).

- **MSIX package** (ship/install test):
  ```powershell
  & windows\scripts\pack-msix.ps1 -PublishDir <dir>   # -> windows/build/PdfLocalCert.msix
  ```
  Payload MUST be published `WindowsPackageType=MSIX`. A `None`-typed payload inside an
  MSIX **silently exits at launch** (packaged app gets its runtime from the dependency
  graph, not the bootstrapper). See header of `pack-msix.ps1`.

## Conventions

- Commit/PR text: normal prose, Conventional Commits. (Chat may be terse; commits are not.)
- Build outputs are **per-platform**, never at repo root: `apple/build/` (the `.app`/dmg,
  via `apple/scripts/build.sh`), `windows/build/` (the `.msix`, via `pack-msix.ps1`), and
  standard `*/bin/`,`*/obj/` for .NET. All gitignored. Don't reintroduce a root `build/`.
- Stale `windows/PdfLocalCert.App/bin/.../win-x64/*.exe` on the Mac is a leftover sync,
  not a local build — macOS can't compile the WinUI shell.
