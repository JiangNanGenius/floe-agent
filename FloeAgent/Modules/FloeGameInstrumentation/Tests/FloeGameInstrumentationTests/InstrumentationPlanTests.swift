// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameDeveloperCore
@testable import FloeGameInstrumentation

private func clean(_ imported: InstrumentationFixture.Imported) {
    try? FileManager.default.removeItem(at: imported.repositoryDirectory)
    try? FileManager.default.removeItem(at: imported.sourceDirectory)
}

@Test func unityPlanPreviewsTheThreeReviewedFiles() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let historyBefore = try await imported.repository.history(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let descriptor = try GameDeveloperEngineCatalog.descriptor(for: .unity)
    #expect(plan.descriptor == descriptor)
    #expect(plan.catalogVersion == GameDeveloperEngineCatalog.version)
    #expect(plan.engineVersion == "2022.3.61f1")
    #expect(plan.files.count == 3)
    #expect(plan.files.allSatisfy { $0.action == .create })
    #expect(plan.files.allSatisfy { $0.existingSHA256 == nil })
    #expect(plan.requiresRebuild)
    #expect(plan.dormancy.gated)
    #expect(plan.autoload == nil)
    #expect(plan.changedFiles.count == 3)
    #expect(plan.hasChanges)
    let paths = Set(plan.files.map { $0.path.value })
    #expect(paths == Set([
        "Assets/Plugins/WebGL/FloeDeveloper.jslib",
        "Assets/Scripts/FloeDeveloperBridge.cs",
        "Assets/Scripts/FloeDeveloperBridgeBehaviour.cs"
    ]))
    for file in plan.files {
        #expect(GameDigest.sha256(file.outputData) == file.outputSHA256)
        #expect(file.outputBytes == file.outputData.count)
    }
    #expect(plan.diagnostics.contains { $0.code == "rebuild-required" })
    let history = try await imported.repository.history(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
    #expect(history.map(\.revision) == historyBefore.map(\.revision))
}

@Test func godotPlanPreviewsTheAutoloadAndHelper() async throws {
    let files: [String: Data] = [
        "project.godot": InstrumentationFixture.godotProject(),
        "main.gd": Data("extends Node2D\n".utf8),
        "main.tscn": Data("[gd_scene format=3]\n".utf8)
    ]
    let imported = try await InstrumentationFixture.imported(files: files)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .godot)
    #expect(plan.engineVersion == "Godot 4 (config_version=5)")
    #expect(plan.files.count == 2)
    let patch = try #require(plan.files.first { $0.kind == .projectPatch })
    let helper = try #require(plan.files.first { $0.kind == .helperSource })
    #expect(patch.path.value == "project.godot")
    #expect(patch.action == .patch)
    #expect(patch.existingSHA256 != nil)
    #expect(helper.path.value == "floe_developer.gd")
    #expect(helper.action == .create)
    let autoload = try #require(plan.autoload)
    #expect(autoload.changed)
    #expect(autoload.key == "FloeDeveloper")
    #expect(autoload.value == "*res://floe_developer.gd")
    #expect(autoload.line == "FloeDeveloper=\"*res://floe_developer.gd\"")
    #expect(autoload.lineEnding == "lf")
    #expect(autoload.hadBOM == false)
    #expect(plan.diagnostics.contains { $0.code == "godot-autoload" })
}

@Test func nestedRootsInstallOnlyUnderTheSelectedRoot() async throws {
    var files: [String: Data] = [:]
    for (path, data) in InstrumentationFixture.unityProject() {
        files["games/unity/" + path] = data
    }
    files["games/godot/project.godot"] = InstrumentationFixture.godotProject()
    files["games/godot/main.gd"] = Data("extends Node2D\n".utf8)
    files["README.md"] = Data("fixture\n".utf8)
    let imported = try await InstrumentationFixture.imported(
        files: files, emptyDirectories: ["games/unity/Assets/Empty", "games/godot/assets_empty"])
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let unityRoot = try GameRelativePath("games/unity")
    let unityPlan = try await instrumenter.plan(
        context: imported.context, engine: .unity, gameRoot: unityRoot)
    #expect(unityPlan.gameRoot == unityRoot)
    #expect(unityPlan.files.allSatisfy { $0.path.value.hasPrefix("games/unity/") })
    let receipt = try await instrumenter.apply(unityPlan)
    let committed = receipt.project
    let unityEmpty = try GameRelativePath("games/unity/Assets/Empty")
    let godotEmpty = try GameRelativePath("games/godot/assets_empty")
    #expect(committed.directories.contains(unityEmpty))
    #expect(committed.directories.contains(godotEmpty))
    let readmePath = try GameRelativePath("README.md")
    let readme = try await imported.repository.read(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner,
        revision: committed.revision, path: readmePath)
    #expect(readme == Data("fixture\n".utf8))

    let godotPlan = try await instrumenter.plan(
        context: receipt.context, engine: .godot,
        gameRoot: try GameRelativePath("games/godot"))
    #expect(godotPlan.files.contains { $0.path.value == "games/godot/project.godot" })
    #expect(godotPlan.files.contains { $0.path.value == "games/godot/floe_developer.gd" })

    let missing = try GameRelativePath("games/missing")
    let error = await InstrumentationFixture.planError(
        instrumenter, context: receipt.context, engine: .unity, root: missing)
    guard let error else { Issue.record("expected rootNotSelected"); return }
    guard case .rootNotSelected(let path) = error else {
        Issue.record("expected rootNotSelected, got \(error)")
        return
    }
    #expect(path == "games/missing")
}

@Test func repeatedApplyIsIdempotentAndCreatesNoRevision() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let firstPlan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let first = try await instrumenter.apply(firstPlan)
    #expect(first.changed)
    let secondPlan = try await instrumenter.plan(context: first.context, engine: .unity)
    #expect(!secondPlan.hasChanges)
    #expect(secondPlan.files.allSatisfy { $0.action == .unchanged })
    #expect(secondPlan.unchangedFiles.count == 3)
    let historyBefore = try await imported.repository.history(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner, limit: 32)
    let second = try await instrumenter.apply(secondPlan)
    #expect(!second.changed)
    #expect(second.revision == first.revision)
    let historyAfter = try await imported.repository.history(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner, limit: 32)
    #expect(historyAfter.count == historyBefore.count)
}

@Test func applyPreservesUnknownFilesAndEmptyDirectories() async throws {
    let native = Data([0x00, 0x01, 0xFF, 0xFE, 0x7F])
    let extra: [String: Data] = [
        "Docs/notes.txt": Data("owner note\n".utf8),
        "Assets/Plugins/Native/libunknown.dylib": native,
        "Assets/Unknown/Nested/file.bin": Data([0xAB, 0xCD])
    ]
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject(extra: extra),
        emptyDirectories: ["Assets/EmptyFolder", "Docs/empty"])
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let before = try await imported.repository.open(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let receipt = try await instrumenter.apply(plan)
    #expect(receipt.project.files.count == before.files.count + 3)
    let emptyFolder = try GameRelativePath("Assets/EmptyFolder")
    let emptyDocs = try GameRelativePath("Docs/empty")
    #expect(receipt.project.directories.contains(emptyFolder))
    #expect(receipt.project.directories.contains(emptyDocs))
    for (path, expected) in extra {
        let relative = try GameRelativePath(path)
        let value = try await imported.repository.read(
            InstrumentationFixture.projectID, owner: InstrumentationFixture.owner,
            revision: receipt.revision, path: relative)
        #expect(value == expected)
    }
}

@Test func storedEngineMismatchIsAWarningAndMetadataIsNotRewritten() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject(), engine: .godot)
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    #expect(plan.diagnostics.contains { $0.code == "engine-override" && $0.severity == .warning })
    let receipt = try await instrumenter.apply(plan)
    #expect(receipt.project.engine == .godot)
}

@Test func unsupportedEngineFailsBeforeAnyRepositoryAccess() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .rpgMakerMZ)
    guard let error else { Issue.record("expected unsupportedEngine"); return }
    guard case .unsupportedEngine(.rpgMakerMZ) = error else {
        Issue.record("expected unsupportedEngine, got \(error)")
        return
    }
}
