// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class ProjectFixture {
    let root: URL
    init(_ files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeGameCoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try write(path, text) }
    }
    func write(_ path: String, _ text: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private func context(_ fixture: ProjectFixture, revision: String = "saved-1", owner: GameProjectOwner? = nil,
                     environmentID: String? = "existing-environment") throws -> GameProjectContext {
    try .init(projectID: projectID, owner: owner ?? .space(recordID: projectID), rootURL: fixture.root,
              savedRevision: revision, environmentID: environmentID)
}
private func registry(_ engine: GameEngineID = .phaser, ready: Bool = true,
                      route: GameRuntimeRoute = .webKit, builder: String? = "qualification.web-build") throws -> GameAdapterRegistry {
    var registry = GameAdapterRegistry()
    try registry.register(.init(engine: engine, route: route, runtimeReady: ready, buildAdapterID: builder))
    return registry
}
private func artifact(_ source: GameProjectContext, engine: GameEngineID = .phaser,
                      route: GameRuntimeRoute = .webKit) throws -> GamePreparedArtifact {
    try .init(id: UUID(), engine: engine, source: source, route: route,
              sha256: String(repeating: "a", count: 64), entry: GameRelativePath("index.html"))
}
private func phaser() throws -> ProjectFixture {
    try .init(["package.json": #"{"dependencies":{"phaser":"^3.90.0"}}"#])
}

@Test func cachedFingerprintRechecksChangedAndReplacedFiles() throws {
    let fixture = try ProjectFixture(["assets/game.bin": "original"])
    let reader = try GameProjectReader(rootURL: fixture.root, maximumFileBytes: 1_024)
    let path = try GameRelativePath("assets/game.bin")
    let original = try #require(try reader.fingerprintWithIdentity(path))
    #expect(try reader.fingerprintWithIdentity(path, cached: original) == original)

    // Same-size changes must not reuse the prior digest, even if a caller
    // restores the original modification time. The filesystem change time
    // and file identity remain part of the validation.
    let url = fixture.root.appendingPathComponent(path.value)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let modified = try #require(attributes[.modificationDate] as? Date)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data("modified".utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    let changed = try #require(try reader.fingerprintWithIdentity(path, cached: original))
    #expect(changed.bytes == original.bytes)
    #expect(changed.sha256 != original.sha256)

    // A cache hint never turns a replaced symlink into an allowed path.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.root.appendingPathComponent("outside"))
    #expect(throws: (any Error).self) { try reader.fingerprintWithIdentity(path, cached: changed) }
}

@Test(arguments: GameEngineID.allCases)
func projectEngineMetadataNeverGrantsARuntime(_ engine: GameEngineID) throws {
    let metadata = try JSONSerialization.data(withJSONObject: ["engine": engine.rawValue, "permissions": ["native.execute"], "buildCommand": "untrusted"])
    let fixture = try ProjectFixture(["project.json": String(decoding: metadata, as: UTF8.self)])
    let current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    #expect(inspection.candidates.map(\.engine) == [engine])
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: .init()) == .unavailable(engine: engine, reason: .adapterNotRegistered))
}

@Test func publishedAndTextProjectsAreDetectedWithoutEditorExecutables() throws {
    for (files, engine) in [
        (["js/rmmz_core.js": "unexecuted", "data/System.json": "{}"], GameEngineID.rpgMakerMZ),
        (["main.lua": "unexecuted", "conf.lua": "unexecuted"], .love),
        (["game/script.rpy": "unexecuted"], .renpy),
        (["story.ink": "unexecuted"], .ink),
        (["game.tic": "unexecuted"], .tic80),
        (["story.twee": "unexecuted"], .twine)
    ] {
        let fixture = try ProjectFixture(files)
        #expect(try GameProjectInspector().inspect(rootURL: fixture.root).candidates.map(\.engine) == [engine])
    }
}

@Test(arguments: [
    ("Game.rxproj", GameEngineID.rpgMakerXP), ("Game.rvproj", .rpgMakerVX),
    ("Game.rvproj2", .rpgMakerVXAce), ("Game.rpgproject", .rpgMakerMV), ("Game.rmmzproject", .rpgMakerMZ)
])
func rpgEditorMarkersAreCandidatesWithoutRunningRuby(_ name: String, _ expected: GameEngineID) throws {
    let fixture = try ProjectFixture([name: "synthetic project marker\n"])
    let current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    #expect(inspection.candidates.map(\.engine) == [expected])
    #expect(inspection.inspectedPaths.map(\.value) == [name])
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: .init())
            == .unavailable(engine: expected, reason: .adapterNotRegistered))
}

@Test func legacyDataLayoutUsesFileTypesWithoutDeserializingArchives() throws {
    let fixture = try ProjectFixture(["Data/System.rvdata": "not a Ruby object", "Data/Scripts.rvdata": String(repeating: "x", count: 2_000)])
    let inspector = GameProjectInspector(limits: try .init(maximumManifestBytes: 64))
    let inspection = try inspector.inspect(rootURL: fixture.root)
    #expect(inspection.candidates.map(\.engine) == [.rpgMakerVX])
    #expect(inspection.candidates[0].evidence.allSatisfy { $0.kind == .dataLayout })
}

@Test func emptyGodotProjectIsRecognizedAtTheSelectedRoot() throws {
    let fixture = try ProjectFixture(["project.godot": ""])
    #expect(try GameProjectInspector().inspect(rootURL: fixture.root).candidates.map(\.engine) == [.godot])
}

@Test func unityRequiresItsAssetsDirectoryAndReportsDeclaredVersion() throws {
    let fixture = try ProjectFixture(["ProjectSettings/ProjectVersion.txt": "m_EditorVersion: 6000.3.0f1\nm_EditorVersionWithRevision: 6000.3.0f1 (synthetic)\n"])
    #expect(throws: GameProjectError.invalidManifest("ProjectSettings/ProjectVersion.txt")) {
        try GameProjectInspector().inspect(rootURL: fixture.root)
    }
    try fixture.write("Assets/.keep", "")
    let current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    #expect(inspection.candidates.map(\.engine) == [.unity])
    #expect(inspection.candidates[0].evidence[0].versionHint == "6000.3.0f1")
    let decision = try GameLaunchPlanner.plan(inspection: inspection, context: current,
        registry: registry(.unity, builder: "qualification.unity-web-ci"))
    guard case .build(let request) = decision else { Issue.record("Expected Web CI preparation"); return }
    #expect(request.engine == .unity)
    #expect(request.buildAdapterID == "qualification.unity-web-ci")
    #expect(throws: GameProjectError.unsupportedRoute(.unity)) {
        try GameAdapterRegistration(engine: .unity, route: .bundledNative(adapterID: "unity"), runtimeReady: true)
    }
}

@Test(arguments: [
    ("phaser", GameEngineID.phaser), ("kaplay", .kaplay), ("playcanvas", .playcanvas),
    ("@babylonjs/core", .babylon), ("babylonjs", .babylon)
])
func npmDependenciesAreHintsAndDoNotExecuteScripts(_ package: String, _ expected: GameEngineID) throws {
    let fixture = try ProjectFixture()
    let sentinel = fixture.root.appendingPathComponent("should-not-exist").path
    let object: [String: Any] = ["devDependencies": [package: "^1.0.0"],
        "scripts": ["postinstall": "touch " + sentinel], "owner": "some other project", "permissions": ["all": true]]
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.root.appendingPathComponent("package.json"))
    let inspection = try GameProjectInspector().inspect(rootURL: fixture.root)
    #expect(inspection.candidates.map(\.engine) == [expected])
    #expect(inspection.candidates[0].evidence[0].versionHint == "^1.0.0")
    #expect(!FileManager.default.fileExists(atPath: sentinel))
}

@Test func multipleEnginesRequireExplicitSelectionAndCannotSelectAnAbsentEngine() throws {
    let fixture = try ProjectFixture(["Game.rxproj": "", "project.godot": ""])
    let current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: .init())
            == .chooseEngine([.godot, .rpgMakerXP]))
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, selectedEngine: .godot, registry: .init())
            == .unavailable(engine: .godot, reason: .adapterNotRegistered))
    #expect(throws: GameProjectError.engineNotDetected(.unity)) {
        try GameLaunchPlanner.plan(inspection: inspection, context: current, selectedEngine: .unity, registry: .init())
    }
}

@Test func arbitraryHtmlAndNestedProjectsAreNotSilentlyChosen() throws {
    let fixture = try ProjectFixture(["index.html": "<html>not necessarily a game</html>", "nested/project.godot": ""])
    let inspection = try GameProjectInspector().inspect(context: context(fixture))
    #expect(inspection.candidates.isEmpty)
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: context(fixture), registry: .init()) == .unrecognized)
}

@Test func malformedAndOversizedMetadataAreRejected() throws {
    let fixture = try ProjectFixture(["package.json": "not JSON"])
    #expect(throws: GameProjectError.invalidManifest("package.json")) { try GameProjectInspector().inspect(rootURL: fixture.root) }
    try fixture.write("package.json", String(repeating: " ", count: 256))
    let bounded = GameProjectInspector(limits: try .init(maximumManifestBytes: 64))
    #expect(throws: GameProjectError.limitExceeded("package.json")) { try bounded.inspect(rootURL: fixture.root) }
    let crowded = GameProjectInspector(limits: try .init(maximumRootEntries: 1))
    try fixture.write("README.md", "")
    #expect(throws: GameProjectError.limitExceeded("rootEntries")) { try crowded.inspect(rootURL: fixture.root) }
}

@Test func symlinkedManifestAndIntermediateDirectoryCannotEscapeTheRoot() throws {
    let outside = try ProjectFixture(["package.json": #"{"dependencies":{"phaser":"*"}}"#, "System.rxdata": "", "Scripts.rxdata": ""])
    let fixture = try ProjectFixture()
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("package.json"),
                                             withDestinationURL: outside.root.appendingPathComponent("package.json"))
    #expect(throws: GameProjectError.unsafePath("package.json")) { try GameProjectInspector().inspect(rootURL: fixture.root) }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("package.json"))
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Data"), withDestinationURL: outside.root)
    #expect(throws: GameProjectError.unsafePath("Data/System.rxdata")) { try GameProjectInspector().inspect(rootURL: fixture.root) }
}

@Test func importedFifoCannotBlockTheInspector() throws {
    let fixture = try ProjectFixture()
    let path = fixture.root.appendingPathComponent("Game.rxproj").path
    #expect(mkfifo(path, 0o600) == 0)
    #expect(throws: GameProjectError.unsafePath("Game.rxproj")) { try GameProjectInspector().inspect(rootURL: fixture.root) }
}

@Test(arguments: ["../game/index.html", "/index.html", "a/../index.html", "a//index.html", "a\\index.html", "file:index.html", "a\nindex.html"])
func decodedArtifactPathsCannotBypassRelativePathValidation(_ path: String) throws {
    let encoded = try JSONEncoder().encode(path)
    #expect(throws: GameProjectError.invalidRelativePath) { try JSONDecoder().decode(GameRelativePath.self, from: encoded) }
}

@Test func launchNeedsActualHostRegistrationAndResources() throws {
    let fixture = try phaser(), current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: .init(), artifact: artifact(current))
            == .unavailable(engine: .phaser, reason: .adapterNotRegistered))
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: registry(ready: false), artifact: artifact(current))
            == .unavailable(engine: .phaser, reason: .runtimeNotReady))
    #expect(try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: registry(builder: nil))
            == .unavailable(engine: .phaser, reason: .buildAdapterNotRegistered))
}

@Test func preparedPlanIsIndependentOfAnActiveFileAndRejectsContextDrift() throws {
    let fixture = try phaser(), current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    let decision = try GameLaunchPlanner.plan(inspection: inspection, context: current,
                                            registry: registry(), artifact: artifact(current))
    guard case .launch(let plan) = decision else { Issue.record("Expected a plan"); return }
    try plan.validate(current: current)
    #expect(plan.artifact.entry.value == "index.html")
    #expect(throws: GameProjectError.contextChanged(.revision)) { try plan.validate(current: context(fixture, revision: "saved-2")) }
    #expect(throws: GameProjectError.contextChanged(.environment)) { try plan.validate(current: context(fixture, environmentID: "other-environment")) }
    let otherOwner = GameProjectOwner.conversation(conversationID: UUID(), workspaceID: UUID())
    #expect(throws: GameProjectError.contextChanged(.owner)) { try plan.validate(current: context(fixture, owner: otherOwner)) }
    let otherRoot = try phaser()
    #expect(throws: GameProjectError.contextChanged(.root)) { try plan.validate(current: context(otherRoot)) }
}

@Test func oldArtifactsAndDifferentRuntimeRoutesCannotBeReused() throws {
    let fixture = try phaser(), old = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: old)
    let newContext = try context(fixture, revision: "saved-2")
    let newInspection = try GameProjectInspector().inspect(context: newContext)
    #expect(throws: GameProjectError.contextChanged(.revision)) {
        try GameLaunchPlanner.plan(inspection: newInspection, context: newContext,
                                  registry: registry(), artifact: artifact(old))
    }
    #expect(throws: GameProjectError.invalidArtifact) {
        try GameLaunchPlanner.plan(inspection: inspection, context: old, registry: registry(),
                                  artifact: artifact(old, route: .bundledNative(adapterID: "other")))
    }
    let otherRoot = try phaser()
    #expect(throws: GameProjectError.contextChanged(.root)) {
        try GameLaunchPlanner.plan(inspection: inspection, context: context(otherRoot), registry: registry())
    }
}

@Test func buildRequestsRetainTheSavedRevisionAndRegistryCannotSilentlyReplaceAdapters() throws {
    let fixture = try phaser(), current = try context(fixture)
    let inspection = try GameProjectInspector().inspect(context: current)
    let decision = try GameLaunchPlanner.plan(inspection: inspection, context: current, registry: registry())
    guard case .build(let request) = decision else { Issue.record("Expected a build request"); return }
    try request.validate(current: current)
    #expect(throws: GameProjectError.contextChanged(.revision)) { try request.validate(current: context(fixture, revision: "saved-2")) }
    var adapters = try registry()
    #expect(throws: GameProjectError.duplicateAdapter(.phaser)) {
        try adapters.register(.init(engine: .phaser, route: .webKit, runtimeReady: true))
    }
}

@Test func unboundImportProbesAndOldInspectionResultsCannotAuthorizePlanning() throws {
    let fixture = try phaser(), old = try context(fixture)
    let unbound = try GameProjectInspector().inspect(rootURL: fixture.root)
    #expect(unbound.candidates.map(\.engine) == [.phaser])
    #expect(throws: GameProjectError.invalidContext) {
        try GameLaunchPlanner.plan(inspection: unbound, context: old, registry: registry())
    }
    let bound = try GameProjectInspector().inspect(context: old)
    #expect(throws: GameProjectError.contextChanged(.revision)) {
        try GameLaunchPlanner.plan(inspection: bound, context: context(fixture, revision: "saved-2"), registry: registry())
    }
}
