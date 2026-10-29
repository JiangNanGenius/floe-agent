import Foundation
import Testing
@testable import FloePersistence

@Suite("Shared file stages across suspension")
struct StorageSuspensionTests {
    private actor CopyGate {
        private var arrived = false
        private var released = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        func arriveAndWait() async {
            arrived = true
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        }
        func waitForArrival() async {
            if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
        }
        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    @Test("Suspension does not unlock a snapshot before its actual copy completes")
    func activeCopyDrainsBeforeUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-copy-suspension-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SQLiteSharedDocumentsStore(root: root)
        let id = try await first.beginContentStage()
        try await first.writeContent(Data("snapshot".utf8), operationID: id)
        let stage = try await first.finishContentStage(operationID: id)
        let item = try await first.commitCreate(parentID: "root", name: "copy.txt", kind: .file, stage: stage)
        let second = try SQLiteSharedDocumentsStore(root: root)
        let gate = CopyGate()
        defer { Task { await gate.release() } }
        let copy = Task {
            try await first.withLeasedContentSnapshot(id: item.id) { snapshot in
                await gate.arriveAndWait()
                return try Data(contentsOf: snapshot.contentURL)
            }
        }
        await gate.waitForArrival()
        let suspension = Task { await first.suspendForBackground() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await first.storageSuspended), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await first.storageSuspended)
        do {
            _ = try await second.withLeasedContentSnapshot(id: item.id) { $0.item.id }
            Issue.record("Suspension force-unlocked a still-running copy")
        } catch SharedDocumentsError.storageCorrupted(_) { }
        await gate.release()
        #expect(try await copy.value == Data("snapshot".utf8))
        await suspension.value
        await first.resumeAfterSuspension()
        let reopened = try await second.withLeasedContentSnapshot(id: item.id) { $0.item.id }
        #expect(reopened == item.id)
        try await first.close()
        try await second.close()
    }

    @Test("Suspension retains partial bytes and rejects a late stage writer after resume")
    func staleWriterCannotResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-stage-suspension-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSharedDocumentsStore(root: root)
        let id = try await store.beginContentStage()
        try await store.writeContent(Data("partial".utf8), operationID: id)
        let stage = try await store.finishContentStage(operationID: id)
        await store.suspendForBackground()
        #expect(try Data(contentsOf: stage.stagedFileURL) == Data("partial".utf8))
        await store.resumeAfterSuspension()
        do {
            try await store.writeContent(Data("late".utf8), operationID: id)
            Issue.record("An old stage callback appended after suspension")
        } catch SharedDocumentsError.cancelled { }
        do {
            _ = try await store.commitCreate(parentID: "root", name: "late.txt", kind: .file, stage: stage)
            Issue.record("A revoked stage committed after suspension")
        } catch SharedDocumentsError.cancelled { }
        #expect(try Data(contentsOf: stage.stagedFileURL) == Data("partial".utf8))
        let next = try await store.beginContentStage()
        try await store.writeContent(Data("next".utf8), operationID: next)
        let ready = try await store.finishContentStage(operationID: next)
        let item = try await store.commitCreate(parentID: "root", name: "next.txt", kind: .file, stage: ready)
        #expect(item.byteCount == 4)
        try await store.discardContentStage(operationID: id)
        try await store.close()
    }
}
