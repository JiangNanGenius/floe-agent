import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeSkills

private actor ManagedSkillFixture: SkillManaging {
    var mutations = 0
    func read(id: String?) async throws -> [ManagedSkill] {
        [.init(id: "example", name: "Example", version: "1.0.0", enabled: true, digest: String(repeating: "a", count: 64), markdown: id == nil ? nil : "body")]
    }
    func manage(_ request: SkillManageTool.Arguments) async throws -> String { mutations += 1; return "applied" }
}

@Suite("Skill management contracts")
struct SkillManagementTests {
    @Test func exactArgumentsAndNoTraversal() throws {
        let tool = SkillManageTool(manager: ManagedSkillFixture())
        let digest = String(repeating: "a", count: 64)
        try tool.validate(.init(action: .update, id: "example", expectedDigest: digest, instructions: "new body"))
        for id in ["../example", "/root", ".", "a/b"] {
            #expect(throws: FloeError.self) { try tool.validate(.init(action: .remove, id: id, expectedDigest: digest)) }
        }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: .remove, id: "example", expectedDigest: digest, instructions: "ambiguous")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: .setEnabled, id: "example", expectedDigest: digest)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: .update, id: "example", expectedDigest: "stale", instructions: "body")) }
    }
    @Test func noGrantCannotMutate() async throws {
        let manager = ManagedSkillFixture()
        let tool = SkillManageTool(manager: manager)
        await #expect(throws: FloeError.self) {
            try await tool.execute(.init(action: .remove, id: "example", expectedDigest: String(repeating: "a", count: 64)), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        }
        #expect(await manager.mutations == 0)
    }
    @Test func listAndDetailAreStructuredAndReadOnly() async throws {
        let tool = SkillReadTool(manager: ManagedSkillFixture())
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let list = try await tool.execute(.init(), context: context)
        let detail = try await tool.execute(.init(id: "example"), context: context)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(list.summary.utf8)).first?.markdown == nil)
        #expect(try JSONDecoder().decode([ManagedSkill].self, from: Data(detail.summary.utf8)).first?.markdown == "body")
        #expect(!SkillReadTool.isSideEffecting)
        #expect(SkillManageTool.isSideEffecting)
    }
}
