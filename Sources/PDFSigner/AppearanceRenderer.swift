import AppKit
import CoreGraphics
import CoreImage

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

        let pad = 6 * scale
        var textRect = CGRect(x: pad, y: pad, width: CGFloat(pxW) - 2 * pad, height: CGFloat(pxH) - 2 * pad)

        // QR badge on the right (square, full height minus padding).
        if config.showQR, let payload = data.qrPayload, !payload.isEmpty,
           let qr = qrImage(payload) {
            let side = min(CGFloat(pxH) - 2 * pad, CGFloat(pxW) * 0.4)
            let qrRect = CGRect(x: CGFloat(pxW) - pad - side, y: (CGFloat(pxH) - side) / 2, width: side, height: side)
            ctx.interpolationQuality = .none
            qr.draw(in: qrRect, from: .zero, operation: .sourceOver, fraction: 1)
            textRect.size.width = qrRect.minX - pad - textRect.minX
        }

        // Handwritten image on the left (preserve aspect).
        if let path = config.handwrittenImagePath,
           let img = NSImage(contentsOfFile: path), img.size.width > 0 {
            let maxW = CGFloat(pxW) * 0.42
            let aspect = img.size.height / img.size.width
            var dw = maxW
            var dh = dw * aspect
            let avail = CGFloat(pxH) - 2 * pad
            if dh > avail { dh = avail; dw = dh / aspect }
            let imgRect = CGRect(x: pad, y: (CGFloat(pxH) - dh) / 2, width: dw, height: dh)
            img.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1)
            let rightEdge = textRect.maxX // preserve any QR reservation
            textRect.origin.x = imgRect.maxX + pad
            textRect.size.width = max(0, rightEdge - textRect.origin.x)
        }

        // Compose text lines.
        var lines: [String] = []
        if !config.customLabel.isEmpty { lines.append(config.customLabel) }
        if config.showName { lines.append(data.name) }
        if config.showReason, let r = data.reason, !r.isEmpty { lines.append("Motivo: \(r)") }
        if config.showLocation, let l = data.location, !l.isEmpty { lines.append("Lugar: \(l)") }
        if config.showDate { lines.append("Fecha: \(data.dateString)") }

        let fontSize = config.fontSize * scale
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: para,
        ]
        let leading = fontSize * 1.25
        let totalH = leading * CGFloat(lines.count)
        // Center the text block vertically, drawn top-down (flipped:false → y up).
        var y = textRect.midY + totalH / 2 - leading
        for line in lines {
            let r = CGRect(x: textRect.minX, y: y, width: textRect.width, height: leading)
            (line as NSString).draw(in: r, withAttributes: attrs)
            y -= leading
        }

        if config.showBorder {
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

    private static let ciContext = CIContext()

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
