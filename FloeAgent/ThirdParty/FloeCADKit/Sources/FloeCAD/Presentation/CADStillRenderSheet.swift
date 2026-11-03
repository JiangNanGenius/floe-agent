#if canImport(RealityKit) && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CADStillRenderSheet: View {
    let document: FloeCADDocument
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CADStillRenderSettings()
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var running = false
    @State private var result: CADStillRenderResult?
    @State private var error: String?
    @State private var file: PNGFileDocument?
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(FloeCADStrings.text("cad.render.quality", "Quality"), selection: $settings.quality) {
                        Text(FloeCADStrings.text("cad.render.standard", "Standard")).tag(CADStillRenderSettings.Quality.standard)
                        Text(FloeCADStrings.text("cad.render.detailed", "Detailed")).tag(CADStillRenderSettings.Quality.detailed)
                    }.accessibilityIdentifier("CADStillRenderQuality")
                    Picker(FloeCADStrings.text("cad.render.size", "Image size"), selection: $settings.width) {
                        ForEach([960, 1280, 1920], id: \.self) { width in
                            Text("\(width) × \(width * 3 / 4)").tag(width)
                        }
                    }.onChange(of: settings.width) { _, width in settings.height = width * 3 / 4 }
                    LabeledContent(FloeCADStrings.text("cad.render.exposure", "Exposure"), value: settings.exposureEV.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $settings.exposureEV, in: -3...3, step: 0.1)
                        .accessibilityLabel(FloeCADStrings.text("cad.render.exposure", "Exposure"))
                    LabeledContent(FloeCADStrings.text("cad.render.color", "Color"), value: settings.saturation.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $settings.saturation, in: 0...2, step: 0.1)
                        .accessibilityLabel(FloeCADStrings.text("cad.render.color", "Color"))
                }.disabled(running)
                if let result, let image = UIImage(data: result.png) {
                    Section {
                        Image(uiImage: image).resizable().scaledToFit()
                            .accessibilityIdentifier("CADStillRenderPreview")
                        Button(FloeCADStrings.text("cad.render.save", "Save image"), systemImage: "square.and.arrow.up") {
                            file = PNGFileDocument(data: result.png); exporting = true
                        }.accessibilityIdentifier("CADStillRenderSave")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    if running {
                        HStack {
                            ProgressView()
                            Text(FloeCADStrings.text("cad.render.rendering", "Rendering image…"))
                            Spacer()
                            Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { operation?.cancel() }
                        }.accessibilityIdentifier("CADStillRenderProgress")
                    } else {
                        Button(FloeCADStrings.text("cad.render.create", "Render image"), systemImage: "sparkles") { begin() }
                            .accessibilityIdentifier("CADStillRenderStart")
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.render.title", "Render image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.done", "Done")) { dismiss() }
                }
            }
            .fileExporter(isPresented: $exporting, document: file, contentType: .png, defaultFilename: "Render") { outcome in
                if case .failure(let failure) = outcome { error = failure.localizedDescription }
            }
            .onAppear { settings = document.stillRenderSettings }
            .onDisappear { generation = UUID(); operation?.cancel() }
        }
    }
    private func begin() {
        guard !running else { return }
        do {
            try settings.validate()
            if document.session.writeBlock == nil { try document.setStillRenderSettings(settings) }
        } catch { self.error = error.localizedDescription; return }
        let token = UUID(); generation = token; running = true; error = nil
        let options = settings
        operation = Task { @MainActor in
            do {
                let rendered = try await CADStillRenderService.shared.render(document: document, settings: options)
                guard !Task.isCancelled, generation == token else { return }
                result = rendered
            } catch is CancellationError {
            } catch { if generation == token, !Task.isCancelled { self.error = error.localizedDescription } }
            if generation == token { running = false; operation = nil }
        }
    }
}
#endif
