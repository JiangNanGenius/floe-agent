// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit
import FloeCAD
import FloeCore

@MainActor
struct CADOfflineRenderEntry: ViewModifier {
    let document: FloeCADDocument
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    @State private var presented = false
    func body(content: Content) -> some View {
        content.toolbar {
            Button { presented = true } label: {
                Label(FloeL10n.l("app.cadoffline_render_view.offline_render"), systemImage: "camera.aperture")
            }.accessibilityIdentifier("cad.offlineRender.open")
        }.sheet(isPresented: $presented) {
            CADOfflineRenderView(document: document, root: root, workspaceID: workspaceID, conversationID: conversationID)
        }
    }
}

nonisolated enum CADOfflineRenderText {
    static func t(_ zh: String, _ en: String) -> String { FloeL10n.bilingual(chinese: zh, english: en) }
}

/// Closing this sheet does not cancel or resubmit a service-owned render.
@MainActor
struct CADOfflineRenderView: View {
    let document: FloeCADDocument
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    private var center: CADOfflineRenderCenter { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CADOfflineRenderSettings()
    @State private var operation: CADOfflineRenderOperation?
    @State private var starting = false
    @State private var cancelling = false
    @State private var message: String?
    @State private var image: UIImage?
    @State private var imageURL: URL?
    private func t(_ zh: String, _ en: String) -> String { CADOfflineRenderText.t(zh, en) }
    private var canStart: Bool { !starting && operation?.isRunning != true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(FloeL10n.l("app.cadoffline_render_view.compute_reflections_indirect_light_and"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section(FloeL10n.l("design.panel.type.image")) {
                    Picker(FloeL10n.l("workspace.workspace_canvas_view.quality"), selection: $settings.quality) {
                        Text(FloeL10n.l("app.cadoffline_render_view.preview_16_samples")).tag(CADOfflineRenderSettings.Quality.preview)
                        Text(FloeL10n.l("app.cadoffline_render_view.studio_64_samples")).tag(CADOfflineRenderSettings.Quality.studio)
                        Text(FloeL10n.l("app.cadoffline_render_view.final_256_samples")).tag(CADOfflineRenderSettings.Quality.final)
                    }.accessibilityIdentifier("cad.offlineRender.quality")
                    Picker(FloeL10n.l("workspace.workspace_canvas_view.size"), selection: $settings.width) {
                        ForEach([640, 1280, 1920, 2560], id: \.self) { width in Text("\(width) × \(width * 3 / 4)").tag(width) }
                    }.onChange(of: settings.width) { _, width in settings.height = width * 3 / 4 }
                    Stepper(value: $settings.maximumBounces, in: 2...16) {
                        LabeledContent(FloeL10n.l("app.cadoffline_render_view.light_bounces"), value: "\(settings.maximumBounces)")
                    }
                    LabeledContent(FloeL10n.l("cad.render.exposure"), value: settings.exposureEV.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $settings.exposureEV, in: -6...6, step: 0.25).accessibilityLabel(FloeL10n.l("cad.render.exposure"))
                }.disabled(starting || operation?.isRunning == true)
                Section {
                    if starting || operation?.isRunning == true {
                        HStack {
                            ProgressView()
                            Text(operation?.state == .cancelling ? FloeL10n.l("app.core_aimodel_inspection.cancelling") : FloeL10n.l("app.cadoffline_render_view.preparing_and_rendering"))
                            Spacer()
                            if let operation {
                                Button(FloeL10n.l("cad.scene.cancel"), role: .destructive) { cancel(operation.id) }.disabled(cancelling)
                            }
                        }.accessibilityIdentifier("cad.offlineRender.progress")
                    } else {
                        Button(FloeL10n.l("app.cadoffline_render_view.render_on_device"), systemImage: "sparkles") { start() }
                            .disabled(!canStart).accessibilityIdentifier("cad.offlineRender.start")
                    }
                    if let operation {
                        LabeledContent(FloeL10n.l("envdetail.status"), value: stateTitle(operation.state))
                        if operation.isRunning, let samples = operation.completedSamples {
                            LabeledContent(FloeL10n.l("app.cadoffline_render_view.samples"), value: "\(samples) / \(operation.settings.quality.samples)")
                        }
                        if operation.state == .ready {
                            LabeledContent(FloeL10n.l("app.cadoffline_render_view.image_size"), value: "\(operation.settings.width) × \(operation.settings.height)")
                            Text(FloeL10n.l("app.cadoffline_render_view.the_image_uses_the_model"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !operation.warnings.isEmpty {
                            DisclosureGroup(FloeL10n.l("app.cadoffline_render_view.scene_conversion_details")) {
                                ForEach(operation.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                }
                if let image {
                    Section {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("cad.offlineRender.preview")
                        if let imageURL {
                            ShareLink(item: imageURL) { Label(FloeL10n.l("app.cadoffline_render_view.save_image"), systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("cad.offlineRender.save")
                        }
                    }
                }
            }
            .navigationTitle(FloeL10n.l("app.cadoffline_render_view.offline_render"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(FloeL10n.l("help.done")) { dismiss() } } }
            .task(id: operation?.id) {
                if operation == nil {
                    operation = center.latest(documentURL: document.url, conversationID: conversationID, workspaceRoot: root)
                    if let operation { settings = operation.settings }
                }
                while !Task.isCancelled, let current = operation {
                    await refresh()
                    if !current.isRunning { break }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                }
            }
        }
    }
    private func stateTitle(_ state: CADOfflineRenderOperation.State) -> String {
        switch state {
        case .preparing: FloeL10n.l("canvas.generation.state.preparing")
        case .rendering: FloeL10n.l("app.cadoffline_render_view.rendering")
        case .ready: FloeL10n.l("app.cadbuilding_professional_view.ready")
        case .cancelling: FloeL10n.l("skills.authoring.phase.cancelling")
        case .cancelled: FloeL10n.l("background.event.cancelled")
        case .failed: FloeL10n.l("canvas.generation.state.failed")
        case .interrupted: FloeL10n.l("core.linux_background_surface.interrupted")
        }
    }
    private func start() {
        guard canStart else { return }
        starting = true; message = nil; image = nil; imageURL = nil
        Task {
            defer { starting = false }
            do {
                operation = try await center.startFromUI(document: document, settings: settings,
                    workspaceRoot: root, workspaceID: workspaceID, conversationID: conversationID)
            } catch { message = error.localizedDescription }
        }
    }
    private func cancel(_ id: UUID) {
        cancelling = true
        Task {
            defer { cancelling = false }
            do { operation = try await center.cancel(id) }
            catch { message = error.localizedDescription }
        }
    }
    private func refresh() async {
        guard let current = operation else { return }
        do {
            let updated = try await center.refresh(current.id)
            guard operation?.id == current.id else { return }
            operation = updated; message = updated.error
            if updated.state == .ready, imageURL == nil, let url = try center.imageURL(updated) {
                imageURL = url; image = UIImage(contentsOfFile: url.path)
            }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
