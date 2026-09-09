import Foundation
import Testing
@testable import FloeDocuments

private final class ExportFaultFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        if destination.pathComponents.contains("exports") {
            try Data("incomplete".utf8).write(to: destination)
        } else {
            try super.copyItem(at: source, to: destination)
        }
    }
}

@Suite("Document export snapshots")
struct DocumentExportTests {
    private func fixture(withFault: Bool = false) async throws -> (URL, SecurityScopedDocumentWorkspace, DocumentSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Quarterly Report.docx")
        try Data("original".utf8).write(to: original)
        let workspace = try withFault
            ? SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"), fileManager: ExportFaultFileManager())
            : SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        return (root, workspace, try await workspace.open(securityScopedURL: original))
    }

    @Test("export is immutable and does not rebase a conflicted original")
    func independentSnapshot() async throws {
        let (root, workspace, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("edited document".utf8).write(to: session.workingURL)
        try Data("external revision".utf8).write(to: session.originalURL)
        let snapshot = try await workspace.prepareExport(session)
        #expect(try await workspace.hasUncommittedWorkingCopy(session))
        #expect(snapshot.fileURL.lastPathComponent == "Quarterly Report.docx")
        try Data("later autosave".utf8).write(to: session.workingURL, options: .atomic)
        #expect(try Data(contentsOf: snapshot.fileURL) == Data("edited document".utf8))
        await #expect(throws: (any Error).self) { try await workspace.save(session) }
        #expect(try Data(contentsOf: session.originalURL) == Data("external revision".utf8))
        await workspace.finishExport(snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.fileURL.path))
        #expect(try Data(contentsOf: session.workingURL) == Data("later autosave".utf8))
        await workspace.close(session)
    }

    @Test("normal close retains a snapshot until the picker finishes reading it")
    func closeDuringExport() async throws {
        let (root, workspace, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await workspace.prepareExport(session)
        await workspace.close(session)
        #expect(try Data(contentsOf: snapshot.fileURL) == Data("original".utf8))
        await workspace.finishExport(snapshot)
        await workspace.finishExport(snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.fileURL.path))
        #expect(try Data(contentsOf: session.originalURL) == Data("original".utf8))
        await #expect(throws: (any Error).self) { try await workspace.prepareExport(session) }
    }

    @Test("an export cannot be cleaned up by another workspace")
    func exportOwnership() async throws {
        let (root, workspace, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await workspace.prepareExport(session)
        let other = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("other"))
        await other.finishExport(snapshot)
        #expect(FileManager.default.fileExists(atPath: snapshot.fileURL.path))
        await workspace.finishExport(snapshot)
        await workspace.close(session)
    }

    @Test("inconsistent copying never publishes an export or touches originals")
    func inconsistentCopy() async throws {
        let (root, workspace, session) = try await fixture(withFault: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("current edit".utf8).write(to: session.workingURL)
        await #expect(throws: (any Error).self) { try await workspace.prepareExport(session) }
        let exports = session.workingURL.deletingLastPathComponent().appendingPathComponent("exports")
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
        #expect(try Data(contentsOf: session.workingURL) == Data("current edit".utf8))
        #expect(try Data(contentsOf: session.originalURL) == Data("original".utf8))
        await workspace.close(session)
    }
}
