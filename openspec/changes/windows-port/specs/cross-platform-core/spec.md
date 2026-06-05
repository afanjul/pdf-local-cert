## ADDED Requirements

### Requirement: Core builds for Windows
The Rust core SHALL build for the `x86_64-pc-windows-msvc` target, producing a `bureaucratpdf-core.exe` binary, both when cross-compiled from macOS and when built natively on Windows, with no source changes between platforms.

#### Scenario: Cross-compile from macOS
- **WHEN** the core is built from macOS targeting `x86_64-pc-windows-msvc` (via cargo-xwin)
- **THEN** a runnable `bureaucratpdf-core.exe` is produced without source modifications

#### Scenario: Native Windows build
- **WHEN** the core is built on a Windows host in release mode
- **THEN** the build succeeds and produces `bureaucratpdf-core.exe`

### Requirement: Protocol parity across platforms
The core SHALL expose the identical line-delimited JSON protocol (`ping`, `prepare`, `finalize`, `verify`) on stdin/stdout on Windows and macOS, with byte-equivalent request/response shapes.

#### Scenario: Ping on Windows
- **WHEN** a `{"op":"ping"}` line is written to the Windows core's stdin
- **THEN** it responds with one line `{"status":"ok","pong":true}`, matching the macOS build

#### Scenario: Prepare response shape is identical
- **WHEN** a valid `prepare` request is sent on either platform
- **THEN** the response contains the same fields (`status`, `handle`, `digest`, `sig_alg`) with the same semantics

### Requirement: Shared conformance vectors
The repository SHALL include a `protocol/` directory with golden request/response vectors, and CI SHALL run the core against them on both macOS and Windows so the two shells cannot silently desync.

#### Scenario: Vectors pass on both OSes in CI
- **WHEN** CI builds the core on macos-latest and windows-latest
- **THEN** the conformance vectors are executed against each build and all pass

#### Scenario: A protocol-breaking change fails CI
- **WHEN** a change alters a response field or shape not reflected in the vectors
- **THEN** the conformance run fails on at least one platform, blocking the merge

### Requirement: Single source tree, one core
The shared core SHALL live in exactly one location in the monorepo and be consumed by both the Apple and Windows shells; no platform-specific fork of the core source is permitted.

#### Scenario: Both shells reference the same core source
- **WHEN** the core's signing or verification logic is modified
- **THEN** both the macOS `.app` and the Windows MSIX pick up the change from the same `core/` source on the next build
