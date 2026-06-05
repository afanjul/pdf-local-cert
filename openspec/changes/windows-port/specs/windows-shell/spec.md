## ADDED Requirements

### Requirement: Open and view a PDF
The Windows shell SHALL let the user open a PDF (file picker and drag-and-drop) and view its pages rendered on screen.

#### Scenario: Open via picker
- **WHEN** the user picks a PDF file
- **THEN** its pages are rendered and scrollable in the viewer

#### Scenario: Open via drag-and-drop
- **WHEN** the user drops a PDF onto the app window
- **THEN** the document loads and is displayed

### Requirement: Place a visible signature on a page
The Windows shell SHALL let the user position a signature rectangle on a chosen page, converting on-screen coordinates to PDF user-space (points, origin bottom-left) consistently with the macOS shell's coordinate mapping, including page rotation and DPI scaling.

#### Scenario: Drag a signature box
- **WHEN** the user draws/moves a signature box on a page
- **THEN** the box's PDF user-space rect (page, x, y, w, h) is computed and sent to the core's `prepare` placement

#### Scenario: Invisible signature
- **WHEN** the user chooses to sign without a visible appearance
- **THEN** `prepare` is sent with no placements (invisible signature)

### Requirement: Select a certificate and sign
The Windows shell SHALL let the user choose a signing identity and produce a signed PDF by driving the core over the JSON protocol: `prepare` → CNG sign the returned digest → `finalize`.

#### Scenario: Successful B-B signature
- **WHEN** the user signs without a timestamp URL
- **THEN** the output PDF is a valid PAdES B-B signature and the app reports success with the signer common name

#### Scenario: Successful B-T signature with TSA
- **WHEN** the user provides an RFC 3161 TSA URL and signs
- **THEN** the core embeds a timestamp token and the result is reported as PAdES B-T

#### Scenario: Signing a certificate that is expired
- **WHEN** the selected certificate is expired
- **THEN** signing is blocked with a clear error before the core is invoked

### Requirement: Verify a signed PDF
The Windows shell SHALL let the user verify a PDF and display each signature's validity, signer/issuer common name, signing time, timestamp presence, PAdES level, and whether the byte range covers the whole file.

#### Scenario: Verify a signed document
- **WHEN** the user verifies a signed PDF
- **THEN** the app shows each signature's `valid` status and its detail fields from the core's `verify` response

#### Scenario: Verify an unsigned document
- **WHEN** the user verifies a PDF with no signature
- **THEN** the app reports that no signature was found

### Requirement: Spawn the core sidecar over stdio
The Windows shell SHALL invoke the bundled `pdflocalcert-core.exe` as a child process, exchanging one JSON request line and reading one JSON response line per call, and SHALL locate the binary inside the installed package with a development fallback.

#### Scenario: Core located in the package
- **WHEN** the app runs from its installed MSIX
- **THEN** it finds and launches the bundled `pdflocalcert-core.exe`

#### Scenario: Core returns an error
- **WHEN** the core responds with `{"status":"error",...}`
- **THEN** the shell surfaces the error code and message to the user instead of crashing

### Requirement: Settings and license parity
The Windows shell SHALL provide settings (including the configurable signed-file suffix) and a license/About surface equivalent to the macOS shell, gated by the free/pro tier.

#### Scenario: Configure signed-file suffix
- **WHEN** the user changes the signed-file suffix in settings
- **THEN** newly signed output filenames use that suffix

#### Scenario: Free-tier gating
- **WHEN** a free-tier user exceeds the allowed sign count
- **THEN** the paywall/upgrade surface is shown, matching the macOS behavior

### Requirement: Packaged as a signed MSIX for Windows 10+
The Windows shell SHALL be distributable as an MSIX package that runs on Windows 10 build 17763 and later, bundling the core binary and the Windows App SDK runtime.

#### Scenario: Install and launch on Windows 10
- **WHEN** the MSIX is installed on Windows 10 17763+
- **THEN** the app launches and can open, sign, and verify a PDF without a separate runtime install
