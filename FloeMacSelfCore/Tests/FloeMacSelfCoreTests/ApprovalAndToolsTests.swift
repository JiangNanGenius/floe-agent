// SPDX-License-Identifier: MPL-2.0
//
// Approval and tool-capability tests exercise the real Floe policy/gate path
// with a synthetic provider and a recording executor. The synthetic provider
// is a test double; production sessions always require a host adapter.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

private struct DuplicateDescriptorToolExecutor: ToolExecutor {
    let descriptor: ToolCatalog.Descriptor

    var allDescriptors: [ToolCatalog.Descriptor] { [descriptor, descriptor] }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        name == descriptor.name ? descriptor : nil
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        Issue.record("An executor with a duplicate catalog must never execute")
        return ToolResult(callID: call.id, status: .denied, outputSummary: "denied", outputDigest: "")
    }
}

@Suite("Mac self-owned runtime approvals and tools")
struct ApprovalAndToolsTests {

    @Test("A duplicate executor descriptor is rejected without starting a run")
    func duplicateToolDescriptorsFailClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Duplicate tool workspace")
            let (provider, _) = fixture.makeProvider(scripts: [])
            let (base, _, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let binding = FloeMacSelfToolBinding(
                executor: DuplicateDescriptorToolExecutor(descriptor: SelfCoreFixture.fixtureDescriptor),
                policy: base.policy,
                gate: base.gate,
                auditSink: base.auditSink,
                boundary: base.boundary,
                allowedToolNames: base.allowedToolNames,
                hostGate: base.hostGate
            )
            let request = fixture.newConversationRequest(
                goal: "Try duplicate tool descriptors",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: provider, tools: binding)
            }
            #expect(error == .toolCapabilityUnavailable("the executor catalog contains duplicate tool names"))
            #expect(try await fixture.runtime.nonTerminalRuns().isEmpty)
        }
    }

    @Test("An exact-run allow reaches the real policy, executes once, and completes")
    func allowExecutesExactToolAndCompletes() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Approval workspace")
            let call = try SelfCoreFixture.fixtureCall()
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "Approved and finished.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, executor, audit) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let request = fixture.newConversationRequest(
                goal: "Write the fixture",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let handle = try await fixture.runtime.startSession(request, provider: provider, tools: tools)
            #expect(handle.identity.toolsEnabled)

            let waiting = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.pendingApproval != nil
            }
            #expect(waiting)
            let snapshot = try #require(await handle.snapshot())
            let pending = try #require(snapshot.pendingApproval)
            #expect(pending.toolCall.id == call.id)
            #expect(pending.toolCall.toolName == call.toolName)

            let wrongConversation = FloeMacSelfApprovalCommand(
                conversationID: UUID(),
                runID: handle.identity.runID,
                workspaceID: handle.identity.workspaceID,
                callID: pending.toolCall.id,
                toolName: pending.toolCall.toolName,
                decision: .deny(reason: "wrong conversation")
            )
            let wrongConversationResult = await handle.resolveApproval(wrongConversation)
            #expect(wrongConversationResult == .rejected(.conversationMismatch))

            let wrongRun = FloeMacSelfApprovalCommand(
                conversationID: handle.identity.conversationID,
                runID: UUID(),
                workspaceID: handle.identity.workspaceID,
                callID: pending.toolCall.id,
                toolName: pending.toolCall.toolName,
                decision: .deny(reason: "wrong run")
            )
            let wrongRunResult = await handle.resolveApproval(wrongRun)
            #expect(wrongRunResult == .rejected(.runMismatch))

            let wrongWorkspace = FloeMacSelfApprovalCommand(
                conversationID: handle.identity.conversationID,
                runID: handle.identity.runID,
                workspaceID: UUID(),
                callID: pending.toolCall.id,
                toolName: pending.toolCall.toolName,
                decision: .deny(reason: "wrong workspace")
            )
            let wrongWorkspaceResult = await handle.resolveApproval(wrongWorkspace)
            #expect(wrongWorkspaceResult == .rejected(.workspaceMismatch))

            let wrongCall = FloeMacSelfApprovalCommand(
                conversationID: handle.identity.conversationID,
                runID: handle.identity.runID,
                workspaceID: handle.identity.workspaceID,
                callID: "call-not-pending",
                toolName: pending.toolCall.toolName,
                decision: .deny(reason: "wrong call")
            )
            let wrongCallResult = await handle.resolveApproval(wrongCall)
            #expect(wrongCallResult == .rejected(.callMismatch))

            let wrongTool = FloeMacSelfApprovalCommand(
                conversationID: handle.identity.conversationID,
                runID: handle.identity.runID,
                workspaceID: handle.identity.workspaceID,
                callID: pending.toolCall.id,
                toolName: "fixture.other",
                decision: .deny(reason: "wrong tool")
            )
            let wrongToolResult = await handle.resolveApproval(wrongTool)
            #expect(wrongToolResult == .rejected(.toolMismatch))

            let allow = approvalCommand(
                handle: handle,
                pending: pending,
                decision: .allow(
                    scope: ApprovalScope(toolName: pending.toolCall.toolName, singleUse: true),
                    expiresAt: nil
                )
            )
            let allowResult = await handle.resolveApproval(allow)
            #expect(allowResult == .accepted)

            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            #expect(executor.executedCalls.map(\.id) == [call.id])

            let auditEntries = audit.entries
            #expect(auditEntries.contains {
                $0.toolName == pending.toolCall.toolName && $0.decision.hasPrefix("allow")
            })

            let durableEvents = try await handle.durableEvents()
            #expect(durableEvents.contains { $0.kind == .approval })
            #expect(durableEvents.contains { $0.kind == .toolResult })

            let stale = await handle.resolveApproval(allow)
            #expect(stale == .rejected(.sessionEnded))

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("A deny is accepted by the runtime, is audited, and never reaches the executor")
    func deniedApprovalPreventsExecution() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Denial workspace")
            let call = try SelfCoreFixture.fixtureCall(id: "call-fixture-deny")
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "The action was denied.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, executor, audit) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let request = fixture.newConversationRequest(
                goal: "Attempt the fixture write",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let handle = try await fixture.runtime.startSession(request, provider: provider, tools: tools)

            let waiting = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.pendingApproval != nil
            }
            #expect(waiting)
            let snapshot = try #require(await handle.snapshot())
            let pending = try #require(snapshot.pendingApproval)
            #expect(pending.toolCall.id == call.id)

            let deny = approvalCommand(
                handle: handle,
                pending: pending,
                decision: .deny(reason: "fixture denial")
            )
            let denyResult = await handle.resolveApproval(deny)
            #expect(denyResult == .accepted)

            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            #expect(executor.executedCalls.isEmpty)
            #expect(audit.entries.contains {
                $0.toolName == pending.toolCall.toolName && $0.decision.hasPrefix("deny")
            })

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("A tool-disabled session has no executor capability and its policy denies by construction")
    func toolsDisabledFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let call = try SelfCoreFixture.fixtureCall(id: "call-fixture-no-tools")
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "No tools were available.")), .completed(.init(stopReason: .endTurn))],
            ])
            let request = fixture.newConversationRequest(goal: "Try an unavailable tool")
            let handle = try await fixture.runtime.startSession(request, provider: provider)
            #expect(handle.identity.toolsEnabled == false)

            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)

            let deniedExecutor = FloeMacSelfDeniedToolExecutor()
            #expect(deniedExecutor.descriptor(named: SelfCoreFixture.fixtureToolName) == nil)
            #expect(deniedExecutor.allDescriptors.isEmpty)
            let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
            let result = try await deniedExecutor.execute(call, context: context)
            #expect(result.status == .denied)

            let action = ProposedAction(
                toolCall: call,
                riskLabels: ["writesFiles"],
                userGoal: "fixture goal",
                hostAndPathScope: .local
            )
            let decision = try await FloeMacSelfToolsDisabledPolicy().decide(action)
            if case .deny = decision {
                // Expected: the deny-only policy never allows anything.
            } else {
                Issue.record("The tool-disabled policy must deny, got \(decision.logLabel)")
            }
        }
    }

    @Test("Host-scoped tools are rejected before a run is created")
    func hostScopedToolRejected() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Host tool workspace")
            let (provider, _) = fixture.makeProvider(scripts: [])
            let (tools, _, _) = try fixture.makeToolBinding(
                workspaceID: workspaceID,
                allowedToolNames: ["fixture.remote"],
                descriptor: SelfCoreFixture.hostScopedDescriptor()
            )
            let request = fixture.newConversationRequest(
                goal: "Try a host tool",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: provider, tools: tools)
            }
            #expect(error?.code == "toolCapabilityUnavailable")

            let runs = try await fixture.runtime.nonTerminalRuns()
            #expect(runs.isEmpty)
        }
    }

    @Test("A typed environment ownership is not silently treated as native")
    func environmentOwnershipFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Environment workspace")
            let (provider, _) = fixture.makeProvider(scripts: [])
            let (tools, _, _) = try fixture.makeToolBinding(
                workspaceID: workspaceID,
                ownership: .environment(id: "env-fixture", binding: nil, localLinuxGuest: false)
            )
            let request = fixture.newConversationRequest(
                goal: "Try a guest environment",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: provider, tools: tools)
            }
            #expect(error?.code == "executionEnvironmentUnsupported")
        }
    }

    @Test("A model without the tools capability cannot start a tool-enabled session")
    func modelWithoutToolsRejected() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "No-tools model workspace")
            let (provider, _) = fixture.makeProvider(scripts: [], capabilities: [.text])
            let (tools, _, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let request = fixture.newConversationRequest(
                goal: "Try tools on a text-only model",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: provider, tools: tools)
            }
            #expect(error?.code == "modelDoesNotSupportTools")
        }
    }

    @Test("Adapter protocol, provider/model ownership, and workspace roots are validated before launch")
    func invalidCapabilityBindingsFailClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let mismatchAdapter = fixture.makeProvider(scripts: [], protocolKind: .anthropicMessages)
            let mismatchRequest = fixture.newConversationRequest(goal: "Protocol mismatch")
            let mismatchError = await selfCoreError {
                _ = try await fixture.runtime.startSession(mismatchRequest, provider: mismatchAdapter.binding)
            }
            #expect(mismatchError?.code == "adapterProtocolMismatch")

            let (base, _) = fixture.makeProvider(scripts: [])
            let foreignModel = ModelProfile(
                providerID: UUID(),
                remoteModelID: "fixture-model",
                displayName: "Foreign Model",
                limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
                capabilities: [.text, .tools],
                isEnabled: true
            )
            let foreignBinding = FloeMacSelfProviderBinding(
                provider: base.provider,
                model: foreignModel,
                adapter: base.adapter,
                credentials: base.credentials
            )
            let foreignRequest = fixture.newConversationRequest(goal: "Foreign model")
            let foreignError = await selfCoreError {
                _ = try await fixture.runtime.startSession(foreignRequest, provider: foreignBinding)
            }
            #expect(foreignError?.code == "providerUnavailable")

            let workspaceID = try await fixture.createWorkspace(named: "Boundary workspace")
            let (provider, _) = fixture.makeProvider(scripts: [])
            let missingRoot = fixture.root.appendingPathComponent("missing-root", isDirectory: true)
            let (missingTools, _, _) = try fixture.makeToolBinding(
                workspaceID: workspaceID,
                boundaryRoot: missingRoot
            )
            let missingRequest = fixture.newConversationRequest(
                goal: "Missing workspace root",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let missingError = await selfCoreError {
                _ = try await fixture.runtime.startSession(
                    missingRequest,
                    provider: provider,
                    tools: missingTools
                )
            }
            #expect(missingError?.code == "invalidTaskBoundary")

            let absolutePathBoundary = FloeMacSelfTaskBoundary(
                workspaceID: workspaceID,
                workspaceRootURL: fixture.workspaceRoot,
                allowedWorkspacePaths: ["/etc/passwd"],
                ownership: .nativeHost
            )
            let absolutePathBinding = FloeMacSelfToolBinding(
                executor: RecordingToolExecutor(descriptors: [SelfCoreFixture.fixtureDescriptor]),
                policy: HumanApprovalPolicy(),
                gate: try CatastrophicActionGate.withBundledPatterns(),
                boundary: absolutePathBoundary,
                allowedToolNames: [SelfCoreFixture.fixtureToolName],
                hostGate: fixture.makeHostGate(
                    workspaceID: workspaceID,
                    allowedToolNames: [SelfCoreFixture.fixtureToolName]
                )
            )
            let absolutePathRequest = fixture.newConversationRequest(
                goal: "Absolute path ceiling",
                workspaceID: workspaceID,
                chatFastMode: false
            )
            let absolutePathError = await selfCoreError {
                _ = try await fixture.runtime.startSession(
                    absolutePathRequest,
                    provider: provider,
                    tools: absolutePathBinding
                )
            }
            #expect(absolutePathError?.code == "invalidTaskBoundary")

            let runs = try await fixture.runtime.nonTerminalRuns()
            #expect(runs.isEmpty)
        }
    }

    @Test("A stale duplicate model profile cannot silently rebind a durable model row")
    func duplicateModelIdentityFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let (firstProvider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "First model run.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let firstHandle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "First canonical model run"),
                provider: firstProvider
            )
            let firstTerminal = try #require(await firstHandle.waitForTerminal(timeout: 15))
            #expect(firstTerminal.confirmed)
            _ = try await firstHandle.close()

            let duplicateModel = ModelProfile(
                providerID: firstProvider.provider.id,
                remoteModelID: firstProvider.model.remoteModelID,
                displayName: "Duplicate Fixture Model",
                limits: firstProvider.model.limits,
                capabilities: [.text, .tools],
                isEnabled: true
            )
            let duplicateBinding = FloeMacSelfProviderBinding(
                provider: firstProvider.provider,
                model: duplicateModel,
                adapter: firstProvider.adapter,
                credentials: firstProvider.credentials
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(
                    fixture.newConversationRequest(goal: "Duplicate model identity"),
                    provider: duplicateBinding
                )
            }
            #expect(error?.code == "preparedIdentityMismatch")
            // The post-prepare identity mismatch must not leave a non-terminal
            // run or an unresolved admission: it is proven pre-dispatch, so
            // the composition records an aborted terminal run instead of
            // silently releasing an unknown claim.
            #expect(try await fixture.runtime.nonTerminalRuns().isEmpty)
            #expect(try await fixture.runtime.unresolvedAdmissions().isEmpty)
        }
    }

    @Test("A mismatched host gate fails before any durable admission or run")
    func mismatchedHostGateFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Gate workspace")
            let (provider, _) = fixture.makeProvider(scripts: [])
            let conversationID = UUID()
            let badGate = fixture.makeHostGate(
                workspaceID: workspaceID,
                allowedToolNames: ["fixture.other"]
            )
            let (tools, _, _) = try fixture.makeToolBinding(
                workspaceID: workspaceID,
                hostGate: badGate
            )
            let request = FloeMacSelfSessionRequest(
                newConversationID: conversationID,
                workspaceID: workspaceID,
                goal: "Bad host gate",
                chatFastMode: false
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(
                    request,
                    provider: provider,
                    tools: tools
                )
            }
            #expect(error == .hostGateMismatch("the gate tool set differs from the executor ceiling"))
            #expect(try await fixture.runtime.admissionRecord(conversationID: conversationID) == nil)
            #expect(try await fixture.runtime.nonTerminalRuns().isEmpty)
        }
    }

    @Test("Approval commands from one run cannot resolve another run's pending card")
    func approvalCommandsCannotCrossSessions() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Cross-session workspace")

            let callA = try SelfCoreFixture.fixtureCall(id: "call-session-a")
            let (providerA, _) = fixture.makeProvider(scripts: [
                [.toolRequest(callA), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "A finished.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (toolsA, executorA, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let handleA = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Session A", workspaceID: workspaceID, chatFastMode: false),
                provider: providerA,
                tools: toolsA
            )

            let callB = try SelfCoreFixture.fixtureCall(id: "call-session-b")
            let (providerB, _) = fixture.makeProvider(scripts: [
                [.toolRequest(callB), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "The action was denied.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (toolsB, executorB, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let handleB = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Session B", workspaceID: workspaceID, chatFastMode: false),
                provider: providerB,
                tools: toolsB
            )

            let waitingA = await eventually {
                let snapshot = await handleA.snapshot()
                return snapshot?.pendingApproval != nil
            }
            let waitingB = await eventually {
                let snapshot = await handleB.snapshot()
                return snapshot?.pendingApproval != nil
            }
            #expect(waitingA && waitingB)
            let snapshotA = try #require(await handleA.snapshot())
            let pendingA = try #require(snapshotA.pendingApproval)
            let snapshotB = try #require(await handleB.snapshot())
            let pendingB = try #require(snapshotB.pendingApproval)

            let allowA = approvalCommand(
                handle: handleA,
                pending: pendingA,
                decision: .allow(
                    scope: ApprovalScope(toolName: pendingA.toolCall.toolName, singleUse: true),
                    expiresAt: nil
                )
            )
            let crossResult = await handleB.resolveApproval(allowA)
            #expect(crossResult == .rejected(.conversationMismatch))

            let allowAResult = await handleA.resolveApproval(allowA)
            #expect(allowAResult == .accepted)
            let denyB = approvalCommand(
                handle: handleB,
                pending: pendingB,
                decision: .deny(reason: "session B denial")
            )
            let denyBResult = await handleB.resolveApproval(denyB)
            #expect(denyBResult == .accepted)

            let terminalA = try #require(await handleA.waitForTerminal(timeout: 15))
            let terminalB = try #require(await handleB.waitForTerminal(timeout: 15))
            #expect(terminalA.confirmed && terminalB.confirmed)
            #expect(executorA.executedCalls.map(\.id) == [callA.id])
            #expect(executorB.executedCalls.isEmpty)

            _ = try await handleA.close()
            _ = try await handleB.close()
        }
    }
}
