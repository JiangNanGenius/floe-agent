// FloeApp — Single-asset media editing, with persisted parameters and verified exports.
#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import FloeCore
import FloeMedia
import FloeTools
import VideoEditorKit

@MainActor
final class MediaEditorModel: ObservableObject {
    @Published var inputPath = ""
    @Published var outputPath = ""
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var duration = 0.0
    @Published var speed = 1.0
    @Published var volume = 1.0
    @Published var exportStatus = ""
    @Published var isExporting = false
    @Published var container = "mp4"
    @Published var videoCodec = "h264"
    @Published var width = ""
    @Published var height = ""
    @Published var frameRate = ""
    @Published var exportedURL: URL?
    let workspaceRoot: URL
    let sourceURL: URL
    private var exportTask: Task<Void, Never>?
    private var cancellation: CancellationToken?

    init(workspaceRoot: URL, sourceURL: URL) {
        self.workspaceRoot = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        self.sourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        if self.sourceURL.path.hasPrefix(self.workspaceRoot.path + "/") {
            inputPath = String(self.sourceURL.path.dropFirst(self.workspaceRoot.path.count + 1))
            let name = (inputPath as NSString).deletingPathExtension
            outputPath = name + "-edited-" + String(UUID().uuidString.prefix(8)) + ".mp4"
        }
    }

    private var projectURL: URL {
        workspaceRoot.appendingPathComponent(".floe-media-edits")
            .appendingPathComponent(FloeDigest.sha256Hex(Data(inputPath.utf8)) + ".json")
    }

    func load() async {
        guard !inputPath.isEmpty else { exportStatus = FloeL10n.l("media.media_editor_view.the_asset_must_belong_to_the"); return }
        do {
            let asset = AVURLAsset(url: sourceURL)
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.invalid_asset_duration")) }
            trimEnd = duration
            guard projectURL.resolvingSymlinksInPath().path.hasPrefix(workspaceRoot.path + "/") else {
                throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_editing_project_path_is_outside"))
            }
            if FileManager.default.fileExists(atPath: projectURL.path) {
                let saved = try JSONDecoder().decode(VideoEditPlan.self, from: Data(contentsOf: projectURL))
                guard saved.input == inputPath else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_editing_project_does_not_match")) }
                outputPath = saved.output
                container = saved.export.container
                videoCodec = saved.export.videoCodec ?? "h264"
                width = saved.export.width.map(String.init) ?? ""
                height = saved.export.height.map(String.init) ?? ""
                frameRate = saved.export.frameRate.map { String($0) } ?? ""
                for operation in saved.operations {
                    switch operation {
                    case .trim(let start, let end): trimStart = start; trimEnd = end
                    case .speed(let rate): speed = rate
                    case .volume(let level): volume = level
                    default: throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.this_editing_project_contains_operations_not"))
                    }
                }
            }
        } catch { exportStatus = error.localizedDescription }
    }

    func plan() throws -> VideoEditPlan {
        func integer(_ text: String) throws -> Int? {
            if text.isEmpty { return nil }
            guard let value = Int(text), value > 0 else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.dimensions_must_be_positive_integers")) }
            return value
        }
        let fps: Double?
        if frameRate.isEmpty { fps = nil }
        else {
            guard let value = Double(frameRate), value.isFinite, value > 0 else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_frame_rate_must_be_positive")) }
            fps = value
        }
        let plan = VideoEditPlan(input: inputPath, output: outputPath,
            operations: [.trim(start: trimStart, end: trimEnd), .speed(rate: speed), .volume(level: volume)],
            export: .init(container: container, videoCodec: videoCodec, width: try integer(width), height: try integer(height), frameRate: fps))
        try plan.validate()
        return plan
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(plan())
            let directory = projectURL.deletingLastPathComponent()
            guard directory.resolvingSymlinksInPath().path.hasPrefix(workspaceRoot.path + "/") else {
                throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_editing_project_directory_is_outside"))
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: projectURL, options: .atomic)
            exportStatus = FloeL10n.l("media.media_editor_view.editing_parameters_saved")
        } catch { exportStatus = error.localizedDescription }
    }

    func startExport() {
        guard !isExporting else { return }
        do {
            let plan = try plan()
            save()
            let token = CancellationToken()
            cancellation = token
            isExporting = true
            exportStatus = FloeL10n.l("media.media_editor_view.processing_and_verifying_output")
            exportTask = Task {
                defer { isExporting = false; cancellation = nil; exportTask = nil }
                do {
                    let root = workspaceRoot
                    let result = try await MediaRenderer(rootProvider: { root }).render(plan: plan, cancellation: token)
                    exportedURL = result.outputPath.hasPrefix("/") ? URL(fileURLWithPath: result.outputPath) : workspaceRoot.appendingPathComponent(result.outputPath)
                    exportStatus = FloeL10n.l("media.media_editor_view.exported_to_workspace", result.outputPath)
                } catch { exportStatus = FloeL10n.l("media.media_editor_view.processing_did_not_finish", error.localizedDescription) }
            }
        } catch { exportStatus = error.localizedDescription }
    }

    func cancel() {
        cancellation?.cancel()
        exportTask?.cancel()
    }
}

struct MediaEditorView: View {
    @StateObject private var model: MediaEditorModel
    @Environment(\.dismiss) private var dismiss
    private let onExported: ((URL) -> Void)?
    @State private var previewOutput = false
    @State private var showVisualEditor = false

    init(workspaceRoot: URL, previewURL: URL, onExported: ((URL) -> Void)? = nil) {
        self.onExported = onExported
        _model = StateObject(wrappedValue: MediaEditorModel(workspaceRoot: workspaceRoot, sourceURL: previewURL))
    }

    var body: some View {
        Form {
            Section("media.media_editor_view.visual_editing") {
                Button("media.media_editor_view.trim_rotate_and_add_subtitles") { showVisualEditor = true }
                    .disabled(model.isExporting)
            }
            Section("media.media_editor_view.preview") {
                if model.exportedURL != nil {
                    Toggle("media.media_editor_view.play_the_processed_file", isOn: $previewOutput)
                }
                MediaPlayerView(url: previewOutput ? (model.exportedURL ?? model.sourceURL) : model.sourceURL)
                    .id(previewOutput ? model.exportedURL : model.sourceURL)
                Text(model.sourceURL.lastPathComponent).font(.caption).textSelection(.enabled)
            }
            Section("media.media_editor_view.single_asset_timeline") {
                Slider(value: $model.trimStart, in: 0...max(model.duration, 0.001))
                LabeledContent("media.media_editor_view.start_seconds") { TextField("media.media_editor_view.trim_start", value: $model.trimStart, format: .number).multilineTextAlignment(.trailing) }
                Slider(value: $model.trimEnd, in: 0...max(model.duration, 0.001))
                LabeledContent("media.media_editor_view.end_seconds") { TextField("media.media_editor_view.trim_end", value: $model.trimEnd, format: .number).multilineTextAlignment(.trailing) }
            }.disabled(model.isExporting)
            Section("media.media_editor_view.process_action") {
                LabeledContent("media.media_player_view.playback_speed") { TextField("media.media_editor_view.speed", value: $model.speed, format: .number).multilineTextAlignment(.trailing) }
                LabeledContent("media.media_editor_view.volume") { TextField("media.media_editor_view.volume", value: $model.volume, format: .number).multilineTextAlignment(.trailing) }
                Text("media.media_editor_view.the_enhancement_model_has_not_passed").font(.footnote).foregroundStyle(.secondary)
            }.disabled(model.isExporting)
            Section("media.media_editor_view.export_settings") {
                Picker("media.media_editor_view.encoder", selection: $model.videoCodec) {
                    Text("H.264").tag("h264")
                    Text("HEVC").tag("hevc")
                }
                TextField("media.media_editor_view.width_blank_to_use_the_asset", text: $model.width).keyboardType(.numberPad)
                TextField("media.media_editor_view.height_blank_to_use_the_asset", text: $model.height).keyboardType(.numberPad)
                TextField("media.media_editor_view.frame_rate_blank_to_use_the", text: $model.frameRate).keyboardType(.decimalPad)
                Text(FloeL10n.l("media.media_editor_view.output", model.outputPath)).font(.caption).textSelection(.enabled)
            }.disabled(model.isExporting)
            Section("background.task.name_fallback") {
                if model.isExporting {
                    ProgressView("media.media_editor_view.processing_and_verifying")
                    Button("workspace.workspace_canvas_view.cancel", role: .cancel) { model.cancel() }
                } else {
                    Button("media.media_editor_view.export_retry") { model.startExport() }
                    Button("media.media_editor_view.save_editing_parameters") { model.save() }
                }
                if !model.exportStatus.isEmpty { Text(model.exportStatus).font(.footnote).textSelection(.enabled) }
            }
        }
        .navigationTitle("media.media_editor_view.media_workbench")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("media.media_editor_view.close") { model.cancel(); dismiss() } } }
        .task { await model.load() }
        .fullScreenCover(isPresented: $showVisualEditor) {
            FloeVisualVideoEditor(root: model.workspaceRoot, source: model.sourceURL) { url in
                model.exportedURL = url
            }
        }
        .onChange(of: model.exportedURL) { _, url in
            if let url { onExported?(url) }
        }
        .onDisappear { model.cancel() }
    }
}

/// Workspace adapter for the pinned MIT VideoEditorKit. Manual captions stay on device.
private struct FloeVisualVideoEditor: View {
    let root: URL
    let source: URL
    let onExported: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = VideoEditingConfiguration.initial
    @State private var showEditor = false
    @State private var text = ""
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var duration = 0.0
    @State private var message = ""
    @State private var loaded = false
    @State private var copying = false
    @State private var output: URL?

    private var projectURL: URL {
        root.appendingPathComponent(".floe-media-edits").appendingPathComponent(
            FloeDigest.sha256Hex(Data(source.path.utf8)) + "-visual.json")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("media.media_editor_view.manual_subtitles") {
                    TextField("media.media_editor_view.subtitle_text_chinese_supported", text: $text, axis: .vertical)
                    LabeledContent("media.media_editor_view.asset_start_seconds") { TextField("media.media_editor_view.trim_start", value: $start, format: .number) }
                    LabeledContent("media.media_editor_view.asset_end_seconds") { TextField("media.media_editor_view.trim_end", value: $end, format: .number) }
                    Button("media.media_editor_view.add_subtitle") { addCaption() }.disabled(!loaded || copying)
                    Text("media.media_editor_view.times_follow_the_original_asset_inside")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(configuration.transcript.document?.segments ?? []) { segment in
                        HStack {
                            Text(segment.editedText)
                            Spacer()
                            Text(FloeL10n.l("media.media_editor_view.sec", segment.timeMapping.sourceStartTime, "%.1f", segment.timeMapping.sourceEndTime, "%.1f")).font(.caption)
                            Button(role: .destructive) {
                                configuration.transcript.document?.segments.removeAll { $0.id == segment.id }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Button("media.media_editor_view.open_visual_editor") { showEditor = true }.disabled(!loaded || copying)
                    Button("media.media_editor_view.save_project_parameters") { persist() }.disabled(!loaded || copying)
                    if copying { ProgressView("media.media_editor_view.verify_and_save_to_workspace") }
                    if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
                    if let output { MediaPlayerView(url: output) }
                }
            }
            .navigationTitle("media.media_editor_view.trim_and_subtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("media.media_editor_view.close") { dismiss() }.disabled(copying) } }
            .task { await load() }
            .fullScreenCover(isPresented: $showEditor) {
                VideoEditorView(FloeL10n.l("media.media_editor_view.media_workbench"), sourceVideoURL: source,
                    editingConfiguration: configuration,
                    configuration: .init(transcription: .init(provider: FloeVideoTranscriptionProvider(root: root))),
                    onSavedVideo: { saved in
                        configuration = saved.editingConfiguration
                        persist()
                        receive(saved.url)
                    }, onExportedVideoURL: { receive($0) })
            }
        }
        .interactiveDismissDisabled(copying)
    }

    private func owned(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
            root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_path_is_outside_the_current"))
        }
    }

    private func load() async {
        do {
            try owned(source); try owned(projectURL)
            duration = try await AVURLAsset(url: source).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.invalid_asset_duration")) }
            end = min(3, duration)
            configuration.trim = .init(lowerBound: 0, upperBound: duration)
            if FileManager.default.fileExists(atPath: projectURL.path) {
                configuration = try JSONDecoder().decode(VideoEditingConfiguration.self, from: Data(contentsOf: projectURL))
            }
            guard configuration.trim.lowerBound.isFinite, configuration.trim.upperBound.isFinite,
                  configuration.trim.lowerBound >= 0, configuration.trim.upperBound > configuration.trim.lowerBound,
                  configuration.trim.upperBound <= duration, configuration.playback.rate.isFinite,
                  configuration.playback.rate > 0 else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_saved_clip_range_or_speed")) }
            loaded = true
        } catch { message = error.localizedDescription }
    }

    private func addCaption() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2000, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= duration else {
            message = FloeL10n.l("media.media_editor_view.enter_subtitles_with_a_valid_asset"); return
        }
        var document = configuration.transcript.document ?? TranscriptDocument()
        guard document.segments.count < 200 else { message = FloeL10n.l("media.media_editor_view.a_project_can_contain_at_most"); return }
        guard !document.segments.contains(where: { start < $0.timeMapping.sourceEndTime && end > $0.timeMapping.sourceStartTime }) else {
            message = FloeL10n.l("media.media_editor_view.subtitle_times_cannot_overlap_adjust_the"); return
        }
        document.segments.append(.init(id: UUID(), timeMapping: .init(sourceStartTime: start, sourceEndTime: end), originalText: value, editedText: value))
        document.segments.sort { $0.timeMapping.sourceStartTime < $1.timeMapping.sourceStartTime }
        configuration.transcript = .init(featureState: .loaded, document: EditorTranscriptRemappingCoordinator.remap(document, trimRange: configuration.trim.lowerBound...configuration.trim.upperBound, playbackRate: configuration.playback.rate))
        text = ""
        persist()
    }

    private func persist() {
        do {
            try owned(projectURL)
            try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: projectURL, options: .atomic)
            message = FloeL10n.l("media.media_editor_view.project_parameters_saved_save_or_export")
        } catch { message = FloeL10n.l("media.media_editor_view.failed_to_save_project") + error.localizedDescription }
    }

    private func receive(_ url: URL) {
        guard !copying else { message = FloeL10n.l("media.media_editor_view.wait_for_the_current_file_to"); return }
        copying = true
        Task { @MainActor in
            defer { copying = false }
            let destination = source.deletingLastPathComponent().appendingPathComponent(
                source.deletingPathExtension().lastPathComponent + "-visual-" + UUID().uuidString + ".mp4")
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".floe-export-" + UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try owned(destination); try owned(staging)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: url, to: staging)
                }.value
                let asset = AVURLAsset(url: staging)
                let playable = try await asset.load(.isPlayable)
                let seconds = try await asset.load(.duration).seconds
                guard playable, seconds.isFinite, seconds > 0 else { throw FloeError.validationFailed(FloeL10n.l("media.media_editor_view.the_exported_file_cannot_be_played")) }
                try FileManager.default.moveItem(at: staging, to: destination)
                output = destination
                onExported(destination)
                message = FloeL10n.l("media.media_editor_view.saved_to_workspace") + destination.lastPathComponent
            } catch { message = FloeL10n.l("media.media_editor_view.failed_to_save_the_final_video") + error.localizedDescription }
        }
    }
}
#endif
