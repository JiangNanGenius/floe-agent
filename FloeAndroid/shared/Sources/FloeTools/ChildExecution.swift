// FloeTools — Subagent (child) execution contracts.
//
// A delegated child runs inside the parent run and must not reach the raw
// tool registry. The parent runtime mints a `ChildExecutionHandoff` for the
// delegate call: it carries the child's non-model-issued identity, the
// CANONICAL dispatcher (the same permission path that approves main-run
// calls) and the peer-collaboration handle for the same root task. Children
// execute through the dispatcher; when no handoff is present the subagent
// runner falls back to a fail-closed read-only ceiling instead of touching
// the registry directly.
//
// None of these values are Codable: they are runtime handles, never model
// data. A provider cannot mint an identity, a dispatcher, a peer handle or
// authority over a workspace by writing JSON.

import Foundation
import FloeModels

/// Runtime-issued provenance of one concrete tool call.
///
/// This is the callable-boundary proof that a call really originated where it
/// claims: the parent runtime mints it for the EXACT call id it approved. A
/// wrapper tool that reconstructs a context, a model-supplied field, a
/// `confirmed` flag or any other JSON can never produce one, and a delegated
/// child's context carries `.delegatedChild` — so `delegate` can verify at
/// execution time that it is the main run's own call and never a nested or
/// wrapper-induced invocation. Not Codable, like every runtime handle here.
public struct ToolCallOrigin: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The main run's own approved call with this exact call id.
        case mainRunDelegate
        /// Any call executed inside a delegated child.
        case delegatedChild
    }

    public var kind: Kind
    public var runID: UUID
    public var callID: String
    /// The runtime-approved tool name of THIS call. A main-only capability
    /// checks it too, so a main-run wrapper that forwards its own identical
    /// runID/callID/origin into a different raw registry tool is refused: the
    /// origin authorizes exactly the approved tool, never "any main call".
    public var toolName: String?
    public var childID: UUID?
    public var rootTaskID: UUID?

    public init(
        kind: Kind,
        runID: UUID,
        callID: String,
        toolName: String? = nil,
        childID: UUID? = nil,
        rootTaskID: UUID? = nil
    ) {
        self.kind = kind
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.childID = childID
        self.rootTaskID = rootTaskID
    }

    /// True only for the main run's own approved call of EXACTLY `toolName`
    /// with the exact approved call id. Every component is runtime-issued:
    /// kind, run, call id and the approved tool name. A wrapper that copies
    /// its own origin into another tool's raw registry entry fails the
    /// tool-name binding; a child, a rebuilt context without an origin and a
    /// stale call id all stay refused.
    public func authorizesMainOnlyCapability(
        toolName: String,
        runID: UUID,
        callID: String?
    ) -> Bool {
        kind == .mainRunDelegate
            && self.toolName == toolName
            && self.runID == runID
            && callID == self.callID
    }

    /// Convenience for `delegate` (the tool name is DelegateTool.name; kept
    /// as a stable string here because FloeTools cannot import the runtime
    /// module). Equivalent to `authorizesMainOnlyCapability(toolName:)` with
    /// the delegate tool name.
    public func authorizesMainOnlyDelegate(runID: UUID, callID: String?) -> Bool {
        authorizesMainOnlyCapability(toolName: Self.delegateToolName, runID: runID, callID: callID)
    }

    /// Stable tool name of the main-only delegation capability.
    public static let delegateToolName = "delegate"
}

/// Stable identity of one delegated child inside one root task. Minted by the
/// parent runtime; carried into every tool context the child executes.
public struct ChildExecutionIdentity: Sendable, Hashable {
    public var childID: UUID
    public var parentRunID: UUID
    /// Same actual root task (conversation). The only scope in which sibling
    /// peers may address each other.
    public var rootTaskID: UUID
    /// The provider tool-call id of the `delegate` call that created this child.
    public var delegateCallID: String
    /// Always 1 for children created by the main run; nested delegation is
    /// denied, so a greater depth can never be minted by the canonical path.
    public var depth: Int
    public var startedAt: Date

    public init(
        childID: UUID = UUID(),
        parentRunID: UUID,
        rootTaskID: UUID,
        delegateCallID: String,
        depth: Int = 1,
        startedAt: Date = Date()
    ) {
        self.childID = childID
        self.parentRunID = parentRunID
        self.rootTaskID = rootTaskID
        self.delegateCallID = delegateCallID
        self.depth = max(1, depth)
        self.startedAt = startedAt
    }
}

/// The parent runtime's canonical tool dispatcher for child calls. `dispatch`
/// runs one child tool call through the SAME catalog/ceiling/policy/gate/
/// executor path as a main-run call and returns its real result. It is a
/// runtime closure, never a registry lookup the child can replace.
public struct ChildToolDispatcher: Sendable {
    public var descriptorProvider: @Sendable (String) -> ToolCatalog.Descriptor?
    public var allDescriptors: @Sendable () -> [ToolCatalog.Descriptor]
    public var dispatch: @Sendable (ToolCall, ToolContext) async -> ToolResult

    public init(
        descriptorProvider: @escaping @Sendable (String) -> ToolCatalog.Descriptor?,
        allDescriptors: @escaping @Sendable () -> [ToolCatalog.Descriptor],
        dispatch: @escaping @Sendable (ToolCall, ToolContext) async -> ToolResult
    ) {
        self.descriptorProvider = descriptorProvider
        self.allDescriptors = allDescriptors
        self.dispatch = dispatch
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        descriptorProvider(name)
    }
}

/// One bounded message exchanged between sibling subagents of the same root
/// task. `messageID` is real (a UUID minted by the bus); `clientMessageID` is
/// optional model-supplied dedup material that never grants anything.
public struct SubagentPeerEnvelope: Sendable, Hashable {
    public var messageID: UUID
    public var fromChildID: UUID
    public var fromLabel: String
    public var toChildID: UUID
    public var rootTaskID: UUID
    public var body: String
    public var sentAt: Date

    public init(
        messageID: UUID,
        fromChildID: UUID,
        fromLabel: String,
        toChildID: UUID,
        rootTaskID: UUID,
        body: String,
        sentAt: Date
    ) {
        self.messageID = messageID
        self.fromChildID = fromChildID
        self.fromLabel = fromLabel
        self.toChildID = toChildID
        self.rootTaskID = rootTaskID
        self.body = body
        self.sentAt = sentAt
    }
}

/// Public, non-authorizing view of a sibling subagent.
public struct SubagentPeerSummary: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case running
        case finished
    }

    public var childID: UUID
    public var label: String
    public var status: Status
    public var startedAt: Date

    public init(childID: UUID, label: String, status: Status, startedAt: Date) {
        self.childID = childID
        self.label = label
        self.status = status
        self.startedAt = startedAt
    }
}

public struct SubagentPeerSendReceipt: Sendable, Hashable {
    public var accepted: Bool
    public var messageID: UUID?
    public var reason: String?

    public init(accepted: Bool, messageID: UUID? = nil, reason: String? = nil) {
        self.accepted = accepted
        self.messageID = messageID
        self.reason = reason
    }
}

/// Peer-collaboration handle for one child. All operations are bounded and
/// scoped to the child's root task by the backing bus; none of them grants
/// permissions or can restart an ended child.
public struct PeerCollaborationHandle: Sendable {
    /// Registers this child as running under its root task.
    public var register: @Sendable (_ label: String) async -> Void
    /// Marks this child finished and rejects any later message to it.
    public var unregister: @Sendable () async -> Void
    /// Removes and returns messages queued for this child (safe-boundary pull).
    public var drain: @Sendable () async -> [SubagentPeerEnvelope]
    /// Lists siblings (and optionally finished/recently ended children).
    public var peers: @Sendable (_ includeFinished: Bool) async -> [SubagentPeerSummary]
    /// Sends one bounded message to a sibling in the same root task.
    public var send: @Sendable (_ toChildID: UUID, _ body: String, _ clientMessageID: String?) async -> SubagentPeerSendReceipt

    public init(
        register: @escaping @Sendable (_ label: String) async -> Void,
        unregister: @escaping @Sendable () async -> Void,
        drain: @escaping @Sendable () async -> [SubagentPeerEnvelope],
        peers: @escaping @Sendable (_ includeFinished: Bool) async -> [SubagentPeerSummary],
        send: @escaping @Sendable (_ toChildID: UUID, _ body: String, _ clientMessageID: String?) async -> SubagentPeerSendReceipt
    ) {
        self.register = register
        self.unregister = unregister
        self.drain = drain
        self.peers = peers
        self.send = send
    }
}

/// Everything a delegated child needs from its parent runtime. Seeded on the
/// `delegate` tool context by the runtime and passed to the subagent runner.
public struct ChildExecutionHandoff: Sendable {
    public var identity: ChildExecutionIdentity
    public var dispatcher: ChildToolDispatcher
    public var peers: PeerCollaborationHandle

    public init(
        identity: ChildExecutionIdentity,
        dispatcher: ChildToolDispatcher,
        peers: PeerCollaborationHandle
    ) {
        self.identity = identity
        self.dispatcher = dispatcher
        self.peers = peers
    }
}
