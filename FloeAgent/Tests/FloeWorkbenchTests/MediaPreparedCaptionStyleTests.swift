// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("Prepared subtitle style persistence and undo")
struct MediaPreparedCaptionStyleTests {
    private func project() -> MediaProject {
        .init(kind: .video, name: "Caption contract", canvas: .init(width: 160, height: 90, frameRate: 30),
              videoTimeline: .init(captions: [.init(start: 0, end: 3, text: "Original caption")]))
    }
    @Test func styleOnlyCommitReopensAndUndoPreservesLaterCaptionEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-style-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root), original = project()
        try await store.save(original)
        let coordinator = MediaPreparedCoordinator(store: store)
        let before = try await coordinator.upgradeDocument(id: original.id)
        let style = CaptionStyle(fontSize: 52, colorHex: "#FFFFFFFF", backgroundHex: nil, positionY: 0.5, alignment: .leading, respectsSafeArea: false)
        let commit = try await coordinator.applyUserOperations([.init(action: .setCaptionStyle(expectedRevision: 0, style: style))], to: original.id, actor: .model)
        #expect(commit.touched == [.init(kind: .captionStyle, id: original.id)])
        let reopened = try #require(try await MediaProjectStore(directory: root).loadProject(id: original.id))
        #expect(reopened.prepared?.trackGraph.captionStyle == style)
        #expect(reopened.prepared?.trackGraph.tracks == before.trackGraph.tracks)
        #expect(reopened.videoTimeline == original.videoTimeline, "The v1 projection remains preserved")
        #expect(reopened.preparedJournal?.entry(commit.groupID)?.changes.count == 1)
        try MediaPreparedIntegrity.validateEnvelope(reopened)
        let styled = try #require(reopened.prepared)
        let track = try #require(styled.trackGraph.tracks.first { $0.kind == .caption })
        var caption = try #require(track.clips.first); caption.captionText = "Later text edit"
        _ = try await coordinator.applyUserOperations([.init(action: .replaceClip(trackID: track.id, clipID: caption.id,
            expectedRevision: caption.revision, clip: caption))], to: original.id)
        _ = try await coordinator.undoGroup(commit.groupID, in: original.id)
        let undone = try #require(try await MediaProjectStore(directory: root).loadProject(id: original.id))
        #expect(undone.prepared?.trackGraph.captionStyle == before.trackGraph.captionStyle)
        #expect(undone.prepared?.trackGraph.clip(id: caption.id)?.clip.captionText == "Later text edit")
        #expect(undone.prepared?.trackGraph.captionStyleRevision == 2)
        #expect(undone.preparedJournal?.entry(commit.groupID)?.status == .undone)
    }
    @Test func generationPreventsStaleWritesAndABAUndoWithoutChangingDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root), original = project()
        try await store.save(original)
        let coordinator = MediaPreparedCoordinator(store: store)
        _ = try await coordinator.upgradeDocument(id: original.id)
        let a = CaptionStyle(positionY: 0.5), b = CaptionStyle(positionY: 0.7)
        let first = try await coordinator.applyUserOperations([.init(action: .setCaptionStyle(expectedRevision: 0, style: a))], to: original.id)
        _ = try await coordinator.applyUserOperations([.init(action: .setCaptionStyle(expectedRevision: 1, style: b))], to: original.id)
        _ = try await coordinator.applyUserOperations([.init(action: .setCaptionStyle(expectedRevision: 2, style: a))], to: original.id)
        let file = store.projectURL(id: original.id), bytes = try Data(contentsOf: file)
        let styleRef = MediaPreparedObjectRef(kind: .captionStyle, id: original.id)
        do {
            _ = try await coordinator.undoGroup(first.groupID, in: original.id)
            Issue.record("ABA style content allowed undo over a newer generation")
        } catch { #expect(error as? MediaPreparedCoreError == .staleObject(styleRef)) }
        #expect(try Data(contentsOf: file) == bytes)
        do {
            _ = try await coordinator.applyUserOperations([.init(action: .setCaptionStyle(expectedRevision: 1, style: b))], to: original.id)
            Issue.record("A stale style generation was committed")
        } catch { #expect(error as? MediaPreparedCoreError == .staleObject(styleRef)) }
        #expect(try Data(contentsOf: file) == bytes)
        let instruction = try await coordinator.beginInstruction(documentID: original.id, targets: [styleRef], actor: .model)
        do {
            _ = try await coordinator.applyUserOperations([.init(action: .setCaptionStyle(expectedRevision: 3, style: b))], to: original.id)
            Issue.record("A style lease was bypassed")
        } catch { #expect(error as? MediaPreparedCoreError == .busyObject(styleRef)) }
        try await coordinator.stop(instruction)
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test func malformedStyleRollsBackWholeBatchAndOldGraphsDecodeWithoutGeneration() throws {
        let legacy = try MediaPreparedUpgrade.upgrade(project())
        let before = try #require(legacy.prepared)
        let graph = try JSONDecoder().decode(MediaPreparedTrackGraph.self, from: JSONEncoder().encode(before.trackGraph))
        #expect(graph.captionStyleRevision == nil)
        for style in [CaptionStyle(fontSize: 0), CaptionStyle(positionY: 1.1), CaptionStyle(colorHex: "#NOTHEX")] {
            var document = before
            do {
                _ = try MediaPreparedEngine.apply([
                    .init(action: .insertTrack(track: .init(kind: .caption, name: "Must roll back"), index: nil)),
                    .init(action: .setCaptionStyle(expectedRevision: 0, style: style))
                ], to: &document)
                Issue.record("An invalid caption style committed")
            } catch { #expect(error is MediaPreparedCoreError) }
            #expect(document == before)
        }
    }
}
