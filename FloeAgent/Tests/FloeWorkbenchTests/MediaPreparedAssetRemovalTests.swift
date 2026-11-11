// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("Prepared asset removal", .serialized)
struct MediaPreparedAssetRemovalTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("media-asset-removal-\(UUID())") }
    private func asset(_ name: String = "original.png") -> MediaAssetReference {
        .init(kind: .image, relativePath: "Assets/\(name)", originalName: name)
    }
    private func unusedProject(_ assets: [MediaAssetReference]) throws -> MediaProject {
        try MediaPreparedUpgrade.upgrade(.init(kind: .image, name: "Assets", canvas: .init(width: 64, height: 64), assets: assets))
    }

    @Test func useDeleteRemoveUndoRedoAndColdReopenRetainOriginalBytes() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory), coordinator = MediaPreparedCoordinator(store: store)
        let imported = asset(), sibling = asset("sibling.png")
        let p = MediaProject(kind: .image, name: "Import", canvas: .init(width: 64, height: 64))
        try await store.save(p); _ = try await coordinator.upgradeDocument(id: p.id)
        let source = directory.appendingPathComponent(imported.relativePath), bytes = Data("unchanged original bytes".utf8)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: source)
        let layer = MediaPreparedLayer(name: "Imported layer", content: .raster(.init(source: .asset(imported.id))))
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(imported)), .init(action: .insertAsset(sibling)), .init(action: .insertLayer(layer: layer, parentID: nil, index: nil))], to: p.id)
        let used = try await coordinator.loadDocument(id: p.id)
        #expect(throws: MediaPreparedAssetRemovalError.self) { try MediaPreparedAssets.removal(assetID: imported.id, in: used) }
        let currentLayer = try #require(used.layer(layer.id))
        _ = try await coordinator.applyUserOperations([.init(action: .removeLayer(id: layer.id, expectedRevision: currentLayer.revision))], to: p.id)
        let before = try await coordinator.loadDocument(id: p.id)
        let removal = try MediaPreparedAssets.removal(assetID: imported.id, in: before)
        // The model-facing operation uses the same codec and canonical engine.
        let decoded = try JSONDecoder().decode(MediaPreparedOperation.self, from: JSONEncoder().encode(removal))
        let commit = try await coordinator.applyUserOperations([decoded], to: p.id, actor: .model)
        #expect(try await store.loadProject(id: p.id)?.prepared?.assets.map(\.id) == [sibling.id])
        #expect(try Data(contentsOf: source) == bytes)
        let reopened = MediaPreparedCoordinator(store: MediaProjectStore(directory: directory))
        _ = try await reopened.undoGroup(commit.groupID, in: p.id)
        let restored = try await reopened.loadDocument(id: p.id)
        #expect(restored.assets == [imported, sibling])
        #expect((restored.assetRevisions?[imported.id] ?? 0) > (before.assetRevisions?[imported.id] ?? 0))
        _ = try await reopened.redoGroup(commit.groupID, in: p.id)
        let cold = try #require(try await MediaProjectStore(directory: directory).loadProject(id: p.id))
        #expect(cold.prepared?.asset(imported.id) == nil)
        #expect(!cold.assets.contains { $0.id == imported.id })
        #expect(cold.prepared?.assetRevisions?[imported.id] == nil)
        #expect(MediaPreparedAssets.retainedAssets(in: cold).contains(imported))
        try MediaPreparedIntegrity.validateEnvelope(cold)
        #expect(try Data(contentsOf: source) == bytes)
        _ = try await reopened.undoGroup(commit.groupID, in: p.id)
        #expect(try await reopened.loadDocument(id: p.id).asset(imported.id) == imported)
    }

    @Test func activeSourceLockedLayerClipAndOpaqueContentRefuseWithoutMutation() throws {
        let a = asset(), range = try MediaTimeRange(start: .seconds(0), duration: .seconds(1))
        let layer = MediaPreparedLayer(name: "Locked layer", isLocked: true, content: .raster(.init(source: .asset(a.id))))
        let clip = MediaPreparedClip(assetID: a.id, timelineRange: range, sourceRange: range)
        var d = MediaPreparedDocument(id: UUID(), kind: .video, name: "References", assets: [a], sourceAssetID: a.id, layers: [layer], trackGraph: .init(tracks: [.init(kind: .visual, name: "Locked video", isLocked: true, clips: [clip])]))
        d.unknownOperations = [.init(kind: "future", payload: Data("opaque".utf8))]
        let uses = MediaPreparedAssets.references(to: a.id, in: d)
        #expect(Set(uses.map(\.kind)) == [.source, .layer, .clip, .unknownContent])
        #expect(uses.filter(\.isLocked).count == 2)
        let before = d
        #expect(throws: MediaPreparedAssetRemovalError.self) {
            try MediaPreparedEngine.apply([.init(action: .removeAsset(expected: a, expectedRevision: 0))], to: &d)
        }
        #expect(d == before)
    }

    @Test func compoundRetainedSourceAndProxyStayProtected() throws {
        let a = asset(), range = try MediaTimeRange(start: .seconds(0), duration: .seconds(1))
        let clip = MediaPreparedClip(assetID: a.id, timelineRange: range, sourceRange: range)
        var d = MediaPreparedDocument(id: UUID(), kind: .video, name: "Compound", canvas: .init(width: 64, height: 64, frameRate: 30), assets: [a], trackGraph: .init(tracks: [.init(kind: .visual, name: "Visual", clips: [clip])]))
        let selected = try MediaPreparedCompounds.selection(clipIDs: [clip.id], in: d)
        let proxy = MediaAssetReference(kind: .video, relativePath: "proxy.mov", originalName: "Proxy", contentHash: String(repeating: "a", count: 64))
        let binding = MediaPreparedCompoundProxy(video: proxy, audio: nil, sourceSHA256: selected.sourceSHA256, settingsIdentity: "fixture", duration: try .seconds(1))
        let operations = try MediaPreparedCompounds.creationOperations(selection: selected, proxy: binding, name: "Retained source", in: d)
        _ = try MediaPreparedEngine.apply(operations, to: &d)
        #expect(MediaPreparedAssets.references(to: a.id, in: d).contains { $0.kind == .compound })
        #expect(MediaPreparedAssets.references(to: proxy.id, in: d).contains { $0.kind == .compound })
        let before = d
        #expect(throws: MediaPreparedAssetRemovalError.self) { try MediaPreparedEngine.apply([.init(action: .removeAsset(expected: a, expectedRevision: 0))], to: &d) }
        #expect(d == before)
    }

    @Test func staleIdentityGenerationAndBatchFailureAreAtomic() throws {
        let a = asset(), b = asset("other.png")
        var d = try #require(unusedProject([a, b]).prepared)
        d.assetRevisions = [a.id: 3]
        let before = d
        #expect(throws: MediaPreparedCoreError.self) {
            try MediaPreparedEngine.apply([.init(action: .removeAsset(expected: a, expectedRevision: 2))], to: &d)
        }
        var altered = a; altered.relativePath = "another-original.png"
        #expect(throws: MediaPreparedCoreError.self) {
            try MediaPreparedEngine.apply([.init(action: .removeAsset(expected: altered, expectedRevision: 3))], to: &d)
        }
        #expect(throws: MediaPreparedCoreError.self) {
            try MediaPreparedEngine.apply([.init(action: .removeAsset(expected: a, expectedRevision: 3)), .init(action: .removeAsset(expected: b, expectedRevision: 9))], to: &d)
        }
        #expect(d == before)
    }

    @Test func undoImportCannotRemoveAnAssetUsedByLaterWork() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory), c = MediaPreparedCoordinator(store: store)
        let p = MediaProject(kind: .image, name: "Later work", canvas: .init(width: 64, height: 64)), a = asset()
        try await store.save(p); _ = try await c.upgradeDocument(id: p.id)
        let imported = try await c.applyUserOperations([.init(action: .insertAsset(a))], to: p.id)
        let layer = MediaPreparedLayer(name: "Later layer", content: .raster(.init(source: .asset(a.id))))
        _ = try await c.applyUserOperations([.init(action: .insertLayer(layer: layer, parentID: nil, index: nil))], to: p.id)
        let bytes = try Data(contentsOf: store.projectURL(id: p.id))
        do { _ = try await c.undoGroup(imported.groupID, in: p.id); Issue.record("Undo discarded a source used by later work") }
        catch { #expect(error is MediaPreparedAssetRemovalError) }
        #expect(try Data(contentsOf: store.projectURL(id: p.id)) == bytes)
        #expect(try await c.loadDocument(id: p.id).asset(a.id) == a)
    }

    @Test func leaseStaleDiskCASAndCancelledInstructionPreserveSavedOriginal() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = asset(), p = try unusedProject([a]), store = MediaProjectStore(directory: directory)
        try await store.save(p)
        let coordinator = MediaPreparedCoordinator(store: store), ref = MediaPreparedObjectRef(kind: .asset, id: a.id)
        let op = try MediaPreparedAssets.removal(assetID: a.id, in: try #require(p.prepared))
        let owner = try await coordinator.beginInstruction(documentID: p.id, targets: [ref], actor: .model)
        let bytes = try Data(contentsOf: store.projectURL(id: p.id))
        do { _ = try await coordinator.applyUserOperations([op], to: p.id); Issue.record("Asset lease bypassed") }
        catch { #expect(error as? MediaPreparedCoreError == .busyObject(ref)) }
        try await coordinator.stop(owner)
        let cancelled = try await coordinator.beginInstruction(documentID: p.id, targets: [ref], actor: .model)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.apply([op], instruction: cancelled)
        }
        do { _ = try await operation.value; Issue.record("Cancelled removal committed") } catch { #expect(error is CancellationError) }
        try await coordinator.stop(cancelled)
        #expect(try Data(contentsOf: store.projectURL(id: p.id)) == bytes)
        let stale = try await coordinator.beginInstruction(documentID: p.id, targets: [ref], actor: .model)
        let other = MediaPreparedCoordinator(store: MediaProjectStore(directory: directory))
        _ = try await other.applyUserOperations([.init(action: .insertLayer(layer: .init(name: "Concurrent edit", content: .strokes(.init())), parentID: nil, index: nil))], to: p.id)
        let currentBytes = try Data(contentsOf: store.projectURL(id: p.id))
        do { _ = try await coordinator.apply([op], instruction: stale); Issue.record("Stale disk CAS succeeded") }
        catch { #expect(String(describing: error).contains("Project revision conflict")) }
        try await coordinator.stop(stale)
        #expect(try Data(contentsOf: store.projectURL(id: p.id)) == currentBytes)
        #expect(try await other.reloadDocument(id: p.id).asset(a.id) == a)
    }

    @Test func failedDurableWriteDoesNotPublishRemovalOrLoseBytes() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = asset(), p = try unusedProject([a]), store = MediaProjectStore(directory: directory)
        try await store.save(p)
        let url = store.projectURL(id: p.id), bytes = try Data(contentsOf: url)
        let boundedStore = MediaProjectStore(directory: directory, limits: .init(maximumDocumentBytes: bytes.count))
        let coordinator = MediaPreparedCoordinator(store: boundedStore)
        let op = try MediaPreparedAssets.removal(assetID: a.id, in: try await coordinator.loadDocument(id: p.id))
        do { _ = try await coordinator.applyUserOperations([op], to: p.id); Issue.record("Oversized journal write succeeded") }
        catch { #expect(String(describing: error).contains("Project document exceeds")) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await coordinator.loadDocument(id: p.id).asset(a.id) == a)
    }

    @Test func modelExamplesOfferActualUnusedAssetAndReportActiveUse() throws {
        let a = asset(), d = try #require(unusedProject([a]).prepared)
        let catalog = try MediaPreparedBundledCatalog.load()
        for tool in ["image.remove-asset", "video.remove-asset"] {
            #expect(try catalog.descriptor(id: tool).existingCommand == "removeAsset")
        }
        let example = try #require(MediaPreparedToolInputGuide.make(document: d, implementedToolIDs: ["image.remove-asset"]).first)
        let json = try #require(example.inputJSON).data(using: .utf8)!
        let fields = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(fields["objectID"] as? String == a.id.uuidString)
        #expect(fields["expectedRevision"] as? String == String(d.revision))
        var used = d; used.sourceAssetID = a.id
        let unavailable = try #require(MediaPreparedToolInputGuide.make(document: used, implementedToolIDs: ["image.remove-asset"]).first)
        #expect(unavailable.inputJSON == nil && unavailable.unavailableReason != nil)
    }
}
