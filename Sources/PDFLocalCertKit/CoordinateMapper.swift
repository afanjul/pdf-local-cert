import CoreGraphics

/// Geometry bridge between the three coordinate spaces involved in placing a
/// visible signature:
///
///   1. **View space** — SwiftUI/AppKit points over the rendered page, origin
///      top-left, +y downward. What the user actually drags.
///   2. **Normalized displayed space** — fractions 0…1 of the *displayed* page
///      box (after `/Rotate` is applied by the viewer), origin top-left. Stored
///      as a resolution/zoom-independent description of the box.
///   3. **PDF user space** — the unrotated coordinate system `/Rect` lives in:
///      origin bottom-left, +y upward, measured in points, offset by the
///      cropBox origin. This is what the Rust core writes into the annotation.
///
/// The mapper is intentionally free of PDFKit/UI types so the rotation × zoom
/// matrix can be unit-tested with plain values. A `PDFPage` convenience init is
/// provided behind `canImport(PDFKit)` for the app target.
public struct CoordinateMapper: Sendable, Equatable {
    /// The page's cropBox in PDF user space (origin may be non-zero).
    public let cropBox: CGRect
    /// `/Rotate` value, normalized to one of 0, 90, 180, 270.
    public let rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        self.rotation = ((rotation % 360) + 360) % 360
    }

    /// Displayed (post-rotation) page size in points.
    public var displayedSize: CGSize {
        switch rotation {
        case 90, 270: return CGSize(width: cropBox.height, height: cropBox.width)
        default: return CGSize(width: cropBox.width, height: cropBox.height)
        }
    }

    // MARK: View ↔ normalized

    /// Convert a rect in view space (origin top-left) into a normalized rect,
    /// given the frame the page occupies in that same view space.
    /// The result is clamped to 0…1 on each axis.
    public func normalize(viewRect: CGRect, in pageFrame: CGRect) -> CGRect {
        guard pageFrame.width > 0, pageFrame.height > 0 else { return .zero }
        let nx = (viewRect.minX - pageFrame.minX) / pageFrame.width
        let ny = (viewRect.minY - pageFrame.minY) / pageFrame.height
        let nw = viewRect.width / pageFrame.width
        let nh = viewRect.height / pageFrame.height
        return clamp01(CGRect(x: nx, y: ny, width: nw, height: nh))
    }

    /// Inverse of `normalize` — place a normalized rect back into a view frame.
    public func viewRect(normalized n: CGRect, in pageFrame: CGRect) -> CGRect {
        CGRect(
            x: pageFrame.minX + n.minX * pageFrame.width,
            y: pageFrame.minY + n.minY * pageFrame.height,
            width: n.width * pageFrame.width,
            height: n.height * pageFrame.height)
    }

    // MARK: Normalized ↔ PDF user space

    /// Map a normalized displayed rect (origin top-left) to a PDF user-space
    /// rect (origin bottom-left, unrotated, cropBox-offset) for `/Rect`.
    public func userSpaceRect(normalized n: CGRect) -> CGRect {
        let d = displayedSize
        // Normalized (top-left) → displayed points (bottom-left origin).
        let dx = n.minX * d.width
        let dw = n.width * d.width
        let dh = n.height * d.height
        let dy = d.height - (n.minY * d.height) - dh // flip y
        // The two opposite corners of the box in displayed space.
        let c0 = displayedToLocal(CGPoint(x: dx, y: dy))
        let c1 = displayedToLocal(CGPoint(x: dx + dw, y: dy + dh))
        let minX = min(c0.x, c1.x), minY = min(c0.y, c1.y)
        let maxX = max(c0.x, c1.x), maxY = max(c0.y, c1.y)
        return CGRect(
            x: cropBox.minX + minX,
            y: cropBox.minY + minY,
            width: maxX - minX,
            height: maxY - minY)
    }

    /// Inverse: PDF user-space rect → normalized displayed rect (top-left).
    public func normalizedRect(userSpace r: CGRect) -> CGRect {
        let local0 = CGPoint(x: r.minX - cropBox.minX, y: r.minY - cropBox.minY)
        let local1 = CGPoint(x: r.maxX - cropBox.minX, y: r.maxY - cropBox.minY)
        let d0 = localToDisplayed(local0)
        let d1 = localToDisplayed(local1)
        let dminX = min(d0.x, d1.x), dmaxX = max(d0.x, d1.x)
        let dminY = min(d0.y, d1.y), dmaxY = max(d0.y, d1.y)
        let d = displayedSize
        guard d.width > 0, d.height > 0 else { return .zero }
        let nx = dminX / d.width
        let nw = (dmaxX - dminX) / d.width
        let nh = (dmaxY - dminY) / d.height
        // Flip y back to top-left origin.
        let ny = 1.0 - (dmaxY / d.height)
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    // MARK: Rotation core (page-local, bottom-left origin, both unrotated px,py)

    /// Displayed-space point (bottom-left origin) → page-local point
    /// (unrotated cropBox-local, bottom-left origin).
    private func displayedToLocal(_ p: CGPoint) -> CGPoint {
        let w = cropBox.width, h = cropBox.height
        switch rotation {
        case 90:  return CGPoint(x: w - p.y, y: p.x)
        case 180: return CGPoint(x: w - p.x, y: h - p.y)
        case 270: return CGPoint(x: p.y, y: h - p.x)
        default:  return p
        }
    }

    /// Page-local point → displayed-space point (inverse of `displayedToLocal`).
    private func localToDisplayed(_ p: CGPoint) -> CGPoint {
        let w = cropBox.width, h = cropBox.height
        switch rotation {
        case 90:  return CGPoint(x: p.y, y: w - p.x)
        case 180: return CGPoint(x: w - p.x, y: h - p.y)
        case 270: return CGPoint(x: h - p.y, y: p.x)
        default:  return p
        }
    }

    private func clamp01(_ r: CGRect) -> CGRect {
        let x = max(0, min(1, r.minX))
        let y = max(0, min(1, r.minY))
        let w = max(0, min(1 - x, r.width))
        let h = max(0, min(1 - y, r.height))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
