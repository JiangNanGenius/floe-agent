// FloeToolsTests — no-wrapper-bypass capability metadata.
//
// Delegation is main-run only, and that must hold through every wrapper
// layer: the type-erased runner registry, the jobs.submit target table and
// the visible-task spawner. These tests assert the ACTUAL registered
// descriptors, not the static tool declarations.

import Foundation
import Testing
import FloeExecution
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeTools.ChildDelegationCapability")
struct ChildDelegationCapabilityTests {
    @Test("main-only/child-only boundaries survive the type-erased registry entry")
    func registryPreservesBoundaryMetadata() {
        let registry = ToolRunnerRegistry()
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        #expect(registry.descriptor(named: "delegate")?.executionBoundary == .mainRunOnly)
        #expect(registry.descriptor(named: "delegate")?.supportsConcurrentBatchDispatch == true)
        #expect(registry.descriptor(named: "delegate")?.isSideEffecting == true)
        #expect(registry.descriptor(named: "delegate")?.effect == .mutating)
        #expect(registry.descriptor(named: "delegate.peers")?.executionBoundary == .childOnly)
        #expect(registry.descriptor(named: "delegate.message")?.executionBoundary == .childOnly)
    }

    @Test("jobs.* cannot be used as a delegation wrapper")
    func jobsCannotTargetDelegation() {
        #expect(!BackgroundJobService.supportedTargets.contains("delegate"))
        #expect(!BackgroundJobService.supportedTargets.contains(DelegateTool.name))
        #expect(!BackgroundJobService.supportedTargets.contains(ConversationSpawnTool.name))
        #expect(!BackgroundJobService.supportedTargets.contains("delegate.peers"))
        #expect(!BackgroundJobService.supportedTargets.contains("delegate.message"))
        #expect(!BackgroundJobService.supportedTargets.contains("conversation.spawn"))
    }

    @Test("the visible-task spawner is main-run only")
    func spawnIsMainOnly() {
        #expect(ConversationSpawnTool.executionBoundary == .mainRunOnly)
    }
}
