import SwiftUI
import UniformTypeIdentifiers

/// Sidebar editor for the visible-signature appearance + live preview.
/// Options are grouped into single-open accordions (only one expanded at a
/// time) to keep the sidebar compact while staying discoverable.
struct AppearanceEditorView: View {
    @Environment(AppModel.self) private var model

    /// Which accordion section is currently open (single-open behavior).
    enum Section: Hashable { case content, image, style, model }
    @State private var open: Section? = .content

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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }

            accordion("Contenido", .content) { contentSection($model) }
            accordion("Imagen", .image) { imageSection($model) }
            accordion("Estilo", .style) { styleSection($model) }
            accordion("Modelo de apariencia", .model) { modelSection($model) }

            PresetBar()
        }
    }

    // MARK: Single-open accordion

    /// A custom accordion: the WHOLE header row is clickable, content is
    /// left-aligned, and expand/collapse is animated. Opening one section
    /// closes the others (single-open).
    @ViewBuilder
    private func accordion<Content: View>(
        _ title: String, _ section: Section,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let isOpen = open == section
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    open = isOpen ? nil : section
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).font(.callout).fontWeight(.medium)
                    Spacer(minLength: 0)
                }
                // Full width so the WHOLE header row is the hit target, not
                // just the text. contentShape after the frame+padding.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                // Material header (depth) that's opaque enough to hide the
                // collapsing content tucking behind it. thickMaterial is the
                // most opaque system material.
                .background(.thickMaterial)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Header sits above the content so the slide animation tucks the
            // content behind the header, never over it.
            .zIndex(1)

            if isOpen {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        // Clip so the content sliding in/out during the expand/collapse
        // animation stays inside the rounded card (like CSS overflow:hidden).
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Hairline border + subtle shadow for depth (Liquid Glass depth, not
        // heavy shadows). Shadow after clip so it renders outside the bounds.
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    // MARK: Sections

    @ViewBuilder
    private func contentSection(_ model: Bindable<AppModel>) -> some View {
        Toggle("Nombre", isOn: model.appearance.showName)
        if model.wrappedValue.appearance.showName {
            Toggle("Etiqueta", isOn: model.appearance.showLabel)
            if model.wrappedValue.appearance.showLabel {
                TextField("Etiqueta", text: model.appearance.customLabel)
                    .textFieldStyle(.roundedBorder)
            }
        }
        Toggle("Fecha", isOn: model.appearance.showDate)
        Toggle("Motivo", isOn: model.appearance.showReason)
        if model.wrappedValue.appearance.showReason {
            TextField("Motivo", text: model.reason).textFieldStyle(.roundedBorder)
        }
        Toggle("Lugar", isOn: model.appearance.showLocation)
        if model.wrappedValue.appearance.showLocation {
            TextField("Lugar", text: model.location).textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func imageSection(_ model: Bindable<AppModel>) -> some View {
        HStack {
            Button("Imagen…") { importImage() }
            if model.wrappedValue.appearance.handwrittenImagePath != nil {
                Button("Quitar") { model.wrappedValue.appearance.handwrittenImagePath = nil }
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        Toggle("Código QR de verificación", isOn: model.appearance.showQR)
    }

    @ViewBuilder
    private func styleSection(_ model: Bindable<AppModel>) -> some View {
        Toggle("Borde", isOn: model.appearance.showBorder)
        Toggle("Fondo transparente", isOn: model.appearance.transparentBackground)
        Toggle("Ajustar texto (multilínea)", isOn: model.appearance.wrapText)
        HStack {
            Text("Tamaño texto").font(.caption)
            Slider(value: model.appearance.fontSize, in: 6...16, step: 1)
            Text("\(Int(model.wrappedValue.appearance.fontSize))").font(.caption).monospacedDigit()
        }
    }

    @ViewBuilder
    private func modelSection(_ model: Bindable<AppModel>) -> some View {
        radio(
            title: "Compatible (Acrobat)",
            hint: "Imágenes opacas sobre blanco. Máxima compatibilidad con Acrobat.",
            selected: model.wrappedValue.proAppearance == false
        ) { model.wrappedValue.proAppearance = false }

        radio(
            title: "Pro / Estándar",
            hint: "Conserva la transparencia de la imagen (modelo estándar PDF).",
            selected: model.wrappedValue.proAppearance == true
        ) { model.wrappedValue.proAppearance = true }
    }

    /// A radio-button row with a hint underneath. Whole row is clickable.
    @ViewBuilder
    private func radio(title: String, hint: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout)
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
