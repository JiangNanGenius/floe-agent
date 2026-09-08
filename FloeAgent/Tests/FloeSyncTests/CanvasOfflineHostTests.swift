#if canImport(CloudKit)
import Testing
import FloeCore
import FloePersistence
@testable import FloeSync

@Suite("Canvas without a CloudKit host")
struct CanvasOfflineHostTests {
    @Test("Local-only construction avoids default-container lookup and reports sync unavailable")
    func localCanvasDoesNotRequireCloudKit() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let service = CanvasCloudAssetService(
            localOnlyStore: CreativeAssetStore(database: database),
            operationStore: CanvasSyncOperationStore(database: database)
        )
        await #expect(throws: FloeError.self) {
            try await service.prepare()
        }
        await service.releasePending()
        #expect(try await CanvasSyncOperationStore(database: database).pending().isEmpty)
    }
}
#endif
