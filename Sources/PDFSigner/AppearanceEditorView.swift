import SwiftUI
import UniformTypeIdentifiers

/// Sidebar editor for the visible-signature appearance + live preview.
struct AppearanceEditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Apariencia").font(.headline)

            // Live preview (same renderer as the embedded result).
            if let img = model.appearancePreview(pixelSize: CGSize(width: 200, height: 60)) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(200.0 / 60.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }

            Toggle("Nombre", isOn: $model.appearance.showName)
            Toggle("Fecha", isOn: $model.appearance.showDate)
            Toggle("Motivo", isOn: $model.appearance.showReason)
            if model.appearance.showReason {
                TextField("Motivo", text: $model.reason).textFieldStyle(.roundedBorder)
            }
            Toggle("Lugar", isOn: $model.appearance.showLocation)
            if model.appearance.showLocation {
                TextField("Lugar", text: $model.location).textFieldStyle(.roundedBorder)
            }

            TextField("Etiqueta (opcional)", text: $model.appearance.customLabel)
                .textFieldStyle(.roundedBorder)

            Toggle("Borde", isOn: $model.appearance.showBorder)
            Toggle("Fondo transparente", isOn: $model.appearance.transparentBackground)
            Toggle("Código QR de verificación", isOn: $model.appearance.showQR)
            Toggle("Firmar en todas las páginas", isOn: $model.signAllPages)

            HStack {
                Text("Tamaño texto").font(.caption)
                Slider(value: $model.appearance.fontSize, in: 6...16, step: 1)
                Text("\(Int(model.appearance.fontSize))").font(.caption).monospacedDigit()
            }

            HStack {
                Button("Imagen…") { importImage() }
                if model.appearance.handwrittenImagePath != nil {
                    Button("Quitar") { model.appearance.handwrittenImagePath = nil }
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)

            PresetBar()
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.appearance.handwrittenImagePath = url.path
        }
    }
}
