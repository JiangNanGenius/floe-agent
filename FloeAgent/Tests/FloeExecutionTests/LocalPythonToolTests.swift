import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.LocalPython")
struct LocalPythonToolTests {
    @Test("descriptor is on-device, bounded, and always approval-sensitive")
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
    }

    @Test("declarative pip commands use the reviewed package path")
    func declarativePipValidation() async {
        let service = LocalPythonService(version: "CPython 3.13") { _, _ in .cancelled }
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

    @Test("declarative pip command is installed only through the managed phase")
    func declarativePipExecution() async throws {
        actor Recorder {
            var requests: [ScriptExecutionRequest] = []
            func append(_ request: ScriptExecutionRequest) { requests.append(request) }
            func snapshot() -> [ScriptExecutionRequest] { requests }
        }
        let recorder = Recorder()
        let service = LocalPythonService(version: "CPython 3.13") { request, _ in
            await recorder.append(request)
            return .ok(
                resultJSON: nil,
                stdout: request.allowsManagedPackageInstaller ? "managedPackages=marko==2.2.0" : "rendered",
                stderr: "",
                truncated: false,
                stderrTruncated: false,
                durationMs: 1
            )
        }
        let tool = LocalPythonTool(service: service)
        let output = try await tool.execute(
            .init(
                script: "import marko; print(marko.convert('# Title'))",
                pipCommand: "pip install marko==2.2.0",
                packagePurpose: "Render the Markdown requested by the user",
                packageCapabilities: ["document.render"]
            ),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let requests = await recorder.snapshot()
        #expect(requests.count == 2)
        #expect(requests.first?.allowsManagedPackageInstaller == true)
        #expect(requests.first?.script.contains("marko==2.2.0") == true)
        #expect(requests.first?.script.contains("os.makedirs(_parent, exist_ok=True)") == true)
        #expect(requests.first?.script.contains("os.makedirs(_target, exist_ok=True)") == true)
        #expect(requests.last?.allowsManagedPackageInstaller == false)
        #expect(output.exitStatus == 0)
    }

    @Test("managed package specs reject direct URLs and script-level pip")
    func managedPackageValidation() async {
        let service = LocalPythonService(version: "CPython 3.13") { _, _ in .cancelled }
        let tool = LocalPythonTool(service: service)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: "pass", packages: ["https://example.com/a.whl"]))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: "import pip"))
        }
        #expect(throws: Never.self) {
            try tool.validate(.init(script: "import requests", packages: ["requests==2.32.4"], packagePurpose: "Fetch the user-requested public dataset", packageCapabilities: ["data.fetch"]))
        }
    }

    @Test("service result is mapped to a tool result")
    func executionMapping() async throws {
        let service = LocalPythonService(version: "CPython 3.13") { request, _ in
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
        let service = LocalPythonService(version: "CPython 3.13") { _, _ in .cancelled }
        let tool = LocalPythonTool(service: service)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: "pass", inputJSON: "not-json"))
        }
    }

    @Test("capability probe reports the injected runtime")
    func probe() async {
        let service = LocalPythonService(version: "CPython 3.13") { _, _ in .cancelled }
        #expect(await LocalPythonCapabilityProbe(service: service).probe()
            == .available(version: "CPython 3.13"))
        #expect(await LocalPythonCapabilityProbe(service: nil).probe()
            == .unavailable(reason: "Bundled CPython runtime is not installed in this build"))
    }
}
