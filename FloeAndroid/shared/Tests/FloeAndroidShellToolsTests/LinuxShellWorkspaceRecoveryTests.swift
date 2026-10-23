// SPDX-License-Identifier: MPL-2.0
// Focused strict-parse + bounded-evidence regressions for the OPTIONAL
// per-execution recovery projection (job-5b987a08b1df40b2). Author-written
// against the 951f2f68/bacbaf91 baseline for the FloeAndroidShellToolsTests
// suite. NOT executed by this lane (Main owns the Swift 6 object compile).
import XCTest
@testable import FloeAndroidShellTools

final class LinuxShellWorkspaceRecoveryTests: XCTestCase {
    private static let key32 = String(repeating: "a", count: 32)
    private static let dE64 = String(repeating: "e", count: 64)
    private static let dF64 = String(repeating: "f", count: 64)
    private static let dD64 = String(repeating: "d", count: 64)

    private func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private var valid: String {
        """
        {"sessionKey":"\(Self.key32)",
         "runID":"A1B2C3D4-0000-4000-9000-000000000005",
         "import":{"outcome":"swappedPreserved","created":0,"replacedSynced":1,"preservedUnsynced":1,
                   "unchanged":2,"appliedBytes":57,
                   "preserved":[{"path":"r3cas/marker.txt","action":"swappedPreserved",
                     "preservedSha256":"\(Self.dE64)","preservedBytes":30,
                     "installedBaselineSha256":"\(Self.dF64)","installedBaselineBytes":27}],
                   "conflicts":["dir/a.txt"]},
         "export":{"result":"aborted","applied":{"created":0},"indexDigest":"\(Self.dD64)",
                   "conflicts":[{"path":"dir/b.txt","kind":"file","artifact":true}],
                   "source":"core-export-finish"}}
        """
    }

    func testLegacyAbsenceStaysUnavailable() throws {
        // A legacy terminal envelope WITHOUT the optional key parses fine and
        // reports nil recovery — never a fabricated zero/cleared projection.
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(nil))
        let object = ["sessionID": "s", "leaseReleased": true] as [String: Any]
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(object["workspaceRecovery"]))
    }

    func testValidGrammarParsesEveryBoundedFact() throws {
        guard let raw = object(valid) else { return XCTFail("fixture JSON") }
        let recovery = try XCTUnwrap(LinuxShellWorkspaceRecovery.parse(raw))
        XCTAssertEqual(recovery.sessionKey, Self.key32)
        XCTAssertEqual(recovery.importOutcome, "swappedPreserved")
        XCTAssertEqual(recovery.preserved.count, 1)
        XCTAssertEqual(recovery.preserved[0].path, "r3cas/marker.txt")
        XCTAssertEqual(recovery.preserved[0].preservedSHA256, Self.dE64)
        XCTAssertEqual(recovery.preserved[0].installedBaselineSHA256, Self.dF64)
        XCTAssertEqual(recovery.exportResult, "aborted")
        XCTAssertTrue(recovery.fromCoreReceipt)
        XCTAssertEqual(recovery.exportIndexDigest, Self.dD64)
        XCTAssertEqual(recovery.exportConflicts.first?.kind, "file")
        XCTAssertTrue(recovery.hasActionableEvidence)
    }

    func testMalformedSupplementaryObjectsDroppedToNilNeverThrow() throws {
        let mutations = [
            // foreign-shaped session key
            valid.replacingOccurrences(of: Self.key32, with: "nope"),
            // absolute workspace path smuggled in
            valid.replacingOccurrences(of: "r3cas/marker.txt", with: "/data/absolute.txt"),
            // truncated digest
            valid.replacingOccurrences(of: Self.dE64, with: "abc123"),
            // unknown typed outcome
            valid.replacingOccurrences(of: "\"outcome\":\"swappedPreserved\"", with: "\"outcome\":\"magic\""),
            // unknown export result
            valid.replacingOccurrences(of: "\"result\":\"aborted\"", with: "\"result\":\"mostly\""),
            // negative counter
            valid.replacingOccurrences(of: "\"unchanged\":2", with: "\"unchanged\":-2"),
        ]
        for text in mutations {
            guard let raw = object(text) else { return XCTFail("fixture parse \(text.prefix(40))") }
            XCTAssertNil(LinuxShellWorkspaceRecovery.parse(raw), "must reject: \(text.prefix(60))")
        }
    }

    func testEntryCountBoundsAreHard() throws {
        let copies = (1...17).map { index in
            """
            {"path":"p\(index).txt","action":"swappedPreserved","preservedSha256":"\(Self.dE64)",
             "preservedBytes":1,"installedBaselineSha256":"\(Self.dF64)","installedBaselineBytes":1}
            """
        }.joined(separator: ",")
        let text = """
        {"sessionKey":"\(Self.key32)",
         "import":{"outcome":"swappedPreserved","created":0,"replacedSynced":0,"preservedUnsynced":17,
                   "unchanged":0,"appliedBytes":1,"preserved":[\(copies)]},
         "export":{"failureCode":"budgetExceeded","stagedPreserved":true}}
        """
        guard let raw = object(text) else { return XCTFail("fixture") }
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(raw), "over-cap arrays are malformed metadata")
    }

    func testEvidenceTextIsBoundedAndRelativeOnly() throws {
        guard let raw = object(valid) else { return XCTFail("fixture") }
        let recovery = try XCTUnwrap(LinuxShellWorkspaceRecovery.parse(raw))
        let text = try XCTUnwrap(recovery.evidenceText)
        XCTAssertLessThanOrEqual(text.utf8.count, 2_560)
        XCTAssertFalse(text.contains("/data/"))
        XCTAssertTrue(text.contains("r3cas/marker.txt"))
        XCTAssertTrue(text.contains("session="))
        XCTAssertNotNil(recovery.recoverableSummary) // preservedUnsynced > 0
    }

    func testCleanSyncedHasNoActionableNoise() throws {
        let text = """
        {"sessionKey":"\(Self.key32)",
         "import":{"outcome":"clean","created":1,"replacedSynced":0,"preservedUnsynced":0,
                   "unchanged":0,"appliedBytes":4},
         "export":{"result":"synced","source":"core-export-finish"}}
        """
        guard let raw = object(text) else { return XCTFail("fixture") }
        let recovery = try XCTUnwrap(LinuxShellWorkspaceRecovery.parse(raw))
        XCTAssertFalse(recovery.hasActionableEvidence)
        XCTAssertNil(recovery.evidenceText)
        XCTAssertNil(recovery.recoverableSummary)
    }

    func testFailureWithoutEvidenceStillActionableButQuietSummary() throws {
        let text = """
        {"sessionKey":"\(Self.key32)",
         "import":{"outcome":"clean","created":1,"replacedSynced":0,"preservedUnsynced":0,
                   "unchanged":0,"appliedBytes":4},
         "export":{"failureCode":"budgetExceeded","stagedPreserved":true}}
        """
        guard let raw = object(text) else { return XCTFail("fixture") }
        let recovery = try XCTUnwrap(LinuxShellWorkspaceRecovery.parse(raw))
        XCTAssertTrue(recovery.hasActionableEvidence)
        XCTAssertNotNil(recovery.evidenceText)
        // No preserved copies -> no "remain recoverable" sentence.
        XCTAssertNil(recovery.recoverableSummary)
        XCTAssertTrue(recovery.evidenceText!.contains("failure=budgetExceeded"))
    }
}
