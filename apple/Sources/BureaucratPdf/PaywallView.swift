import SwiftUI

/// Upgrade sheet shown when a Pro feature is used or the free quota is hit.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    private let buyURL = URL(string: "https://bureaucratpdf.app/pro")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("bureaucrat_pdf_pro", comment: "")).font(.title2).bold()

            VStack(alignment: .leading, spacing: 6) {
                feature(NSLocalizedString("feature_custom_placement", comment: ""))
                feature(NSLocalizedString("feature_appearance", comment: ""))
                feature(NSLocalizedString("feature_presets", comment: ""))
                feature(NSLocalizedString("feature_unlimited", comment: ""))
            }

            if model.license.remainingFreeSigns <= 0 {
                Text(String(format: NSLocalizedString("free_limit_reached", comment: ""), model.license.freeMonthlyLimit))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Link(NSLocalizedString("buy_license", comment: ""), destination: buyURL)
                .buttonStyle(.borderedProminent)

            Divider()

            Text(NSLocalizedString("already_have_license", comment: "")).font(.headline)
            HStack {
                TextField("PDFS-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button(NSLocalizedString("activate", comment: "")) {
                    if model.license.activate(key) { dismiss() }
                    else { error = NSLocalizedString("invalid_license_key", comment: "") }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(NSLocalizedString("close", comment: "")) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func feature(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text)
        }
    }
}
