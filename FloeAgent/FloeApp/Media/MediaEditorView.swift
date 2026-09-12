// FloeApp — Single-asset media editing, with persisted parameters and verified exports.
#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import FloeCore
import FloeMedia
import FloeTools

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
    @State private var previewOutput = false

    init(workspaceRoot: URL, previewURL: URL) {
        _model = StateObject(wrappedValue: MediaEditorModel(workspaceRoot: workspaceRoot, sourceURL: previewURL))
    }

    var body: some View {
        Form {
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
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.cancel(); dismiss() } } }
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }
}
#endif
