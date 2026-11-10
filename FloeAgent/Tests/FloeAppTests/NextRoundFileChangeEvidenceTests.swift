#if canImport(UIKit)
import Foundation
import XCTest
import FloeCore
import FloeModels
import FloeTools
@testable import FloeWorkspace
@testable import FloeApp

@MainActor final class NextRoundFileChangeEvidenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let run = UUID()
        let token = CancellationToken()
        var environment: WorkspaceToolEnvironment { .init(rootProvider: { [root] in root }) }
        var context: ToolContext { .init(runID: run, cancellation: token) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDiff-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func close() {
            try? FileManager.default.removeItem(at: root)
            if let support = try? FloeArtifactStore.root() {
                try? FileManager.default.removeItem(at: support.appendingPathComponent("ChangeArtifacts/" + run.uuidString))
            }
        }
        func data(_ artifact: ToolArtifactReference) throws -> Data {
            let bytes = try Data(contentsOf: FloeArtifactStore.root().appendingPathComponent(artifact.relativePath))
            XCTAssertEqual(bytes.count, artifact.byteCount)
            XCTAssertEqual(FloeDigest.sha256Hex(bytes), artifact.sha256)
            return bytes
        }
    }

    func testFreshCreateHasNoPhantomRemovedOrTrailingBlankLine() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let output = try await WorkspaceCreateFileTool(environment: fixture.environment)
            .execute(.init(path: "new.txt", content: "one\ntwo\n"), context: fixture.context)
        let artifact = try XCTUnwrap(output.artifacts.first)
        XCTAssertEqual(artifact.mimeType, "text/x-diff")
        let diff = try NativeFileDiff(unifiedDiff: String(decoding: fixture.data(artifact), as: UTF8.self))
        XCTAssertEqual(diff.added, 2); XCTAssertEqual(diff.removed, 0)
        XCTAssertEqual(diff.changedLines.map(\.newNumber), [1, 2])
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("new.txt"), encoding: .utf8), "one\ntwo\n")
    }
    func testOverwriteReadsCompleteBaselineBeyondNormalReadPage() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let original = String(repeating: "a", count: 70_000) + "\n"
        let modified = String(repeating: "b", count: 70_000) + "\n"
        try Data(original.utf8).write(to: fixture.root.appendingPathComponent("long.txt"))
        let output = try await WorkspaceCreateFileTool(environment: fixture.environment)
            .execute(.init(path: "long.txt", content: modified, overwrite: true), context: fixture.context)
        let artifact = try XCTUnwrap(output.artifacts.first)
        XCTAssertEqual(artifact.mimeType, "text/x-diff")
        let diff = try NativeFileDiff(unifiedDiff: String(decoding: fixture.data(artifact), as: UTF8.self))
        XCTAssertEqual(diff.removed, 1); XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.changedLines.first?.content, String(repeating: "a", count: 70_000))
    }
    func testUnknownBinaryBaselineGivesSavedPreviewWithoutFakeAddedTotals() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let file = fixture.root.appendingPathComponent("old.txt")
        try Data([0, 1, 2, 3]).write(to: file)
        let output = try await WorkspaceCreateFileTool(environment: fixture.environment)
            .execute(.init(path: "old.txt", content: "saved", overwrite: true), context: fixture.context)
        let artifact = try XCTUnwrap(output.artifacts.first)
        XCTAssertEqual(artifact.mimeType, "application/vnd.floe.file-preview+json")
        let preview = try JSONDecoder().decode(WorkspaceFileChangePreview.self, from: fixture.data(artifact))
        XCTAssertEqual(preview.comparison, .baselineUnavailable); XCTAssertEqual(preview.text, "saved")
        XCTAssertEqual(preview.byteCount, 5); XCTAssertEqual(preview.sha256, FloeDigest.sha256Hex(Data("saved".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), Data("saved".utf8))
    }
    func testBoundedComparisonPreservesCompleteFileAndExplicitPartialPreview() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let original = String(repeating: "old line abcdef\n", count: 2100)
        let modified = String(repeating: "new line abcdef\n", count: 2100)
        let file = fixture.root.appendingPathComponent("large.txt")
        try Data(original.utf8).write(to: file)
        let output = try await WorkspaceWriteFileTool(environment: fixture.environment)
            .execute(.init(path: "large.txt", content: modified, expectedSHA256: FloeDigest.sha256Hex(Data(original.utf8))), context: fixture.context)
        let artifact = try XCTUnwrap(output.artifacts.first)
        let preview = try JSONDecoder().decode(WorkspaceFileChangePreview.self, from: fixture.data(artifact))
        XCTAssertEqual(preview.comparison, .comparisonTooLarge); XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.text, String(modified.prefix(24_000)))
        XCTAssertEqual(try Data(contentsOf: file), Data(modified.utf8))
        XCTAssertEqual(preview.byteCount, modified.utf8.count)
    }
    func testRealConflictLeavesFileAndEvidenceStoreUntouched() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let file = fixture.root.appendingPathComponent("kept.txt")
        try Data("kept".utf8).write(to: file)
        do {
            _ = try await WorkspaceWriteFileTool(environment: fixture.environment)
                .execute(.init(path: "kept.txt", content: "wrong", expectedSHA256: String(repeating: "0", count: 64)), context: fixture.context)
            XCTFail("A real revision conflict must fail before producing a Saved diff")
        } catch let error as WorkspaceToolError {
            guard case .conflict = error else { return XCTFail("Expected the existing real conflict error") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("kept".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try FloeArtifactStore.root().appendingPathComponent("ChangeArtifacts/" + fixture.run.uuidString).path))
    }
    func testCancelledWriteCannotBecomeComparisonUnavailableSuccess() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.token.cancel()
        do {
            _ = try await WorkspaceCreateFileTool(environment: fixture.environment)
                .execute(.init(path: "absent.txt", content: "wrong"), context: fixture.context)
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(fixture.token.isCancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("absent.txt").path))
    }
    func testRemoteBaselineRequiresCompleteSameRevisionUTF8Bytes() {
        let bytes = Data("old".utf8)
        let first = NetworkWorkspaceFileMetadata(path: "remote", isDirectory: false, byteCount: 3, modifiedAt: nil, entityTag: "r1")
        var changed = first; changed.entityTag = "r2"
        var noToken = first; noToken.entityTag = nil
        XCTAssertEqual(WorkspaceFileChangeEvidence.remoteBaseline(bytes: bytes, before: first, after: first), "old")
        XCTAssertNil(WorkspaceFileChangeEvidence.remoteBaseline(bytes: bytes, before: first, after: changed))
        XCTAssertNil(WorkspaceFileChangeEvidence.remoteBaseline(bytes: bytes, before: noToken, after: noToken))
        XCTAssertNil(WorkspaceFileChangeEvidence.remoteBaseline(bytes: Data("ol".utf8), before: first, after: first))
        XCTAssertNil(WorkspaceFileChangeEvidence.remoteBaseline(bytes: Data([0, 1, 2]), before: first, after: first))
    }
    func testEOFAndNoOpEvidenceAreAccurate() throws {
        let text = try XCTUnwrap(WorkspaceFileChangeEvidence.diff(original: "one", modified: "one\n", label: "eof"))
        let diff = try NativeFileDiff(unifiedDiff: text)
        XCTAssertEqual(diff.added, 1); XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.lines.filter { $0.kind == .noNewline }.count, 1)
        XCTAssertEqual(WorkspaceFileChangeEvidence.diff(original: "same", modified: "same", label: "same"), "")
        let fixture = try Fixture(); defer { fixture.close() }
        let refs = try WorkspaceFileChangeEvidence.artifacts(original: "same", modified: "same", path: "same.txt", runID: fixture.run)
        let preview = try JSONDecoder().decode(WorkspaceFileChangePreview.self, from: fixture.data(try XCTUnwrap(refs.first)))
        XCTAssertEqual(preview.comparison, .unchanged)
    }
    func testInlineDiffAdmissionRequiresActualNativeWriterRunAndDigestPath() {
        let run = UUID(), digest = String(repeating: "a", count: 64)
        var artifact = ToolArtifactReference(id: UUID(), relativePath: "ChangeArtifacts/\(run.uuidString)/\(digest).diff", mimeType: "text/x-diff", byteCount: 60, sha256: digest)
        XCTAssertTrue(ChatInlineContentCatalog.accepts(artifact, runID: run, tool: "workspace.writeFile"))
        XCTAssertFalse(ChatInlineContentCatalog.accepts(artifact, runID: UUID(), tool: "workspace.writeFile"))
        XCTAssertFalse(ChatInlineContentCatalog.accepts(artifact, runID: run, tool: "mcp.fake.writeFile"))
        artifact.relativePath = "ChangeArtifacts/\(run.uuidString)/wrong.diff"
        XCTAssertFalse(ChatInlineContentCatalog.accepts(artifact, runID: run, tool: "workspace.writeFile"))
    }
    func testSavedPreviewUsesExistingNoFollowAndHashVerifier() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try Data([0, 1]).write(to: fixture.root.appendingPathComponent("old.txt"))
        let output = try await WorkspaceCreateFileTool(environment: fixture.environment)
            .execute(.init(path: "old.txt", content: "actual", overwrite: true), context: fixture.context)
        let artifact = try XCTUnwrap(output.artifacts.first), root = try FloeArtifactStore.root()
        let verified = try VerifiedChatInlineArtifact.load(artifact, runID: fixture.run, tool: "workspace.createFile", root: root)
        XCTAssertEqual(verified.data, try fixture.data(artifact))
        try Data("tampered".utf8).write(to: root.appendingPathComponent(artifact.relativePath))
        XCTAssertThrowsError(try VerifiedChatInlineArtifact.load(artifact, runID: fixture.run, tool: "workspace.createFile", root: root))
    }
}
#endif
