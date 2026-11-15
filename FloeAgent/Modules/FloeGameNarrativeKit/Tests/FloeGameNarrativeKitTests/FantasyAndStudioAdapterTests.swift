// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

final class Wasm4AdapterTests: XCTestCase {
    func testStarterCartIsGenuineWASM4Module() throws {
        let cart = try GameWasm4Adapter.starterCart()
        XCTAssertGreaterThan(cart.count, 64)
        XCTAssertEqual([UInt8](cart.prefix(4)), [0x00, 0x61, 0x73, 0x6D])
        XCTAssertEqual([UInt8](cart.prefix(8)), [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        let exports = try WasmModuleReader.exports(cart)
        XCTAssertTrue(exports.contains("start"))
        XCTAssertTrue(exports.contains("update"))
        // The starter's mutable state must be captured by upstream saveGameState.
        XCTAssertTrue(exports.contains("px"))
        XCTAssertTrue(exports.contains("py"))
        XCTAssertTrue(exports.contains("frames"))
        // The label lives in a data segment the cartridge's text call reads.
        XCTAssertTrue(String(decoding: cart, as: UTF8.self).contains(GameWasm4Adapter.starterLabel))
    }

    func testCreateBuildAndPackage() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("wasm4")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameWasm4Adapter.createProject(at: project, title: "Postie Dot")
        let cart = try NarrativeTestSupport.read(project.appendingPathComponent("cart.wasm"))
        XCTAssertEqual(try WasmModuleReader.exports(cart).contains("update"), true)

        let artifact = work.appendingPathComponent("artifact")
        try GameWasm4Adapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("cart.wasm")), cart)
        let runtime = try NarrativeTestSupport.read(artifact.appendingPathComponent("wasm4.js"))
        XCTAssertEqual(GameDigest.sha256(runtime), GameWasm4Adapter.runtimeSHA256)
        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        XCTAssertTrue(html.contains("<wasm4-app>"))
        XCTAssertTrue(html.contains("wasm4.js"))
        XCTAssertTrue(html.contains("support/wasm4-bridge.js"))
        XCTAssertFalse(html.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("saveGameState"))
        XCTAssertTrue(support.contains("loadGameState"))
        XCTAssertTrue(support.contains("app.inputState.gamepad[0] = pad()"))
        // The restore parameter must not shadow the app lookup helper.
        XCTAssertTrue(support.contains("function gameApp()"))
        XCTAssertTrue(support.contains("const app2 = gameApp()"))
        XCTAssertFalse(support.contains("const app2 = state()"))
        XCTAssertFalse(support.contains("FLOE WASM-4 POSTIE"))

        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .wasm4)
        try package.verify()
        XCTAssertEqual(package.prepared.engine, .wasm4)
    }

    func testImportOriginalCart() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("wasm4-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let cart = try GameWasm4Adapter.starterCart()
        try cart.write(to: source.appendingPathComponent("game.wasm"))
        try Data("{\"unknown\":true}".utf8).write(to: source.appendingPathComponent("meta.json"))
        let target = work.appendingPathComponent("imported")
        try GameWasm4Adapter.importProject(from: source, to: target, title: "Imported cart")
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("cart.wasm")), cart)
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("original/game.wasm")), cart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("project.json").path))
    }

    func testImportRejectsNonCartridge() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("wasm4-bad")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not a wasm".utf8).write(to: source.appendingPathComponent("fake.wasm"))
        XCTAssertThrowsError(try GameWasm4Adapter.importProject(from: source, to: work.appendingPathComponent("imported"), title: "Bad"))
    }
}

final class TIC80AdapterTests: XCTestCase {
    func testStarterCartChunksAndCode() throws {
        let bytes = try GameTIC80Adapter.starterCart()
        let cart = try TICCart.parse(bytes)
        XCTAssertEqual(cart.chunks.map(\.type), [TICCart.ChunkType.defaultChunk.rawValue,
                                                  TICCart.ChunkType.code.rawValue,
                                                  TICCart.ChunkType.language.rawValue])
        XCTAssertEqual(cart.language, GameTIC80Adapter.Language.js.rawValue)
        XCTAssertEqual(cart.languageName, "js")
        let code = try XCTUnwrap(cart.codeString())
        XCTAssertTrue(code.contains("// script: js"))
        XCTAssertTrue(code.contains("function TIC()"))
        XCTAssertTrue(code.contains("btn(0)"))
        // Parse -> serialize is byte-identical (real container roundtrip).
        XCTAssertEqual(cart.serialized(), bytes)
    }

    func testFullBankCodeChunkUsesZeroSizeEncoding() throws {
        // A 64 KiB CODE chunk is spelled with size 0 by upstream; parse and
        // serialize must reproduce that exact convention.
        var payload = [UInt8](repeating: 0x20, count: TICCart.bankSize)
        payload[0] = 0x2F; payload[1] = 0x2F // "//"
        var cart = TICCart(chunks: [.init(type: TICCart.ChunkType.code.rawValue, bank: 0, data: Data(payload))])
        let serialized = cart.serialized()
        let header = [UInt8](serialized.prefix(4))
        let rawHeader = UInt32(header[0]) | (UInt32(header[1]) << 8) | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
        XCTAssertEqual((rawHeader >> 8) & 0xFFFF, 0) // size field zero
        XCTAssertEqual((rawHeader & 0x1F), UInt32(TICCart.ChunkType.code.rawValue))
        let reparsed = try TICCart.parse(serialized)
        XCTAssertEqual(reparsed.codeBytes(), Data(payload))
        cart.append(.init(type: 7, bank: 0, data: Data([0xDE, 0xAD])))
        let withUnknown = cart.serialized()
        let round = try TICCart.parse(withUnknown)
        XCTAssertEqual(round.serialized(), withUnknown)
        XCTAssertEqual(round.chunks.last?.data, Data([0xDE, 0xAD]))
    }

    func testCreateBuildAndPackage() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("tic80")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameTIC80Adapter.createProject(at: project, title: "TIC Postie")
        let artifact = work.appendingPathComponent("artifact")
        try GameTIC80Adapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("cart.tic")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("cart.tic")))
        XCTAssertEqual(GameDigest.sha256(try NarrativeTestSupport.read(artifact.appendingPathComponent("tic80.js"))), GameTIC80Adapter.jsSHA256)
        XCTAssertEqual(GameDigest.sha256(try NarrativeTestSupport.read(artifact.appendingPathComponent("tic80js.wasm"))), GameTIC80Adapter.wasmSHA256)
        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let boot = try NarrativeTestSupport.text(artifact.appendingPathComponent("support/tic80-boot.js"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        XCTAssertTrue(html.contains("<canvas id=\"canvas\""))
        XCTAssertTrue(html.contains("<script src=\"tic80.js\">"))
        XCTAssertTrue(boot.contains("arguments: [\"cart.tic\"]"))
        XCTAssertFalse(html.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("window.FloeGame"))
        XCTAssertFalse(support.contains("FLOE TIC-80"))
        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .tic80)
        try package.verify()
        XCTAssertEqual(package.prepared.engine, .tic80)
    }

    func testImportOriginalCartPreservesBytes() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("tic80-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = try GameTIC80Adapter.starterCart()
        try bytes.write(to: source.appendingPathComponent("postie.tic"))
        try Data("notes".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let target = work.appendingPathComponent("imported")
        try GameTIC80Adapter.importProject(from: source, to: target, title: "Imported cart")
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("cart.tic")), bytes)
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("original/postie.tic")), bytes)
        let config = try JSONSerialization.jsonObject(with: try NarrativeTestSupport.read(target.appendingPathComponent("project.json"))) as? [String: Any]
        XCTAssertEqual(config?["language"] as? String, "js")
    }
}

final class MicroStudioAdapterTests: XCTestCase {
    func testCreateBuildBundleAndPackage() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("microstudio")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameMicroStudioAdapter.createProject(at: project, title: "micro Postie")
        let source = try NarrativeTestSupport.text(project.appendingPathComponent("src/main.ms"))
        XCTAssertTrue(source.contains("init = function()"))
        XCTAssertTrue(source.contains("update = function()"))
        XCTAssertTrue(source.contains("floe_snapshot = function(seed)"))
        XCTAssertTrue(source.contains("floe_restore = function(sx, sy, sscore)"))

        let artifact = work.appendingPathComponent("artifact")
        try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        let engine = try NarrativeTestSupport.read(artifact.appendingPathComponent("microengine.js"))
        XCTAssertEqual(engine, try GameMicroStudioAdapter.rebuildEngineBundle(resources: NarrativeTestSupport.resources))
        let language = try NarrativeTestSupport.read(artifact.appendingPathComponent("language.js"))
        for fragment in ["Compiler = (function()", "this.Processor = class Processor", "Transpiler = (function()", "this.Runner = class Runner"] {
            XCTAssertTrue(String(decoding: language, as: UTF8.self).contains(fragment), "language bundle missing \(fragment)")
        }
        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        let sourceDocument = try NarrativeTestSupport.read(
            artifact.appendingPathComponent("game/microstudio-sources.json"))
        let sourceText = String(decoding: sourceDocument, as: UTF8.self)
        XCTAssertTrue(html.contains("support/microstudio-bridge.js"))
        XCTAssertFalse(html.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("window.exported_project = true"))
        XCTAssertFalse(html.contains("id=\"code\" type=\"text/x-microscript\""))
        XCTAssertTrue(support.contains("document.createElement(\"script\")"))
        XCTAssertNotNil(support.range(of: #"new Player\(function\s*\(event\)"#, options: .regularExpression))
        XCTAssertTrue(support.contains("player.call(\"floe_snapshot\", [0])"))
        XCTAssertTrue(sourceText.contains("screen.drawRect"))
        XCTAssertFalse(support.contains("screen.drawRect"))

        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .microStudio)
        try package.verify()
        XCTAssertEqual(package.prepared.engine, .microStudio)
    }

    func testImportFolderPreservesSources() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("ms-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("init = function()\nend\n".utf8).write(to: source.appendingPathComponent("src/main.ms"))
        try Data("update = function()\nend\n".utf8).write(to: source.appendingPathComponent("src/other.ms"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source.appendingPathComponent("sprite.png"))
        let target = work.appendingPathComponent("imported")
        try GameMicroStudioAdapter.importProject(from: source, to: target, title: "Imported")
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("src/main.ms")),
                       Data("init = function()\nend\n".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("src/other.ms")),
                       Data("update = function()\nend\n".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("sprite.png")),
                       Data([0x89, 0x50, 0x4E, 0x47]))
        let collected = try GameMicroStudioAdapter.collectSources(project: target)
        XCTAssertEqual(collected.map(\.name), ["main.ms", "other.ms"])
        XCTAssertTrue(collected[0].text.contains("init = function()"))
    }
}
