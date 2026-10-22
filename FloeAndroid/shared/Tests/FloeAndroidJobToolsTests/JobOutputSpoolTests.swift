// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the ORIGINAL output-spool ownership/bounds
// contract under the Android explicit-root rule (J2). The mirror REMOVES
// `BackgroundJobOutputSpool.defaultRoot()` entirely: on Android the
// globalApplicationSupport fallback must never silently pick a location,
// and every write/read only ever touches the canonical `<job>.txt` inside
// the trusted root Main injected. The compile of this file against the
// mirror is itself the assertion that no default-root API exists.
import XCTest
import Foundation
@testable import FloeAndroidJobTools

final class JobOutputSpoolTests: XCTestCase {

    // MARK: - Canonical ownership confinement

    func testWriteAndReadRoundTripInsideExplicitRoot() throws {
        let root = try JobTestRoot.make(name: "job-output")
        let job = UUID()
        let text = "first line\nsecond line\n"
        guard let spooled = BackgroundJobOutputSpool.write(jobID: job, text: text, root: root) else {
            return XCTFail("explicit trusted root must accept the artifact")
        }
        XCTAssertTrue(spooled.path.hasPrefix(root.path))
        XCTAssertEqual(BackgroundJobOutputSpool.canonicalArtifactURL(jobID: job, root: root).path,
                       spooled.path)
        let metadata = BackgroundJobOutputSpool.readMetadata(path: spooled.path, jobID: job, root: root)
        XCTAssertEqual(metadata, BackgroundJobOutputSpool.Metadata(
            originalBytes: Data(text.utf8).count,
            savedBytes: Data(text.utf8).count,
            truncated: false))
        // The footer is metadata, never page text.
        let page = BackgroundJobOutputSpool.readPage(jobID: job, path: spooled.path,
                                                    offset: 0, maxBytes: 4096, root: root)
        XCTAssertEqual(page?.text, text)
        XCTAssertEqual(page?.nextOffset, nil)
        XCTAssertEqual(page?.complete, true)
        XCTAssertFalse(page?.text?.contains(BackgroundJobOutputSpool.footerPrefix) ?? true)
    }

    func testStoredPathOutsideTheCanonicalRootIsNeverOpened() throws {
        let root = try JobTestRoot.make(name: "job-output")
        let other = try JobTestRoot.make(name: "elsewhere")
        let job = UUID()
        let foreign = other.appendingPathComponent("\(job.uuidString).txt")
        try "foreign".data(using: .utf8)!.write(to: foreign)
        XCTAssertNil(BackgroundJobOutputSpool.readPage(jobID: job, path: foreign.path,
                                                      offset: 0, maxBytes: 4096, root: root),
                     "a stored path outside the spool root is refused, not read")
        XCTAssertFalse(BackgroundJobOutputSpool.isCanonicalArtifactPath(foreign.path, jobID: job, root: root))
        // Another job's artifact inside the root is ALSO not this job's path.
        let someoneElse = BackgroundJobOutputSpool.canonicalArtifactURL(jobID: UUID(), root: root)
        XCTAssertFalse(BackgroundJobOutputSpool.isCanonicalArtifactPath(
            someoneElse.path, jobID: job, root: root))
    }

    // MARK: - Bounds and structured truncation (byte-equal ORIGINAL rules)

    func testOversizedOutputIsCappedAtAScalarBoundaryWithHonestFooter() throws {
        let root = try JobTestRoot.make(name: "job-output")
        let job = UUID()
        // > 1 MiB of 3-byte CJK scalars: the cap lands mid-scalar unless the
        // cut sheds the dangling leading byte.
        var text = ""
        while text.utf8.count < BackgroundJobOutputSpool.maximumArtifactBytes + 8 {
            text += "测"
        }
        guard let spooled = BackgroundJobOutputSpool.write(jobID: job, text: text, root: root) else {
            return XCTFail("explicit trusted root must accept the capped artifact")
        }
        let metadata = BackgroundJobOutputSpool.readMetadata(path: spooled.path, jobID: job, root: root)
        XCTAssertEqual(metadata?.truncated, true)
        XCTAssertLessThanOrEqual(metadata?.savedBytes ?? Int.max,
                                 BackgroundJobOutputSpool.maximumArtifactBytes)
        XCTAssertEqual(metadata?.originalBytes, Data(text.utf8).count)
        // The saved prefix must end on a complete scalar: reading the page
        // with the cap as the bound yields decodable text without a split.
        let page = BackgroundJobOutputSpool.readPage(jobID: job, path: spooled.path,
                                                     offset: 0, maxBytes: 256, root: root)
        XCTAssertNotNil(page?.text)
        let bytes = Data((page?.text ?? "").utf8)
        XCTAssertEqual(bytes.count % 3, 0, "page text must hold whole CJK scalars")
        XCTAssertEqual(page?.complete, false,
                       "a capped artifact is never presented as the complete output")
    }

    // MARK: - Age-pruned retention (called on write, best-effort)

    func testPruneRemovesOnlyExpiredArtifacts() throws {
        let root = try JobTestRoot.make(name: "job-output")
        let old = BackgroundJobOutputSpool.canonicalArtifactURL(jobID: UUID(), root: root)
        let fresh = BackgroundJobOutputSpool.canonicalArtifactURL(jobID: UUID(), root: root)
        try "old".data(using: .utf8)!.write(to: old)
        try "new".data(using: .utf8)!.write(to: fresh)
        let backdated = Date().addingTimeInterval(-BackgroundJobOutputSpool.retentionSeconds - 60)
        try FileManager.default.setAttributes([.modificationDate: backdated],
                                              ofItemAtPath: old.path)
        BackgroundJobOutputSpool.prune(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - UTF-8 window arithmetic (shared with the bounded reader)

    func testScalarBoundaryEndShedsDanglingLeadingByteMidBuffer() {
        // "测" is E6 BD 9B; a cut at 1 or 2 lands INSIDE the scalar and must
        // shed the leading byte too (boundary 0 = whole scalar excluded);
        // a cut at 3 is the scalar boundary; EOF with a full scalar stands.
        let bytes = Data([0xE6, 0xBD, 0x9B, 0x41])
        XCTAssertEqual(JobsResultTool.scalarBoundaryEnd(bytes, proposed: 1), 0)
        XCTAssertEqual(JobsResultTool.scalarBoundaryEnd(bytes, proposed: 2), 0)
        XCTAssertEqual(JobsResultTool.scalarBoundaryEnd(bytes, proposed: 3), 3)
        XCTAssertEqual(JobsResultTool.scalarBoundaryEnd(bytes, proposed: 4), 4)
    }
}
