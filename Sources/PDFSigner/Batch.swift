import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum BatchStatus: Equatable { case pending, signing, done, failed }

struct BatchItem: Identifiable {
    let id = UUID()
    let url: URL
    var status: BatchStatus = .pending
    var message: String = ""
    var output: URL?
}

extension AppModel {
    func addBatchFiles(_ urls: [URL]) {
        let existing = Set(batchItems.map(\.url))
        for u in urls where u.pathExtension.lowercased() == "pdf" && !existing.contains(u) {
            batchItems.append(BatchItem(url: u))
        }
    }

    func clearBatch() { batchItems.removeAll() }

    /// Sign every queued file with the current cert + options, default placement.
    /// Pro-only (a scale feature). Outputs `<name>-firmado.pdf` beside each source.
    func runBatch() async {
        guard let cert = selectedCert else { lastError = SigningError.noCertificate.errorDescription; return }
        if !license.isPro { showPaywall = true; return }
        guard !batchRunning else { return }
        batchRunning = true
        defer { batchRunning = false }

        for idx in batchItems.indices {
            guard batchItems[idx].status == .pending else { continue }
            batchItems[idx].status = .signing
            let url = batchItems[idx].url
            let doc = PDFDocument(url: url)
            let req = makeRequest(url: url, cert: cert, doc: doc, drawn: false)
            do {
                let result = try await Task.detached { try SigningCoordinator.sign(req) }.value
                let dest = Self.batchDestination(for: url)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: result.outputURL, to: dest)
                batchItems[idx].status = .done
                batchItems[idx].output = dest
                batchItems[idx].message = "\(result.padesLevel) · \(dest.lastPathComponent)"
            } catch {
                batchItems[idx].status = .failed
                batchItems[idx].message = (error as? SigningError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    var batchSummary: String {
        let done = batchItems.filter { $0.status == .done }.count
        let failed = batchItems.filter { $0.status == .failed }.count
        return "\(done) firmados · \(failed) con error · \(batchItems.count) total"
    }

    private static func batchDestination(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent("\(stem)-firmado.pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem)-firmado (\(n)).pdf")
            n += 1
        }
        return dest
    }
}

struct BatchView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Firma por lotes").font(.headline)
                Spacer()
                Button("Añadir…") { pick() }
                Button("Limpiar") { model.clearBatch() }
                    .disabled(model.batchItems.isEmpty || model.batchRunning)
            }
            .padding(8)
            Divider()

            if model.batchItems.isEmpty {
                DropZone(prompt: "Arrastra varios PDF aquí", isActive: isDropTargeted) { _ in }
            } else {
                List(model.batchItems) { item in
                    HStack {
                        statusIcon(item.status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            if !item.message.isEmpty {
                                Text(item.message).font(.caption)
                                    .foregroundStyle(item.status == .failed ? .red : .secondary)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                if !model.license.isPro {
                    Label("Pro", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                }
                Text(model.batchSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.runBatch() }
                } label: {
                    HStack {
                        if model.batchRunning { ProgressView().controlSize(.small) }
                        Text("Firmar todo")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.batchItems.isEmpty || model.batchRunning || model.selectedCert == nil)
            }
            .padding(8)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            DropSupport.loadPDFs(providers) { urls in model.addBatchFiles(urls) }
        }
    }

    @ViewBuilder private func statusIcon(_ s: BatchStatus) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .signing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { model.addBatchFiles(panel.urls) }
    }
}
