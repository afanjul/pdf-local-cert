import SwiftUI
import AppKit

/// Installs a local scroll-wheel/magnify monitor while mounted, reporting a zoom
/// delta when ⌘ or ⌃ is held (or on trackpad pinch). Plain scrolling is left
/// untouched so the enclosing ScrollView behaves normally. A local monitor is
/// used (rather than overriding scrollWheel on a view) so it never competes with
/// the SwiftUI signature-box drag gesture for hit-testing.
struct ScrollZoomCatcher: NSViewRepresentable {
    /// Called with a zoom delta (positive = zoom in).
    var onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.install(for: v, onZoom: onZoom)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onZoom: ((CGFloat) -> Void)?
        private var scrollMonitor: Any?
        private var magnifyMonitor: Any?
        private weak var view: NSView?

        func install(for view: NSView, onZoom: @escaping (CGFloat) -> Void) {
            self.view = view
            self.onZoom = onZoom
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event) ?? event
            }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                self?.handleMagnify(event) ?? event
            }
        }

        func remove() {
            if let m = scrollMonitor { NSEvent.removeMonitor(m) }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m) }
            scrollMonitor = nil
            magnifyMonitor = nil
        }

        /// True when the event happened over our view (so zoom is scoped to the
        /// PDF area, not the sidebar).
        private func isOverView(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            let p = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(p)
        }

        private func handleScroll(_ event: NSEvent) -> NSEvent? {
            guard isOverView(event),
                  event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
            else { return event }
            let dy = event.scrollingDeltaY
            if dy != 0 {
                let step = event.hasPreciseScrollingDeltas ? dy / 200.0 : dy / 8.0
                onZoom?(step)
            }
            return nil // consume so the page doesn't also scroll while zooming
        }

        private func handleMagnify(_ event: NSEvent) -> NSEvent? {
            guard isOverView(event) else { return event }
            onZoom?(event.magnification)
            return nil
        }
    }
}
