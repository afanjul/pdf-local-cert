import SwiftUI

/// A named, persisted appearance preset.
struct AppearancePreset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var config: AppearanceConfig
}

/// Loads/saves appearance presets as JSON under Application Support.
enum PresetStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bureaucrat-PDF", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("presets.json")
    }

    static func load() -> [AppearancePreset] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([AppearancePreset].self, from: data) else {
            return []
        }
        return list
    }

    static func save(_ presets: [AppearancePreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: fileURL)
    }
}

/// Sidebar control: load / save / delete appearance presets.
struct PresetBar: View {
    @Environment(AppModel.self) private var model
    @State private var saving = false
    @State private var newName = ""

    var body: some View {
        HStack {
            Menu(NSLocalizedString("presets", comment: "")) {
                if model.presets.isEmpty {
                    Text(NSLocalizedString("none_saved", comment: "")).disabled(true)
                }
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.appearance = preset.config }
                }
                if !model.presets.isEmpty {
                    Divider()
                    Menu(NSLocalizedString("delete", comment: "")) {
                        ForEach(model.presets) { preset in
                            Button(preset.name, role: .destructive) { model.deletePreset(preset) }
                        }
                    }
                }
            }
            .font(.callout)
            Button {
                newName = ""; saving = true
            } label: { Image(systemName: "square.and.arrow.down") }
            .help(NSLocalizedString("save_preset_help", comment: ""))
        }
        .popover(isPresented: $saving) {
            VStack(alignment: .leading) {
                Text(NSLocalizedString("save_appearance_as", comment: "")).font(.callout).bold()
                TextField(NSLocalizedString("name", comment: ""), text: $newName).frame(width: 200)
                HStack {
                    Spacer()
                    Button(NSLocalizedString("cancel", comment: "")) { saving = false }
                    Button(NSLocalizedString("save", comment: "")) {
                        model.savePreset(named: newName)
                        saving = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }
}
