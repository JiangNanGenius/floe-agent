// Focused behavioral regression for the Plan-mode capability boundary.
//
// Plan stays read-only except for the two exact main-run-native descriptors
// (`user.ask`, `checklist.resetPlan`) the runtime can really execute. This
// suite pins the descriptor identity checks so a broader internal-state
// opening (or an iOS-only memory-write exception) cannot slip in unnoticed.
// Registered in the shared package's FloeAgentRuntimeTests target; it does
// not build or drive the Android App.

import Foundation
import XCTest
import FloeTools
@testable import FloeAgentRuntime

final class PlanToolPolicyTests: XCTestCase {
    private func descriptor(
        _ name: String,
        effect: ToolEffect,
        riskLabels: Set<RiskLabel> = [],
        isSideEffecting: Bool = false,
        requiresHostScope: Bool = false,
        boundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "test descriptor for \(name)",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect,
            requiresHostScope: requiresHostScope,
            executionBoundary: boundary
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

    private func memoryDescriptor(
        _ name: String,
        effect: ToolEffect = .internalState,
        riskLabels: Set<RiskLabel> = [.persistsPersonalData],
        isSideEffecting: Bool = true,
        requiresHostScope: Bool = false,
        boundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        descriptor(name, effect: effect, riskLabels: riskLabels,
                   isSideEffecting: isSideEffecting,
                   requiresHostScope: requiresHostScope, boundary: boundary)
    }

    // MARK: Exact internal-state exceptions

    func testNativeQuestionAndChecklistResetPassWithTheirExactDescriptors() throws {
        let policy = PlanToolPolicy()
        XCTAssertNoThrow(try policy.decision(for: userAskDescriptor).get())
        XCTAssertNoThrow(try policy.decision(for: resetPlanDescriptor).get())
        // The same decision feeds executor-side denial; a permitted
        // descriptor is never rewritten into a denied receipt.
        if case .failure = policy.decision(for: userAskDescriptor) {
            XCTFail("user.ask must be permitted in Plan")
        }
    }

    func testUserAskLosesTheExceptionWhenItsDescriptorIdentityChanges() {
        let policy = PlanToolPolicy()
        let variants: [ToolCatalog.Descriptor] = [
            descriptor(UserAskTool.name, effect: .internalState, boundary: .any),
            descriptor(UserAskTool.name, effect: .internalState, isSideEffecting: true, boundary: .mainRunOnly),
            descriptor(UserAskTool.name, effect: .internalState,
                       riskLabels: [.persistsPersonalData], boundary: .mainRunOnly),
            descriptor(UserAskTool.name, effect: .internalState, requiresHostScope: true, boundary: .mainRunOnly),
            descriptor(UserAskTool.name, effect: .internalState, boundary: .childOnly),
        ]
        for variant in variants {
            guard case .failure(let error) = policy.decision(for: variant) else {
                return XCTFail("\(variant.name) with changed identity must stay denied in Plan")
            }
            XCTAssertEqual(error.reason, .internalStateNotModelCallable)
        }
    }

    func testDurableMemoryWritesPassOnlyWithTheirExactRegisteredIdentity() {
        let policy = PlanToolPolicy()
        for name in ["memory.remember", "memory.update", "memory.forget"] {
            XCTAssertNoThrow(
                try policy.decision(for: memoryDescriptor(name)).get(),
                "\(name) must follow the latest iOS plan/chat memory rule"
            )
        }
        // Android registers exactly the same descriptor identity: internal
        // state, side-effecting, only persisted-personal-data, any run, no
        // host scope. Any other shape loses the exception.
        let variants: [ToolCatalog.Descriptor] = [
            memoryDescriptor("memory.remember", effect: .readOnly),
            memoryDescriptor("memory.remember", effect: .mutating),
            memoryDescriptor("memory.remember", isSideEffecting: false),
            memoryDescriptor("memory.remember", riskLabels: []),
            memoryDescriptor("memory.remember", riskLabels: [.persistsPersonalData, .writesFiles]),
            memoryDescriptor("memory.remember", boundary: .mainRunOnly),
            memoryDescriptor("memory.remember", requiresHostScope: true),
        ]
        for variant in variants {
            guard case .failure = policy.decision(for: variant) else {
                return XCTFail("a changed memory descriptor must not inherit Plan write authority")
            }
        }
        // The sibling batch-maintenance writer stays outside the closed
        // three-name exception and remains denied.
        guard case .failure(let error) = policy.decision(for: memoryDescriptor("memory.batchApply")) else {
            return XCTFail("memory.batchApply must stay denied in Plan")
        }
        XCTAssertEqual(error.reason, .internalStateNotModelCallable)
    }

    func testOtherInternalStateToolsStayDeniedIncludingChecklistUpdateAndSpawn() {
        let policy = PlanToolPolicy()
        let updatePlan = descriptor(
            TaskUpdatePlanTool.name, effect: .internalState, boundary: .mainRunOnly)
        guard case .failure(let updateError) = policy.decision(for: updatePlan) else {
            return XCTFail("checklist.updatePlan must stay unavailable in Plan")
        }
        XCTAssertEqual(updateError.reason, .internalStateNotModelCallable)

        for name in ["conversation.spawn", "jobs.cancel", "delegate"] {
            let internalState = memoryDescriptor(name, riskLabels: [])
            guard case .failure(let error) = policy.decision(for: internalState) else {
                return XCTFail("\(name) must stay denied in Plan")
            }
            XCTAssertEqual(error.reason, .internalStateNotModelCallable)
        }
    }

    // MARK: Read-only and mutating

    func testOrdinaryReadOnlyDescriptorIsAllowed() throws {
        XCTAssertNoThrow(try PlanToolPolicy().decision(
            for: descriptor("workspace.readFile", effect: .readOnly)).get())
        XCTAssertNoThrow(try PlanToolPolicy().decision(
            for: descriptor("web.search", effect: .readOnly,
                            riskLabels: [.networkAccess])).get())
    }

    func testContradictoryOrMutatingDescriptorsFailClosed() {
        let policy = PlanToolPolicy()
        let readOnlyButSideEffecting = descriptor(
            "workspace.readFile", effect: .readOnly, isSideEffecting: true)
        let readOnlyButWritesFiles = descriptor(
            "workspace.readFile", effect: .readOnly, riskLabels: [.writesFiles])
        let mutating = descriptor("exec.shell", effect: .mutating, isSideEffecting: true)
        for denied in [readOnlyButSideEffecting, readOnlyButWritesFiles, mutating] {
            guard case .failure(let error) = policy.decision(for: denied) else {
                return XCTFail("\(denied.name) must be denied in Plan")
            }
            XCTAssertEqual(error.reason, .mutationNotAllowed)
        }
    }

    func testAllowedDescriptorsProjectsTheDecisionNotTheEffectLabelAlone() {
        let descriptors = [
            descriptor("workspace.readFile", effect: .readOnly),
            descriptor("workspace.writeFile", effect: .mutating, isSideEffecting: true),
            descriptor("exec.shell", effect: .mutating, isSideEffecting: true),
            descriptor(TaskUpdatePlanTool.name, effect: .internalState, boundary: .mainRunOnly),
            memoryDescriptor("memory.remember"),
            memoryDescriptor("memory.batchApply"),
            userAskDescriptor,
            resetPlanDescriptor,
        ]
        let allowed = Set(PlanToolPolicy().allowedDescriptors(from: descriptors).map(\.name))
        XCTAssertEqual(allowed, [
            "workspace.readFile", "memory.remember",
            UserAskTool.name, TaskResetPlanTool.name,
        ])
    }
}
