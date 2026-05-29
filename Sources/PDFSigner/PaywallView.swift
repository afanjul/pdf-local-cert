import SwiftUI

/// Upgrade sheet shown when a Pro feature is used or the free quota is hit.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    private let buyURL = URL(string: "https://pdfsigner.app/pro")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PDF-Signer Pro").font(.title2).bold()

            VStack(alignment: .leading, spacing: 6) {
                feature("Coloca la firma donde quieras (caja a medida)")
                feature("Apariencia configurable + imagen manuscrita")
                feature("Ajustes preestablecidos")
                feature("Firmas ilimitadas")
            }

            if model.license.remainingFreeSigns <= 0 {
                Text("Has alcanzado el límite gratuito de \(model.license.freeMonthlyLimit) firmas este mes.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Link("Comprar licencia…", destination: buyURL)
                .buttonStyle(.borderedProminent)

            Divider()

            Text("¿Ya tienes licencia?").font(.headline)
            HStack {
                TextField("PDFS-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Activar") {
                    if model.license.activate(key) { dismiss() }
                    else { error = "Clave de licencia no válida." }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
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
