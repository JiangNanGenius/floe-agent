// SPDX-License-Identifier: MPL-2.0
//
// G07.3B — REAL same-revision CAS regression for the scheduled-task CRUD.
//
// The service used to read the record + compare the revision, then await
// validation/other work, then call an unconditional store write. The actor is
// reentrant across those awaits, so two updates from the same base could both
// succeed (or overwrite a `lastStartedAt` written by a real launch).
//
// These tests use the REAL file-backed DatabaseManager + SQLiteTaskScheduleStore
// and a controlled latch inside validation (no sleeps, no mock DB, no serial
// test actor pretending to be the DB). The final store comparison must happen
// inside ONE writer transaction.

import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence

struct G073CASTimeout: Error {}

final class G073TaskScheduleCASRaceTests: XCTestCase {
    private var databaseURL: URL!
    private var database: DatabaseManager!
    private var store: SQLiteTaskScheduleStore!

    private let modelID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let providerID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_100)

    override func setUp() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-g073-cas-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
        store = SQLiteTaskScheduleStore(database: database)
    }

    override func tearDown() async throws {
        if let database { try? await database.close() }
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
        }
    }

    // MARK: - Deterministic gate (the only synchronization; no sleeps)

    private actor Latch {
        private(set) var arrivals = 0
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func arrive() async {
            arrivals += 1
            if released { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private struct NoopLaunch: G073ScheduledRunLaunching {
        func launchScheduled(_ request: G073ScheduledLaunchRequest) async
            -> G073ScheduledLaunchResult {
            .refused(code: "notUsed", reason: "CAS regression never launches")
        }
    }

    private func dependencies(latch: Latch?,
                              now clock: Date? = nil) -> G073TaskScheduleDependencies {
        let modelID = self.modelID
        let providerID = self.providerID
        let now = clock ?? self.fixedNow
        return G073TaskScheduleDependencies(
            launch: NoopLaunch(),
            workspaceForConversation: { _ in nil },
            workspace: { _ in nil },
            workspaces: { [] },
            model: { id in
                if let latch { await latch.arrive() }
                guard id == modelID else { return nil }
                return G073ModelSummary(
                    id: modelID, providerID: providerID,
                    displayName: "CAS model", providerName: "CAS provider",
                    supportsChat: true)
            },
            models: { [] },
            defaultModelID: { modelID },
            runState: { _ in nil },
            terminalStopReason: { _ in nil },
            claimedOccurrences: { [] },
            environmentSource: nil,
            environmentOwnership: G073ScheduleEnvironmentOwnership {
                _ in nil
            },
            now: { now })
    }

    private func seedSchedule(title: String,
                              lastStartedAt: Date? = nil) async throws
        -> TaskScheduleRecord {
        let record = TaskScheduleRecord(
            title: title,
            prompt: "A deterministic scheduled prompt.",
            cadence: .daily,
            scheduledAt: scheduledAt,
            isEnabled: true,
            lastStartedAt: lastStartedAt,
            nextExpectedAt: scheduledAt,
            createdAt: scheduledAt,
            updatedAt: scheduledAt,
            anchorTimezone: "UTC",
            modelID: modelID)
        try await store.save(record)
        return record
    }

    private func draft(title: String) -> G073ScheduleDraft {
        G073ScheduleDraft(
            title: title,
            prompt: "A deterministic scheduled prompt.",
            cadence: .daily,
            scheduledAt: scheduledAt,
            anchorTimezone: "UTC",
            modelID: modelID,
            policy: DraftTaskPolicy())
    }

    private func waitUntil(_ seconds: Double,
                           _ condition: @escaping @Sendable () async -> Bool)
        async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw G073CASTimeout()
    }

    // MARK: - Tests

    func testFractionalNowRevisionsMatchPersistedDetailAndRemainCASUsable() async throws {
        // Persisted ISO-8601 seconds keep millisecond precision; an unrounded
        // `now` must not leak a different digest into the outer revision.
        let fractionalNow = Date(timeIntervalSince1970: 1_700_000_000.1234567)
        let service = G073TaskScheduleService(
            epoch: 1, store: store,
            dependencies: dependencies(latch: nil, now: fractionalNow))

        let created = await service.create(draft(title: "fractional"))
        guard created.accepted, let createdDetail = created.detail,
              let createdRevision = created.revision else {
            return XCTFail("create must return a detail snapshot and revision")
        }
        XCTAssertEqual(createdRevision, createdDetail.summary.revision)
        let firstReadBack = await service.detail(id: createdDetail.summary.id)
        XCTAssertEqual(createdRevision, firstReadBack?.summary.revision)

        // The returned token is immediately usable as the next CAS base.
        let updated = await service.update(
            id: createdDetail.summary.id, draft: draft(title: "fractional-updated"),
            expectedRevision: createdRevision)
        guard updated.accepted, let updatedDetail = updated.detail,
              let updatedRevision = updated.revision else {
            return XCTFail("the first revision must be an immediately valid CAS base")
        }
        XCTAssertEqual(updatedRevision, updatedDetail.summary.revision)
        let secondReadBack = await service.detail(id: createdDetail.summary.id)
        XCTAssertEqual(updatedRevision, secondReadBack?.summary.revision)

        let disabled = await service.setEnabled(
            id: createdDetail.summary.id, enabled: false,
            expectedRevision: updatedRevision)
        guard disabled.accepted, let disabledDetail = disabled.detail,
              let disabledRevision = disabled.revision else {
            return XCTFail("the update revision must be an immediately valid CAS base")
        }
        XCTAssertEqual(disabledRevision, disabledDetail.summary.revision)
        let thirdReadBack = await service.detail(id: createdDetail.summary.id)
        XCTAssertEqual(disabledRevision, thirdReadBack?.summary.revision)
    }

    func testTwoSameBaseUpdatesAdmitExactlyOneAndPreserveLaunchTruth() async throws {
        let launchTruth = Date(timeIntervalSince1970: 1_799_999_000)
        let seeded = try await seedSchedule(title: "base", lastStartedAt: launchTruth)
        let revision = G073ScheduleRevision.digest(seeded)

        let latch = Latch()
        let dependencies = dependencies(latch: latch)
        let one = G073TaskScheduleService(
            epoch: 1, store: store, dependencies: dependencies)
        let two = G073TaskScheduleService(
            epoch: 1, store: store, dependencies: dependencies)
        let first = draft(title: "first")
        let second = draft(title: "second")

        async let a = one.update(
            id: seeded.id, draft: first, expectedRevision: revision)
        async let b = two.update(
            id: seeded.id, draft: second, expectedRevision: revision)
        try await waitUntil(5) { await latch.arrivals == 2 }
        await latch.release()
        let results = [await a, await b]

        XCTAssertEqual(results.filter(\.accepted).count, 1)
        let rejected = results.filter { !$0.accepted }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.code, .revisionMismatch)

        guard let accepted = results.first(where: \.accepted),
              let detail = accepted.detail else {
            return XCTFail("the one accepted update must return its detail")
        }
        let stored = try await store.schedule(id: seeded.id)
        XCTAssertEqual(stored?.title, detail.summary.title)
        XCTAssertTrue(["first", "second"].contains(detail.summary.title))
        // A real launch completion recorded before the write must survive.
        XCTAssertEqual(stored?.lastStartedAt, launchTruth)
    }

    func testALaunchDuringValidationWritesNothingAndLosesNoCompletion() async throws {
        let seeded = try await seedSchedule(title: "base", lastStartedAt: nil)
        let revision = G073ScheduleRevision.digest(seeded)
        let latch = Latch()
        let store = self.store!
        let service = G073TaskScheduleService(
            epoch: 1, store: store, dependencies: dependencies(latch: latch))
        let seededID = seeded.id
        let edited = draft(title: "edited")

        async let pending = service.update(
            id: seededID, draft: edited,
            expectedRevision: revision)
        try await waitUntil(5) { await latch.arrivals == 1 }

        // The REAL durable launch writes `lastStartedAt` while the editor is
        // still validating. The stale write must be refused, not resurrect the
        // old nil or the old title.
        let startedAt = Date(timeIntervalSince1970: 1_800_000_500)
        try await store.markStarted(id: seededID, at: startedAt)
        await latch.release()
        let result = await pending

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.code, .revisionMismatch)
        let stored = try await store.schedule(id: seededID)
        XCTAssertEqual(stored?.title, "base")
        XCTAssertEqual(stored?.lastStartedAt, startedAt)
    }

    func testSameRevisionSetEnabledHasOneWinnerAndPreservesCompletion() async throws {
        let launchTruth = Date(timeIntervalSince1970: 1_799_999_000)
        let seeded = try await seedSchedule(title: "base", lastStartedAt: launchTruth)
        let revision = G073ScheduleRevision.digest(seeded)
        let date = fixedNow
        let store = self.store!
        let seededID = seeded.id

        async let first = store.setEnabledIfUnchanged(
            id: seededID, enabled: false, expectedRevision: revision, at: date)
        async let second = store.setEnabledIfUnchanged(
            id: seededID, enabled: false, expectedRevision: revision, at: date)
        let results = [try await first, try await second]

        XCTAssertEqual(results.filter { $0 != nil }.count, 1)
        XCTAssertEqual(results.filter { $0 == nil }.count, 1)
        let stored = try await store.schedule(id: seededID)
        XCTAssertEqual(stored?.isEnabled, false)
        XCTAssertEqual(stored?.lastStartedAt, launchTruth)
    }

    func testSameRevisionDeleteHasOneWinnerAndLeavesHistoryUntouched() async throws {
        let seeded = try await seedSchedule(title: "base")
        let revision = G073ScheduleRevision.digest(seeded)
        let store = self.store!
        let seededID = seeded.id

        async let first = store.deleteIfUnchanged(
            id: seededID, expectedRevision: revision)
        async let second = store.deleteIfUnchanged(
            id: seededID, expectedRevision: revision)
        let results = [try await first, try await second]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(results.filter { !$0 }.count, 1)
        let remaining = try await store.schedule(id: seededID)
        XCTAssertNil(remaining)
    }
}
