import XCTest
import FloeBiologyCore
import FloeBiologyEngine

final class BiologyStoreTests: XCTestCase {
    func testCreateAndRead() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("BiologyTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try BiologyProjectStore(root:root)
        let p=try await store.create(title:"Independent project")
        let read=try await store.load(p.id)
        XCTAssertEqual(read,p)
    }
}
