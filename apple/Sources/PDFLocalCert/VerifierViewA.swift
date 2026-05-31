import SwiftUI
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════════════
// ALT A — Persistent drop zone + growing list of result cards ("append" mode).
//
// The drop zone never disappears: empty state shows the big zone; once results
// exist it shrinks to a slim always-active bar at the top and result blocks
// accumulate below. Drop more anytime to append. Each file can be removed.
// Self-contained: owns its own per-file state, does not touch AppModel.verify.
// ════════════════════════════════════════════════════════════════════════════

struct VerifierViewA: View {
    @State private var items: [VerifyItemA] = []
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            if items.isEmpty {
                emptyState
            } else {
                compactBar
                summaryHeader
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { item in
                            FileBlockA(item: item) { remove(item) }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        // One drop target for the whole view; collects every PDF at once.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            DropSupport.loadPDFs(providers) { urls in add(urls) }
        }
    }

    // MARK: Subviews

    private var emptyState: some View {
        DropZone(prompt: NSLocalizedString("drag_signed_pdfs", comment: ""),
                 isActive: isDropTargeted) { url in add([url]) }
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text(NSLocalizedString("drag_more_pdfs", comment: ""))
                .foregroundStyle(.secondary)
            Spacer()
            Button(NSLocalizedString("open", comment: "")) { openPanel() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                     : AnyShapeStyle(.regularMaterial))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4]))
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .padding([.horizontal, .top])
    }

    private var summaryHeader: some View {
        HStack {
            Text(summaryText).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(NSLocalizedString("reverify", comment: "")) { reverifyAll() }
                .disabled(items.allSatisfy { if case .verifying = $0.state { return true } else { return false } })
            Button(NSLocalizedString("clear", comment: "")) { items.removeAll() }
        }
        .padding(.horizontal)
    }

    private var summaryText: String {
        let total = items.count
        let invalid = items.filter { $0.isInvalid }.count
        let pending = items.filter { if case .verifying = $0.state { return true } else { return false } }.count
        var parts = [String(format: NSLocalizedString("x_files", comment: ""), total, total == 1 ? "" : "s")]
        if pending > 0 { parts.append(String(format: NSLocalizedString("x_verifying", comment: ""), pending)) }
        if invalid > 0 { parts.append(String(format: NSLocalizedString("x_invalid", comment: ""), invalid, invalid == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        for url in urls {
            let std = url.standardizedFileURL
            if let idx = items.firstIndex(where: { $0.url.standardizedFileURL == std }) {
                items[idx].state = .verifying       // re-verify in place (dedup)
                verify(id: items[idx].id, url: std)
            } else {
                let item = VerifyItemA(url: std, state: .verifying)
                items.append(item)
                verify(id: item.id, url: std)
            }
        }
    }

    private func reverifyAll() {
        for item in items {
            update(item.id) { $0.state = .verifying }
            verify(id: item.id, url: item.url)
        }
    }

    private func remove(_ item: VerifyItemA) {
        items.removeAll { $0.id == item.id }
    }

    private func verify(id: UUID, url: URL) {
        Task {
            do {
                let sigs = try await Task.detached { try SigningCoordinator.verify(url) }.value
                update(id) { $0.state = sigs.isEmpty ? .failed(NSLocalizedString("no_signatures", comment: "")) : .done(sigs) }
            } catch {
                let msg = (error as? SigningError)?.errorDescription ?? error.localizedDescription
                update(id) { $0.state = .failed(msg) }
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout VerifyItemA) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

// MARK: - Per-file model

struct VerifyItemA: Identifiable {
    let id = UUID()
    let url: URL
    var state: State

    enum State {
        case verifying
        case done([VerificationDisplay])
        case failed(String)
    }

    var isInvalid: Bool {
        switch state {
        case .failed: return true
        case .done(let sigs): return sigs.contains { !$0.valid }
        case .verifying: return false
        }
    }
}

// MARK: - One file's block (header + its signatures)

private struct FileBlockA: View {
    let item: VerifyItemA
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                Text(item.url.lastPathComponent).font(.callout).bold()
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help(NSLocalizedString("remove_from_list", comment: ""))
            }
            switch item.state {
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString("verifying", comment: "")).font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Label(msg, systemImage: "xmark.seal").font(.caption).foregroundStyle(.red)
            case .done(let sigs):
                ForEach(sigs) { ResultCard(result: $0) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.state {
        case .verifying: Image(systemName: "clock").foregroundStyle(.secondary)
        case .failed:    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
        case .done(let sigs):
            let ok = !sigs.isEmpty && sigs.allSatisfy { $0.valid }
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(ok ? .green : .red)
        }
    }
}
