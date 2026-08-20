import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeSkills

@Suite("FloeSkills.SkillCreate")
struct SkillCreateToolTests {

    @Test("descriptor is side-effecting and writes files")
    func descriptorContract() {
        #expect(SkillCreateTool.name == "skill.create")
        #expect(SkillCreateTool.isSideEffecting)
        #expect(SkillCreateTool.riskLabels == [.writesFiles, .changesAgentBehavior])
        #expect(SkillCreateTool.parametersJSON.contains("\"name\""))
        #expect(SkillCreateTool.parametersJSON.contains("\"instructions\""))
    }

    @Test("empty name and oversized instructions are rejected")
    func validation() async {
        let tool = SkillCreateTool(creator: FakeSkillCreator())
        #expect(throws: FloeError.self) {
            try tool.validate(.init(name: "", description: "d", instructions: "i"))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                name: "x", description: "d",
                instructions: String(repeating: "a", count: 300_000)
            ))
        }
    }

    @Test("creator result is mapped to a tool result")
    func executionMapping() async throws {
        let tool = SkillCreateTool(creator: FakeSkillCreator())
        let output = try await tool.execute(
            .init(name: "My Skill", description: "Does a thing", instructions: "# Steps\n1. Go"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=created"))
        #expect(output.summary.contains("my-skill"))
        #expect(output.fullOutputSHA256.count == 64)
    }

    @Test("creator failure maps to a non-zero tool result")
    func failureMapping() async throws {
        let tool = SkillCreateTool(creator: FakeSkillCreator(error: FloeError.validationFailed("bad name")))
        let output = try await tool.execute(
            .init(name: "Bad", description: "d", instructions: "i"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("status=failed"))
    }
}

private struct FakeSkillCreator: SkillCreating {
    var error: (any Error)?
    func create(_ request: SkillCreationRequest) async throws -> CreatedSkill {
        if let error { throw error }
        return CreatedSkill(id: "my-skill", name: request.name, version: "1.0.0")
    }
}
