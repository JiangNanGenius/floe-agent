import Foundation
import Testing
import FloeTools
@testable import FloeAgentRuntime

@Suite("Deferred tool discovery")
struct ToolDiscoveryTests {
    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        .init(name: name, toolDescription: name, parametersJSON: #"{"type":"object","properties":{}}"#, riskLabels: [], isSideEffecting: false)
    }

    @Test("VNC discovery loads the whole lifecycle and SSH, not unrelated groups")
    func vncGroup() {
        let names = ["vnc.status", "vnc.connect", "vnc.observe", "vnc.click", "vnc.disconnect", "ssh.execute", "memory.organizePreview", "network.ping"]
        let found = ToolDiscovery.matches(query: "测试 VNC", descriptors: names.map(descriptor)).map(\.name)
        #expect(found == Array(names.prefix(6)))
    }

    @Test("Discovery never invents or restores tools outside the supplied ceiling")
    func permissionCeiling() {
        let available = [descriptor("workspace.readFile")]
        #expect(ToolDiscovery.matches(query: "workspace", descriptors: available).map(\.name) == ["workspace.readFile"])
        #expect(ToolDiscovery.matches(query: "vnc", descriptors: available).isEmpty)
        #expect(ToolDiscovery.index(available).contains("workspace (1)"))
    }

    @Test("The executable registry is authoritative; static-only declarations stay hidden")
    func executableSource() {
        let registry = ToolRunnerRegistry()
        let d = descriptor("test.live")
        registry.register(AnyAgentTool(descriptor: d) { _, _ in .init(summary: "ok", fullOutputSHA256: "") })
        let executor = CatalogToolExecutor(runners: registry)
        #expect(executor.allDescriptors.map(\.name) == ["test.live"])
        #expect(executor.descriptor(named: "vnc.observe") == nil)
    }
}
