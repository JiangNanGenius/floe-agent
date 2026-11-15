// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameInstrumentation

private func clean(_ imported: InstrumentationFixture.Imported) {
    try? FileManager.default.removeItem(at: imported.repositoryDirectory)
    try? FileManager.default.removeItem(at: imported.sourceDirectory)
}

@Test func unityHelperCollisionIsNeverOverwritten() async throws {
    let files = InstrumentationFixture.unityProject(extra: [
        "Assets/Scripts/FloeDeveloperBridge.cs": Data("// owner custom bridge\n".utf8)
    ])
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected collision"); return }
    guard case .existingFileCollision(let path, let sha) = error else {
        Issue.record("expected existingFileCollision, got \(error)")
        return
    }
    #expect(path.value == "Assets/Scripts/FloeDeveloperBridge.cs")
    #expect(sha == GameDigest.sha256(Data("// owner custom bridge\n".utf8)))
}

@Test func godotHelperCollisionIsNeverOverwritten() async throws {
    let files: [String: Data] = [
        "project.godot": InstrumentationFixture.godotProject(),
        "floe_developer.gd": Data("# owner custom helper\n".utf8)
    ]
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .godot)
    guard let error else { Issue.record("expected collision"); return }
    guard case .existingFileCollision(let path, _) = error else {
        Issue.record("expected existingFileCollision, got \(error)")
        return
    }
    #expect(path.value == "floe_developer.gd")
}

@Test func godotConflictingAutoloadIsNeverRewritten() async throws {
    let files: [String: Data] = [
        "project.godot": InstrumentationFixture.godotProject(
            autoloads: ["FloeDeveloper=\"*res://owner_bridge.gd\""])
    ]
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .godot)
    guard let error else { Issue.record("expected autoload conflict"); return }
    guard case .conflictingAutoload(let key, _) = error else {
        Issue.record("expected conflictingAutoload, got \(error)")
        return
    }
    #expect(key == "FloeDeveloper")
}

@Test func godot3ProjectIsRejected() async throws {
    let files: [String: Data] = [
        "project.godot": InstrumentationFixture.godotProject(configVersion: 4)
    ]
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .godot)
    guard let error else { Issue.record("expected unsupported version"); return }
    guard case .unsupportedEngineVersion(.godot, let detail) = error else {
        Issue.record("expected unsupportedEngineVersion, got \(error)")
        return
    }
    #expect(detail.contains("config_version=4"))
}

@Test func godotInvalidUTF8ProjectIsRejected() async throws {
    let files: [String: Data] = [
        "project.godot": Data([0xFF, 0xFE, 0x00, 0x01])
    ]
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .godot)
    guard let error else { Issue.record("expected invalid project"); return }
    guard case .invalidProjectFile(_) = error else {
        Issue.record("expected invalidProjectFile, got \(error)")
        return
    }
}

@Test func unityProjectWithoutProjectVersionIsRejected() async throws {
    var files = InstrumentationFixture.unityProject()
    files.removeValue(forKey: "ProjectSettings/ProjectVersion.txt")
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected unrecognized root"); return }
    guard case .rootUnrecognized(.unity, let detail) = error else {
        Issue.record("expected rootUnrecognized, got \(error)")
        return
    }
    #expect(detail.contains("ProjectVersion.txt"))
}

@Test func unity2018ProjectIsRejected() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject(version: "2018.4.36f1"))
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected unsupported version"); return }
    guard case .unsupportedEngineVersion(.unity, let detail) = error else {
        Issue.record("expected unsupportedEngineVersion, got \(error)")
        return
    }
    #expect(detail.contains("2019.4"))
}

@Test func unityInvalidProjectVersionIsRejected() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject(version: "not-a-version"))
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected unrecognized root"); return }
    guard case .rootUnrecognized(.unity, _) = error else {
        Issue.record("expected rootUnrecognized, got \(error)")
        return
    }
}

@Test func duplicateUnityBridgeClassElsewhereIsRejected() async throws {
    let files = InstrumentationFixture.unityProject(extra: [
        "Assets/ThirdParty/Copy.cs": Data("public class FloeDeveloperBridge { }\n".utf8)
    ])
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected duplicate definition"); return }
    guard case .duplicateHelperDefinition(let path, let symbol) = error else {
        Issue.record("expected duplicateHelperDefinition, got \(error)")
        return
    }
    #expect(path.value == "Assets/ThirdParty/Copy.cs")
    #expect(symbol == "FloeDeveloperBridge")
}

@Test func duplicateUnityJSLibrarySymbolElsewhereIsRejected() async throws {
    let files = InstrumentationFixture.unityProject(extra: [
        "Assets/Plugins/WebGL/Owner.jslib": Data("mergeInto(LibraryManager.library, { FloeDeveloperRegister: function(){} });\n".utf8)
    ])
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected duplicate definition"); return }
    guard case .duplicateHelperDefinition(let path, let symbol) = error else {
        Issue.record("expected duplicateHelperDefinition, got \(error)")
        return
    }
    #expect(path.value == "Assets/Plugins/WebGL/Owner.jslib")
    #expect(symbol == "FloeDeveloperRegister")
}

@Test func projectRootWithOnlyNestedUnityIsRejected() async throws {
    var files: [String: Data] = [:]
    for (path, data) in InstrumentationFixture.unityProject() {
        files["nested/" + path] = data
    }
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected unrecognized root"); return }
    guard case .rootUnrecognized(.unity, _) = error else {
        Issue.record("expected rootUnrecognized, got \(error)")
        return
    }
}

@Test func unityDirectoryAtHelperPathIsRejected() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject(),
        emptyDirectories: ["Assets/Scripts/FloeDeveloperBridge.cs"])
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected targetIsDirectory"); return }
    guard case .targetIsDirectory(let path) = error else {
        Issue.record("expected targetIsDirectory, got \(error)")
        return
    }
    #expect(path.value == "Assets/Scripts/FloeDeveloperBridge.cs")
}

@Test func godotDirectoryAtHelperPathIsRejected() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.godotProjectData(),
        emptyDirectories: ["floe_developer.gd"])
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .godot)
    guard let error else { Issue.record("expected targetIsDirectory"); return }
    guard case .targetIsDirectory(let path) = error else {
        Issue.record("expected targetIsDirectory, got \(error)")
        return
    }
    #expect(path.value == "floe_developer.gd")
}

@Test func unityCaseFoldedHelperCollisionIsRejected() async throws {
    let files = InstrumentationFixture.unityProject(extra: [
        "Assets/Scripts/floedeveloperbridge.cs": Data("// different case\n".utf8)
    ])
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected case-folded collision"); return }
    guard case .existingFileCollision(let path, _) = error else {
        Issue.record("expected existingFileCollision, got \(error)")
        return
    }
    #expect(path.value == "Assets/Scripts/floedeveloperbridge.cs")
}
