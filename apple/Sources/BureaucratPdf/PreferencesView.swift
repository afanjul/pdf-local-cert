import SwiftUI

/// Preferences window: tabbed — General (theme/language), License, About.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(NSLocalizedString("tab_general", comment: ""), systemImage: "gearshape") }

            LicenseSettingsTab()
                .tabItem { Label(NSLocalizedString("tab_license", comment: ""), systemImage: "checkmark.seal") }

            AboutTab()
                .tabItem { Label(NSLocalizedString("tab_about", comment: ""), systemImage: "info.circle") }
        }
        .frame(width: 440, height: 360)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(NSLocalizedString("appearance", comment: "")) {
                Picker(NSLocalizedString("theme", comment: ""), selection: $settings.theme) {
                    Text(NSLocalizedString("system_theme", comment: "")).tag(AppTheme.system)
                    Text(NSLocalizedString("light_theme", comment: "")).tag(AppTheme.light)
                    Text(NSLocalizedString("dark_theme", comment: "")).tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
            }

            Section(NSLocalizedString("language", comment: "")) {
                Picker(NSLocalizedString("language", comment: ""), selection: $settings.language) {
                    Text(NSLocalizedString("system_language", comment: "")).tag(AppLanguage.system)
                    Text(NSLocalizedString("spanish", comment: "")).tag(AppLanguage.es)
                    Text(NSLocalizedString("english", comment: "")).tag(AppLanguage.en)
                }
                Text(NSLocalizedString("language_restart_help", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("output", comment: "")) {
                TextField(NSLocalizedString("signed_suffix", comment: ""), text: $settings.signedSuffix)
                Text(String(format: NSLocalizedString("signed_suffix_help", comment: ""),
                            "documento\(settings.signedSuffix).pdf"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - License

private struct LicenseSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var error: String?

    private let buyURL = URL(string: "https://bureaucratpdf.app/pro")!

    var body: some View {
        Form {
            if model.license.isPro {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("license_active", comment: "")).bold()
                            Text(NSLocalizedString("license_active_desc", comment: ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                Section(NSLocalizedString("license_management", comment: "")) {
                    Button(NSLocalizedString("deactivate_license", comment: ""), role: .destructive) {
                        model.license.deactivate()
                    }
                }
            } else {
                Section(NSLocalizedString("free_plan", comment: "")) {
                    Text(String(format: NSLocalizedString("free_signs_status", comment: ""),
                                model.license.monthlyCount, model.license.freeMonthlyLimit))
                        .foregroundStyle(.secondary)
                    Link(NSLocalizedString("buy_license", comment: ""), destination: buyURL)
                }
                Section(NSLocalizedString("already_have_license", comment: "")) {
                    TextField("PDFS-XXXX-XXXX-XXXX", text: $key,
                              prompt: Text(NSLocalizedString("enter_license_key", comment: "")))
                        .textFieldStyle(.roundedBorder)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button(NSLocalizedString("activate", comment: "")) {
                        if model.license.activate(key) { error = nil; key = "" }
                        else { error = NSLocalizedString("invalid_license_key", comment: "") }
                    }
                    .disabled(key.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    private let githubURL = URL(string: "https://github.com/afanjul/bureaucrat-pdf")!

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(short)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("Bureaucrat PDF").font(.title2).bold()
                Text(version).font(.callout).foregroundStyle(.secondary)
            }

            Text(NSLocalizedString("developed_by", comment: ""))
                .font(.callout)

            Link(NSLocalizedString("view_on_github", comment: ""), destination: githubURL)

            Text(NSLocalizedString("open_source_note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
