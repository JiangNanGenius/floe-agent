import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.V15ProviderDisplayName")
struct V15ProviderDisplayNameTests {
    @Test("v15 adds the nullable provider display-name column")
    func schema() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()

        let displayNameNotNull: Int? = try await database.reader { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(providers)")
                .first { row in (row["name"] as String) == "display_name" }
                .map { row in row["notnull"] as Int }
        }
        #expect(try #require(displayNameNotNull) == 0)
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        #expect(DatabaseManager.currentSchemaVersion >= 15)
    }
}
