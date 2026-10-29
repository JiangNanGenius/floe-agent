import Foundation
import Testing
@testable import FloeDocuments

@Suite("Document recovery ownership across suspension")
struct DocumentLeaseSuspensionTests {
    private func fixture() throws -> (URL, URL, SecurityScopedDocumentWorkspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-document-suspension-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("example.txt")
        try Data("original".utf8).write(to: original)
        return (root, original, try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions")))
    }

    @Test("An unchanged session reacquires ownership and retains its unsaved working bytes")
    func unchangedResume() async throws {
        let (root, original, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await workspace.open(securityScopedURL: original)
        try Data("unsaved".utf8).write(to: session.workingURL)
        await workspace.suspendForBackground()
        #expect(await workspace.resumeAfterSuspension().isEmpty)
        #expect(try await workspace.hasUncommittedWorkingCopy(session))
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        await workspace.close(session)
        #expect(FileManager.default.fileExists(atPath: session.workingURL.path))
    }

    @Test("Background really releases the kernel lease; a second owner fences the first")
    func anotherOwnerWins() async throws {
        let (root, original, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await first.open(securityScopedURL: original)
        try Data("unsaved".utf8).write(to: session.workingURL)
        await first.suspendForBackground()
        let second = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        let other = try await second.resumeRecovery(id: session.id)
        #expect(await first.resumeAfterSuspension() == [session.id])
        do {
            _ = try await first.prepareExport(session)
            Issue.record("A session that lost its lease exported another owner's working file")
        } catch OfficeDocumentError.revisionConflict { }
        await first.discardChangesAndClose(session)
        #expect(FileManager.default.fileExists(atPath: other.workingURL.path))
        await second.close(other)
    }

    @Test("Changed recovery bytes are preserved and rejected instead of rebased on resume")
    func changedWorkingCopy() async throws {
        let (root, original, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await workspace.open(securityScopedURL: original)
        await workspace.suspendForBackground()
        try Data("another owner".utf8).write(to: session.workingURL)
        #expect(await workspace.resumeAfterSuspension() == [session.id])
        do {
            try await workspace.save(session)
            Issue.record("Resume silently adopted changed working bytes")
        } catch OfficeDocumentError.revisionConflict { }
        await workspace.close(session)
        #expect(try Data(contentsOf: session.workingURL) == Data("another owner".utf8))
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }
}
