# Design — macOS → WinUI UI/UX/feature parity

Goal: the Windows (WinUI 3) shell delivers the **same features, user flows, and
UX** as the macOS app — same sections, same options, same sign/verify/batch
processes — rendered in idiomatic Fluent Design. The shared Rust core is already
identical across platforms; this is a **shell-only** effort plus a small protocol
field extension for the rich appearance.

Decisions (locked):

- **Phased, UI-first.** Ship shell → sign → appearance(text) → batch → verify →
  preferences → full appearance(logo/QR). Each phase is independently testable.
- **CommunityToolkit.Mvvm, one shared `AppViewModel`** mirroring macOS `AppModel`
  as the single source of truth; all views `x:Bind` to it. This is explicitly to
  prevent the per-file state drift that hid the earlier placement bug.

## Reference: the macOS app (source of truth)

`apple/Sources/PDFLocalCert/`:

- `ContentView` — toolbar `Segmented` **Sign / Batch / Verify**; "New" + Preferences.
- `SignTab` — `HSplitView`: PDF/drop-zone left, options sidebar right.
- `AppModel` — observable state + `sign()`, `verify()`, `runBatch()`, request build,
  license gating, appearance preview cache.
- `AppearanceEditorView` / `AppearanceConfig` — single-open accordions
  (Content / Image / Style) + live preview + drag-preview-to-place + `PresetBar`.
- `Batch` — queue model + `BatchView` list with status icons.
- `VerifierViewB` — multi-file verify queue, expandable rows, filters.
- `PreferencesView` — tabbed General (theme/language/suffix) / License / About.
- `LicenseManager` — free monthly quota + Pro; Pro gates custom placement,
  custom appearance, sign-all-pages, QR, batch.

## Gap analysis (macOS has → Windows current)

| Area | macOS | Windows now | Task |
|---|---|---|---|
| Section nav | Segmented Sign/Batch/Verify | Sign only; Verify=dialog | 7.0.3 |
| Empty state | drop zone + drag-drop + Open | Open button only | 7.1.1 |
| Sign sidebar | cert + detail/warnings, toggles, inline sign + status | partial (combo + detail) | 7.1.2 |
| TSA default | ACCV qualified | DigiCert (non-qualified) | 7.1.3 |
| Sign all pages | toggle | — | 7.1.4 |
| Zoom | 1–4× + reset | ScrollViewer zoom only | 7.1.5 |
| Appearance | accordions + preview + presets | — | 7.2.* |
| Batch | full queue | — | 7.3.* |
| Verify | multi-file queue | single-file dialog | 7.4.* |
| Preferences | theme/language/license/about | suffix/license/about only | 7.5.* |
| Pro gating | feature-level | quota-only | 7.6.1 |
| Logo + QR | `PlacedImageSpec` + composer | not plumbed | 7.7.* |

## Protocol boundary (why appearance is last/heaviest)

macOS `PlacementSpec` carries `fontSize, wrap, textX, textW, images[]`
(`PlacedImageSpec` = rgba + px + rect) for logo/QR, with layout from the shared
`SignatureComposer`. Windows `windows/PdfLocalCert.Core/SigningModels.cs`
`PlacementSpec` only has `Page,X,Y,W,H,Lines,Border,Background`. The **same Rust
core** already accepts the richer fields, so 7.7 extends the C# model + the JSON
`SigningService` emits, then ports the composer so preview == embedded output.

## WinUI control mapping (grounded via winui-search)

| Need | macOS | WinUI | Source id |
|---|---|---|---|
| Section switch | segmented `Picker` | `Segmented` (CommunityToolkit) | toolkit-segmented-1 |
| Collapsible options | custom accordion | `Expander`, single-open | gallery-expander-1 |
| Drop zone | `onDrop` + `DropZone` | drag-drop + dashed `Border` | drag-drop-files |
| Batch/verify rows | `List` | `ListView` + status `FontIcon` | — |
| Font size | `Slider` | `Slider` (6–16, step 1) | gallery-slider-1 |
| Preferences | `TabView`/`Form` | `SettingsCard`/`SettingsExpander` | toolkit-settingscard-9 |
| Live preview | `Image(nsImage:)` | `Image` from rendered bitmap | — |

## Layout (Sign tab)

`Grid` `Auto,*,Auto`: command bar (Segmented + New + Preferences) / split
(`*` page-or-dropzone, fixed 320–360 sidebar) / status bar. Sidebar scroll:
Certificate → Visible signature (+ appearance accordions + sign-all) → Timestamp
(+ TSA) → Sign-and-save (inline progress) → status/error. Fluent rules: 4px grid,
`{ThemeResource}` brushes, `SubtitleTextBlockStyle` headers, `CaptionTextBlockStyle`
help text, Light/Dark/HighContrast theme dictionaries.

## Out of scope here

Smartcard/DNIe (6.1), moving CoordinateMapper/license into core (6.2/6.3),
PDFium swap (6.4). Verifier ships the macOS shipping variant (Alt B queue).
