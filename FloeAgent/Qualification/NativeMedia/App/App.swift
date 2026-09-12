import SwiftUI
import AVFoundation
import FloeMedia

@main struct SmokeApp: App {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var body: some Scene {
        WindowGroup {
            NavigationStack { MediaEditorView(workspaceRoot: root, previewURL: root.appendingPathComponent("input.mov")) }
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--model-smoke") { await qualifyModel() }
                }
        }
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
