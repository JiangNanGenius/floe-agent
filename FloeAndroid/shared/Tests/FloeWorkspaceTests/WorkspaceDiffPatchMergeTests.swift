// FloeAndroidWorkspaceTests — Android-authored unified-diff, patch and
// three-way merge contracts. Authored (job-b6c74b42a49d4f45, G04-R1
// files-domain), NOT executed in this source lane.
//
// The AI edit path (workspace.applyPatch), the editor conflict review
// (WorkspaceEditConflict → TextMergePlan) and the human resolution share the
// ONE service: patches must apply with hunk-offset drift, refuse on context
// mismatch WITHOUT touching disk, and merge must never guess silently.

import XCTest
import Foundation
import FloeCore
@testable import FloeWorkspace

final class WorkspaceDiffPatchMergeTests: XCTestCase {
    private var root: URL!
    private var service: WorkspaceFileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ws-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func rawBytes(_ relative: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relative))
    }

    /// diff→applyPatch round trip: the generated patch is exactly applicable
    /// to the original bytes and lands the modified bytes.
    func testDiffApplyRoundTrip() throws {
        let original = (1...30).map { "line \($0)" }.joined(separator: "\n")
        var modifiedLines = original.components(separatedBy: "\n")
        modifiedLines[2] = "line 3 EDITED"
        modifiedLines.remove(at: 15)
        modifiedLines.insert("brand new", at: 25)
        let modified = modifiedLines.joined(separator: "\n")

        let patch = service.diff(original: original, modified: modified, label: "doc.txt")
        XCTAssertTrue(patch.hasPrefix("--- a/doc.txt\n+++ b/doc.txt\n@@ "))
        try service.createFile("doc.txt", content: original)
        let outcome = try service.applyPatch("doc.txt", patch: patch)
        XCTAssertEqual(try service.readFileForEditing("doc.txt").text, modified)
        XCTAssertGreaterThan(outcome.hunksApplied, 0)
        XCTAssertGreaterThanOrEqual(outcome.linesAdded, 1)
        XCTAssertGreaterThanOrEqual(outcome.linesRemoved, 1)
        XCTAssertEqual(outcome.sha256, FloeDigest.sha256Hex(Data(modified.utf8)))
    }

    /// Line-position drift between hunks must be tracked: a second hunk
    /// written against pre-first-hunk coordinates still applies.
    func testPatchTracksMultiHunkLineDelta() throws {
        let original = (1...40).map { "n\($0)" }.joined(separator: "\n")
        let modified = "block1\nblock2\nblock3\n" + original
            .replacingOccurrences(of: "\nn20", with: "\nn20extra\nn20.5")
        try service.createFile("drift.txt", content: original)
        let patch = service.diff(original: original, modified: modified, label: "drift.txt")
        XCTAssertNoThrow(try service.applyPatch("drift.txt", patch: patch))
        XCTAssertEqual(try service.readFileForEditing("drift.txt").text, modified)
    }

    /// Context mismatch is refused and NOTHING is written; multi-file patches
    /// and `diff --git` headers are rejected up front.
    func testPatchRefusalsLeaveDiskUntouched() throws {
        try service.createFile("strict.txt", content: "alpha\nbeta\ngamma\n")
        let untouched = try rawBytes("strict.txt")

        XCTAssertThrowsError(try service.applyPatch(
            "strict.txt", patch: "--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n alpha\n-BETA\n+OMEGA\n gamma\n")) { error in
            guard case WorkspaceToolError.invalidPatch(let reason) = error else {
                return XCTFail("expected invalidPatch, got \(error)")
            }
            XCTAssertTrue(reason.contains("context mismatch"))
        }
        // Out-of-range hunk.
        XCTAssertThrowsError(try service.applyPatch(
            "strict.txt", patch: "--- a/x\n+++ b/x\n@@ -99,1 +99,1 @@\n-alpha\n+omega\n")) { error in
            guard case WorkspaceToolError.invalidPatch = error else {
                return XCTFail("expected out-of-range invalidPatch, got \(error)")
            }
        }
        // Two-file patch.
        let twoFile = """
        --- a/one
        +++ b/one
        @@ -1 +1 @@
         alpha
        --- a/two
        +++ b/two
        @@ -1 +1 @@
         beta
        """
        XCTAssertThrowsError(try service.applyPatch("strict.txt", patch: twoFile)) { error in
            guard case WorkspaceToolError.invalidPatch(let reason)? = error as? WorkspaceToolError else {
                return XCTFail("expected multi-file refusal, got \(error)")
            }
            XCTAssertEqual(reason, "multi-file patches are not supported; apply one file per call")
        }
        XCTAssertThrowsError(try service.applyPatch(
            "strict.txt", patch: "diff --git a/strict.txt b/strict.txt\n--- a/strict.txt\n+++ b/strict.txt\n@@ -1 +1 @@\n-alpha\n+omega\n"))
        XCTAssertEqual(try rawBytes("strict.txt"), untouched)
    }

    /// editConflict(preserveDraft:true) snapshots the CURRENT disk bytes with
    /// their mtime+sha, and never destroys the user's draft; resolveConflict
    /// writes through the reviewed version's own expectations, and a NEWER
    /// external edit re-opens the conflict instead of forcing the old choice.
    func testConflictReviewAndResolutionNeverLoseData() throws {
        try service.createFile("shared.txt", content: "disk-v1\n")
        let review = try service.editConflict(
            path: "shared.txt", base: "disk-v0\n", draft: "my-draft\n", preserveDraft: true)
        XCTAssertEqual(review.current, "disk-v1\n")
        XCTAssertEqual(review.currentSHA256, FloeDigest.sha256Hex(Data("disk-v1\n".utf8)))
        XCTAssertNotNil(review.recoveryPath)
        let recovered = try service.readFileForEditing(review.recoveryPath!).text
        XCTAssertEqual(recovered, "my-draft\n", "draft must survive review dismissal")

        // Plan offers the three-way blocks; a same-line clash is an explicit
        // conflict the caller must choose.
        let plan = review.plan
        XCTAssertFalse(plan.conflicts.isEmpty, "base/draft/current diverge on one line")
        XCTAssertNil(plan.resolved([:]), "unresolved conflicts return nil, never a guess")
        let chosenMine = plan.resolved(Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .mine) }))
        XCTAssertEqual(chosenMine, "my-draft\n")

        // Clean resolution binds to the reviewed on-disk version.
        let merged = "merged\n"
        let outcome = try service.resolveConflict(review, content: merged)
        XCTAssertEqual(outcome.sha256, FloeDigest.sha256Hex(Data(merged.utf8)))
        XCTAssertEqual(try rawBytes("shared.txt"), Data(merged.utf8))

        // External edit after the review opened → resolving the stale review
        // is a NEW conflict; the external bytes stay on disk.
        let stale = try service.editConflict(path: "shared.txt", base: nil, draft: "stale-draft")
        try service.writeFile("shared.txt", content: "external-v2\n")
        XCTAssertThrowsError(try service.resolveConflict(stale, content: "force")) { error in
            guard case WorkspaceToolError.conflict = error else {
                return XCTFail("expected re-opened conflict, got \(error)")
            }
        }
        XCTAssertEqual(try rawBytes("shared.txt"), Data("external-v2\n".utf8))
    }

    /// Non-UTF-8 originals must not be silently recoded during conflict
    /// review: review on a binary file fails, and with preserveDraft the
    /// recovery copy is still written first (draft preservation wins).
    func testConflictReviewRefusesNonUTF8WithoutRecoding() throws {
        try Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]).write(
            to: root.appendingPathComponent("utf16.txt"))
        XCTAssertThrowsError(try service.editConflict(path: "utf16.txt", base: nil, draft: "d"))
        var recoverable = false
        do {
            _ = try service.editConflict(path: "utf16.txt", base: nil, draft: "d", preserveDraft: true)
        } catch let recovery as WorkspaceDraftRecoveryError {
            recoverable = true
            XCTAssertFalse(recovery.recoveryPath.isEmpty)
            XCTAssertEqual(try service.readFileForEditing(recovery.recoveryPath).text, "d")
        }
        XCTAssertTrue(recoverable, "preserveDraft must surface WorkspaceDraftRecoveryError")
    }

    /// TextMergePlan auto-merges disjoint edits and only asks for the blocks
    /// where BOTH sides changed the same region differently.
    func testMergePlanAutoMergesDisjointEdits() throws {
        let base = "a\nb\nc\nd\ne\n"
        let mine = "A\nb\nc\nd\ne\n"
        let current = "a\nb\nc\nd\nE\n"
        let plan = TextMergePlan(base: base, mine: mine, current: current)
        XCTAssertTrue(plan.conflicts.isEmpty, "disjoint line edits must not surface as conflicts")
        XCTAssertEqual(plan.resolved(), "A\nb\nc\nd\nE\n")

        // Same region, different content → explicit conflict block.
        let clash = TextMergePlan(base: base, mine: "a\nc\nd\ne\n", current: "a\nX\nY\nd\ne\n")
        XCTAssertFalse(clash.conflicts.isEmpty)
        XCTAssertNil(clash.resolved())
        let takeCurrent = TextMergePlan(base: base, mine: "a\nb\nC\nd\ne\n", current: "a\nb\nD\nd\ne\n")
        XCTAssertEqual(takeCurrent.resolved(Dictionary(uniqueKeysWithValues: takeCurrent.conflicts.map { ($0.id, .current) })),
                       "a\nb\nD\nd\ne\n")
    }
}
