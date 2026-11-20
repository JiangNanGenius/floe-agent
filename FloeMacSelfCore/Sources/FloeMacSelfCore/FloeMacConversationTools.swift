// SPDX-License-Identifier: MPL-2.0
//
// FloeMacConversationTools — Mac self-core conversation capability.
//
// Top-level `conversation.list` / `conversation.search` / `conversation.read`
// / `conversation.spawn` / `conversation.message` for the unified Mac host,
// with authority identical to the iPad composition
// (FloeAgent/FloeApp/App/AppEnvironment.swift `registerConversationTools`):
//
// - The executable tools are the exact shared
//   FloeAgentRuntime/ConversationTools.swift and
//   ConversationCoordination.swift `ConversationMessageTool` types. No Mac
//   fork of the tool logic exists here; this file only binds them to the
//   Mac runtime's one SQLite database and live sessions.
// - Cross-task reads stay quoted, untrusted historical data (enforced by
//   the shared tools + ConversationEnvelope).
// - `conversation.spawn` creates a separate user-visible task with
//   deterministic identities (shared ConversationSpawnIdentity), fresh
//   durable ownership and NO silent parent project/workspace inheritance:
//   a workspace is linked only when the model explicitly passes one, exactly
//   like the iPad spawner. A delegated child or a reconstructed context can
//   never spawn (shared `.mainRunOnly` callable-boundary check).
// - `conversation.message` reuses the shared ConversationCoordinationService
//   so live delivery, idempotency, owner-change fencing and the untrusted
//   system-notice projection stay byte-identical to iPad.
//
// The capability is constructed from store protocols (the same
// SQLite*Store instances the runtime already owns), so tests can bind it to
// an isolated database and the runtime can bind it to its single writer.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

/// Composition namespace for the Mac conversation tool capability.
public enum FloeMacConversationTools {
    public static let listToolName = ConversationListTool.name
    public static let searchToolName = ConversationSearchTool.name
    public static let readToolName = ConversationReadTool.name
    public static let spawnToolName = ConversationSpawnTool.name
    public static let messageToolName = ConversationMessageTool.name

    /// Read-only discovery names. These pass the existing
    /// `ConversationToolAccess.plan`/`PlanToolPolicy` ceiling, so plan-style
    /// sessions may bind exactly this set (iPad parity).
    public static let readToolNames: Set<String> = [
        listToolName, searchToolName, readToolName,
    ]
    /// Main-run creation plus live coordination. Never part of the read-only
    /// plan ceiling; `conversation.spawn` additionally carries the shared
    /// `.mainRunOnly` execution boundary enforced at the callable boundary.
    public static let stateToolNames: Set<String> = [
        spawnToolName, messageToolName,
    ]
    public static let allToolNames: Set<String> = readToolNames.union(stateToolNames)

    /// Stable labels for the host gate (provenance, not secrets).
    public static let toolCorpusIdentifier = "floe.macselfcore.conversation-tools.v1"
}

/// One bound conversation capability: the five shared tool instances wired
/// to one database's stores and one live-session resolver. Value-typed and
/// `Sendable`; safe to hand across the host/runtime boundary.
public struct FloeMacConversationToolCapability: Sendable {
    /// Discovery reader. On the Mac this is the same
    /// `SQLiteIntelligenceStore` instance the runtime composes, so
    /// archive/privacy scoping (`purpose='ordinary'`, visibility and
    /// archived filters) is identical to iPad.
    public let reader: any ConversationHistoryReader
    public let listTool: ConversationListTool
    public let searchTool: ConversationSearchTool
    public let readTool: ConversationReadTool
    public let spawnTool: ConversationSpawnTool
    public let messageTool: ConversationMessageTool
    /// The single coordination owner used by `messageTool`. One per database,
    /// matching the iPad single `taskCoordinationDelivery` owner.
    public let coordination: ConversationCoordinationService

    public init(
        reader: any ConversationHistoryReader,
        listTool: ConversationListTool,
        searchTool: ConversationSearchTool,
        readTool: ConversationReadTool,
        spawnTool: ConversationSpawnTool,
        messageTool: ConversationMessageTool,
        coordination: ConversationCoordinationService
    ) {
        self.reader = reader
        self.listTool = listTool
        self.searchTool = searchTool
        self.readTool = readTool
        self.spawnTool = spawnTool
        self.messageTool = messageTool
        self.coordination = coordination
    }

    /// Type-erased runners in deterministic name order, for scoped
    /// `ToolExecutor` composition (the Mac host never routes these through
    /// the process-wide shared registry).
    public var tools: [AnyAgentTool] {
        [AnyAgentTool(listTool), AnyAgentTool(searchTool), AnyAgentTool(readTool),
         AnyAgentTool(spawnTool), AnyAgentTool(messageTool)]
    }

    public var descriptors: [ToolCatalog.Descriptor] {
        tools.map(\.descriptor).sorted { $0.name < $1.name }
    }

    public var names: Set<String> {
        Set(descriptors.map(\.name))
    }
}

public extension FloeMacConversationTools {
    /// Binds the capability to one database's stores. Every closure mirrors
    /// the iPad `AppEnvironment.registerConversationTools` wiring:
    ///
    /// - `currentConversationID`: the durable run row's conversation.
    /// - `hasExplicitUserAuthority`: the LATEST user message of the run's
    ///   conversation must be an explicit new-task request (shared
    ///   `ConversationSpawnAuthority.isExplicitRequest`). Vague suggestions
    ///   never authorize spawning.
    /// - `spawner`: deterministic, idempotent, atomic single-transaction
    ///   publish with an always-bound durable owner — an explicit
    ///   user-selected project, or a fresh canonical private task root. It
    ///   never erases or rewrites an existing task, and never inherits the
    ///   source conversation's workspace.
    /// - `messenger`: shared `ConversationCoordinationService` over the same
    ///   conversation/run/input stores and the caller's live-service map.
    static func makeCapability(
        reader: any ConversationHistoryReader,
        runStore: any RunStore,
        conversationStore: any ConversationStore,
        runningInputStore: any RunningInputStore,
        resolveWorkspace: @escaping @Sendable (UUID) async throws -> WorkspaceRecord?,
        liveService: @escaping @Sendable (UUID) async -> ConversationRunService?
    ) -> FloeMacConversationToolCapability {
        let currentConversationID: @Sendable (UUID) async throws -> UUID? = { runID in
            try await runStore.run(id: runID)?.conversationID
        }
        let hasExplicitUserAuthority: @Sendable (UUID) async throws -> Bool = { runID in
            guard let conversationID = try await runStore.run(id: runID)?.conversationID else {
                return false
            }
            let latestUserText = try await conversationStore.messages(conversationID: conversationID)
                .last(where: { $0.role == "user" })?.content ?? ""
            return ConversationSpawnAuthority.isExplicitRequest(latestUserText)
        }
        let spawner: ConversationSpawner = { request in
            try await spawn(
                request,
                conversationStore: conversationStore,
                resolveWorkspace: resolveWorkspace
            )
        }
        let coordination = ConversationCoordinationService(
            conversations: conversationStore,
            runs: runStore,
            inputs: runningInputStore,
            liveService: liveService
        )
        return FloeMacConversationToolCapability(
            reader: reader,
            listTool: ConversationListTool(
                reader: reader,
                currentConversationID: currentConversationID
            ),
            searchTool: ConversationSearchTool(
                reader: reader,
                currentConversationID: currentConversationID
            ),
            readTool: ConversationReadTool(
                reader: reader,
                currentConversationID: currentConversationID
            ),
            spawnTool: ConversationSpawnTool(
                sourceConversationID: currentConversationID,
                hasExplicitUserAuthority: hasExplicitUserAuthority,
                spawner: spawner
            ),
            messageTool: ConversationMessageTool(messenger: { request, cancellation in
                try await coordination.deliver(request, cancellation: cancellation)
            }),
            coordination: coordination
        )
    }

    /// iPad-equal visible task creation, independently persisted on macOS.
    ///
    /// Identities are deterministic (shared `ConversationSpawnIdentity`), so
    /// a retried provider call addresses the exact same task and initial
    /// message instead of duplicating them. Ownership is never silent: the
    /// new task binds an explicit user-selected project only when the caller
    /// passes one (verified `.project`; a private or unknown workspace is
    /// rejected fail-closed), and otherwise receives a fresh canonical
    /// private task root (`PrivateTasks/<task UUID>`) — never the source
    /// conversation's workspace, never nil.
    ///
    /// The whole publish is ONE SQLite transaction
    /// (`ConversationStore.applyVisibleTaskSpawn`): an idempotent retry
    /// compares and preserves the existing task, its history and its owner;
    /// a mismatched retry throws, the transaction rolls back, and the
    /// existing task is never erased.
    static func spawn(
        _ request: ConversationSpawnRequest,
        conversationStore: any ConversationStore,
        resolveWorkspace: @escaping @Sendable (UUID) async throws -> WorkspaceRecord?
    ) async throws -> ConversationSpawnResult {
        let now = Date()
        let conversationID = ConversationSpawnIdentity.uuid(
            operationID: request.operationID,
            suffix: "conversation"
        )
        let initialMessageID = ConversationSpawnIdentity.uuid(
            operationID: request.operationID,
            suffix: "initial-message"
        )
        let workspace: ConversationSpawnWorkspace
        if let explicitID = request.workspaceID {
            guard let row = try await resolveWorkspace(explicitID) else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "the explicit workspace \(explicitID.uuidString) is unavailable"
                )
            }
            guard row.kind == .project else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "a spawned task may only join an explicit user-selected project workspace"
                )
            }
            workspace = .project(explicitID)
        } else {
            workspace = .canonicalPrivateTask
        }
        let record = ConversationRecord(
            id: conversationID,
            title: request.title,
            createdAt: now,
            updatedAt: now,
            // `.manual` matches the iPad spawn: the title the user asked
            // for is never overwritten by automatic titling.
            titleOrigin: .manual
        )
        let outcome = try await conversationStore.applyVisibleTaskSpawn(
            conversation: record,
            initialMessage: PersistedMessage(
                id: initialMessageID,
                conversationID: conversationID,
                role: "user",
                content: request.objective,
                createdAt: now
            ),
            workspace: workspace
        )
        return ConversationSpawnResult(
            conversationID: record.id,
            title: record.title,
            workspaceID: outcome.workspaceID,
            wasCreated: outcome.wasCreated
        )
    }
}
