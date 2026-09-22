// FloeAppTests — Native capability router and Linux convergence.
//
// Proves the routing table is exhaustive and stable: interpreter/CLI/package/
// server workloads land in the Linux guest, heavy media/GPU work stays on
// native Apple frameworks with no silent emulator fallback, remote prefixes
// stay remote, and retired WASI/PHP/Ruby/Lua surfaces converge on the guest
// instead of a bundled interpreter.

import Foundation
import Testing
import FloeModels
import FloeTools

@Suite("FloeApp.CapabilityExecutionRouter")
struct CapabilityExecutionRouterTests {

    @Test("Linux workers keep their stable tool names")
    func linuxToolNamesStayStable() {
        let names = [
            "exec.shell", "shell.open", "shell.exchange", "shell.close", "shell.signal",
            "exec.localPython", "exec.localService", "apt", "python.packages",
            "environment.prepareLinux",
        ]
        for name in names {
            let decision = CapabilityExecutionRouter.decision(for: name)
            #expect(decision.backend == .linuxGuest, "\(name) must run in the Linux guest")
            #expect(decision.toolName == name)
        }
    }

    @Test("Workload classes match the documented responsibilities")
    func workloadClassification() {
        #expect(CapabilityExecutionRouter.decision(for: "exec.localService").workload == .server)
        #expect(CapabilityExecutionRouter.decision(for: "apt").workload == .package)
        #expect(CapabilityExecutionRouter.decision(for: "python.packages").workload == .package)
        #expect(CapabilityExecutionRouter.decision(for: "exec.localPython").workload == .interpreter)
        #expect(CapabilityExecutionRouter.decision(for: "exec.shell").workload == .cli)
    }

    @Test("Versioned shell names still route through the guest prefix rule")
    func versionedShellPrefixesRouteToGuest() {
        // A retired/renamed suffix must still resolve to the guest, never to a
        // native substrate and never to a temporary directory.
        #expect(CapabilityExecutionRouter.decision(for: "shell.echo").backend == .linuxGuest)
        #expect(CapabilityExecutionRouter.decision(for: "exec.shell.session").backend == .linuxGuest)
    }

    @Test("Retired generic interpreter surfaces converge on the Linux guest")
    func genericRuntimesConvergeOnLinux() {
        for name in ["exec.wasm", "exec.compatEvaluator", "wasm.packages"] {
            let decision = CapabilityExecutionRouter.decision(for: name)
            #expect(decision.backend == .linuxGuest, "\(name) must not run a bundled WASM payload")
            #expect(decision.reason.contains("Linux guest"))
        }
        // JavaScript is the one in-process interpreter that remains native:
        // it is the system JavaScriptCore framework, not a bundled payload.
        let js = CapabilityExecutionRouter.decision(for: "exec.javascript")
        #expect(js.backend == .nativeApple)
        #expect(js.reason.contains("JavaScriptCore"))
    }

    @Test("Heavy media and GPU work never silently emulates on the guest")
    func nativeMediaHasNoSilentLinuxFallback() {
        let nativeTools = [
            "video.generate", "video.edit", "audio.transcribe", "media.probe",
            "image.ocr", "image.barcode", "image.generate", "document.pdf.fill",
            "canvas.render", "notes.assistant",
        ]
        for name in nativeTools {
            let decision = CapabilityExecutionRouter.decision(for: name)
            #expect(decision.backend == .nativeApple, "\(name) is native Apple")
            #expect(!decision.boundedLinuxFallback, "\(name) must not fall back to TinyEMU")
        }
        #expect(CapabilityExecutionRouter.decision(for: "image.ocr").workload == .ocr)
        #expect(CapabilityExecutionRouter.decision(for: "document.pdf.fill").workload == .pdf)
    }

    @Test("Remote prefixes stay on the configured remote host")
    func remotePrefixesStayRemote() {
        for name in ["ssh.run", "remote.python", "remoteHosting.agentUpdate"] {
            let decision = CapabilityExecutionRouter.decision(for: name)
            #expect(decision.backend == .remoteHost)
            #expect(decision.workload == .remote)
        }
    }

    @Test("Unknown tools are honest compiled-Swift tools")
    func unknownToolsDefaultToNative() {
        let decision = CapabilityExecutionRouter.decision(for: "some.futureTool")
        #expect(decision.backend == .nativeApple)
        #expect(decision.workload == .general)
        #expect(!decision.boundedLinuxFallback)
    }

    @Test("The routing ledger is bounded and newest-first")
    func ledgerIsBounded() async {
        let ledger = CapabilityRouteLedger()
        await ledger.clear()
        for _ in 0..<(CapabilityRouteLedger.maxRecords + 20) {
            await ledger.record(toolName: "exec.shell")
        }
        #expect(await ledger.recent(limit: CapabilityRouteLedger.maxRecords).count == CapabilityRouteLedger.maxRecords)
        #expect(await ledger.recent(limit: 1).first?.toolName == "exec.shell")
        #expect(await ledger.recent(limit: 1).first?.backend == .linuxGuest)
        await ledger.clear()
        #expect(await ledger.recent().isEmpty)
    }
}

@Suite("FloeApp.ToolResultProvenance")
struct ToolResultProvenanceBackendTests {

    @Test("Runtime-authored backend provenance round-trips and defaults to unknown")
    func backendProvenanceRoundTrip() throws {
        let defaulted = ToolResultProvenance(sourceID: "src", toolName: "exec.shell", runID: UUID())
        #expect(defaulted.executionBackend == nil)
        #expect(defaulted.executionBackendReason == nil)

        let authored = ToolResultProvenance(
            sourceID: "src",
            toolName: "exec.shell",
            runID: UUID(),
            executionBackend: CapabilityBackend.linuxGuest.rawValue,
            executionBackendReason: "interpreter/CLI workloads run inside the TinyEMU Linux guest"
        )
        let decoded = try JSONDecoder().decode(
            ToolResultProvenance.self,
            from: try JSONEncoder().encode(authored)
        )
        #expect(decoded.executionBackend == "linux-guest")
        #expect(decoded.executionBackendReason?.contains("Linux guest") == true)
        #expect(decoded.toolName == "exec.shell")
    }
}
