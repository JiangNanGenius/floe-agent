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
        guard !inputPath.isEmpty else { exportStatus = "素材必须属于当前工作区"; return }
        do {
            let asset = AVURLAsset(url: sourceURL)
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw FloeError.validationFailed("素材时长无效") }
            trimEnd = duration
            guard projectURL.resolvingSymlinksInPath().path.hasPrefix(workspaceRoot.path + "/") else {
                throw FloeError.validationFailed("编辑工程路径越出工作区")
            }
            if FileManager.default.fileExists(atPath: projectURL.path) {
                let saved = try JSONDecoder().decode(VideoEditPlan.self, from: Data(contentsOf: projectURL))
                guard saved.input == inputPath else { throw FloeError.validationFailed("编辑工程与素材不匹配") }
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
                    default: throw FloeError.validationFailed("此编辑工程包含当前工作台未支持的操作")
                    }
                }
            }
        } catch { exportStatus = error.localizedDescription }
    }

    func plan() throws -> VideoEditPlan {
        func integer(_ text: String) throws -> Int? {
            if text.isEmpty { return nil }
            guard let value = Int(text), value > 0 else { throw FloeError.validationFailed("尺寸必须是正整数") }
            return value
        }
        let fps: Double?
        if frameRate.isEmpty { fps = nil }
        else {
            guard let value = Double(frameRate), value.isFinite, value > 0 else { throw FloeError.validationFailed("帧率必须是正数") }
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
                throw FloeError.validationFailed("编辑工程目录越出工作区")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: projectURL, options: .atomic)
            exportStatus = "编辑参数已保存"
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
            exportStatus = "正在处理与验证输出…"
            exportTask = Task {
                defer { isExporting = false; cancellation = nil; exportTask = nil }
                do {
                    let root = workspaceRoot
                    let result = try await MediaRenderer(rootProvider: { root }).render(plan: plan, cancellation: token)
                    exportedURL = result.outputPath.hasPrefix("/") ? URL(fileURLWithPath: result.outputPath) : workspaceRoot.appendingPathComponent(result.outputPath)
                    exportStatus = "已导出到工作区：\(result.outputPath)"
                } catch { exportStatus = "处理未完成：\(error.localizedDescription)" }
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
            Section("可视化编辑") {
                Button("剪裁、旋转与添加字幕") { showVisualEditor = true }
                    .disabled(model.isExporting)
            }
            Section("预览") {
                if model.exportedURL != nil {
                    Toggle("播放处理后的文件", isOn: $previewOutput)
                }
                MediaPlayerView(url: previewOutput ? (model.exportedURL ?? model.sourceURL) : model.sourceURL)
                    .id(previewOutput ? model.exportedURL : model.sourceURL)
                Text(model.sourceURL.lastPathComponent).font(.caption).textSelection(.enabled)
            }
            Section("单素材时间线") {
                Slider(value: $model.trimStart, in: 0...max(model.duration, 0.001))
                LabeledContent("起点（秒）") { TextField("起点", value: $model.trimStart, format: .number).multilineTextAlignment(.trailing) }
                Slider(value: $model.trimEnd, in: 0...max(model.duration, 0.001))
                LabeledContent("终点（秒）") { TextField("终点", value: $model.trimEnd, format: .number).multilineTextAlignment(.trailing) }
            }.disabled(model.isExporting)
            Section("处理操作") {
                LabeledContent("播放速度") { TextField("速度", value: $model.speed, format: .number).multilineTextAlignment(.trailing) }
                LabeledContent("音量") { TextField("音量", value: $model.volume, format: .number).multilineTextAlignment(.trailing) }
                Text("增强模型尚未完成推理验收").font(.footnote).foregroundStyle(.secondary)
            }.disabled(model.isExporting)
            Section("导出设置") {
                Picker("编码器", selection: $model.videoCodec) {
                    Text("H.264").tag("h264")
                    Text("HEVC").tag("hevc")
                }
                TextField("宽度（留空沿用素材）", text: $model.width).keyboardType(.numberPad)
                TextField("高度（留空沿用素材）", text: $model.height).keyboardType(.numberPad)
                TextField("帧率（留空沿用素材）", text: $model.frameRate).keyboardType(.decimalPad)
                Text("输出：\(model.outputPath)").font(.caption).textSelection(.enabled)
            }.disabled(model.isExporting)
            Section("任务") {
                if model.isExporting {
                    ProgressView("正在处理与验证")
                    Button("取消", role: .cancel) { model.cancel() }
                } else {
                    Button("导出 / 重试") { model.startExport() }
                    Button("保存编辑参数") { model.save() }
                }
                if !model.exportStatus.isEmpty { Text(model.exportStatus).font(.footnote).textSelection(.enabled) }
            }
        }
        .navigationTitle("媒体工作台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.cancel(); dismiss() } } }
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
                Section("手工字幕") {
                    TextField("字幕文字（支持中文）", text: $text, axis: .vertical)
                    LabeledContent("素材起点（秒）") { TextField("起点", value: $start, format: .number) }
                    LabeledContent("素材终点（秒）") { TextField("终点", value: $end, format: .number) }
                    Button("添加字幕") { addCaption() }.disabled(!loaded || copying)
                    Text("时间以原素材为准；进入编辑器后可调整字幕文字、位置和大小。裁剪和变速会重新映射字幕时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(configuration.transcript.document?.segments ?? []) { segment in
                        HStack {
                            Text(segment.editedText)
                            Spacer()
                            Text("\(segment.timeMapping.sourceStartTime, specifier: "%.1f")–\(segment.timeMapping.sourceEndTime, specifier: "%.1f") 秒").font(.caption)
                            Button(role: .destructive) {
                                configuration.transcript.document?.segments.removeAll { $0.id == segment.id }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Button("打开可视化编辑器") { showEditor = true }.disabled(!loaded || copying)
                    Button("保存工程参数") { persist() }.disabled(!loaded || copying)
                    if copying { ProgressView("验证并保存到工作区…") }
                    if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
                    if let output { MediaPlayerView(url: output) }
                }
            }
            .navigationTitle("剪裁与字幕")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(copying) } }
            .task { await load() }
            .fullScreenCover(isPresented: $showEditor) {
                VideoEditorView("媒体工作台", sourceVideoURL: source,
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
            throw FloeError.validationFailed("路径越出当前工作区")
        }
    }

    private func load() async {
        do {
            try owned(source); try owned(projectURL)
            duration = try await AVURLAsset(url: source).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw FloeError.validationFailed("素材时长无效") }
            end = min(3, duration)
            configuration.trim = .init(lowerBound: 0, upperBound: duration)
            if FileManager.default.fileExists(atPath: projectURL.path) {
                configuration = try JSONDecoder().decode(VideoEditingConfiguration.self, from: Data(contentsOf: projectURL))
            }
            guard configuration.trim.lowerBound.isFinite, configuration.trim.upperBound.isFinite,
                  configuration.trim.lowerBound >= 0, configuration.trim.upperBound > configuration.trim.lowerBound,
                  configuration.trim.upperBound <= duration, configuration.playback.rate.isFinite,
                  configuration.playback.rate > 0 else { throw FloeError.validationFailed("保存的剪辑范围或速度无效") }
            loaded = true
        } catch { message = error.localizedDescription }
    }

    private func addCaption() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2000, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= duration else {
            message = "请输入字幕及有效的素材时间范围（单条最多 2000 字）"; return
        }
        var document = configuration.transcript.document ?? TranscriptDocument()
        guard document.segments.count < 200 else { message = "单个工程最多添加 200 条字幕"; return }
        guard !document.segments.contains(where: { start < $0.timeMapping.sourceEndTime && end > $0.timeMapping.sourceStartTime }) else {
            message = "字幕时间不能重叠，请调整起止时间"; return
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
            message = "工程参数已保存；成片请在编辑器内保存或导出"
        } catch { message = "保存工程失败：" + error.localizedDescription }
    }

    private func receive(_ url: URL) {
        guard !copying else { message = "请等待当前文件保存完成"; return }
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
                guard playable, seconds.isFinite, seconds > 0 else { throw FloeError.validationFailed("导出文件不可播放") }
                try FileManager.default.moveItem(at: staging, to: destination)
                output = destination
                onExported(destination)
                message = "已保存到工作区：" + destination.lastPathComponent
            } catch { message = "保存成片失败：" + error.localizedDescription }
        }
    }
}
#endif
