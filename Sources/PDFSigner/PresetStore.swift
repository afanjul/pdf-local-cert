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
            .appendingPathComponent("PDF-Signer", isDirectory: true)
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
            Menu("Ajustes preestablecidos") {
                if model.presets.isEmpty {
                    Text("Ninguno guardado").disabled(true)
                }
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.appearance = preset.config }
                }
                if !model.presets.isEmpty {
                    Divider()
                    Menu("Eliminar") {
                        ForEach(model.presets) { preset in
                            Button(preset.name, role: .destructive) { model.deletePreset(preset) }
                        }
                    }
                }
            }
            .font(.callout)
            Button {
                newName = ""; saving = true
            } label: { Image(systemName: "plus.circle") }
        }
        .popover(isPresented: $saving) {
            VStack(alignment: .leading) {
                Text("Guardar apariencia como…").font(.callout).bold()
                TextField("Nombre", text: $newName).frame(width: 200)
                HStack {
                    Spacer()
                    Button("Cancelar") { saving = false }
                    Button("Guardar") {
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
