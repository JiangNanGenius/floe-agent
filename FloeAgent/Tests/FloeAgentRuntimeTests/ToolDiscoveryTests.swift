import Foundation
import Testing
import FloeTools
@testable import FloeAgentRuntime

@Suite("Deferred tool discovery")
struct ToolDiscoveryTests {
    @Test("Executor and interactive Terminal are separate roles despite the SSH prefix")
    func executionRoles() {
        let available = ["ssh.execute", "ssh.taskStatus", "ssh.cancelTask", "ssh.shellOpen", "ssh.shellExchange", "ssh.shellClose", "ssh.listHosts", "exec.localPython"].map(descriptor)
        let terminal = ToolDiscovery.matches(query: "terminal", descriptors: available).map(\.name)
        #expect(terminal.contains("ssh.shellOpen"))
        #expect(terminal.contains("ssh.listHosts"))
        #expect(!terminal.contains("ssh.execute"))
        let executor = ToolDiscovery.matches(query: "executor", descriptors: available).map(\.name)
        #expect(executor.contains("ssh.cancelTask"))
        #expect(!executor.contains("ssh.shellOpen"))
        #expect(ToolDiscovery.matches(query: "python", descriptors: available).map(\.name) == ["exec.localPython"])
    }

    @Test("Exact lookup and bounded presentation keep requested tools and the skill reader")
    func boundedSchemas() {
        let available = (0..<80).map { descriptor("workspace.tool\($0)") } + [descriptor("skill.read")]
        #expect(ToolDiscovery.matches(query: "workspace.tool79", descriptors: available).map(\.name) == ["workspace.tool79"])
        let bounded = ToolDiscovery.bounded(available, priority: ["workspace.tool79"], maxTools: 4)
        #expect(bounded.count == 4)
        #expect(bounded.map(\.name).contains("skill.read"))
        #expect(bounded.map(\.name).contains("workspace.tool79"))
    }

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

    @Test("Chinese mail discovery selects only available mail runners")
    func mailGroup() {
        let available = ["mail.accounts", "mail.read", "mail.send", "vnc.click", "memory.organizePreview"].map(descriptor)
        #expect(ToolDiscovery.matches(query: "查看邮箱", descriptors: available).map(\.name) == ["mail.accounts", "mail.read", "mail.send"])
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

    @Test("Chinese skill discovery loads the available lifecycle without unrelated tools")
    func skillGroup() {
        let available = ["skill.create", "skill.read", "skill.manage", "memory.organizePreview", "ssh.cancelTask"].map(descriptor)
        #expect(ToolDiscovery.matches(query: "修改已有技能", descriptors: available).map(\.name) == ["skill.create", "skill.read", "skill.manage"])
    }
}
