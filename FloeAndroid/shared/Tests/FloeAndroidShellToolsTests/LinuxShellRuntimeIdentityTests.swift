// SPDX-License-Identifier: MPL-2.0
//
// G07.3A live-files identity regression (sessionwire13 PRIVATE patch).
//
// The retained live-files failure was an identity mix-up: `ShellOpenResult`
// only exposed the Center's CLIENT session UUID, while the runtime pump
// resolves live files by the ENGINE lease id echoed by the real `shell.start`.
// These assertions pin the explicit transfer: the Center keeps its client key
// for every terminal action, and carries the engine lease id separately for
// live files only. A backend that never observed a start reply has no engine
// echo, so live files must refuse rather than address the client token.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellRuntimeIdentityTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-live-identity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCenterKeepsClientTokenAndCarriesTheEngineLeaseID() async throws {
        let transport = FakeLinuxShellTransport()
        transport.startReply = { _ in
            LinuxShellStartReply(sessionID: "engine-lease-1", environmentID: "env-1",
                                 runtimeGeneration: "gen-1", workspaceOwner: true)
        }
        transport.pollScript = { session, cursor, nth in
            if nth == 1 {
                return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "$ ")
            }
            return nil
        }
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000, releaseGrace: 0.2,
                stdinWriteRetries: 8, reconcileIntervalNanos: 5_000_000,
                reconcileObservation: 30))
        let center = ShellSessionCenter(backend: backend)
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let conversation = UUID()
        let opened = try await center.open(
            command: "", cwd: ".", environment: [:], columns: 80, rows: 24,
            runID: runID, rootURL: root, cancellation: nil, forTerminal: true,
            clientSessionID: nil, conversationID: conversation)
        let start = try XCTUnwrap(transport.starts.first)
        XCTAssertEqual(start.runID, runID,
                       "the start carries the trusted run identity")
        XCTAssertEqual(start.conversationID, conversation,
                       "the start carries the trusted conversation identity")
        XCTAssertNotEqual(opened.sessionID, "engine-lease-1",
                          "the client token must never be the engine lease id")
        XCTAssertEqual(opened.runtimeSessionID, "engine-lease-1",
                       "live files must address the actual engine lease id")
        XCTAssertEqual(opened.runtimeGeneration, "gen-1")
        _ = await center.close(sessionID: opened.sessionID, runID: runID)
    }

    func testLegacyOpenWithoutAnObservedStartHasNoLiveIdentity() {
        // No real start reply -> no engine echo. The domain must refuse live
        // files (empty runtimeSessionID) instead of silently sending the
        // client token, which the pump would refuse.
        let result = ShellOpenResult(sessionID: "client-token", initialOutput: "", alive: true)
        XCTAssertNil(result.runtimeSessionID)
    }
}
