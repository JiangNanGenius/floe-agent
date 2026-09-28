// FloeCoreTests — BoundedRecoverableBox contract.
//
// The box backs the recoverable Linux image service. These tests pin the
// exact races primary review identified:
//   * concurrent callers coalesce onto one build and see the same result,
//   * nothing is observable until the build returns a fully wired value,
//   * a failed build publishes nothing and the next ensure retries,
//   * an external publish is never clobbered by a late build/offer.

import Foundation
import Testing
@testable import FloeCore

private final class Service: @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
}

/// Scripted build: counts invocations, and can be held at a gate so the test
/// observes the in-flight (unpublished) state.
private final class ScriptedBuild: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var result: Service?

    var invocationCount: Int { lock.withLock { invocations } }

    /// Scripts the value a released build returns.
    func script(_ service: Service?) {
        lock.withLock { result = service }
    }

    /// The closure handed to `ensure`. It blocks once at the gate.
    func make() -> @Sendable () async -> Service? {
        { [weak self] in
            guard let self else { return nil }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.withLock {
                    self.invocations += 1
                    self.arrived = true
                    self.gate = continuation
                }
            }
            return self.lock.withLock { result }
        }
    }

    func release() {
        let continuation = lock.withLock {
            let current = gate
            gate = nil
            return current
        }
        continuation?.resume()
    }

    func waitUntilArrived() async {
        while true {
            if lock.withLock({ arrived }) { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@Suite("Bounded recoverable box")
struct BoundedRecoverableBoxTests {
    @Test("Nothing is observable while the build is in flight")
    func unpublishedUntilBuildCompletes() async throws {
        let box = BoundedRecoverableBox<Service>()
        let script = ScriptedBuild()
        script.script(Service("ready"))

        let completed = Flag()
        let run = Task {
            await box.ensure(script.make())
            await completed.set()
        }
        await script.waitUntilArrived()
        #expect(box.value == nil, "a half-wired service must be observable to nobody")
        #expect(!box.isAvailable)
        #expect(!completed.isSet)
        script.release()
        _ = await run.value
        #expect(box.value?.label == "ready")
        #expect(box.isAvailable)
    }

    @Test("Concurrent callers coalesce onto one build and all succeed")
    func concurrentCallersCoalesce() async throws {
        let box = BoundedRecoverableBox<Service>()
        let script = ScriptedBuild()
        script.script(Service("shared"))

        // Launch eight ensures; every build closure blocks at the one gate.
        let results = AtomicCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let success = await box.ensure(script.make())
                    if success { await results.increment() }
                }
                try await Task.sleep(for: .milliseconds(2))
                _ = index
            }
            await script.waitUntilArrived()
            // Wait until all callers have joined the in-flight build task.
            try await Task.sleep(for: .milliseconds(80))
            #expect(box.value == nil)
            script.release()
            try await group.waitForAll()
        }
        #expect(script.invocationCount == 1, "two callers must never build twice")
        #expect(await results.value == 8)
        #expect(box.value?.label == "shared")

        // A post-ready ensure never builds again.
        let again = await box.ensure(script.make())
        #expect(again)
        #expect(script.invocationCount == 1)
    }

    @Test("A failed build publishes nothing and the next ensure retries")
    func failedBuildRetries() async throws {
        let box = BoundedRecoverableBox<Service>()

        let failing = ScriptedBuild()
        failing.script(nil)
        let firstTask = Task { await box.ensure(failing.make()) }
        await failing.waitUntilArrived()
        failing.release()
        let first = await firstTask.value
        #expect(!first, "an unwired build must answer false")
        #expect(box.value == nil)
        #expect(!box.isAvailable)

        // Retry with a ready build succeeds.
        let succeeding = ScriptedBuild()
        succeeding.script(Service("recovered"))
        let secondTask = Task { await box.ensure(succeeding.make()) }
        await succeeding.waitUntilArrived()
        succeeding.release()
        #expect(await secondTask.value)
        #expect(box.value?.label == "recovered")
    }

    @Test("An external publish survives late builds and offers")
    func externalPublishWins() async throws {
        let box = BoundedRecoverableBox<Service>()
        box.publish(Service("assembly"))
        #expect(box.value?.label == "assembly")

        // A later offer cannot clobber the present value.
        box.publish(Service("later-offer"))
        #expect(box.value?.label == "assembly")
        // A nil offer is ignored.
        box.publish(nil)
        #expect(box.value?.label == "assembly")

        // A build completing after the value already exists reports success
        // without replacing the winner.
        let script = ScriptedBuild()
        script.script(Service("late-build"))
        let task = Task { await box.ensure(script.make()) }
        // The build closure must never run when the value is already present.
        try await Task.sleep(for: .milliseconds(40))
        #expect(script.invocationCount == 0)
        script.release()
        #expect(await task.value)
        #expect(box.value?.label == "assembly")
    }
}

// MARK: - Small concurrency fixtures

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() async { lock.withLock { value = true } }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() async { lock.withLock { count += 1 } }
}
