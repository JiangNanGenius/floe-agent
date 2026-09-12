// FloeApp — Lightweight timeline editor. Non-destructive: the model builds a
// VideoEditPlan, previews it through the shared player, and exports through
// the same engine the agent tools use. All values are explicit in the UI.
#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeMedia

@MainActor
final class MediaEditorModel: ObservableObject {
    @Published var inputPath: String = ""
    @Published var outputPath: String = ""
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var speed: Double = 1
    @Published var volume: Double = 1
    @Published var operations: [VideoEditPlan.Operation] = []
    @Published var exportStatus: String = ""
    @Published var isExporting = false
    @Published var container: String = "mp4"
    @Published var videoCodec: String = ""
    @Published var audioCodec: String = ""
    @Published var width: String = ""
    @Published var height: String = ""
    @Published var frameRate: String = ""

    var workspaceRoot: URL?

    func addTrim() {
        operations.append(.trim(start: trimStart, end: trimEnd))
    }

    func addSpeed() {
        operations.append(.speed(rate: speed))
    }

    func addVolume() {
        operations.append(.volume(level: volume))
    }

    func remove(at offsets: IndexSet) {
        operations.remove(atOffsets: offsets)
    }

    func export() async {
        guard let root = workspaceRoot, !inputPath.isEmpty, !outputPath.isEmpty else {
            exportStatus = "input and output are required"
            return
        }
        isExporting = true
        defer { isExporting = false }
        let export = VideoEditPlan.Export(
            container: container,
            videoCodec: videoCodec.isEmpty ? nil : videoCodec,
            audioCodec: audioCodec.isEmpty ? nil : audioCodec,
            videoBitrate: nil,
            audioBitrate: nil,
            width: Int(width),
            height: Int(height),
            frameRate: Double(frameRate),
            quality: nil,
            range: nil,
            hardwareAcceleration: nil
        )
        let plan = VideoEditPlan(input: inputPath, output: outputPath, operations: operations, export: export)
        do {
            let renderer = MediaRenderer(rootProvider: { root })
            let result = try await renderer.render(plan: plan)
            exportStatus = "exported \(result.outputPath) (\(result.byteCount) bytes)"
        } catch {
            exportStatus = "export failed: \(error.localizedDescription)"
        }
    }
}

struct MediaEditorView: View {
    @StateObject private var model = MediaEditorModel()
    private let previewURL: URL?

    init(workspaceRoot: URL?, previewURL: URL?) {
        self.previewURL = previewURL
        _model = StateObject(wrappedValue: {
            let model = MediaEditorModel()
            model.workspaceRoot = workspaceRoot
            return model
        }())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Source") {
                TextField("input path", text: $model.inputPath)
                TextField("output path", text: $model.outputPath)
            }
            if let previewURL {
                MediaPlayerView(url: previewURL)
                    .frame(minHeight: 220)
            }
            GroupBox("Operations") {
                HStack {
                    TextField("start", value: $model.trimStart, format: .number)
                    TextField("end", value: $model.trimEnd, format: .number)
                    Button("Trim") { model.addTrim() }
                }
                HStack {
                    TextField("speed", value: $model.speed, format: .number)
                    Button("Speed") { model.addSpeed() }
                    TextField("volume", value: $model.volume, format: .number)
                    Button("Volume") { model.addVolume() }
                }
                List {
                    ForEach(Array(model.operations.enumerated()), id: \.offset) { index, op in
                        Text("\(index + 1). \(String(describing: op))")
                    }
                    .onDelete { model.remove(at: $0) }
                }
                .frame(minHeight: 120)
            }
            GroupBox("Export") {
                TextField("container", text: $model.container)
                HStack {
                    TextField("video codec", text: $model.videoCodec)
                    TextField("audio codec", text: $model.audioCodec)
                }
                HStack {
                    TextField("width", text: $model.width)
                    TextField("height", text: $model.height)
                    TextField("frame rate", text: $model.frameRate)
                }
                Button("Export") {
                    Task { await model.export() }
                }
                .disabled(model.isExporting)
                Text(model.exportStatus)
                    .font(.footnote)
            }
        }
        .padding()
    }
}
#endif
