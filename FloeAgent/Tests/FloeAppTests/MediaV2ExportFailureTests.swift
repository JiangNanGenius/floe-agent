// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("Native media export failures", .serialized)
@MainActor struct MediaV2ExportFailureTests {
    @Test func mutingSourceAudioDoesNotHideTheVideoFrames() throws {
        let range = try MediaV2Session.range(start: 0, duration: 1)
        let clip = MediaPreparedClip(assetID: UUID(), timelineRange: range, sourceRange: range, isMuted: true)
        let track = MediaPreparedTrack(kind: .visual, name: "Source audio extracted", clips: [clip])
        let graph = MediaPreparedTrackGraph(tracks: [track])
        #expect(MediaV2Session.hasVisibleClips(graph))
        var hidden = graph; hidden.tracks[0].isMuted = true
        #expect(!MediaV2Session.hasVisibleClips(hidden))
    }
    @Test func emptyVideoReturnsAndRetainsOriginalErrorWithActionableDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-empty-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root)
        let original = MediaProject(kind: .video, name: "Empty export contract", canvas: .init(width: 160, height: 90, frameRate: 30), videoTimeline: .init())
        try await store.save(original)
        let session = try await MediaV2Session.open(projectID: original.id, root: root, store: store, upgrade: true)
        let file = store.projectURL(id: original.id), bytes = try Data(contentsOf: file)
        do {
            _ = try await session.exportAndWait()
            Issue.record("An empty video was reported as exported")
        } catch { #expect(error as? PreparedVideoError == .emptyTimeline) }
        #expect(session.exportError as? PreparedVideoError == .emptyTimeline)
        #expect(session.exportedFile == nil && !session.rendering)
        let diagnostic = try #require(session.diagnostic)
        #expect(diagnostic.contains("视频或图片") || diagnostic.contains("video or image"))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Exports").path))
    }
}
#endif
