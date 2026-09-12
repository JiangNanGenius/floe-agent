import SwiftUI
import AVFoundation
import FloeMedia
import VideoEditorKit

@main struct SmokeApp: App {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @State private var imageSaved = false
    @State private var imageEditorPresented = true
    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--image-editor") {
                    if imageSaved {
                        Text("图像副本已保存").accessibilityIdentifier("image.export.saved")
                    } else {
                        Text("编辑已关闭").accessibilityIdentifier("image.editor.closed")
                            .fullScreenCover(isPresented: $imageEditorPresented) {
                                FloeImageEditorView(sourceURL: imageFixtureURL) { data in
                                    try data.write(to: root.appendingPathComponent("image-editor-output.png"), options: .atomic)
                                    imageSaved = true
                                    imageEditorPresented = false
                                }
                            }
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--library-editor") {
                    VideoEditorView("Floe", sourceVideoURL: root.appendingPathComponent("input.mov"), configuration: .init(transcription: .init()))
                } else {
                    NavigationStack { MediaEditorView(workspaceRoot: root, previewURL: root.appendingPathComponent("input.mov")) }
                }
            }
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--model-smoke") { await qualifyModel() }
                }
        }
    }

    @MainActor private var imageFixtureURL: URL {
        let url = root.appendingPathComponent("image-editor-source.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
                UIColor.systemOrange.setFill()
                context.fill(CGRect(x: 100, y: 100, width: 300, height: 250))
                ("Floe 图像工作台" as NSString).draw(at: CGPoint(x: 80, y: 450), withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.white])
            }
            try? image.pngData()?.write(to: url, options: .atomic)
        }
        return url
    }

    @MainActor private func qualifyModel() async {
        var result: [String: Any] = [:]
        do {
            let source = root.appendingPathComponent("input.mov")
            let first = MediaEditorModel(workspaceRoot: root, sourceURL: source)
            await first.load()
            first.trimStart = 1
            first.trimEnd = 5
            first.speed = 2
            first.volume = 0.5
            first.width = "320"
            first.height = "180"
            first.frameRate = "15"
            first.save()
            let reopened = MediaEditorModel(workspaceRoot: root, sourceURL: source)
            await reopened.load()
            result["savedAndReopened"] = reopened.trimStart == 1 && reopened.trimEnd == 5 && reopened.speed == 2 && reopened.volume == 0.5 && reopened.width == "320"
            reopened.startExport()
            let deadline = Date().addingTimeInterval(60)
            while reopened.isExporting && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard let output = reopened.exportedURL, !reopened.isExporting else {
                reopened.cancel()
                throw CocoaError(.fileWriteUnknown)
            }
            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw CocoaError(.fileReadCorruptFile) }
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration).seconds
            result["dimensionsApplied"] = size == CGSize(width: 320, height: 180)
            result["frameRateApplied"] = abs(fps - 15) < 0.1
            result["trimAndSpeedApplied"] = abs(duration - 2) < 0.2
            result["playable"] = try await asset.load(.isPlayable)
            result["sourcePreserved"] = FileManager.default.fileExists(atPath: source.path)
            result["passed"] = result.values.allSatisfy { ($0 as? Bool) == true }
        } catch {
            result["passed"] = false
            result["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("media-model-results.json"), options: .atomic)
        }
    }
}
