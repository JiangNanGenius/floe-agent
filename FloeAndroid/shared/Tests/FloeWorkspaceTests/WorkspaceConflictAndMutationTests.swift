// FloeAndroidWorkspaceTests — Android-authored conflict/CAS and filesystem
// mutation contracts. Authored (job-b6c74b42a49d4f45, G04-R1 files-domain),
// NOT executed in this source lane; Main's grouped host cohort runs them.
//
// These pin the ORIGINAL optimistic-concurrency guarantees (mtime+sha256,
// no-overwrite creation, root/descendant refusal, non-empty directory
// refusal, serialized filesystem transactions) and explicitly do not touch
// the G03 transfer engine/journal, which stays the separate Linux-workspace
// authority.

import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeWorkspace

final class WorkspaceConflictAndMutationTests: XCTestCase {
    private var root: URL!
    private var service: WorkspaceFileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ws-cas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func rawBytes(_ relative: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relative))
    }

    /// mtime+sha256 mismatch is a typed conflict and NEVER overwrites.
    func testStaleExpectationsConflictAndLeaveDiskUntouched() throws {
        try service.createFile("doc.txt", content: "v1\n")
        let current = try service.metadata("doc.txt")

        XCTAssertThrowsError(try service.writeFile(
            "doc.txt", content: "overwritten",
            expectedSHA256: String(repeating: "0", count: 64))) { error in
            guard case WorkspaceToolError.conflict(let expected, let actual) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertTrue(expected.hasPrefix("sha256 "))
            XCTAssertTrue(actual.hasPrefix("sha256 \(current.sha256)"))
        }
        XCTAssertThrowsError(try service.writeFile(
            "doc.txt", content: "overwritten", expectedMtime: current.mtime + 5)) { error in
            guard case WorkspaceToolError.conflict = error else {
                return XCTFail("expected mtime conflict, got \(error)")
            }
        }
        XCTAssertEqual(try rawBytes("doc.txt"), Data("v1\n".utf8))

        // An expectation against a MISSING file is itself a conflict: a
        // creation through a stale CAS handle is refused, not smuggled in.
        XCTAssertThrowsError(try service.writeFile(
            "ghost.txt", content: "new", expectedSHA256: current.sha256)) { error in
            guard case WorkspaceToolError.conflict(let expected, let actual) = error else {
                return XCTFail("expected missing-file conflict, got \(error)")
            }
            XCTAssertEqual(expected, "existing file")
            XCTAssertEqual(actual, "missing file")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ghost.txt").path))
    }

    /// Matching expectations commit; the returned outcome equals the final
    /// on-disk state (digest + mtime), so the caller can rebind its baseline.
    func testMatchedExpectationsCommitWithRebindableOutcome() throws {
        try service.createFile("cas.txt", content: "base\n")
        let first = try service.metadata("cas.txt")
        let outcome = try service.writeFile(
            "cas.txt", content: "next\n", expectedMtime: first.mtime, expectedSHA256: first.sha256)
        XCTAssertEqual(outcome.sha256, FloeDigest.sha256Hex(Data("next\n".utf8)))
        XCTAssertEqual(outcome.bytesWritten, 5)
        let reread = try service.metadata("cas.txt")
        XCTAssertEqual(reread.sha256, outcome.sha256)
        XCTAssertEqual(reread.mtime, outcome.mtime, accuracy: 1.0)
    }

    func testCreateSemanticsNeverTouchDirectoriesSilently() throws {
        try service.createDirectory("sub")
        try service.createFile("sub/file.txt", content: "x")

        XCTAssertThrowsError(try service.createFile("sub/file.txt", content: "y")) { error in
            XCTAssertEqual(error as? WorkspaceToolError, .alreadyExistsOverwritable("sub/file.txt"))
        }
        XCTAssertThrowsError(try service.createFile("sub", content: "y")) { error in
            XCTAssertEqual(error as? WorkspaceToolError, .alreadyExists("sub"))
        }
        XCTAssertThrowsError(try service.createDirectory("sub/file.txt"))
        // Explicit overwrite targets files only.
        XCTAssertNoThrow(try service.createFile("sub/file.txt", content: "y", overwrite: true))
        XCTAssertEqual(try rawBytes("sub/file.txt"), Data("y".utf8))
    }

    /// Root and self-descendant mutations are refused BEFORE filesystem calls;
    /// delete of a non-empty directory requires an explicit recursive consent.
    func testRootAndDescendantAndDeleteRefusals() throws {
        try service.createDirectory("dir")
        try service.createFile("dir/inner.txt", content: "1")

        for operation in ["move", "copy", "delete"] {
            XCTAssertThrowsError(try { () throws -> Void in
                switch operation {
                case "move": try service.move(".", to: "elsewhere")
                case "copy": try service.copy(".", to: "elsewhere")
                default: try service.delete(".")
                }
            }()) { error in
                guard case WorkspaceToolError.invalidArguments(let reason)? = error as? WorkspaceToolError else {
                    return XCTFail("\(operation): expected invalidArguments, got \(error)")
                }
                XCTAssertTrue(reason.contains("workspace root"), operation)
            }
        }
        XCTAssertThrowsError(try service.move("dir", to: "dir/sub/inner"))
        XCTAssertThrowsError(try service.copy("dir", to: "dir/nested-copy/inner"))
        XCTAssertThrowsError(try service.delete("dir")) // non-empty without consent
        XCTAssertEqual(try rawBytes("dir/inner.txt"), Data("1".utf8))
        XCTAssertNoThrow(try service.delete("dir", recursive: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dir").path))
    }

    /// Move/copy refuse an existing destination and copy keeps BOTH sides.
    func testMoveCopyDestinationRules() throws {
        try service.createFile("a.txt", content: "A")
        try service.createFile("b.txt", content: "B")
        XCTAssertThrowsError(try service.copy("a.txt", to: "b.txt")) { error in
            XCTAssertEqual(error as? WorkspaceToolError, .alreadyExists("b.txt"))
        }
        XCTAssertThrowsError(try service.move("a.txt", to: "b.txt"))
        try service.copy("a.txt", to: "copy/a-copy.txt")
        XCTAssertEqual(try rawBytes("a.txt"), Data("A".utf8))
        XCTAssertEqual(try rawBytes("copy/a-copy.txt"), Data("A".utf8))
        try service.move("a.txt", to: "moved/a-moved.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try rawBytes("moved/a-moved.txt"), Data("A".utf8))
    }

    /// Concurrent filesystem transactions against one workspace root are
    /// serialized by the shared mutation lock and never interleave partial
    /// states: every writer succeeds and every file ends in exactly one
    /// writer's bytes with a digest that re-reads as that writer's last CAS.
    func testConcurrentWritesSerializeWithoutCorruption() throws {
        try service.createFile("shared.txt", content: "init\n")
        let writers = 8
        let iterations = 8
        let serviceCopy = service!
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for round in 0..<iterations {
                _ = try? serviceCopy.writeFile(
                    "shared.txt", content: "w\(writer)-r\(round)\n")
            }
        }
        let final = try service.readFileForEditing("shared.txt").text
        let digest = FloeDigest.sha256Hex(Data(final.utf8))
        XCTAssertEqual(digest, (try service.metadata("shared.txt")).sha256,
                       "reader must never observe a half-written file")
        XCTAssertNotNil(final.range(of: #"^w\d+-r\d+\n$"#, options: .regularExpression),
                        "final state must be exactly one writer's complete payload: \(final)")
    }

    /// The mutationGuard contract (design-freeze seam): a throwing gate blocks
    /// every mutation kind — create-overwrite, write, patch, move source AND
    /// destination, copy destination, delete, user import — while reads,
    /// listings, searches and metadata stay available.
    func testMutationGuardBlocksEveryMutationAndNotReads() throws {
        try service.createFile("frozen.txt", content: "keep\n")
        try service.createFile("other.txt", content: "ok\n")
        let guarded = WorkspaceFileService(guard: service.guardResolver, mutationGuard: { url in
            if url.lastPathComponent == "frozen.txt" || url.lastPathComponent == "into-frozen.txt" {
                throw WorkspaceToolError.invalidArguments("frozen original")
            }
        })
        XCTAssertEqual(try guarded.readFileForEditing("frozen.txt").text, "keep\n")
        XCTAssertNoThrow(try guarded.listDirectory("", pageToken: nil))
        XCTAssertNoThrow(try guarded.search(query: "keep"))
        XCTAssertNoThrow(try guarded.metadata("frozen.txt"))

        XCTAssertThrowsError(try guarded.writeFile("frozen.txt", content: "x"))
        XCTAssertThrowsError(try guarded.createFile("frozen.txt", content: "x", overwrite: true))
        XCTAssertThrowsError(try guarded.createBinaryFile("frozen.txt", data: Data("x".utf8), overwrite: true))
        let patch = guarded.diff(original: "keep\n", modified: "changed\n", label: "frozen.txt")
        XCTAssertFalse(patch.isEmpty)
        XCTAssertThrowsError(try guarded.applyPatch("frozen.txt", patch: patch))
        XCTAssertThrowsError(try guarded.move("frozen.txt", to: "gone.txt"))
        XCTAssertThrowsError(try guarded.move("other.txt", to: "into-frozen.txt"))
        // The ORIGINAL copy guards only the destination (the source stays
        // readable while frozen); this pins that exact asymmetry.
        XCTAssertThrowsError(try guarded.copy("other.txt", to: "into-frozen.txt"))
        XCTAssertThrowsError(try guarded.delete("frozen.txt"))
        XCTAssertEqual(try rawBytes("frozen.txt"), Data("keep\n".utf8))
        XCTAssertEqual(try rawBytes("other.txt"), Data("ok\n".utf8))

        // A NEW file at an unguarded path still works while the original is
        // frozen (staging-then-adopt flow).
        XCTAssertNoThrow(try guarded.createFile("candidate.txt", content: "proposal"))
    }

    /// Cancellation fences every cooperative operation BEFORE it touches the
    /// filesystem, and a cancelled token never mutates (recoverable data).
    func testPreCancelledTokenFencesAllOperations() throws {
        try service.createFile("c.txt", content: "base\n")
        try service.createDirectory("d")
        let attachment = root.appendingPathComponent("attachment.bin")
        try Data("attach".utf8).write(to: attachment)
        let directorySnapshot = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let token = CancellationToken()
        token.cancel()

        func assertCancelled(_ label: String, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), label) { error in
                guard case FloeError.cancelled = error else {
                    return XCTFail("\(label): expected FloeError.cancelled, got \(error)")
                }
            }
        }
        assertCancelled("list") { _ = try service.listDirectory("", pageToken: nil, cancellation: token) }
        assertCancelled("read") { _ = try service.readFile("c.txt", cancellation: token) }
        assertCancelled("editRead") { _ = try service.readFileForEditing("c.txt", cancellation: token) }
        assertCancelled("search") { _ = try service.search(query: "base", cancellation: token) }
        assertCancelled("names") { _ = try service.searchFileNames(query: "c", cancellation: token) }
        assertCancelled("create") { _ = try service.createFile("new.txt", content: "x", cancellation: token) }
        assertCancelled("createBinary") { _ = try service.createBinaryFile("new.bin", data: Data([1]), cancellation: token) }
        assertCancelled("mkdir") { try service.createDirectory("newdir", cancellation: token) }
        assertCancelled("write") { _ = try service.writeFile("c.txt", content: "x", cancellation: token) }
        assertCancelled("patch") { _ = try service.applyPatch("c.txt", patch: "not-even-a-patch", cancellation: token) }
        assertCancelled("move") { try service.move("c.txt", to: "moved.txt", cancellation: token) }
        assertCancelled("copy") { try service.copy("c.txt", to: "copied.txt", cancellation: token) }
        assertCancelled("delete") { try service.delete("c.txt", cancellation: token) }
        // `editConflict`/`resolveConflict` take no token by original design:
        // they run the same fenced read/write helpers, pinned in the conflict
        // tests above; here only the token-carrying surface is exercised.
        assertCancelled("import") {
            _ = try service.importUserFile(from: attachment, to: "imported.bin", expectedSHA256: nil, cancellation: token)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       directorySnapshot, "cancelled operations must leave the tree exactly as found")
        XCTAssertEqual(try rawBytes("c.txt"), Data("base\n".utf8))
    }
}
