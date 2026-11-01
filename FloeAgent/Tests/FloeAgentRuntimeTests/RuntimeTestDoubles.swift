// Shared runtime test doubles, used by focused configuration/input tests too.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

// MARK: - Async-safe lock

/// NSLock wrapper usable from async contexts (Xcode's SDK marks raw
/// NSLock unavailable in async; os_unfair_lock via a tiny nonisolated
/// wrapper keeps tests dependency-free).
final class AsyncLock<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()

    init(_ state: State) {
        self.state = state
    }

    nonisolated func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

// MARK: - Mocks

/// Scripted adapter: emits a fixed event sequence per stream call.
final class MockAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private struct Storage {
        var script: [[AgentEvent]] = []
        var callCount = 0
        var requests: [ProviderStreamRequest] = []
        /// Script a stream that throws at a given request index (a transport /
        /// adapter failure instead of a yielded .error event).
        var throwAt: [Int: Error] = [:]
    }
    private let storage = AsyncLock(Storage())

    var script: [[AgentEvent]] {
        get { storage.withLock { $0.script } }
        set { storage.withLock { $0.script = newValue } }
    }

    var requests: [ProviderStreamRequest] { storage.withLock { $0.requests } }

    /// Mark request index `index` (0-based, in adapter call order) to throw
    /// `error` instead of yielding its scripted events.
    func setThrow(_ error: Error, at index: Int) {
        storage.withLock { $0.throwAt[index] = error }
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let (events, thrown) = storage.withLock { state -> ([AgentEvent], Error?) in
            state.requests.append(request)
            let events = state.callCount < state.script.count ? state.script[state.callCount] : []
            let thrown = state.throwAt[state.callCount]
            state.callCount += 1
            return (events, thrown)
        }
        return AsyncThrowingStream { continuation in
            if let thrown {
                continuation.finish(throwing: thrown)
                return
            }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

/// Scripted executor: returns queued results, or a default ok.
final class MockExecutor: ToolExecutor, @unchecked Sendable {
    private struct Storage {
        var descriptors: [String: ToolCatalog.Descriptor] = [:]
        var results: [ToolResult] = []
        var executedCalls: [ToolCall] = []
    }

    private let storage = AsyncLock(Storage())
    /// Gate for tests that need the tool to block until released.
    var executionGate: (@Sendable () async -> Void)?

    var descriptors: [String: ToolCatalog.Descriptor] {
        get { storage.withLock { $0.descriptors } }
        set { storage.withLock { $0.descriptors = newValue } }
    }

    var results: [ToolResult] {
        get { storage.withLock { $0.results } }
        set { storage.withLock { $0.results = newValue } }
    }

    var executedCalls: [ToolCall] {
        storage.withLock { $0.executedCalls }
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        storage.withLock { $0.descriptors[name] }
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        storage.withLock { state in
            state.descriptors.values.sorted { $0.name < $1.name }
        }
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        if let executionGate { await executionGate() }
        try context.cancellation.throwIfCancelled()
        let result = storage.withLock { state -> ToolResult? in
            state.executedCalls.append(call)
            return state.results.isEmpty ? nil : state.results.removeFirst()
        }
        return result ?? ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
    }
}

final class MockCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let storage = AsyncLock<[AgentCheckpoint]>([])
    var saved: [AgentCheckpoint] { storage.withLock { $0 } }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        storage.withLock { $0.append(checkpoint) }
    }

    func load(runID: UUID) async throws -> AgentCheckpoint? {
        storage.withLock { $0.last { $0.runID == runID } }
    }
}
