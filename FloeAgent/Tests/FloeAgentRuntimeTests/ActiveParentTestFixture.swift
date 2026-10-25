// A test-only provider and structured lifetime for direct canonical child
// dispatch tests. No production state is set or guard bypassed: the parent
// enters its normal start/provider stream and stays there until released or
// cancelled. Every owned start task is joined before the test scope exits.
import Foundation
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeAgentRuntime

final class ActiveParentTestAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let gate = Gate()
    private let continuationAdapter: (any ProviderAdapter)?

    init(continuation: (any ProviderAdapter)? = nil) {
        continuationAdapter = continuation
    }

    actor Gate {
        private var released = false
        func release() { released = true }
        func wait() async throws {
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func release() async { await gate.release() }

    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let gate = self.gate
        let base = continuationAdapter
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "active-parent-fixture")))
            let producer = Task {
                do {
                    try await gate.wait()
                    if let base {
                        for try await event in base.stream(request: request, credentials: credentials) {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                    } else {
                        continuation.yield(.completed(.init(stopReason: .endTurn)))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            ActiveParentTestScope.registerProducer(producer)
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

enum ActiveParentTestScope {
    @TaskLocal private static var current: Session?

    enum FixtureError: Error { case missingScope, parentDidNotStart(String) }

    /// Use around the whole test, so multiple dispatches share one active
    /// parent and errors still cancel and join all work before file teardown.
    static func withScope<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        let session = Session()
        return try await $current.withValue(session) {
            do {
                let result = try await operation()
                await session.stopAll()
                return result
            } catch {
                await session.stopAll()
                throw error
            }
        }
    }

    static func activate(_ runtime: FloeAgentRuntime) async throws {
        guard let current else { throw FixtureError.missingScope }
        try await current.activate(runtime)
    }

    /// The existing scripted main-run control phase resumes the already
    /// running parent; it must not call start a second time.
    static func finish(_ runtime: FloeAgentRuntime) async throws {
        guard let current else { throw FixtureError.missingScope }
        try await current.finish(runtime)
    }

    /// Mirrors a defer, but after the runtime and provider tasks are joined.
    static func afterStop(_ cleanup: @escaping @Sendable () -> Void) throws {
        guard let current else { throw FixtureError.missingScope }
        current.afterStop(cleanup)
    }

    fileprivate static func registerProducer(_ task: Task<Void, Never>) {
        current?.registerProducer(task)
    }

    private final class Session: @unchecked Sendable {
        struct OwnedRun: Sendable {
            let runtime: FloeAgentRuntime
            let task: Task<Void, Error>
        }
        private struct Storage {
            var runs: [UUID: OwnedRun] = [:]
            var producers: [Task<Void, Never>] = []
            var cleanups: [@Sendable () -> Void] = []
        }
        private let storage = AsyncLock(Storage())

        func registerProducer(_ task: Task<Void, Never>) {
            storage.withLock { $0.producers.append(task) }
        }

        func afterStop(_ cleanup: @escaping @Sendable () -> Void) {
            storage.withLock { $0.cleanups.append(cleanup) }
        }

        func activate(_ runtime: FloeAgentRuntime) async throws {
            let id = await runtime.runID
            if storage.withLock({ $0.runs[id] == nil }) {
                // An already running real parent belongs to its original
                // test. Never start or assume cleanup ownership of it twice.
                let state = await runtime.state.name
                guard state == "idle" else {
                    guard ["preparing", "streamingModel", "waitingApproval", "executingTool", "compacting", "verifying"].contains(state) else {
                        throw FixtureError.parentDidNotStart(state)
                    }
                    return
                }
                storage.withLock { state in
                    if state.runs[id] == nil {
                        let task = Task { try await runtime.start(goal: "hold the parent for child-dispatch qualification") }
                        state.runs[id] = OwnedRun(runtime: runtime, task: task)
                    }
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if await runtime.state.name == "streamingModel" { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw FixtureError.parentDidNotStart(await runtime.state.name)
        }

        func finish(_ runtime: FloeAgentRuntime) async throws {
            let id = await runtime.runID
            guard let owned = storage.withLock({ $0.runs[id] }) else { throw FixtureError.missingScope }
            try await owned.task.value
        }

        func stopAll() async {
            let owned = storage.withLock { state -> [OwnedRun] in
                let owned = Array(state.runs.values)
                state.runs.removeAll()
                return owned
            }
            for run in owned { run.task.cancel() }
            for run in owned {
                await run.runtime.cancel()
                // Cancellation is expected; a failed activation already
                // propagates through the operation's error path.
                _ = try? await run.task.value
            }
            // Parent completion guarantees no later provider task can be
            // registered. Cancel and join every parked/forwarding producer.
            let producers = storage.withLock { state -> [Task<Void, Never>] in
                let producers = state.producers
                state.producers.removeAll()
                return producers
            }
            for task in producers { task.cancel() }
            for task in producers { await task.value }
            let cleanups = storage.withLock { state -> [@Sendable () -> Void] in
                let cleanups = state.cleanups
                state.cleanups.removeAll()
                return cleanups
            }
            for cleanup in cleanups.reversed() { cleanup() }
        }
    }
}
