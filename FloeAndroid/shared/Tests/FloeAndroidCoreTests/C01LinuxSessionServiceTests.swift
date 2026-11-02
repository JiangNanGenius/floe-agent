// SPDX-License-Identifier: MPL-2.0
//
// C01 focused ownership regressions (authored, not executed by this job).
//
// These pin the source-level contracts that are easy to regress while wiring
// model sessions and managed services: a model session cannot run without the
// facade receipt, a sibling/model client cannot close or exchange a manual UI
// session, and the managed-service declaration refuses paths/ports it must not
// own. No engine, runtime component, provider, device or port listener is used.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools
@testable import FloeAndroidJobTools
@testable import FloeAndroidCore

private actor C01FakeSessionBackend: LocalShellBackend {
    private(set) var opens = 0
    private(set) var closes: [String] = []
    private var live: Set<String> = []

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        .failed(message: "not used in this test")
    }

    func openSession(_ request: ShellOpenRequest,
                     cancellation: CancellationToken?) async throws -> ShellOpenResult {
        opens += 1
        live.insert(request.sessionID)
        return ShellOpenResult(sessionID: request.sessionID, initialOutput: "",
                               alive: true, environmentID: "env-test")
    }

    func exchangeSession(_ request: ShellExchangeRequest,
                         cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard live.contains(request.sessionID) else {
            throw FloeError.notFound("unknown")
        }
        return ShellExchangeResult(output: "", alive: true, cancelled: false,
                                   bytesRead: 0, bytesWritten: 0)
    }

    func closeSession(sessionID: String) async {
        closes.append(sessionID)
        live.remove(sessionID)
    }

    func signalSession(sessionID: String, signal: ShellSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
    func requestStopForSettlement(sessionID: String) async {}
    func runReportingPhases(_ request: ShellRunRequest,
                            cancellation: CancellationToken?) async -> ShellRunReport {
        ShellRunReport(outcome: .failed(message: "not used"), phaseTimings: nil)
    }
}

private func c01Context(runID: UUID, conversationID: UUID = UUID(),
                        roleClient: String?) -> ToolContext {
    ToolContext(runID: runID,
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                cancellation: CancellationToken(),
                conversationID: conversationID,
                clientSessionID: roleClient)
}

private func c01Ownership() -> LinuxShellSessionOwnership {
    LinuxShellSessionOwnership { _ in }
}

private struct C01FakeEnvironmentHost: C01LinuxEnvironmentHosting {
    var snapshot: C01LinuxEnvironmentSnapshot
    func status(environmentID: String?) async -> C01LinuxEnvironmentSnapshot { snapshot }
    func start(environmentID: String?, cancellation: CancellationToken) async -> C01LinuxEnvironmentSnapshot { snapshot }
    func stop(environmentID: String?, cancellation: CancellationToken) async -> C01LinuxEnvironmentSnapshot { snapshot }
}

final class C01LinuxSessionServiceTests: XCTestCase {
    func testModelSessionRefusalPreventsAnyEngineDispatch() async throws {
        let backend = C01FakeSessionBackend()
        let center = ShellSessionCenter(backend: backend,
                                        ownershipHook: { _ in nil })
        let context = c01Context(runID: UUID(), roleClient: "run:model")
        do {
            _ = try await center.open(command: "", cwd: ".", environment: [:],
                                      columns: 80, rows: 24, runID: context.runID,
                                      rootURL: try XCTUnwrap(context.workspaceRootURL),
                                      cancellation: nil,
                                      ownershipContext: context)
            XCTFail("a refused ownership receipt must prevent shell.start")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("not admitted"), "\(error)")
        }
        let opens = await backend.opens
        XCTAssertEqual(opens, 0)
    }

    func testUiSessionDoesNotNeedTheModelOwnershipHook() async throws {
        let backend = C01FakeSessionBackend()
        let center = ShellSessionCenter(backend: backend,
                                        ownershipHook: { _ in nil })
        let uiRun = UUID()
        let opened = try await center.open(command: "", cwd: ".", environment: [:],
                                           columns: 80, rows: 24, runID: uiRun,
                                           rootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                                           cancellation: nil,
                                           clientSessionID: nil,
                                           forTerminal: true)
        XCTAssertTrue(opened.alive)
        let opens = await backend.opens
        XCTAssertEqual(opens, 1)
    }

    func testModelClientCannotExchangeOrCloseAManualTab() async throws {
        let backend = C01FakeSessionBackend()
        let center = ShellSessionCenter(backend: backend,
                                        ownershipHook: { _ in c01Ownership() })
        let uiRun = UUID()
        let manual = try await center.open(command: "", cwd: ".", environment: [:],
                                           columns: 80, rows: 24, runID: uiRun,
                                           rootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                                           cancellation: nil,
                                           clientSessionID: nil,
                                           forTerminal: true)
        let modelRun = UUID()
        let context = c01Context(runID: modelRun, roleClient: "run:model")
        do {
            _ = try await center.exchange(sessionID: manual.sessionID, input: "x\n",
                                          waitMs: 100, maxBytes: 100,
                                          runID: modelRun, cancellation: nil,
                                          clientSessionID: "run:model")
            XCTFail("a different run must not exchange a manual UI tab")
        } catch {
            // Expected: the center's run/client ownership check refused it.
        }
        let closeOutcome = await center.close(sessionID: manual.sessionID,
                                              runID: modelRun,
                                              clientSessionID: "run:model")
        XCTAssertEqual(closeOutcome, .notFound)
        let stillLive = await center.activeSessionIDs(runID: uiRun)
        XCTAssertTrue(stillLive.contains(manual.sessionID),
                      "the model close attempt must not touch the manual tab")
        // A model-owned session opened with its own context remains reachable
        // only through the same model run/client.
        let modelSession = try await center.open(command: "", cwd: ".", environment: [:],
                                                 columns: 80, rows: 24, runID: modelRun,
                                                 rootURL: try XCTUnwrap(context.workspaceRootURL),
                                                 cancellation: nil,
                                                 clientSessionID: "run:model",
                                                 ownershipContext: context)
        let wrongClient = await center.close(sessionID: modelSession.sessionID,
                                             runID: modelRun,
                                             clientSessionID: "child:other")
        XCTAssertEqual(wrongClient, .ownerMismatch)
    }

    func testServiceDeclarationRefusesForeignPathsAndPorts() throws {
        XCTAssertThrowsError(try C01ManagedServiceDeclaration(
            runtime: .node, entry: "../server.js", port: 8080).validateForJobSubmit())
        XCTAssertThrowsError(try C01ManagedServiceDeclaration(
            runtime: .node, entry: "/etc/passwd", port: 8080).validateForJobSubmit())
        XCTAssertThrowsError(try C01ManagedServiceDeclaration(
            runtime: .python, entry: "server.py", port: 80).validateForJobSubmit())
        XCTAssertThrowsError(try C01ManagedServiceDeclaration(
            runtime: .shell, entry: "server.sh", port: 65_536).validateForJobSubmit())
        XCTAssertNoThrow(try C01ManagedServiceDeclaration(
            runtime: .node, entry: "server.js", port: 8080).validateForJobSubmit())
    }

    func testServicePayloadKeepsTheTypedObjectAndRejectsASecondCommand() throws {
        let declaration = C01ManagedServiceDeclaration(
            runtime: .python, entry: "server.py", arguments: ["--port", "8080"],
            cwd: "web", port: 8080)
        let payload = try C01ManagedServicePayload.combine(
            innerArguments: Data(#"{"cwd":"web"}"#.utf8), declaration: declaration,
            acceptedEpoch: 7)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertNotNil(object["service"] as? [String: Any])
        XCTAssertNotNil(object["command"] as? String)
        XCTAssertThrowsError(try C01ManagedServicePayload.combine(
            innerArguments: Data(#"{"command":"curl evil"}"#.utf8), declaration: declaration,
            acceptedEpoch: 7))
    }

    func testServiceCommandQuotesEveryArgumentAndBoundedTailKeepsUTF8() {
        let declaration = C01ManagedServiceDeclaration(
            runtime: .shell, entry: "my script.sh",
            arguments: ["a'b", "$(touch /tmp/x)"], cwd: nil, port: 8080)
        let command = C01ManagedServiceDomain.command(declaration)
        XCTAssertTrue(command.hasPrefix("sh 'my script.sh'"), command)
        XCTAssertTrue(command.contains("'a'\\''b'"), command)
        XCTAssertTrue(command.contains("'$(touch /tmp/x)'"),
                      "model text must remain a single quoted argument: \(command)")
        let tail = C01ManagedServiceDomain.boundedTail("你好世界", cap: 5)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertNotNil(tail.data(using: .utf8), "the bounded tail must remain valid UTF-8")
    }
    func testEnvironmentStatusRendersInstallRequiredWithoutFakeReady() async throws {
        let host = C01FakeEnvironmentHost(snapshot: C01LinuxEnvironmentSnapshot(
            phase: .installRequired, environmentID: "env-1", componentMatches: true,
            installed: false, installRequired: true, retryable: true,
            detail: "Open Settings > Local Linux runtime"))
        C01LinuxEnvironmentDomain.shared.install(host, epoch: 5)
        defer { C01LinuxEnvironmentDomain.shared.install(nil, epoch: 0) }
        let output = try await C01LinuxEnvironmentStatusTool().execute(
            .init(), context: c01Context(runID: UUID(), roleClient: nil))
        XCTAssertEqual(output.exitStatus, 75)
        XCTAssertTrue(output.summary.contains("phase=installRequired"), output.summary)
        XCTAssertTrue(output.summary.contains("installed=false"), output.summary)
        XCTAssertFalse(output.summary.contains("phase=ready"), output.summary)
    }
}
