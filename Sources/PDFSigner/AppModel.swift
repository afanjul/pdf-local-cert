import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import PDFSignerKit

@MainActor
@Observable
final class AppModel {
    // Document
    var documentURL: URL?
    var pdfDocument: PDFDocument?

    // Visible-signature placement (set by SignaturePlacementView)
    var placementPage: Int = 1                 // 1-based
    var placementNormalized: CGRect?           // fraction of displayed page
    var signAllPages = false                   // replicate the box on every page

    // Certificates
    var identities: [CertificateInfo] = []
    var selectedCert: CertificateInfo?

    // Signing options
    var visibleSignature = false
    var reason = ""
    var location = ""
    var useTimestamp = false
    // Qualified Spanish/EU TSA (ACCV, on the EU Trusted List) so timestamped
    // signatures validate in VALIDe. DigiCert's TSA is not a qualified EU TSA.
    var tsaURL = "http://tss.accv.es:8318/tsa"

    // Visible appearance
    var appearance = AppearanceConfig.default
    var presets: [AppearancePreset] = PresetStore.load()
    private var previewCache: [String: NSImage] = [:]
    /// Per-signature verification token, minted when a QR badge is requested.
    private var verifyToken: String?

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let idx = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[idx].config = appearance
        } else {
            presets.append(AppearancePreset(name: trimmed, config: appearance))
        }
        PresetStore.save(presets)
    }

    func deletePreset(_ preset: AppearancePreset) {
        presets.removeAll { $0.id == preset.id }
        PresetStore.save(presets)
    }

    // Licensing
    let license = LicenseManager()
    var showPaywall = false

    // Batch
    var batchItems: [BatchItem] = []
    var batchRunning = false

    // Status
    var statusMessage = ""
    var isSigning = false
    var lastError: String?

    // Verifier
    var verifierResults: [VerificationDisplay] = []
    var verifierError: String?

    func loadIdentities() {
        identities = IdentityStore.loadIdentities()
        if selectedCert == nil {
            selectedCert = identities.first(where: { !$0.isExpired && $0.canSign }) ?? identities.first
        }
    }

    func openDocument(_ url: URL) {
        documentURL = url
        pdfDocument = PDFDocument(url: url)
        statusMessage = pdfDocument == nil ? "No se pudo abrir el PDF." : ""
    }

    func sign() async {
        guard let url = documentURL else { lastError = SigningError.noDocument.errorDescription; return }
        guard let cert = selectedCert else { lastError = SigningError.noCertificate.errorDescription; return }

        // License gating: free tier allows invisible + default visible only, up
        // to a monthly quota. Custom placement/appearance require Pro.
        if !license.isPro {
            if license.remainingFreeSigns <= 0 { showPaywall = true; return }
            let usesPro = visibleSignature && (placementNormalized != nil || appearance != .default || signAllPages)
            if usesPro { showPaywall = true; return }
        }

        isSigning = true
        lastError = nil
        statusMessage = "Firmando…"

        let req = makeRequest(url: url, cert: cert, doc: pdfDocument, drawn: true)

        do {
            let result = try await Task.detached { try SigningCoordinator.sign(req) }.value
            statusMessage = "Firmado (\(result.padesLevel)). Guardando…"
            try save(result.outputURL)
            license.recordSign()
        } catch {
            lastError = (error as? SigningError)?.errorDescription ?? error.localizedDescription
            statusMessage = ""
        }
        isSigning = false
    }

    /// Resolved values for the appearance (signer name, reason, location, date).
    func previewData() -> AppearanceData {
        let qr = appearance.showQR
            ? "https://verify.pdfsigner.app/v/\(verifyToken ?? "preview")"
            : nil
        return AppearanceData(
            name: selectedCert?.commonName ?? "Nombre Apellidos",
            reason: reason.isEmpty ? nil : reason,
            location: location.isEmpty ? nil : location,
            date: Date(),
            qrPayload: qr)
    }

    /// Cached appearance preview for a given on-screen pixel size. Used both in
    /// the sidebar and as the live fill of the drawn box (preview == output).
    func appearancePreview(pixelSize: CGSize) -> NSImage? {
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let w = Int(pixelSize.width.rounded()), h = Int(pixelSize.height.rounded())
        let data = previewData()
        // Key omits the sub-minute part of the date so the cache actually hits
        // across SwiftUI layout passes (otherwise every render rebuilds the QR).
        let key = "\(w)x\(h)|\(appearance)|\(data.name)|\(data.reason ?? "")|\(data.location ?? "")|\(data.dateString)|\(data.qrPayload ?? "")"
        if let cached = previewCache[key] { return cached }
        let img = AppearanceRenderer.render(
            appearance, data: data,
            pointSize: CGSize(width: w, height: h), scale: 2)?.nsImage
        if let img {
            if previewCache.count > 64 { previewCache.removeAll() }
            previewCache[key] = img
        }
        return img
    }

    /// Build a `SignRequest` for one document, rendering an appearance bitmap
    /// per placement. `drawn` selects the user-drawn box vs. the default
    /// bottom-right box (used by batch). When `signAllPages`, the box is
    /// replicated on every page as one signature with multiple widgets.
    func makeRequest(url: URL, cert: CertificateInfo, doc: PDFDocument?, drawn: Bool) -> SignRequest {
        if appearance.showQR { verifyToken = UUID().uuidString }
        let specs = visibleSignature ? buildPlacementSpecs(doc: doc, drawn: drawn) : []
        return SignRequest(
            pdf: url, cert: cert, visible: visibleSignature, placements: specs,
            reason: reason.isEmpty ? nil : reason,
            location: location.isEmpty ? nil : location,
            signerName: cert.commonName,
            tsaURL: useTimestamp ? tsaURL : nil)
    }

    private func buildPlacementSpecs(doc: PDFDocument?, drawn: Bool) -> [PlacementSpec] {
        guard let doc else {
            // No document handle (shouldn't happen for visible) → single default.
            let p = Self.defaultPlacement(for: nil)
            return [renderSpec(p)]
        }
        let pageIdxs: [Int] = (signAllPages && drawn)
            ? Array(0..<doc.pageCount)
            : [drawn ? placementPage - 1 : 0]
        return pageIdxs.compactMap { idx in
            guard let page = doc.page(at: idx) else { return nil }
            let placement: SignaturePlacement
            if drawn, let n = placementNormalized {
                let r = CoordinateMapper(page: page).userSpaceRect(normalized: n)
                placement = SignaturePlacement(page: idx + 1,
                    x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height))
            } else {
                let b = page.bounds(for: .mediaBox)
                let w = 200.0, h = 60.0, m = 36.0
                placement = SignaturePlacement(page: idx + 1,
                    x: Double(b.width) - w - m, y: m, w: w, h: h)
            }
            return renderSpec(placement)
        }
    }

    /// Appearance rendering mode.
    /// `true`  = OPTION C: send no bitmap; core draws the appearance as crisp
    ///           VECTOR TEXT inside the layered n0/n2/FRM/N model. Acrobat VALID.
    ///           (No image/QR yet — that is Option B.)
    /// `false` = send the rendered appearance bitmap, which core embeds as an
    ///           OPAQUE RGB image (no /SMask) inside the same layered model.
    ///           Acrobat VALID but text is rasterized (blurrier, larger files).
    static let forceVectorTextAppearance = true

    private func renderSpec(_ placement: SignaturePlacement) -> PlacementSpec {
        if Self.forceVectorTextAppearance {
            // OPTION B-2 — vector text + opaque logo/handwriting image + opaque
            // QR badge, plus optional vector border/background, composited in
            // the n2 layer by the core.
            var spec = PlacementSpec(placement: placement, rgba: nil, lines: composeAppearanceLines())
            spec.fontSize = appearance.fontSize
            spec.border = appearance.showBorder
            spec.background = !appearance.transparentBackground
            let pad = 4.0
            let scale: CGFloat = 3
            var images: [PlacedImageSpec] = []
            var leftEdge = pad           // where text starts
            var rightEdge = placement.w - pad  // where text must end

            // Logo / handwritten image on the left (~38% of width).
            if let path = appearance.handwrittenImagePath,
               let r = AppearanceRenderer.rasterizeRGBA(
                   path: path,
                   maxPx: CGSize(width: placement.w * 0.38 * scale, height: (placement.h - 2 * pad) * scale)) {
                let wPt = Double(r.w) / Double(scale)
                let hPt = Double(r.h) / Double(scale)
                images.append(PlacedImageSpec(
                    rgba: r.rgba, pxW: r.w, pxH: r.h,
                    x: pad, y: (placement.h - hPt) / 2, w: wPt, h: hPt))
                leftEdge = pad + wPt + pad
            }

            // QR badge on the right (square), if enabled.
            if appearance.showQR, let payload = previewData().qrPayload,
               let qr = AppearanceRenderer.qrImage(payload) {
                let sidePt = min(placement.h - 2 * pad, placement.w * 0.4)
                let px = max(1, Int(sidePt * scale))
                if let rgba = AppearanceRenderer.rasterizeImageRGBA(qr, pxW: px, pxH: px, sharp: true) {
                    let x = placement.w - pad - sidePt
                    images.append(PlacedImageSpec(
                        rgba: rgba, pxW: px, pxH: px,
                        x: x, y: (placement.h - sidePt) / 2, w: sidePt, h: sidePt))
                    rightEdge = x - pad
                }
            }

            spec.images = images
            spec.textX = leftEdge
            spec.textW = max(0, rightEdge - leftEdge)
            return spec
        }
        guard let render = AppearanceRenderer.render(
            appearance, data: previewData(),
            pointSize: CGSize(width: placement.w, height: placement.h)) else {
            return PlacementSpec(placement: placement, rgba: nil)
        }
        return PlacementSpec(placement: placement, rgba: render.rgba, w: render.width, h: render.height)
    }

    /// STEP 3 — compose the visible-signature text lines from the appearance
    /// config, honoring the user's toggles. Pure text (no image) so the result
    /// stays an Acrobat-valid vector appearance.
    private func composeAppearanceLines() -> [String] {
        let data = previewData()
        var lines: [String] = []
        if appearance.showName {
            let label = appearance.customLabel.trimmingCharacters(in: .whitespaces)
            lines.append(label.isEmpty ? "Firmado por: \(data.name)" : "\(label): \(data.name)")
        }
        if appearance.showDate {
            lines.append("Fecha: \(data.dateString)")
        }
        if appearance.showReason, let r = data.reason {
            lines.append("Motivo: \(r)")
        }
        if appearance.showLocation, let l = data.location {
            lines.append("Lugar: \(l)")
        }
        return lines
    }

    /// Resolve the placement to send to core. Uses the user-drawn rectangle
    /// (mapped from normalized displayed space → PDF user space) when present;
    /// otherwise falls back to the default bottom-right box.
    private func resolvedPlacement() -> SignaturePlacement {
        guard let n = placementNormalized,
              let page = pdfDocument?.page(at: placementPage - 1) else {
            return defaultPlacement()
        }
        let mapper = CoordinateMapper(page: page)
        let r = mapper.userSpaceRect(normalized: n)
        return SignaturePlacement(
            page: placementPage,
            x: Double(r.minX), y: Double(r.minY),
            w: Double(r.width), h: Double(r.height))
    }

    private func defaultPlacement() -> SignaturePlacement { Self.defaultPlacement(for: pdfDocument) }

    /// Default visible-signature box: bottom-right of page 1 (PDF user space).
    static func defaultPlacement(for doc: PDFDocument?) -> SignaturePlacement {
        let bounds = doc?.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let w = 200.0, h = 60.0, margin = 36.0
        return SignaturePlacement(
            page: 1,
            x: Double(bounds.width) - w - margin,
            y: margin,
            w: w, h: h)
    }

    private func save(_ tempOutput: URL) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stem = documentURL?.deletingPathExtension().lastPathComponent ?? "documento"
        panel.nameFieldStringValue = "\(stem)-firmado.pdf"
        guard panel.runModal() == .OK, let dest = panel.url else {
            statusMessage = "Guardado cancelado."
            return
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: tempOutput, to: dest)
        statusMessage = "Guardado en \(dest.lastPathComponent)"
    }

    func verify(_ url: URL) async {
        verifierError = nil
        verifierResults = []
        do {
            let sigs = try await Task.detached { try SigningCoordinator.verify(url) }.value
            verifierResults = sigs
            if verifierResults.isEmpty { verifierError = "Sin firmas." }
        } catch {
            verifierError = (error as? SigningError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct VerificationDisplay: Identifiable, Sendable {
    let id = UUID()
    let valid: Bool
    let signer: String
    let issuer: String
    let level: String
    let hasTimestamp: Bool
    let detail: String

    init(_ dict: [String: Any]) {
        valid = dict["valid"] as? Bool ?? false
        signer = dict["signer_cn"] as? String ?? "(desconocido)"
        issuer = dict["issuer_cn"] as? String ?? "(desconocido)"
        level = dict["pades_level"] as? String ?? "?"
        hasTimestamp = dict["has_timestamp"] as? Bool ?? false
        detail = dict["detail"] as? String ?? ""
    }
}
