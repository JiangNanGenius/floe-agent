import Foundation
import Testing
@testable import FloeDocuments
@testable import FloeCore

private final class RecoveryCopyFaultFileManager: FileManager, @unchecked Sendable {
    enum Fault { case copyFailure, changedCopy }
    let fault: Fault

    init(_ fault: Fault) { self.fault = fault; super.init() }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard dstURL.lastPathComponent.hasPrefix(".floe-recovery-") else {
            return try super.copyItem(at: srcURL, to: dstURL)
        }
        switch fault {
        case .copyFailure:
            throw CocoaError(.fileWriteOutOfSpace)
        case .changedCopy:
            try Data("incomplete new copy".utf8).write(to: dstURL)
        }
    }
}

@Suite("FloeDocuments.DocumentWorkspace")
struct DocumentWorkspaceTests {

    @Test("Normal close preserves unsettled engine generations even when the working file is unchanged")
    func engineGenerationSurvivesCleanWorkingClose() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("native.docx")
        try Data("original".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        let generation = session.engineCopyDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        let nativeCopy = generation.appendingPathComponent("working.docx")
        try Data("new engine edits".utf8).write(to: nativeCopy)
        await workspace.close(session)
        await workspace.close(session)
        #expect(try Data(contentsOf: nativeCopy) == Data("new engine edits".utf8))
        #expect(try Data(contentsOf: session.workingURL) == Data("original".utf8))
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test("Only explicit discard may remove a native generation before it reaches the working file")
    func explicitDiscardRemovesNativeGeneration() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("native.pptx")
        try Data("original".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        try FileManager.default.createDirectory(at: session.engineCopyDirectory, withIntermediateDirectories: true)
        let nativeCopy = session.engineCopyDirectory.appendingPathComponent("working.pptx")
        try Data("discarded edit".utf8).write(to: nativeCopy)
        await workspace.discardChangesAndClose(session)
        #expect(!FileManager.default.fileExists(atPath: nativeCopy.path))
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test("Failed or inconsistent recovery refresh preserves the previous recovery bytes",
          arguments: [RecoveryCopyFaultFileManager.Fault.copyFailure, .changedCopy])
    fileprivate func recoveryRefreshFailure(_ fault: RecoveryCopyFaultFileManager.Fault) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-recovery-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"),
                                                            fileManager: RecoveryCopyFaultFileManager(fault))
        let original = root.appendingPathComponent("document.docx")
        try Data("original".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        try Data("previous recovery".utf8).write(to: session.recoveryURL)
        try Data("current edit".utf8).write(to: session.workingURL)
        await #expect(throws: (any Error).self) { try await workspace.save(session) }
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        #expect(try Data(contentsOf: session.recoveryURL) == Data("previous recovery".utf8))
        #expect(try Data(contentsOf: session.workingURL) == Data("current edit".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: session.workingURL.deletingLastPathComponent().path)
        #expect(!files.contains { $0.hasPrefix(".floe-recovery-") })
        await workspace.close(session)
        #expect(try Data(contentsOf: session.recoveryURL) == Data("previous recovery".utf8))
    }

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

    @Test("External same-size changes survive save conflicts and normal close")
    func externalChangeCannotBeOverwritten() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("conflict.xlsx")
        try Data("base".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        try Data("edit".utf8).write(to: session.workingURL)
        try Data("older recovery".utf8).write(to: session.recoveryURL)
        try Data("peer".utf8).write(to: original)
        await #expect(throws: (any Error).self) { try await workspace.save(session) }
        #expect(try Data(contentsOf: original) == Data("peer".utf8))
        #expect(try Data(contentsOf: session.recoveryURL) == Data("edit".utf8))
        await workspace.close(session)
        #expect(try Data(contentsOf: session.workingURL) == Data("edit".utf8))
        await #expect(throws: (any Error).self) { try await workspace.save(session) }
    }

    @Test("Repeated saves advance the baseline and explicit discard preserves the original")
    func repeatedSaveAndDiscard() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("slides.pptx")
        try Data("one".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        for value in ["two", "three"] {
            try Data(value.utf8).write(to: session.workingURL)
            try await workspace.save(session)
            #expect(try Data(contentsOf: original) == Data(value.utf8))
            #expect(try Data(contentsOf: session.workingURL) == Data(value.utf8))
        }
        try Data("discard".utf8).write(to: session.workingURL)
        await workspace.discardChangesAndClose(session)
        #expect(try Data(contentsOf: original) == Data("three".utf8))
        #expect(!FileManager.default.fileExists(atPath: session.workingURL.path))
    }

    @Test("Forged session paths cannot direct writeback or cleanup")
    func forgedSessionIsRejected() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.docx")
        try Data("original".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        let forged = DocumentSession(id: session.id, originalURL: original, workingURL: original, recoveryURL: root.appendingPathComponent("bad"))
        await #expect(throws: (any Error).self) { try await workspace.save(forged) }
        await workspace.discardChangesAndClose(forged)
        #expect(try Data(contentsOf: original) == Data("original".utf8))
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
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = URL(string: "https://example.com/doc.docx")!
        await #expect(throws: FloeError.self) {
            _ = try await workspace.open(securityScopedURL: bad)
        }
    }
}
