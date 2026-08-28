import GRDB
import Foundation
import Testing
@testable import FloePersistence

@Suite("V28 Canvas model routing")
struct V28CanvasModelRoutingTests {
    @Test("Canvas route columns are nullable foreign keys")
    func migrationAddsCanvasRoutes() async throws {
        let database = try DatabaseManager(path: temporaryDatabaseURL())
        try await database.migrate()

        let columns: Set<String> = try await database.reader { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(model_preferences)")
                .compactMap { $0["name"] as String? })
        }
        #expect(columns.contains("canvas_agent_model_id"))
        #expect(columns.contains("canvas_vision_model_id"))
        #expect(try await database.userVersion() == 28)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-v28-\(UUID().uuidString).sqlite")
    }
}
