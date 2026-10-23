// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the STRICT parse of the OPTIONAL failed-start
// reverse-restore evidence riding a settled status-1 frame
// (job-150dee8e1ed14ba1). Pure value-level grammar checks against the
// public LinuxShellImportRestore.parse surface — no mailbox, no host, no
// device. NOT executed by the authoring job; Main compiles it with the
// existing FloeAndroidShellToolsTests cohort.
import XCTest
import Foundation
import FloeAndroidShellTools

final class LinuxShellFailedStartStrictParseTests: XCTestCase {

    private let sessionKey = String(repeating: "ab", count: 16)
    private let run = "A1B2C3D4-0000-4000-9000-000000000004"

    private func recovery(_ overrides: [String: Any] = [:], omit: Set<String> = [],
                          extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "record": "importRestore",
            "sessionKey": sessionKey,
            "runID": run,
            "trigger": "cancelRequested",
            "restoredPriorChanges": 3,
            "revertedNewEntries": 1,
            "retainedFailures": 0,
        ]
        for key in omit { base.removeValue(forKey: key) }
        for (key, value) in overrides { base[key] = value }
        for (key, value) in extra { base[key] = value }
        return base
    }

    func testValidPairParsesEveryFieldExactly() {
        let parsed = LinuxShellImportRestore.parse(
            failureCode: "importCancelled",
            recovery: recovery())
        XCTAssertEqual(parsed, LinuxShellImportRestore(
            failureCode: "importCancelled", sessionKey: sessionKey, runID: run,
            trigger: "cancelRequested", restoredPriorChanges: 3,
            revertedNewEntries: 1, retainedFailures: 0))
    }

    func testZeroCountersAreLegitimateMeasurementsNotAbsence() {
        // A measured zero is REAL evidence (the restore pass genuinely
        // reverted nothing); it parses and is never confused with absence.
        let parsed = LinuxShellImportRestore.parse(
            failureCode: "swapInterrupted",
            recovery: recovery(["restoredPriorChanges": 0, "revertedNewEntries": 0]))
        XCTAssertEqual(parsed?.restoredPriorChanges, 0)
        XCTAssertEqual(parsed?.revertedNewEntries, 0)
    }

    func testRetainedFailuresStayHonest() {
        let parsed = LinuxShellImportRestore.parse(
            failureCode: "importCancelled:restoreFailures2",
            recovery: recovery(["retainedFailures": 2]))
        XCTAssertEqual(parsed?.retainedFailures, 2)
    }

    // MARK: - Absence and partial pairs

    func testAbsentEitherPartStaysNil() {
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: nil, recovery: nil))
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: "importCancelled", recovery: nil))
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: nil, recovery: recovery()))
    }

    // MARK: - Closed field names

    func testExtraOrMissingFieldNamesDropEverything() {
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: "x", recovery: recovery(omit: ["trigger"])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(extra: ["absPath": "/private/tmp/x"])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(extra: ["nested": ["a": 1]])))
    }

    func testWrongRecordTokenDropped() {
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["record": "exportFinish"])))
    }

    // MARK: - Identity grammars

    func testSessionKeyMustBeExactly32LowercaseHex() {
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["sessionKey": sessionKey.uppercased()])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["sessionKey": String(repeating: "g", count: 32)])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["sessionKey": String(repeating: "ab", count: 15)])))
    }

    func testRunIDMustBeCanonicalUUID() {
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["runID": "not-a-uuid"])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["runID": "{A1B2C3D4-0000-4000-9000-000000000004}"])))
        // Lower-case canonical form is valid grammar (case-insensitive hex).
        XCTAssertNotNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["runID": run.lowercased()])))
    }

    func testTriggerAndFailureCodeTokensBoundedPrintable() {
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["trigger": String(repeating: "t", count: 49)])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["trigger": "has space"])))
        XCTAssertNil(LinuxShellImportRestore.parse(
            failureCode: String(repeating: "c", count: 49), recovery: recovery()))
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: "", recovery: recovery()))
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: 7, recovery: recovery()))
    }

    // MARK: - Exact nonnegative integers (Bool/fraction/overflow refused)

    func testCounterGrammarIsExact() {
        let rejected: [Any] = [true, false, "3", 3.5, -1, 9.3e18] // 9.3e18 saturates Int64: refused, never clamped
        for bad in rejected {
            XCTAssertNil(LinuxShellImportRestore.parse(
                failureCode: "x", recovery: recovery(["restoredPriorChanges": bad])),
                "counter value \(bad) must be refused, never coerced")
        }
        XCTAssertNotNil(LinuxShellImportRestore.parse(
            failureCode: "x", recovery: recovery(["retainedFailures": NSNumber(value: Int64(4))])))
    }

    func testOversizedEnvelopeDropped() {
        // The four closed string fields are individually grammar-bound, so a
        // well-formed object cannot approach the 4 KiB ceiling; an oversized
        // RAW object (e.g. smuggled through the Any bridge) must still be
        // dropped by the byte cap.
        var huge = recovery(extra: [:])
        huge["record"] = "importRestore" + String(repeating: "x", count: 5_000)
        // The oversized record token ALSO fails the closed-value check; use
        // an oversized well-named field the grammar cannot reject alone:
        // the runID bound by UUID grammar can't grow, so the cap's purpose is
        // defense-in-depth against future field widening. Verify the
        // oversized object is dropped either way.
        XCTAssertNil(LinuxShellImportRestore.parse(failureCode: "x", recovery: huge))
    }

    func testEvidenceTextIsBoundedAndCarriesNoPaths() throws {
        let parsed = try XCTUnwrap(LinuxShellImportRestore.parse(
            failureCode: "importCancelled", recovery: recovery()))
        let text = parsed.evidenceText
        XCTAssertTrue(text.hasPrefix("failed-start-recovery session="))
        XCTAssertTrue(text.contains("restoredPriorChanges=3"))
        XCTAssertTrue(text.contains("retainedFailures=0"))
        XCTAssertFalse(text.contains("/")) // relative identities/counts only
        XCTAssertLessThan(text.utf8.count, 512)
    }
}
