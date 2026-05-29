import Foundation
import Security

/// Minimal Keychain generic-password store for the license token. 🔒
enum LicenseKeychain {
    private static let service = "com.palbin.pdfsigner.license"
    private static let account = "license-key"

    static func read() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String) {
        let data = Data(key.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }
}

/// License + free-tier metering. Pro is unlocked by a valid offline license
/// token (stored in the Keychain). The token issuance/Stripe flow lives on the
/// server side (not bundled); `validate(_:)` is the single seam to plug it in.
@MainActor
@Observable
final class LicenseManager {
    enum Tier: String { case free, pro }

    private(set) var tier: Tier = .free
    private(set) var monthlyCount: Int = 0

    /// Free tier: number of signatures per calendar month.
    let freeMonthlyLimit = 10

    private let defaults = UserDefaults.standard

    init() {
        if let key = LicenseKeychain.read(), Self.validate(key) {
            tier = .pro
        }
        monthlyCount = defaults.integer(forKey: countKey())
    }

    var isPro: Bool { tier == .pro }
    var remainingFreeSigns: Int { max(0, freeMonthlyLimit - monthlyCount) }

    /// Offline token check. A real deployment verifies a signed token against an
    /// embedded public key + expiry/grace; here we accept the documented format
    /// `PDFS-XXXX-XXXX-XXXX` so the gating/UI is exercised end-to-end.
    static func validate(_ key: String) -> Bool {
        let parts = key.uppercased().split(separator: "-")
        return parts.count == 4 && parts[0] == "PDFS" && parts.dropFirst().allSatisfy { $0.count == 4 }
    }

    @discardableResult
    func activate(_ key: String) -> Bool {
        guard Self.validate(key) else { return false }
        LicenseKeychain.write(key)
        tier = .pro
        return true
    }

    func deactivate() {
        LicenseKeychain.clear()
        tier = .free
    }

    /// Record one successful signature against the monthly free quota.
    func recordSign() {
        guard !isPro else { return }
        monthlyCount += 1
        defaults.set(monthlyCount, forKey: countKey())
    }

    private func countKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "signCount-\(c.year ?? 0)-\(c.month ?? 0)"
    }
}
