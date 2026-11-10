import Foundation
import Testing
@testable import FloeHeavyEditorSupport

private enum QualificationFailure: Error { case deadline, expectedFailure }

@MainActor
private final class Captured<Value: Sendable> {
    var result: Result<Value, any Error>?
}

@MainActor
private final class Events {
    var values: [String] = []
    var cancelled: [UUID] = []
    var timeouts = 0
    var callbacks: [String: HeavyEditorCallbackBridge<Int>.Completion] = [:]
}

@Suite("RQ21 FIFO ownership and callback lifecycle", .serialized)
@MainActor
struct EditorOperationStateTests {
    private func capture<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) -> (Task<Void, Never>, Captured<Value>) {
        let box = Captured<Value>()
        let task = Task { @MainActor in
            do { box.result = .success(try await operation()) }
            catch { box.result = .failure(error) }
        }
        return (task, box)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw QualificationFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func result<Value: Sendable>(_ box: Captured<Value>) async throws -> Result<Value, any Error> {
        try await until { box.result != nil }
        return box.result!
    }

    private func cancelled<Value: Sendable>(_ result: Result<Value, any Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }

    @Test("Cancelling a middle caller returns promptly but cannot let its successor bypass a running predecessor")
    func cancelledMiddleKeepsFIFOBarrier() async throws {
        let queue = HeavyEditorOperationQueue<Int>(), gate = HeavyEditorOneShot<Void>(), events = Events()
        let (first, firstResult) = capture {
            try await queue.execute { _ in
                events.values.append("first-start")
                try await gate.value()
                events.values.append("first-end")
                return 1
            }
        }
        defer { gate.resolve(.success(())); first.cancel() }
        try await until { queue.activeID != nil }
        let (middle, middleResult) = capture {
            try await queue.execute { _ in events.values.append("cancelled-body"); return 2 }
        }
        let (last, lastResult) = capture {
            try await queue.execute { _ in events.values.append("last"); return 3 }
        }
        defer { middle.cancel(); last.cancel() }
        try await until { queue.pendingCount == 2 }
        middle.cancel()
        #expect(cancelled(try await result(middleResult)))
        #expect(events.values == ["first-start"])
        #expect(lastResult.result == nil)
        gate.resolve(.success(()))
        #expect(try await result(firstResult).get() == 1)
        #expect(try await result(lastResult).get() == 3)
        #expect(events.values == ["first-start", "first-end", "last"])
    }

    @Test("Active cancellation belongs to one ID and holds the execution barrier until its uncooperative body exits")
    func activeCancellationKeepsOwnedBarrier() async throws {
        let queue = HeavyEditorOperationQueue<Int>(), gate = HeavyEditorOneShot<Void>(), events = Events()
        let ownID = UUID()
        let (first, firstResult) = capture {
            try await queue.execute(id: ownID, onCancel: { events.cancelled.append($0) }) { _ in
                events.values.append("first")
                try await gate.value() // deliberately does not react to Task cancellation
                events.values.append("first-exit")
                return 1
            }
        }
        defer { gate.resolve(.success(())); first.cancel() }
        try await until { events.values == ["first"] }
        let (next, nextResult) = capture {
            try await queue.execute(onCancel: { events.cancelled.append($0) }) { _ in
                events.values.append("next"); return 2
            }
        }
        defer { next.cancel() }
        try await until { queue.pendingCount == 1 }
        first.cancel()
        #expect(cancelled(try await result(firstResult)))
        try await until { events.cancelled == [ownID] }
        queue.cancelActive() // idempotent stop for the same owned operation
        #expect(events.cancelled == [ownID])
        #expect(!queue.isActive(ownID))
        #expect(nextResult.result == nil)
        gate.resolve(.success(()))
        #expect(try await result(nextResult).get() == 2)
        #expect(events.cancelled == [ownID])
        #expect(events.values == ["first", "first-exit", "next"])
    }

    @Test("Cancellation before admission neither starts a body nor stops another operation")
    func cancellationBeforeAdmissionDoesNotStart() async throws {
        let queue = HeavyEditorOperationQueue<Int>(), events = Events()
        let (task, output) = capture {
            try await queue.execute(onCancel: { events.cancelled.append($0) }) { _ in
                events.values.append("unexpected"); return 1
            }
        }
        task.cancel()
        #expect(cancelled(try await result(output)))
        #expect(events.values.isEmpty)
        #expect(events.cancelled.isEmpty)
        #expect(queue.pendingCount == 0)
    }

    @Test("Bounded admission rejects only the new excess request")
    func fullQueueRetainsExistingWork() async throws {
        let queue = HeavyEditorOperationQueue<Int>(capacity: 2), gate = HeavyEditorOneShot<Void>(), events = Events()
        let (first, firstResult) = capture { try await queue.execute { _ in try await gate.value(); return 1 } }
        defer { gate.resolve(.success(())); first.cancel() }
        try await until { queue.activeID != nil }
        let (second, secondResult) = capture { try await queue.execute { _ in 2 } }
        defer { second.cancel() }
        try await until { queue.pendingCount == 1 }
        do {
            _ = try await queue.execute { _ in events.values.append("excess"); return 3 }
            Issue.record("Excess request was admitted")
        } catch let error as HeavyEditorOperationStateError {
            #expect(error == .queueFull)
        }
        #expect(events.values.isEmpty)
        gate.resolve(.success(()))
        #expect(try await result(firstResult).get() == 1)
        #expect(try await result(secondResult).get() == 2)
    }

    @Test("A missing provider callback times out as failure once and late completion is discarded")
    func missingCallbackIsBounded() async throws {
        let bridge = HeavyEditorCallbackBridge<Int>(), events = Events()
        let (task, output) = capture {
            try await bridge.perform(timeout: .milliseconds(20), onTimeout: { events.timeouts += 1 }) {
                events.callbacks["late"] = $0
            }
        }
        defer { task.cancel(); bridge.invalidate() }
        if case .failure(let error) = try await result(output) {
            #expect(error as? HeavyEditorOperationStateError == .timedOut)
        } else { Issue.record("Timeout was reported as success") }
        #expect(events.timeouts == 1)
        #expect(bridge.pendingCount == 0)
        events.callbacks["late"]?(.success(19))
        #expect(events.timeouts == 1)
        if case .failure(let error) = output.result {
            #expect(error as? HeavyEditorOperationStateError == .timedOut)
        } else { Issue.record("Late provider changed the timed-out outcome") }
    }

    @Test("One callback cancellation cannot stop a concurrent independent callback")
    func callbackCancellationIsPerRequest() async throws {
        let bridge = HeavyEditorCallbackBridge<Int>(), events = Events()
        let firstID = UUID()
        let (first, firstResult) = capture {
            try await bridge.perform(timeout: .seconds(1), onCancel: { events.cancelled.append(firstID) }) { events.callbacks["first"] = $0 }
        }
        let (second, secondResult) = capture {
            try await bridge.perform(timeout: .seconds(1), onCancel: { events.values.append("wrong-cancel") }) { events.callbacks["second"] = $0 }
        }
        defer { first.cancel(); second.cancel(); bridge.invalidate() }
        try await until { events.callbacks.count == 2 }
        first.cancel()
        #expect(cancelled(try await result(firstResult)))
        try await until { events.cancelled == [firstID] }
        events.callbacks["second"]?(.success(7))
        #expect(try await result(secondResult).get() == 7)
        events.callbacks["first"]?(.success(99))
        #expect(events.values.isEmpty)
        #expect(bridge.pendingCount == 0)
        #expect(cancelled(firstResult.result!))
    }

    @Test("Duplicate synchronous callbacks keep the first value and resume once")
    func callbacksAreOneShot() async throws {
        let bridge = HeavyEditorCallbackBridge<Int>()
        defer { bridge.invalidate() }
        let value = try await bridge.perform(timeout: .seconds(1)) { complete in
            complete(.success(11))
            complete(.failure(QualificationFailure.expectedFailure))
            complete(.success(12))
        }
        #expect(value == 11)
        #expect(bridge.pendingCount == 0)
    }

    @Test("Cancelling a caller does not pretend its provider has settled, and settlement belongs to one owner")
    func providerSettlementIsSeparateAndOwned() async throws {
        let bridge = HeavyEditorCallbackBridge<Int>(), events = Events()
        let owner = UUID(), otherOwner = UUID()
        let (first, firstResult) = capture {
            try await bridge.perform(timeout: .seconds(1), owner: owner) { events.callbacks["first"] = $0 }
        }
        let (other, _) = capture {
            try await bridge.perform(timeout: .seconds(1), owner: otherOwner) { events.callbacks["other"] = $0 }
        }
        defer { first.cancel(); other.cancel(); bridge.invalidate() }
        try await until { events.callbacks.count == 2 }
        first.cancel()
        #expect(cancelled(try await result(firstResult)))
        #expect(!(await bridge.waitForSettlement(owner: owner, timeout: .milliseconds(20))))
        #expect(bridge.pendingCount == 2)
        events.callbacks["first"]?(.success(42))
        #expect(await bridge.waitForSettlement(owner: owner, timeout: .milliseconds(20)))
        #expect(bridge.pendingCount == 1) // another owner is still running
        #expect(!(await bridge.waitForSettlement(owner: otherOwner, timeout: .milliseconds(20))))
        bridge.invalidate()
        #expect(!(await bridge.waitForSettlement(owner: owner, timeout: .milliseconds(20))))
    }

    @Test("Concurrent producer and cancellation outcomes have exactly one winner")
    func oneShotResolutionIsThreadSafe() async throws {
        let shot = HeavyEditorOneShot<Int>()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for value in 0..<32 {
                group.addTask { shot.resolve(.success(value)) }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
        #expect((0..<32).contains(try await shot.value()))
    }

    @Test("A failed or timed-out operation releases its host lease once and keeps its original error")
    func failedOperationReleasesOnce() async throws {
        let bridge = HeavyEditorCallbackBridge<Int>(), events = Events()
        defer { bridge.invalidate() }
        let (task, output) = capture {
            try await heavyEditorWithLeaseRelease(release: {
                await MainActor.run { events.values.append("released") }
            }, operation: {
                try await bridge.perform(timeout: .milliseconds(20)) { _ in }
            })
        }
        defer { task.cancel() }
        if case .failure(let error) = try await result(output) {
            #expect(error as? HeavyEditorOperationStateError == .timedOut)
        } else { Issue.record("Failed leased operation was reported as successful") }
        #expect(events.values == ["released"])
    }

    @Test("A dead page generation rejects waiting and future calls; a late callback cannot reopen it")
    func invalidatedGenerationCannotPublish() async throws {
        let bridge = HeavyEditorCallbackBridge<Int>(), events = Events()
        let oldGeneration = bridge.generation
        let (task, output) = capture {
            try await bridge.perform(timeout: .seconds(1)) { events.callbacks["old"] = $0 }
        }
        defer { task.cancel(); bridge.invalidate() }
        try await until { events.callbacks["old"] != nil }
        bridge.invalidate()
        if case .failure(let error) = try await result(output) {
            #expect(error as? HeavyEditorOperationStateError == .invalidated)
        } else { Issue.record("Invalidated page completed successfully") }
        #expect(bridge.generation != oldGeneration)
        #expect(!bridge.isValid)
        events.callbacks["old"]?(.success(42))
        do {
            _ = try await bridge.perform(timeout: .seconds(1)) { _ in events.values.append("unexpected-start") }
            Issue.record("Dead page admitted another provider call")
        } catch let error as HeavyEditorOperationStateError {
            #expect(error == .invalidated)
        }
        #expect(events.values.isEmpty)
        #expect(bridge.pendingCount == 0)
    }
}
