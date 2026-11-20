// SPDX-License-Identifier: MPL-2.0
//
// MacSubagentPeerTests — sibling subagent discovery, bounded message exchange
// and spawn-authority parity for the Mac self-core runtime, composed onto the
// REAL FloeMacSelfRuntime / ConversationRunService / AgentRuntime child
// dispatch with scripted provider adapters.
//
// Covered behavior:
// - the Mac parent surface exposes exactly the two shared child-only
//   collaboration descriptors (`delegate.peers` / `delegate.message`) and the
//   runtime ceiling admits them for ordinary task sessions only — the main
//   run's wire request never lists them in schemas or capability names;
// - two real delegated children of ONE root task discover each other through
//   the real `SubagentPeerBus`, exchange one bounded message (delivered to
//   the sibling at its safe boundary) and finish; the parent spawns both
//   through its own approved `delegate` calls;
// - a child's `delegate` call is denied (`mainRunOnly`): no recursive
//   privilege, exactly the iPad boundary;
// - forged senders, unknown targets and cross-root messages are rejected with
//   receipts by the real bus, using real identities from two parked children
//   of two different root tasks;
// - the peer surface fails closed for a main-run context and for unknown
//   tool names, and the composition never overrides a base descriptor.

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

// MARK: - Scripted provider for the two-sibling coordination scenario

/// Routes parent/child turns by request meaning and parks each child's first
/// turn until the test has observed the collaboration phase, so discovery and
/// delivery assertions are deterministic. The alpha child's
/// `delegate.message` call is built dynamically from the real
/// `delegate.peers` response (the sibling childID is minted by the runtime
/// and cannot be known in advance).
final class PeerCoordinationAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses

    static let childMarker = "You are now running as a delegated subagent"
    static let alphaMarker = "peer-alpha investigation"
    static let betaMarker = "peer-beta investigation"
    static let alphaPeersCallID = "alpha-peers-1"
    static let alphaMsgCallID = "alpha-msg-1"
    static let betaReadCallID = "beta-read-1"
    static let betaNestedCallID = "beta-nested-1"
    static let claimBody = "claim:README.md"

    private let alphaGate = CancellableChildGate()
    private let betaGate = CancellableChildGate()
    private let lock = NSLock()
    private var recorded: [ProviderStreamRequest] = []

    var requests: [ProviderStreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func openAlphaGate() async { await alphaGate.open() }
    func openBetaGate() async { await betaGate.open() }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        let routed = route(request)
        let parkAlpha = routed.parkAlpha
        let parkBeta = routed.parkBeta
        return AsyncThrowingStream { continuation in
            let task = Task {
                if parkAlpha { await self.alphaGate.wait(continuation: continuation) }
                if parkBeta { await self.betaGate.wait(continuation: continuation) }
                for event in routed.events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        []
    }

    // MARK: Routing

    private struct Route {
        var events: [AgentEvent]
        var parkAlpha = false
        var parkBeta = false
    }

    private func route(_ request: ProviderStreamRequest) -> Route {
        let isChild = request.messages.contains {
            $0.role == "system" && $0.content.contains(Self.childMarker)
        }
        do {
            if !isChild {
                // Parent: turn 1 delegates both children; turn 2 answers.
                if request.toolResults.isEmpty {
                    return Route(events: [
                        .toolRequest(try Self.delegateCall(id: "call-peer-alpha", task: Self.alphaMarker)),
                        .toolRequest(try Self.delegateCall(id: "call-peer-beta", task: Self.betaMarker)),
                        .completed(.init(stopReason: .toolUse)),
                    ])
                }
                return Route(events: [
                    .textDelta(.init(text: "parent coordinated both subagents")),
                    .completed(.init(stopReason: .endTurn)),
                ])
            }
            let isAlpha = request.messages.contains { $0.content.contains(Self.alphaMarker) }
            if isAlpha {
                if request.toolResults.isEmpty {
                    // Parked until the test has verified both registrations.
                    return Route(events: [
                        .toolRequest(try Self.peersCall(id: Self.alphaPeersCallID)),
                        .completed(.init(stopReason: .toolUse)),
                    ], parkAlpha: true)
                }
                if request.toolResults.contains(where: { $0.callID == Self.alphaPeersCallID }),
                   let peerID = Self.extractPeerID(from: request) {
                    return Route(events: [
                        .toolRequest(try Self.messageCall(id: Self.alphaMsgCallID, to: peerID)),
                        .completed(.init(stopReason: .toolUse)),
                    ])
                }
                return Route(events: [
                    .textDelta(.init(text: "alpha findings complete")),
                    .completed(.init(stopReason: .endTurn)),
                ])
            }
            // Beta: turn 1 runs one read and attempts a nested delegate (must
            // be denied); turn 2 answers after the peer message was drained.
            if request.toolResults.isEmpty {
                return Route(events: [
                    .toolRequest(try ToolCall(
                        id: Self.betaReadCallID,
                        toolName: "workspace.readFile",
                        argumentsJSON: Data(#"{"path":"."}"#.utf8),
                        scope: .local
                    )),
                    .toolRequest(try Self.delegateCall(id: Self.betaNestedCallID, task: "spawn a nested subagent")),
                    .completed(.init(stopReason: .toolUse)),
                ], parkBeta: true)
            }
            return Route(events: [
                .textDelta(.init(text: "beta findings complete")),
                .completed(.init(stopReason: .endTurn)),
            ])
        } catch {
            return Route(events: [
                .textDelta(.init(text: "fixture routing error \(error.localizedDescription)")),
                .completed(.init(stopReason: .endTurn)),
            ])
        }
    }

    static func extractPeerID(from request: ProviderStreamRequest) -> UUID? {
        guard let result = request.toolResults.first(where: { $0.callID == alphaPeersCallID }),
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = object["peers"] as? [[String: Any]],
              let first = peers.first,
              let raw = first["childID"] as? String,
              let id = UUID(uuidString: raw) else { return nil }
        return id
    }

    static func delegateCall(id: String, task: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: DelegateTool.name,
            argumentsJSON: Data("{\"task\":\"\(task)\",\"background\":false}".utf8),
            scope: .local
        )
    }

    static func peersCall(id: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: DelegatePeersTool.name,
            argumentsJSON: Data(#"{"includeFinished":false}"#.utf8),
            scope: .local
        )
    }

    static func messageCall(id: String, to: UUID) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: DelegateMessageTool.name,
            argumentsJSON: Data(
                #"{"to":"\#(to.uuidString)","message":"\#(claimBody)","clientMessageID":"\#(id)"}"#
                    .utf8
            ),
            scope: .local
        )
    }
}

// MARK: - Tests

@Suite("FloeMacSelfCore.MacSubagentPeer", .serialized)
struct MacSubagentPeerTests {
    // Mirrors MacAgentWorkspaceTools.readToolNames (the package cannot import
    // the FloeMac target; tests pin the same contract independently).
    static let workspaceReadAllowlist: Set<String> = [
        "workspace.listDirectory",
        "workspace.readFile",
        "workspace.inspectFileMetadata",
        "workspace.searchFiles",
        "workspace.readDocument",
    ]
    static let writeToolName = "workspace.createFile"

    static func readDescriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "Fixture read \(name)",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#,
            riskLabels: [.readsFiles],
            isSideEffecting: false,
            effect: .readOnly
        )
    }

    static let writeDescriptor = ToolCatalog.Descriptor(
        name: writeToolName,
        toolDescription: "Fixture write",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"text":{"type":"string"}},"required":["path","text"],"additionalProperties":false}"#,
        riskLabels: [.writesFiles],
        isSideEffecting: true,
        effect: .mutating
    )

    static func fixtureExecutor() -> RecordingToolExecutor {
        RecordingToolExecutor(descriptors: workspaceReadAllowlist.map(readDescriptor) + [writeDescriptor])
    }

    // MARK: - Pure surface and admission checks

    @Test("Peer surface exposes exactly the two shared child-only tools")
    func peerSurfaceExposesExactlyTheTwoSharedTools() async throws {
        let surface = FloeMacSubagentPeerExecutor()
        let descriptors = surface.allDescriptors
        #expect(descriptors.map(\.name).sorted() == [
            DelegateMessageTool.name,
            DelegatePeersTool.name,
        ].sorted())
        for descriptor in descriptors {
            #expect(descriptor.executionBoundary == .childOnly)
        }
        #expect(surface.descriptor(named: DelegatePeersTool.name) != nil)
        #expect(surface.descriptor(named: DelegateMessageTool.name) != nil)
        #expect(surface.descriptor(named: "delegate") == nil)
        #expect(surface.descriptor(named: "workspace.readFile") == nil)

        // Unknown names fail closed at execution.
        let denied = try await surface.execute(
            ToolCall(id: "x1", toolName: "workspace.readFile", argumentsJSON: Data("{}".utf8), scope: .local),
            context: ToolContext(runID: UUID(), toolCallID: "x1", scope: .local, cancellation: CancellationToken())
        )
        #expect(denied.status == .denied)
    }

    @Test("Peer tools fail closed outside a delegated child, like iPad")
    func peerToolsFailClosedOnMainRunContext() async throws {
        let bus = SubagentPeerBus()
        let root = UUID()
        let identity = ChildExecutionIdentity(
            parentRunID: UUID(),
            rootTaskID: root,
            delegateCallID: "delegate-1"
        )
        await bus.register(identity, label: "unit-child")
        // A lone child has no same-root siblings; discovery excludes self.
        #expect(await bus.peers(of: identity.childID).isEmpty)

        let surface = FloeMacSubagentPeerExecutor()
        // A main-run context carries no childExecution: both tools refuse.
        let mainContext = ToolContext(
            runID: identity.parentRunID,
            toolCallID: "t-main",
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: root
        )
        let peersResult = try await surface.execute(
            try PeerCoordinationAdapter.peersCall(id: "m-peers"),
            context: mainContext
        )
        #expect(peersResult.status == .failed)
        #expect(peersResult.outputSummary.contains("only available inside a delegated subagent"))

        // A canonical child context works against the real bus.
        let handoff = ChildExecutionHandoff(
            identity: identity,
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, _ in
                    ToolResult(callID: call.id, status: .denied, outputSummary: "fixture", outputDigest: "")
                }
            ),
            peers: bus.handle(for: identity)
        )
        let childContext = ToolContext(
            runID: identity.parentRunID,
            toolCallID: "t-child",
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: root,
            childExecution: handoff
        )
        let childPeers = try await surface.execute(
            try PeerCoordinationAdapter.peersCall(id: "c-peers"),
            context: childContext
        )
        #expect(childPeers.status == .ok)
        #expect(childPeers.outputSummary.contains(identity.childID.uuidString))

        // Sending to an unknown target is a non-success receipt, never a drop.
        let unknownSend = try await surface.execute(
            try PeerCoordinationAdapter.messageCall(id: "c-msg", to: UUID()),
            context: childContext
        )
        #expect(unknownSend.status == .failed)
        #expect(unknownSend.outputSummary.contains("\"accepted\":false"))
        #expect(unknownSend.outputSummary.contains("no such subagent in this root task"))
    }

    @Test("Runtime admission matrix matches the shared frozen-catalog rule")
    func admitsPeerToolsMatrix() async throws {
        // Ordinary task session with tools: admitted into the ceiling.
        #expect(FloeMacSubagentPeerSupport.admitsPeerTools(
            runtimeToolsEnabled: true, conversationMode: .chat, chatFastMode: false, temporaryReadOnly: false))
        #expect(FloeMacSubagentPeerSupport.admitsPeerTools(
            runtimeToolsEnabled: true, conversationMode: .goal, chatFastMode: false, temporaryReadOnly: false))
        // Plan, chat-fast and tool-free surfaces: never admitted.
        #expect(!FloeMacSubagentPeerSupport.admitsPeerTools(
            runtimeToolsEnabled: true, conversationMode: .plan, chatFastMode: false, temporaryReadOnly: false))
        #expect(!FloeMacSubagentPeerSupport.admitsPeerTools(
            runtimeToolsEnabled: true, conversationMode: .chat, chatFastMode: true, temporaryReadOnly: false))
        #expect(!FloeMacSubagentPeerSupport.admitsPeerTools(
            runtimeToolsEnabled: false, conversationMode: .chat, chatFastMode: false, temporaryReadOnly: false))
        #expect(!FloeMacSubagentPeerSupport.admitsPeerTools(
            runtimeToolsEnabled: true, conversationMode: .chat, chatFastMode: false, temporaryReadOnly: true))
    }

    @Test("Peer-aware composition prefers the base and fails closed otherwise")
    func peerAwareCompositionPrefersBase() async throws {
        let base = Self.fixtureExecutor()
        let composite = FloeMacPeerAwareToolExecutor(wrapping: base)
        let names = Set(composite.allDescriptors.map(\.name))
        #expect(names == Self.workspaceReadAllowlist.union([Self.writeToolName])
            .union(FloeMacSubagentPeerSupport.toolNames))
        // Base descriptors win for base names.
        let read = try await composite.execute(
            ToolCall(id: "r1", toolName: "workspace.readFile", argumentsJSON: Data(#"{"path":"."}"#.utf8), scope: .local),
            context: ToolContext(runID: UUID(), toolCallID: "r1", scope: .local, cancellation: CancellationToken())
        )
        #expect(read.status == .ok)
        #expect(base.executedCalls.map(\.toolName) == ["workspace.readFile"])
        // A base that claims a peer name keeps ownership of it.
        let overriding = ToolCatalog.Descriptor(
            name: DelegatePeersTool.name,
            toolDescription: "fixture override",
            parametersJSON: #"{"type":"object","additionalProperties":false}"#,
            riskLabels: [],
            isSideEffecting: false,
            effect: .readOnly
        )
        let owningBase = RecordingToolExecutor(descriptors: [overriding])
        let owned = FloeMacPeerAwareToolExecutor(wrapping: owningBase)
        #expect(owned.descriptor(named: DelegatePeersTool.name)?.toolDescription == "fixture override")
        let ownedResult = try await owned.execute(
            try PeerCoordinationAdapter.peersCall(id: "o1"),
            context: ToolContext(runID: UUID(), toolCallID: "o1", scope: .local, cancellation: CancellationToken())
        )
        #expect(ownedResult.status == .ok)
        #expect(owningBase.executedCalls.map(\.toolName) == [DelegatePeersTool.name])
        // Unknown names stay denied.
        let unknown = try await composite.execute(
            ToolCall(id: "u1", toolName: "workspace.deleteFile", argumentsJSON: Data("{}".utf8), scope: .local),
            context: ToolContext(runID: UUID(), toolCallID: "u1", scope: .local, cancellation: CancellationToken())
        )
        #expect(unknown.status == .denied)
    }

    // MARK: - Bus guarantees with real identities

    @Test("Isolated bus enforces same-root delivery, bounds and receipts")
    func isolatedBusSameRootAndBounds() async throws {
        let bus = SubagentPeerBus()
        let rootA = UUID(), rootB = UUID(), parent = UUID()
        let alpha = ChildExecutionIdentity(parentRunID: parent, rootTaskID: rootA, delegateCallID: "d-alpha")
        let beta = ChildExecutionIdentity(parentRunID: parent, rootTaskID: rootA, delegateCallID: "d-beta")
        let foreign = ChildExecutionIdentity(parentRunID: parent, rootTaskID: rootB, delegateCallID: "d-foreign")
        await bus.register(alpha, label: "alpha")
        await bus.register(beta, label: "beta")
        await bus.register(foreign, label: "foreign")

        // Discovery is same-root and excludes the caller.
        let alphaPeers = await bus.peers(of: alpha.childID)
        #expect(alphaPeers.map(\.childID) == [beta.childID])
        #expect(await bus.peers(of: UUID()).isEmpty)

        // Real delivery: bounded envelope, pull-based drain. The first send
        // already carries the idempotency key; a retry with the same key is
        // the same logical message.
        let sent = await bus.send(
            from: alpha.childID, to: beta.childID, body: "  claim:file-x  ", clientMessageID: "k1"
        )
        #expect(sent.accepted)
        let drained = await bus.drain(childID: beta.childID)
        #expect(drained.count == 1)
        #expect(drained.first?.body == "claim:file-x")
        #expect(drained.first?.fromChildID == alpha.childID)
        #expect(drained.first?.rootTaskID == rootA)

        // Idempotent resend returns the same messageID without a second copy.
        let again = await bus.send(
            from: alpha.childID, to: beta.childID, body: "claim:file-x", clientMessageID: "k1"
        )
        #expect(again.accepted)
        #expect(again.messageID == sent.messageID)
        #expect(await bus.drain(childID: beta.childID).isEmpty)

        // Structural rejections, each with a receipt.
        #expect(await bus.send(from: alpha.childID, to: alpha.childID, body: "x").reason == "cannot message yourself")
        #expect(await bus.send(from: alpha.childID, to: UUID(), body: "x").reason == "no such subagent in this root task")
        #expect(await bus.send(from: alpha.childID, to: foreign.childID, body: "x").reason == "subagent belongs to a different root task")
        #expect(await bus.send(from: UUID(), to: beta.childID, body: "x").reason == "sender is not a running delegated child")
        #expect(await bus.send(from: alpha.childID, to: beta.childID, body: "   ").reason == "message body is empty")
        #expect(await bus.send(from: alpha.childID, to: beta.childID, body: String(repeating: "a", count: 4097)).reason?.contains("bytes") == true)
        await bus.unregister(childID: beta.childID)
        #expect(await bus.send(from: alpha.childID, to: beta.childID, body: "x").reason == "the target subagent has already finished")
        // A finished child can still read its mailbox (it drains nothing new).
        #expect(await bus.drain(childID: beta.childID).isEmpty)

        // Bounded audit trail observed the acceptances and rejections.
        let audit = await bus.auditEntries
        #expect(audit.contains { $0.accepted && $0.fromChildID == alpha.childID && $0.toChildID == beta.childID })
        #expect(audit.contains { !$0.accepted && $0.toChildID == foreign.childID })
    }

    @Test("A delegated child's delegate call is denied (no recursive privilege)")
    func childDelegationAttemptIsDenied() async throws {
        let tool = DelegateTool(runners: SubagentRunnerRegistry())
        let runID = UUID(), root = UUID()
        let identity = ChildExecutionIdentity(
            parentRunID: runID,
            rootTaskID: root,
            delegateCallID: "delegate-parent-1"
        )
        let handoff = ChildExecutionHandoff(
            identity: identity,
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, _ in
                    ToolResult(callID: call.id, status: .denied, outputSummary: "fixture", outputDigest: "")
                }
            ),
            peers: SubagentPeerBus().handle(for: identity)
        )
        // A child-context origin — even with the same run id and call id the
        // runtime would bind — can never authorize `delegate`.
        let context = ToolContext(
            runID: runID,
            toolCallID: "child-call-1",
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: root,
            childExecution: handoff,
            callOrigin: ToolCallOrigin(
                kind: .delegatedChild,
                runID: runID,
                callID: "child-call-1",
                toolName: DelegateTool.name,
                childID: identity.childID,
                rootTaskID: root
            )
        )
        let output = try await tool.execute(
            .init(task: "spawn a nested subagent"),
            context: context
        )
        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("status=denied"))
        #expect(output.summary.contains("cannot delegate"))
    }

    // MARK: - End-to-end: two real siblings discover and exchange

    @Test("Two real siblings of one root discover, exchange and stay invisible to the main run")
    func twoSiblingsDiscoverAndExchangeEndToEnd() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Peer workspace")
            let project = Self.fixtureExecutor()
            let base = fixture.makeProvider(scripts: []).binding
            let adapter = PeerCoordinationAdapter()
            let provider = FloeMacSelfProviderBinding(
                provider: base.provider, model: base.model,
                adapter: adapter, credentials: base.credentials
            )
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindPeerAwareParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(
                    conversationID: conversationID, workspaceID: workspaceID, runID: runID,
                    goal: "Coordinate two delegated subagents"
                ),
                provider: provider,
                tools: bound.tools
            )

            // Parent-initiated spawn under the usual approval, twice, one root.
            #expect(try await approvePendingDelegate(handle: handle, callID: "call-peer-alpha"))
            #expect(try await approvePendingDelegate(handle: handle, callID: "call-peer-beta"))

            // Both children are durably registered — hence on the real bus.
            let bothRunning = await eventually(timeout: 15) {
                guard let children = try? await bound.childRuntime.durableChildren(parentRunID: runID),
                      children.count == 2 else { return false }
                return children.allSatisfy { $0.state == .running }
            }
            #expect(bothRunning)
            let children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            let alphaRecord = try #require(children.first { $0.delegateCallID == "call-peer-alpha" })
            let betaRecord = try #require(children.first { $0.delegateCallID == "call-peer-beta" })
            #expect(alphaRecord.id != betaRecord.id)
            #expect(alphaRecord.conversationID == conversationID)
            #expect(betaRecord.conversationID == conversationID)

            // Discovery on the real bus, both directions, same root only.
            let alphaPeers = await SubagentPeerBus.shared.peers(of: alphaRecord.id)
            let betaPeers = await SubagentPeerBus.shared.peers(of: betaRecord.id)
            #expect(alphaPeers.map(\.childID) == [betaRecord.id])
            #expect(betaPeers.map(\.childID) == [alphaRecord.id])
            #expect(await SubagentPeerBus.shared.peers(of: UUID()).isEmpty)

            // Release alpha: it lists the sibling and sends the bounded claim.
            await adapter.openAlphaGate()
            let alphaSent = await eventually(timeout: 15) {
                let audit = await SubagentPeerBus.shared.auditEntries
                return audit.contains {
                    $0.accepted && $0.fromChildID == alphaRecord.id && $0.toChildID == betaRecord.id
                }
            }
            #expect(alphaSent)

            // Release beta: it reads its mailbox at the safe boundary.
            await adapter.openBetaGate()

            let terminal = try #require(await handle.waitForTerminal(timeout: 30))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            let requests = adapter.requests
            let parentRequests = requests.filter {
                !$0.messages.contains { $0.role == "system" && $0.content.contains(PeerCoordinationAdapter.childMarker) }
            }
            let alphaRequests = requests.filter {
                $0.messages.contains { $0.content.contains(PeerCoordinationAdapter.alphaMarker) }
            }
            let betaRequests = requests.filter {
                $0.messages.contains { $0.content.contains(PeerCoordinationAdapter.betaMarker) }
            }
            // The runtime may replay a request after a checkpoint retry; the
            // collaboration phases must each appear exactly once on the wire.
            let alphaPeersPhase = alphaRequests.filter {
                $0.toolResults.contains { $0.callID == PeerCoordinationAdapter.alphaPeersCallID }
            }
            let alphaMessagePhase = alphaRequests.filter {
                $0.toolResults.contains { $0.callID == PeerCoordinationAdapter.alphaMsgCallID }
            }
            let betaDeliveryPhase = betaRequests.filter {
                $0.messages.contains { $0.content.contains(PeerCoordinationAdapter.claimBody) }
            }
            #expect(parentRequests.count == 2)
            #expect(alphaRequests.first != nil)
            #expect(alphaPeersPhase.count == 1)
            #expect(alphaMessagePhase.count == 1)
            #expect(betaDeliveryPhase.count == 1)
            #expect(betaRequests.count == 2)

            // Main run never sees the child-only tools — schemas or names.
            for request in parentRequests {
                #expect(!request.toolSchemas.contains { $0.name == DelegatePeersTool.name })
                #expect(!request.toolSchemas.contains { $0.name == DelegateMessageTool.name })
                #expect(!request.allToolNames.contains(DelegatePeersTool.name))
                #expect(!request.allToolNames.contains(DelegateMessageTool.name))
            }
            // The parent's own delegation ceiling stays intact.
            #expect(parentRequests[0].toolSchemas.contains { $0.name == DelegateTool.name })

            // Alpha's wire carried the peer schemas (child sees).
            let alphaWire = alphaRequests[0]
            #expect(alphaWire.toolSchemas.contains { $0.name == DelegatePeersTool.name })
            #expect(alphaWire.toolSchemas.contains { $0.name == DelegateMessageTool.name })
            #expect(alphaWire.allToolNames.contains(DelegatePeersTool.name))
            #expect(alphaWire.allToolNames.contains(DelegateMessageTool.name))

            // Alpha discovered the REAL beta id and its send was accepted.
            let alphaTurnTwo = try #require(alphaPeersPhase.first)
            let peersResult = try #require(
                alphaTurnTwo.toolResults.first { $0.callID == PeerCoordinationAdapter.alphaPeersCallID }
            )
            #expect(peersResult.output.contains(betaRecord.id.uuidString))
            let messageResult = try #require(
                alphaMessagePhase.first?.toolResults.first { $0.callID == PeerCoordinationAdapter.alphaMsgCallID }
            )
            #expect(messageResult.output.contains("\"accepted\":true"))

            // Beta received the claim at its safe boundary and the nested
            // delegate attempt was denied by the parent dispatcher boundary.
            let betaSecond = try #require(betaDeliveryPhase.first)
            #expect(betaSecond.messages.contains { $0.content.contains(PeerCoordinationAdapter.claimBody) })
            let nestedResult = try #require(
                betaSecond.toolResults.first { $0.callID == PeerCoordinationAdapter.betaNestedCallID }
            )
            #expect(nestedResult.output.contains("main-run only"))
            let readResult = try #require(
                betaSecond.toolResults.first { $0.callID == PeerCoordinationAdapter.betaReadCallID }
            )
            #expect(readResult.output.contains("fixture ok"))

            // Both children completed durably; the parent reconciled both.
            let finished = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(finished.count == 2)
            #expect(finished.allSatisfy { $0.state == .completed })
            #expect(parentRequests[1].toolResults.allSatisfy { $0.output.contains("status=ok") })

            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - End-to-end: cross-root and forged identities denied live

    @Test("Real identities of two roots cannot reach each other; forged senders are refused")
    func crossRootAndForgedIdentitiesDeniedLive() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceA = try await fixture.createWorkspace(named: "Root A")
            let workspaceB = try await fixture.createWorkspace(named: "Root B")
            let project = Self.fixtureExecutor()
            let base = fixture.makeProvider(scripts: []).binding
            let adapter = TwoRootsAdapter()
            let provider = FloeMacSelfProviderBinding(
                provider: base.provider, model: base.model,
                adapter: adapter, credentials: base.credentials
            )
            let conversationA = UUID(), runA = UUID()
            let conversationB = UUID(), runB = UUID()
            let boundA = try await bindPeerAwareParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceA, conversationID: conversationA, runID: runA
            )
            let boundB = try await bindPeerAwareParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceB, conversationID: conversationB, runID: runB
            )
            let handleA = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationA, workspaceID: workspaceA, runID: runA, goal: "Root A task"),
                provider: provider, tools: boundA.tools
            )
            let handleB = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationB, workspaceID: workspaceB, runID: runB, goal: "Root B task"),
                provider: provider, tools: boundB.tools
            )
            #expect(try await approvePendingDelegate(handle: handleA, callID: "call-root-a"))
            #expect(try await approvePendingDelegate(handle: handleB, callID: "call-root-b"))

            // Both children are live on the shared process bus, in two roots.
            let bothLive = await eventually(timeout: 15) {
                guard let childrenA = try? await boundA.childRuntime.durableChildren(parentRunID: runA),
                      let childrenB = try? await boundB.childRuntime.durableChildren(parentRunID: runB),
                      childrenA.count == 1, childrenB.count == 1 else { return false }
                return childrenA[0].state == .running && childrenB[0].state == .running
            }
            #expect(bothLive)
            let childA = try #require((try await boundA.childRuntime.durableChildren(parentRunID: runA)).first)
            let childB = try #require((try await boundB.childRuntime.durableChildren(parentRunID: runB)).first)
            #expect(childA.conversationID == conversationA)
            #expect(childB.conversationID == conversationB)
            #expect(childA.id != childB.id)

            // Cross-root discovery shows nothing; cross-root send is rejected.
            #expect(await SubagentPeerBus.shared.peers(of: childA.id).isEmpty)
            #expect(await SubagentPeerBus.shared.peers(of: childB.id).isEmpty)
            let crossSend = await SubagentPeerBus.shared.send(
                from: childA.id, to: childB.id, body: "cross-root hello"
            )
            #expect(!crossSend.accepted)
            #expect(crossSend.reason == "subagent belongs to a different root task")
            let reverseSend = await SubagentPeerBus.shared.send(
                from: childB.id, to: childA.id, body: "cross-root hello"
            )
            #expect(!reverseSend.accepted)

            // Forged sender ids are refused outright.
            let forged = await SubagentPeerBus.shared.send(
                from: UUID(), to: childB.id, body: "forged"
            )
            #expect(!forged.accepted)
            #expect(forged.reason == "sender is not a running delegated child")

            // The rejected cross-root message never entered the mailbox.
            #expect(await SubagentPeerBus.shared.drain(childID: childB.id).isEmpty)
            let audit = await SubagentPeerBus.shared.auditEntries
            #expect(audit.contains {
                !$0.accepted && $0.fromChildID == childA.id && $0.toChildID == childB.id
                    && $0.rootTaskID == conversationA
            })

            // Both parents still finish normally.
            await adapter.openGate()
            let terminalA = try #require(await handleA.waitForTerminal(timeout: 30))
            let terminalB = try #require(await handleB.waitForTerminal(timeout: 30))
            #expect(terminalA.confirmed && terminalA.outcome == .completed)
            #expect(terminalB.confirmed && terminalB.outcome == .completed)
            _ = try await handleA.close()
            _ = try await handleB.close()
            await boundA.childRuntime.releaseParentRun(runA)
            await boundB.childRuntime.releaseParentRun(runB)
        }
    }

    // MARK: - Fixture composition helpers (peer-aware variants)

    func agentRequest(
        conversationID: UUID,
        workspaceID: UUID,
        runID: UUID,
        goal: String
    ) -> FloeMacSelfSessionRequest {
        FloeMacSelfSessionRequest(
            newConversationID: conversationID,
            workspaceID: workspaceID,
            conversationTitle: "Peer collaboration task",
            goal: goal,
            mode: .chat,
            runID: runID,
            context: FloeMacSelfRunContext(workspaceName: "Peer workspace"),
            chatFastMode: false
        )
    }

    func makeBinding(
        fixture: SelfCoreFixture,
        workspaceID: UUID,
        executor: any ToolExecutor,
        allowed: Set<String>
    ) throws -> FloeMacSelfToolBinding {
        let gate = try CatastrophicActionGate.withBundledPatterns()
        let boundary = FloeMacSelfTaskBoundary(
            workspaceID: workspaceID,
            workspaceRootURL: fixture.workspaceRoot,
            allowedWorkspacePaths: [],
            ownership: .nativeHost
        )
        return FloeMacSelfToolBinding(
            executor: executor,
            policy: HumanApprovalPolicy(),
            gate: gate,
            auditSink: nil,
            boundary: boundary,
            allowedToolNames: allowed,
            hostGate: fixture.makeHostGate(workspaceID: workspaceID, allowedToolNames: allowed)
        )
    }

    @discardableResult
    func approvePendingDelegate(
        handle: FloeMacSelfSessionHandle,
        callID: String
    ) async throws -> Bool {
        let waiting = await eventually(timeout: 15) {
            let snapshot = await handle.snapshot()
            return snapshot?.pendingApproval?.toolCall.id == callID
        }
        guard waiting,
              let pending = await handle.snapshot()?.pendingApproval,
              pending.toolCall.id == callID else { return false }
        let command = approvalCommand(
            handle: handle,
            pending: pending,
            decision: .allow(
                scope: ApprovalScope(toolName: pending.toolCall.toolName, singleUse: true),
                expiresAt: nil
            )
        )
        return await handle.resolveApproval(command) == .accepted
    }

    /// Installs the child runtime, binds the parent run and builds the
    /// session binding. Both the parent session surface and the child runner
    /// use the SAME peer-aware project executor — the single wrap the
    /// child-subagent owner applies to `tools.executor` — so the child's
    /// discovery universe is the parent's effective catalog plus the two
    /// child-only collaboration tools.
    func bindPeerAwareParent(
        fixture: SelfCoreFixture,
        provider: FloeMacSelfProviderBinding,
        project: RecordingToolExecutor,
        workspaceID: UUID,
        conversationID: UUID,
        runID: UUID
    ) async throws -> (childRuntime: FloeMacChildSubagentRuntime, tools: FloeMacSelfToolBinding) {
        let store = try await fixture.runtime.childRunStoring()
        let childRuntime = FloeMacChildSubagentRuntime(childStore: store)
        await fixture.runtime.installChildSubagentRuntime(childRuntime)
        let composite = FloeMacPeerAwareToolExecutor(
            wrapping: FloeMacDelegatingProjectToolExecutor(project: project, runners: childRuntime.registry)
        )
        var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName])
        allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
        let tools = try makeBinding(fixture: fixture, workspaceID: workspaceID, executor: composite, allowed: allowed)
        await childRuntime.bindParentRun(
            runID: runID,
            provider: provider.provider,
            model: provider.model,
            adapter: provider.adapter,
            credentials: provider.credentials,
            projectExecutor: composite
        )
        return (childRuntime, tools)
    }
}

// MARK: - Two-root scripted adapter

/// Drives two independent parent tasks (root A and root B), each delegating
/// one child whose first turn parks until the test has exercised the
/// cross-root denial live.
final class TwoRootsAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses

    static let childMarker = "You are now running as a delegated subagent"
    static let childAMarker = "root-a-child"
    static let childBMarker = "root-b-child"

    private let gate = CancellableChildGate()
    private let lock = NSLock()
    private var recorded: [ProviderStreamRequest] = []

    var requests: [ProviderStreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func openGate() async { await gate.open() }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        let isChild = request.messages.contains {
            $0.role == "system" && $0.content.contains(Self.childMarker)
        }
        if !isChild {
            let isRootA = request.messages.contains { $0.content.contains("Root A task") }
            let callID = isRootA ? "call-root-a" : "call-root-b"
            let task = isRootA ? Self.childAMarker : Self.childBMarker
            guard let delegate = try? ToolCall(
                id: callID,
                toolName: DelegateTool.name,
                argumentsJSON: Data("{\"task\":\"\(task) investigate\",\"background\":false}".utf8),
                scope: .local
            ) else {
                return AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            }
            let events: [AgentEvent] = request.toolResults.isEmpty
                ? [.toolRequest(delegate), .completed(.init(stopReason: .toolUse))]
                : [.textDelta(.init(text: "root task finished")), .completed(.init(stopReason: .endTurn))]
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let park = true
        let marker = request.messages.contains { $0.content.contains(Self.childAMarker) }
            ? "root a child findings"
            : "root b child findings"
        let events: [AgentEvent] = [.textDelta(.init(text: marker)), .completed(.init(stopReason: .endTurn))]
        return AsyncThrowingStream { continuation in
            let task = Task {
                if park { await self.gate.wait(continuation: continuation) }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        []
    }
}
