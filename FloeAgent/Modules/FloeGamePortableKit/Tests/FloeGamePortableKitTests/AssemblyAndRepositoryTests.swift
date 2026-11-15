// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeGameCore
@testable import FloeGamePortableKit

final class AssemblyAndRepositoryTests: XCTestCase {
    func testMVAssemblerMergesPinnedCoreWithoutOverwritingSource() throws {
        let source = try TestSupport.temporaryDirectory("mv-assemble-source")
        for path in ["index.html", "js/main.js", "js/plugins.js", "data/System.json",
                     "js/floe_bridge.js", "floe-inputs.json"] {
            try TestSupport.write(path == "floe-inputs.json"
                ? String(data: try TestSupport.mvInputDeclaration().encoded(), encoding: .utf8)!
                : "{}", to: source, path: path)
        }
        let resources = try TestSupport.makePreparedResources()
        let parent = try TestSupport.temporaryDirectory("mv-assemble-parent")
        let output = parent.appendingPathComponent("game")
        let result = try GamePortableMVAssembler.assemble(
            project: try GamePortableProjectDescriptor(rootURL: source),
            resources: resources.resources, to: output)
        XCTAssertEqual(result.entry.value, "index.html")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("js/rpg_core.js"), encoding: .utf8),
                       "var core=1;")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("js/libs/pixi.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("licenses/RPG-MAKER-MV-CORESCRIPT-MIT.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("js/rpg_core.js").path) == false)
        XCTAssertThrowsError(try GamePortableMVAssembler.assemble(
            project: try GamePortableProjectDescriptor(rootURL: source),
            resources: resources.resources, to: output))
        let verification = try GamePortableArtifactVerifier.verify(directory: output, engine: .rpgMakerMV,
            profile: nil, resources: resources.resources)
        XCTAssertTrue(verification.runtimeHashVerified)
    }

    func testRepositoryPreservesCompleteTemplateTreeByteExactly() async throws {
        let template = try GamePortableTemplateCatalog.load(.mv)
        let repositoryDirectory = try TestSupport.temporaryDirectory("repository")
        let repository = try FileGameProjectRepository(directory: repositoryDirectory)
        let projectID = UUID()
        let owner = GameProjectOwner.space(recordID: projectID)
        let created = try await repository.createProject(projectID: projectID, owner: owner,
            title: "Portable MV", engine: .rpgMakerMV)
        let imported = try await repository.importContents(from: template.rootURL, into: projectID,
            owner: owner, expectedRevision: created.revision)
        let expected = try GamePortableFileAccess.enumerate(root: template.rootURL)
        XCTAssertEqual(imported.files.count, expected.filter { !$0.directory }.count)
        let system = try GameRelativePath("data/System.json")
        let original = try await repository.read(projectID, owner: owner, revision: imported.revision, path: system)
        var edited = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        edited["gameTitle"] = "Portable MV Renamed"
        let editedData = try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys])
        let committed = try await repository.commit(projectID, owner: owner, expectedRevision: imported.revision,
            changes: [.write(system, editedData)], title: "Rename")
        XCTAssertNotEqual(committed.revision, imported.revision)
        let history = try await repository.history(projectID, owner: owner)
        XCTAssertEqual(history.count, 3)
        let committedSystem = try await repository.read(projectID, owner: owner,
            revision: committed.revision, path: system)
        XCTAssertEqual(committedSystem, editedData)
        let restored = try await repository.restore(projectID, owner: owner, expectedRevision: committed.revision,
            historicalRevision: imported.revision)
        let restoredSystem = try await repository.read(projectID, owner: owner,
            revision: restored.revision, path: system)
        XCTAssertEqual(restoredSystem, original)
        XCTAssertEqual(restored.files, imported.files)
        let export = repositoryDirectory.appendingPathComponent("export")
        let context = try await repository.export(projectID, owner: owner, expectedRevision: restored.revision, to: export)
        XCTAssertEqual(context.savedRevision, restored.revision)
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("data/System.json")), original)
    }

    func testSaveBridgeSupportsOnlyCompleteSnapshots() async throws {
        let root = try TestSupport.makeMVWebProject()
        let project = try GamePortableProjectDescriptor(rootURL: root)
        let profile = try GamePortableMVAdapter().inspect(project)
        let owner = GameProjectOwner.space(recordID: project.projectID)
        let save = try GamePortableSaveBridge(directory: try TestSupport.temporaryDirectory("save"),
            projectID: project.projectID, owner: owner, profile: profile)
        let first = try await save.save(Data("{\"a\":1}".utf8), expectedRevision: 0)
        XCTAssertEqual(first.revision, 1)
        let loaded = try await save.load()
        XCTAssertEqual(loaded?.state, Data("{\"a\":1}".utf8))

        let love = try GamePortableLoveAdapter().inspect(GamePortableProjectDescriptor(
            rootURL: try TestSupport.makeLoveWebProject()))
        XCTAssertThrowsError(try GamePortableSaveBridge(directory: try TestSupport.temporaryDirectory("save2"),
            projectID: UUID(), owner: .space(recordID: UUID()), profile: love))
    }
}
