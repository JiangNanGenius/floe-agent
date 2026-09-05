// FloeSkills — skill tool registration entry point.
//
// Same dual-registration seam as the execution/workspace tools: the
// compile-time Descriptor goes to ToolCatalog and the runtime runner to
// ToolRunnerRegistry. The creator is injected so the app supplies the real
// assembly + persistence pipeline while tests inject fakes.

import Foundation
import FloeTools

/// Registers the `skill.create` tool. Returns the creator for chaining.
@discardableResult
public func registerSkillTools(
    registry: ToolRunnerRegistry = .shared,
    creator: any SkillCreating,
    manager: (any SkillManaging)? = nil
) -> any SkillCreating {
    ToolCatalog.register(SkillCreateTool.self)
    registry.register(SkillCreateTool(creator: creator))
    if let manager {
        ToolCatalog.register(SkillReadTool.self)
        ToolCatalog.register(SkillManageTool.self)
        registry.register(SkillReadTool(manager: manager))
        registry.register(SkillManageTool(manager: manager))
    }
    return creator
}
