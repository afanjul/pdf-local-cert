import SwiftUI

@main
struct PDFLocalCertApp: App {
    @State private var model = AppModel()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup("PDF Local Cert") {
            ContentView()
                .environment(model)
                .environment(settings)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .windowToolbarStyle(.unified)

        // Standard macOS Preferences scene: adds "Settings…" to the app menu
        // with the Cmd+, shortcut automatically.
        Settings {
            PreferencesView()
                .environment(model)
                .environment(settings)
                .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
