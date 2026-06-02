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
Solution `windows/PdfLocalCert.sln` ties three projects: `PdfLocalCert.Core` (UI-free
logic, unit-tested on any host), `PdfLocalCert.App` (WinUI 3 shell, ships as
`PdfLocalCert.exe`), `PdfLocalCert.Core.Tests`. **x64 only** (runs under x64 emulation
on the ARM box — do not build arm64).

Unit tests run headless anywhere: `dotnet test windows\PdfLocalCert.Core.Tests`.

**Run the app = MSIX, always.** There is no loose-`.exe` dev path — it was tried and
abandoned (see "Why MSIX-only" below). Build → pack → install:
```powershell
# winvm has only Windows PowerShell (no pwsh); invoke .ps1 with &, not pwsh.
# 1. payload MUST be WindowsPackageType=MSIX (a None-typed payload silently exits
#    inside a package — packaged apps get the runtime from the dependency graph).
dotnet publish windows\PdfLocalCert.App -c Release -r win-x64 `
  --self-contained true -p:WindowsPackageType=MSIX -o <payload>
# 2. pack + dev self-sign -> windows\build\PdfLocalCert.msix
& windows\scripts\pack-msix.ps1 -PublishDir <payload>
# 3. install (elevated, one-time cert trust); launch from the Start menu
& windows\scripts\install-msix.ps1
```

**Building from the share needs a `subst` drive.** `mt.exe` (manifest tool, run by the
MSIX/self-contained targets) rejects UNC working dirs (`c1010070 ... volume label syntax
is incorrect`). subst a drive letter onto the repo first, build from there:
```powershell
subst S: \\Mac\Home\apps\pdf-local-cert; Set-Location S:\windows
# ...dotnet publish... then:
Set-Location C:\; subst S: /d
```

**Execution-policy bypass is pre-authorized for builds.** The user has explicitly
granted permission to run the repo's own build/pack/install `.ps1` scripts on the
Windows hosts with `powershell -ExecutionPolicy Bypass` (default policy blocks the
unsigned local scripts). This applies only to the in-repo scripts under
`windows/scripts/` (`pack-msix.ps1`, `install-msix.ps1`, etc.) — not to arbitrary
remote code.

**Why MSIX-only (don't re-litigate):** a loose unpackaged `.exe` on this box fails two
ways at once — framework-dependent crashes at startup needing the x64 **DDLM**
(`0xc000027b` in `combase.dll`; `REGDB_E_CLASSNOTREG`), and self-contained can't be
built because `mt.exe` can't embed the reg-free WinRT manifest from the UNC share.
Burned a long session proving this. MSIX sidesteps both via its dependency graph.

## Conventions

- Commit/PR text: normal prose, Conventional Commits. (Chat may be terse; commits are not.)
- Build outputs are **per-platform**, never at repo root: `apple/build/` (the `.app`/dmg,
  via `apple/scripts/build.sh`), `windows/build/` (the `.msix`, via `pack-msix.ps1`), and
  standard `*/bin/`,`*/obj/` for .NET. All gitignored. Don't reintroduce a root `build/`.
- Stale `windows/PdfLocalCert.App/bin/.../win-x64/*.exe` on the Mac is a leftover sync,
  not a local build — macOS can't compile the WinUI shell.
