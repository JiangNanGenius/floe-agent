// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

enum Fixture {
    static var root: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }
    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-rgss-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeContext(root: URL, projectID: UUID = UUID(), owner: GameProjectOwner,
                 revision: String = "fixture-r1", environment: String? = "env-rgss") throws -> GameProjectContext {
    try GameProjectContext(projectID: projectID, owner: owner, rootURL: root,
                           savedRevision: revision, environmentID: environment)
}

func runtimePackOrSkip() throws -> RGSSRuntimePack {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["FLOE_RGSS_RUNTIME_PACK"], !path.isEmpty else {
        throw XCTSkip("set FLOE_RGSS_RUNTIME_PACK to the reviewed engine pack")
    }
    return try RGSSRuntimePack(directory: URL(fileURLWithPath: path))
}

final class RGSSInputDeclarationTests: XCTestCase {
    func testStandardDeclarationMatchesTapirNativeDefaults() throws {
        let value = try RGSSInputDeclaration.standard(for: .rpgMakerXP)
        XCTAssertEqual(value.schemaVersion, 1)
        XCTAssertEqual(value.engine, .rpgMakerXP)
        XCTAssertEqual(value.movement.left, ["left"])
        XCTAssertEqual(value.movement.right, ["right"])
        XCTAssertEqual(value.movement.up, ["up"])
        XCTAssertEqual(value.movement.down, ["down"])
        XCTAssertEqual(value.buttons.map(\.id), ["confirm", "cancel", "action1", "action2", "action3"])
        XCTAssertEqual(value.buttons[0].keys, ["c"])
        XCTAssertEqual(value.buttons[1].keys, ["x"])
        XCTAssertEqual(value.buttons[2].keys, ["shift"])
        XCTAssertEqual(value.buttons[3].keys, ["q"])
        XCTAssertEqual(value.buttons[4].keys, ["w"])
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "z", engine: .rpgMakerXP), "A")
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "x", engine: .rpgMakerXP), "B")
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "c", engine: .rpgMakerXP), "C")
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "z", engine: .rpgMakerVXAce), "C")
        XCTAssertNil(RGSSKeyRuntimeMapping.button(for: "c", engine: .rpgMakerVXAce))
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "shift", engine: .rpgMakerVXAce), "A")
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "q", engine: .rpgMakerVXAce), "L")
        XCTAssertEqual(RGSSKeyRuntimeMapping.button(for: "w", engine: .rpgMakerVXAce), "R")
        try value.validate()
    }

    func testDeclarationJSONRoundTripAndValidation() throws {
        let value = try RGSSInputDeclaration.standard(for: .rpgMakerVXAce)
        XCTAssertEqual(value.buttons[0].keys, ["z"])
        XCTAssertEqual(value.buttons[2].keys, ["shift"])
        XCTAssertFalse(value.buttons.flatMap(\.keys).contains("c"))
        let data = try value.jsonData()
        let decoded = try RGSSInputDeclaration.decode(data, expectedEngine: .rpgMakerVXAce)
        XCTAssertEqual(value, decoded)
        XCTAssertThrowsError(try RGSSInputDeclaration.decode(data, expectedEngine: .rpgMakerXP))
        XCTAssertThrowsError(try RGSSInputDeclaration(engine: .rpgMakerXP,
            movement: .init(left: [], right: ["right"], up: ["up"], down: ["down"]),
            buttons: []).validate())
        XCTAssertThrowsError(try RGSSInputDeclaration(engine: .rpgMakerXP,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [.init(id: "confirm", label: "Z", keys: ["z"]),
                      .init(id: "confirm", label: "X", keys: ["x"])]).validate())
        XCTAssertThrowsError(try RGSSInputDeclaration(engine: .rpgMakerXP,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [.init(id: "bad", label: "Bad", keys: ["rm -rf /"])]).validate())
    }

    func testTemplateDeclarationsExistForAllThreeEngines() throws {
        for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
            let value = try RGSSInputDeclaration.standard(for: engine)
            XCTAssertEqual(value.engine, engine)
            try value.validate()
            if engine != .rpgMakerXP {
                XCTAssertEqual(value.buttons[0].keys, ["z"])
                XCTAssertEqual(value.buttons[2].keys, ["shift"])
            }
        }
    }
}

final class RGSSSaveStateTests: XCTestCase {
    func testEnvelopeRoundTripAndFileBytes() throws {
        let bytes = Data([0x04, 0x08, 0x7b, 0x0a, 0x00, 0x41, 0x42])
        let file = RGSSSaveFile(name: "Save1.rxdata", bytes: bytes.count,
                                data: bytes.base64EncodedString(),
                                sha256: RGSSRuntimePack.digest(bytes))
        let envelope = RGSSSaveEnvelope(engine: .rpgMakerXP, files: [file],
                                        stats: .init(frames: 12))
        let encoded = try envelope.encoded()
        let decoded = try RGSSSaveEnvelope.decode(encoded, expectedEngine: .rpgMakerXP)
        XCTAssertEqual(try decoded.fileBytes()["Save1.rxdata"], bytes)
        XCTAssertEqual(decoded.stats?.frames, Optional(12))
    }

    func testUnsafeOrCorruptSavesReject() throws {
        let bytes = Data([1, 2, 3])
        let badName = RGSSSaveEnvelope(engine: .rpgMakerXP, files: [
            .init(name: "../Save1.rxdata", bytes: 3, data: bytes.base64EncodedString())
        ], truncated: false, stats: nil)
        XCTAssertThrowsError(try badName.encoded())
        let badCount = RGSSSaveEnvelope(engine: .rpgMakerXP, files: [
            .init(name: "Save1.rxdata", bytes: 99, data: bytes.base64EncodedString())
        ], truncated: false, stats: nil)
        XCTAssertThrowsError(try badCount.encoded())
        let badDigest = RGSSSaveEnvelope(engine: .rpgMakerXP, files: [
            .init(name: "Save1.rxdata", bytes: 3, data: bytes.base64EncodedString(),
                  sha256: String(repeating: "0", count: 64))
        ], truncated: false, stats: nil)
        XCTAssertThrowsError(try badDigest.encoded())
        XCTAssertThrowsError(try RGSSSaveEnvelope.decode(Data("{}".utf8)))
    }

    func testProgressRepositoryUsesExistingCASStore() async throws {
        let root = try temporaryDirectory()
        let projectID = UUID()
        let owner = GameProjectOwner.space(recordID: projectID)
        let store = try RGSSProgressRepository(directory: root, projectID: projectID, owner: owner)
        let envelope = RGSSSaveEnvelope(engine: .rpgMakerXP, files: [
            .init(name: "Save1.rxdata", bytes: 3, data: Data([1, 2, 3]).base64EncodedString())
        ], truncated: false, stats: .init(frames: 1))
        let revision = try await store.save(envelope, expectedRevision: 0)
        XCTAssertEqual(revision, 1)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.envelope, Optional(envelope))
        XCTAssertEqual(loaded?.revision, Optional(UInt64(1)))
        do {
            _ = try await store.save(envelope, expectedRevision: 0)
            XCTFail("expected CAS conflict")
        } catch {
            XCTAssertEqual(error as? GameProjectError, .conflict(expected: "0", actual: "1"))
        }
    }
}
