// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameCore

private final class RecognitionFixture {
    let root: URL

    init(_ files: [String: Data] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGameRecognitionTests-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in files { try write(path, data) }
    }

    convenience init(_ files: [String: String]) throws {
        try self.init(files.mapValues { Data($0.utf8) })
    }

    func write(_ path: String, _ data: Data) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic])
    }

    func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                withIntermediateDirectories: true)
    }

    func copyContents(of source: URL) throws {
        let enumerator = FileManager.default.enumerator(at: source,
            includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let item = enumerator?.nextObject() as? URL {
            let relative = String(item.path.dropFirst(source.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try makeDirectory(relative)
            } else {
                try write(relative, Data(contentsOf: item))
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private func gdevelopJSON(name: String = "Native GDevelop") -> Data {
    let object: [String: Any] = [
        "firstLayout": "Main",
        "gdVersion": ["major": 5, "minor": 6, "revision": 0, "build": 287],
        "properties": ["name": name],
        "layouts": [[
            "name": "Main", "objects": [], "instances": [], "events": []
        ]],
        "resources": ["resources": []]
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func cocosPackage() -> Data {
    let object: [String: Any] = [
        "name": "native-cocos",
        "uuid": "E6B0F7C2-6C31-4F24-9F33-6C0EDC4F9A18",
        "version": "3.8.6",
        "creator": ["version": "3.8.6"]
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func microStudioProject() -> Data {
    let object: [String: Any] = [
        "title": "Native microStudio",
        "language": "microscript_v2",
        "graphics": "canvas2d",
        "aspect": "16/9",
        "files": ["ms/main.ms": ["version": 1]]
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func twineHTML(paddingBytes: Int = 0) -> Data {
    let padding = String(repeating: " ", count: paddingBytes)
    let html = """
    <!DOCTYPE html>
    <html><head><title>Native Twine</title></head><body>
    \(padding)
    <tw-storydata name = "Native Twine" startnode = "1" creator="Twine" creator-version="2.8.1" ifid="8E7C4F3A-1D2B-4C5E-9F60-112233445566" format = "SugarCube" format-version = "2.37.3">
    <tw-passagedata pid="1" name="Start" tags="" position="100,100" size="100,100">Hello.</tw-passagedata>
    </tw-storydata>
    </body></html>
    """
    return Data(html.utf8)
}

/// A genuine minimal WASM-4 release-cartridge shape: env.memory import plus
/// exported start/update functions, with a 64 KiB upstream size limit.
private func wasm4Cart() -> Data {
    Data([
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x02, 0x0F, 0x01, 0x03, 0x65, 0x6E, 0x76, 0x06, 0x6D, 0x65, 0x6D,
        0x6F, 0x72, 0x79, 0x02, 0x00, 0x01,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x12, 0x02, 0x05, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
        0x06, 0x75, 0x70, 0x64, 0x61, 0x74, 0x65, 0x00, 0x00,
        0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B
    ])
}

private func nonWasm4Module() -> Data {
    // Same module without the WASM-4 update/start exports.
    Data([
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x02, 0x0F, 0x01, 0x03, 0x65, 0x6E, 0x76, 0x06, 0x6D, 0x65, 0x6D,
        0x6F, 0x72, 0x79, 0x02, 0x00, 0x01,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6E, 0x00, 0x00,
        0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B
    ])
}

private func recognitionFixtureBase() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Recognition", isDirectory: true)
}

@Test func allTwentyNativeStandardProjectsAreRecognized() throws {
    let cases: [(String, [String: Data], GameEngineID)] = [
        ("rpgMakerXP", ["Game.rxproj": Data()], .rpgMakerXP),
        ("rpgMakerVX", ["Game.rvproj": Data()], .rpgMakerVX),
        ("rpgMakerVXAce", ["Game.rvproj2": Data()], .rpgMakerVXAce),
        ("rpgMakerMV", [
            "Game.rpgproject": Data(),
            "data/System.json": Data("{}".utf8),
            "js/rpg_core.js": Data("// unexecuted".utf8)
        ], .rpgMakerMV),
        ("rpgMakerMZ", [
            "Game.rmmzproject": Data(),
            "data/System.json": Data("{}".utf8),
            "js/rmmz_core.js": Data("// unexecuted".utf8)
        ], .rpgMakerMZ),
        ("phaser", [
            "package.json": Data(#"{"dependencies":{"phaser":"^3.90.0"}}"#.utf8),
            "index.html": Data("<html></html>".utf8),
            "phaser.min.js": Data("// unexecuted".utf8)
        ], .phaser),
        ("kaplay", [
            "package.json": Data(#"{"dependencies":{"kaplay":"^3001.0.0"}}"#.utf8),
            "index.html": Data("<html></html>".utf8),
            "kaplay.js": Data("// unexecuted".utf8)
        ], .kaplay),
        ("godot", ["project.godot": Data()], .godot),
        ("babylon", [
            "package.json": Data(#"{"dependencies":{"@babylonjs/core":"^9.35.0"}}"#.utf8),
            "index.html": Data("<html></html>".utf8),
            "babylon.js": Data("// unexecuted".utf8)
        ], .babylon),
        ("playcanvas", [
            "package.json": Data(#"{"dependencies":{"playcanvas":"^2.24.0"}}"#.utf8),
            "index.html": Data("<html></html>".utf8),
            "playcanvas.js": Data("// unexecuted".utf8)
        ], .playcanvas),
        ("love", ["main.lua": Data(), "conf.lua": Data()], .love),
        ("renpy", ["game/script.rpy": Data("label start:\nreturn\n".utf8)], .renpy),
        ("tic80", ["cart.tic": Data("TIC-80 cartridge".utf8)], .tic80),
        ("ink", ["story.ink": Data("Hello -> END\n".utf8)], .ink),
        ("twine", ["index.html": twineHTML()], .twine),
        ("gdevelop", ["game.json": gdevelopJSON()], .gdevelop),
        ("cocosCreator", [
            "package.json": cocosPackage(),
            "assets/Scenes/Main.scene": Data("[]".utf8)
        ], .cocosCreator),
        ("microStudio", [
            "project.json": microStudioProject(),
            "ms/main.ms": Data("update = function()\nend\n".utf8)
        ], .microStudio),
        ("wasm4", ["cart.wasm": wasm4Cart()], .wasm4),
        ("unity", [
            "ProjectSettings/ProjectVersion.txt": Data("m_EditorVersion: 6000.3.0f1\n".utf8),
            "Assets/.keep": Data()
        ], .unity)
    ]
    for (name, files, expected) in cases {
        let fixture = try RecognitionFixture(files)
        let inspection = try GameProjectInspector().inspect(rootURL: fixture.root)
        #expect(inspection.candidates.map(\.engine) == [expected],
                "native \(name) project should be the only candidate")
    }
}

@Test func gdevelopJSONWithArbitraryNameAtTheSelectedRootIsRecognized() throws {
    let fixture = try RecognitionFixture(["MyNativeGame.json": gdevelopJSON(name: "Arbitrary")])
    let inspection = try GameProjectInspector().inspect(rootURL: fixture.root)
    #expect(inspection.candidates.map(\.engine) == [.gdevelop])
    #expect(inspection.candidates[0].evidence[0].versionHint == "5.6.0 build 287")
}

@Test func cocosCreatorRequiresAssetsAndProjectMetadata() throws {
    let withoutAssets = try RecognitionFixture(["package.json": cocosPackage()])
    #expect(try GameProjectInspector().inspect(rootURL: withoutAssets.root).candidates.isEmpty)

    let fallback = try RecognitionFixture([
        "package.json": Data(#"{"name":"native-cocos","uuid":"E6B0F7C2-6C31-4F24-9F33-6C0EDC4F9A18"}"#.utf8),
        "assets/.keep": Data(),
        "settings/v2/packages/project.json": Data("{}".utf8)
    ])
    #expect(try GameProjectInspector().inspect(rootURL: fallback.root)
        .candidates.map(\.engine) == [.cocosCreator])
}

@Test func conflictingRealEnginesRemainMultipleCandidates() throws {
    let fixture = try RecognitionFixture([
        "game.json": gdevelopJSON(), "project.godot": Data()
    ])
    let inspection = try GameProjectInspector().inspect(rootURL: fixture.root)
    #expect(inspection.candidates.map(\.engine) == [.gdevelop, .godot])
}

@Test func nativeMissingFormatsAreRecognizedWithoutFloeMetadata() throws {
    let gdevelop = try RecognitionFixture(["game.json": gdevelopJSON()])
    let cocos = try RecognitionFixture([
        "package.json": cocosPackage(),
        "assets/Scenes/Main.scene": Data("[]".utf8)
    ])
    let studio = try RecognitionFixture([
        "project.json": microStudioProject(),
        "ms/main.ms": Data("update = function()\nend\n".utf8)
    ])
    let twine = try RecognitionFixture(["index.html": twineHTML()])
    let wasm = try RecognitionFixture(["cart.wasm": wasm4Cart()])

    #expect(try GameProjectInspector().inspect(rootURL: gdevelop.root)
        .candidates.map(\.engine) == [.gdevelop])
    #expect(try GameProjectInspector().inspect(rootURL: cocos.root)
        .candidates.map(\.engine) == [.cocosCreator])
    #expect(try GameProjectInspector().inspect(rootURL: studio.root)
        .candidates.map(\.engine) == [.microStudio])
    #expect(try GameProjectInspector().inspect(rootURL: twine.root)
        .candidates.map(\.engine) == [.twine])
    #expect(try GameProjectInspector().inspect(rootURL: wasm.root)
        .candidates.map(\.engine) == [.wasm4])
}

@Test func twineHTMLAllowsWhitespaceAroundEquals() throws {
    let root = try RecognitionFixture(["index.html": twineHTML()])
    #expect(try GameProjectInspector().inspect(rootURL: root.root)
        .candidates.map(\.engine) == [.twine])
    let nested = try RecognitionFixture(["Stories/One/index.html": twineHTML()])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: nested.root))
}

@Test func twineHTMLBeyondAPrefixAndRenpyNonStarterSourceAreRecognized() throws {
    let twine = try RecognitionFixture(["story.html": twineHTML(paddingBytes: 300_000)])
    #expect(try GameProjectInspector().inspect(rootURL: twine.root)
        .candidates.map(\.engine) == [.twine])

    let renpy = try RecognitionFixture(["game/options.rpy": Data("define config.name = 'x'\n".utf8)])
    #expect(try GameProjectInspector().inspect(rootURL: renpy.root)
        .candidates.map(\.engine) == [.renpy])
}

@Test func vendoredWebEngineScriptsWithoutNpmMetadataAreRecognized() throws {
    for (engine, file) in [
        (GameEngineID.phaser, "phaser.min.js"),
        (.kaplay, "kaplay.js"),
        (.babylon, "babylon.js"),
        (.playcanvas, "playcanvas.js")
    ] {
        let fixture = try RecognitionFixture([
            "index.html": Data("<html></html>".utf8), file: Data("// unexecuted".utf8)
        ])
        #expect(try GameProjectInspector().inspect(rootURL: fixture.root)
            .candidates.map(\.engine) == [engine])
    }
}

@Test func ordinaryCodeAndUnrelatedNpmPackagesRemainUnrecognized() throws {
    let fixture = try RecognitionFixture([
        "package.json": Data(#"{"name":"plain-library","dependencies":{"left-pad":"1.3.0"}}"#.utf8),
        "src/index.js": Data("module.exports = 1\n".utf8),
        "config.json": Data(#"{"name":"config","version":"1"}"#.utf8),
        "index.html": Data("<html><body>Documentation</body></html>".utf8),
        "notes/project.json": Data(#"{"name":"notes","version":1}"#.utf8)
    ])
    let inspection = try GameProjectInspector().inspect(rootURL: fixture.root)
    #expect(inspection.candidates.isEmpty)
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root) == false)
}

@Test func fakeMarkersAndMalformedNativeMetadataDoNotCreateCandidates() throws {
    let fixture = try RecognitionFixture([
        "game.json": Data(#"{"gdVersion":{"major":5},"properties":{},"layouts":{}}"#.utf8),
        "package.json": Data(#"{"creator":{"version":"3.8.6"}}"#.utf8),
        "project.json": Data(#"{"language":"microscript_v2","files":{}}"#.utf8),
        "cart.wasm": nonWasm4Module()
    ])
    #expect(try GameProjectInspector().inspect(rootURL: fixture.root).candidates.isEmpty)

    // A function called env.memory and a memory exported as update are both
    // valid core WebAssembly shapes, but neither is the WASM-4 memory/function ABI.
    let prefix: [UInt8] = [0, 0x61, 0x73, 0x6D, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0]
    let importName: [UInt8] = [1, 3] + Array("env".utf8) + [6] + Array("memory".utf8)
    let exportName: [UInt8] = [1, 6] + Array("update".utf8)
    for (kind, descriptor, exportKind) in [(UInt8(0), [UInt8(0)], UInt8(0)),
                                          (UInt8(2), [UInt8(0), UInt8(1)], UInt8(2))] {
        let imports = importName + [kind] + descriptor
        let exports = exportName + [exportKind, 0]
        let bytes = prefix + [2, UInt8(imports.count)] + imports
            + [7, UInt8(exports.count)] + exports
        let nonCart = try RecognitionFixture(["cart.wasm": Data(bytes)])
        #expect(try GameProjectInspector().inspect(rootURL: nonCart.root).candidates.isEmpty)
    }
    let malformedLEB = try RecognitionFixture([
        "cart.wasm": wasm4Cart() + Data([0, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F])
    ])
    #expect(try GameProjectInspector().inspect(rootURL: malformedLEB.root).candidates.isEmpty)
}

@Test func eachNativeGapFormatIsDiscoveredInItsOwnNestedRoot() throws {
    let cases: [(String, [String: Data])] = [
        ("gdevelop", ["gdevelop/game.json": gdevelopJSON()]),
        ("cocos", [
            "cocos/package.json": cocosPackage(),
            "cocos/assets/Scenes/Main.scene": Data("[]".utf8)
        ]),
        ("microstudio", [
            "studio/project.json": microStudioProject(),
            "studio/ms/main.ms": Data("update = function()\nend\n".utf8)
        ]),
        ("twine", ["twine/index.html": twineHTML()]),
        ("wasm4", ["wasm/cart.wasm": wasm4Cart()])
    ]
    for (name, files) in cases {
        let fixture = try RecognitionFixture(files)
        #expect(try GameProjectInspector().inspect(rootURL: fixture.root).candidates.isEmpty)
        #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root),
                "nested \(name) root should be discovered")
    }
}

@Test func nestedCocosAssetsAreRelativeToPackageAndOuterAssetsDoNotLeak() throws {
    let valid = try RecognitionFixture([
        "Games/Cocos/package.json": cocosPackage(),
        "Games/Cocos/assets/Scenes/Main.scene": Data("[]".utf8)
    ])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: valid.root))

    let outerAssetsOnly = try RecognitionFixture([
        "assets/.keep": Data(),
        "Games/Cocos/package.json": cocosPackage()
    ])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: outerAssetsOnly.root) == false)
}

@Test func arbitraryNativeJSONWithLargePreludeAndCompiledInkAreRecognized() throws {
    let prelude = String(repeating: " ", count: 9_000)
    let gdevelop = Data((prelude + String(decoding: gdevelopJSON(), as: UTF8.self)).utf8)
    let compiledInk = Data(#"{"inkVersion":21,"root":["^Hello","\n","end",null]}"#.utf8)

    let rootGDevelop = try RecognitionFixture(["MyGame.json": gdevelop])
    #expect(try GameProjectInspector().inspect(rootURL: rootGDevelop.root)
        .candidates.map(\.engine) == [.gdevelop])

    let nestedGDevelop = try RecognitionFixture(["Games/GD/MyGame.json": gdevelop])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: nestedGDevelop.root))

    let rootInk = try RecognitionFixture(["story.json": compiledInk])
    #expect(try GameProjectInspector().inspect(rootURL: rootInk.root)
        .candidates.map(\.engine) == [.ink])

    let nestedInk = try RecognitionFixture(["Games/Ink/story.json": compiledInk])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: nestedInk.root))
}

@Test func exportedWebBuildRootsAreRecognized() throws {
    let cases: [([String: Data], GameEngineID?)] = [
        ([
            "index.html": Data("<!doctype html>".utf8),
            "data.js": Data("gdjs.projectData = {};".utf8),
            "gd.js": Data("// unexecuted".utf8),
            "code0.js": Data("// unexecuted".utf8)
        ], .gdevelop),
        ([
            "index.html": Data("<!doctype html>".utf8),
            "application.js": Data("// unexecuted".utf8),
            "src/settings.json": Data("{}".utf8)
        ], .cocosCreator),
        ([
            "index.html": Data("<!doctype html>".utf8),
            "Build/game.loader.js": Data("// unexecuted".utf8),
            "Build/game.wasm": Data("wasm".utf8),
            "Build/game.data": Data("data".utf8)
        ], .unity),
        ([
            "index.html": Data("<!doctype html>".utf8),
            "index.wasm": Data("wasm".utf8),
            "index.pck": Data("pck".utf8)
        ], .godot),
        ([
            "index.html": Data("<!doctype html>".utf8),
            "love.wasm": Data("wasm".utf8),
            "game.data": Data("data".utf8),
            "love.js": Data("// unexecuted".utf8)
        ], .love),
        ([
            "index.html": Data("<!doctype html>".utf8),
            "renpy.wasm": Data("wasm".utf8),
            "game.zip": Data("zip".utf8)
        ], .renpy),
        (["index.html": Data("<!doctype html><html>plain</html>".utf8)], nil)
    ]
    for (files, expected) in cases {
        let fixture = try RecognitionFixture(files)
        let engines = try GameProjectInspector().inspect(rootURL: fixture.root)
            .candidates.map(\.engine)
        if let expected {
            #expect(engines == [expected])
        } else {
            #expect(engines.isEmpty)
        }
    }
}

@Test func nestedNativeGapFormatsAreDiscovered() throws {
    let fixture = try RecognitionFixture([
        "gdevelop/game.json": gdevelopJSON(),
        "cocos/package.json": cocosPackage(),
        "cocos/assets/Scenes/Main.scene": Data("[]".utf8),
        "studio/project.json": microStudioProject(),
        "studio/ms/main.ms": Data("update = function()\nend\n".utf8),
        "twine/index.html": twineHTML(),
        "wasm/cart.wasm": wasm4Cart()
    ])
    #expect(try GameProjectInspector().inspect(rootURL: fixture.root).candidates.isEmpty)
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root))
}

@Test func staticNativeFixturesAreRecognizedWhenBundled() throws {
    let base = recognitionFixtureBase()
    guard FileManager.default.fileExists(atPath: base.path) else { return }
    for name in ["gdevelop", "cocos", "microstudio", "twine", "ink", "negative"] {
        let source = base.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        let fixture = try RecognitionFixture()
        try fixture.copyContents(of: source)
        let inspection = try GameProjectInspector().inspect(rootURL: fixture.root)
        if name == "negative" {
            #expect(inspection.candidates.isEmpty, "negative fixture \(name)")
        } else {
            #expect(!inspection.candidates.isEmpty, "positive fixture \(name)")
        }
    }
}
