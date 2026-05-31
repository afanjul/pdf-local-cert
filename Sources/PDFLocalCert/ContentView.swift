import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.sign

    enum Tab { case sign, batch, verify }

    var body: some View {
        Group {
            switch tab {
            case .sign: SignTab()
            case .batch: BatchView()
            // Compare the two multi-file verifier UX options: swap to
            // VerifierViewB() to try Alt B (batch list). VerifierView() is the
            // original single-file view.
            case .verify: VerifierViewB()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(NSLocalizedString("section", comment: ""), selection: $tab) {
                    Text(NSLocalizedString("sign", comment: "")).tag(Tab.sign)
                    Text(NSLocalizedString("batch", comment: "")).tag(Tab.batch)
                    Text(NSLocalizedString("verify", comment: "")).tag(Tab.verify)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if tab == .sign, model.pdfDocument != nil {
                    Button {
                        model.clearDocument()
                    } label: {
                        Label(NSLocalizedString("new", comment: ""), systemImage: "doc.badge.plus")
                    }
                    .help(NSLocalizedString("close_pdf_help", comment: ""))
                }
                SettingsLink {
                    Label(NSLocalizedString("preferences", comment: ""), systemImage: "gearshape")
                }
                .help(NSLocalizedString("preferences_help", comment: ""))
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
                    DropZone(prompt: NSLocalizedString("drag_pdf_here", comment: ""), isActive: isDropTargeted) { url in
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
                    Text(NSLocalizedString("certificate", comment: "")).font(.headline)
                    if model.identities.isEmpty {
                        Text(NSLocalizedString("no_certificates_found", comment: ""))
                            .foregroundStyle(.secondary).font(.callout)
                    } else {
                        Picker(NSLocalizedString("certificate", comment: ""), selection: $model.selectedCert) {
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

                    Toggle(NSLocalizedString("visible_signature", comment: ""), isOn: $model.visibleSignature)
                    Text(NSLocalizedString("visible_signature_help", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.visibleSignature {
                        AppearanceEditorView()
                        Toggle(NSLocalizedString("sign_all_pages", comment: ""), isOn: $model.signAllPages)
                    }

                    Divider()

                    Toggle(NSLocalizedString("timestamp", comment: ""), isOn: $model.useTimestamp)
                    Text(NSLocalizedString("timestamp_help", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.useTimestamp {
                        TextField(NSLocalizedString("tsa_url", comment: ""), text: $model.tsaURL)
                            .font(.caption).textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    Button {
                        Task { await model.sign() }
                    } label: {
                        HStack {
                            if model.isSigning { ProgressView().controlSize(.small) }
                            Text(NSLocalizedString("sign_and_save", comment: ""))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.documentURL == nil || model.selectedCert == nil || model.isSigning)

                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    if let err = model.lastError {
                        Text(err).font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 280, maxWidth: 360)
        }
        .sheet(isPresented: $model.showPaywall) { PaywallView() }
    }

    private func label(_ c: CertificateInfo) -> String {
        c.isExpired ? "\(c.commonName) — \(NSLocalizedString("expired", comment: ""))" : c.commonName
    }

}

struct CertDetail: View {
    let cert: CertificateInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cert.commonName).font(.callout).bold()
            Text("\(NSLocalizedString("issuer", comment: "")): \(cert.issuer)").font(.caption).foregroundStyle(.secondary)
            if let exp = cert.notAfter {
                Text("\(NSLocalizedString("validity", comment: "")): \(exp.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(cert.isExpired ? .red : .secondary)
            }
            if !cert.canSign {
                Text(NSLocalizedString("no_signing_usage", comment: "")).font(.caption).foregroundStyle(.orange)
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
                .frame(width: 150) // height follows the artwork's aspect ratio
                .allowsHitTesting(false) // drops fall through to the zone behind
            Text(prompt)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("open", comment: "")) { pick() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                               : AnyShapeStyle(.regularMaterial))
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
