import SwiftUI
import UniformTypeIdentifiers

struct VerifierView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            // No outer padding here: DropZone already insets itself by 16, so it
            // matches the Sign tab's drop area. The results below get their own
            // padding instead.
            DropZone(prompt: NSLocalizedString("drag_signed_pdf", comment: ""), isActive: isDropTargeted) { url in
                Task { await model.verify(url) }
            }
            .frame(minHeight: model.verifierResults.isEmpty ? 380 : 300)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                DropSupport.loadPDF(providers) { url in
                    Task { await model.verify(url) }
                }
            }

            VStack(spacing: 16) {
                if let err = model.verifierError {
                    Label(err, systemImage: "xmark.seal").foregroundStyle(.red)
                }

                ForEach(model.verifierResults) { r in
                    ResultCard(result: r)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)

            Spacer()
        }
    }
}

struct ResultCard: View {
    let result: VerificationDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result.valid ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(result.valid ? .green : .red)
                Text(result.valid ? NSLocalizedString("signature_valid", comment: "") : NSLocalizedString("signature_invalid", comment: "")).bold()
                Spacer()
                Text(result.level).font(.caption).padding(4)
                    .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(String(format: NSLocalizedString("signer", comment: ""), result.signer)).font(.callout)
            Text(String(format: NSLocalizedString("issuer", comment: ""), result.issuer)).font(.caption).foregroundStyle(.secondary)
            Label(result.hasTimestamp ? NSLocalizedString("with_timestamp", comment: "") : NSLocalizedString("without_timestamp", comment: ""),
                  systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            Text(result.detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
