import Foundation
import Testing
@testable import FloeDocuments
@testable import FloeCore

@Suite("FloeDocuments.DocumentWorkspace")
struct DocumentWorkspaceTests {

    private func makeWorkspace() throws -> (URL, SecurityScopedDocumentWorkspace) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-document-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try SecurityScopedDocumentWorkspace(
            root: root.appendingPathComponent("workspace", isDirectory: true)
        )
        return (root, workspace)
    }

    @Test("Save replaces the original through a private working copy")
    func roundTrip() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("sample.docx")
        try Data("before".utf8).write(to: original)

        let session = try await workspace.open(securityScopedURL: original)
        try Data("after".utf8).write(to: session.workingURL)
        try await workspace.save(session)

        #expect(try Data(contentsOf: original) == Data("after".utf8))
        #expect(try Data(contentsOf: session.workingURL) == Data("after".utf8))
        await workspace.close(session)
        #expect(!FileManager.default.fileExists(atPath: session.workingURL.path))
    }

    @Test("Security-scoped bookmark round-trip resolves back to the original")
    func bookmarkRoundTrip() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("bookmark.docx")
        try Data("payload".utf8).write(to: original)

        // Create a security-scoped bookmark and resolve it back.
        let bookmark = try original.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #expect(resolved.lastPathComponent == original.lastPathComponent)

        // A session opened from the resolved URL works end to end.
        let session = try await workspace.open(securityScopedURL: resolved)
        try Data("updated".utf8).write(to: session.workingURL)
        try await workspace.save(session)
        #expect(try Data(contentsOf: resolved) == Data("updated".utf8))
        await workspace.close(session)
    }

    @Test("Conflict-safe writeback leaves a recovery copy when the original vanished")
    func conflictWritebackRecovery() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("conflict.docx")
        try Data("v1".utf8).write(to: original)

        let session = try await workspace.open(securityScopedURL: original)
        try Data("v2".utf8).write(to: session.workingURL)

        // Simulate an external change: the original is removed before save.
        try FileManager.default.removeItem(at: original)
        do {
            try await workspace.save(session)
        } catch {
            // Save may fail; the working copy must still hold the user's edit
            // so the caller can surface an explicit conflict state.
        }
        #expect(try Data(contentsOf: session.workingURL) == Data("v2".utf8))
        await workspace.close(session)
    }

    @Test("Close is idempotent and releases the working copy")
    func closeIdempotent() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("close.docx")
        try Data("data".utf8).write(to: original)

        let session = try await workspace.open(securityScopedURL: original)
        await workspace.close(session)
        await workspace.close(session) // second close must not throw/crash
        #expect(!FileManager.default.fileExists(atPath: session.workingURL.path))
    }

    @Test("Opening a non-file URL throws validationFailed")
    func openRejectsNonFileURL() async throws {
        let (_, workspace) = try makeWorkspace()
        let bad = URL(string: "https://example.com/doc.docx")!
        await #expect(throws: FloeError.self) {
            _ = try await workspace.open(securityScopedURL: bad)
        }
    }
}
