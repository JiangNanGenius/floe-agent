// FloeWorkbench — Model, command, transaction and persistence tests.

import Foundation
import Testing
import FloeCore
@testable import FloeWorkbench

@Suite("Media project model and transactions")
struct MediaProjectModelTests {
    private func imageProject() -> MediaProject {
        var project = MediaProject(kind: .image, name: "Test", canvas: MediaCanvas(width: 1000, height: 800))
        let asset = MediaAssetReference(kind: .image, relativePath: "assets/base.png", originalName: "base.png",
                                        metadata: MediaAssetMetadata(width: 1000, height: 800))
        project.assets = [asset]
        project.sourceAssetID = asset.id
        let base = ImageLayer(kind: .image, name: "Base", assetID: asset.id)
        project.imageLayers = [base]
        return project
    }

    @Test func layerStudioOrderUndoRedoIsMonotonic() throws {
        var project = imageProject()
        let baseID = project.imageLayers[0].id
        let text = ImageLayer(kind: .text, name: "Title",
                              text: ImageTextContent(text: "你好 Floe", fontSize: 64, colorHex: "#FF0000"))
        try MediaTransactions.apply(.addImageLayer(text), to: &project)
        #expect(project.revision == 1)
        #expect(project.imageLayers.count == 2)

        try MediaTransactions.apply(.moveLayer(id: text.id, toIndex: 0), to: &project)
        #expect(project.imageLayers.first?.id == text.id)
        #expect(project.revision == 2)

        #expect(MediaTransactions.undo(&project))
        #expect(project.imageLayers.first?.id == baseID)
        #expect(project.revision == 3, "undo must advance the revision, never restore an old one")

        #expect(MediaTransactions.redo(&project))
        #expect(project.imageLayers.first?.id == text.id)
        #expect(project.revision == 4)

        // Undo again then a new edit clears redo, and revisions stay monotonic.
        #expect(MediaTransactions.undo(&project))
        try MediaTransactions.apply(.updateLayer(id: baseID, transform: nil, opacity: 0.5,
                                                 isHidden: nil, isLocked: nil, adjustment: nil, text: nil, crop: .unchanged),
                                    to: &project)
        #expect(project.revision == 6)
        #expect(MediaTransactions.canRedo(project) == false)
    }

    @Test func failedCommandSequenceLeavesProjectUntouched() throws {
        var project = imageProject()
        let before = project
        let missing = UUID()
        let good = ImageLayer(kind: .text, name: "Caption", text: ImageTextContent(text: "hi"))
        // Sequence: valid add, then invalid update of a missing layer.
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply([.addImageLayer(good),
                                         .removeLayer(id: missing)], to: &project)
        }
        #expect(project.revision == before.revision)
        #expect(project.imageLayers.count == before.imageLayers.count)
        #expect(project.undoHistory.isEmpty)
    }

    @Test func lockedLayerRejectsGeometryEdits() throws {
        var project = imageProject()
        let layerID = project.imageLayers[0].id
        try MediaTransactions.apply(.updateLayer(id: layerID, transform: nil, opacity: nil,
                                                 isHidden: nil, isLocked: true, adjustment: nil, text: nil, crop: .unchanged),
                                    to: &project)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.updateLayer(id: layerID,
                                                     transform: ImageLayerTransform(centerX: 0.2, centerY: 0.2, scale: 1, rotationDegrees: 0),
                                                     opacity: nil, isHidden: nil, isLocked: nil,
                                                     adjustment: nil, text: nil, crop: .unchanged),
                                        to: &project)
        }
        // Opacity-only change on a locked layer is allowed (lock protects geometry).
        try MediaTransactions.apply(.updateLayer(id: layerID, transform: nil, opacity: 0.4,
                                                 isHidden: nil, isLocked: nil, adjustment: nil, text: nil, crop: .unchanged),
                                    to: &project)
        #expect(project.imageLayers[0].opacity == 0.4)
    }

    @Test func durableHistorySurvivesReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MediaProjectStore(directory: dir)
        var project = imageProject()
        try MediaTransactions.apply(.addImageLayer(ImageLayer(kind: .text, name: "A",
                                                              text: ImageTextContent(text: "A"))),
                                    to: &project)
        try await store.save(project)

        let reopened = try #require(try await store.loadProject(id: project.id))
        #expect(reopened.undoHistory.count == 1, "undo history must persist with the project")
        var mutable = reopened
        #expect(MediaTransactions.undo(&mutable))
        #expect(mutable.imageLayers.count == 1)
        #expect(mutable.revision == reopened.revision + 1)
    }

    @Test func saveCompareAndSwapRejectsStaleRevision() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MediaProjectStore(directory: dir)
        var project = imageProject()
        try await store.save(project)
        var advanced = project
        try MediaTransactions.apply(.setCanvas(width: 640, height: 480, frameRate: nil), to: &advanced)
        try await store.save(advanced)

        await #expect(throws: (any Error).self) {
            // Writing with the old revision must fail (document changed).
            try await store.save(project, expectedRevision: project.revision)
        }
        project.canvas = MediaCanvas(width: 320, height: 240)
        // The same stale content cannot overwrite the newer revision.
        let onDisk = try #require(try await store.loadProject(id: project.id))
        #expect(onDisk.canvas?.width == 640)
    }

    @Test func migrationPreservesUnknownOperationsAndReportsThem() throws {
        let legacy = Data("""
        {"input":"old.mp4","output":"out.mp4","operations":[{"op":"trim","start":0.5,"end":2.5},{"op":"magicEffect","strength":9}],"export":{"container":"mp4"}}
        """.utf8)
        let project = try MigrationSupport.migrateLegacyPlan(name: "Legacy", sourceRelativePath: "old.mp4",
                                                             data: legacy)
        #expect(project.kind == .video)
        #expect(project.videoTimeline?.clips.first?.trimStart == 0.5)
        #expect(project.videoTimeline?.clips.first?.trimEnd == 2.5)
        #expect(project.unknownOperations.count == 1)
        #expect(project.unknownOperations.first?.kind == "magicEffect")
        #expect(project.unknownOperations.first?.payload.isEmpty == false)
        #expect(project.recoveryWarnings.contains { $0.contains("magicEffect") })
    }

    @Test func missingAssetRelinkKeepsEdits() throws {
        var project = imageProject()
        let layer = ImageLayer(kind: .text, name: "Kept", text: ImageTextContent(text: "keep me"))
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        let assetID = project.assets[0].id
        try MediaTransactions.apply(.relinkAsset(assetID: assetID, relativePath: "moved/base.png"),
                                    to: &project)
        #expect(project.assets[0].relativePath == "moved/base.png")
        #expect(project.imageLayers.count == 2, "relink must not discard edits")
    }

    @Test func clipSplitAndReorder() throws {
        let asset = MediaAssetReference(kind: .video, relativePath: "v.mp4", originalName: "v.mp4",
                                        metadata: MediaAssetMetadata(durationSeconds: 10, frameRate: 30))
        var project = MediaProject(kind: .video, name: "V", canvas: MediaCanvas(width: 640, height: 360, frameRate: 30),
                                   assets: [asset], sourceAssetID: asset.id)
        let clip = VideoClip(assetID: asset.id, trimStart: 0, trimEnd: 4)
        try MediaTransactions.apply(.appendClip(clip), to: &project)
        try MediaTransactions.apply(.splitClip(id: clip.id, atTimelineSeconds: 2), to: &project)
        let clips = try #require(project.videoTimeline?.clips)
        #expect(clips.count == 2)
        #expect(abs(clips[0].trimEnd - 2) < 0.0001)
        #expect(abs(clips[1].trimStart - 2) < 0.0001)
        #expect(clips[1].leadingTransition == .none)
        try MediaTransactions.apply(.reorderClips(orderedIDs: [clips[1].id, clips[0].id]), to: &project)
        #expect(project.videoTimeline?.clips.first?.trimStart == 2)
    }

    @Test func timelineMathRetimesSpeedAndDissolves() {
        let a = VideoClip(assetID: UUID(), trimStart: 0, trimEnd: 4, speed: 2) // 2s
        let b = VideoClip(assetID: UUID(), trimStart: 0, trimEnd: 6, speed: 1,
                          leadingTransition: .crossDissolve, transitionDuration: 1)
        let placed = MediaTimelineMath.placeClips([a, b])
        #expect(abs(placed[0].timelineEnd - 2) < 0.0001)
        #expect(abs(placed[1].timelineStart - 1) < 0.0001, "dissolve overlaps tail by 1s")
        #expect(abs(placed[1].timelineEnd - 7) < 0.0001)
        let windows = MediaTimelineMath.dissolveWindows(placed)
        #expect(windows.count == 1)
        #expect(abs(windows[0].duration - 1) < 0.0001)
        // Source mapping through speed retiming.
        let source = MediaTimelineMath.sourceTime(for: placed[0], timeline: 1.5)
        #expect(abs((source ?? 0) - 3) < 0.0001)
    }

    @Test func captionsRetimeWithSpeedChange() {
        // Clip was 4s; speed 2 halves it to 2s.
        let spedUp = VideoClip(assetID: UUID(), trimStart: 0, trimEnd: 4, speed: 2)
        let clipAfter = MediaTimelineMath.placeClips([spedUp])[0]
        let captions = [CaptionSegment(start: 1, end: 1.5, text: "one"),
                        CaptionSegment(start: 3, end: 3.5, text: "two")]
        let retimed = MediaTimelineMath.retimeCaptions(captions, clipAfter: clipAfter,
                                                       previousDuration: 4)
        #expect(abs(retimed[0].start - 1) < 0.0001)
        #expect(abs(retimed[1].start - 1.0) < 0.0001)
        #expect(retimed[1].end <= 2.0 + 0.0001, "captions may not exceed the new clip length")
    }

    @Test func noOpCommandsDoNotAdvanceRevisionOrUndo() throws {
        var project = imageProject()
        let layerID = project.imageLayers[0].id
        let before = project.revision

        // Same-value opacity update: no revision, no empty undo step.
        try MediaTransactions.apply(.updateLayer(id: layerID, transform: nil, opacity: 1,
                                                 isHidden: nil, isLocked: nil, adjustment: nil,
                                                 text: nil, crop: .unchanged), to: &project)
        #expect(project.revision == before)
        #expect(project.undoHistory.isEmpty)

        // Reorder to the same order is also a no-op.
        try MediaTransactions.apply(.reorderLayers(orderedIDs: project.imageLayers.map(\.id)),
                                    to: &project)
        #expect(project.revision == before)
        #expect(project.undoHistory.isEmpty)

        // A real change still lands exactly once.
        try MediaTransactions.apply(.updateLayer(id: layerID, transform: nil, opacity: 0.5,
                                                 isHidden: nil, isLocked: nil, adjustment: nil,
                                                 text: nil, crop: .unchanged), to: &project)
        #expect(project.revision == before + 1)
        #expect(project.undoHistory.count == 1)
        #expect(project.imageLayers[0].opacity == 0.5)
    }

    @Test func bigImageGuardOffersScaledCopy() {
        let decision = MediaResourceGuard.evaluateImage(width: 30_000, height: 20_000)
        if case .offerScaledCopy(let maxEdge) = decision {
            #expect(maxEdge > 0 && maxEdge <= 16384)
        } else {
            Issue.record("oversized image must offer a scaled copy, got \(decision)")
        }
        let normal = MediaResourceGuard.evaluateImage(width: 1024, height: 768)
        #expect(normal == .fullResolution)
    }
}
