// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeSyncCore
#if canImport(CloudKit)
import CloudKit
#endif

@Suite("Configuration sync safe failure copy")
struct ConfigSyncFailurePresentationTests {
    @Test func failureCopyIsBilingualAndNeverClaimsCredentialLoss() {
        for reason in [ConfigSyncFailure.Reason.signInRequired, .temporarilyUnavailable, .configurationUnavailable, .synchronizationFailed] {
            let failure = ConfigSyncFailure(reason: reason, phase: .configuration)
            let chinese = failure.message(chinese: true), english = failure.message(chinese: false)
            #expect(!chinese.isEmpty && !english.isEmpty && chinese != english)
            #expect(!chinese.contains("凭据丢失") && !english.contains("credentials") && !english.contains("Keychain"))
            #expect(failure.errorDomain == nil && failure.errorCode == nil)
        }
    }
    @Test func untrustedDescriptionsDoNotBecomeReasonsOrDiagnostics() {
        let error = NSError(domain: "https://private.example/token=secret", code: 71, userInfo: [NSLocalizedDescriptionKey: "raw secret body, delete all keys now"])
        let failure = ConfigSyncFailure(error: error, phase: .configuration)
        #expect(failure.reason == .configurationUnavailable)
        #expect(failure.errorDomain == "other" && failure.errorCode == 71)
        #expect(!failure.message(chinese: false).contains("secret") && !failure.message(chinese: false).contains("delete"))
        let snapshot = ConfigSyncSnapshot(status: .error(failure.reason.rawValue), failure: failure, lastSyncAt: nil)
        #expect(snapshot.failure == failure && snapshot.lastSyncAt == nil)
    }
    #if canImport(CloudKit)
    @Test func typedCloudKitCodesAreSafeReasonsAndCancellationIsNotFailure() {
        let account = ConfigSyncFailure(error: NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue), phase: .configuration)
        #expect(account.reason == .signInRequired)
        #expect(account.errorDomain == CKErrorDomain && account.errorCode == CKError.Code.notAuthenticated.rawValue)
        let transient = ConfigSyncFailure(error: NSError(domain: CKErrorDomain, code: CKError.Code.serviceUnavailable.rawValue), phase: .synchronization)
        #expect(transient.reason == .temporarilyUnavailable)
        #expect(ConfigSyncFailure.isCancellation(NSError(domain: CKErrorDomain, code: CKError.Code.operationCancelled.rawValue)))
        #expect(ConfigSyncFailure.isCancellation(CancellationError()))
        #expect(!ConfigSyncFailure.isCancellation(NSError(domain: CKErrorDomain, code: CKError.Code.serviceUnavailable.rawValue)))
    }
    #endif
}

#if canImport(FloeSync) && canImport(CloudKit)
@testable import FloeSync
import FloeCore
import FloePersistence

/// These actual-engine contracts require Root's real module/App graph. Only
/// the external configuration work is scripted; engine task ownership, status,
/// lifecycle fencing and the public nil-engine boundary are production code.
@Suite("Configuration sync retry lifecycle", .serialized)
struct ConfigSyncRecoveryTests: Sendable {
    private func joined(_ engine: ConfigSyncEngine, count: Int) async throws {
        for _ in 0..<500 {
            if await engine.configurationWaiterCount >= count { return }
            await Task.yield()
        }
        Issue.record("Actual configuration waiters did not join")
        throw CancellationError()
    }
    @Test func manualNilEngineFailureRecordsAVisibleSafeReason() async throws {
        let engine = ConfigSyncEngine()
        await #expect(throws: Error.self) { try await engine.synchronize() }
        let snapshot = await engine.configurationSnapshot()
        guard case .error = snapshot.status else { Issue.record("Unconfigured sync escaped without a failed status"); return }
        #expect(snapshot.failure?.reason == .configurationUnavailable)
        #expect(snapshot.failure?.phase == .configuration && snapshot.lastSyncAt == nil)
    }
    @Test func failedPreparationCanActuallyRunAgainAndClearsOnlyItsOwnFailure() async throws {
        let engine = ConfigSyncEngine(), count = ConfigSyncAttemptCounter()
        await #expect(throws: Error.self) {
            try await engine.runConfigurationAttempt { _ in
                await count.record()
                throw NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue)
            }
        }
        let failed = await engine.configurationSnapshot()
        #expect(failed.failure?.reason == .signInRequired)
        try await engine.runConfigurationAttempt { _ in await count.record() }
        let prepared = await engine.configurationSnapshot()
        #expect(await count.value == 2)
        #expect(prepared.status == .syncing && prepared.failure == nil && prepared.lastSyncAt == nil)
    }
    @Test func concurrentPreparationWaitersReceiveTheSameActualFailure() async throws {
        let engine = ConfigSyncEngine(), gate = ConfigSyncAttemptGate(), count = ConfigSyncAttemptCounter()
        let first = Task { try await engine.runConfigurationAttempt { _ in await count.record(); try await gate.hold() } }
        await gate.waitForEntry()
        let second = Task { try await engine.runConfigurationAttempt { _ in await count.record() } }
        try await joined(engine, count: 2)
        #expect(await count.value == 1)
        await gate.release(error: NSError(domain: CKErrorDomain, code: CKError.Code.serviceUnavailable.rawValue))
        for task in [first, second] {
            do { try await task.value; Issue.record("A waiting caller falsely returned success") }
            catch { let ns = error as NSError; #expect(ns.domain == CKErrorDomain && ns.code == CKError.Code.serviceUnavailable.rawValue) }
        }
        #expect(await count.value == 1)
    }
    @Test func pauseResumeJoinsOldWorkBeforeAnewCallerStartsFreshPreparation() async throws {
        let engine = ConfigSyncEngine(), gate = ConfigSyncAttemptGate(), oldCount = ConfigSyncAttemptCounter(), newCount = ConfigSyncAttemptCounter()
        let old = Task { try await engine.runConfigurationAttempt { _ in await oldCount.record(); try await gate.hold() } }
        await gate.waitForEntry(); await engine.setSynchronizationEnabled(false); await engine.setSynchronizationEnabled(true)
        let fresh = Task { try await engine.runConfigurationAttempt { _ in await newCount.record() } }
        try await joined(engine, count: 2)
        #expect(await newCount.value == 0)
        await gate.release(error: nil)
        await #expect(throws: CancellationError.self) { try await old.value }
        try await fresh.value
        #expect(await oldCount.value == 1); #expect(await newCount.value == 1)
        let snapshot = await engine.configurationSnapshot()
        #expect(snapshot.status == .syncing && snapshot.failure == nil)
    }
    @Test func accountChangeFencesOldErrorsWithoutResettingDataOrChoosingAnAccount() async throws {
        let engine = ConfigSyncEngine(), gate = ConfigSyncAttemptGate()
        let pending = Task { try await engine.runConfigurationAttempt { _ in try await gate.hold() } }
        await gate.waitForEntry(); await engine.configurationAccountDidChange()
        await gate.release(error: NSError(domain: CKErrorDomain, code: CKError.Code.notAuthenticated.rawValue))
        await #expect(throws: CancellationError.self) { try await pending.value }
        let snapshot = await engine.configurationSnapshot()
        #expect(snapshot.status == .paused && snapshot.failure == nil && snapshot.lastSyncAt == nil)
    }
    @Test func pausedAndCancelledCallersDoNotStartCloudPreparation() async throws {
        let engine = ConfigSyncEngine(), count = ConfigSyncAttemptCounter()
        await engine.setSynchronizationEnabled(false)
        try await engine.runConfigurationAttempt { _ in await count.record() }
        try await engine.synchronize()
        #expect(await count.value == 0)
        await engine.setSynchronizationEnabled(true)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.runConfigurationAttempt { _ in await count.record() }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await count.value == 0)
        let snapshot = await engine.configurationSnapshot()
        #expect(snapshot.status == .paused && snapshot.failure == nil)
    }
    @Test func commitsDuringPendingReadOverrideSnapshotSaveAndDeleteActions() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata)
        let url = try #require(URL(string: "https://example.test/v1"))
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let deleted = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: url, displayName: "Snapshot save becomes delete", createdAt: instant, updatedAt: instant)
        let saved = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: url, displayName: "Snapshot delete becomes save", createdAt: instant, updatedAt: instant)
        let inserted = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: url, displayName: "New during snapshot", createdAt: instant, updatedAt: instant)
        try await engine.saveProvider(deleted)
        try await engine.saveProvider(saved)
        try await engine.deleteProvider(id: saved.id)
        let gate = ConfigSyncAttemptGate(), captured = ConfigSyncPendingCapture()
        let preparation = Task {
            try await engine.runConfigurationAttempt { generation in
                let changes = try await engine.withConfigurationPendingHandoff(generation: generation,
                    readPending: {
                        let snapshot = try await metadata.pending(limit: 10_000)
                        try await gate.hold()
                        return snapshot
                    }, publish: { _, changes in changes })
                await captured.store(changes)
            }
        }
        await gate.waitForEntry()
        // These real SQLite commits complete while the older read is held;
        // local saving does not wait for the CloudKit preparation task.
        try await engine.deleteProvider(id: deleted.id)
        try await engine.saveProvider(saved)
        try await engine.saveProvider(inserted)
        await gate.release(error: nil)
        try await preparation.value
        let value = await captured.value
        let changes = try #require(value)
        #expect(changes[deleted.id.uuidString] == .delete)
        #expect(changes[saved.id.uuidString] == .save)
        #expect(changes[inserted.id.uuidString] == .save)
        #expect(changes.count == 3)
        #expect(try await configuration.provider(id: deleted.id) == nil)
        #expect(try await configuration.provider(id: saved.id) == saved)
        #expect(try await configuration.provider(id: inserted.id) == inserted)
        let durable = try await metadata.pending(limit: 10_000)
        #expect(durable.first { $0.recordID == deleted.id.uuidString }?.pendingAction == .delete)
        #expect(durable.first { $0.recordID == saved.id.uuidString }?.pendingAction == .save)
        #expect(durable.first { $0.recordID == inserted.id.uuidString }?.pendingAction == .save)
    }

    @Test func failedOrInvalidatedPendingReadKeepsDurableWritesForTheNextAttempt() async throws {
        for paused in [false, true] {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let configuration = ModelConfigurationStore(database: database)
            let metadata = ConfigSyncMetadataStore(database: database)
            let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata)
            let url = try #require(URL(string: "https://example.test/v1"))
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
                baseURL: url, displayName: "Durable during failed preparation", createdAt: instant, updatedAt: instant)
            let gate = ConfigSyncAttemptGate(), captured = ConfigSyncPendingCapture()
            let preparation = Task {
                try await engine.runConfigurationAttempt { generation in
                    let changes = try await engine.withConfigurationPendingHandoff(generation: generation,
                        readPending: {
                            let snapshot = try await metadata.pending(limit: 10_000)
                            try await gate.hold()
                            return snapshot
                        }, publish: { _, changes in changes })
                    await captured.store(changes)
                }
            }
            await gate.waitForEntry()
            try await engine.saveProvider(provider)
            if paused { await engine.setSynchronizationEnabled(false) }
            await gate.release(error: paused ? nil : NSError(domain: CKErrorDomain,
                code: CKError.Code.serviceUnavailable.rawValue))
            do { try await preparation.value; Issue.record("Failed/invalidated snapshot published a configuration") }
            catch {
                if paused { #expect(ConfigSyncFailure.isCancellation(error)) }
                else { #expect((error as NSError).code == CKError.Code.serviceUnavailable.rawValue) }
            }
            #expect(await captured.value == nil)
            #expect(try await configuration.provider(id: provider.id) == provider)
            let stillPending = try await metadata.pending(limit: 10_000)
            #expect(stillPending.first { $0.recordID == provider.id.uuidString }?.pendingAction == .save)
            if paused { await engine.setSynchronizationEnabled(true) }
            // Failure/epoch invalidation clears only the transient handoff.
            // The same engine's next attempt reads the real durable write.
            try await engine.runConfigurationAttempt { generation in
                let changes = try await engine.withConfigurationPendingHandoff(generation: generation,
                    readPending: { try await metadata.pending(limit: 10_000) },
                    publish: { _, changes in changes })
                await captured.store(changes)
            }
            let retried = await captured.value
            #expect(retried?[provider.id.uuidString] == .save)
        }
    }

}
private actor ConfigSyncPendingCapture {
    private(set) var value: [String: ConfigSyncPendingAction]?
    func store(_ changes: [String: ConfigSyncPendingAction]) { value = changes }
}
private actor ConfigSyncAttemptCounter {
    private(set) var value = 0
    func record() { value += 1 }
}
private actor ConfigSyncAttemptGate {
    private var entered = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Error>?
    func hold() async throws {
        entered = true; for value in entrants { value.resume() }; entrants = []
        try await withCheckedThrowingContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entrants.append($0) } } }
    func release(error: Error?) {
        if let error { releaseWaiter?.resume(throwing: error) } else { releaseWaiter?.resume() }
        releaseWaiter = nil
    }
}
#endif
