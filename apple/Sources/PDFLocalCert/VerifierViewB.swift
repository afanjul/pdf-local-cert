import SwiftUI
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════════════
// ALT B — Batch "queue" list (dense, scalable, pro).
//
// Compact toolbar (Añadir / Reverificar / Limpiar / Solo inválidos) over a List
// of files. One row per file: status + name + level badge; click to expand and
// see every signature's full detail. The whole list is a drop target, so more
// files can be added anytime. A global progress bar runs during verification.
// Self-contained: owns its own per-file state, does not touch AppModel.verify.
// ════════════════════════════════════════════════════════════════════════════

struct VerifierViewB: View {
    @State private var items: [VerifyItemB] = []
    @State private var onlyInvalid = false
    @State private var newestFirst = true
    @State private var expanded: Set<UUID> = []
    @State private var isDropTargeted = false

    private var pending: Int {
        items.filter { if case .verifying = $0.state { return true } else { return false } }.count
    }
    private var visible: [VerifyItemB] {
        // `items` is kept in insertion order (oldest first); newestFirst shows
        // the most recently added at the top.
        let filtered = onlyInvalid ? items.filter { $0.isInvalid } : items
        return newestFirst ? filtered.reversed() : filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if pending > 0 {
                ProgressView(value: Double(items.count - pending), total: Double(items.count))
                    .padding(.horizontal).padding(.bottom, 6)
            }
            Divider()
            content
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            DropSupport.loadPDFs(providers) { urls in add(urls) }
        }
        .overlay { if isDropTargeted { dropHighlight } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { openPanel() } label: { Label(NSLocalizedString("add_button", comment: ""), systemImage: "plus") }
            Button { reverifyAll() } label: { Label(NSLocalizedString("reverify", comment: ""), systemImage: "arrow.clockwise") }
                .disabled(items.isEmpty)
            Button(role: .destructive) { items.removeAll(); expanded.removeAll() } label: {
                Label(NSLocalizedString("clear", comment: ""), systemImage: "trash")
            }
            .disabled(items.isEmpty)

            Spacer()

            if !items.isEmpty {
                Text(summaryText).font(.caption).foregroundStyle(.secondary)
                Toggle(NSLocalizedString("newest_first", comment: ""), isOn: $newestFirst)
                    .toggleStyle(.checkbox)
                Toggle(NSLocalizedString("only_invalid", comment: ""), isOn: $onlyInvalid)
                    .toggleStyle(.checkbox)
                    .disabled(items.allSatisfy { !$0.isInvalid })
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var summaryText: String {
        let invalid = items.filter { $0.isInvalid }.count
        if pending > 0 { return String(format: NSLocalizedString("verifying_x_of_y", comment: ""), items.count - pending, items.count) }
        return invalid == 0 ? String(format: NSLocalizedString("x_valid", comment: ""), items.count) : String(format: NSLocalizedString("x_invalid", comment: ""), items.count, invalid, invalid == 1 ? "" : "s")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            DropZone(prompt: NSLocalizedString("drag_signed_pdfs", comment: ""),
                     isActive: isDropTargeted) { url in add([url]) }
                .padding()
        } else {
            List {
                ForEach(visible) { item in
                    RowB(item: item,
                         isExpanded: expanded.contains(item.id),
                         onToggle: { toggle(item.id) },
                         onRemove: { remove(item) })
                        // Zero insets so the row's own padding defines the full
                        // clickable height (the toggle area = entire row).
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }
            .listStyle(.inset)
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .padding(6)
            .allowsHitTesting(false)
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        var touched: [UUID] = []
        for url in urls {
            let std = url.standardizedFileURL
            if let idx = items.firstIndex(where: { $0.url.standardizedFileURL == std }) {
                items[idx].state = .verifying       // re-verify in place (dedup)
                verify(id: items[idx].id, url: std)
                touched.append(items[idx].id)
            } else {
                let item = VerifyItemB(url: std, state: .verifying)
                items.append(item)
                verify(id: item.id, url: std)
                touched.append(item.id)
            }
        }
        // The files just dropped open expanded; everything already in the list
        // collapses, so the latest additions stand out.
        expanded = Set(touched)
    }

    private func reverifyAll() {
        for item in items {
            update(item.id) { $0.state = .verifying }
            verify(id: item.id, url: item.url)
        }
    }

    private func remove(_ item: VerifyItemB) {
        items.removeAll { $0.id == item.id }
        expanded.remove(item.id)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
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

    private func update(_ id: UUID, _ mutate: (inout VerifyItemB) -> Void) {
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

struct VerifyItemB: Identifiable {
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

    var levelText: String {
        switch state {
        case .verifying: return "…"
        case .failed: return "—"
        case .done(let sigs): return sigs.first?.level ?? "—"
        }
    }
}

// MARK: - One file row (compact, expandable)

private struct RowB: View {
    let item: VerifyItemB
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                Text(item.url.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.levelText)
                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 4))
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                if hasDetail {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            // Full-height header padding + contentShape so the whole row area
            // (not just the text) toggles the disclosure.
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if hasDetail { onToggle() } }

            if isExpanded {
                switch item.state {
                case .done(let sigs): ForEach(sigs) { ResultCard(result: $0) }
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.seal").font(.caption).foregroundStyle(.red)
                case .verifying: EmptyView()
                }
                Spacer().frame(height: 4)
            }
        }
    }

    private var hasDetail: Bool {
        switch item.state {
        case .verifying: return false
        default: return true
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.state {
        case .verifying: ProgressView().controlSize(.small)
        case .failed:    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
        case .done(let sigs):
            let ok = !sigs.isEmpty && sigs.allSatisfy { $0.valid }
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(ok ? .green : .red)
        }
    }
}
