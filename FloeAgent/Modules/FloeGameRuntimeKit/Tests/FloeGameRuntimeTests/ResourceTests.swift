// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameRuntime
import FloeGameCore

private struct InvalidTransport: GameEngineResourceTransport {
    func fetch(_ file: GameEngineResourceFile) async throws -> Data { Data("invalid resource".utf8) }
}

@MainActor final class ResourceTests: XCTestCase {
    func testRealLicenseAndNoticePinsAreRetained() throws {
        let specs = try GameEngineResourceCatalog.all()
        XCTAssertEqual(specs.count, 3)
        let kaplay = try GameEngineResourceCatalog.spec(.kaplay)
        XCTAssertEqual(kaplay.license, "MIT")
        XCTAssertEqual(kaplay.version, "3001.0.0")
        XCTAssertEqual(kaplay.files.first(where: { $0.path.value == "licenses/ENGINE.txt" })?.packagePath, "LICENSE")
        XCTAssertTrue(try GameEngineResourceCatalog.spec(.babylon).files.contains { $0.path.value == "licenses/NOTICE.md" })
        for spec in specs {
            XCTAssertTrue(spec.files.contains { $0.path.value == "licenses/ENGINE.txt" })
            XCTAssertEqual(Set(spec.files.map(\.path)).count, spec.files.count)
        }
    }
    func testCorruptDownloadCannotPublishAPreparedPack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GameEnginePackStore(directory: root)
        do { _ = try await store.prepare(.kaplay, transport: InvalidTransport()); XCTFail("Expected pinned-byte failure") }
        catch { XCTAssertEqual(error as? GameProjectError, .corruptStorage) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
