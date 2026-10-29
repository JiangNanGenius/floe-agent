// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeCore
@testable import FloeAndroidCore

/// Host regressions for the narrow Android qualification seam added by
/// job-f86ae143808f47b5: corpus pinning, fail-closed rejection, the public
/// handle surface, and BOTH smoke routines executed end-to-end on macOS so
/// the device run exercises the same already-validated code path.
/// Synthetic data only; the corpus is the exact upstream public resource.
final class QualificationSeamTests: XCTestCase {
    private func corpusData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/FloeSecurity/Resources/"
                                    + "catastrophic-patterns.json")
            .standardizedFileURL
        return try Data(floeContentsOf: url)
    }

    private func smokeJSON(_ pointer: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let pointer else { return ["ok": false, "error": "nullResponse"] }
        let data = Data(bytes: pointer, count: strlen(pointer))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["ok": false]
    }

    func testVerifiedCorpusLoadsGateAndStaysPrecise() throws {
        let gate = try AndroidCatastrophicCorpus.makeGate(from: try corpusData())
        let stopped = gate.evaluate(command: "rm -rf / --no-preserve-root")
        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.matchedPatternID, "rm-rf-root")
        XCTAssertFalse(gate.evaluate(command: "ls -la").stopped,
                       "trusted corpus must not be a match-everything gate")
    }

    private func tampered(_ corpus: Data) -> Data {
        var copy = corpus
        let last = copy.index(before: copy.endIndex)
        let value = Int(copy[last])
        copy[last] = UInt8(truncatingIfNeeded: value &+ 0x41)
        return copy
    }

    func testUntrustedOrDamagedCorpusIsNeverAccepted() throws {
        let corpus = try corpusData()
        XCTAssertThrowsError(try AndroidCatastrophicCorpus.makeGate(from: Data()))
        let truncated = Data(corpus.dropLast(16))
        XCTAssertThrowsError(try AndroidCatastrophicCorpus.makeGate(from: truncated))
        XCTAssertThrowsError(try AndroidCatastrophicCorpus.makeGate(from: tampered(corpus)))
        // Structurally valid, semantically identical, byte-different JSON is
        // still untrusted content: the hash pin must reject it.
        let object = try JSONSerialization.jsonObject(with: corpus)
        let reencoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        XCTAssertThrowsError(try AndroidCatastrophicCorpus.makeGate(from: reencoded))
    }

    func testLoadFailClosedKeepsTheGate() throws {
        let corpus = try corpusData()
        let damaged = tampered(corpus)
        for rejected: Data? in [nil, damaged, Data()] {
            let gate = AndroidCatastrophicCorpus.loadFailClosed(from: rejected)
            let verdict = gate.evaluate(command: "ls -la")
            XCTAssertTrue(verdict.stopped, "missing/corrupt corpus must fail closed")
            XCTAssertEqual(verdict.matchedPatternID, "gate-unavailable")
        }
    }

    func testCHandleSurface() throws {
        let corpus = try corpusData()
        let handle = corpus.withUnsafeBytes { raw in
            floeGateCreateFromCorpus(raw.bindMemory(to: UInt8.self).baseAddress, corpus.count)
        }
        XCTAssertNotNil(handle)
        if let handle {
            let verdict = smokeJSON(floeGateEvaluate(handle, "rm -rf /"))
            XCTAssertEqual(verdict["stopped"] as? Bool, true)
            XCTAssertEqual(verdict["matchedPatternID"] as? String, "rm-rf-root")
            floeGateRelease(handle)
        }
        let rejected: UnsafeMutableRawPointer? = corpus.withUnsafeBytes { raw in
            var bytes = [UInt8](raw)
            bytes[bytes.count - 2] ^= 0x41
            return floeGateCreateFromCorpus(bytes, bytes.count)
        }
        XCTAssertNil(rejected)
        let invalid = smokeJSON(floeGateEvaluate(nil, "ls -la"))
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        XCTAssertEqual(invalid["error"] as? String, "invalidHandle")
    }

    func testDatabaseSmokeRunsCleanlyOnHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-seam-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = smokeJSON(floeDbSmoke(directory.path))
        let failures = (report["failures"] as? [String]) ?? []
        XCTAssertEqual(report["ok"] as? Bool, true, "db smoke failures: \(failures)")
        XCTAssertEqual(report["schemaVersion"] as? Int, 48)
        XCTAssertEqual(report["appliedMigrationCount"] as? Int, 48)
        XCTAssertEqual(report["appliedContainsV47"] as? Bool, true)
        XCTAssertEqual(report["ftsEnglishHits"] as? Int, 1)
        XCTAssertEqual(report["ftsCjkSubstringHits"] as? Int, 0)
        XCTAssertEqual(report["ftsWholeRunPhraseHits"] as? Int, 1)
        XCTAssertEqual(report["ftsWildcardHits"] as? Int, 1)
        XCTAssertEqual(report["runEventSequences"] as? [Int], [1, 2, 3])
        XCTAssertEqual(report["snapshotGetCode"] as? Int, 0)
        XCTAssertEqual(report["snapshotCmpEqualSnapshots"] as? Int, 0)
        XCTAssertEqual(report["snapshotOpenCode"] as? Int, 0)
        XCTAssertEqual(report["durableReopenOK"] as? Bool, true)
        XCTAssertEqual(report["journalMode"] as? String, "wal")
        // The seam removes its own file database directory.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents.filter { $0.hasPrefix("floe-native-smoke-") }.isEmpty,
                      "smoke left its database behind: \(contents)")
    }

    func testJsonKindSmokeHoldsTheCanvasContractOnHost() throws {
        let report = smokeJSON(floeJsonKindSmoke())
        let failures = (report["failures"] as? [String]) ?? []
        XCTAssertEqual(report["ok"] as? Bool, true, "json-kind failures: \(failures)")
        XCTAssertEqual(report["foundationMappingContractHolds"] as? Bool, true)
        XCTAssertEqual(report["decoderMappingContractHolds"] as? Bool, true)
        XCTAssertEqual(report["decoderRoundTrip"] as? String, "[1,0,true,false,1.5]")
        // HOST (Darwin) observation recorded honestly: JSONSerialization
        // yields Foundation.__NSCFBoolean, whose Swift dynamic type is NOT
        // Bool.self but whose CF runtime type is CFBoolean. The shared CF
        // route maps it to .bool; Android executes the same branch and its
        // actual answer must still come from the device smoke.
        let values = (report["foundationValues"] as? [[String: Any]]) ?? []
        XCTAssertEqual(values.count, 7)
        XCTAssertEqual(values.first?["designCase"] as? String, "bool")
        XCTAssertEqual(report["narrowNumbersContractHolds"] as? Bool, true)
        XCTAssertEqual((report["narrowNumbers"] as? [[String: Any]])?.count, 14)
    }

    func testRunBoundedReturnsOnNormalCompletion() {
        XCTAssertEqual(runBounded(timeout: 5) { "done" }, "done")
    }

    /// The owned task is retained and CANCELLED on timeout (never discarded);
    /// the body observes cancellation at its next await boundary and still
    /// completes its bounded cleanup. Synchronous SQLite segments cannot be
    /// halted instantly and this test does not fake that.
    func testRunBoundedTimeoutCancelsOwnedTaskWithBoundedLateCompletion() throws {
        final class Observation: @unchecked Sendable {
            private let lock = NSLock()
            private var _completed = false
            private var _cancelled = false
            var completed: Bool { lock.withLock { _completed } }
            var cancelled: Bool { lock.withLock { _cancelled } }
            func finish(cancelled: Bool) { lock.withLock { _cancelled = cancelled; _completed = true } }
        }
        let box = Observation()
        let result = runBounded(timeout: 0.05) {
            var sawCancel = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { sawCancel = true; break }
            }
            box.finish(cancelled: sawCancel)
            return "late-result"
        }
        XCTAssertTrue(result.contains("qualification-smoke-timeout"), result)
        let deadline = Date().addingTimeInterval(3)
        while !box.completed && Date() < deadline { usleep(10_000) }
        XCTAssertTrue(box.completed, "the owned task never terminated after cancellation")
        XCTAssertTrue(box.cancelled, "cancellation was not observed at the next await boundary")
    }

    func testExportedAPKAssetIsTheExactPinnedCorpus() throws {
        let asset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/FloeAndroidCoreTests
            .appendingPathComponent("../../../core/swiftbridge/src/main/assets/security/"
                                    + "catastrophic-patterns.json")
            .standardizedFileURL
        // Produced by build-swift.sh; absent only in a never-built checkout.
        guard FileManager.default.fileExists(atPath: asset.path) else {
            throw XCTSkip("exported corpus asset not present yet; run build-swift.sh")
        }
        let data = try Data(floeContentsOf: asset)
        XCTAssertEqual(data, try corpusData(), "asset drifted from the upstream resource")
        // Byte-identical to the pinned resource; the seam's own hash check
        // (pinned constant above) then guards every runtime load.
        XCTAssertEqual(
            AndroidCatastrophicCorpus.pinnedSHA256,
            "b20667f2d9713961231327c931188cc74474cdbd294593c6071c804edf0c038b")
        _ = try AndroidCatastrophicCorpus.makeGate(from: data)
    }
}

