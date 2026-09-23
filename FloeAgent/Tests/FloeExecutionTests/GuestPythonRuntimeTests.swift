// FloeExecutionTests — guest Python routing (Phase 2 migration).
//
// These focused cases carry over the behavior that the retired native-runtime
// app tests guarded, now against the TinyEMU routing layer with a scripted
// guest (real-guest execution is the engine worker's TinyEMU qualification,
// not a host unit test):
//
//   retired app test                         -> mapped here / elsewhere
//   LocalPythonRuntimeTests (all)            -> routing, stdin, cancellation,
//                                               result markers, containment;
//                                               real guest: TinyEMU qualification
//   LocalShellRuntimeTests piped input &     -> testStandardInputAndArgumentsReachTheGuest
//   live input/cancellation                  -> testCancellationCancelsGuestRun
//   LocalServiceLifecycleTests service stop  -> LinuxGuestLocalServiceSupervisorTests
//                                               (same file's supervisor cases)
//   batchWorkflow/httpsThroughCurl…          -> TinyEMU qualification (real guest)

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

/// Scripted guest: records argv, answers provisioning, maps one workspace
/// share, and can play the controller for lazy-activation checks.
private final class ScriptedGuest: LinuxCommandRunning, LinuxGuestPathMapping, LinuxGuestControlling, @unchecked Sendable {
    struct Call: Sendable {
        var argv: [String]
        var workingDirectory: String?
        var standardInput: String?
        var joined: String { argv.joined(separator: " ") }
    }

    var owns = true
    var running = true
    private(set) var startCalls = 0
    var handler: ([String]) -> LinuxCommandResult = { _ in LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
    var pathMap: LinuxGuestPathMap?

    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }

    func supports(environmentID: String) async -> Bool { running }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { owns }
    func linuxGuestPathMap(environmentID: String) async -> LinuxGuestPathMap? { pathMap }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        lock.withLock { recorded.append(Call(argv: argv, workingDirectory: workingDirectory, standardInput: standardInput)) }
        return handler(argv)
    }

    // LinuxGuestControlling (only what the activator touches is live)
    var startHook: (() throws -> Bool)?
    func startGuest(environmentID: String, taskID: String?) async throws -> Bool {
        startCalls += 1
        if let hook = startHook { return try hook() }
        running = true
        return true
    }
    func stopGuest(environmentID: String) async { running = false }
    func resetGuest(environmentID: String) async { running = false }
    func deleteGuest(environmentID: String) async { running = false }
    func guestIsRunning(environmentID: String) async -> Bool { running }
    func guestStatus(environmentID: String) async -> LinuxGuestStatus {
        LinuxGuestStatus(environmentID: environmentID, running: running)
    }
    func stopGuests(taskID: String) async {}
    func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {}
    func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {}
    func openSession(environmentID: String, sessionID: String, argv: [String], workingDirectory: String?, columns: Int, rows: Int) async throws {}
    func readSession(sessionID: String, maxBytes: Int, waitMs: Int) async -> (output: Data, info: LinuxGuestSessionInfo)? { nil }
    func writeSession(sessionID: String, text: String) async throws {}
    func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
    func closeSession(sessionID: String) async {}
    func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? { nil }
}

final class GuestPythonRuntimeTests: XCTestCase {
    /// Answers the shared-venv provisioner so no apt/venv creation runs.
    private static func provisioned(_ guest: ScriptedGuest) {
        guest.handler = { argv in
            let joined = argv.joined(separator: " ")
            if joined.contains("sysconfig.get_paths") {
                return LinuxCommandResult(stdout: "/floe/env/python/venv/lib/python3.13/site-packages\n", stderr: "", exitCode: 0)
            }
            if joined.contains("bin/pip") {
                return LinuxCommandResult(stdout: "pip-ok\n", stderr: "", exitCode: 0)
            }
            if argv.contains("--version") {
                return LinuxCommandResult(stdout: "Python 3.13.5\n", stderr: "", exitCode: 0)
            }
            return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private func makePathMap() throws -> (LinuxGuestPathMap, URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-py-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let layer = workspace.appendingPathComponent("layer", isDirectory: true)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer),
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)
        ])
        return (map, workspace)
    }

    func testScriptRunsInSharedVenvWithMappedCwdAndResultMarker() async throws {
        let guest = ScriptedGuest()
        let (map, workspace) = try makePathMap()
        defer { try? FileManager.default.removeItem(at: workspace) }
        guest.pathMap = map
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        Self.provisioned(guest)
        let outcome = await GuestPythonRuntime.run(
            ScriptExecutionRequest(
                script: "print('hi')",
                timeout: 10,
                maxOutputBytes: 4096,
                pythonContext: .init(
                    environmentID: environmentID,
                    workingDirectory: workspace.path,
                    environment: [
                        "HOME": "/private/var/host-home-should-not-cross",
                        "MY_FLAG": "kept",
                        "ESCAPED": "/etc/passwd"
                    ],
                    arguments: ["a", "b"]
                )
            ),
            environmentID: environmentID,
            guests: guest,
            controller: guest,
            cancellation: nil
        )
        guard case .ok = outcome else { return XCTFail("run failed: \(outcome)") }
        let run = try XCTUnwrap(guest.calls.last)
        // The shared venv interpreter runs the script with the caller's argv.
        XCTAssertTrue(run.argv.contains("/floe/env/python/venv/bin/python3"), run.joined)
        XCTAssertTrue(run.argv.contains("-c"))
        XCTAssertEqual(run.argv.suffix(2), ["a", "b"])
        // cwd mapped into the workspace share, never a host path.
        XCTAssertEqual(run.workingDirectory, "/workspace")
        // printJSON prelude is present; host paths and host-owned keys are not.
        let script = run.argv[run.argv.firstIndex(of: "-c")! + 1]
        XCTAssertTrue(script.contains("printJSON"))
        XCTAssertFalse(run.joined.contains("/private/var/host-home-should-not-cross"), run.joined)
        XCTAssertFalse(run.joined.contains("ESCAPED="), run.joined)
        XCTAssertTrue(run.joined.contains("MY_FLAG=kept"), run.joined)
        XCTAssertTrue(run.joined.contains("VIRTUAL_ENV=/floe/env/python/venv"), run.joined)
        XCTAssertTrue(run.joined.contains("HOME=/floe/env/home"), run.joined)
    }

    func testResultMarkerBecomesResultJSONAndLeavesStdout() async throws {
        let guest = ScriptedGuest()
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        Self.provisioned(guest)
        let base = guest.handler
        guest.handler = { argv in
            let joined = argv.joined(separator: " ")
            // Only the real user script carries the printJSON prelude. The
            // provisioner's sysconfig/pip/--version probes must keep falling
            // through to `base`, otherwise the shared venv cannot be detected.
            if joined.contains("python3"), joined.contains("-c"), joined.contains("printJSON") {
                return LinuxCommandResult(
                    stdout: "before\n\u{1e}FLOE-RESULT {\"floeShellExitCode\": 7}\nafter\n",
                    stderr: "", exitCode: 0
                )
            }
            return base(argv)
        }
        let outcome = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "pass", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: environmentID)),
            environmentID: environmentID, guests: guest, controller: guest, cancellation: nil
        )
        guard case .ok(let resultJSON, let stdout, _, _, _, _) = outcome else {
            return XCTFail("run failed: \(outcome)")
        }
        XCTAssertEqual(resultJSON, "{\"floeShellExitCode\": 7}")
        XCTAssertEqual(stdout, "before\nafter")
    }

    func testStandardInputAndArgumentsReachTheGuest() async throws {
        let guest = ScriptedGuest()
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        Self.provisioned(guest)
        _ = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "pass", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: environmentID, standardInput: "piped-bytes")),
            environmentID: environmentID, guests: guest, controller: guest, cancellation: nil
        )
        XCTAssertEqual(guest.calls.last?.standardInput, "piped-bytes")
    }

    func testCancellationCancelsGuestRun() async throws {
        let guest = ScriptedGuest()
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        Self.provisioned(guest)
        let token = CancellationToken()
        let base = guest.handler
        guest.handler = { argv in base(argv) }
        // Cancel before the run starts: the runtime must answer cancelled
        // without executing anything.
        token.cancel()
        let outcome = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "pass", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: environmentID)),
            environmentID: environmentID, guests: guest, controller: guest, cancellation: token
        )
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(guest.calls.contains { $0.argv.contains("-c") })
    }

    func testNonOwnedEnvironmentFailsHonestlyAndNeverRuns() async throws {
        let guest = ScriptedGuest()
        guest.owns = false
        let outcome = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "pass", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: "native-env")),
            environmentID: "native-env", guests: guest, controller: guest, cancellation: nil
        )
        guard case .jsException(let message, _) = outcome else {
            return XCTFail("a native environment must not execute: \(outcome)")
        }
        XCTAssertTrue(message.contains("Linux"), message)
        XCTAssertTrue(guest.calls.isEmpty)
    }

    func testStoppedGuestIsStartedOnDemand() async throws {
        let guest = ScriptedGuest()
        guest.running = false
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        Self.provisioned(guest)
        _ = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "pass", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: environmentID)),
            environmentID: environmentID, guests: guest, controller: guest, cancellation: nil
        )
        XCTAssertEqual(guest.startCalls, 1)
        XCTAssertTrue(guest.calls.contains { $0.argv.contains("-c") })
    }

    func testWorkingDirectoryOutsideSharesIsRejected() async throws {
        let guest = ScriptedGuest()
        let (map, workspace) = try makePathMap()
        defer { try? FileManager.default.removeItem(at: workspace) }
        guest.pathMap = map
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        Self.provisioned(guest)
        let outcome = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "pass", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: environmentID, workingDirectory: "/usr")),
            environmentID: environmentID, guests: guest, controller: guest, cancellation: nil
        )
        guard case .jsException(let message, _) = outcome else {
            return XCTFail("an unmappable cwd must not execute: \(outcome)")
        }
        XCTAssertTrue(message.contains("shared folders"), message)
        XCTAssertFalse(guest.calls.contains { $0.argv.contains("-c") })
    }

    /// First Linux use on an uninstalled/unqualified image must invoke the
    /// shared preparation handler once, then resume the original action —
    /// the model never has to discover environment.prepareLinux itself.
    func testMissingImageInvokesPreparationThenResumes() async throws {
        let guest = ScriptedGuest()
        guest.running = false
        var firstStart = true
        var prepareCalls = 0
        guest.startHook = {
            if firstStart {
                firstStart = false
                throw LinuxGuestError.imageNotQualified(
                    environmentID: "env-prep",
                    reason: "image not installed"
                )
            }
            guest.running = true
            return true
        }
        Self.provisioned(guest)
        let environmentID = "env-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        let prepareBox = Counter()
        let prepare: LinuxPreparationHandler = { _ in
            prepareBox.increment()
            return "prepared"
        }
        let outcome = await GuestPythonRuntime.run(
            ScriptExecutionRequest(script: "1+1", timeout: 10, maxOutputBytes: 4096,
                                   pythonContext: .init(environmentID: environmentID)),
            environmentID: environmentID, guests: guest, controller: guest,
            prepareLinux: prepare, cancellation: nil
        )
        guard case .ok = outcome else {
            return XCTFail("expected the command to run after preparation, got \(outcome)")
        }
        XCTAssertEqual(prepareBox.value, 1, "missing image must trigger exactly one preparation")
        XCTAssertEqual(guest.startCalls, 2, "activation retries once after preparation")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
