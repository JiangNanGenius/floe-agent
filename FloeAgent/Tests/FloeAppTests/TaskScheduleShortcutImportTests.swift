// Focused state-machine regressions for the signed-template import lane.
//
// All system contact is injected: no UIApplication open, no real share
// sheet, no Shortcuts app. The tests pin the honesty contract:
//   • without a bundled signed template the UI stays manual-only;
//   • each attempt records exactly what Floe did (prepared → opened /
//     handed off / cancelled / failed), with fresh unique temp bytes;
//   • display evidence persists across instances (relaunch) for ONE schedule
//     and never for another;
//   • the user-confirmed mark is separate from observed states;
//   • the attempt vocabulary contains no "installed"/"imported" state —
//     opening is never labelled as adding;
//   • ONLY actual handoff/confirmation durably (re)starts silent monitoring
//     (the SQLite row that later lets a real retirement open cleanup);
//     failed/cancelled imports persist nothing.

#if canImport(UIKit) && canImport(SwiftUI) && DEBUG
import Foundation
import Testing
import FloeModels
import FloePersistence
@testable import FloeApp

@MainActor
private final class Written: @unchecked Sendable {
    var urls: [URL] = []
}

@MainActor
private func makeCleanupStore() throws -> TaskScheduleCleanupReminderStore {
    let database = try DatabaseManager.inMemory()
    try database.migrate()
    return TaskScheduleCleanupReminderStore(database: database)
}

@MainActor
private func makeModel(
    templateData: Data?,
    opener: ((URL) async -> Bool)? = nil,
    tempWriter: ((Data, String) -> URL?)? = nil,
    scheduleID: UUID,
    title: String,
    written: Written,
    suite: UserDefaults,
    cleanupStore: TaskScheduleCleanupReminderStore? = nil
) -> TaskScheduleShortcutImport {
    let model = TaskScheduleShortcutImport(
        templateReader: { templateData },
        tempWriter: tempWriter ?? { data, name in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-import-test-\(name)")
            try? data.write(to: url, options: .atomic)
            written.urls.append(url)
            return url
        },
        fileOpener: opener,
        defaults: suite
    )
    model.refresh(scheduleID: scheduleID, title: title, cleanupStore: cleanupStore)
    return model
}

@Suite("FloeApp.TaskScheduleShortcutImport")
@MainActor
struct TaskScheduleShortcutImportTests {

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "floe.tests.\(UUID().uuidString)")!
    }

    private func cleanup(_ suite: UserDefaults, _ written: Written) {
        written.urls.forEach { try? FileManager.default.removeItem(at: $0) }
        suite.removePersistentDomain(forName: suite.suiteName ?? "")
    }

    @Test("No bundled template keeps the manual-only path with zero durable writes")
    func noTemplate() async throws {
        let suite = makeSuite()
        let written = Written()
        let store = try makeCleanupStore()
        let scheduleID = UUID()
        let model = makeModel(
            templateData: nil, scheduleID: scheduleID, title: "T",
            written: written, suite: suite, cleanupStore: store)
        #expect(model.availability == .noTemplate)
        await model.presentImport()
        #expect(model.evidence?.attempt == nil)
        #expect(written.urls.isEmpty)
        #expect(try await store.reminder(scheduleID: scheduleID) == nil)
        cleanup(suite, written)
    }

    @Test("A present template becomes ready with a stable digest")
    func readyDigest() async throws {
        let data = Data("signed-template-bytes".utf8)
        let suite = makeSuite()
        let written = Written()
        let model = makeModel(
            templateData: data, scheduleID: UUID(), title: "T",
            written: written, suite: suite)
        guard case .ready(let digest) = model.availability else {
            Issue.record("expected .ready")
            cleanup(suite, written)
            return
        }
        #expect(digest?.count == 8)
        let suite2 = makeSuite()
        let written2 = Written()
        let model2 = makeModel(
            templateData: data, scheduleID: UUID(), title: "T",
            written: written2, suite: suite2)
        if case .ready(let digest2) = model2.availability {
            #expect(digest2 == digest)   // deterministic content digest
        }
        cleanup(suite, written)
        cleanup(suite2, written2)
    }

    @Test("Successful open records importFlowOpened AND silent monitoring")
    func openedPath() async throws {
        let data = Data("signed-v1".utf8)
        let suite = makeSuite()
        let written = Written()
        let store = try makeCleanupStore()
        let scheduleID = UUID()
        var handedURLs: [URL] = []
        let model = makeModel(
            templateData: data,
            opener: { url in
                handedURLs.append(url)
                return true
            },
            scheduleID: scheduleID,
            title: "Morning report",
            written: written,
            suite: suite,
            cleanupStore: store
        )
        #expect(model.availability != .noTemplate)
        await model.presentImport()
        #expect(model.evidence?.attempt?.state == .importFlowOpened)
        #expect(model.shareItem == nil)
        let handed = try #require(handedURLs.first)
        #expect((try? Data(contentsOf: handed)) == data)
        // Durable monitoring: silent row, captured title, NOT an open list.
        let row = try #require(try await store.reminder(scheduleID: scheduleID))
        #expect(row.status == .monitoring)
        #expect(row.setupSource == .importFlowOpened)
        #expect(row.title == "Morning report")
        #expect(try await store.openReminders().isEmpty)
        // Second attempt must be a NEW file, never a replayed handoff.
        await model.presentImport()
        #expect(written.urls.count == 2)
        #expect(written.urls[0].path != written.urls[1].path)
        #expect(model.evidence?.attempt?.templateDigest != nil)
        cleanup(suite, written)
    }

    @Test("Refused open falls back to share: completion monitors, cancel does not")
    func shareFallback() async throws {
        let suite = makeSuite()
        let written = Written()
        let store = try makeCleanupStore()
        let scheduleID = UUID()
        let model = makeModel(
            templateData: Data("x".utf8),
            opener: { _ in false },
            scheduleID: scheduleID,
            title: "Shared plan",
            written: written,
            suite: suite,
            cleanupStore: store
        )
        await model.presentImport()
        // Until the sheet finishes, only the prepared file is claimed AND
        // nothing durable has been monitored yet.
        #expect(model.evidence?.attempt?.state == .filePrepared)
        #expect(model.shareItem != nil)
        #expect(try await store.reminder(scheduleID: scheduleID) == nil)
        await model.finishShareSheet(completed: true)
        #expect(model.evidence?.attempt?.state == .handedOffToUser)
        #expect(model.shareItem == nil)
        let row = try #require(try await store.reminder(scheduleID: scheduleID))
        #expect(row.setupSource == .handedOffToUser)
        // Re-entrant dismissal cannot double-record.
        await model.finishShareSheet(completed: false)
        #expect(model.evidence?.attempt?.state == .handedOffToUser)

        let suite2 = makeSuite()
        let written2 = Written()
        let store2 = try makeCleanupStore()
        let other = UUID()
        let model2 = makeModel(
            templateData: Data("y".utf8),
            opener: { _ in false },
            scheduleID: other,
            title: "Cancelled plan",
            written: written2,
            suite: suite2,
            cleanupStore: store2
        )
        await model2.presentImport()
        await model2.finishShareSheet(completed: false)
        #expect(model2.evidence?.attempt?.state == .cancelled)
        // A cancelled handoff can never claim anything: NO monitoring row.
        #expect(try await store2.reminder(scheduleID: other) == nil)
        cleanup(suite, written)
        cleanup(suite2, written2)
    }

    @Test("Unwritable temp copy records failed and persists nothing durable")
    func failureStates() async throws {
        let suite = makeSuite()
        let store = try makeCleanupStore()
        let scheduleID = UUID()
        let model = TaskScheduleShortcutImport(
            templateReader: { Data("z".utf8) },
            tempWriter: { _, _ in nil },
            fileOpener: { _ in true },
            defaults: suite
        )
        model.refresh(scheduleID: scheduleID, title: "F", cleanupStore: store)
        await model.presentImport()
        #expect(model.evidence?.attempt?.state == .failed)
        #expect(try await store.reminder(scheduleID: scheduleID) == nil)
        cleanup(suite, Written())
    }

    @Test("Evidence persists across relaunch for its schedule only")
    func persistsPerSchedule() async throws {
        let data = Data("persist-me".utf8)
        let first = UUID()
        let second = UUID()
        let suite = makeSuite()
        let written = Written()
        let store = try makeCleanupStore()
        let model = makeModel(
            templateData: data,
            opener: { _ in true },
            scheduleID: first,
            title: "Persisted",
            written: written,
            suite: suite,
            cleanupStore: store
        )
        await model.presentImport()
        #expect(model.evidence?.attempt?.state == .importFlowOpened)

        // "Relaunch": fresh model instances over the same suite + database.
        let relaunched = TaskScheduleShortcutImport(
            templateReader: { data },
            defaults: suite
        )
        relaunched.refresh(scheduleID: first, title: "Persisted", cleanupStore: store)
        #expect(relaunched.evidence?.attempt?.state == .importFlowOpened)
        let row = try #require(try await store.reminder(scheduleID: first))
        #expect(row.status == .monitoring)
        let other = TaskScheduleShortcutImport(
            templateReader: { data },
            defaults: suite
        )
        other.refresh(scheduleID: second, title: "Other", cleanupStore: store)
        #expect(other.evidence == nil)
        #expect(try await store.reminder(scheduleID: second) == nil)

        // The user-confirmed mark persists, stays distinct from the
        // observed attempt, and UPGRADES the monitoring source.
        await model.markSetupConfirmedByUser()
        let relaunched2 = TaskScheduleShortcutImport(
            templateReader: { data },
            defaults: suite
        )
        relaunched2.refresh(scheduleID: first, title: "Persisted", cleanupStore: store)
        #expect(relaunched2.evidence?.userConfirmedSetup == true)
        #expect(relaunched2.evidence?.attempt?.state == .importFlowOpened)
        let confirmedRow = try #require(try await store.reminder(scheduleID: first))
        #expect(confirmedRow.setupSource == .userConfirmed)
        cleanup(suite, written)
    }

    @Test("Explicit confirmation alone starts monitoring (manual path)")
    func manualConfirmationIsMonitored() async throws {
        let suite = makeSuite()
        let store = try makeCleanupStore()
        let scheduleID = UUID()
        let model = makeModel(
            templateData: nil, scheduleID: scheduleID, title: "Manual only",
            written: Written(), suite: suite, cleanupStore: store)
        // No template: still no import button, but the user's OWN explicit
        // confirmation of a manually created automation is valid evidence.
        await model.markSetupConfirmedByUser()
        let row = try #require(try await store.reminder(scheduleID: scheduleID))
        #expect(row.status == .monitoring)
        #expect(row.setupSource == .userConfirmed)
        #expect(try await store.openReminders().isEmpty)
        cleanup(suite, Written())
    }

    @Test("Handoff monitoring then a real delete opens exactly one cleanup")
    func monitoredDeleteOpensCleanup() async throws {
        let database = try DatabaseManager.inMemory()
        try database.migrate()
        let suite = makeSuite()
        let store = TaskScheduleCleanupReminderStore(database: database)
        let schedules = SQLiteTaskScheduleStore(database: database)
        let record = TaskScheduleRecord(
            title: "Imported plan", prompt: "p", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60))
        try await schedules.save(record)

        let model = makeModel(
            templateData: Data("tpl".utf8),
            opener: { _ in true },
            scheduleID: record.id,
            title: record.title,
            written: Written(),
            suite: suite,
            cleanupStore: store
        )
        await model.presentImport()
        try await schedules.delete(id: record.id)
        let open = try await store.openReminders()
        #expect(open.count == 1)
        #expect(open.first?.reason == .deleted)
        #expect(open.first?.title == "Imported plan")
        cleanup(suite, Written())
    }

    @Test("The attempt vocabulary has no installed/imported state")
    func honestVocabulary() {
        // Freeze the honesty contract: nothing an opening can report as a
        // completed system install.
        #expect(Set(TaskScheduleImportAttemptState.allCases.map(\.rawValue))
                == ["filePrepared", "importFlowOpened", "handedOffToUser",
                    "cancelled", "failed"])
    }
}
#endif
