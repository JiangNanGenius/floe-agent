// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameBuildKit
@testable import FloeGameGDevelopKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-gdevelop-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ files: [GameRelativePath: Data], to root: URL) throws {
    for (path, data) in files {
        let target = root.appendingPathComponent(path.value)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic])
    }
}

private func fixtureURL() throws -> URL {
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
    throw GameGDevelopError.io("test fixture")
}

private func context(root: URL, revision: String = "test-revision") throws -> GameProjectContext {
    let id = UUID()
    return try .init(projectID: id, owner: .space(recordID: id), rootURL: root, savedRevision: revision)
}

@Suite("GDevelop project/template/import")
struct GameGDevelopProjectTests {
    @Test("starter is a real standard project with procedural asset and keyboard declaration")
    func starter() throws {
        let uuid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let files = try GameGDevelopTemplate.makeProject(title: "Floe Test", projectUUID: uuid)
        #expect(files.count == 3)
        let projectPath = try GameRelativePath(GameGDevelopTemplate.projectFileName)
        let document = try GameGDevelopProjectDocument(data: files[projectPath]!)
        #expect(document.summary.name == "Floe Test")
        #expect(document.summary.projectUUID == uuid.uuidString.lowercased())
        #expect(document.summary.firstLayout == "Main")
        #expect(document.summary.scenes.count == 1)
        #expect(document.summary.scenes[0].objectNames == ["Orb"])
        #expect(document.summary.scenes[0].eventCount == 5)
        #expect(document.summary.resources.map(\.name) == ["assets/floe_orb.png"])
        #expect(document.summary.extensionTypes.contains("Sprite"))

        let assetPath = try GameRelativePath(GameGDevelopTemplate.assetPath)
        let png = files[assetPath]!
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(png.count > 500)

        let inputPath = try GameRelativePath(GameGDevelopTemplate.inputFileName)
        let inputs = try GameGDevelopInputDeclaration.decode(files[inputPath]!)
        #expect(inputs.engine == "gdevelop")
        #expect(inputs.movement.right.map(\.rawValue) == ["right"])
        #expect(inputs.buttons.map(\.id) == ["reset"])
        #expect(inputs.buttons[0].keys.map(\.rawValue) == ["z"])
        #expect(try inputs.gdevelopKeyNames() == Set(document.keyboardKeys()))
        #expect(document.keyboardKeys() == ["Down", "Left", "Right", "Up", "z"])
        #expect(GameGDevelopBrowserInput.requiresWindowFloeGameKeyHook == false)
    }

    @Test("unknown plugin fields and original document survive typed edits")
    func unknownFields() throws {
        let originalFiles = try GameGDevelopTemplate.makeProject(title: "Original")
        let originalPath = try GameRelativePath(GameGDevelopTemplate.projectFileName)
        var original = originalFiles[originalPath]!
        var root = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        root["unknownPlugin"] = ["nested": [1, 2, 3], "flag": true]
        var layouts = root["layouts"] as! [[String: Any]]
        var layout = layouts[0]
        layout["pluginField"] = "keep-me"
        layouts[0] = layout
        root["layouts"] = layouts
        var resources = root["resources"] as! [String: Any]
        var resourceList = resources["resources"] as! [[String: Any]]
        resourceList[0]["pluginResourceField"] = 42
        resources["resources"] = resourceList
        root["resources"] = resources
        original = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])

        let document = try GameGDevelopProjectDocument(data: original)
        let renamed = try document.replacingProjectName("Renamed")
        let moved = try renamed.movingInstance(scene: "Main", object: "Orb", x: 123, y: 45)
        let afterRoot = try JSONSerialization.jsonObject(with: moved.encoded()) as! [String: Any]
        #expect((afterRoot["unknownPlugin"] as? [String: Any])?["flag"] as? Bool == true)
        #expect(((afterRoot["layouts"] as? [[String: Any]])?[0]["pluginField"] as? String) == "keep-me")
        let afterResources = (afterRoot["resources"] as? [String: Any])?["resources"] as? [[String: Any]]
        #expect(afterResources?[0]["pluginResourceField"] as? Int == 42)
        #expect((afterRoot["properties"] as? [String: Any])?["name"] as? String == "Renamed")
        let instances = (afterRoot["layouts"] as? [[String: Any]])?[0]["instances"] as? [[String: Any]]
        #expect(instances?[0]["x"] as? Double == 123)
        #expect(instances?[0]["y"] as? Double == 45)
        #expect(document.summary.name == "Original")
    }

    @Test("inspector selects the root project, reports nested projects and missing assets")
    func inspector() throws {
        let root = try temporaryDirectory()
        let files = try GameGDevelopTemplate.makeProject(title: "Inspector")
        try write(files, to: root)
        let nested = try GameGDevelopTemplate.makeProject(title: "Nested")
        try write(nested, to: root.appendingPathComponent("nested"))
        let inspector = try GameGDevelopInspector()
        var inspection = try inspector.inspect(rootURL: root)
        #expect(inspection.primaryProject?.path.value == "game.json")
        #expect(inspection.inputDeclaration?.buttons.map(\.id) == ["reset"])
        #expect(inspection.nestedProjects.contains(where: { $0.path.value.hasSuffix("nested/game.json") }))
        #expect(inspection.diagnostics.contains(where: { $0.kind == .nestedProject }))

        try FileManager.default.removeItem(at: root.appendingPathComponent(GameGDevelopTemplate.assetPath))
        inspection = try inspector.inspect(rootURL: root)
        #expect(inspection.primaryProject?.summary.resources.first?.fileExists == false)
        #expect(inspection.diagnostics.contains(where: { $0.kind == .missingResource }))

        try Data("{\"gdVersion\":".utf8).write(to: root.appendingPathComponent("broken.json"))
        inspection = try inspector.inspect(rootURL: root)
        #expect(inspection.diagnostics.contains(where: { $0.kind == .invalidProjectJSON }))
    }

    @Test("create-project-then-import preserves the full starter in core history")
    func repositoryImport() async throws {
        let root = try temporaryDirectory()
        let repository = try FileGameProjectRepository(directory: root.appendingPathComponent("repo"))
        let id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let result = try await GameGDevelopImportBridge.createProjectAndImportTemplate(
            repository: repository, projectID: id, owner: owner, title: "Imported")
        #expect(result.importedFileCount == 3)
        #expect(result.stored.engine == .gdevelop)
        #expect(result.stored.files.count == 3)
        #expect(result.inspection.primaryProject?.path.value == "game.json")
        let gamePath = try GameRelativePath(GameGDevelopTemplate.projectFileName)
        let data = try await repository.read(id, owner: owner, revision: result.stored.revision, path: gamePath)
        let document = try GameGDevelopProjectDocument(data: data)
        #expect(document.summary.name == "Imported")
        #expect(document.summary.firstLayout == "Main")
    }

    @Test("whole-tree import preserves unknown files and nested projects")
    func wholeTreeImport() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let files = try GameGDevelopTemplate.makeProject(title: "Whole Tree")
        try write(files, to: source)
        try Data("plugin payload".utf8).write(to: source.appendingPathComponent("plugin.dat"))
        try Data("keep me".utf8).write(to: source.appendingPathComponent("notes.txt"))
        let nested = try GameGDevelopTemplate.makeProject(title: "Nested")
        try write(nested, to: source.appendingPathComponent("nested"))
        let repository = try FileGameProjectRepository(directory: root.appendingPathComponent("repo2"))
        let id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner,
                                                          title: "Whole Tree", engine: .gdevelop)
        let result = try await GameGDevelopImportBridge.importTree(
            from: source, repository: repository, projectID: id, owner: owner,
            expectedRevision: created.revision)
        #expect(result.stored.files.count >= 7)
        #expect(result.stored.files.contains(where: { $0.path.value == "plugin.dat" }))
        #expect(result.stored.files.contains(where: { $0.path.value == "notes.txt" }))
        #expect(result.stored.files.contains(where: { $0.path.value == "nested/game.json" }))
        #expect(result.inspection.nestedProjects.contains(where: { $0.path.value.hasSuffix("nested/game.json") }))
        let note = try await repository.read(id, owner: owner, revision: result.stored.revision,
                                            path: try GameRelativePath("notes.txt"))
        #expect(String(decoding: note, as: UTF8.self) == "keep me")
    }

    @Test("input declaration rejects unsupported keys, duplicates and schema drift")
    func inputValidation() throws {
        #expect(throws: GameGDevelopError.self) { try GameGDevelopInputKey("not-a-real-key") }
        let key = try GameGDevelopInputKey("z")
        #expect(throws: GameGDevelopError.self) {
            try GameGDevelopButton(id: "bad id", label: "Z", keys: [key])
        }
        #expect(throws: GameGDevelopError.self) {
            try GameGDevelopInputDeclaration(movement: .init(left: [key, key], right: [], up: [], down: []))
        }
        let invalid = Data("{\"schemaVersion\":2,\"engine\":\"gdevelop\",\"movement\":{\"left\":[],\"right\":[],\"up\":[],\"down\":[]},\"buttons\":[]}".utf8)
        #expect(throws: GameGDevelopError.self) { try GameGDevelopInputDeclaration.decode(invalid) }
    }
}

@Suite("GDevelop artifact/export contracts")
struct GameGDevelopArtifactTests {
    @Test("real official 5.6.287 Web export verifies with resources, compiled code and input declaration")
    func realExport() throws {
        let fixture = try fixtureURL()
        let expectedInputs = try GameGDevelopInputDeclaration.starter()
        let manifest = try GameGDevelopArtifactVerifier.verify(
            directory: fixture, expectedInputs: expectedInputs, sdkVersion: "5.6.287")
        #expect(manifest.engine == .gdevelop)
        #expect(manifest.entry.value == "index.html")
        #expect(manifest.project.firstLayout == "Main")
        #expect(manifest.project.scenes.contains(where: { $0.name == "Main" }))
        #expect(manifest.resources.allSatisfy { $0.fileExists == true })
        #expect(manifest.hasGDevelopLicense)
        #expect(manifest.hasRuntimeCode)
        #expect(manifest.hasDataFile)
        #expect(manifest.files.count > 60)
        #expect(manifest.totalBytes > 500_000)
        #expect(manifest.digest.utf8.count == 64)
        #expect(manifest.inputDeclaration == expectedInputs)
        #expect(manifest.sdkVersion == "5.6.287")
        let dataText = try String(contentsOf: fixture.appendingPathComponent("data.js"), encoding: .utf8)
        #expect(dataText.contains("\"latestCompilationDirectory\":\"\""))
        #expect(!dataText.contains(".gdevelop-export-"))
        try manifest.validateManifest()
    }

    @Test("HTML-only mock and missing resource are rejected")
    func rejection() throws {
        let root = try temporaryDirectory()
        try Data("<html><script>console.log('mock')</script></html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        #expect(throws: GameGDevelopError.self) {
            try GameGDevelopArtifactVerifier.verify(directory: root)
        }
        let fixture = try fixtureURL()
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try FileManager.default.removeItem(at: copy.appendingPathComponent("floe_orb.png"))
        #expect(throws: GameGDevelopError.self) {
            try GameGDevelopArtifactVerifier.verify(directory: copy)
        }
    }

    @Test("verified artifact seals through the core Web package bound to source revision")
    func seal() throws {
        let fixture = try fixtureURL()
        let manifest = try GameGDevelopArtifactVerifier.verify(directory: fixture)
        let root = try temporaryDirectory()
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("playable")
        let source = try context(root: sourceRoot, revision: "sealed-revision")
        let package = try manifest.seal(source: source, to: target)
        #expect(package.prepared.engine == .gdevelop)
        #expect(package.prepared.entry.value == "index.html")
        #expect(package.files.count == manifest.files.count)
        try package.verify()
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("index.html").path))
        #expect(throws: GameProjectError.self) {
            _ = try manifest.seal(source: source, to: sourceRoot.appendingPathComponent("inside-source"))
        }
    }

    @Test("official SDK pin is complete and receipt verification rejects tampering")
    func sdkReceipt() throws {
        let pin = GameGDevelopSDKPin.official56287
        #expect(pin.version == "5.6.287")
        #expect(pin.sourceCommit == "cfaccd2c20bba2b43fea529523042249c90b9a41")
        #expect(pin.license == "MIT")
        #expect(GameGDevelopSDKVerifier.isDigest(pin.macOSAssetSHA256))
        #expect(GameGDevelopSDKVerifier.isDigest(pin.linuxAssetSHA256))

        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent(GameGDevelopPlatform.macOSUniversal.executableRelativePath)
        let index = root.appendingPathComponent(GameGDevelopPlatform.macOSUniversal.runtimeIndexRelativePath)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: executable)
        let indexBytes = Data("official runtime index".utf8)
        try indexBytes.write(to: index)
        let receipt = GameGDevelopSDKReceipt(
            version: pin.version, platform: .macOSUniversal, assetName: pin.macOSAssetName,
            assetSHA256: pin.macOSAssetSHA256, assetVerified: true,
            executableRelativePath: GameGDevelopPlatform.macOSUniversal.executableRelativePath,
            runtimeIndexRelativePath: GameGDevelopPlatform.macOSUniversal.runtimeIndexRelativePath,
            runtimeIndexSHA256: GameDigest.sha256(indexBytes))
        let receiptData = try JSONEncoder().encode(receipt)
        try receiptData.write(to: root.appendingPathComponent("sdk-receipt.json"))
        let verified = try GameGDevelopSDKVerifier.verify(extractedRoot: root, platform: .macOSUniversal, pin: pin)
        #expect(verified.receipt.assetVerified)

        var tampered = receipt
        tampered = GameGDevelopSDKReceipt(
            version: tampered.version, platform: tampered.platform, assetName: tampered.assetName,
            assetSHA256: String(repeating: "0", count: 64), assetVerified: true,
            executableRelativePath: tampered.executableRelativePath,
            runtimeIndexRelativePath: tampered.runtimeIndexRelativePath,
            runtimeIndexSHA256: tampered.runtimeIndexSHA256)
        try JSONEncoder().encode(tampered).write(to: root.appendingPathComponent("sdk-receipt.json"))
        #expect(throws: GameGDevelopError.self) {
            try GameGDevelopSDKVerifier.verify(extractedRoot: root, platform: .macOSUniversal, pin: pin)
        }
    }
}

@Suite("GDevelop typed build plan")
struct GameGDevelopPlanTests {
    @Test("plan carries the checked official-SDK command and rejects unsafe output")
    func plan() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let workspace = root.appendingPathComponent("workspace")
        let output = workspace.appendingPathComponent("artifact")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let files = try GameGDevelopTemplate.makeProject(title: "Plan")
        try write(files, to: source)
        let script = root.appendingPathComponent("gdevelop-export.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
        let plan = try GameGDevelopExportPlanner.plan(
            source: try context(root: source), projectPath: try GameRelativePath("game.json"),
            sdkRoot: root.appendingPathComponent("sdk"), workspace: workspace, output: output,
            platform: .macOSUniversal, exportScriptURL: script)
        #expect(plan.engine == .gdevelop)
        #expect(plan.engineVersion == "5.6.287")
        #expect(plan.commands.count == 1)
        #expect(plan.commands[0].executable == "python3")
        #expect(plan.commands[0].arguments.contains("--sdk-root"))
        #expect(plan.commands[0].arguments.contains("macOSUniversal"))
        #expect(plan.inputs.buttons.map(\.id) == ["reset"])
        let planData = try plan.jsonData()
        #expect(planData.count > 100)
        try plan.validate()

        #expect(throws: GameGDevelopError.self) {
            _ = try GameGDevelopExportPlanner.plan(
                source: try context(root: source), projectPath: try GameRelativePath("game.json"),
                sdkRoot: root.appendingPathComponent("sdk"), workspace: workspace,
                output: root.appendingPathComponent("outside"), platform: .macOSUniversal,
                exportScriptURL: script)
        }
    }

    @Test("runner uses the existing BuildKit host port and stops on failure")
    func runner() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let files = try GameGDevelopTemplate.makeProject(title: "Runner")
        try write(files, to: source)
        let script = root.appendingPathComponent("gdevelop-export.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
        let plan = try GameGDevelopExportPlanner.plan(
            source: try context(root: source), projectPath: try GameRelativePath("game.json"),
            sdkRoot: root.appendingPathComponent("sdk"), workspace: root.appendingPathComponent("workspace"),
            output: root.appendingPathComponent("workspace/output"), platform: .macOSUniversal,
            exportScriptURL: script)
        let host = FakeHost(exitCodes: [0])
        let result = try await GameGDevelopExportRunner(host: host).run(plan)
        #expect(result.commandResults.count == 1)
        let commandCount = await host.commands.count
        #expect(commandCount == 1)
        let failing = FakeHost(exitCodes: [1])
        do {
            _ = try await GameGDevelopExportRunner(host: failing).run(plan)
            Issue.record("expected export failure")
        } catch is GameGDevelopError {
            // expected
        }
    }
}

private actor FakeHost: GameBuildHostPort {
    private let exitCodes: [Int32]
    private(set) var commands: [GameHostCommand] = []
    init(exitCodes: [Int32]) { self.exitCodes = exitCodes }
    func run(_ command: GameHostCommand) async throws -> GameHostResult {
        commands.append(command)
        let index = min(commands.count - 1, exitCodes.count - 1)
        return .init(exitCode: exitCodes[index], stdout: Data(), stderr: Data())
    }
    func terminate(jobID: String) async throws {}
}

private extension GameGDevelopArtifactManifest {
    func validateManifest() throws {
        #expect(files.allSatisfy { $0.sha256.utf8.count == 64 })
        let canonical = files.sorted { $0.path.value < $1.path.value }
            .map { "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable)" }
            .joined(separator: "\n")
        #expect(GameDigest.sha256(Data(canonical.utf8)) == digest)
    }
}
