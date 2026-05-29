import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.sign

    enum Tab { case sign, batch, verify }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("", selection: $tab) {
                    Text("Firmar").tag(Tab.sign)
                    Text("Lote").tag(Tab.batch)
                    Text("Verificar").tag(Tab.verify)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                } 
                .help("Preferencias")
                .padding(.trailing, 8)
            }
            .padding(8)

            Divider()

            switch tab {
            case .sign: SignTab()
            case .batch: BatchView()
            case .verify: VerifierView()
            }
        }
        .task { model.loadIdentities() }
    }
}

struct SignTab: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        HSplitView {
            // PDF area / drop zone
            Group {
                if model.pdfDocument != nil {
                    // Same view for visible/invisible so the page never shifts
                    // scale; the draw overlay only appears for visible signatures.
                    SignaturePlacementView()
                } else {
                    DropZone(prompt: "Arrastra un PDF aquí", isActive: isDropTargeted) { url in
                        model.openDocument(url)
                    }
                }
            }
            .frame(minWidth: 480)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                DropSupport.loadPDF(providers) { url in model.openDocument(url) }
            }

            // Sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Certificado").font(.headline)
                    if model.identities.isEmpty {
                        Text("No se encontraron certificados en el Llavero.")
                            .foregroundStyle(.secondary).font(.callout)
                    } else {
                        Picker("Certificado", selection: $model.selectedCert) {
                            ForEach(model.identities) { cert in
                                Text(label(cert)).tag(Optional(cert))
                            }
                        }
                        .labelsHidden()
                        if let c = model.selectedCert {
                            CertDetail(cert: c)
                        }
                    }

                    Divider()

                    Toggle("Firma visible", isOn: $model.visibleSignature)
                    Text("Además de firmar el documento, te permite hacer tu firma visible.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.visibleSignature {
                        AppearanceEditorView()
                        Toggle("Firmar en todas las páginas", isOn: $model.signAllPages)
                    }

                    Divider()

                    Toggle("Sello de tiempo (B-T)", isOn: $model.useTimestamp)
                    Text("Certifica que el documento existía tal como está en este momento exacto.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.useTimestamp {
                        TextField("URL TSA", text: $model.tsaURL)
                            .font(.caption).textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    Button {
                        Task { await model.sign() }
                    } label: {
                        HStack {
                            if model.isSigning { ProgressView().controlSize(.small) }
                            Text("Firmar y guardar")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.documentURL == nil || model.selectedCert == nil || model.isSigning)

                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    if let err = model.lastError {
                        Text(err).font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                    LicenseFooter()
                }
                .padding()
            }
            .frame(minWidth: 280, maxWidth: 360)
        }
        .sheet(isPresented: $model.showPaywall) { PaywallView() }
    }

    private func label(_ c: CertificateInfo) -> String {
        c.isExpired ? "\(c.commonName) — caducado" : c.commonName
    }

}

struct LicenseFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Divider()
        if model.license.isPro {
            Label("Pro", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            HStack {
                Text("Gratis · \(model.license.remainingFreeSigns)/\(model.license.freeMonthlyLimit) firmas")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Pro") { model.showPaywall = true }
                    .font(.caption)
            }
        }
    }
}

struct CertDetail: View {
    let cert: CertificateInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cert.commonName).font(.callout).bold()
            Text("Emisor: \(cert.issuer)").font(.caption).foregroundStyle(.secondary)
            if let exp = cert.notAfter {
                Text("Validez: \(exp.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(cert.isExpired ? .red : .secondary)
            }
            if !cert.canSign {
                Text("Sin uso de firma").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct DropZone: View {
    let prompt: String
    var isActive: Bool = false
    let onDrop: (URL) -> Void
    @State private var picking = false

    var body: some View {
        VStack(spacing: 16) {
            SVGDropIcon(isActive: isActive)
                .frame(width: 150, height: 165)
                .allowsHitTesting(false) // drops fall through to the zone behind
            Text(prompt)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Abrir…") { pick() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isActive ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isActive ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 1.5, dash: [8, 6])
                )
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .contentShape(Rectangle()) // whole area is the drop/click target
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onDrop(url) }
    }
}
