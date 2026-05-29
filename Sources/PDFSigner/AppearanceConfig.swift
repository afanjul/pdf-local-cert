import Foundation

/// User-configurable look of a visible signature box. Persisted as a preset.
struct AppearanceConfig: Codable, Equatable, Sendable {
    var showName = true
    var showReason = false
    var showLocation = false
    var showDate = true
    /// Optional label drawn on the first line (e.g. "Firmado digitalmente por").
    var customLabel = ""
    /// Path to an imported handwritten-signature PNG (transparent), if any.
    var handwrittenImagePath: String?
    var fontSize: Double = 9
    var showBorder = false
    /// Transparent box (straight alpha) vs. opaque white card.
    var transparentBackground = false
    /// Draw a verification QR badge on the right of the box.
    var showQR = false

    static let `default` = AppearanceConfig()
}

/// Values resolved at sign time and merged into the appearance.
struct AppearanceData: Equatable, Sendable {
    var name: String
    var reason: String?
    var location: String?
    var date: Date
    /// Verification URL encoded into the QR badge (when `showQR`).
    var qrPayload: String?

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: date)
    }
}
