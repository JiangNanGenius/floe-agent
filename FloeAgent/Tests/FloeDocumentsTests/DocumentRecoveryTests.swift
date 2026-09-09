import Foundation
import Testing
import Crypto
@testable import FloeDocuments

@Suite("FloeDocuments durable recovery")
struct DocumentRecoveryTests {
    private func fixture() throws -> (URL, URL, SecurityScopedDocumentWorkspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Report.docx")
        try Data("base".utf8).write(to: original)
        return (root, original, try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions")))
    }

    @Test("A retained edit resumes with its original revision and can be saved")
    func resumeEdit() async throws {
        let (root, original, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await first.open(securityScopedURL: original)
        try Data("edit".utf8).write(to: session.workingURL)
        await first.close(session)
        let restarted = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        let records = try await restarted.recoveryRecords()
        #expect(records.map(\.id) == [session.id])
        #expect(records.first?.displayName == "Report.docx")
        let resumed = try await restarted.resumeRecovery(id: session.id)
        #expect(resumed.id == session.id)
        #expect(resumed.originalURL.standardizedFileURL == original.standardizedFileURL)
        #expect(try Data(contentsOf: resumed.workingURL) == Data("edit".utf8))
        try await restarted.save(resumed)
        #expect(try Data(contentsOf: original) == Data("edit".utf8))
        await restarted.close(resumed)
        #expect(try await restarted.recoveryRecords().isEmpty)
    }

    @Test("Restarting does not silently accept another editor's revision")
    func conflictAfterRestart() async throws {
        let (root, original, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await first.open(securityScopedURL: original)
        try Data("edit".utf8).write(to: session.workingURL)
        await first.close(session)
        try Data("peer".utf8).write(to: original)
        let restarted = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        let resumed = try await restarted.resumeRecovery(id: session.id)
        await #expect(throws: (any Error).self) { try await restarted.save(resumed) }
        #expect(try Data(contentsOf: original) == Data("peer".utf8))
        #expect(try Data(contentsOf: resumed.recoveryURL) == Data("edit".utf8))
        await restarted.close(resumed)
    }

    @Test("A pending commit reconciles only the exact intended digest", arguments: [true, false])
    func interruptedCommit(matchingOriginal: Bool) async throws {
        let (root, original, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await first.open(securityScopedURL: original)
        try Data("edit".utf8).write(to: session.workingURL)
        await first.close(session)
        let directory = session.workingURL.deletingLastPathComponent()
        var journal = try DocumentRecoveryManifest.read(from: directory)
        journal.pendingDigest = SHA256.hash(data: Data("edit".utf8)).map { String(format: "%02x", $0) }.joined()
        try journal.write(to: directory)
        // Reproduce the disk state between original replacement and journal
        // settlement, or an unrelated external edit at that same boundary.
        try Data((matchingOriginal ? "edit" : "peer").utf8).write(to: original)
        let restarted = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        let resumed = try await restarted.resumeRecovery(id: session.id)
        try Data("next".utf8).write(to: resumed.workingURL)
        if matchingOriginal {
            try await restarted.save(resumed)
            #expect(try Data(contentsOf: original) == Data("next".utf8))
        } else {
            await #expect(throws: (any Error).self) { try await restarted.save(resumed) }
            #expect(try Data(contentsOf: original) == Data("peer".utf8))
        }
        await restarted.close(resumed)
    }

    @Test("Two workspace instances cannot own the same recovery copy")
    func exclusiveRecoveryLease() async throws {
        let (root, original, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await first.open(securityScopedURL: original)
        try Data("edit".utf8).write(to: session.workingURL)
        let second = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        #expect(try await second.recoveryRecords().isEmpty)
        await #expect(throws: (any Error).self) { try await second.resumeRecovery(id: session.id) }
        await first.close(session)
        let resumed = try await second.resumeRecovery(id: session.id)
        #expect(try await first.recoveryRecords().isEmpty)
        await #expect(throws: (any Error).self) { try await first.resumeRecovery(id: session.id) }
        await second.close(resumed)
        #expect(try await first.recoveryRecords().count == 1)
    }

    @Test("Malformed metadata and aliased copies are preserved but never resumed")
    func invalidRecordIsNotTrusted() async throws {
        let (root, original, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await first.open(securityScopedURL: original)
        try Data("edit".utf8).write(to: session.workingURL)
        await first.close(session)
        let manifest = session.workingURL.deletingLastPathComponent().appendingPathComponent(DocumentRecoveryManifest.fileName)
        let bytes = try Data(contentsOf: manifest)
        try Data("broken record".utf8).write(to: manifest)
        #expect(try await first.recoveryRecords().isEmpty)
        await #expect(throws: (any Error).self) { try await first.resumeRecovery(id: session.id) }
        #expect(try Data(contentsOf: session.workingURL) == Data("edit".utf8))
        try bytes.write(to: manifest)
        try FileManager.default.removeItem(at: session.workingURL)
        try FileManager.default.createSymbolicLink(at: session.workingURL, withDestinationURL: original)
        #expect(try await first.recoveryRecords().isEmpty)
        await #expect(throws: (any Error).self) { try await first.resumeRecovery(id: session.id) }
        #expect(try Data(contentsOf: original) == Data("base".utf8))
    }
}
