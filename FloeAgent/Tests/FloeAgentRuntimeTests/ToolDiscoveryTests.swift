import Foundation
import Testing
import FloeTools
import FloeCore
import FloeModels
@testable import FloeAgentRuntime

@Suite("Deferred tool discovery")
struct ToolDiscoveryTests {
    @Test func executorPreservesCompleteImageCatalog() async throws {
        let registry = ToolRunnerRegistry()
        let json = try JSONSerialization.data(withJSONObject: [
            "models": (1...25).map { ["id": "model-\($0)", "parameters": String(repeating: "supported ", count: 100)] },
            "nextOffset": 25
        ])
        let text = String(decoding: json, as: UTF8.self)
        registry.register(AnyAgentTool(descriptor: descriptor("image.models")) { _, _ in
            .init(summary: text, fullOutputSHA256: "", maximumSummaryCharacters: 262_144)
        })
        let result = try await CatalogToolExecutor(runners: registry).execute(
            ToolCall(id: "catalog", toolName: "image.models", argumentsJSON: Data("{}".utf8), scope: .local),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(result.status == .ok)
        #expect(result.outputSummary == text)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any])
        #expect(decoded["nextOffset"] as? Int == 25)
    }

    @Test func instructionsRespectTheEffectiveCatalog() {
        let limited = ToolDiscovery.index([descriptor("workspace.readFile")])
        #expect(!limited.contains("task.updatePlan"))
        #expect(!limited.contains("exec.localPython"))
        #expect(!limited.contains("skill.list"))
        let complete = ToolDiscovery.index(["task.readPlan", "task.updatePlan", "skill.list"].map(descriptor))
        #expect(complete.contains("Revise the same checklist"))
        #expect(complete.contains("A checklist never enables Goal mode"))
        #expect(complete.contains("skill.list"))
    }

    @Test func directoryDistinguishesOwnershipFromWorkflowGuidance() throws {
        let owned = ToolCatalog.Descriptor(name: "custom.report", toolDescription: "Report", parametersJSON: "{}",
            riskLabels: [], isSideEffecting: false, ownerSkillID: "report-plugin")
        let output = try ToolDiscovery.list(arguments: Data("{}".utf8),
            descriptors: [owned, descriptor("workspace.readFile")], loaded: [owned.name],
            relatedSkills: ["workspace.readFile": ["floe-files", "floe-office"]])
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let entries = try #require(object["tools"] as? [[String: Any]])
        let report = try #require(entries.first { $0["name"] as? String == owned.name })
        #expect(report["ownerSkillID"] as? String == "report-plugin")
        #expect(report["schemaLoaded"] as? Bool == true)
        let file = try #require(entries.first { $0["name"] as? String == "workspace.readFile" })
        #expect(file["ownerSkillID"] == nil)
        #expect(file["relatedSkillIDs"] as? [String] == ["floe-files", "floe-office"])
    }

    @Test func batchExactAndCapabilityQueriesDoNotMaskEachOther() throws {
        let queries = try JSONDecoder().decode(DiscoveryQueries.self,
            from: Data(#"{"queries":["workspace.readFile","pdf","workspace.readFile"]}"#.utf8)).validated()
        let found = ToolDiscovery.matches(queries: queries,
            descriptors: [descriptor("workspace.readFile"), descriptor("pdf.inspect"), descriptor("network.ping")])
        #expect(found.map(\.name) == ["workspace.readFile", "pdf.inspect"])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DiscoveryQueries.self, from: Data(#"{"query":"pdf","queries":["pdf"]}"#.utf8)).validated()
        }
        #expect(throws: (any Error).self) { try DiscoveryQueries(queries: [" "]).validated() }
    }

    @Test func directoryPagingDoesNotLoadOrTruncateToSchemaBudget() throws {
        let descriptors = (0..<240).map { descriptor(String(format: "custom.tool%03d", $0)) }
        var cursor: String? = nil
        var names: [String] = []
        repeat {
            var arguments: [String: Any] = ["limit": 37]
            if let cursor { arguments["afterName"] = cursor }
            let output = try ToolDiscovery.list(arguments: JSONSerialization.data(withJSONObject: arguments), descriptors: descriptors, loaded: [])
            let result = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            let entries = try #require(result["tools"] as? [[String: Any]])
            #expect(result["total"] as? Int == 240)
            #expect(entries.allSatisfy { $0["schemaLoaded"] as? Bool == false })
            names += entries.compactMap { $0["name"] as? String }
            cursor = result["nextAfterName"] as? String
        } while cursor != nil
        #expect(names == descriptors.map(\.name))
    }
    @Test("Description fallback does not activate unrelated tools in the same group")
    func descriptionFallbackIsNarrow() {
        let hit = ToolCatalog.Descriptor(name: "custom.one", toolDescription: "Use for quux processing", parametersJSON: "{}", riskLabels: [], isSideEffecting: false)
        let available = [hit, descriptor("custom.two"), descriptor("custom.three")]
        #expect(ToolDiscovery.matches(query: "quux", descriptors: available).map(\.name) == ["custom.one"])
        #expect(ToolDiscovery.matches(query: "  ", descriptors: available).isEmpty)
    }
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

    @Test("Compat mode: underscored cursors paginate and entries are wire-spelled")
    func compatListCursorAndWireNames() throws {
        let descriptors = ["workspace.createFile", "workspace.listDirectory", "workspace.readFile", "web.search"].map(descriptor)
        // Underscored cursor from a wire-spelled page turn must not skip the group.
        let output = try ToolDiscovery.list(
            arguments: Data(#"{"afterName":"workspace_createFile","limit":10}"#.utf8),
            descriptors: descriptors, loaded: [], wireSafeNames: true
        )
        struct Row: Decodable { let name: String }
        struct Page: Decodable { let tools: [Row]; let total: Int; let nextAfterName: String? }
        let page = try JSONDecoder().decode(Page.self, from: Data(output.utf8))
        #expect(page.tools.map(\.name) == ["workspace_listDirectory", "workspace_readFile"])
        #expect(page.total == 4)
        #expect(page.nextAfterName == nil)
        // Paged output hands back a wire-spelled cursor that keeps working.
        let firstPage = try ToolDiscovery.list(
            arguments: Data(#"{"limit":2}"#.utf8),
            descriptors: descriptors, loaded: [], wireSafeNames: true
        )
        let first = try JSONDecoder().decode(Page.self, from: Data(firstPage.utf8))
        #expect(first.nextAfterName == "workspace_createFile")
        let secondPage = try ToolDiscovery.list(
            arguments: Data(#"{"afterName":"\#(first.nextAfterName ?? "")","limit":2}"#.utf8),
            descriptors: descriptors, loaded: [], wireSafeNames: true
        )
        let second = try JSONDecoder().decode(Page.self, from: Data(secondPage.utf8))
        #expect(second.tools.map(\.name) == ["workspace_listDirectory", "workspace_readFile"])
    }

    @Test("Compat mode: underscored exact query loads the canonical tool")
    func compatSearchExactName() {
        let available = ["workspace.readFile", "workspace.writeFile", "web.search"].map(descriptor)
        #expect(ToolDiscovery.matches(query: "workspace_readfile", descriptors: available).map(\.name) == ["workspace.readFile"])
        // Canonical spelling keeps working.
        #expect(ToolDiscovery.matches(query: "workspace.readfile", descriptors: available).map(\.name) == ["workspace.readFile"])
    }
}
