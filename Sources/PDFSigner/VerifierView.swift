import SwiftUI
import UniformTypeIdentifiers

struct VerifierView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            DropZone(prompt: "Arrastra un PDF firmado para verificar", isActive: isDropTargeted) { url in
                Task { await model.verify(url) }
            }
            .frame(minHeight: model.verifierResults.isEmpty ? 380 : 300)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                DropSupport.loadPDF(providers) { url in
                    Task { await model.verify(url) }
                }
            }

            if let err = model.verifierError {
                Label(err, systemImage: "xmark.seal").foregroundStyle(.red)
            }

            ForEach(model.verifierResults) { r in
                ResultCard(result: r)
            }
            Spacer()
        }
        .padding()
    }
}

struct ResultCard: View {
    let result: VerificationDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result.valid ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(result.valid ? .green : .red)
                Text(result.valid ? "Firma válida" : "Firma no válida").bold()
                Spacer()
                Text(result.level).font(.caption).padding(4)
                    .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text("Firmante: \(result.signer)").font(.callout)
            Text("Emisor: \(result.issuer)").font(.caption).foregroundStyle(.secondary)
            Label(result.hasTimestamp ? "Con sello de tiempo" : "Sin sello de tiempo",
                  systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            Text(result.detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
