import SwiftUI

/// Preferences window: appearance theme + app language.
struct PreferencesView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Apariencia") {
                Picker("Tema", selection: $settings.theme) {
                    Text("Sistema").tag(AppTheme.system)
                    Text("Claro").tag(AppTheme.light)
                    Text("Oscuro").tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
            }

            Section("Idioma") {
                Picker("Idioma", selection: $settings.language) {
                    Text("Sistema").tag(AppLanguage.system)
                    Text("Español").tag(AppLanguage.es)
                    Text("English").tag(AppLanguage.en)
                }
                Text("El cambio de idioma se aplica al reiniciar la app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 260)
    }
}
