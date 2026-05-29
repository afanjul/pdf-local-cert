import SwiftUI
import PDFKit
import PDFSignerKit

extension CoordinateMapper {
    /// Build a mapper from a live PDFKit page (cropBox + `/Rotate`).
    init(page: PDFPage) {
        self.init(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }
}

/// Page picker + draw surface for placing the visible signature box.
/// The target page is rendered (rotation already baked in by PDFKit), and the
/// user drags / resizes a rectangle over it. The drawn rect is stored as a
/// normalized fraction of the *displayed* page in `AppModel.placementNormalized`.
struct SignaturePlacementView: View {
    @Environment(AppModel.self) private var model
    @State private var pageImage: NSImage?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let doc = model.pdfDocument, doc.pageCount > 1 {
                HStack(spacing: 12) {
                    Button {
                        model.placementPage = max(1, model.placementPage - 1)
                    } label: { Image(systemName: "chevron.left") }
                    .disabled(model.placementPage <= 1)

                    Text("Página \(model.placementPage) de \(doc.pageCount)")
                        .font(.callout).monospacedDigit()

                    Button {
                        model.placementPage = min(doc.pageCount, model.placementPage + 1)
                    } label: { Image(systemName: "chevron.right") }
                    .disabled(model.placementPage >= doc.pageCount)

                    Spacer()
                    if model.visibleSignature {
                        Text("Arrastra para dibujar la firma")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                Divider()
            }

            GeometryReader { geo in
                if let page = model.pdfDocument?.page(at: model.placementPage - 1) {
                    let mapper = CoordinateMapper(page: page)
                    let d = mapper.displayedSize
                    // Fit to width (like PDFView) so toggling the visible signature
                    // doesn't change the page scale; scroll vertically if taller.
                    // Keep a small margin to frame the page (matches PDFView).
                    let margin: CGFloat = 16
                    let w = max(0, geo.size.width - margin * 2)
                    let h = d.width > 0 ? w * d.height / d.width : 0
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            if let img = pageImage {
                                Image(nsImage: img).resizable().frame(width: w, height: h)
                            } else {
                                Rectangle().fill(.quaternary).frame(width: w, height: h)
                            }
                            if model.visibleSignature {
                                SignatureBoxOverlay(
                                    normalized: $model.placementNormalized,
                                    size: CGSize(width: w, height: h),
                                    preview: { px in model.appearancePreview(pixelSize: px) })
                                    .frame(width: w, height: h)
                            }
                        }
                        .frame(width: w, height: h)
                        .shadow(radius: 2)
                        .padding(margin)
                    }
                }
            }
            // Gray document canvas so the margin reads as a gutter, not white padding.
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear { renderPage() }
        .onChange(of: model.placementPage) { _, _ in
            model.placementNormalized = nil
            renderPage()
        }
        .onChange(of: model.documentURL) { _, _ in
            model.placementPage = 1
            model.placementNormalized = nil
            renderPage()
        }
    }

    private func renderPage() {
        guard let page = model.pdfDocument?.page(at: model.placementPage - 1) else {
            pageImage = nil; return
        }
        let mapper = CoordinateMapper(page: page)
        let d = mapper.displayedSize
        // Render at 2× for crispness, capped so huge pages don't blow memory.
        let scale = min(2.0, 1600.0 / max(d.width, d.height, 1))
        let size = CGSize(width: d.width * scale, height: d.height * scale)
        pageImage = page.thumbnail(of: size, for: .cropBox)
    }
}

/// Draws and edits a single normalized rectangle over a page-sized surface.
/// Local coordinates run 0…`size`; `normalized` is the fraction of that size.
struct SignatureBoxOverlay: View {
    @Binding var normalized: CGRect?
    let size: CGSize
    var preview: ((CGSize) -> NSImage?)? = nil

    private let minSizePt: CGFloat = 24
    private let handle: CGFloat = 12

    /// Action chosen at drag start, plus the rect we started from.
    private enum Mode { case draw, move, resize(Corner) }
    @State private var mode: Mode?
    @State private var startRect: CGRect = .zero
    /// In-progress rect (local pixels) during a drag. Local @State so a drag
    /// doesn't write the @Observable model every tick (would re-render the whole
    /// page view → flicker). Committed once on .onEnded.
    @State private var liveRect: CGRect?

    /// The rect to display: the live in-progress one if dragging, else the model's.
    private var currentRect: CGRect? {
        if let l = liveRect { return l }
        if let n = normalized { return denorm(n) }
        return nil
    }

    var body: some View {
        // One stable gesture surface for the whole canvas. The visuals on top are
        // non-interactive, so re-rendering the preview image never resets the
        // gesture's hit-testing (which caused the stutter / "sometimes works").
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) { visuals.allowsHitTesting(false) }
            .gesture(unifiedGesture)
    }

    @ViewBuilder private var visuals: some View {
        if let r = currentRect {
            ZStack(alignment: .topLeading) {
                Group {
                    if let img = preview?(CGSize(width: r.width, height: r.height)) {
                        Image(nsImage: img).resizable()
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    } else {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    }
                }
                .frame(width: r.width, height: r.height)
                // Corner handles in local (box) space.
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle().fill(Color.accentColor)
                        .frame(width: handle, height: handle)
                        .position(corner.point(in: CGRect(origin: .zero, size: r.size)))
                }
            }
            .offset(x: r.minX, y: r.minY)
        }
    }

    // MARK: unified gesture

    private var unifiedGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if mode == nil { begin(at: v.startLocation) }
                apply(translation: v.translation)
            }
            .onEnded { _ in
                // Discard an accidental click / tiny draw (0×0 box). Move/resize
                // of an existing box always commit, even with no movement.
                if case .draw = mode, let r = liveRect,
                   r.width < minSizePt || r.height < minSizePt {
                    // ignore — leaves any existing box untouched
                } else if let r = liveRect {
                    normalized = norm(r)
                }
                liveRect = nil
                mode = nil
            }
    }

    /// Decide what the drag does, based on where it started.
    private func begin(at p: CGPoint) {
        if let n = normalized {
            let r = denorm(n)
            // Near a corner handle? → resize that corner.
            for corner in Corner.allCases where corner.point(in: r).distance(to: p) <= handle * 1.6 {
                mode = .resize(corner); startRect = r; return
            }
            if r.insetBy(dx: -2, dy: -2).contains(p) { mode = .move; startRect = r; return }
        }
        mode = .draw; startRect = CGRect(origin: p, size: .zero)
    }

    private func apply(translation t: CGSize) {
        guard let mode else { return }
        switch mode {
        case .draw:
            let end = CGPoint(x: startRect.origin.x + t.width, y: startRect.origin.y + t.height)
            liveRect = clampToBounds(rectBetween(startRect.origin, end))
        case .move:
            var r = startRect.offsetBy(dx: t.width, dy: t.height)
            r.origin.x = max(0, min(size.width - r.width, r.origin.x))
            r.origin.y = max(0, min(size.height - r.height, r.origin.y))
            liveRect = r
        case .resize(let corner):
            let fixed = corner.opposite.point(in: startRect)
            let moving = CGPoint(x: corner.point(in: startRect).x + t.width,
                                 y: corner.point(in: startRect).y + t.height)
            var r = rectBetween(fixed, moving)
            if r.width < minSizePt { r.size.width = minSizePt }
            if r.height < minSizePt { r.size.height = minSizePt }
            liveRect = clampToBounds(r)
        }
    }

    // MARK: helpers

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clampToBounds(_ r: CGRect) -> CGRect {
        let x = max(0, min(size.width, r.minX))
        let y = max(0, min(size.height, r.minY))
        let mx = max(0, min(size.width, r.maxX))
        let my = max(0, min(size.height, r.maxY))
        return CGRect(x: x, y: y, width: mx - x, height: my - y)
    }

    private func denorm(_ n: CGRect) -> CGRect {
        CGRect(x: n.minX * size.width, y: n.minY * size.height,
               width: n.width * size.width, height: n.height * size.height)
    }

    private func norm(_ r: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: r.minX / size.width, y: r.minY / size.height,
                      width: r.width / size.width, height: r.height / size.height)
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
        var opposite: Corner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }
    }
}

private extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat {
        hypot(x - p.x, y - p.y)
    }
}
