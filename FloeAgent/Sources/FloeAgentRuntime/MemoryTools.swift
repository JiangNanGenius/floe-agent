// FloeAgentRuntime — memory.remember / memory.recall agent tools.
//
// The agent can explicitly record a durable memory and recall active ones.
// Remembered entries are saved directly as active only after the approval
// policy obtains explicit user consent. They do not enter the passive review
// pipeline. Recall is read-only; remember writes Floe-owned internal state.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Records a durable memory the agent can recall in later runs.
public struct MemoryRememberTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var content: String
        public var scope: String?
        public var importance: Double?
        public var isPinned: Bool?

        public init(content: String, scope: String? = nil, importance: Double? = nil, isPinned: Bool? = nil) {
            self.content = content
            self.scope = scope
            self.importance = importance
            self.isPinned = isPinned
        }
    }

    public static let name = "memory.remember"
    public static let toolDescription =
        "Record a durable memory the agent can recall in later runs (a user preference, a decision, a convention). Scope is \"user\" for cross-project user facts or \"global\" for agent-wide notes. Recall saved memories with memory.recall."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "content": {"type": "string", "description": "The memory content to store"},
        "scope": {"type": "string", "description": "\"user\" or \"global\" (default \"global\")"},
        "importance": {"type": "number", "description": "Importance 0..1 (default 0.5)"},
        "isPinned": {"type": "boolean", "description": "Pin this memory so it always surfaces"}
      },
      "required": ["content"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    static let maxContentBytes = 4_096

    private let store: any DurableMemoryStore
    private let taskIDForRun: @Sendable (UUID) async throws -> UUID?

    public init(
        store: any DurableMemoryStore,
        taskIDForRun: @escaping @Sendable (UUID) async throws -> UUID? = { _ in nil }
    ) {
        self.store = store
        self.taskIDForRun = taskIDForRun
    }

    public func validate(_ args: Arguments) throws {
        let content = args.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw FloeError.validationFailed("content must not be empty") }
        guard content.utf8.count <= Self.maxContentBytes else {
            throw FloeError.validationFailed("content exceeds \(Self.maxContentBytes) bytes")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        // A tool invocation always belongs to a durable run. Silently
        // swallowing a lookup failure produced memories with no task origin,
        // which then could not be explained or aged with their owner.
        guard let ownerTaskID = try await taskIDForRun(context.runID) else {
            return Self.output(
                "status=failed error=memory owner task is unavailable",
                exitStatus: 1
            )
        }
        let entry = MemoryEntry(
            scope: Self.parseScope(args.scope),
            status: .active,
            content: args.content,
            confidence: 1.0,
            importance: min(1, max(0, args.importance ?? 0.5)),
            isPinned: args.isPinned ?? false,
            sourceKind: .explicitUserRequest,
            originConversationID: ownerTaskID
        )
        do {
            try await store.saveMemory(entry, evidence: [])
            return Self.output("status=remembered id=\(entry.id.uuidString)", exitStatus: 0)
        } catch {
            return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
    }

    static func parseScope(_ raw: String?) -> MemoryScope {
        switch raw?.lowercased() {
        case "user", "profile", "userprofile": .userProfile
        default: .agentGlobal
        }
    }

    static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

/// Recalls active durable memories for a scope.
public struct MemoryRecallTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var scope: String?

        public init(scope: String? = nil) {
            self.scope = scope
        }
    }

    public static let name = "memory.recall"
    public static let toolDescription =
        "List active durable memories for a scope (\"user\" or \"global\"), most important first. Use it to remember preferences, decisions and conventions recorded with memory.remember."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "scope": {"type": "string", "description": "\"user\" or \"global\" (default \"global\")"}
      },
      "required": [],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let store: any DurableMemoryStore

    public init(store: any DurableMemoryStore) {
        self.store = store
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let entries = try await store.memories(
                scope: MemoryRememberTool.parseScope(args.scope),
                status: .active
            )
            let sorted = entries.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                if $0.importance != $1.importance { return $0.importance > $1.importance }
                return $0.updatedAt > $1.updatedAt
            }
            let body = sorted.isEmpty
                ? "No active memories."
                : sorted.map { "- \($0.content)" }.joined(separator: "\n")
            return MemoryRememberTool.output("count=\(sorted.count)\n\(body)", exitStatus: 0)
        } catch {
            return MemoryRememberTool.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
    }
}

/// Registers the memory tools against the shared durable memory store.
@discardableResult
public func registerMemoryTools(
    registry: ToolRunnerRegistry = .shared,
    store: any DurableMemoryStore,
    taskIDForRun: @escaping @Sendable (UUID) async throws -> UUID? = { _ in nil }
) -> any DurableMemoryStore {
    ToolCatalog.register(MemoryRememberTool.self)
    ToolCatalog.register(MemoryRecallTool.self)
    registry.register(MemoryRememberTool(store: store, taskIDForRun: taskIDForRun))
    registry.register(MemoryRecallTool(store: store))
    return store
}
