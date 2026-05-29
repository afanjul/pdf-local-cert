import AppKit
import CoreGraphics
import CoreImage

/// Single source of truth for visible-signature composition — the text lines
/// and the box-local sub-rects (logo, QR, text). BOTH the on-screen preview
/// and the signed output derive from this, so what you see is what you sign.
///
/// All rects are in box-local PDF points, origin bottom-left (matching the
/// core's coordinate system).
struct SignatureLayout {
    var lines: [String]
    var fontSize: Double
    var leading: Double
    var textRect: CGRect
    var logoRect: CGRect?
    var qrRect: CGRect?
    var border: Bool
    var background: Bool
}

enum SignatureComposer {
    static let pad = 4.0
    static let logoFraction = 0.38
    static let qrFraction = 0.40

    /// The text lines, honoring the config toggles. This is THE composition
    /// used by both preview and output (no second copy).
    static func lines(_ config: AppearanceConfig, _ data: AppearanceData) -> [String] {
        var lines: [String] = []
        if config.showName {
            let label = config.customLabel.trimmingCharacters(in: .whitespaces)
            if config.showLabel && !label.isEmpty {
                // Join with a single space; the label already carries its own
                // trailing colon if the user wants one (default "Firmado por:").
                lines.append("\(label) \(data.name)")
            } else {
                lines.append(data.name)
            }
        }
        if config.showDate { lines.append("Fecha: \(data.dateString)") }
        if config.showReason, let r = data.reason, !r.isEmpty { lines.append("Motivo: \(r)") }
        if config.showLocation, let l = data.location, !l.isEmpty { lines.append("Lugar: \(l)") }
        return lines
    }

    /// Compute the full layout for a box of `box` points. `logoAspect` is the
    /// logo image's height/width (nil = no logo); `hasQR` reserves the right
    /// square. Font leading matches the core (`fontSize + 2`).
    static func layout(config: AppearanceConfig, data: AppearanceData,
                       box: CGSize, logoAspect: Double?, hasQR: Bool) -> SignatureLayout {
        var left = pad
        var right = Double(box.width) - pad
        var logoRect: CGRect? = nil
        var qrRect: CGRect? = nil

        if let aspect = logoAspect, aspect > 0 {
            let maxW = Double(box.width) * logoFraction
            let avail = Double(box.height) - 2 * pad
            var w = maxW
            var h = w * aspect
            if h > avail { h = avail; w = h / aspect }
            logoRect = CGRect(x: pad, y: (Double(box.height) - h) / 2, width: w, height: h)
            left = pad + w + pad
        }
        if hasQR {
            let side = min(Double(box.height) - 2 * pad, Double(box.width) * qrFraction)
            let x = Double(box.width) - pad - side
            qrRect = CGRect(x: x, y: (Double(box.height) - side) / 2, width: side, height: side)
            right = x - pad
        }
        let textRect = CGRect(x: left, y: pad,
                              width: max(0, right - left), height: Double(box.height) - 2 * pad)
        let size = config.fontSize > 0 ? config.fontSize : 9
        return SignatureLayout(
            lines: lines(config, data), fontSize: size, leading: size + 2,
            textRect: textRect, logoRect: logoRect, qrRect: qrRect,
            border: config.showBorder, background: !config.transparentBackground)
    }

    /// height/width of an image file, or nil if it can't be read.
    static func imageAspect(path: String?) -> Double? {
        guard let path, let img = NSImage(contentsOfFile: path),
              img.size.width > 0, img.size.height > 0 else { return nil }
        return Double(img.size.height / img.size.width)
    }
}

/// Renders an `AppearanceConfig` to a bitmap. The SAME render feeds both the
/// on-screen preview (`nsImage`) and the bytes embedded by the core
/// (`rgba`, straight-alpha RGBA8, top row first) — so preview == output.
struct AppearanceRender {
    let nsImage: NSImage
    let rgba: Data
    let width: Int
    let height: Int
}

enum AppearanceRenderer {
    /// `pointSize` is the box size in PDF points; `scale` oversamples for crispness.
    static func render(_ config: AppearanceConfig, data: AppearanceData,
                       pointSize: CGSize, scale: CGFloat = 3) -> AppearanceRender? {
        let pxW = max(1, Int((pointSize.width * scale).rounded()))
        let pxH = max(1, Int((pointSize.height * scale).rounded()))
        let bytesPerRow = pxW * 4
        var buf = [UInt8](repeating: 0, count: pxH * bytesPerRow)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = buf.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: pxW, height: pxH,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        if !config.transparentBackground {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        }

        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        // Shared layout (same lines + geometry the signed output uses).
        let aspect = SignatureComposer.imageAspect(path: config.handwrittenImagePath)
        let hasQR = config.showQR && (data.qrPayload?.isEmpty == false)
        let layout = SignatureComposer.layout(
            config: config, data: data, box: pointSize, logoAspect: aspect, hasQR: hasQR)
        // Box-local points → pixels.
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        }

        // Logo / handwritten image (left).
        if let lr = layout.logoRect, let path = config.handwrittenImagePath,
           let img = NSImage(contentsOfFile: path) {
            img.draw(in: px(lr), from: .zero, operation: .sourceOver, fraction: 1)
        }
        // QR badge (right).
        if let qr = layout.qrRect, let payload = data.qrPayload, let qrImg = qrImage(payload) {
            ctx.interpolationQuality = .none
            qrImg.draw(in: px(qr), from: .zero, operation: .sourceOver, fraction: 1)
        }

        // Text — Helvetica (same family as the signed output), top-down,
        // vertically centered over the FULL box height (matches the core).
        let fontSizePx = layout.fontSize * Double(scale)
        let leadingPx = layout.leading * Double(scale)
        let font = NSFont(name: "Helvetica", size: fontSizePx) ?? .systemFont(ofSize: fontSizePx)
        let tr = px(layout.textRect)
        // When wrapping, expand each logical line into physical rows that fit
        // tr.width (mirrors the core's word-wrap); otherwise truncate per line.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = config.wrapText ? .byWordWrapping : .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: para,
        ]
        let rows: [String] = config.wrapText
            ? layout.lines.flatMap { Self.wrapRows($0, font: font, maxWidth: tr.width) }
            : layout.lines
        let total = leadingPx * Double(rows.count)
        // First line top, centered over the whole box (pxH), drawn downward.
        var y = (Double(pxH) + total) / 2 - leadingPx
        for line in rows {
            let r = CGRect(x: tr.minX, y: y, width: tr.width, height: leadingPx)
            (line as NSString).draw(in: r, withAttributes: attrs)
            y -= leadingPx
        }

        if layout.border {
            ctx.setStrokeColor(NSColor.gray.cgColor)
            ctx.setLineWidth(scale)
            ctx.stroke(CGRect(x: scale / 2, y: scale / 2, width: CGFloat(pxW) - scale, height: CGFloat(pxH) - scale))
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: pxW, height: pxH))

        // Unpremultiply to straight alpha for PDF /SMask.
        var out = buf
        var i = 0
        while i < out.count {
            let a = out[i + 3]
            if a > 0 && a < 255 {
                out[i]     = UInt8(min(255, Int(out[i])     * 255 / Int(a)))
                out[i + 1] = UInt8(min(255, Int(out[i + 1]) * 255 / Int(a)))
                out[i + 2] = UInt8(min(255, Int(out[i + 2]) * 255 / Int(a)))
            }
            i += 4
        }
        return AppearanceRender(nsImage: nsImage, rgba: Data(out), width: pxW, height: pxH)
    }

    /// Word-wrap `line` into physical rows that each fit `maxWidth` px at `font`,
    /// mirroring the core's wrap_to_width (split on spaces; hard-break a word
    /// that is itself wider than maxWidth). Pixel-space measurement.
    static func wrapRows(_ line: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        func w(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        if maxWidth <= 0 || w(line) <= maxWidth { return [line] }
        var rows: [String] = []
        var cur = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = cur.isEmpty ? word : cur + " " + word
            if w(candidate) <= maxWidth { cur = candidate; continue }
            if !cur.isEmpty { rows.append(cur); cur = "" }
            if w(word) <= maxWidth {
                cur = word
            } else {
                var piece = ""
                for c in word {
                    let trial = piece + String(c)
                    if w(trial) > maxWidth && !piece.isEmpty { rows.append(piece); piece = "" }
                    piece.append(c)
                }
                cur = piece
            }
        }
        if !cur.isEmpty { rows.append(cur) }
        return rows.isEmpty ? [""] : rows
    }

    private static let ciContext = CIContext()

    /// Rasterize an image file to straight-alpha RGBA8 (rows top-to-bottom),
    /// scaled to fit `maxPx` while preserving aspect. Returns the buffer and its
    /// pixel size. Used to embed a logo/handwriting as an opaque image layer.
    static func rasterizeRGBA(path: String, maxPx: CGSize) -> (rgba: Data, w: Int, h: Int)? {
        guard let img = NSImage(contentsOfFile: path), img.size.width > 0, img.size.height > 0 else {
            return nil
        }
        let aspect = img.size.height / img.size.width
        var w = maxPx.width
        var h = w * aspect
        if h > maxPx.height { h = maxPx.height; w = h / aspect }
        let pxW = max(1, Int(w.rounded()))
        let pxH = max(1, Int(h.rounded()))
        guard let rgba = rasterizeImageRGBA(img, pxW: pxW, pxH: pxH, sharp: false) else { return nil }
        return (rgba, pxW, pxH)
    }

    /// Rasterize an `NSImage` to straight-alpha RGBA8 (rows top-to-bottom) at an
    /// exact pixel size. `sharp` disables interpolation (for QR codes). The
    /// buffer orientation matches `render()` so the core embeds it upright.
    static func rasterizeImageRGBA(_ img: NSImage, pxW: Int, pxH: Int, sharp: Bool) -> Data? {
        let bytesPerRow = pxW * 4
        var buf = [UInt8](repeating: 0, count: pxH * bytesPerRow)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = buf.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: pxW, height: pxH,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        if sharp { ctx.interpolationQuality = .none }
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        img.draw(in: CGRect(x: 0, y: 0, width: pxW, height: pxH),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // Match AppearanceRenderer.render exactly: the core draws this buffer
        // with a positive-height matrix and it comes out upright, so do NOT
        // flip here — just unpremultiply to straight alpha.
        var out = buf
        var i = 0
        while i < out.count {
            let a = out[i + 3]
            if a > 0 && a < 255 {
                out[i]     = UInt8(min(255, Int(out[i])     * 255 / Int(a)))
                out[i + 1] = UInt8(min(255, Int(out[i + 1]) * 255 / Int(a)))
                out[i + 2] = UInt8(min(255, Int(out[i + 2]) * 255 / Int(a)))
            }
            i += 4
        }
        return Data(out)
    }

    /// Generate a crisp QR code NSImage for `payload`.
    static func qrImage(_ payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        guard let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
