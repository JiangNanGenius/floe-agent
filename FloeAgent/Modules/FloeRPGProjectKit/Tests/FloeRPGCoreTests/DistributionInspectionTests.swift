// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore

final class DistributionInspectionTests: XCTestCase {
    func testPublishedXPGameReportsEncryptedNativeAndRTPConditions() throws {
        let inspection = try RPGDistributionInspector.inspect(rootURL: Fixture.url("published-xp"))
        XCTAssertEqual(inspection.engine, .rpgMakerXP)
        let codes = Set(inspection.diagnostics.map(\.code))
        XCTAssertTrue(codes.contains(.encryptedArchivePresent))
        XCTAssertTrue(codes.contains(.nativeRuntimeRequired))
        XCTAssertTrue(codes.contains(.rtpReferenced))
        XCTAssertTrue(codes.contains(.dataMissing))
        // Every file importable; archive + binaries flagged.
        for file in inspection.files {
            XCTAssertTrue(inspection.fileStates[file]?.contains(.importable) == true, "\(file) importable")
        }
        XCTAssertTrue(inspection.fileStates["Game.rgssad"]?.contains(.encrypted) == true)
        XCTAssertTrue(inspection.fileStates["RGSS100J.dll"]?.contains(.nativeBinary) == true)
        XCTAssertTrue(inspection.fileStates["Game.exe"]?.contains(.nativeBinary) == true)
    }

    func testEditorProjectWithReadableData() throws {
        let inspection = try RPGDistributionInspector.inspect(rootURL: Fixture.url("mv-project"))
        XCTAssertEqual(inspection.engine, .rpgMakerMV)
        XCTAssertTrue(inspection.diagnostics.contains(where: { $0.code == .playableWebBundle }))
        XCTAssertTrue(inspection.fileStates["data/Map001.json"]?.contains(.editable) == true)
        XCTAssertTrue(inspection.fileStates["data/Actors.json"]?.contains(.readable) == true)
    }

    func testEditorXPProjectClassifiesPlainDataFiles() throws {
        let inspection = try RPGDistributionInspector.inspect(rootURL: Fixture.url("xp-project"))
        XCTAssertEqual(inspection.engine, .rpgMakerXP)
        XCTAssertFalse(inspection.diagnostics.contains(where: { $0.code == .encryptedArchivePresent }))
        XCTAssertTrue(inspection.fileStates["Data/Map001.rxdata"]?.contains(.editable) == true)
        XCTAssertTrue(inspection.diagnostics.contains(where: { $0.code == .readableDataPresent }))
    }

    func testVXAceProjectDetectedByExtension() throws {
        let inspection = try RPGDistributionInspector.inspect(rootURL: Fixture.url("ace-project"))
        XCTAssertEqual(inspection.engine, .rpgMakerVXAce)
    }

    func testNonProjectFolderReportsNoMarkers() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("RPGDistEmpty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data("hello".utf8).write(to: empty.appendingPathComponent("readme.txt"))
        let inspection = try RPGDistributionInspector.inspect(rootURL: empty)
        XCTAssertNil(inspection.engine)
        XCTAssertTrue(inspection.diagnostics.contains(where: { $0.code == .noProjectMarkers }))
        XCTAssertTrue(inspection.fileStates["readme.txt"]?.contains(.importable) == true)
    }
}
