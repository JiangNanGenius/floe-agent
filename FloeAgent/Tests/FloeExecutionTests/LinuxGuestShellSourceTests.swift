#if os(macOS) || os(Linux)
import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

/// Real backend, source persistence, staging and sensitive carrier. The VM
/// runner/PTY endpoint is a test seam; POSIX exports run with /bin/sh on macOS.
private actor SourceShellRunner: LinuxCommandRunning, LinuxGuestControlling, LinuxGuestSensitiveEnvironmentDelivering {
    struct Call: Sendable {
        let command: String
        let argv: [String]
        let environmentID: String
        let sensitiveNames: [String]
        let staged: Bool
    }
    let workspace: URL
    let available: Bool
    let cancelRun: Bool
    var calls: [Call] = []
    var opens: [Call] = []
    var firstOutput = Data()
    init(workspace: URL, available: Bool = true, cancelRun: Bool = false) {
        self.workspace = workspace; self.available = available; self.cancelRun = cancelRun
    }
    func supports(environmentID: String) async -> Bool { available }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }
    func startGuest(environmentID: String, taskID: String?) async throws -> Bool {
        XCTFail("A shell source default must not start a guest")
        throw FloeError.invalidConfiguration("No VM in this shell seam")
    }
    func stopGuest(environmentID: String) async { XCTFail("Unexpected guest stop") }
    func resetGuest(environmentID: String) async { XCTFail("Unexpected guest reset") }
    func deleteGuest(environmentID: String) async { XCTFail("Unexpected guest deletion") }
    func guestIsRunning(environmentID: String) async -> Bool { available }
    func guestStatus(environmentID: String) async -> LinuxGuestStatus {
        LinuxGuestStatus(environmentID: environmentID, running: available)
    }
    func stopGuests(taskID: String) async { XCTFail("Unexpected guest stop") }
    func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        XCTFail("Unexpected guest forwarding")
    }
    func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        XCTFail("Unexpected forwarding removal")
    }
    private func capture(_ argv: [String], id: String) throws -> (Call, SensitiveProcessEnvironment?) {
        let sensitive = SensitiveProcessEnvironmentCarrier.pending?.consume()
        var command = argv[2]; var staged = false
        if command.hasPrefix(". '") && command.hasSuffix("'") {
            let guest = String(command.dropFirst(3).dropLast(1))
            command = try String(contentsOf: workspace.appendingPathComponent(String(guest.dropFirst("/workspace/".count))), encoding: .utf8)
            staged = true
        }
        return (Call(command: command, argv: argv, environmentID: id, sensitiveNames: sensitive?.names ?? [], staged: staged), sensitive)
    }
    private func execute(_ call: Call, sensitive: SensitiveProcessEnvironment?) throws -> LinuxCommandResult {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", call.command]
        var env = ["PATH": "/usr/bin:/bin", "PIP_INDEX_URL": "https://guest.example/simple/",
                   "PIP_EXTRA_INDEX_URL": "https://guest-extra.example/simple/", "PIP_TRUSTED_HOST": "guest.example"]
        for (name, value) in sensitive?.valuesByName ?? [:] { env[name] = value }
        process.environment = env; process.standardOutput = output; process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LinuxCommandResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: process.terminationStatus)
    }
    func run(environmentID: String, argv: [String], workingDirectory: String?, standardInput: String?,
             timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        try await run(environmentID: environmentID, argv: argv, workingDirectory: workingDirectory,
                      standardInput: standardInput, deadline: .seconds(timeout), maxOutputBytes: maxOutputBytes, cancellation: cancellation)
    }
    func run(environmentID: String, argv: [String], workingDirectory: String?, standardInput: String?,
             deadline: ShellExecutionDeadline, maxOutputBytes: Int, cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        let (call, sensitive) = try capture(argv, id: environmentID); calls.append(call)
        try cancellation?.throwIfCancelled()
        if cancelRun { throw FloeError.cancelled }
        return try execute(call, sensitive: sensitive)
    }
    func openSession(environmentID: String, sessionID: String, argv: [String], workingDirectory: String?, columns: Int, rows: Int) async throws {
        let (call, sensitive) = try capture(argv, id: environmentID); opens.append(call)
        if call.command.contains("exec bash --noprofile --norc -i") { firstOutput = Data() }
        else { firstOutput = Data(try execute(call, sensitive: sensitive).stdout.utf8) }
    }
    func readSession(sessionID: String, maxBytes: Int, waitMs: Int) async -> (output: Data, info: LinuxGuestSessionInfo)? {
        (firstOutput, LinuxGuestSessionInfo(sessionID: sessionID, alive: true))
    }
    func writeSession(sessionID: String, text: String) async throws {}
    func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
    func closeSession(sessionID: String) async {}
    func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? { nil }
}

final class LinuxGuestShellSourceTests: XCTestCase, @unchecked Sendable {
    private let selected = "https://pypi.tuna.tsinghua.edu.cn/simple/"
    private let probe = "printf '%s|%s|%s' \"$PIP_INDEX_URL\" \"$PIP_EXTRA_INDEX_URL\" \"$PIP_TRUSTED_HOST\""
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pypi-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func environment(_ root: URL, id: String = "chosen") -> ToolEnvironment {
        ToolEnvironment(id: id, writableLayerURL: root, layerURLs: [root], variables: [:])
    }
    private func run(_ backend: LinuxGuestShellBackend, _ workspace: URL, _ env: ToolEnvironment,
                     command: String? = nil, variables: [String: String] = [:], sensitive: SensitiveProcessEnvironment? = nil,
                     cancellation: CancellationToken? = nil) async -> ShellRunOutcome {
        await backend.run(ShellRunRequest(command: command ?? probe, cwd: ".", rootURL: workspace,
            environment: variables, sensitiveEnvironment: sensitive, sessionID: UUID().uuidString,
            toolEnvironment: env), cancellation: cancellation)
    }
    private func stdout(_ outcome: ShellRunOutcome) throws -> String {
        guard case .exited(let code, let output, _, _, _, _) = outcome, code == 0 else {
            XCTFail("Shell did not exit successfully"); throw FloeError.internalError("shell fixture")
        }
        return output
    }
    private func legacy(_ root: URL, python: String = "https://pypi.org/simple/") throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("var"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pythonIndex": python, "nodeRegistry": "https://node.example/"])
            .write(to: root.appendingPathComponent("var/language-package-sources.json"))
    }

    func testMissingAndNodeOnlyPreserveGuestConfiguration() async throws {
        let layer = try directory(), workspace = try directory()
        let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
        let original = "https://guest.example/simple/|https://guest-extra.example/simple/|guest.example"
        let missing = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertEqual(missing, original)
        try LanguagePackageSources(nodeRegistry: "https://node.example/").save(in: layer)
        XCTAssertFalse(try LanguagePackageSources.load(in: layer).pythonIndexIsExplicit)
        let nodeOnly = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertEqual(nodeOnly, original)
    }

    func testExplicitSelectionReachesRunAndPTYInOnlyTheResolvedLayer() async throws {
        let layer = try directory(), other = try directory(), workspace = try directory()
        try LanguagePackageSources(pythonIndex: selected, nodeRegistry: "https://node.example/").save(in: layer)
        try LanguagePackageSources(pythonIndex: "https://workspace.example/simple/").save(in: workspace)
        let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
        let selectedOutput = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertEqual(selectedOutput, selected + "||")
        let opened = try await backend.openSession(ShellOpenRequest(command: probe, rootURL: workspace,
            sessionID: "pty", toolEnvironment: environment(layer)), cancellation: nil)
        XCTAssertEqual(opened.initialOutput, selected + "||")
        _ = try await backend.openSession(ShellOpenRequest(rootURL: workspace, sessionID: "interactive", toolEnvironment: environment(layer)), cancellation: nil)
        let interactive = await runner.opens.last
        XCTAssertTrue(interactive?.command.contains(selected) == true)
        XCTAssertTrue(interactive?.command.contains("exec bash --noprofile --norc -i") == true)
        await backend.closeSession(sessionID: "pty")
        await backend.closeSession(sessionID: "interactive")
        let otherOutput = try stdout(await run(backend, workspace, environment(other, id: "other")))
        XCTAssertEqual(otherOutput, "https://guest.example/simple/|https://guest-extra.example/simple/|guest.example")
        XCTAssertEqual(try LanguagePackageSources.load(in: layer).nodeRegistry, "https://node.example/")
    }

    func testLegacyAmbiguityAndExplicitOfficialResave() async throws {
        let layer = try directory(), workspace = try directory()
        let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
        try legacy(layer)
        var value = try LanguagePackageSources.load(in: layer)
        XCTAssertFalse(value.pythonIndexIsExplicit)
        try value.save(in: layer)
        let legacyOfficial = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertTrue(legacyOfficial.hasPrefix("https://guest.example/"))
        value.pythonIndex = "https://pypi.org/simple/"  // The existing Python UI save assignment.
        try value.save(in: layer)
        XCTAssertTrue(try LanguagePackageSources.load(in: layer).pythonIndexIsExplicit)
        let explicitOfficial = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertEqual(explicitOfficial, "https://pypi.org/simple/||")
        try legacy(layer, python: selected)
        XCTAssertTrue(try LanguagePackageSources.load(in: layer).pythonIndexIsExplicit)
        let legacyCustom = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertEqual(legacyCustom, selected + "||")
    }

    func testExplicitEnvironmentConfigAndUnrestrictedCommandOverrides() async throws {
        let layer = try directory(), workspace = try directory()
        try LanguagePackageSources(pythonIndex: selected).save(in: layer)
        let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
        let explicit = try stdout(await run(backend, workspace, environment(layer), variables: [
            "PIP_INDEX_URL": "http://per-call.example/simple/", "PIP_EXTRA_INDEX_URL": "https://explicit-extra.example/", "PIP_TRUSTED_HOST": "per-call.example"
        ]))
        XCTAssertEqual(explicit, "http://per-call.example/simple/|https://explicit-extra.example/|per-call.example")
        let pty = try await backend.openSession(ShellOpenRequest(command: probe, rootURL: workspace,
            environment: ["PIP_INDEX_URL": "http://pty.example/simple/"], sessionID: "override-pty", toolEnvironment: environment(layer)), cancellation: nil)
        XCTAssertEqual(pty.initialOutput, "http://pty.example/simple/||")
        await backend.closeSession(sessionID: "override-pty")
        let configured = try stdout(await run(backend, workspace, environment(layer), variables: ["PIP_CONFIG_FILE": "/guest/custom-pip.conf"]))
        XCTAssertTrue(configured.hasPrefix("https://guest.example/"))
        let command = "unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_TRUSTED_HOST; printf '%s' \"${PIP_INDEX_URL-unset}\""
        let unset = try stdout(await run(backend, workspace, environment(layer), command: command))
        XCTAssertEqual(unset, "unset")
        let last = await runner.calls.last
        XCTAssertTrue(last?.command.hasSuffix(command) == true)
        XCTAssertFalse(last?.command.contains(layer.path) == true)
        let inCommand = try stdout(await run(backend, workspace, environment(layer), command: "PIP_INDEX_URL=http://inline.example/simple/ " + "/bin/sh -c 'printf %s \"$PIP_INDEX_URL\"'"))
        XCTAssertEqual(inCommand, "http://inline.example/simple/")
    }

    func testInvalidEscapingAndOversizedFilesRefuseBeforeDispatchWithoutSecretEcho() async throws {
        for kind in 0..<5 {
            let layer = try directory(), workspace = try directory(), outside = try directory()
            let varDirectory = layer.appendingPathComponent("var")
            if kind == 3 { try FileManager.default.createSymbolicLink(at: varDirectory, withDestinationURL: outside) }
            else {
                try FileManager.default.createDirectory(at: varDirectory, withIntermediateDirectories: true)
                let data: Data
                switch kind {
                case 0: data = Data("broken".utf8)
                case 1: data = Data(repeating: 65, count: 8193)
                case 4: data = try JSONSerialization.data(withJSONObject: ["pythonIndex": "https://pypi.org/simple/", "nodeRegistry": "https://node.example/", "pythonIndexIsExplicit": "true"])
                default: data = try JSONSerialization.data(withJSONObject: ["pythonIndex": "https://user:fixture-secret@example.org/simple/", "nodeRegistry": "https://node.example/"])
                }
                try data.write(to: varDirectory.appendingPathComponent("language-package-sources.json"))
            }
            let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
            let result = await run(backend, workspace, environment(layer))
            guard case .failed(let message) = result else { XCTFail("Invalid source accepted"); continue }
            XCTAssertFalse(message.contains("fixture-secret"))
            let calls = await runner.calls; XCTAssertTrue(calls.isEmpty)
            do {
                _ = try await backend.openSession(ShellOpenRequest(command: probe, rootURL: workspace, sessionID: "bad", toolEnvironment: environment(layer)), cancellation: nil)
                XCTFail("Invalid source accepted for PTY")
            } catch {}
            let opens = await runner.opens; XCTAssertTrue(opens.isEmpty)
        }
    }

    func testLargeScriptAndCancellationKeepSourceAndOwnedCleanup() async throws {
        let layer = try directory(), workspace = try directory()
        try LanguagePackageSources(pythonIndex: selected).save(in: layer)
        let runner = SourceShellRunner(workspace: workspace)
        let backend = LinuxGuestShellBackend(runner: runner, limits: LinuxGuestLimits(maxCommandBytes: 1024))
        let command = String(repeating: "# large body\n", count: 4096) + probe
        let stagedOutput = try stdout(await run(backend, workspace, environment(layer), command: command))
        XCTAssertEqual(stagedOutput, selected + "||")
        let last = await runner.calls.last; XCTAssertTrue(last?.staged == true)
        let cancelled = SourceShellRunner(workspace: workspace, cancelRun: true)
        let result = await run(LinuxGuestShellBackend(runner: cancelled, limits: LinuxGuestLimits(maxCommandBytes: 1024)), workspace, environment(layer), command: command)
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent(".floe-shell").path))?.isEmpty == true)
    }

    func testSensitiveOverridesRemainOnlyInTheNativeCarrierForRunAndPTY() async throws {
        let layer = try directory(), workspace = try directory()
        try LanguagePackageSources(pythonIndex: selected).save(in: layer)
        let secret = "https://user:fixture-token@private.example/simple/"
        let sensitive = try SensitiveProcessEnvironment(["PIP_INDEX_URL": secret])
        let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
        let result = try stdout(await run(backend, workspace, environment(layer), sensitive: sensitive))
        XCTAssertFalse(result.contains("fixture-token"))
        let runCall = await runner.calls.last
        XCTAssertEqual(runCall?.sensitiveNames, ["PIP_INDEX_URL"])
        XCTAssertFalse(runCall?.command.contains("fixture-token") == true)
        XCTAssertFalse(runCall?.command.contains(selected) == true)
        let opened = try await backend.openSession(ShellOpenRequest(command: probe, rootURL: workspace,
            sensitiveEnvironment: sensitive, sessionID: "sensitive", toolEnvironment: environment(layer)), cancellation: nil)
        XCTAssertFalse(opened.initialOutput.contains("fixture-token"))
        let openCall = await runner.opens.last; XCTAssertEqual(openCall?.sensitiveNames, ["PIP_INDEX_URL"])
        XCTAssertFalse(openCall?.command.contains("fixture-token") == true)
        await backend.closeSession(sessionID: "sensitive")
    }

    func testStoppedAndPerRunOverridesNeverProvisionOrPersist() async throws {
        let layer = try directory(), workspace = try directory()
        try LanguagePackageSources(pythonIndex: selected).save(in: layer)
        let stopped = SourceShellRunner(workspace: workspace, available: false)
        guard case .failed = await run(LinuxGuestShellBackend(runner: stopped), workspace, environment(layer)) else {
            return XCTFail("Stopped guest was accepted")
        }
        let stoppedCalls = await stopped.calls; XCTAssertTrue(stoppedCalls.isEmpty)
        let runner = SourceShellRunner(workspace: workspace), backend = LinuxGuestShellBackend(runner: runner)
        _ = await run(backend, workspace, environment(layer), variables: ["PIP_INDEX_URL": "https://one-run.example/simple/"])
        let nextRun = try stdout(await run(backend, workspace, environment(layer)))
        XCTAssertEqual(nextRun, selected + "||")
        XCTAssertEqual(try LanguagePackageSources.load(in: layer).pythonIndex, selected)
        let token = CancellationToken(); token.cancel()
        let cancelled = await run(backend, workspace, environment(layer), cancellation: token)
        XCTAssertEqual(cancelled, .cancelled)
    }
}
#endif
