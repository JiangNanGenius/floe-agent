import Foundation
import GRDB
import Testing
import FloeCore
@testable import FloePersistence

@Suite("FloePersistence.V16ProviderCompatibilityAndPackageReview")
struct V16ProviderCompatibilityAndPackageReviewTests {
    @Test("v16 persists provider compatibility and package review routing")
    func persistence() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = ModelConfigurationStore(database: database)
        var provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.com")!
        )
        provider.toolNameCompatibility = true
        try await store.saveProvider(provider)
        #expect(try await store.provider(id: provider.id)?.toolNameCompatibility == true)

        let columns: Set<String> = try await database.reader { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(model_preferences)")
                .map { $0["name"] as String })
        }
        #expect(columns.contains("package_review_model_id"))
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)
        #expect(DatabaseManager.currentSchemaVersion >= 16)
    }
}
