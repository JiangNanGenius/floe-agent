import Foundation
import Testing
import GRDB
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeApp

@Suite("Low storage notice", .serialized)
struct StorageAvailabilityNoticeTests {
    @MainActor @Test func dismissalEscalationAndRecovery() {
        var free = DeviceStorageAvailability.lowBytes - 1
        let center = StorageAvailabilityCenter(probe: { .init(availableBytes: free) })
        #expect(center.showsNotice)
        center.dismiss()
        center.refresh()
        #expect(!center.showsNotice)
        free = 0
        center.refresh()
        #expect(center.showsNotice) // A more serious state is not silenced.
        center.dismiss()
        free = DeviceStorageAvailability.lowBytes + 1
        center.refresh()
        #expect(!center.showsNotice)
        free = 0
        center.refresh()
        #expect(center.showsNotice) // Recovery re-arms a later warning.
    }

    @MainActor @Test func realFailureWarnsEvenWhenCapacityIsUnknown() {
        let center = StorageAvailabilityCenter(probe: { .init(availableBytes: nil) })
        #expect(!center.showsNotice)
        center.refresh(writeFailed: true)
        #expect(center.showsNotice)
        #expect(center.writeFailed)
        center.dismiss()
        #expect(!center.showsNotice)
    }

    @Test func atomicWriteFailurePreservesPreviousBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("kept.txt")
        let original = Data("kept".utf8)
        try original.write(to: destination)
        let failure = NSError(domain: NSCocoaErrorDomain, code: 640)
        do {
            try AtomicFileCommitter.commit(Data("new".utf8), to: destination,
                policy: .init(conflict: .replaceAtomically(consent: true),
                              verifyBeforeCommit: { _ in throw failure }))
            Issue.record("A failed staged write must not report success")
        } catch {
            #expect(StorageSpaceFailure.matches(error))
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["kept.txt"])
    }

    @Test func sqliteFullRollsBackAndRemainsRetryable() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.writer { db in
            try db.execute(sql: "CREATE TABLE storage_probe (value BLOB)")
            // Exercise a real SQLITE_FULL with a tiny, isolated in-memory
            // database quota, rather than filling the Simulator/device disk.
            try db.execute(sql: "PRAGMA max_page_count = 3")
        }
        do {
            try await manager.writer { db in
                try db.execute(sql: "INSERT INTO storage_probe VALUES (zeroblob(1048576))")
            }
            Issue.record("SQLITE_FULL must propagate")
        } catch {
            #expect(error is DatabaseError) // No lossy replacement of the DB error.
            #expect(StorageSpaceFailure.matches(error))
        }
        #expect(try await manager.reader { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM storage_probe") } == 0)
        try await manager.writer { db in
            try db.execute(sql: "PRAGMA max_page_count = 1000")
            try db.execute(sql: "INSERT INTO storage_probe VALUES ('retried')")
        }
        #expect(try await manager.reader { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM storage_probe") } == 1)
    }
}
