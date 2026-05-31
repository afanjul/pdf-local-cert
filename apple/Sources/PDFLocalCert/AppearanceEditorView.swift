import SwiftUI
import UniformTypeIdentifiers

/// Sidebar editor for the visible-signature appearance + live preview.
/// Options are grouped into single-open accordions (only one expanded at a
/// time) to keep the sidebar compact while staying discoverable.
struct AppearanceEditorView: View {
    @Environment(AppModel.self) private var model

    /// Which accordion section is currently open (single-open behavior).
    /// Starts `nil` so every section is collapsed initially.
    enum Section: Hashable { case content, image, style }
    @State private var open: Section? = nil

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("appearance", comment: "")).font(.headline)

            // Live preview (same renderer as the embedded result). Rendered at
            // 3× the 200×60 display ratio so it stays crisp when the sidebar
            // stretches it (~300pt wide on Retina = 600px); was pixelated at 1×.
            // pointSize fixed at 200×60 (the on-page proportions) while pixels
            // render at 3× for crispness — keeps the font size faithful.
            if let img = model.appearancePreview(pointSize: CGSize(width: 200, height: 60),
                                                 pixelSize: CGSize(width: 600, height: 180)) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(200.0 / 60.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    // Drag this preview onto the page to place the signature box.
                    .draggable(SignaturePreviewToken(aspect: 200.0 / 60.0)) {
                        Image(nsImage: img).resizable()
                            .frame(width: 120, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .help(NSLocalizedString("drag_preview_to_place", comment: ""))
            }

            accordion(NSLocalizedString("content", comment: ""), .content) { contentSection($model) }
            accordion(NSLocalizedString("image", comment: ""), .image) { imageSection($model) }
            accordion(NSLocalizedString("style", comment: ""), .style) { styleSection($model) }

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
        Toggle(NSLocalizedString("name", comment: ""), isOn: model.appearance.showName)
        if model.wrappedValue.appearance.showName {
            Toggle(NSLocalizedString("label", comment: ""), isOn: model.appearance.showLabel)
            if model.wrappedValue.appearance.showLabel {
                TextField(NSLocalizedString("label", comment: ""), text: model.appearance.customLabel)
                    .textFieldStyle(.roundedBorder)
            }
        }
        Toggle(NSLocalizedString("date", comment: ""), isOn: model.appearance.showDate)
        Toggle(NSLocalizedString("reason", comment: ""), isOn: model.appearance.showReason)
        if model.wrappedValue.appearance.showReason {
            TextField(NSLocalizedString("reason", comment: ""), text: model.reason).textFieldStyle(.roundedBorder)
        }
        Toggle(NSLocalizedString("location", comment: ""), isOn: model.appearance.showLocation)
        if model.wrappedValue.appearance.showLocation {
            TextField(NSLocalizedString("location", comment: ""), text: model.location).textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func imageSection(_ model: Bindable<AppModel>) -> some View {
        HStack {
            Button(NSLocalizedString("image_button", comment: "")) { importImage() }
            if model.wrappedValue.appearance.handwrittenImagePath != nil {
                Button(NSLocalizedString("remove", comment: "")) { model.wrappedValue.appearance.handwrittenImagePath = nil }
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        Toggle(NSLocalizedString("verification_qr", comment: ""), isOn: model.appearance.showQR)
    }

    @ViewBuilder
    private func styleSection(_ model: Bindable<AppModel>) -> some View {
        Toggle(NSLocalizedString("border", comment: ""), isOn: model.appearance.showBorder)
        Toggle(NSLocalizedString("transparent_background", comment: ""), isOn: model.appearance.transparentBackground)
        Toggle(NSLocalizedString("wrap_text", comment: ""), isOn: model.appearance.wrapText)
        HStack {
            Text(NSLocalizedString("text_size", comment: "")).font(.caption)
            Slider(value: model.appearance.fontSize, in: 6...16, step: 1)
            Text("\(Int(model.wrappedValue.appearance.fontSize))").font(.caption).monospacedDigit()
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
