import SwiftUI
import AppKit

/// Drop-zone icon (fountain pen signing a PDF beside an inkwell).
///
/// Rendered as two stacked raster layers — **not** a `WKWebView`. A web view
/// registers its internal subviews as AppKit drag destinations asynchronously
/// after the page loads, and those subviews swallow file drops that land "on
/// the icon" before SwiftUI's `.onDrop` ever sees them (the drop cursor would
/// vanish over the artwork). Plain images never become drag destinations, so
/// drops fall straight through to the zone behind them.
///
/// The pen is a separate layer on the same 600×729 canvas as the document, so
/// it stays registered with the artwork. While a drag is active (`isActive`)
/// the pen bobs up and down — lifting out of and dipping back into the inkwell.
///
/// `drop-icon-base.png` (document + inkwell, no pen) and `drop-icon-pen.png`
/// (pen only, transparent elsewhere) are copied into the bundle by
/// `scripts/build.sh`, mirroring how `AppIcon.icns` is handled (SPM resource
/// bundles are not copied into the hand-assembled `.app`, so `Bundle.module`
/// is unavailable).
struct SVGDropIcon: View {
    var isActive: Bool

    var body: some View {
        if let base = Self.base, let pen = Self.pen {
            ZStack {
                Image(nsImage: base)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                Image(nsImage: pen)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // Bob the pen out of the inkwell while a file is dragged
                    // over the zone. The fraction is relative to the layer
                    // height so it scales with the rendered size.
                    .offset(y: isActive ? -0.07 * Self.aspect : 0)
                    .animation(
                        isActive
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.2),
                        value: isActive
                    )
            }
        } else {
            // Fallback if resources are missing (e.g. `swift run` without the
            // assembled bundle): a system glyph keeps the zone usable.
            Image(systemName: "doc.text")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(20)
        }
    }

    // The pen offset is expressed as a fraction of the rendered height. Since
    // the icon is laid out by width (150pt), derive height from the aspect.
    private static let aspect: CGFloat = 150 * 729 / 600

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    private static let base = load("drop-icon-base")
    private static let pen = load("drop-icon-pen")
}
