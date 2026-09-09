import Foundation
import Testing
@testable import FloeDocuments

@Suite("Document recovery versions")
struct DocumentRecoveryVersionTests {
    private func fixture() async throws -> (URL, SecurityScopedDocumentWorkspace, DocumentSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-versions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Document.docx")
        try Data("original".utf8).write(to: original)
        let workspace = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        let session = try await workspace.open(securityScopedURL: original)
        let generation = session.engineCopyDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        let engine = generation.appendingPathComponent("working.docx")
        try Data("new editor contents".utf8).write(to: engine)
        return (root, workspace, session, engine)
    }

    @Test("restore exposes newer engine bytes while preserving previous work and original CAS")
    func restoreEngineVersion() async throws {
        let (root, workspace, session, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("prior working edit".utf8).write(to: session.workingURL)
        let versions = try await workspace.recoveryVersions(session)
        let editor = try #require(versions.first { $0.kind == .editor })
        try await workspace.restoreRecoveryVersion(editor, in: session)
        #expect(try Data(contentsOf: session.workingURL) == Data("new editor contents".utf8))
        #expect(try Data(contentsOf: session.originalURL) == Data("original".utf8))
        #expect(try await workspace.hasUncommittedWorkingCopy(session))
        let refreshed = try await workspace.recoveryVersions(session)
        let previous = try #require(refreshed.first { $0.kind == .previousEdit })
        #expect(try Data(contentsOf: previous.fileURL) == Data("prior working edit".utf8))
        try Data("peer edit".utf8).write(to: session.originalURL)
        await #expect(throws: (any Error).self) { try await workspace.save(session) }
        #expect(try Data(contentsOf: session.originalURL) == Data("peer edit".utf8))
        await workspace.close(session)
    }

    @Test("changed and unknown version rows cannot overwrite working contents")
    func staleVersion() async throws {
        let (root, workspace, session, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let versions = try await workspace.recoveryVersions(session)
        let editor = try #require(versions.first { $0.kind == .editor })
        try Data("different engine version".utf8).write(to: engine)
        await #expect(throws: (any Error).self) { try await workspace.restoreRecoveryVersion(editor, in: session) }
        #expect(try Data(contentsOf: session.workingURL) == Data("original".utf8))
        let other = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("other"))
        await #expect(throws: (any Error).self) { try await other.restoreRecoveryVersion(editor, in: session) }
        await workspace.close(session)
    }

    @Test("identical editor generations are deduplicated and aliases are excluded")
    func safeInventory() async throws {
        let (root, workspace, session, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: engine)
        let versions = try await workspace.recoveryVersions(session)
        #expect(versions.count == 1)
        #expect(versions.first?.kind == .current)
        try FileManager.default.removeItem(at: engine)
        try FileManager.default.createSymbolicLink(at: engine, withDestinationURL: session.originalURL)
        #expect(try await workspace.recoveryVersions(session).count == 1)
        await workspace.close(session)
    }

    @Test("an ancestor replaced by an alias after listing cannot be restored")
    func ancestorAlias() async throws {
        let (root, workspace, session, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let versions = try await workspace.recoveryVersions(session)
        let editor = try #require(versions.first { $0.kind == .editor })
        let parent = engine.deletingLastPathComponent()
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        await #expect(throws: (any Error).self) { try await workspace.restoreRecoveryVersion(editor, in: session) }
        #expect(try Data(contentsOf: session.workingURL) == Data("original".utf8))
        await workspace.close(session)
    }
}
