import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.LocalPython")
struct LocalPythonToolTests {
    @Test func shellPipPreservesArgumentsAndRejectsTargetOrCodeInjection() throws {
        if case .install(let specs) = try ManagedPythonPackageSpecParser.parseShell(arguments: ["install", "-U", "httpx==0.28.1", "requests"]) {
            #expect(specs == ["httpx==0.28.1", "requests"])
        } else { Issue.record("Install was not routed") }
        if case .remove(let name) = try ManagedPythonPackageSpecParser.parseShell(arguments: ["uninstall", "-y", "requests"]) { #expect(name == "requests") }
        else { Issue.record("Uninstall was not routed") }
        if case .inspect(let command, let args) = try ManagedPythonPackageSpecParser.parseShell(arguments: ["list", "--format=json"]) {
            #expect(command == "list" && args == ["--format=json"])
        } else { Issue.record("Inventory was not routed") }
        for arguments in [["install", "--target", "/tmp", "requests"], ["install", "https://example.com/p.whl"],
                          ["install", "requests;print(1)"], ["uninstall", "one", "two"], ["show", "os.system('x')"]] {
            #expect(throws: (any Error).self) { try ManagedPythonPackageSpecParser.parseShell(arguments: arguments) }
        }
    }

    @Test("descriptor is on-device, bounded, Linux-backed and always approval-sensitive")
    func descriptorContract() {
        #expect(LocalPythonTool.name == "exec.localPython")
        #expect(LocalPythonTool.isSideEffecting)
        #expect(LocalPythonTool.riskLabels == [.executesLocalCode])
        #expect(LocalPythonTool.parametersJSON.contains("maxOutputBytes"))
        #expect(LocalPythonTool.parametersJSON.contains("inputJSON"))
        #expect(LocalPythonTool.parametersJSON.contains("packages"))
        #expect(LocalPythonTool.parametersJSON.contains("pipCommand"))
        #expect(LocalPythonTool.toolDescription.contains("packagePurpose"))
        #expect(LocalPythonTool.parametersJSON.contains("packageCapabilities"))
        // Phase 2: the description discloses the Linux guest backend and the
        // absence of bundled packages instead of advertising a native
        // interpreter.
        #expect(LocalPythonTool.toolDescription.contains("Linux guest"))
        #expect(LocalPythonTool.toolDescription.contains("Packages are NOT bundled"))
        #expect(!LocalPythonTool.toolDescription.contains("bundles compatible iOS"))
    }

    @Test("declarative pip commands use the reviewed package path")
    func declarativePipValidation() async {
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { _, _ in .cancelled }
        let tool = LocalPythonTool(service: service)
        #expect(throws: Never.self) {
            try tool.validate(.init(
                script: "import marko",
                pipCommand: "pip install marko==2.2.0",
                packagePurpose: "Render the Markdown document requested by the user",
                packageCapabilities: ["document.render"]
            ))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                script: "pass",
                pipCommand: "pip install --index-url https://example.com marko",
                packagePurpose: "Render Markdown",
                packageCapabilities: ["document.render"]
            ))
        }
    }

    /// Scripted guest runner: provisions the shared venv and answers pip.
    private static func guestRunner(
        pipExitCode: Int32 = 0,
        pipOutput: String = "Successfully installed marko-2.2.0\n"
    ) -> ScriptedLinuxCommandRunner {
        ScriptedLinuxCommandRunner { argv, _, _ in
            let joined = argv.joined(separator: " ")
            if joined.contains("sysconfig.get_paths") {
                return LinuxCommandResult(stdout: "/floe/env/python/venv/lib/python3.13/site-packages\n", stderr: "", exitCode: 0)
            }
            if joined.contains("bin/pip") && !joined.contains("install") {
                return LinuxCommandResult(stdout: "pip-ok\n", stderr: "", exitCode: 0)
            }
            if argv.contains("--version") {
                return LinuxCommandResult(stdout: "Python 3.13.5\n", stderr: "", exitCode: 0)
            }
            if joined.contains("floePythonInventory") {
                return LinuxCommandResult(stdout: "floePythonInventory=[]\n", stderr: "", exitCode: 0)
            }
            if joined.contains("install") {
                return LinuxCommandResult(stdout: pipOutput, stderr: "", exitCode: pipExitCode)
            }
            return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    @Test("declarative pip command installs through the guest venv before the script runs")
    func declarativePipExecution() async throws {
        actor Recorder {
            var requests: [ScriptExecutionRequest] = []
            func append(_ request: ScriptExecutionRequest) { requests.append(request) }
            func snapshot() -> [ScriptExecutionRequest] { requests }
        }
        let recorder = Recorder()
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { request, _ in
            await recorder.append(request)
            return .ok(resultJSON: nil, stdout: "rendered", stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
        }
        let environmentID = "env-tool-\(UUID().uuidString)"
        let runner = Self.guestRunner()
        let installer = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: runner))
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        let tool = LocalPythonTool(service: service, installer: installer)
        let userScript = "import marko; print(marko.convert('# Title'))"
        let output = try await tool.execute(
            .init(
                script: userScript,
                pipCommand: "pip install marko==2.2.0",
                packagePurpose: "Render the Markdown requested by the user",
                packageCapabilities: ["document.render"]
            ),
            context: ToolContext(
                runID: UUID(),
                cancellation: CancellationToken(),
                environment: ToolEnvironment(
                    id: environmentID,
                    writableLayerURL: FileManager.default.temporaryDirectory,
                    layerURLs: [FileManager.default.temporaryDirectory],
                    variables: [:]
                )
            )
        )
        // The install ran through the guest's real pip (not an in-process
        // installer phase) and the user script ran afterwards.
        #expect(runner.calls.contains { $0.argv.contains("install") && $0.argv.contains("marko==2.2.0") })
        #expect(await recorder.snapshot().last?.script == userScript)
        #expect(output.exitStatus == 0)
    }

    @Test("failed guest installation never starts the user script")
    func failedInstallPreventsExecution() async throws {
        actor Recorder {
            var count = 0
            func increment() { count += 1 }
            func snapshot() -> Int { count }
        }
        let recorder = Recorder()
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { _, _ in
            await recorder.increment()
            return .ok(resultJSON: nil, stdout: "", stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
        }
        let environmentID = "env-tool-\(UUID().uuidString)"
        let runner = Self.guestRunner(pipExitCode: 1, pipOutput: "ERROR: ownership conflict\n")
        let installer = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: runner))
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }
        let output = try await LocalPythonTool(service: service, installer: installer).execute(
            .init(script: "print('must not execute')", packages: ["marko==2.2.0"],
                  packagePurpose: "Render the user's document", packageCapabilities: ["document.render"]),
            context: ToolContext(
                runID: UUID(),
                cancellation: CancellationToken(),
                environment: ToolEnvironment(
                    id: environmentID,
                    writableLayerURL: FileManager.default.temporaryDirectory,
                    layerURLs: [FileManager.default.temporaryDirectory],
                    variables: [:]
                )
            )
        )
        #expect(output.exitStatus != 0)
        #expect(await recorder.snapshot() == 0)
    }

    @Test("non-Linux environments fail honestly without touching any interpreter")
    func nonLinuxEnvironmentFailsHonestly() async throws {
        actor Recorder {
            var count = 0
            func increment() { count += 1 }
            func snapshot() -> Int { count }
        }
        let recorder = Recorder()
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { _, _ in
            await recorder.increment()
            return .ok(resultJSON: nil, stdout: "", stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
        }
        let runner = ScriptedLinuxCommandRunner()
        runner.owns = false
        let installer = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: runner))
        let output = try await LocalPythonTool(service: service, installer: installer).execute(
            .init(script: "print('x')", packages: ["marko==2.2.0"],
                  packagePurpose: "Render the user's document", packageCapabilities: ["document.render"]),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus != 0)
        #expect(output.summary.contains("Linux"))
        #expect(await recorder.snapshot() == 0)
    }

    @Test("managed package specs reject direct URLs")
    func managedPackageValidation() async {
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { _, _ in .cancelled }
        let tool = LocalPythonTool(service: service)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: "pass", packages: ["https://example.com/a.whl"]))
        }
        #expect(throws: Never.self) {
            try tool.validate(.init(script: "import requests", packages: ["requests==2.32.4"], packagePurpose: "Fetch the user-requested public dataset", packageCapabilities: ["data.fetch"]))
        }
    }

    @Test("service result is mapped to a tool result")
    func executionMapping() async throws {
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { request, _ in
            .ok(
                resultJSON: nil,
                stdout: "received=\(request.inputJSON ?? "null")",
                stderr: "",
                truncated: false,
                stderrTruncated: false,
                durationMs: 4
            )
        }
        let tool = LocalPythonTool(service: service)
        let cancellation = CancellationToken()
        let output = try await tool.execute(
            .init(script: "print(input)", inputJSON: #"{"answer":42}"#),
            context: ToolContext(runID: UUID(), cancellation: cancellation)
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains(#"received={"answer":42}"#))
        #expect(output.fullOutputSHA256.count == 64)
    }

    @Test("invalid input JSON is rejected before runtime")
    func validation() async {
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { _, _ in .cancelled }
        let tool = LocalPythonTool(service: service)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: "pass", inputJSON: "not-json"))
        }
    }

    @Test("capability probe reports the Linux backend honestly")
    func probe() async {
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { _, _ in .cancelled }
        #expect(await LocalPythonCapabilityProbe(
            service: service,
            backendStatus: { .init(backendPresent: true, componentInstalled: true) }
        ).probe() == .available(version: "Python 3 (Linux guest)"))
        let missing = await LocalPythonCapabilityProbe(
            service: service,
            backendStatus: { .init(backendPresent: true, componentInstalled: false) }
        ).probe()
        guard case .unavailable(let reason) = missing, reason.contains("Linux component") else {
            Issue.record("Missing component must be the honest unavailable reason: \(missing)")
            return
        }
        #expect(await LocalPythonCapabilityProbe(service: nil).probe()
            == .unavailable(reason: "Local Python runs in the Linux guest component, which is not part of this build"))
    }

    @Test("runtime manifest is a live guest probe or an honest static statement")
    func runtimeLibraryManifest() async {
        let service = LocalPythonService(version: "guest") { request, _ in
            #expect(request.script.contains("importlib.import_module"))
            return .ok(resultJSON: nil, stdout: #"{"python":"3.13.5","backend":"linux-guest","libraries":{"numpy":{"available":true,"version":"2.5.2"}}}"#,
                stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
        }
        // No running guest: static statement, no fabricated library list.
        let staticManifest = await LocalPythonCapabilityProbe(service: service).runtimeManifest()
        #expect(staticManifest.contains("Linux environment"))
        // A running environment yields the live probe result.
        let live = await LocalPythonCapabilityProbe(
            service: service,
            backendStatus: { .init(backendPresent: true, componentInstalled: true) },
            liveProbeEnvironment: { "env-live" }
        ).runtimeManifest()
        #expect(live.contains("3.13.5"))
        #expect(live.contains("linux-guest"))
        #expect(await LocalPythonCapabilityProbe(service: nil).runtimeManifest().contains("unavailable"))
    }
}
