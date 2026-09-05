// FloeApp — App-side skill creation bridge.
//
// Reuses SkillsCenter's package assembly, validation, persistence and
// permission grants so the `skill.create` tool installs skills through the
// exact same reviewed pipeline as the on-device UI.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeSkills

@MainActor
struct LocalSkillCreator: SkillCreating, SkillManaging {
    private let center: SkillsCenter

    init(center: SkillsCenter) {
        self.center = center
    }

    func create(_ request: SkillCreationRequest) async throws -> CreatedSkill {
        try await center.createSkill(request)
    }
    func read(id: String?) async throws -> [ManagedSkill] { try await center.readSkills(id: id) }
    func manage(_ request: SkillManageTool.Arguments) async throws -> String { try await center.manageSkill(request) }
}
#endif
