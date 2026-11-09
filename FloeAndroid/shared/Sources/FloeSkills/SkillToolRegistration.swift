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
    manager: (any SkillManaging)? = nil,
    isAvailable: @escaping @Sendable () -> Bool = { true }
) -> any SkillCreating {
    func register<T: AgentTool>(_ tool: T) {
        ToolCatalog.register(T.self)
        var runner = AnyAgentTool(tool)
        runner.isAvailable = isAvailable
        registry.register(runner)
    }
    register(SkillCreateTool(creator: creator))
    if let manager {
        register(SkillListTool(manager: manager))
        register(SkillReadTool(manager: manager))
        register(SkillSearchTool(manager: manager))
        register(SkillManageTool(manager: manager))
    }
    return creator
}
