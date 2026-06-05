import SwiftUI
import UniformTypeIdentifiers

/// Robust PDF file-drop handling for Finder drags. `loadObject(ofClass: URL.self)`
/// is flaky for file URLs, so we load the `fileURL` type identifier and decode
/// either a URL or its data representation.
enum DropSupport {
    static func loadPDF(_ providers: [NSItemProvider], _ completion: @escaping @MainActor (URL) -> Void) -> Bool {
        let typeID = UTType.fileURL.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(typeID) {
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                let resolved: URL?
                switch item {
                case let data as Data:
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                case let u as URL:
                    resolved = u
                default:
                    resolved = nil
                }
                guard let url = resolved, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in completion(url) }
            }
            return true
        }
        return false
    }

    /// Multi-file variant: collects every dropped PDF URL, then calls back once.
    static func loadPDFs(_ providers: [NSItemProvider], _ completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL] = []
            func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
        }
        let typeID = UTType.fileURL.identifier
        let group = DispatchGroup()
        let box = Box()
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(typeID) {
            handled = true
            group.enter()
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                defer { group.leave() }
                let resolved: URL?
                switch item {
                case let data as Data: resolved = URL(dataRepresentation: data, relativeTo: nil)
                case let u as URL: resolved = u
                default: resolved = nil
                }
                guard let url = resolved, url.pathExtension.lowercased() == "pdf" else { return }
                box.add(url)
            }
        }
        group.notify(queue: .main) { Task { @MainActor in completion(box.urls) } }
        return handled
    }
}
