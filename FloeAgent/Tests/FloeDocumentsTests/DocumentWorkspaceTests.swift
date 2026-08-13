import Foundation
import Testing
@testable import FloeDocuments

@Suite("FloeDocuments.DocumentWorkspace")
struct DocumentWorkspaceTests {
    @Test("Save replaces the original through a private working copy")
    func roundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-document-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("sample.docx")
        try Data("before".utf8).write(to: original)
        let workspace = try SecurityScopedDocumentWorkspace(
            root: root.appendingPathComponent("workspace", isDirectory: true)
        )

        let session = try await workspace.open(securityScopedURL: original)
        try Data("after".utf8).write(to: session.workingURL)
        try await workspace.save(session)

        #expect(try Data(contentsOf: original) == Data("after".utf8))
        #expect(try Data(contentsOf: session.workingURL) == Data("after".utf8))
        await workspace.close(session)
        #expect(!FileManager.default.fileExists(atPath: session.workingURL.path))
    }
}
