// FloeExecution — live Linux-guest Python service and capability probe.
//
// These cases moved out of the retired exec.localPython tool test file. The
// service itself is still the shared script/runtime seam used by internal
// processors and the Settings capability probe.

import Foundation
import Testing
@testable import FloeExecution
import FloeCore
import FloeTools

@Suite("FloeExecution.LocalPythonService")
struct LocalPythonServiceTests {
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
        let staticManifest = await LocalPythonCapabilityProbe(service: service).runtimeManifest()
        #expect(staticManifest.contains("Linux environment"))
        let live = await LocalPythonCapabilityProbe(
            service: service,
            backendStatus: { .init(backendPresent: true, componentInstalled: true) },
            liveProbeEnvironment: { "env-live" }
        ).runtimeManifest()
        #expect(live.contains("3.13.5"))
        #expect(live.contains("linux-guest"))
        #expect(await LocalPythonCapabilityProbe(service: nil).runtimeManifest().contains("unavailable"))
    }

    @Test("service maps a real guest result without inventing output")
    func serviceResultMapping() async {
        let service = LocalPythonService(version: "Python 3 (Linux guest)") { request, _ in
            .ok(resultJSON: nil, stdout: "received=\(request.inputJSON ?? "null")",
                stderr: "", truncated: false, stderrTruncated: false, durationMs: 4)
        }
        let outcome = await service.run(
            ScriptExecutionRequest(script: "print(input)", inputJSON: #"{"answer":42}"#),
            cancellation: CancellationToken())
        guard case .ok(_, let stdout, _, false, _, _) = outcome else {
            Issue.record("expected a successful guest result: \(outcome)")
            return
        }
        #expect(stdout == #"received={"answer":42}"#)
    }

    @Test("cancellation before the runner starts returns cancelled")
    func cancelledBeforeStart() async {
        let service = LocalPythonService(version: "guest") { _, _ in
            .ok(resultJSON: nil, stdout: "must not run", stderr: "", truncated: false,
                stderrTruncated: false, durationMs: 1)
        }
        let cancellation = CancellationToken()
        cancellation.cancel()
        let outcome = await service.run(ScriptExecutionRequest(script: "print(1)"), cancellation: cancellation)
        #expect(outcome == .cancelled)
    }
}
