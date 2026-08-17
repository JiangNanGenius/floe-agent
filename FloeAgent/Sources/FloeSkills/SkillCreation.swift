// FloeSkills — skill creation contract.
//
// The on-device UI can author skills by hand, and the agent should be able
// to do the same through a tool. This protocol lets the tool live in the
// testable SPM layer while the app injects the concrete creation pipeline
// (package assembly + validation + SQLite persistence + permission grants).

import Foundation

/// Inputs for creating a declarative Floe skill.
public struct SkillCreationRequest: Sendable, Equatable {
    public var name: String
    public var description: String
    public var instructions: String

    public init(name: String, description: String, instructions: String) {
        self.name = name
        self.description = description
        self.instructions = instructions
    }
}

/// Result of a successful skill creation.
public struct CreatedSkill: Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String

    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
    }
}

/// Creates a declarative skill from a name, description, and instruction body.
public protocol SkillCreating: Sendable {
    func create(_ request: SkillCreationRequest) async throws -> CreatedSkill
}
