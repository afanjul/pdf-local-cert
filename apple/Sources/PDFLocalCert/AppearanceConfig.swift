import Foundation

/// User-configurable look of a visible signature box. Persisted as a preset.
struct AppearanceConfig: Codable, Equatable, Sendable {
    var showName = true
    var showReason = false
    var showLocation = false
    var showDate = true
    /// Whether to prefix the name line with `customLabel`.
    var showLabel = false
    /// Label prefixed to the name line when `showLabel` (e.g. "Firmado por:").
    var customLabel = "Firmado por:"
    /// Path to an imported handwritten-signature PNG (transparent), if any.
    var handwrittenImagePath: String?
    var fontSize: Double = 9
    var showBorder = false
    /// Transparent box (straight alpha) vs. opaque white card.
    var transparentBackground = false
    /// Draw a verification QR badge on the right of the box.
    var showQR = false
    /// Word-wrap long lines to fit the box width instead of truncating them.
    var wrapText = false

    static let `default` = AppearanceConfig()

    // Resilient decoding: any key missing from an older saved preset falls back
    // to the default above (synthesized Codable would otherwise throw and drop
    // all presets when a new field like showLabel is added).
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceConfig()
        showName = try c.decodeIfPresent(Bool.self, forKey: .showName) ?? d.showName
        showReason = try c.decodeIfPresent(Bool.self, forKey: .showReason) ?? d.showReason
        showLocation = try c.decodeIfPresent(Bool.self, forKey: .showLocation) ?? d.showLocation
        showDate = try c.decodeIfPresent(Bool.self, forKey: .showDate) ?? d.showDate
        showLabel = try c.decodeIfPresent(Bool.self, forKey: .showLabel) ?? d.showLabel
        customLabel = try c.decodeIfPresent(String.self, forKey: .customLabel) ?? d.customLabel
        handwrittenImagePath = try c.decodeIfPresent(String.self, forKey: .handwrittenImagePath)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        showBorder = try c.decodeIfPresent(Bool.self, forKey: .showBorder) ?? d.showBorder
        transparentBackground = try c.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? d.transparentBackground
        showQR = try c.decodeIfPresent(Bool.self, forKey: .showQR) ?? d.showQR
        wrapText = try c.decodeIfPresent(Bool.self, forKey: .wrapText) ?? d.wrapText
    }
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
