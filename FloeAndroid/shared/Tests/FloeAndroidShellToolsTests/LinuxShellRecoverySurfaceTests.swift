// SPDX-License-Identifier: MPL-2.0
// Focused regressions for surfacing the OPTIONAL per-execution recovery
// evidence on ORDINARY successful exec.shell results (job-5b987a08b1df40b2,
// Main acceptance steer: the real digest-CAS case is third-import
// swappedPreserved + export synced; success must still carry the bounded
// both-revision evidence through the EXISTING labelled backend-metadata
// stderr channel, with FULL measured SHA-256 values, no fabricated failure
// and no new reader). Author-written against the 951f2f68/bacbaf91 baseline
// for FloeAndroidShellToolsTests. NOT executed by this lane (Main owns the
// Swift 6 object compile).
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellRecoverySurfaceTests: XCTestCase {
    private static let key32 = String(repeating: "a", count: 32)
    private static let dE64 = String(repeating: "e", count: 64)
    private static let dF64 = String(repeating: "f", count: 64)

    private func recovery(preserved: Int, entries: Int) -> LinuxShellWorkspaceRecovery? {
        let entryList = (0..<entries).map { index in
            """
            {"path":"r3cas/f\(index).txt","action":"swappedPreserved",
             "preservedSha256":"\(Self.dE64)","preservedBytes":30,
             "installedBaselineSha256":"\(Self.dF64)","installedBaselineBytes":27}
            """
        }.joined(separator: ",")
        let entryJSON = entries > 0 ? "[\(entryList)]" : "[]"
        let text = """
        {"sessionKey":"\(Self.key32)",
         "runID":"A1B2C3D4-0000-4000-9000-000000000006",
         "import":{"outcome":"\(preserved > 0 ? "swappedPreserved" : "clean")",
                   "created":0,"replacedSynced":1,"preservedUnsynced":\(preserved),
                   "unchanged":2,"appliedBytes":57,"preserved":\(entryJSON)},
         "export":{"result":"synced","source":"core-export-finish"}}
        """
        let data = text.data(using: .utf8)!
        return LinuxShellWorkspaceRecovery.parse(try! JSONSerialization.jsonObject(with: data))
    }

    private func makeBackend(_ transport: FakeLinuxShellTransport) -> AndroidLinuxShellBackend {
        AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000, releaseGrace: 0.2, stdinWriteRetries: 8,
                reconcileIntervalNanos: 5_000_000, reconcileObservation: 30))
    }

    private func runRequest(root: URL) -> ShellRunRequest {
        ShellRunRequest(command: "cat r3cas/marker.txt", cwd: ".", rootURL: root,
                        environment: [:], stdin: nil, timeout: 1, gateTimeout: 0.5,
                        maxOutputBytes: 64 * 1024, sessionID: "run:unit-test:recovery-1",
                        runID: UUID(), toolEnvironment: nil, conversationID: nil)
    }

    /// The intended REAL CAS success: preserved diverged bytes + synced
    /// export => ordinary .exited result whose labelled metadata stderr
    /// carries BOTH full measured SHA-256 revisions.
    func testSyncedSuccessWithPreservedCopiesSurfacesFullDigestEvidence() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        let evidence = try XCTUnwrap(recovery(preserved: 1, entries: 1))
        transport.pollScript = { session, cursor, _ in
            var page = FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "R3_FCR_V2_REPLACED",
                                                    state: .terminated, released: true, exit: 0,
                                                    workspaceStatus: "synced")
            page.workspaceRecovery = evidence
            return page
        }
        let outcome = await makeBackend(transport).run(runRequest(root: root), cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("synced success must stay .exited, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "R3_FCR_V2_REPLACED", "engine bytes are never polluted by metadata")
        XCTAssertTrue(stderr.contains("[recovery-evidence]"), stderr)
        XCTAssertTrue(stderr.contains(Self.dE64), "unsaved revision digest must be FULL")
        XCTAssertTrue(stderr.contains(Self.dF64), "installed baseline revision digest must be FULL")
        XCTAssertTrue(stderr.contains("r3cas/f0.txt"))
        XCTAssertFalse(stderr.contains("…"), "no digest ellipsis anywhere")
    }

    /// A clean synced turn shows NO recovery noise (legacy-identical).
    func testCleanSyncedSuccessStaysQuiet() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        let evidence = try XCTUnwrap(recovery(preserved: 0, entries: 0))
        transport.pollScript = { session, cursor, _ in
            var page = FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "ok",
                                                    state: .terminated, released: true, exit: 0,
                                                    workspaceStatus: "synced")
            page.workspaceRecovery = evidence
            return page
        }
        let outcome = await makeBackend(transport).run(runRequest(root: root), cancellation: nil)
        guard case .exited(_, _, let stderr, _, _, _) = outcome else { return XCTFail("exited expected") }
        XCTAssertFalse(stderr.contains("[recovery-evidence]"), stderr)
    }

    /// Absent metadata (legacy runtime) keeps the result byte-identical.
    func testLegacySuccessWithoutMetadataIsUntouched() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "legacy output",
                                         state: .terminated, released: true, exit: 0,
                                         workspaceStatus: "synced")
        }
        let outcome = await makeBackend(transport).run(runRequest(root: root), cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("exited expected, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout, "legacy output")
        XCTAssertFalse(stderr.contains("recovery"), stderr)
    }

    /// Over-budget entry lists drop WHOLE lines with an honest note; every
    /// displayed digest stays complete (never 16-char ellipsis truncation).
    func testEvidenceTruncatesWholeLinesNotDigests() throws {
        let evidence = try XCTUnwrap(recovery(preserved: 16, entries: 16))
        let text = try XCTUnwrap(evidence.evidenceText)
        XCTAssertLessThanOrEqual(text.utf8.count, 2_560)
        XCTAssertFalse(text.contains("…"), "digests are never ellipsized")
        let displayed = text.components(separatedBy: "\n").filter { $0.hasPrefix("preserved:") }
        XCTAssertLessThan(displayed.count, 16, "the size cap must drop whole entries first")
        for line in displayed {
            XCTAssertTrue(line.contains(Self.dE64) && line.contains(Self.dF64), line)
        }
        XCTAssertTrue(text.contains("omitted for size"), text)
    }
}
