// FloeAppTests — Shared Documents store, real SQLite/filesystem (S5 C4).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this lane.
// The unified qualification run owns execution after the primary integrates
// test membership. Synthetic content only; no FileProvider domain, no user
// data, no App Group dependency (each test uses its own temp root).
//
// Coverage:
// * CRUD with stable IDs, parent hierarchy, collision-safe names
// * CAS version conflicts and cross-writer interleaving on one file
// * staged streaming: byte preservation + digests, cancel before commit
//   preserves prior bytes/version, post-commit state is the truth
// * combined metadata+content commit: one journal row, atomic visibility;
//   failure preserves prior bytes AND name/versions
// * cancellation at admission and inside the committing SQL transaction
// * exact-version crash-orphan retry converges without version drift
// * leased snapshot pairs the exact immutable version with the exact bytes
// * interrupted stage/commit recovery: dead staging reclaimed, orphans
//   reclaimed only when unreferenced, referenced bytes never touched,
//   recovery counters reflect ACTUAL deletions only
// * keyset pagination stability while rows are inserted mid-enumeration
// * change journal: insert/update/delete tombstones, anchors, pruning floor
//   expiry, future anchors rejected, high-water stays monotonic after a
//   full prune, empty diff at the head is truthful (not a false clean)
// * rename/move collisions and cycle refusal; bounded recursive delete
// * malformed names/IDs refused; no path outside the dedicated root

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
@testable import FloePersistence

// MARK: - Fixtures

private func makeStoreRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shared-documents-store-\(UUID().uuidString)", isDirectory: true)
}

private func makeStore(at root: URL) throws -> SQLiteSharedDocumentsStore {
    try SQLiteSharedDocumentsStore(root: root)
}

/// Stages arbitrary bytes through the leased staging path and returns the
/// finished stage descriptor.
private func stageBytes(
    _ bytes: Data,
    store: SQLiteSharedDocumentsStore,
    cancellation: (any SharedDocumentsOperationCancellation)? = nil
) async throws -> SharedDocumentsContentStage {
    let operationID = try await store.beginContentStage(cancellation: cancellation)
    do {
        try await store.writeContent(bytes, operationID: operationID, cancellation: cancellation)
        return try await store.finishContentStage(operationID: operationID, cancellation: cancellation)
    } catch {
        try? await store.discardContentStage(operationID: operationID)
        throw error
    }
}

private func writeFile(_ bytes: Data, name: String = "source.bin") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("shared-documents-src-\(UUID().uuidString)")
        .appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try bytes.write(to: url)
    return url
}

/// Cancellation token that answers false for the first `flips` checks and
/// true afterwards — deterministic placement of cancellation at the
/// admission check vs. inside the committing transaction.
private struct FlipCancellation: SharedDocumentsOperationCancellation {
    let flips: Int
    private let state = FlipState()

    final class FlipState: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
    }

    func isCancelled() -> Bool {
        state.next() > flips
    }
}

private struct AlreadyCancelled: SharedDocumentsOperationCancellation {
    func isCancelled() -> Bool { true }
}

// The production wrapper, rather than the actor executor or FileManager's
// undocumented thread safety, owns serialization across GRDB and actor calls.
private enum InjectedSharedDocumentsIOError: Error { case moveDenied }
private final class SharedDocumentsIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var denyMove = false
    func armMoveFailure() { lock.lock(); denyMove = true; lock.unlock() }
    func consumeMoveFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = denyMove; denyMove = false; return value
    }
    func copy<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        // Widen overlap deliberately: concurrent calls without the production
        // lock must be observed while still performing real file copies.
        Thread.sleep(forTimeInterval: 0.002)
        return try body()
    }
    var maximumConcurrentCopies: Int { lock.lock(); defer { lock.unlock() }; return maximum }
}
private final class ProbedSharedDocumentsFileManager: FileManager {
    let probe: SharedDocumentsIOProbe
    init(probe: SharedDocumentsIOProbe) { self.probe = probe; super.init() }
    override func copyItem(at source: URL, to destination: URL) throws {
        try probe.copy { try super.copyItem(at: source, to: destination) }
    }
    override func moveItem(at source: URL, to destination: URL) throws {
        if probe.consumeMoveFailure() { throw InjectedSharedDocumentsIOError.moveDenied }
        try super.moveItem(at: source, to: destination)
    }
}

@Suite("SharedDocumentsStore synchronized file I/O")
struct SharedDocumentsSynchronizedFileIOTests {
    @Test("the injected manager is serialized across concurrent executors with real copies")
    func concurrentFileIOUsesOneLock() async throws {
        let root = makeStoreRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let bytes = Data(repeating: 9, count: 8192)
        try bytes.write(to: source)
        let probe = SharedDocumentsIOProbe()
        let fileIO = SharedDocumentsFileIO(manager: ProbedSharedDocumentsFileManager(probe: probe))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let destination = root.appendingPathComponent("copy-\(index)")
                    try fileIO.copyItem(at: source, to: destination)
                    #expect(try Data(contentsOf: destination) == bytes)
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.maximumConcurrentCopies == 1)
        #expect(try fileIO.contentsOfDirectory(atPath: root.path).count == 17)
    }

    @Test("injected move errors propagate without changing committed CAS, journal or leased bytes")
    func injectedMoveFailurePreservesCommittedState() async throws {
        let root = makeStoreRoot(), probe = SharedDocumentsIOProbe()
        let store = try SQLiteSharedDocumentsStore(root: root, fileManager: ProbedSharedDocumentsFileManager(probe: probe))
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let original = Data("committed".utf8)
        let item = try await store.commitCreate(parentID: SharedDocumentsIdentity.rootItemID,
            name: "original.txt", kind: .file, stage: stageBytes(original, store: store))
        let anchor = try await store.currentAnchor()
        let replacement = try await stageBytes(Data("replacement".utf8), store: store)
        probe.armMoveFailure()
        await #expect(throws: InjectedSharedDocumentsIOError.self) {
            _ = try await store.commitReplace(id: item.id, stage: replacement, expected: item.versions)
        }
        #expect(try await store.item(id: item.id) == item)
        #expect(try await store.currentAnchor() == anchor)
        let actual = try await store.withLeasedContentSnapshot(id: item.id, cancellation: nil) {
            try Data(contentsOf: $0.contentURL)
        }
        #expect(actual == original)
        // Failure did not consume the stage or silently retry the mutation.
        #expect(FileManager.default.fileExists(atPath: replacement.stagedFileURL.path))
        try await store.discardContentStage(operationID: replacement.operationID)
    }
}

@Suite("SharedDocumentsStore stage creation and virtual root")
struct SharedDocumentsStageCreationTests {
    @Test("begin creates a new private content file and streams actual bytes through it")
    func beginCreatesPrivateContentAndStreamsRealBytes() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let operationID = try await store.beginContentStage()
        let content = root.appendingPathComponent("store/staging/\(operationID.uuidString)/content")
        let properties = try content.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        #expect(properties.isRegularFile == true && properties.isSymbolicLink == false)
        #expect(try Data(contentsOf: content).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: content.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let payload = Data("actual staged bytes".utf8)
        try await store.writeContent(payload, operationID: operationID)
        let stage = try await store.finishContentStage(operationID: operationID)
        #expect(stage.byteCount == Int64(payload.count))
        #expect(stage.sha256 == FloeDigest.sha256Hex(payload))
        #expect(try Data(contentsOf: stage.stagedFileURL) == payload)
        try await store.discardContentStage(operationID: operationID)
        #expect(!FileManager.default.fileExists(atPath: content.deletingLastPathComponent().path))
    }

    @Test("exclusive content creation preserves an existing file and refuses a symlink without touching its target")
    func exclusiveStageLeafDoesNotOverwriteOrFollowLinks() throws {
        let root = makeStoreRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing"), link = root.appendingPathComponent("link")
        let original = Data("preserve existing bytes".utf8)
        try original.write(to: existing)
        #expect(throws: FloeFileIOError.self) { try SQLiteSharedDocumentsStore.createOwnedStageContentHandle(at: existing) }
        #expect(try Data(contentsOf: existing) == original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        #expect(throws: FloeFileIOError.self) { try SQLiteSharedDocumentsStore.createOwnedStageContentHandle(at: link) }
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: existing) == original)
    }

    @Test("the virtual root accepts children across reopen while missing and non-folder parents still fail")
    func virtualRootReopenAndParentChecks() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let folder = try await store.commitCreate(parentID: SharedDocumentsIdentity.rootItemID,
            name: "Folder", kind: .folder, stage: nil)
        #expect(folder.parentID == SharedDocumentsIdentity.rootItemID)
        let second = try makeStore(at: root)
        defer { Task { try? await second.close() } }
        #expect(try await second.item(id: SharedDocumentsIdentity.rootItemID) == SharedDocumentsIdentity.rootItem)
        let listed = try await second.children(parentID: SharedDocumentsIdentity.rootItemID, cursorToken: nil, limit: 10)
        #expect(listed.items.map(\.id) == [folder.id])
        #expect(try await second.allLiveItems().allSatisfy { $0.id != SharedDocumentsIdentity.rootItemID })
        let missing = UUID().uuidString
        await #expect(throws: SharedDocumentsError.parentNotFound(missing)) {
            try await second.commitCreate(parentID: missing, name: "Missing", kind: .folder, stage: nil)
        }
        let file = try await store.commitCreate(parentID: SharedDocumentsIdentity.rootItemID,
            name: "file.txt", kind: .file, stage: stageBytes(Data("file".utf8), store: store))
        await #expect(throws: SharedDocumentsError.parentNotAFolder(file.id)) {
            try await second.commitCreate(parentID: file.id, name: "Invalid child", kind: .folder, stage: nil)
        }
    }
}

// MARK: - CRUD / identity / hierarchy

@Suite("SharedDocumentsStore CRUD")
struct SharedDocumentsStoreCRUDTests {
    @Test("create file with content commits immutable version 1")
    func createFile() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let payload = Data("hello floe".utf8)
        let stage = try await stageBytes(payload, store: store)
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "notes.txt",
            kind: .file,
            stage: stage
        )
        #expect(item.contentVersion == 1)
        #expect(item.metadataVersion == 1)
        #expect(item.byteCount == Int64(payload.count))
        #expect(item.sha256 == FloeDigest.sha256Hex(payload))
        #expect(item.parentID == SharedDocumentsIdentity.rootItemID)
        let reread = try await store.item(id: item.id)
        #expect(reread == item)
    }

    @Test("folder hierarchy keeps stable IDs across renames")
    func folderHierarchy() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let folder = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "Papers",
            kind: .folder,
            stage: nil
        )
        let file = try await store.commitCreate(
            parentID: folder.id,
            name: "a.txt",
            kind: .file,
            stage: try await stageBytes(Data("a".utf8), store: store)
        )
        let renamed = try await store.commitMetadata(
            id: folder.id,
            newName: "Renamed",
            newParentID: nil,
            expected: folder.versions
        )
        #expect(renamed.id == folder.id)
        #expect(renamed.metadataVersion == 2)
        let child = try await store.item(id: file.id)
        #expect(child.parentID == folder.id)
        #expect(child.name == "a.txt")
        #expect(child.contentVersion == 1)
    }

    @Test("name collision in one parent throws, other parents allowed")
    func nameCollision() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        _ = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "same.txt",
            kind: .file,
            stage: try await stageBytes(Data("1".utf8), store: store)
        )
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.commitCreate(
                parentID: SharedDocumentsIdentity.rootItemID,
                name: "SAME.txt",
                kind: .file,
                stage: try await stageBytes(Data("2".utf8), store: store)
            )
        }
        let other = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "folder",
            kind: .folder,
            stage: nil
        )
        let nested = try await store.commitCreate(
            parentID: other.id,
            name: "same.txt",
            kind: .file,
            stage: try await stageBytes(Data("3".utf8), store: store)
        )
        #expect(nested.name == "same.txt")
    }

    @Test("rename onto an existing sibling collides")
    func renameCollision() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        _ = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "b.txt",
            kind: .file,
            stage: try await stageBytes(Data("b".utf8), store: store)
        )
        let a = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "a.txt",
            kind: .file,
            stage: try await stageBytes(Data("a".utf8), store: store)
        )
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.commitMetadata(
                id: a.id,
                newName: "B.txt",
                newParentID: nil,
                expected: a.versions
            )
        }
    }

    @Test("moving a folder into its own descendant is refused")
    func cycleRefused() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let outer = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "outer",
            kind: .folder,
            stage: nil
        )
        let inner = try await store.commitCreate(
            parentID: outer.id,
            name: "inner",
            kind: .folder,
            stage: nil
        )
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.commitMetadata(
                id: outer.id,
                newName: nil,
                newParentID: inner.id,
                expected: outer.versions
            )
        }
    }

    @Test("malformed names and IDs are refused")
    func malformedInputs() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        for bad in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 300)] {
            await #expect(throws: SharedDocumentsError.self) {
                _ = try await store.commitCreate(
                    parentID: SharedDocumentsIdentity.rootItemID,
                    name: bad,
                    kind: .folder,
                    stage: nil
                )
            }
        }
        for badID in ["../escape", "a/b", "not-a-uuid"] {
            await #expect(throws: SharedDocumentsError.self) {
                _ = try await store.item(id: badID)
            }
        }
    }
}

// MARK: - Versions / CAS / concurrency

@Suite("SharedDocumentsStore versions and CAS")
struct SharedDocumentsStoreVersionTests {
    @Test("replace bumps content version and preserves byte identity")
    func replaceBumpsVersion() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let v1 = Data("version one".utf8)
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "doc.bin",
            kind: .file,
            stage: try await stageBytes(v1, store: store)
        )
        let v2 = Data("version two, longer".utf8)
        let replaced = try await store.commitReplace(
            id: item.id,
            stage: try await stageBytes(v2, store: store),
            expected: item.versions
        )
        #expect(replaced.contentVersion == 2)
        #expect(replaced.metadataVersion == 1)
        #expect(replaced.sha256 == FloeDigest.sha256Hex(v2))
        guard let url = try await store.committedContentURL(id: item.id) else {
            Issue.record("missing committed content")
            return
        }
        #expect(try Data(contentsOf: url) == v2)
    }

    @Test("CAS mismatch throws versionConflict with actual committed state")
    func casConflict() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "cas.txt",
            kind: .file,
            stage: try await stageBytes(Data("one".utf8), store: store)
        )
        let stale = SharedDocumentsExpectedVersions(content: 1, metadata: 1)
        let newer = try await store.commitReplace(
            id: item.id,
            stage: try await stageBytes(Data("two".utf8), store: store),
            expected: item.versions
        )
        #expect(newer.contentVersion == 2)
        do {
            _ = try await store.commitReplace(
                id: item.id,
                stage: try await stageBytes(Data("three".utf8), store: store),
                expected: stale
            )
            Issue.record("stale CAS unexpectedly succeeded")
        } catch SharedDocumentsError.versionConflict(let itemID, _, let actual) {
            #expect(itemID == item.id)
            #expect(actual.content == 2)
            #expect(actual.metadata == 1)
        }
    }

    @Test("two store instances on one root interleave with real CAS")
    func crossInstanceConcurrency() async throws {
        let root = makeStoreRoot()
        let writerA = try makeStore(at: root)
        let writerB = try makeStore(at: root)
        defer {
            Task {
                try? await writerA.close()
                try? await writerB.close()
                try? FileManager.default.removeItem(at: root)
            }
        }
        let item = try await writerA.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "race.txt",
            kind: .file,
            stage: try await stageBytes(Data("base".utf8), store: writerA)
        )
        // Both writers read version 1; exactly one commit may succeed.
        let first = try? await writerA.commitReplace(
            id: item.id,
            stage: try await stageBytes(Data("from A".utf8), store: writerA),
            expected: item.versions
        )
        let second = try? await writerB.commitReplace(
            id: item.id,
            stage: try await stageBytes(Data("from B".utf8), store: writerB),
            expected: item.versions
        )
        #expect((first == nil) != (second == nil))
        let final = try await writerA.item(id: item.id)
        #expect(final.contentVersion == 2)
    }

    @Test("restore appends a new version without rewriting history")
    func restoreAppendOnly() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let v1 = Data("original".utf8)
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "restore.me",
            kind: .file,
            stage: try await stageBytes(v1, store: store)
        )
        _ = try await store.commitReplace(
            id: item.id,
            stage: try await stageBytes(Data("changed".utf8), store: store),
            expected: item.versions
        )
        let current = try await store.item(id: item.id)
        let restored = try await store.restoreContent(
            id: item.id,
            targetContentVersion: 1,
            expected: current.versions
        )
        #expect(restored.contentVersion == 3)
        guard let url = try await store.committedContentURL(id: item.id) else {
            Issue.record("missing committed content")
            return
        }
        #expect(try Data(contentsOf: url) == v1)
        #expect(restored.sha256 == FloeDigest.sha256Hex(v1))
    }
}

// MARK: - Cancellation / atomicity / recovery

@Suite("SharedDocumentsStore cancel and recovery")
struct SharedDocumentsStoreRecoveryTests {
    @Test("cancel before commit preserves the prior committed bytes/version")
    func cancelBeforeCommit() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "keep.me",
            kind: .file,
            stage: try await stageBytes(Data("original".utf8), store: store)
        )
        let operationID = try await store.beginContentStage()
        try await store.writeContent(Data("partial replacement".utf8), operationID: operationID)
        // Caller cancels before finishing/committing.
        try await store.discardContentStage(operationID: operationID)
        let after = try await store.item(id: item.id)
        #expect(after == item)
        guard let url = try await store.committedContentURL(id: item.id) else {
            Issue.record("missing committed content")
            return
        }
        #expect(try Data(contentsOf: url) == Data("original".utf8))
    }

    @Test("abandoned staging directory is reclaimed by recovery")
    func recoveryReclaimsStaging() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        let stagingRoot = root.appendingPathComponent("store/staging", isDirectory: true)
        // Simulate a crashed writer: staging dir + lock file, no live fd.
        let dead = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dead.appendingPathComponent("lock").path, contents: nil)
        FileManager.default.createFile(atPath: dead.appendingPathComponent("content").path, contents: Data("orphan".utf8))
        let report = try await store.recoverInterruptedOperations()
        #expect(report.reclaimedStages == 1)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        try await store.close()
        try? FileManager.default.removeItem(at: root)
    }

    @Test("orphan blob reclaimed; referenced blob preserved")
    func recoveryOrphanPolicy() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "live.bin",
            kind: .file,
            stage: try await stageBytes(Data("live bytes".utf8), store: store)
        )
        // Plant an unreferenced blob next to the committed one.
        let dir = root.appendingPathComponent("store/blobs/\(item.id)", isDirectory: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("v999").path, contents: Data("junk".utf8))
        let report = try await store.recoverInterruptedOperations()
        #expect(report.reclaimedOrphans == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("v999").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("v1").path))
        #expect(report.missingContentItemIDs.isEmpty)
    }

    @Test("missing committed content is surfaced, not hidden")
    func recoverySurfacesMissingContent() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "gone.bin",
            kind: .file,
            stage: try await stageBytes(Data("bytes".utf8), store: store)
        )
        let dir = root.appendingPathComponent("store/blobs/\(item.id)", isDirectory: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("v1"))
        let report = try await store.recoverInterruptedOperations()
        #expect(report.missingContentItemIDs.contains(item.id))
    }

    @Test("delete tombstones item and removes content only after commit")
    func deleteTombstone() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "trash.me",
            kind: .file,
            stage: try await stageBytes(Data("bye".utf8), store: store)
        )
        let outcome = try await store.commitDelete(id: item.id, expected: item.versions, recursive: false)
        #expect(outcome.deletedIDs == [item.id])
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.item(id: item.id)
        }
        // A second delete of the same identity is an unknown-item no-op path
        // handled by the bridge; the store itself reports not found.
        let dir = root.appendingPathComponent("store/blobs/\(item.id)", isDirectory: true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty != false)
    }

    @Test("non-empty folder delete requires recursion and stays bounded")
    func boundedRecursiveDelete() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let folder = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "tree",
            kind: .folder,
            stage: nil
        )
        _ = try await store.commitCreate(
            parentID: folder.id,
            name: "child.txt",
            kind: .file,
            stage: try await stageBytes(Data("c".utf8), store: store)
        )
        await #expect(throws: SharedDocumentsError.self) {
            try await store.commitDelete(id: folder.id, expected: folder.versions, recursive: false)
        }
        let outcome = try await store.commitDelete(id: folder.id, expected: folder.versions, recursive: true)
        #expect(outcome.deletedIDs.count == 2)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.item(id: folder.id)
        }
    }
}

// MARK: - Pagination / journal / anchors

@Suite("SharedDocumentsStore enumeration and journal")
struct SharedDocumentsStoreEnumerationTests {
    @Test("keyset pagination is stable across concurrent inserts")
    func paginationStable() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        // Seed 25 items; page size 10; insert during pagination.
        var ids: [String] = []
        for index in 0..<25 {
            let item = try await store.commitCreate(
                parentID: SharedDocumentsIdentity.rootItemID,
                name: String(format: "f%03d.txt", index),
                kind: .file,
                stage: try await stageBytes(Data([UInt8(index)]), store: store)
            )
            ids.append(item.id)
        }
        var seen: [String] = []
        var cursor: Data? = nil
        var pageCount = 0
        repeat {
            let page = try await store.children(
                parentID: SharedDocumentsIdentity.rootItemID,
                cursorToken: cursor,
                limit: 10
            )
            seen.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursorToken
            pageCount += 1
            if pageCount == 1 {
                // A late insert must neither duplicate nor drop existing rows.
                _ = try await store.commitCreate(
                    parentID: SharedDocumentsIdentity.rootItemID,
                    name: "f-000-late.txt",
                    kind: .file,
                    stage: try await stageBytes(Data("late".utf8), store: store)
                )
            }
        } while cursor != nil
        #expect(seen.count == Set(seen).count)
        #expect(seen.contains(ids[0]))
        #expect(seen.contains(ids[24]))
        #expect(seen.count >= 25)
    }

    @Test("change journal carries insert/update/delete with tombstones")
    func journalKinds() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let start = try await store.currentAnchor()
        let file = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "j.txt",
            kind: .file,
            stage: try await stageBytes(Data("j".utf8), store: store)
        )
        _ = try await store.commitMetadata(
            id: file.id,
            newName: "j2.txt",
            newParentID: nil,
            expected: file.versions
        )
        let current = try await store.item(id: file.id)
        _ = try await store.commitDelete(id: file.id, expected: current.versions, recursive: false)
        let batch = try await store.changes(anchor: start, limit: 100)
        #expect(batch.changes.map(\.kind) == [.insert, .update, .delete])
        #expect(batch.more == false)
        #expect(try SQLiteSharedDocumentsStore.parseAnchor(batch.nextAnchor) > SQLiteSharedDocumentsStore.parseAnchor(start))
    }

    @Test("pruned journal expires anchors below the floor and rejects future anchors")
    func anchorFloor() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let anchor0 = try await store.currentAnchor()
        _ = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "old.txt",
            kind: .file,
            stage: try await stageBytes(Data("old".utf8), store: store)
        )
        // Prune everything older than a moment in the future.
        let pruned = try await store.pruneChanges(olderThan: Date().addingTimeInterval(60))
        #expect(pruned >= 1)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.changes(anchor: anchor0, limit: 10)
        }
        let future = SQLiteSharedDocumentsStore.makeAnchor(sequence: 9_999_999)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.changes(anchor: future, limit: 10)
        }
    }

    @Test("working set listing pages across the whole hierarchy")
    func workingSetListing() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let folder = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "dir",
            kind: .folder,
            stage: nil
        )
        _ = try await store.commitCreate(
            parentID: folder.id,
            name: "nested.txt",
            kind: .file,
            stage: try await stageBytes(Data("n".utf8), store: store)
        )
        let page = try await store.allItems(cursorToken: nil, limit: 50)
        #expect(page.items.count == 2)
        #expect(page.nextCursorToken == nil)
    }
}

// MARK: - Combined commit / cancellation / journal truth (primary-review closure)

@Suite("SharedDocumentsStore combined commit and journal truth")
struct SharedDocumentsStoreClosureTests {
    @Test("combined metadata+content modify commits atomically with one journal row")
    func combinedModifyAtomic() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "combo.txt",
            kind: .file,
            stage: try await stageBytes(Data("one".utf8), store: store)
        )
        let start = try await store.currentAnchor()
        let replacement = Data("two — replaced and renamed".utf8)
        let modified = try await store.commitModify(
            id: item.id,
            newName: "combo-renamed.txt",
            newParentID: nil,
            stage: try await stageBytes(replacement, store: store),
            expected: item.versions,
            cancellation: nil
        )
        #expect(modified.name == "combo-renamed.txt")
        #expect(modified.contentVersion == 2)
        #expect(modified.metadataVersion == 2)
        guard let url = try await store.committedContentURL(id: item.id) else {
            Issue.record("missing committed content")
            return
        }
        #expect(try Data(contentsOf: url) == replacement)
        // Exactly ONE journal row carries the coherent final state.
        let batch = try await store.changes(anchor: start, limit: 100)
        #expect(batch.changes.count == 1)
        #expect(batch.changes.first?.kind == .update)
        #expect(batch.changes.first?.item.name == "combo-renamed.txt")
        #expect(batch.changes.first?.item.contentVersion == 2)
        #expect(batch.more == false)
    }

    @Test("combined modify failure preserves prior bytes, name and versions")
    func combinedModifyFailurePreservesPrior() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let original = Data("original".utf8)
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "keep-name.txt",
            kind: .file,
            stage: try await stageBytes(original, store: store)
        )
        // Nonexistent target parent fails the admission probe AFTER the stage
        // exists: the combined commit must leave everything untouched.
        let stage = try await stageBytes(Data("newer".utf8), store: store)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.commitModify(
                id: item.id,
                newName: "renamed.txt",
                newParentID: "00000000-0000-0000-0000-0000000000FF",
                stage: stage,
                expected: item.versions,
                cancellation: nil
            )
        }
        let after = try await store.item(id: item.id)
        #expect(after == item)
        guard let url = try await store.committedContentURL(id: item.id) else {
            Issue.record("missing committed content")
            return
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("cancellation at admission leaves the committed state untouched")
    func cancelAtAdmission() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "cancel-admission.txt",
            kind: .file,
            stage: try await stageBytes(Data("stable".utf8), store: store)
        )
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.commitReplace(
                id: item.id,
                stage: try await stageBytes(Data("never".utf8), store: store),
                expected: item.versions,
                cancellation: AlreadyCancelled()
            )
        }
        #expect(try await store.item(id: item.id) == item)
    }

    @Test("cancellation inside the committing SQL transaction rolls back")
    func cancelInsideCommitTransaction() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "cancel-txn.txt",
            kind: .file,
            stage: try await stageBytes(Data("committed".utf8), store: store)
        )
        // Entry check passes, the probe transaction sees cancelled: the
        // write rolls back and no rename/commit happens.
        let token = FlipCancellation(flips: 1)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.commitReplace(
                id: item.id,
                stage: try await stageBytes(Data("shadow".utf8), store: store),
                expected: item.versions,
                cancellation: token
            )
        }
        let after = try await store.item(id: item.id)
        #expect(after == item)
    }

    @Test("crash orphan at the exact next version is adopted by the bounded retry")
    func exactVersionOrphanRetryConverges() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "retry.txt",
            kind: .file,
            stage: try await stageBytes(Data("v1".utf8), store: store)
        )
        // Simulate a crash between rename and commit: the exact next version
        // exists on disk while the row still names v1.
        let dir = root.appendingPathComponent("store/blobs/\(item.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("v2").path, contents: Data("orphan".utf8))
        let replacement = Data("v2 for real".utf8)
        let replaced = try await store.commitReplace(
            id: item.id,
            stage: try await stageBytes(replacement, store: store),
            expected: item.versions,
            cancellation: nil
        )
        // Versions stay exact (no drift), no collision, bytes are the new ones.
        #expect(replaced.contentVersion == 2)
        guard let url = try await store.committedContentURL(id: item.id) else {
            Issue.record("missing committed content")
            return
        }
        #expect(try Data(contentsOf: url) == replacement)
    }

    @Test("leased snapshot pairs the exact immutable version with the exact bytes")
    func leasedSnapshotPairing() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let payload = Data("immutable pair".utf8)
        let item = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "snapshot.txt",
            kind: .file,
            stage: try await stageBytes(payload, store: store)
        )
        let outcome: (version: Int, digest: String) = try await store.withLeasedContentSnapshot(
            id: item.id,
            cancellation: nil
        ) { snapshot in
            let bytes = try Data(contentsOf: snapshot.contentURL)
            return (snapshot.contentVersion, FloeDigest.sha256Hex(bytes))
        }
        #expect(outcome.version == 1)
        #expect(outcome.digest == FloeDigest.sha256Hex(payload))
        #expect(outcome.digest == item.sha256)
    }

    @Test("high-water stays monotonic after the whole journal is pruned")
    func highWaterMonotonicAfterFullPrune() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let anchor0 = try await store.currentAnchor()
        _ = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "a.txt",
            kind: .file,
            stage: try await stageBytes(Data("a".utf8), store: store)
        )
        _ = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "b.txt",
            kind: .file,
            stage: try await stageBytes(Data("b".utf8), store: store)
        )
        let anchor1 = try await store.currentAnchor()
        #expect(try SQLiteSharedDocumentsStore.parseAnchor(anchor1) > SQLiteSharedDocumentsStore.parseAnchor(anchor0))
        let pruned = try await store.pruneChanges(olderThan: Date().addingTimeInterval(60))
        #expect(pruned >= 2)
        // The anchor NEVER moves backwards, even with zero live rows.
        let anchor2 = try await store.currentAnchor()
        #expect(try SQLiteSharedDocumentsStore.parseAnchor(anchor2) >= SQLiteSharedDocumentsStore.parseAnchor(anchor1))
        // A fresh enumerator at the head gets a truthful empty diff, not an
        // expiry and not a false clean that loses later changes.
        let head = try await store.changes(anchor: anchor2, limit: 10)
        #expect(head.changes.isEmpty)
        #expect(head.more == false)
        // New changes after the prune are still visible from the head.
        _ = try await store.commitCreate(
            parentID: SharedDocumentsIdentity.rootItemID,
            name: "c.txt",
            kind: .file,
            stage: try await stageBytes(Data("c".utf8), store: store)
        )
        let after = try await store.changes(anchor: anchor2, limit: 10)
        #expect(after.changes.count == 1)
        #expect(after.more == false)
        // Anchors below the floor still expire honestly.
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.changes(anchor: anchor0, limit: 10)
        }
    }

    @Test("recovery counters reflect actual deletions only")
    func recoveryCountsActualDeletions() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let stagingRoot = root.appendingPathComponent("store/staging", isDirectory: true)
        // A dead staging directory IS reclaimed and counted.
        let dead = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dead.appendingPathComponent("lock").path, contents: nil)
        // A staging directory whose lock cannot be probed (a directory where
        // the lock file belongs) is NOT reclaimed and NOT counted.
        let stuck = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stuck.appendingPathComponent("lock", isDirectory: true),
            withIntermediateDirectories: true
        )
        let report = try await store.recoverInterruptedOperations()
        #expect(report.reclaimedStages == 1)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: stuck.path))
    }

    @Test("store-side staging streams real bytes and enforces cancellation")
    func storeSideStaging() async throws {
        let root = makeStoreRoot()
        let store = try makeStore(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let payload = Data(repeating: 7, count: 300_000)
        let source = try writeFile(payload, name: "stream.bin")
        let stage = try await store.stageContentFromURL(source, cancellation: nil, progress: nil)
        #expect(stage.byteCount == Int64(payload.count))
        #expect(stage.sha256 == FloeDigest.sha256Hex(payload))
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        // Pre-cancelled staging refuses before creating anything durable.
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await store.stageContentFromURL(
                writeFile(Data("x".utf8)),
                cancellation: AlreadyCancelled(),
                progress: nil
            )
        }
    }
}
#endif
