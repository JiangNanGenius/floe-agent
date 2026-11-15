// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameNarrativeKit
import FloeGameCore

final class NarrativeImportRetentionTests: XCTestCase {
    func testCartridgeAndStoryImportsRetainMetadataCustomKeysNoticesAndEmptyDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for engine in [GameEngineID.twine, .tic80, .wasm4] {
            let source = root.appendingPathComponent(engine.rawValue + "-external")
            let target = root.appendingPathComponent(engine.rawValue + "-imported")
            switch engine {
            case .twine: try GameTwineAdapter.createProject(at: source, title: "External")
            case .tic80: try GameTIC80Adapter.createProject(at: source, title: "External")
            case .wasm4: try GameWasm4Adapter.createProject(at: source, title: "External")
            default: XCTFail("Unsupported fixture")
            }
            try FileManager.default.removeItem(at: source.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt"))
            let metadata = try JSONSerialization.data(withJSONObject: [
                "engine": engine.rawValue, "title": "Keep this title", "unknown": ["keep": true]
            ], options: [.prettyPrinted])
            let inputs = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "engine": engine.rawValue, "movement": [String: [String]](),
                "buttons": [["id": "custom", "keys": ["shift", "z"]]]
            ])
            let notice = Data("Copyright external fixture author. Original custom terms.\n".utf8)
            try metadata.write(to: source.appendingPathComponent("project.json"))
            try inputs.write(to: source.appendingPathComponent(NarrativeInputs.fileName))
            try notice.write(to: source.appendingPathComponent("LICENSE"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
            let unknown = Data([0, 1, 2, 3, 255])
            try unknown.write(to: source.appendingPathComponent("unknown.bin"))
            switch engine {
            case .twine: try GameTwineAdapter.importProject(from: source, to: target, title: "Fallback")
            case .tic80: try GameTIC80Adapter.importProject(from: source, to: target, title: "Fallback")
            case .wasm4: try GameWasm4Adapter.importProject(from: source, to: target, title: "Fallback")
            default: XCTFail("Unsupported fixture")
            }
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("project.json")), metadata)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(NarrativeInputs.fileName)), inputs)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("original/LICENSE")), notice)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("original/unknown.bin")), unknown)
            XCTAssertTrue((try target.appendingPathComponent("original/empty/nested").resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), metadata)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(NarrativeInputs.fileName)), inputs)
        }
    }
}
