// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameGDevelopKit

private func fixtureDirectory() throws -> URL {
    if let url = Bundle.module.url(forResource: "official-5.6.287-export",
                                   withExtension: nil, subdirectory: "Fixtures") {
        return url
    }
    if let resources = Bundle.module.resourceURL {
        let fallback = resources.appendingPathComponent("Fixtures/official-5.6.287-export")
        if FileManager.default.fileExists(atPath: fallback.appendingPathComponent("index.html").path) {
            return fallback
        }
    }
    throw GameGDevelopExportBridgeError.io("test fixture")
}

private func temporaryExport() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-gdevelop-bridge-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.copyItem(at: try fixtureDirectory(), to: root)
    for name in [GameGDevelopExportBridge.fileName,
                 GameGDevelopExportBridge.manifestFileName] {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
    }
    return root
}

@Suite("GDevelop export bridge decoration")
struct GameGDevelopExportBridgeTests {
    @Test("stamps the reviewed bridge and deterministic provenance")
    func decorate() throws {
        let root = try temporaryExport()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIndex = try Data(contentsOf: root.appendingPathComponent("index.html"))
        let receipt = try GameGDevelopExportBridge.decorate(directory: root)
        #expect(!receipt.alreadyDecorated)
        #expect(receipt.bridgeCreated)
        #expect(receipt.changed)
        #expect(receipt.bridgeSHA256 == GameGDevelopExportBridge.pinnedSourceSHA256)
        let index = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(index.components(separatedBy: GameGDevelopExportBridge.scriptTag).count == 2)
        #expect(GameDigest.sha256(originalIndex) == receipt.indexSHA256Before)
        let bridge = try Data(contentsOf: root.appendingPathComponent(GameGDevelopExportBridge.fileName))
        let expectedBridge = try GameGDevelopExportBridge.sourceData
        #expect(bridge == expectedBridge)
        let manifestURL = root.appendingPathComponent(GameGDevelopExportBridge.manifestFileName)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
        #expect(manifest?["bridgeSHA256"] as? String == receipt.bridgeSHA256)
        #expect(manifest?["indexSHA256After"] as? String == receipt.indexSHA256After)
        let second = try GameGDevelopExportBridge.decorate(directory: root)
        #expect(second.alreadyDecorated)
        #expect(!second.changed)
        #expect(second.indexSHA256After == receipt.indexSHA256After)
        let afterSecond = try Data(contentsOf: root.appendingPathComponent("index.html"))
        #expect(GameDigest.sha256(afterSecond) == receipt.indexSHA256After)
        // The source fixture itself is never edited.
        let sourceIndex = try Data(contentsOf: try fixtureDirectory().appendingPathComponent("index.html"))
        #expect(GameDigest.sha256(sourceIndex) == GameDigest.sha256(originalIndex))
    }

    @Test("rejects an index that is not the official GDJS entry")
    func incompatibleIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gdevelop-bad-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><html><body>not a game</body></html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        try Data("var x = 1;\n".utf8).write(to: root.appendingPathComponent("data.js"))
        try Data("var gdjs = {};\n".utf8).write(to: root.appendingPathComponent("gd.js"))
        #expect(throws: GameGDevelopExportBridgeError.self) {
            _ = try GameGDevelopExportBridge.decorate(directory: root)
        }
        #expect(!FileManager.default.fileExists(atPath:
            root.appendingPathComponent(GameGDevelopExportBridge.fileName).path))
    }

    @Test("never overwrites a different floe-developer.js")
    func collision() throws {
        let root = try temporaryExport()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("// user file\n".utf8)
            .write(to: root.appendingPathComponent(GameGDevelopExportBridge.fileName))
        #expect(throws: GameGDevelopExportBridgeError.self) {
            _ = try GameGDevelopExportBridge.decorate(directory: root)
        }
        let index = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(!index.contains(GameGDevelopExportBridge.scriptTag))
    }
}
