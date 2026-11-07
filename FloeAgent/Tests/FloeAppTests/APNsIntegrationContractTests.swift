// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Security
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
@testable import FloeApp

@Suite("APNs scheduled ownership and registration contracts", .serialized)
@MainActor struct APNsIntegrationContractTests {
    private func isolatedEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        let platform = PlatformCalls()
        environment.apnsCenter = APNsCenter(store: try APNsStateStore(directory:
            FileManager.default.temporaryDirectory.appendingPathComponent("APNs-off-\(UUID())")),
            credentials: FakeCredentials(), platform: platform.value,
            eligibility: { .unavailable }, performWake: { _ in .rejected })
        // Finish both real cold-run recovery and occurrence reconciliation
        // before creating this process's live ledger. No task is launched.
        let empty = try await environment.backgroundRunCoordinator.pushEligibilitySnapshot()
        try #require(!empty.eligible)
        return environment
    }
    private func running(_ environment: AppEnvironment, automatic: Bool?, withJob: Bool = false,
                         registerLive: Bool = true) async throws -> (UUID, UUID, UUID?) {
        let conversationID = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversationID,
            title: "APNs owned fixture", createdAt: now, updatedAt: now))
        try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID,
            state: "executingTool", goal: "APNs fixture", startedAt: now))
        var scheduleID: UUID?
        if let automatic {
            let schedule = TaskScheduleRecord(title: "APNs schedule fixture", prompt: "APNs fixture",
                cadence: .once, scheduledAt: now)
            scheduleID = schedule.id
            let store = SQLiteTaskScheduleStore(database: environment.database)
            try await store.save(schedule)
            let key = automatic ? "calendar:\(UUID().uuidString)" : "manual:\(UUID().uuidString)"
            let occurrence = TaskScheduleOccurrence(id: .init(), scheduleID: schedule.id,
                scheduledFor: now, dedupeKey: key)
            #expect(try await store.enqueueOccurrence(occurrence))
            #expect(try await store.claimOccurrence(id: occurrence.id, at: now))
            #expect(try await store.markOccurrenceRunning(id: occurrence.id, runID: runID,
                conversationID: conversationID, at: now))
            // A one-shot has no future calendar work after its launch. This
            // is the existing real transition, not a forged isEnabled fact.
            try await store.markStarted(id: schedule.id, at: now)
        }
        if withJob {
            _ = try await BackgroundJobStore(database: environment.database).save(.init(
                conversationID: conversationID, runID: runID, kind: .tool,
                targetTool: "APNsFixture.neverExecuted", payloadJSON: Data("{}".utf8)))
        }
        if registerLive {
            environment.backgroundRunCoordinator.didStart(conversationID: conversationID, runID: runID,
                title: "APNs fixture", origin: .scheduledTask)
        }
        return (runID, conversationID, scheduleID)
    }

    @Test("Manual chat, explicit Run-now, and manual jobs do not retain heartbeat eligibility")
    func manualWorkCannotQualify() async throws {
        let environment = try await isolatedEnvironment()
        _ = try await running(environment, automatic: nil, withJob: true)
        _ = try await running(environment, automatic: false, withJob: true)
        let snapshot = try await environment.backgroundRunCoordinator.pushEligibilitySnapshot()
        #expect(!snapshot.hasEnabledSchedule)
        #expect(!snapshot.hasProgressableExecution)
    }

    @Test("Real automatic occurrence remains eligible after future-plan deletion; attention and terminal states withdraw it")
    func automaticOwnershipAndAttention() async throws {
        let environment = try await isolatedEnvironment()
        let (runID, _, scheduleID) = try await running(environment, automatic: true)
        let coordinator = environment.backgroundRunCoordinator
        #expect(try await coordinator.pushEligibilitySnapshot().hasProgressableExecution)
        let durable = try #require(await environment.runStore.run(id: runID))
        try #require(durable.state == "executingTool" && durable.endedAt == nil)
        let occurrence = try #require(await SQLiteTaskScheduleStore(database: environment.database).occurrence(runID: runID))
        try #require(occurrence.state == .running)
        try await SQLiteTaskScheduleStore(database: environment.database).delete(id: try #require(scheduleID))
        // Deleting the future plan preserves an already launched execution.
        #expect(try await coordinator.pushEligibilitySnapshot().hasProgressableExecution)
        coordinator.didUpdatePendingApproval(runID: runID, toolName: "fixture.approval")
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
        coordinator.didUpdatePendingApproval(runID: runID, toolName: nil)
        #expect(try await coordinator.pushEligibilitySnapshot().hasProgressableExecution)
        coordinator.didUpdatePendingQuestion(runID: runID, requestID: "fixture-question")
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
        coordinator.didUpdatePendingQuestion(runID: runID, requestID: nil)
        coordinator.didSuspend(runID: runID, message: "Fixture suspended")
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
        coordinator.didReceiveActivity(runID: runID)
        #expect(try await coordinator.pushEligibilitySnapshot().hasProgressableExecution)
        try await environment.runStore.updateRunState(id: runID, state: "completed", endedAt: Date())
        _ = try await SQLiteTaskScheduleStore(database: environment.database).recordRunCompletion(
            runID: runID, succeeded: true, cancelled: false, summary: "Fixture complete", at: Date())
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
    }

    @Test("Future and overdue valid plans qualify independently, while scheduled jobs require a live durable parent")
    func futurePlansAndOwnedJobs() async throws {
        let environment = try await isolatedEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        for offset: TimeInterval in [3_600, -3_600] {
            let plan = TaskScheduleRecord(title: "APNs clock fixture", prompt: "Fixture",
                cadence: .once, scheduledAt: Date().addingTimeInterval(offset))
            try await store.save(plan)
            #expect(try await environment.backgroundRunCoordinator.pushEligibilitySnapshot().hasEnabledSchedule)
            try await store.delete(id: plan.id)
        }
        let (runID, _, _) = try await running(environment, automatic: true, withJob: true, registerLive: false)
        #expect(try await environment.backgroundRunCoordinator.pushEligibilitySnapshot().hasProgressableExecution)
        try await environment.runStore.updateRunState(id: runID, state: "waitingApproval", endedAt: nil)
        #expect(try await !environment.backgroundRunCoordinator.pushEligibilitySnapshot().eligible)
        try await environment.runStore.updateRunState(id: runID, state: "interrupted", endedAt: Date())
        #expect(try await !environment.backgroundRunCoordinator.pushEligibilitySnapshot().eligible)
    }

    @Test("After-success eligibility follows its exact upstream and single real occurrence, not the retained enabled flag")
    func afterSuccessIsConsumedByItsRealLifecycle() async throws {
        let environment = try await isolatedEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let coordinator = environment.backgroundRunCoordinator
        for terminal in ["failed", "cancelled"] {
            let upstreamID = UUID(), conversationID = UUID()
            try await environment.conversationStore.saveConversation(.init(id: conversationID,
                title: "APNs failed upstream fixture", createdAt: Date(), updatedAt: Date()))
            try await environment.runStore.saveRun(.init(id: upstreamID, conversationID: conversationID,
                state: terminal, goal: "Fixture", startedAt: Date(), endedAt: Date()))
            try await store.save(.init(title: "APNs terminal condition", prompt: "Fixture", cadence: .afterSuccess,
                scheduledAt: Date(), upstreamRunID: upstreamID))
            #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
        }
        let upstreamID = UUID(), upstreamConversation = UUID()
        try await environment.conversationStore.saveConversation(.init(id: upstreamConversation,
            title: "APNs successful upstream fixture", createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(id: upstreamID, conversationID: upstreamConversation,
            state: "streaming", goal: "Fixture", startedAt: Date()))
        let plan = TaskScheduleRecord(title: "APNs after-success fixture", prompt: "Fixture", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: upstreamID)
        try await store.save(plan)
        #expect(try await coordinator.pushEligibilitySnapshot().hasEnabledSchedule)
        try await environment.runStore.updateRunState(id: upstreamID, state: "completed", endedAt: Date())
        // The read path cannot manufacture an occurrence if settlement has
        // not actually armed it, even though the upstream says completed.
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
        let enqueued = try await store.recordRunCompletion(runID: upstreamID, succeeded: true,
            cancelled: false, summary: "Fixture success", at: Date())
        #expect(enqueued.count == 1)
        #expect(try await coordinator.pushEligibilitySnapshot().hasEnabledSchedule)
        let occurrenceID = try #require(enqueued.first)
        let (runID, conversationID, _) = try await running(environment, automatic: nil)
        #expect(try await store.claimOccurrence(id: occurrenceID, at: Date()))
        #expect(try await store.markOccurrenceRunning(id: occurrenceID, runID: runID,
            conversationID: conversationID, at: Date()))
        try await store.markStarted(id: plan.id, at: Date())
        let launched = try await coordinator.pushEligibilitySnapshot()
        #expect(!launched.hasEnabledSchedule && launched.hasProgressableExecution)
        coordinator.didUpdatePendingApproval(runID: runID, toolName: "fixture.approval")
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
        coordinator.didUpdatePendingApproval(runID: runID, toolName: nil)
        #expect(try await coordinator.pushEligibilitySnapshot().hasProgressableExecution)
        try await environment.runStore.updateRunState(id: runID, state: "completed", endedAt: Date())
        _ = try await store.recordRunCompletion(runID: runID, succeeded: true,
            cancelled: false, summary: "Fixture done", at: Date())
        #expect(try await store.schedule(id: plan.id)?.isEnabled == true)
        #expect(try await !coordinator.pushEligibilitySnapshot().eligible)
    }

    private final class FakeCredentials: APNsCredentials, @unchecked Sendable {
        let secretBytes = Data(repeating: 0x4a, count: 32)
        private let lock = NSLock()
        private var storedToken = Data(repeating: 0x6b, count: 32)
        func secret(installationID: UUID, create: Bool) throws -> Data? { secretBytes }
        func token(installationID: UUID) throws -> Data? { lock.withLock { storedToken } }
        func saveToken(_ token: Data, installationID: UUID) throws { lock.withLock { storedToken = token } }
    }
    private actor RenewalTransport: APNsEnrollmentTransport {
        let failure: APNsRemoteFailure
        private(set) var calls: [APNsRegistrationRequest] = []
        init(_ failure: APNsRemoteFailure) { self.failure = failure }
        func apply(_ request: APNsRegistrationRequest, installationSecret: Data) async throws -> APNsRegistrationReceipt {
            calls.append(request)
            if calls.count == 1 { throw APNsServiceError.remote(failure) }
            return .init(installationID: request.installationID, acceptedRevision: request.revision,
                enabled: request.enabled, acceptedAt: Date(), leaseExpiresAt: Date().addingTimeInterval(300))
        }
    }
    @MainActor private final class PlatformCalls {
        var registrations = 0
        var unregistrations = 0
        var visiblePrompts = 0
        var value: APNsPlatform {
            .init(authorization: { .denied }, requestVisibleAuthorization: { self.visiblePrompts += 1 },
                register: { self.registrations += 1 }, unregister: { self.unregistrations += 1 },
                backgroundRefreshAvailable: { true }, installChannel: { .development })
        }
    }
    private func settle(_ center: APNsCenter, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate(), "Bounded native state transition did not settle")
    }

    @Test("410 renewal waits for an actual OS callback, preserves installation/secret, and permits the same token under a newer revision")
    func renewalRequiresActualOSCallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-renewal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var initial = APNsPersistentState(); initial.preferences.enabled = true
        try store.save(initial)
        let transport = RenewalTransport(.tokenNeedsRenewal), calls = PlatformCalls(), credentials = FakeCredentials()
        let center = APNsCenter(store: store, signingEnvironment: .development, transport: transport,
            credentials: credentials, platform: calls.value,
            eligibility: { .init(hasEnabledSchedule: true, hasProgressableExecution: false) }, performWake: { _ in .noData })
        await center.reconcile()
        try await settle(center) { center.state.tokenRenewalPending == true }
        let before = center.preferences.revision
        #expect(calls.registrations == 2)
        #expect(calls.visiblePrompts == 0) // Denied alerts never block silent registration.
        #expect(!center.status().serverConnected)
        await center.reconcile()
        try await settle(center) { center.syncState == "waitingForDevice" }
        #expect(await transport.calls.count == 1)
        #expect(center.preferences.revision == before)
        await center.didRegister(token: Data(repeating: 0x6b, count: 32))
        try await settle(center) { center.status().serverConnected }
        #expect(center.state.installationID == initial.installationID)
        #expect(center.preferences.revision > before)
        #expect(try credentials.secret(installationID: initial.installationID, create: false) == credentials.secretBytes)
        #expect(await transport.calls.count == 2)
        let requests = await transport.calls
        #expect(requests.last?.deviceToken == requests.first?.deviceToken)
    }

    @Test("Revision conflicts never trigger renewal or replace the installation")
    func otherConflictIsTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-conflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var initial = APNsPersistentState(); initial.preferences.enabled = true
        try store.save(initial)
        let transport = RenewalTransport(.revisionConflict), calls = PlatformCalls()
        let center = APNsCenter(store: store, signingEnvironment: .development, transport: transport,
            credentials: FakeCredentials(), platform: calls.value,
            eligibility: { .init(hasEnabledSchedule: false, hasProgressableExecution: false) }, performWake: { _ in .noData })
        await center.reconcile()
        try await settle(center) { center.syncState == "failed" }
        #expect(calls.registrations == 1)
        #expect(center.state.tokenRenewalPending != true)
        #expect(center.state.installationID == initial.installationID)
        #expect(await transport.calls.count == 1)
    }

    private actor RecordingTransport: APNsEnrollmentTransport {
        private(set) var calls: [APNsRegistrationRequest] = []
        func apply(_ request: APNsRegistrationRequest, installationSecret: Data) async throws -> APNsRegistrationReceipt {
            calls.append(request)
            return .init(installationID: request.installationID, acceptedRevision: request.revision,
                enabled: request.enabled, acceptedAt: Date(), leaseExpiresAt: Date().addingTimeInterval(300))
        }
    }

    @Test("Normal finish and Stop automatically withdraw the last execution's registration even with no downstream schedule")
    func terminalBridgeAutomaticallyWithdrawsRegistration() async throws {
        for cancel in [false, true] {
            let environment = try await isolatedEnvironment()
            let (runID, _, _) = try await running(environment, automatic: true)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-terminal-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try APNsStateStore(directory: directory)
            var initial = APNsPersistentState(); initial.preferences.enabled = true
            try store.save(initial)
            let transport = RecordingTransport(), platform = PlatformCalls()
            let center = APNsCenter(store: store, signingEnvironment: .development, transport: transport,
                credentials: FakeCredentials(), platform: platform.value,
                eligibility: { [weak environment] in
                    guard let environment else { throw APNsServiceError.unavailable }
                    return try await environment.backgroundRunCoordinator.pushEligibilitySnapshot()
                }, performWake: { _ in .noData })
            environment.apnsCenter = center
            await center.reconcile()
            try await settle(center) { center.status().serverConnected && center.eligibilitySnapshot?.eligible == true }
            let registeredRevision = center.preferences.revision
            // The real runtime commits its terminal run record BEFORE this
            // normal native callback. No manual eligibility read follows it.
            try await environment.runStore.updateRunState(id: runID,
                state: cancel ? "cancelled" : "completed", endedAt: Date())
            if cancel { environment.backgroundRunCoordinator.didCancel(runID: runID, message: "Fixture stopped") }
            else { environment.backgroundRunCoordinator.didFinish(runID: runID, succeeded: true, message: "Fixture done") }
            try await settle(center) {
                center.status().serverConnected && center.eligibilitySnapshot?.eligible == false
                    && center.preferences.revision > registeredRevision
            }
            let registered = await transport.calls
            #expect(registered.first?.hasEligibleSchedules == true)
            #expect(registered.last?.hasEligibleSchedules == false)
            #expect(registered.allSatisfy { $0.installationID == initial.installationID })
            #expect(registered.last!.revision > registered.first!.revision)
            let settled = try #require(try await SQLiteTaskScheduleStore(database: environment.database).occurrence(runID: runID))
            #expect(settled.state == (cancel ? .cancelled : .completed))
        }
    }

    @Test("Opt-out or cancellation while notification authorization is suspended cannot show a late permission prompt")
    func versionPermissionRespectsOptOutAndCancellation() async throws {
        for cancelOnly in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-permission-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try APNsStateStore(directory: directory)
            var initial = APNsPersistentState(); initial.preferences.enabled = true
            try store.save(initial)
            var waiting: CheckedContinuation<APNsVisibleAuthorization, Never>?
            var queryCount = 0, promptCount = 0, unregisterCount = 0
            let platform = APNsPlatform(authorization: {
                queryCount += 1
                if queryCount == 1 { return await withCheckedContinuation { waiting = $0 } }
                return .denied
            }, requestVisibleAuthorization: { promptCount += 1 }, register: {},
               unregister: { unregisterCount += 1 }, backgroundRefreshAvailable: { true }, installChannel: { .unknown })
            let center = APNsCenter(store: store, credentials: FakeCredentials(), platform: platform,
                eligibility: { .unavailable }, performWake: { _ in .noData })
            let enablingReminder = Task { await center.setVersionReminders(true) }
            try await settle(center) { waiting != nil }
            if cancelOnly { enablingReminder.cancel() }
            else { await center.setEnabled(false) }
            let continuation = try #require(waiting)
            waiting = nil
            continuation.resume(returning: .notDetermined)
            await enablingReminder.value
            #expect(promptCount == 0)
            #expect(center.preferences.enabled == cancelOnly)
            #expect(unregisterCount == (cancelOnly ? 0 : 1))
        }
    }

    @MainActor private final class ChannelGate {
        var first: CheckedContinuation<APNsInstallChannel, Never>?
        var count = 0
        func detect() async -> APNsInstallChannel {
            count += 1
            if count == 1 { return await withCheckedContinuation { first = $0 } }
            return .testFlight
        }
    }
    private struct FixtureRelease: APNsReleaseResolving {
        let record: APNsReleaseRecord
        func release(id: String, channel: APNsInstallChannel) async throws -> APNsReleaseRecord { record }
    }
    @Test("A superseded channel detector cannot publish after a newer receipt")
    func enrollmentChannelDetectionIsFencedBeforePublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-channel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var initial = APNsPersistentState(); initial.preferences.enabled = true; try store.save(initial)
        let gate = ChannelGate(), calls = PlatformCalls(), transport = RecordingTransport()
        var platform = calls.value; platform.installChannel = { await gate.detect() }
        let center = APNsCenter(store: store, signingEnvironment: .production, transport: transport,
            credentials: FakeCredentials(), platform: platform,
            eligibility: { .unavailable }, performWake: { _ in .noData })
        let firstRetry = Task { await center.reload() }
        try await settle(center) { gate.first != nil }
        await center.reconcile()
        try await settle(center) { center.status().serverConnected && center.channel == .testFlight }
        let continuation = try #require(gate.first); gate.first = nil
        continuation.resume(returning: .unknown)
        // The explicit Retry waits for exactly its own center-owned task.
        // This assertion therefore follows completion of the old G1, not a
        // timing guess or a handle that G2 replaced while G1 was suspended.
        await firstRetry.value
        #expect(center.channel == .testFlight && center.status().serverConnected)
        #expect(await transport.calls.count == 1)
    }

    @Test("An old explicit release detector preserves the newer registered channel")
    func releaseChannelDetectionPreservesNewerEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-release-channel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var initial = APNsPersistentState(); initial.preferences.enabled = true; try store.save(initial)
        let gate = ChannelGate(), calls = PlatformCalls(), transport = RecordingTransport()
        var platform = calls.value; platform.installChannel = { await gate.detect() }
        let release = APNsReleaseRecord(id: "fixture", channel: .testFlight, version: "99", build: "999999",
            title: "Fixture", notes: "Fixture", isInstallable: true, availableAt: Date())
        let center = APNsCenter(store: store, signingEnvironment: .production, transport: transport,
            releaseLookup: FixtureRelease(record: release), credentials: FakeCredentials(), platform: platform,
            eligibility: { .unavailable }, performWake: { _ in .noData })
        let payload = APNsPayload(schemaVersion: 1, kind: .release, eventID: UUID(), installationID: initial.installationID,
            registrationRevision: 0, sentAt: Date(), expiresAt: Date().addingTimeInterval(60), releaseID: "fixture", channel: .testFlight)
        let opening = Task { await center.openRelease(payload: payload) }
        try await settle(center) { gate.first != nil }
        await center.reconcile()
        try await settle(center) { center.status().serverConnected && center.channel == .testFlight }
        let continuation = try #require(gate.first); gate.first = nil
        continuation.resume(returning: .unknown)
        await opening.value
        #expect(center.channel == .testFlight && center.status().serverConnected)
        #expect(center.presentedRelease?.id == release.id)
    }

    private actor LateRenewalTransport: APNsEnrollmentTransport {
        private(set) var suspended: CheckedContinuation<APNsRegistrationReceipt, Error>?
        private(set) var count = 0
        func apply(_ request: APNsRegistrationRequest, installationSecret: Data) async throws -> APNsRegistrationReceipt {
            count += 1
            if count == 1 { return try await withCheckedThrowingContinuation { suspended = $0 } }
            return .init(installationID: request.installationID, acceptedRevision: request.revision,
                enabled: request.enabled, acceptedAt: Date(), leaseExpiresAt: Date().addingTimeInterval(300))
        }
        func failFirst() { let continuation = suspended; suspended = nil; continuation?.resume(throwing: APNsServiceError.remote(.tokenNeedsRenewal)) }
    }
    @Test("A revision advanced before permission settles fences an older typed renewal response")
    func lateRenewalCannotMutateNewerRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-renewal-revision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var initial = APNsPersistentState(); initial.preferences.enabled = true; try store.save(initial)
        let transport = LateRenewalTransport(), calls = PlatformCalls()
        var authorizationCount = 0
        var waiting: CheckedContinuation<APNsVisibleAuthorization, Never>?
        var platform = calls.value
        platform.authorization = {
            authorizationCount += 1
            if authorizationCount == 2 { return await withCheckedContinuation { waiting = $0 } }
            return .denied
        }
        let center = APNsCenter(store: store, signingEnvironment: .development, transport: transport,
            credentials: FakeCredentials(), platform: platform,
            eligibility: { .unavailable }, performWake: { _ in .noData })
        await center.reconcile()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await transport.suspended == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await transport.suspended != nil)
        let oldRevision = center.preferences.revision
        let reminder = Task { await center.setVersionReminders(true) }
        try await settle(center) { waiting != nil }
        #expect(center.preferences.revision > oldRevision)
        await transport.failFirst()
        try await settle(center) { center.syncState == "pending" }
        #expect(center.state.tokenRenewalPending != true)
        #expect(center.status().deviceRegistered)
        #expect(calls.registrations == 1)
        let continuation = try #require(waiting); waiting = nil; continuation.resume(returning: .denied)
        await reminder.value
        try await settle(center) { center.status().serverConnected }
        #expect(center.state.installationID == initial.installationID && center.state.tokenRenewalPending != true)
    }

    @Test("Only the APNs installation's legacy secret/token migrate to the actual device-only background protection class")
    func scopedKeychainMigrationPreservesBytes() throws {
        let installationID = UUID(), prefix = installationID.uuidString.lowercased()
        let service = "org.floeagent.ios.push-installation"
        let legacy = KeychainStore(service: service, synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly)
        let secret = Data(repeating: 0x5c, count: 32), token = Data(repeating: 0x7d, count: 32)
        let accounts = [prefix + "/credential", prefix + "/token"]
        defer { for account in accounts { try? legacy.delete(account: account) } }
        try legacy.store(account: accounts[0], secret: secret)
        try legacy.store(account: accounts[1], secret: token)
        let vault = APNsCredentialVault()
        #expect(try vault.secret(installationID: installationID, create: false) == secret)
        #expect(try vault.token(installationID: installationID) == token)
        // An actual SecItem attribute read checks the real platform constant;
        // no enum-string-only assertion and no other user's account is read.
        for account in accounts {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false, kSecReturnAttributes as String: true]
            var result: CFTypeRef?
            #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
            let attributes = try #require(result as? [String: Any])
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
        #expect(try vault.secret(installationID: installationID, create: false) == secret)
    }
}
#endif
