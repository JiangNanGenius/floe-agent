import Foundation
import Testing
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

@Suite("File canvas dead blob collection", .serialized)
@MainActor struct FileRepositoryGarbageCollectionTests {
    private struct Fixture {
        let root: URL
        let repository: FileCanvasRepository
        let snapshot: CanvasSnapshot
        let page: UUID
        let node: UUID
        var directory: URL { root.appendingPathComponent("canvases/" + snapshot.id.uuidString, isDirectory: true) }
        var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
        func batch(_ text: String) -> CanvasEditBatch { .init(pageID: page, operations: [.updateContent(nodeID: node, content: .text(text))]) }
    }
    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-gc-\(UUID())", isDirectory: true)
        let repository = try FileCanvasRepository(root: root)
        let node = CanvasNodeSnapshot(content: .text("v0"), frame: .init(center: .zero, size: .init(width: 10, height: 10)))
        let page = CanvasPageSnapshot(nodes: [node]), snapshot = CanvasSnapshot(name: "GC real history", pages: [page])
        try await repository.create(canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
        return Fixture(root: root, repository: repository, snapshot: snapshot, page: page.id, node: node.id)
    }
    private func currentHashes(_ f: Fixture) throws -> Set<String> {
        let data = try Data(contentsOf: f.directory.appendingPathComponent("manifest.json"))
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return [try #require(value["snapshotBlob"] as? String), try #require(value["historyBlob"] as? String)]
    }
    private func regularJSON(_ f: Fixture) throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(at: f.blobs, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return try Set(urls.filter {
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return $0.pathExtension == "json" && values.isRegularFile == true && values.isSymbolicLink != true
        }.map { $0.deletingPathExtension().lastPathComponent })
    }
    @Test func repeatedRealCommitsAndUndoRedoReopenKeepCompleteHistoryReceiptsAndOnlyCurrentBlobs() async throws {
        let f = try await makeFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let firstID = UUID(), firstBatch = f.batch("v1")
        let first = try await f.repository.commit(firstBatch, canvasID: f.snapshot.id, expectedRevision: 0, requestID: firstID)
        for revision in 1..<6 {
            _ = try await f.repository.commit(f.batch("v\(revision + 1)"), canvasID: f.snapshot.id,
                expectedRevision: Int64(revision), requestID: UUID())
            #expect(try regularJSON(f) == currentHashes(f))
        }
        var revision: Int64 = 6
        for expected in ["v5", "v4", "v3"] {
            let repo = try FileCanvasRepository(root: f.root)
            let receipt = try await repo.undo(canvasID: f.snapshot.id, expectedRevision: revision, requestID: UUID())
            revision = receipt.revision
            #expect(try await repo.load(canvasID: f.snapshot.id).selectedPage?.nodes.first?.textContent == expected)
            #expect(try regularJSON(f) == currentHashes(f))
        }
        let mid = try await f.repository.historyAvailability(canvasID: f.snapshot.id)
        #expect(mid.undoCount == 3 && mid.redoCount == 3)
        for expected in ["v4", "v5", "v6"] {
            let repo = try FileCanvasRepository(root: f.root)
            let receipt = try await repo.redo(canvasID: f.snapshot.id, expectedRevision: revision, requestID: UUID())
            revision = receipt.revision
            #expect(try await repo.load(canvasID: f.snapshot.id).selectedPage?.nodes.first?.textContent == expected)
            #expect(try regularJSON(f) == currentHashes(f))
        }
        let reopened = try FileCanvasRepository(root: f.root)
        let replay = try await reopened.commit(firstBatch, canvasID: f.snapshot.id, expectedRevision: 0, requestID: firstID)
        #expect(replay == first)
        let history = try await reopened.historyAvailability(canvasID: f.snapshot.id)
        #expect(history.undoCount == 6 && history.redoCount == 0)
        #expect(try await reopened.undoHistory(canvasID: f.snapshot.id).count == 6)
        #expect(try await reopened.load(canvasID: f.snapshot.id).revision == revision)
        #expect(try regularJSON(f) == currentHashes(f))
        // This failure leaves no committed receipt; GC must not change the
        // current commit, history or its still-usable undo frames.
        f.repository.setFailBeforeManifestWrite(true)
        await #expect(throws: (any Error).self) { _ = try await f.repository.commit(f.batch("failed"), canvasID: f.snapshot.id, expectedRevision: revision, requestID: UUID()) }
        #expect(try await reopened.load(canvasID: f.snapshot.id).revision == revision)
        _ = try await reopened.undo(canvasID: f.snapshot.id, expectedRevision: revision, requestID: UUID())
        #expect(try await reopened.load(canvasID: f.snapshot.id).selectedPage?.nodes.first?.textContent == "v5")
        #expect(try regularJSON(f) == currentHashes(f))
    }
    @Test func failedDurabilityOrCurrentValidationDeletesNothingAndUnfamiliarFilesArePreserved() async throws {
        let f = try await makeFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try currentHashes(f)
        let orphanData = Data("uncommitted dead payload".utf8)
        let orphan = f.blobs.appendingPathComponent(CanvasBatchDigest.hash(orphanData) + ".json")
        try orphanData.write(to: orphan)
        let outside = f.root.appendingPathComponent("keep-external.txt")
        let retained = Data("not repository garbage".utf8); try retained.write(to: outside)
        let symbolic = f.blobs.appendingPathComponent(CanvasBatchDigest.hash(retained) + ".json")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: outside)
        let unknown = f.blobs.appendingPathComponent("operator-note.json"), staging = f.blobs.appendingPathComponent(".inflight.tmp")
        try retained.write(to: unknown); try retained.write(to: staging)
        let directory = f.blobs.appendingPathComponent(String(repeating: "e", count: 64) + ".json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        f.repository.setFailGarbageCollectionBarrier(true)
        let id = UUID(), batch = f.batch("v1")
        let committed = try await f.repository.commit(batch, canvasID: f.snapshot.id, expectedRevision: 0, requestID: id)
        #expect(committed.revision == 1 && FileManager.default.fileExists(atPath: orphan.path))
        #expect(old.isSubset(of: try regularJSON(f)))
        let manifest = f.directory.appendingPathComponent("manifest.json"), beforeManifest = try Data(contentsOf: manifest)
        let value = try #require(JSONSerialization.jsonObject(with: beforeManifest) as? [String: Any])
        let historyURL = f.blobs.appendingPathComponent(try #require(value["historyBlob"] as? String) + ".json")
        let goodHistory = try Data(contentsOf: historyURL)
        try Data("corrupt current history".utf8).write(to: historyURL)
        #expect(throws: (any Error).self) { try f.repository.collectUnreferencedBlobsSynchronously(canvasID: f.snapshot.id) }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: manifest) == beforeManifest)
        // Restore only this deliberate test corruption, then perform the
        // same locked maintenance; this does not retry away the assertion.
        try goodHistory.write(to: historyURL)
        try f.repository.collectUnreferencedBlobsSynchronously(canvasID: f.snapshot.id)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: manifest) == beforeManifest)
        let outsideBytes = try Data(contentsOf: outside), noteBytes = try Data(contentsOf: unknown), stagingBytes = try Data(contentsOf: staging)
        #expect(outsideBytes == retained && noteBytes == retained && stagingBytes == retained)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symbolic.path) == outside.path)
        #expect(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try await f.repository.commit(batch, canvasID: f.snapshot.id, expectedRevision: 0, requestID: id) == committed)
        #expect(try await f.repository.load(canvasID: f.snapshot.id).selectedPage?.nodes.first?.textContent == "v1")
    }
}
