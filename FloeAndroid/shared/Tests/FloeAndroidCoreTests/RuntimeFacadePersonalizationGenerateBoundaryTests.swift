// SPDX-License-Identifier: MPL-2.0
//
// MEM-GEN-C1 successor (2026-10-20): the public `personalization.generate`
// entry runs the real operation in an OWNED task so an accepted explicit
// `personalization.generate.cancel` can cancel the actual provider await.
// An unstructured Task does NOT inherit cancellation from the Task that
// called generate, so cancelling the CALLER (service/Root/binder lifetime
// cancellation, or an already-cancelled caller) must be bridged explicitly.
// These regressions exercise the REAL DatabaseManager (schema 46), the REAL
// provider stream contract and the REAL single-flight latch:
//
//  * a held stream (one delta, then no next delta and no finish) is
//    terminated by cancelling ONLY the public caller Task, with no
//    generate.cancel command and no fixture release on the passing path;
//  * an already-cancelled caller binds no operation and dispatches no model;
//  * a caller cancellation while the child is queued behind a REAL writer is
//    refused by the same atomic unsealed decision (zero writes);
//  * once the real writer closure has begun/sealed, caller cancellation does
//    not fabricate a cancellation: the commit stays the honest terminal.
//
// The held-fixture release exists ONLY as post-failure diagnostic cleanup so
// a pre-fix run cannot hang the suite; a passing assertion path never calls
// it (the provider must observe consumer cancellation instead).

import XCTest
import Foundation
import GRDB
import Crypto
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

/// A real `ProviderAdapter` whose stream yields ONE delta and then neither
/// yields again nor finishes. Only consumer-task cancellation (or the
/// post-failure diagnostic `releaseHeldStream`) can end it.
final class CallerCancelHeldStreamAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private let lock = NSLock()
    private var requests = 0
    private var cancelled = false
    private var released = false
    private var continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    private let firstDelta: SyntheticGate

    init(firstDelta: SyntheticGate) { self.firstDelta = firstDelta }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var recordedCancellation: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock(); requests += 1; lock.unlock()
        let gate = firstDelta
        return AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    self.lock.lock(); self.cancelled = true; self.lock.unlock()
                }
            }
            continuation.yield(.textDelta(AgentEvent.TextDelta(text: "# held\n")))
            Task { await gate.signal() }
            // Deliberately no further yield and no finish: a future-delta
            // cancellation check alone can never wake this stream.
        }
    }

    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }

    /// DIAGNOSTIC ONLY: end a still-held fixture AFTER a bounded observation
    /// already recorded a failure. Idempotent; never used by a passing path.
    func releaseHeldStream() {
        lock.lock()
        guard !released, let continuation else { lock.unlock(); return }
        released = true
        self.continuation = nil
        lock.unlock()
        continuation.finish()
    }
}

/// Route that hands out the held adapter for the first generate and a real
/// scripted adapter for every later call, so a retry runs on the SAME
/// `FacadePersonalizationGenerate` actor and therefore proves that actor's
/// single-flight latch was released at the real terminal.
final class HeldThenScriptedRoute: PersonalizationRouteProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let held: any ProviderAdapter
    private let retry: any ProviderAdapter
    private let provider: ProviderProfile
    private let model: ModelProfile

    init(held: any ProviderAdapter, retry: any ProviderAdapter,
         provider: ProviderProfile, model: ModelProfile) {
        self.held = held
        self.retry = retry
        self.provider = provider
        self.model = model
    }

    func textOnlyRoute() async -> PersonalizationRouteOutcome {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        return .resolved(PersonalizationGenerateModelInput(
            provider: provider, model: model,
            credentials: ProviderCredentials(apiKey: nil),
            adapter: call == 1 ? held : retry))
    }
}

final class RuntimeFacadePersonalizationGenerateCallerCancellationTests: XCTestCase {
    private var manager: DatabaseManager!
    private var url: URL!
    private var workspaces: SQLiteWorkspaceStore!
    private var provider: ProviderProfile!
    private var model: ModelProfile!

    override func setUp() async throws {
        let made = try await IntelligenceTestSupport.makeDatabase(
            "gencc-\(UUID().uuidString.prefix(8))")
        manager = made.0
        url = made.1
        workspaces = SQLiteWorkspaceStore(database: manager)
        provider = ProviderProfile(kind: .openAI,
                                   wireProtocol: .openAIChatCompletions,
                                   baseURL: URL(string: "https://synthetic.invalid")!)
        model = ModelProfile(providerID: provider.id,
                             remoteModelID: "synthetic-aux",
                             displayName: "Synthetic",
                             limits: ModelLimits(contextTokens: 8_192,
                                                 maxOutputTokens: 1_024),
                             capabilities: [.text])
    }

    override func tearDown() async throws {
        IntelligenceTestSupport.cleanup(url)
    }

    private func seedActiveMemories() async throws {
        for content in ["prefers terse answers", "works on hk host",
                        "reviews plans before edits"] {
            _ = try await IntelligenceTestSupport.seedMemory(
                manager, content: content, importance: 0.6)
        }
    }

    private func counts() async throws -> (docs: Int64, cursors: Int64) {
        let docs = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_documents")
        }
        let cursors = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        return (docs ?? 0, cursors ?? 0)
    }

    /// Bounded observation of the provider's REAL consumer-cancellation
    /// termination. Polling only bounds the diagnostic run; the assertion is
    /// the provider-observed `.cancelled` termination itself.
    private func waitForProviderCancellation(_ adapter: CallerCancelHeldStreamAdapter,
                                             timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if adapter.recordedCancellation { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return adapter.recordedCancellation
    }

    // MARK: - Caller cancellation while the provider stream is held

    func testCallerTaskCancellationTerminatesHeldStreamWithoutExplicitCancel() async throws {
        try await seedActiveMemories()
        let firstDelta = SyntheticGate()
        let held = CallerCancelHeldStreamAdapter(firstDelta: firstDelta)
        let retryScript = SyntheticModelAdapter(scripts: [
            SyntheticModelAdapter.Script(deltas: ["# retried after caller cancel\n"]),
        ])
        let route = HeldThenScriptedRoute(
            held: held,
            retry: SyntheticAdapterBox(adapter: retryScript),
            provider: provider, model: model)
        let generate = FacadePersonalizationGenerate(
            database: manager, workspaceStore: workspaces, route: route)
        let running = Task {
            try await generate.generate(kind: .soul, workspaceID: nil,
                                        operationReceiptID: "op-caller-held")
        }
        await firstDelta.wait()
        XCTAssertEqual(held.requestCount, 1,
                       "the operation dispatched exactly one real model request")
        // NO generate.cancel command and NO adapter release: only the public
        // caller Task is cancelled. The owned generation must observe it.
        running.cancel()
        let terminated = await waitForProviderCancellation(held)
        XCTAssertTrue(terminated,
                      "cancelling the public caller Task must terminate a held stream with no next delta")
        XCTAssertTrue(held.recordedCancellation,
                      "the provider stream must observe real consumer cancellation")
        if !terminated {
            // A failure is already recorded. Clean the held fixture NOW so a
            // pre-fix diagnostic run cannot hang; the passing path never
            // reaches this branch and never uses cleanup as cancellation.
            held.releaseHeldStream()
            _ = try? await running.value
            return
        }
        do {
            _ = try await running.value
            XCTFail("caller cancellation must not let the held stream commit")
        } catch let canceled as MemoryOperationCanceled {
            XCTAssertEqual(canceled, .phase(.streaming),
                           "the frozen cancel grammar reports the real stream phase")
        } catch {
            XCTFail("caller cancellation must surface canceled{phase}, got \(error)")
        }
        let after = try await counts()
        XCTAssertEqual(after.docs, 0, "zero documents after caller cancellation")
        XCTAssertEqual(after.cursors, 0, "zero cursor mutations after caller cancellation")
        // The receipt reached a truthful canceled terminal through the SAME
        // registry (no new statuses): a late command cancel reads it back.
        let late = try await XCTUnwrapAsync(
            await generate.cancel(operationReceiptID: "op-caller-held"))
        XCTAssertEqual(late.status, .canceled)
        XCTAssertEqual(late.phase, .streaming)
        // A retry on the SAME actor proves the real single-flight latch was
        // released only after the owned task's terminal.
        let effect = try await generate.generate(kind: .soul, workspaceID: nil,
                                                 operationReceiptID: "op-caller-held-retry")
        XCTAssertEqual(effect.outcome, .active)
        let retryRequests = await retryScript.requestCount
        XCTAssertEqual(retryRequests, 1)
        let afterRetry = try await counts()
        XCTAssertEqual(afterRetry.docs, 1)
    }

    // MARK: - Already-cancelled caller before binding

    func testAlreadyCancelledCallerBindsNothingAndDispatchesNoModel() async throws {
        try await seedActiveMemories()
        let adapter = SyntheticModelAdapter(scripts: [
            SyntheticModelAdapter.Script(deltas: ["# never dispatched while cancelled\n"]),
        ])
        let generate = FacadePersonalizationGenerate(
            database: manager, workspaceStore: workspaces,
            route: FixedProviderRoute(adapter: SyntheticAdapterBox(adapter: adapter),
                                      provider: provider, model: model))
        let started = SyntheticGate()
        let caller = Task {
            await started.wait()
            return try await generate.generate(kind: .soul, workspaceID: nil,
                                               operationReceiptID: "op-caller-precancelled")
        }
        // Deterministic already-cancelled-before-binding schedule: the task
        // is cancelled while parked, and only then is the generate entry
        // allowed to run.
        caller.cancel()
        await started.signal()
        do {
            _ = try await caller.value
            XCTFail("an already-cancelled caller must not bind a generation")
        } catch is CancellationError {
            // Expected: no operation receipt/latch was ever created.
        } catch {
            XCTFail("an already-cancelled caller must observe CancellationError, got \(error)")
        }
        let requests = await adapter.requestCount
        XCTAssertEqual(requests, 0, "no model request may be dispatched")
        let after = try await counts()
        XCTAssertEqual(after.docs, 0)
        XCTAssertEqual(after.cursors, 0)
        let receipt = await generate.cancel(operationReceiptID: "op-caller-precancelled")
        XCTAssertNil(receipt, "no operation receipt was bound")
        // The untouched first script is still available for a real retry on
        // the same actor: the pre-cancelled call consumed nothing.
        let effect = try await generate.generate(kind: .soul, workspaceID: nil,
                                                 operationReceiptID: "op-caller-precancelled-retry")
        XCTAssertEqual(effect.outcome, .active)
        let afterRetry = await adapter.requestCount
        XCTAssertEqual(afterRetry, 1)
    }

    // MARK: - Caller cancellation while the child is queued on a REAL writer

    func testCallerCancelWhileQueuedBehindWriterWinsWithZeroWrites() async throws {
        try await seedActiveMemories()
        let writerGate = WriterBeganGate()
        let database: DatabaseManager = try XCTUnwrap(manager)
        let hold = Task { try await database.writer { _ in writerGate.enter() } }
        let entered = await writerGate.waitUntilEntered()
        XCTAssertTrue(entered, "the real writer must be held")
        let reachedPreWriter = SyntheticGate()
        let adapter = SyntheticModelAdapter(scripts: [
            SyntheticModelAdapter.Script(deltas: ["# queued caller cancel\n"]),
        ])
        let generate = FacadePersonalizationGenerate(
            database: manager, workspaceStore: workspaces,
            route: FixedProviderRoute(adapter: SyntheticAdapterBox(adapter: adapter),
                                      provider: provider, model: model),
            beforeCommitHook: { await reachedPreWriter.signal() })
        let running = Task {
            try await generate.generate(kind: .soul, workspaceID: nil,
                                        operationReceiptID: "op-caller-queued")
        }
        await reachedPreWriter.wait()
        // Let the owned operation actually block on the real writer handoff;
        // being queued is NOT commit-started.
        try? await Task.sleep(nanoseconds: 300_000_000)
        running.cancel()
        // Task.cancel invokes the cancellation handler synchronously; it
        // marks the same unsealed registry decision an accepted cancel uses
        // before the writer queue is released.
        writerGate.release()
        _ = try? await hold.value
        do {
            _ = try await running.value
            XCTFail("a caller cancellation while queued must not write after the writer opens")
        } catch let canceled as MemoryOperationCanceled {
            XCTAssertEqual(canceled, .phase(.streaming))
        } catch {
            XCTFail("queued caller cancellation must surface canceled{phase}, got \(error)")
        }
        let after = try await counts()
        XCTAssertEqual(after.docs, 0, "no document row after queued caller cancellation")
        XCTAssertEqual(after.cursors, 0, "no cursor row after queued caller cancellation")
    }

    // MARK: - Caller cancellation after the REAL writer entered/sealed

    func testCallerCancelAfterRealWriterEnteredPreservesCommittedTerminal() async throws {
        try await seedActiveMemories()
        let writerGate = WriterBeganGate()
        let adapter = SyntheticModelAdapter(scripts: [
            SyntheticModelAdapter.Script(deltas: ["# committed despite late caller cancel\n"]),
        ])
        let generate = FacadePersonalizationGenerate(
            database: manager, workspaceStore: workspaces,
            route: FixedProviderRoute(adapter: SyntheticAdapterBox(adapter: adapter),
                                      provider: provider, model: model),
            beforeCommitHook: nil,
            insideWriterHook: { writerGate.enter() })
        let running = Task {
            try await generate.generate(kind: .soul, workspaceID: nil,
                                        operationReceiptID: "op-caller-writer")
        }
        let entered = await writerGate.waitUntilEntered()
        XCTAssertTrue(entered, "the real writer closure must have begun and sealed")
        running.cancel()
        // The irreversible boundary is already crossed: the late caller
        // cancellation must not be reported as a cancellation and ownership
        // stays until the real commit terminal.
        let reply = try await XCTUnwrapAsync(
            await generate.cancel(operationReceiptID: "op-caller-writer"))
        XCTAssertEqual(reply.status, .completed)
        XCTAssertEqual(reply.phase, .committing)
        writerGate.release()
        let effect = try await running.value
        XCTAssertEqual(effect.outcome, .active, "the real committed effect is preserved")
        let after = try await counts()
        XCTAssertEqual(after.docs, 1, "the real commit landed")
        XCTAssertEqual(after.cursors, 1, "the real cursor write landed")
        let late = try await XCTUnwrapAsync(
            await generate.cancel(operationReceiptID: "op-caller-writer"))
        XCTAssertEqual(late.status, .completed)
        XCTAssertEqual(late.phase, .committed)
    }
}
