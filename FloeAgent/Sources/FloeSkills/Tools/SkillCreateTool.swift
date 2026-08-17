// FloeSkills — skill.create agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Lets the agent author a declarative Floe skill from a name, a short
/// description, and an instruction body (the SKILL.md content). The actual
/// package assembly, validation, persistence and permission grants run in the
/// injected pipeline — the tool never trusts model output to self-install.
public struct SkillCreateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var name: String
        public var description: String
        public var instructions: String

        public init(name: String, description: String, instructions: String) {
            self.name = name
            self.description = description
            self.instructions = instructions
        }
    }

    public static let name = "skill.create"
    public static let toolDescription =
        "Create a reusable Floe skill from a name, a one-line description, and instructions. The skill is validated, persisted, and becomes available for future runs. Give the instructions as the full SKILL.md body (steps, conventions, or reference knowledge the agent should reuse)."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "Skill name (letters/numbers; becomes a lowercase identifier)"},
        "description": {"type": "string", "description": "One-line description of when to use this skill"},
        "instructions": {"type": "string", "description": "The skill body (Markdown): steps, conventions, or reference knowledge to reuse"}
      },
      "required": ["name", "description", "instructions"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maxNameBytes = 128
    static let maxDescriptionBytes = 512
    static let maxInstructionsBytes = 256 * 1024

    private let creator: any SkillCreating

    public init(creator: any SkillCreating) {
        self.creator = creator
    }

    public func validate(_ args: Arguments) throws {
        let name = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= Self.maxNameBytes else {
            throw FloeError.validationFailed("name must be non-empty and at most \(Self.maxNameBytes) bytes")
        }
        guard !args.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args.description.utf8.count <= Self.maxDescriptionBytes else {
            throw FloeError.validationFailed("description must be non-empty and at most \(Self.maxDescriptionBytes) bytes")
        }
        guard !args.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args.instructions.utf8.count <= Self.maxInstructionsBytes else {
            throw FloeError.validationFailed("instructions must be non-empty and at most \(Self.maxInstructionsBytes) bytes")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let skill = try await creator.create(SkillCreationRequest(
                name: args.name,
                description: args.description,
                instructions: args.instructions
            ))
            let text = "status=created id=\(skill.id) name=\(skill.name) version=\(skill.version)"
            return Self.output(text, exitStatus: 0)
        } catch {
            return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
