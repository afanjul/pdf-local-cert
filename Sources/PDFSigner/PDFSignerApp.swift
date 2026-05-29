import SwiftUI

@main
struct PDFSignerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("PDF-Signer") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}
