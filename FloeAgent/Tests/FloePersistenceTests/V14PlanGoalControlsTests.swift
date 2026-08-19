import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.V14PlanGoalControls")
struct V14PlanGoalControlsTests {
    @Test("v14 persists plan scale advice and explicit Goal boundaries")
    func schema() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        #expect(DatabaseManager.currentSchemaVersion >= 14)
        let planColumns = try await database.reader { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(plan_drafts)")
                .map { $0["name"] as String })
        }
        let goalColumns = try await database.reader { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(conversation_goals)")
                .map { $0["name"] as String })
        }
        #expect(["execution_recommendation", "recommendation_reason"].allSatisfy(planColumns.contains))
        #expect(["blocking_conditions_json", "stopping_conditions_json", "revision"].allSatisfy(goalColumns.contains))
    }
}
