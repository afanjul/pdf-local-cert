import SwiftUI
import PDFKit
import PDFLocalCertKit
import UniformTypeIdentifiers

/// Dragged from the appearance mini-preview; carries the box aspect (w/h) so the
/// dropped box keeps the preview's proportions. Uses the system `.json` content
/// type so no custom UTType has to be registered in Info.plist (an unregistered
/// `exportedAs:` type silently fails to match, rejecting the drop).
struct SignaturePreviewToken: Codable, Transferable {
    var aspect: CGFloat
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

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
            if let doc = model.pdfDocument {
                HStack(spacing: 12) {
                    if doc.pageCount > 1 {
                        Button {
                            model.placementPage = max(1, model.placementPage - 1)
                        } label: { Image(systemName: "chevron.left") }
                        .disabled(model.placementPage <= 1)
                        .accessibilityLabel(NSLocalizedString("previous_page", comment: ""))

                        Text(String(format: NSLocalizedString("page_x_of_y", comment: ""), model.placementPage, doc.pageCount))
                            .font(.callout).monospacedDigit()

                        Button {
                            model.placementPage = min(doc.pageCount, model.placementPage + 1)
                        } label: { Image(systemName: "chevron.right") }
                        .disabled(model.placementPage >= doc.pageCount)
                        .accessibilityLabel(NSLocalizedString("next_page", comment: ""))
                    }

                    Spacer()
                    if model.visibleSignature {
                        Text(NSLocalizedString("drag_to_draw_signature", comment: ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // Zoom controls (also ⌘/⌃ + scroll over the page).
                    Button { model.adjustZoom(by: -0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(model.zoom <= AppModel.zoomMin)
                        .accessibilityLabel(NSLocalizedString("zoom_out", comment: ""))
                    Button { model.resetZoom() } label: {
                        Text("\(Int(model.zoom * 100))%").font(.callout).monospacedDigit().frame(minWidth: 38)
                    }
                    .help(NSLocalizedString("zoom_reset", comment: ""))
                    .accessibilityLabel("Zoom \(Int(model.zoom * 100)) por ciento. Restablecer")
                    Button { model.adjustZoom(by: 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(model.zoom >= AppModel.zoomMax)
                        .accessibilityLabel(NSLocalizedString("zoom_in", comment: ""))
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
                    // `zoom` scales the fitted width (1.0 = fit-to-width).
                    let margin: CGFloat = 16
                    let fitW = max(0, geo.size.width - margin * 2)
                    let w = fitW * model.zoom
                    let h = d.width > 0 ? w * d.height / d.width : 0
                    ScrollView([.vertical, .horizontal]) {
                        ZStack(alignment: .topLeading) {
                            if let img = pageImage {
                                Image(nsImage: img).resizable().frame(width: w, height: h)
                            } else {
                                Rectangle().fill(.quaternary).frame(width: w, height: h)
                            }
                            if model.visibleSignature {
                                // Screen-px → PDF-points scale (fit-to-width is
                                // uniform). Pass the box in PDF points so the
                                // preview's font/box ratio matches the signed
                                // output exactly; px size drives resolution only.
                                let s = w > 0 ? d.width / w : 1
                                SignatureBoxOverlay(
                                    normalized: $model.placementNormalized,
                                    size: CGSize(width: w, height: h),
                                    preview: { px in
                                        let pdfBox = CGSize(width: px.width * s, height: px.height * s)
                                        return model.appearancePreview(pointSize: pdfBox, pixelSize: px)
                                    })
                                    .frame(width: w, height: h)
                            }
                        }
                        .frame(width: w, height: h)
                        // Drop the sidebar mini-preview here to place the box.
                        // `location` is in this frame's local space (0…w, 0…h).
                        .dropDestination(for: SignaturePreviewToken.self) { tokens, location in
                            guard model.visibleSignature, w > 0, h > 0 else { return false }
                            let aspect = tokens.first?.aspect ?? (200.0 / 60.0)
                            let boxW = w * 0.33
                            let boxH = boxW / max(aspect, 0.1)
                            let x = min(max(0, location.x - boxW / 2), max(0, w - boxW))
                            let y = min(max(0, location.y - boxH / 2), max(0, h - boxH))
                            model.placementNormalized = CGRect(
                                x: x / w, y: y / h, width: boxW / w, height: boxH / h)
                            return true
                        }
                        .shadow(radius: 2)
                        .padding(margin)
                    }
                    .background(ScrollZoomCatcher { delta in model.adjustZoom(by: delta) })
                }
            }
            // Gray document canvas so the margin reads as a gutter, not white padding.
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .animation(.easeInOut(duration: 0.2), value: model.placementNormalized == nil)
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
