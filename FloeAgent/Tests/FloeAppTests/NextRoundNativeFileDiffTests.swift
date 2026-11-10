import Foundation
import XCTest
@testable import FloeApp

final class NextRoundNativeFileDiffTests: XCTestCase {
    func testFiveChangesShowByDefaultWithExactOldAndNewNumbers() throws {
        let diff = try NativeFileDiff(unifiedDiff: "--- a/a.txt\n+++ b/a.txt\n@@ -8,3 +8,4 @@\n keep\n-old\n-old2\n+new\n+new2\n+new3\n")
        XCTAssertEqual(diff.added, 3); XCTAssertEqual(diff.removed, 2)
        XCTAssertEqual(diff.changedLineCount, 5); XCTAssertTrue(diff.showsChangesByDefault)
        XCTAssertEqual(diff.changedLines.map(\.oldNumber), [9, 10, nil, nil, nil])
        XCTAssertEqual(diff.changedLines.map(\.newNumber), [nil, nil, 9, 10, 11])
        XCTAssertEqual(diff.compactLines.count, 5)
    }
    func testSixChangesUseSummaryRatherThanHunkCount() throws {
        let diff = try NativeFileDiff(unifiedDiff: "@@ -1,3 +1,3 @@\n-a\n-b\n-c\n+A\n+B\n+C\n")
        XCTAssertEqual(diff.changedLineCount, 6); XCTAssertFalse(diff.showsChangesByDefault)
    }
    func testPlusAndMinusPrefixesInsideHunkRemainFileContents() throws {
        let diff = try NativeFileDiff(unifiedDiff: "--- a/example\n+++ b/example\n@@ -1 +1 @@\n--- not a header\n+++ not a header\n")
        XCTAssertEqual(diff.paths, ["example"])
        XCTAssertEqual(diff.changedLines.map(\.content), ["-- not a header", "++ not a header"])
        XCTAssertEqual(diff.added, 1); XCTAssertEqual(diff.removed, 1)
    }
    func testZeroRangeCreationAndDeletionUseRealNumbers() throws {
        let created = try NativeFileDiff(unifiedDiff: "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+hello\n+world\n")
        XCTAssertEqual(created.paths, ["new.txt"]); XCTAssertEqual(created.removed, 0)
        XCTAssertEqual(created.changedLines.map(\.newNumber), [1, 2])
        let deleted = try NativeFileDiff(unifiedDiff: "--- a/old.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-hello\n-world\n")
        XCTAssertEqual(deleted.paths, ["old.txt"]); XCTAssertEqual(deleted.added, 0)
        XCTAssertEqual(deleted.changedLines.map(\.oldNumber), [1, 2])
    }
    func testBlankChangedLinesAndNoNewlineMarkerAreNotDropped() throws {
        let diff = try NativeFileDiff(unifiedDiff: "@@ -1,2 +1,2 @@\n-\n-old\n\\ No newline at end of file\n+\n+new\n\\ No newline at end of file\n")
        XCTAssertEqual(diff.changedLineCount, 4)
        XCTAssertEqual(diff.changedLines.map(\.content), ["", "old", "", "new"])
        XCTAssertEqual(diff.lines.filter { $0.kind == .noNewline }.count, 2)
    }
    func testSeparatedHunksKeepAbsoluteLineNumbers() throws {
        let diff = try NativeFileDiff(unifiedDiff: "@@ -2 +2 @@\n-old\n+new\n@@ -100 +100 @@ fn\n-tail\n+TAIL\n")
        XCTAssertEqual(diff.changedLines.compactMap(\.oldNumber), [2, 100])
        XCTAssertEqual(diff.changedLines.compactMap(\.newNumber), [2, 100])
    }
    func testGitMetadataAndMultipleFilesDoNotInflateCounts() throws {
        let diff = try NativeFileDiff(unifiedDiff: "diff --git a/a b/a\nindex 111..222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+A\ndiff --git a/b b/b\nnew file mode 100644\n--- /dev/null\n+++ b/b\n@@ -0,0 +1 @@\n+B\n")
        XCTAssertEqual(diff.paths, ["a", "b"]); XCTAssertEqual(diff.added, 2); XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.compactLines.filter { $0.kind == .file }.count, 2)
    }
    func testMalformedAndTruncatedHunksNeverOfferInventedTotals() {
        for text in ["+hello\n-world", "@@ -1,2 +1,2 @@\n-a\n+A\n", "--- a/missing\n@@ -1 +1 @@\n-a\n+A", "@@ -1 +1 @@\n-a\n+A\n+extra\n", "@@ -0 +1 @@\n-a\n+b\n"] {
            XCTAssertThrowsError(try NativeFileDiff(unifiedDiff: text), text)
        }
    }
    func testHugeCountsAndOverlappingHunksFailWithoutOverflow() {
        for text in ["@@ -9223372036854775807,1 +1 @@\n-a\n+A", "@@ -1,99999999 +1 @@\n-a\n+A", "@@ -2 +2 @@\n-a\n+A\n@@ -1 +1 @@\n-b\n+B"] {
            XCTAssertThrowsError(try NativeFileDiff(unifiedDiff: text))
        }
    }
    func testBinaryAndCombinedDiffKeepOriginalEvidenceInsteadOfFalseStatistics() {
        XCTAssertThrowsError(try NativeFileDiff(unifiedDiff: "Binary files a/file and b/file differ"))
        XCTAssertThrowsError(try NativeFileDiff(unifiedDiff: "@@@ -1,1 -1,1 +1,1 @@@\n-a\n+b"))
        XCTAssertThrowsError(try NativeFileDiff(unifiedDiff: String(repeating: "+", count: 512 * 1024 + 1)))
    }
    func testSavedStatusRequiresSuccessfulNativeWriterAndRealResultMarker() {
        XCTAssertEqual(NativeFileDiffDisposition.result(tool: "workspace.writeFile", status: "ok", summary: "written=a bytes=1 sha256=abc"), .applied)
        for status in ["pending", "failed", "denied", "cancelled"] {
            XCTAssertEqual(NativeFileDiffDisposition.result(tool: "workspace.writeFile", status: status, summary: "written=a sha256=abc"), .reference)
        }
        XCTAssertEqual(NativeFileDiffDisposition.result(tool: "mcp.fake.writeFile", status: "ok", summary: "written=a sha256=abc"), .reference)
        XCTAssertEqual(NativeFileDiffDisposition.result(tool: "workspace.writeFile", status: "ok", summary: "proposal preview"), .reference)
        XCTAssertEqual(NativeFileDiffDisposition.result(tool: "workspace.writeFile", status: "ok", summary: "written=a sha256=abc", outcomeUnknown: true), .reference)
    }
    func testPendingPatchIsOnlyAProposalAndTruncatedArgumentsAreRejected() throws {
        let patch = "@@ -1 +1 @@\n-old\n+new\n"
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "file", "patch": patch]), as: UTF8.self)
        XCTAssertEqual(NativeFileDiffDisposition.proposedPatch(tool: "workspace.applyPatch", status: "pending", input: input), patch)
        XCTAssertNil(NativeFileDiffDisposition.proposedPatch(tool: "workspace.applyPatch", status: "ok", input: input))
        XCTAssertNil(NativeFileDiffDisposition.proposedPatch(tool: "workspace.applyPatch", status: "pending", input: String(input.dropLast())))
        XCTAssertNil(NativeFileDiffDisposition.proposedPatch(tool: "workspace.createFile", status: "pending", input: input))
    }
    func testScrollBoundsRespectDeviceAndActualViewport() {
        XCTAssertEqual(NativeFileDiffLayout.maximumHeight(isPad: true, viewportHeight: nil), 320)
        XCTAssertEqual(NativeFileDiffLayout.maximumHeight(isPad: false, viewportHeight: nil), 240)
        XCTAssertEqual(NativeFileDiffLayout.maximumHeight(isPad: true, viewportHeight: 300), 135)
        XCTAssertEqual(NativeFileDiffLayout.maximumHeight(isPad: false, viewportHeight: 200), 90)
        XCTAssertEqual(NativeFileDiffLayout.maximumHeight(isPad: false, viewportHeight: .nan), 240)
    }
}
