// Focused behavioral regression for the run-mode tool-discovery base.
//
// The base sets are presentation preference only: the runtime intersects them
// with the live, availability-filtered catalog and, for Plan, with
// PlanToolPolicy. These tests pin that an ordinary cloud Agent run reaches
// the real memory/workspace/conversation/jobs/user.ask capabilities without a
// discovery round-trip, that Plan sees only its read-only investigation set
// plus the exact policy-approved internal tools (user.ask,
// checklist.resetPlan and the three durable-memory writes), and that the Chinese
// workspace-operation ordering never overrides web intent or invents a tool.
// Registered in the shared package's FloeAgentRuntimeTests target; it does
// not build or drive the Android App.

import Foundation
import XCTest
import FloeTools
@testable import FloeAgentRuntime

final class ToolDiscoveryModeBaseTests: XCTestCase {
    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "description for \(name)",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    private var userAskDescriptor: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: UserAskTool.name,
            toolDescription: UserAskTool.toolDescription,
            parametersJSON: UserAskTool.parametersJSON,
            riskLabels: UserAskTool.riskLabels,
            isSideEffecting: UserAskTool.isSideEffecting,
            effect: UserAskTool.toolEffect,
            requiresHostScope: UserAskTool.requiresHostScope,
            executionBoundary: UserAskTool.executionBoundary
        )
    }

    private var resetPlanDescriptor: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: TaskResetPlanTool.name,
            toolDescription: TaskResetPlanTool.toolDescription,
            parametersJSON: TaskResetPlanTool.parametersJSON,
            riskLabels: TaskResetPlanTool.riskLabels,
            isSideEffecting: TaskResetPlanTool.isSideEffecting,
            effect: TaskResetPlanTool.toolEffect,
            requiresHostScope: TaskResetPlanTool.requiresHostScope,
            executionBoundary: TaskResetPlanTool.executionBoundary
        )
    }

    private var mutatingExecShell: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: "exec.shell",
            toolDescription: "shell",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: [.writesFiles, .executesLocalCode],
            isSideEffecting: true,
            effect: .mutating
        )
    }

    private var mutatingWorkspaceWrite: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: "workspace.writeFile",
            toolDescription: "write",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: [.writesFiles],
            isSideEffecting: true,
            effect: .mutating
        )
    }

    private func memoryWriteDescriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "durable memory",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: [.persistsPersonalData],
            isSideEffecting: true,
            effect: .internalState
        )
    }

    private var internalStateChecklistUpdate: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: TaskUpdatePlanTool.name,
            toolDescription: TaskUpdatePlanTool.toolDescription,
            parametersJSON: TaskUpdatePlanTool.parametersJSON,
            riskLabels: TaskUpdatePlanTool.riskLabels,
            isSideEffecting: TaskUpdatePlanTool.isSideEffecting,
            effect: TaskUpdatePlanTool.toolEffect,
            requiresHostScope: TaskUpdatePlanTool.requiresHostScope,
            executionBoundary: TaskUpdatePlanTool.executionBoundary
        )
    }

    // MARK: Agent base

    func testOrdinaryCloudAgentBaseCarriesTheRealMemoryWorkspaceConversationJobsAndUserAskSet() {
        let names = ToolDiscovery.baseNames(mode: .chat, isLocalProvider: false)
        for expected in [
            "memory.search", "memory.recall", "memory.list",
            "memory.remember", "memory.update", "memory.forget",
            "workspace.listDirectory", "workspace.searchFiles", "workspace.readFile",
            "workspace.inspectFileMetadata", "workspace.createFile", "workspace.appendFile",
            "workspace.replaceText", "workspace.writeFile", "workspace.applyPatch",
            "workspace.createDirectory", "workspace.copyFile", "workspace.moveFile",
            "workspace.deleteFile", "workspace.publishOutput",
            "conversation.list", "conversation.search", "conversation.read", "conversation.spawn",
            "jobs.submit", "jobs.status", "jobs.result", "jobs.cancel",
            "delegate", "task.schedule", "user.ask", "checklist.resetPlan",
            "skill.search", "skill.read", "skill.list", "checklist.readPlan", "exec.shell",
        ] {
            XCTAssertTrue(names.contains(expected), "Agent base must reach \(expected)")
        }
        XCTAssertEqual(
            ToolDiscovery.baseNames(mode: .goal, isLocalProvider: false),
            names,
            "Goal runs execute through the same ordinary cloud Agent base"
        )
    }

    func testOnDeviceProviderKeepsItsCuratedSeedInsteadOfTheCloudBase() {
        XCTAssertEqual(
            ToolDiscovery.baseNames(mode: .chat, isLocalProvider: true),
            ToolDiscovery.coreNames
        )
        XCTAssertEqual(
            ToolDiscovery.baseNames(mode: .plan, isLocalProvider: true),
            ToolDiscovery.coreNames
        )
        XCTAssertFalse(ToolDiscovery.coreNames.contains("workspace.writeFile"))
        XCTAssertFalse(ToolDiscovery.coreNames.contains("user.ask"))
    }

    func testBaseSetsNeverAdvertiseIOSOnlyOrRetiredCapabilities() {
        let forbidden: Set<String> = [
            // iOS-only registrations; Android has no such tools.
            "chat.present", "chat.content.list", "conversation.message",
            "workspace.importOutput", "goal.create", "goal.read", "task.wait",
            // Retired execution aliases must never resurface through discovery.
            "exec.localPython", "exec.javascript", "exec.compatEvaluator",
            "exec.wasm", "python.packages", "wasm.packages",
        ]
        for mode in ConversationMode.allCases {
            let names = ToolDiscovery.baseNames(mode: mode, isLocalProvider: false)
            XCTAssertTrue(names.isDisjoint(with: forbidden),
                          "\(mode) base leaked \(names.intersection(forbidden))")
        }
    }

    // MARK: Plan base

    func testPlanBaseCombinesReadOnlyInvestigationWithOnlyTheApprovedInternalTools() {
        let names = ToolDiscovery.baseNames(mode: .plan, isLocalProvider: false)
        for expected in [
            "skill.list", "skill.search", "skill.read",
            "checklist.readPlan", "checklist.resetPlan", "user.ask",
            "web.search", "web.fetch",
            "workspace.listDirectory", "workspace.searchFiles", "workspace.readFile",
            "workspace.inspectFileMetadata",
            "conversation.list", "conversation.search", "conversation.read",
            "git.status", "git.diff", "git.log",
            "memory.search", "memory.recall", "memory.list",
            "memory.remember", "memory.update", "memory.forget",
        ] {
            XCTAssertTrue(names.contains(expected), "Plan base must reach \(expected)")
        }
        // No mutating execution and no internal state outside the closed,
        // policy-checked exceptions (user.ask, checklist.resetPlan and the
        // three exact durable-memory writes above).
        for forbidden in ["exec.shell", "workspace.writeFile", "workspace.createFile",
                          "jobs.submit", "conversation.spawn", "delegate",
                          "checklist.updatePlan", "memory.batchApply", "memory.organizePreview",
                          "task.schedule"] {
            XCTAssertFalse(names.contains(forbidden), "Plan base must not preload \(forbidden)")
        }
    }

    func testPlanBaseSurvivesTheCatalogProjectionForExactlyTheApprovedTools() {
        let catalog = [
            userAskDescriptor, resetPlanDescriptor, internalStateChecklistUpdate,
            mutatingExecShell, mutatingWorkspaceWrite,
            descriptor("workspace.readFile"), descriptor("memory.search"),
            memoryWriteDescriptor("memory.remember"),
            memoryWriteDescriptor("memory.update"),
            memoryWriteDescriptor("memory.forget"),
        ]
        let projected = PlanToolPolicy().allowedDescriptors(from: catalog)
            .filter { ToolDiscovery.planCoreNames.contains($0.name) }
        XCTAssertEqual(
            Set(projected.map(\.name)),
            ["user.ask", "checklist.resetPlan", "workspace.readFile", "memory.search",
             "memory.remember", "memory.update", "memory.forget"]
        )
    }

    func testAgentBaseNeverWidensTheLiveCatalog() {
        // The runtime applies the base as a filter over already-projected
        // descriptors; a base name absent from the live catalog stays absent.
        let live = [descriptor("workspace.readFile"), descriptor("skill.search")]
        let base = ToolDiscovery.baseNames(mode: .chat, isLocalProvider: false)
        XCTAssertEqual(
            live.filter { base.contains($0.name) }.map(\.name),
            ["workspace.readFile", "skill.search"]
        )
    }

    func testPlanMemoryExceptionNeverReachesTemporaryChatProjection() throws {
        let remember = memoryWriteDescriptor("memory.remember")
        // The ordinary Plan policy permits the exact durable-memory write.
        XCTAssertNoThrow(try PlanToolPolicy().decision(for: remember).get())
        // A temporary conversation keeps its frozen public-web-only ceiling:
        // the projection drops the descriptor and the executor-side reason
        // refuses the call, independently of the Plan policy.
        XCTAssertNil(TemporaryChatToolPolicy.readOnlyDescriptor(remember))
        XCTAssertFalse(TemporaryChatToolPolicy.allowedToolNames(from: [remember]).contains("memory.remember"))
        XCTAssertNotNil(TemporaryChatToolPolicy.denialReason(
            descriptor: remember, arguments: Data(#"{"content":"x"}"#.utf8)))
    }

    // MARK: Chinese workspace-operation ordering

    func testNamedChineseFileOperationLeadsItsWorkspaceNamespace() {
        let descriptors = [
            descriptor("workspace.archive"),
            descriptor("workspace.copyFile"),
            descriptor("workspace.moveFile"),
            descriptor("workspace.readFile"),
            descriptor("workspace.replaceText"),
            descriptor("workspace.searchFiles"),
        ]
        let matched = ToolDiscovery.matches(query: "把工作区文件解压", descriptors: descriptors)
        XCTAssertEqual(matched.first?.name, "workspace.archive")
        XCTAssertEqual(Set(matched.map(\.name)).count, matched.count, "no duplicate entries")
        XCTAssertTrue(matched.contains { $0.name == "workspace.readFile" },
                      "the rest of the workspace namespace stays discoverable")
    }

    func testBareChineseOperationSelectsTheSpecificTool() {
        XCTAssertEqual(ToolDiscovery.workspaceOperationNames(in: "复制"), ["workspace.copyFile"])
        XCTAssertEqual(ToolDiscovery.workspaceOperationNames(in: "追加文件"), ["workspace.appendFile"])
        XCTAssertEqual(ToolDiscovery.workspaceOperationNames(in: "替换工作区文件中的文本"),
                       ["workspace.replaceText"])
        XCTAssertEqual(ToolDiscovery.workspaceOperationNames(in: "用例文件/unzip 归档"),
                       ["workspace.archive"])
    }

    func testWebSearchKeepsItsWebMeaning() {
        XCTAssertTrue(ToolDiscovery.workspaceOperationNames(in: "搜索网页").isEmpty)
        let descriptors = [
            descriptor("web.search"),
            descriptor("web.fetch"),
            descriptor("workspace.searchFiles"),
            descriptor("workspace.readFile"),
        ]
        let matched = ToolDiscovery.matches(query: "搜索网页", descriptors: descriptors)
        XCTAssertEqual(matched.first?.name, "web.search")
        XCTAssertFalse(matched.contains { $0.name == "workspace.searchFiles" },
                       "an unnamed file operation must not be pulled into a web query")
    }

    func testWorkspaceOperationOrderingNeverInventsAnAbsentTool() {
        let descriptors = [descriptor("workspace.readFile"), descriptor("web.search")]
        let matched = ToolDiscovery.matches(query: "解压压缩包", descriptors: descriptors)
        XCTAssertFalse(matched.contains { $0.name == "workspace.archive" })
        XCTAssertTrue(matched.allSatisfy { descriptors.map(\.name).contains($0.name) })
    }
}
