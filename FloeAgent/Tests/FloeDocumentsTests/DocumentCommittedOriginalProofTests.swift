import Foundation
import Testing
@testable import FloeDocuments
@testable import FloeCore

/// Behavior tests for `SecurityScopedDocumentWorkspace.verifyCommittedOriginal`,
/// the read-only original-version proof behind the owner-less clean preview
/// no-op. The skipped `save` is normally the only place where the committed
/// original digest is CAS-checked under file coordination and the mutation
/// lock, so these tests pin the equivalent protection: verify clean originals,
/// reject same-size external rewrites, never write or rebase anything, and
/// fail closed for unregistered sessions or unreadable originals.
@Suite("FloeDocuments.DocumentCommittedOriginalProof")
struct DocumentCommittedOriginalProofTests {

    private func makeWorkspace() throws -> (URL, SecurityScopedDocumentWorkspace) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-committed-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try SecurityScopedDocumentWorkspace(
            root: root.appendingPathComponent("workspace", isDirectory: true)
        )
        return (root, workspace)
    }

    private func isRevisionConflict(_ error: Error) -> Bool {
        guard let officeError = error as? OfficeDocumentError else { return false }
        if case .revisionConflict = officeError { return true }
        return false
    }

    private func snapshot(_ url: URL) throws -> (bytes: Data, modificationDate: Date?, identifier: UInt64?) {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileIdentifierKey])
        return (try Data(contentsOf: url), values.contentModificationDate, values.fileIdentifier)
    }

    @Test("An unchanged committed original verifies repeatedly without touching any bytes")
    func unchangedOriginalVerifiesWithoutWrites() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("proof.docx")
        try Data("committed bytes".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        let directory = session.workingURL.deletingLastPathComponent()
        let manifestURL = directory.appendingPathComponent(DocumentRecoveryManifest.fileName)
        let originalBefore = try snapshot(original)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        try await workspace.verifyCommittedOriginal(session)
        try await workspace.verifyCommittedOriginal(session) // idempotent, read-only

        let originalAfter = try snapshot(original)
        #expect(originalAfter.bytes == originalBefore.bytes)
        #expect(originalAfter.modificationDate == originalBefore.modificationDate)
        #expect(originalAfter.identifier == originalBefore.identifier)
        // No journal rewrite, no rebasing, no staging or recovery artifacts.
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == listingBefore)
        #expect(try await workspace.hasUncommittedWorkingCopy(session) == false)
        await workspace.close(session)
    }

    @Test("An external same-size rewrite with a restored timestamp is rejected and never rebased")
    func sameSizeRewriteWithRestoredTimestampIsRejected() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("conflict.xlsx")
        let pristine = Data("same-size payload".utf8)
        try pristine.write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        let directory = session.workingURL.deletingLastPathComponent()
        let manifestURL = directory.appendingPathComponent(DocumentRecoveryManifest.fileName)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let mtime = try #require(
            try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var tampered = pristine
        for index in tampered.startIndex..<tampered.endIndex { tampered[index] ^= 0x01 }
        #expect(tampered.count == pristine.count && tampered != pristine)
        try tampered.write(to: original)
        var restoredValues = URLResourceValues()
        restoredValues.contentModificationDate = mtime
        var originalAttributes = original
        try originalAttributes.setResourceValues(restoredValues)
        let afterRewrite = try snapshot(original)
        #expect(afterRewrite.bytes.count == pristine.count)
        // Setup verification only: the scenario must preserve size AND
        // timestamp, so a metadata-confusing rewrite looks untouched.
        #expect(afterRewrite.modificationDate.map { abs($0.timeIntervalSince(mtime)) < 1.0 } == true)

        // The editor-side working-copy check alone misses this rewrite:
        // `hasLocalEditsToProtect()` reads clean, which is exactly why the
        // clean no-op needs the original-version proof.
        #expect(try await workspace.hasUncommittedWorkingCopy(session) == false)

        var thrown: Error?
        do { try await workspace.verifyCommittedOriginal(session) } catch { thrown = error }
        #expect(thrown != nil && isRevisionConflict(thrown!))
        // The rejection wrote nothing: the foreign bytes stay intact.
        #expect(try Data(contentsOf: original) == tampered)
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)

        // The baseline was not rebased to the foreign bytes: an immediate
        // second proof fails the same way.
        thrown = nil
        do { try await workspace.verifyCommittedOriginal(session) } catch { thrown = error }
        #expect(thrown != nil && isRevisionConflict(thrown!))

        // Restoring the expected bytes makes the proof pass again, proving the
        // saved committed digest survived every rejection untouched.
        try pristine.write(to: original)
        try await workspace.verifyCommittedOriginal(session)
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)
        #expect(try Data(contentsOf: session.workingURL) == pristine)
        await workspace.close(session)
    }

    @Test("Closed or foreign sessions refuse even when the original bytes still match")
    func closedAndForeignSessionsRefuse() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (root2, otherWorkspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root2) }
        let original = root.appendingPathComponent("owned.docx")
        try Data("original".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)

        // A second workspace registers its own session for the same file.
        let foreignSession = try await otherWorkspace.open(securityScopedURL: original)
        #expect(try Data(contentsOf: original) == Data("original".utf8)) // proof must fail on ownership, not bytes

        await #expect(throws: FloeError.self) {
            try await workspace.verifyCommittedOriginal(foreignSession)
        }
        let forged = DocumentSession(id: UUID(), originalURL: original,
                                     workingURL: session.workingURL, recoveryURL: session.recoveryURL)
        await #expect(throws: FloeError.self) {
            try await workspace.verifyCommittedOriginal(forged)
        }

        await workspace.close(session)
        // Still matching bytes, but the ownership guard fires first.
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        await #expect(throws: FloeError.self) {
            try await workspace.verifyCommittedOriginal(session)
        }
        await otherWorkspace.discardChangesAndClose(foreignSession)
    }

    @Test("A vanished or substituted original fails closed instead of claiming committed")
    func unreadableOriginalFailsClosed() async throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("vanishing.docx")
        try Data("payload".utf8).write(to: original)
        let session = try await workspace.open(securityScopedURL: original)
        try FileManager.default.removeItem(at: original)
        await #expect(throws: (any Error).self) {
            try await workspace.verifyCommittedOriginal(session)
        }
        // A directory at the original path is not a regular readable file.
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await workspace.verifyCommittedOriginal(session)
        }
        try FileManager.default.removeItem(at: original)
        try Data("payload".utf8).write(to: original)
        try await workspace.verifyCommittedOriginal(session) // recovery path intact
        await workspace.close(session)
    }
}
