// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSSHostCore

final class RGSSGuestSaveManagementTests: XCTestCase {
    func testSaveFilesStayOutsideSourceAndRoundTrip() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-saves")
        let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerXP,
                                           sourceRoot: source)
        try store.write(Data("slot-one".utf8), name: "Save1.rxdata")
        try store.write(Data("slot-two".utf8), name: "Save2.rxdata")
        let files = try store.list()
        XCTAssertEqual(files.map(\.name), ["Save1.rxdata", "Save2.rxdata"])
        XCTAssertEqual(try store.read("Save1.rxdata"), Data("slot-one".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("Save1.rxdata").path))

        try store.rename("Save2.rxdata", to: "Save3.rxdata")
        XCTAssertEqual(try store.list().map(\.name), ["Save1.rxdata", "Save3.rxdata"])
        try store.delete("Save3.rxdata")
        XCTAssertEqual(try store.list().map(\.name), ["Save1.rxdata"])
    }

    func testSaveNameAndByteLimitsAreEnforced() throws {
        let source = try RGSSGuestTestSupport.makeProject()
        let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-saves")
        let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerXP,
                                           sourceRoot: source)
        XCTAssertThrowsError(try store.write(Data(), name: "../Save1.rxdata"))
        XCTAssertThrowsError(try store.write(Data(), name: "Save1.rvdata"))
        XCTAssertThrowsError(try store.write(Data(repeating: 0, count: RGSSGuestSaveLimits.maximumFileBytes + 1),
                                             name: "Save1.rxdata"))
    }

    func testCheckpointRestoresExactBytes() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-saves")
        let checkpointRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-checkpoints")
        let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerXP,
                                           sourceRoot: source)
        let repository = try FileGameSaveRepository(
            directory: checkpointRoot, projectID: projectID, owner: owner,
            maximumStateBytes: 4_194_304)
        let manager = RGSSGuestSaveManager(store: store, checkpointRepository: repository)
        let original = Data((0..<4_096).map { UInt8($0 % 251) })
        try await manager.write(original, name: "Save1.rxdata")
        let revision = try await manager.checkpoint()
        XCTAssertNotNil(revision)

        try await manager.delete("Save1.rxdata")
        let restored = try await manager.restoreCheckpoint()
        XCTAssertEqual(restored, ["Save1.rxdata"])
        let readBack = try await manager.read("Save1.rxdata")
        XCTAssertEqual(readBack, original)
    }

    func testImportRequiresStandardEngineExtension() async throws {
        let source = try RGSSGuestTestSupport.makeProject()
        let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-saves")
        let external = try RGSSGuestTestSupport.temporaryDirectory("rgss-import")
        let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerVXAce,
                                           sourceRoot: source)
        let manager = RGSSGuestSaveManager(store: store)
        let good = external.appendingPathComponent("Save1.rvdata2")
        try Data("ace".utf8).write(to: good)
        _ = try await manager.importFile(from: good)
        let imported = try await manager.list().map(\.name)
        XCTAssertEqual(imported, ["Save1.rvdata2"])

        let wrong = external.appendingPathComponent("Save1.rxdata")
        try Data("xp".utf8).write(to: wrong)
        do {
            _ = try await manager.importFile(from: wrong)
            XCTFail("wrong engine extension must be rejected")
        } catch let error as RGSSGuestRunError {
            guard case .invalidSaveName = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
