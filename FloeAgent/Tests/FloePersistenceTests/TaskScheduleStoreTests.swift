import Foundation
import Testing
@testable import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.TaskScheduleStore")
struct TaskScheduleStoreTests {
    @Test("One-time schedule becomes disabled after its actual start")
    func onceDisables() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteTaskScheduleStore(database: database)
        let dueAt = Date().addingTimeInterval(-60)
        let schedule = TaskScheduleRecord(
            title: "One time", prompt: "Do it", cadence: .once, scheduledAt: dueAt
        )
        try await store.save(schedule)
        #expect(try await store.due(at: Date()).map(\.id) == [schedule.id])

        let actual = Date()
        try await store.markStarted(id: schedule.id, at: actual)
        let saved = try #require(try await store.schedules().first)
        #expect(saved.isEnabled == false)
        #expect(saved.nextExpectedAt == nil)
        #expect(saved.lastStartedAt != nil)
    }

    @Test("Daily schedule advances from actual execution time")
    func dailyAdvances() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteTaskScheduleStore(database: database)
        let schedule = TaskScheduleRecord(
            title: "Daily", prompt: "Report", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60)
        )
        try await store.save(schedule)
        let actual = Date()
        try await store.markStarted(id: schedule.id, at: actual)
        let saved = try #require(try await store.schedules().first)
        #expect(saved.isEnabled)
        #expect(abs((saved.nextExpectedAt?.timeIntervalSince(actual) ?? 0) - 86_400) < 5)
    }
}
