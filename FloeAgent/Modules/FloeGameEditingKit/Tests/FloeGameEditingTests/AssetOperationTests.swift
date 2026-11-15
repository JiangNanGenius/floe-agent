// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Asset operations with reference-safe diagnostics")
struct AssetOperationTests {
    @Test("Duplicate names in one import batch cannot overwrite each other")
    @MainActor
    func duplicateNamesInBatch() async throws {
        let (_, session) = try await SessionTests().makeSession("duplicate-batch")
        do {
            _ = try await session.importAssets([("new.dat", Data([1])), ("new.dat", Data([2]))])
            Issue.record("Duplicate batch must fail before editing")
        } catch GameProjectError.destinationExists { }
        #expect(!session.isDirty)
        #expect(!session.isBusy)
        #expect(!session.existingPaths().contains(try GameRelativePath("new.dat")))
    }
    func makeSession(_ name: String) async throws -> GameEditingSession {
        let (_, repository) = try TestSupport.makeRepository(name: name)
        let projectRoot = try TestSupport.makeTemporaryDirectory(name + "-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        return try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .phaser))
    }

    @Test("Rename rewrites JSON and text references and is undoable")
    @MainActor
    func renameUpdatesReferences() async throws {
        let session = try await makeSession("rename")
        let asset = try GameRelativePath("assets/hero.png")
        let plan = try await session.renameAsset(at: asset, newName: "mira.png")
        #expect(plan.to.value == "assets/mira.png")
        #expect(plan.references.count >= 3) // manifest (exact path), characters (file name), spawn.lua (text, x2)
        let manifest = try JSONValue.parse(try await session.documentBytes(at: try GameRelativePath("data/manifest.json")))
        #expect(manifest["heroSprite"] == .string("assets/mira.png"))
        let characters = try JSONValue.parse(try await session.documentBytes(at: try GameRelativePath("data/characters.json")))
        #expect(characters["characters"]?[0]?["portrait"] == .string("assets/mira.png"))
        let script = try await session.documentBytes(at: try GameRelativePath("data/spawn.lua"))
        #expect(String(data: script, encoding: .utf8)?.contains("assets/mira.png") == true)
        #expect(session.documentExists(at: asset) == false)
        #expect(session.documentExists(at: plan.to))
        try await session.undo()
        #expect(session.documentExists(at: asset))
        #expect(!session.documentExists(at: plan.to))
        let reverted = try JSONValue.parse(try await session.documentBytes(at: try GameRelativePath("data/manifest.json")))
        #expect(reverted["heroSprite"] == .string("assets/hero.png"))
    }

    @Test("Rename dry run reports the plan without touching the working set")
    @MainActor
    func renameDryRun() async throws {
        let session = try await makeSession("dryrun")
        let asset = try GameRelativePath("assets/hero.png")
        let plan = try await session.renameAsset(at: asset, newName: "probe.png", dryRun: true)
        #expect(plan.references.count >= 3)
        #expect(!session.isDirty)
        #expect(session.documentExists(at: asset))
    }

    @Test("Delete is blocked with exact referencing locations")
    @MainActor
    func deleteBlockedWhenReferenced() async throws {
        let session = try await makeSession("deleteblocked")
        let asset = try GameRelativePath("assets/hero.png")
        do {
            _ = try await session.deleteAsset(at: asset)
            Issue.record("Delete must be blocked while referenced")
        } catch let issue as GameEditIssue {
            #expect(issue.diagnostics.count >= 3)
            #expect(issue.diagnostics.contains { $0.path?.value == "data/manifest.json" })
            #expect(issue.diagnostics.contains { $0.path?.value == "data/spawn.lua" && $0.jsonPath == nil })
        }
        #expect(session.documentExists(at: asset))
    }

    @Test("Delete succeeds for unreferenced assets and undo restores")
    @MainActor
    func deleteUnreferenced() async throws {
        let session = try await makeSession("deletefree")
        let orphan = try GameRelativePath("assets/orphan.png")
        _ = try await session.importAssets([(name: "orphan.png", bytes: TestSupport.pngData(side: 4, rgb: (200, 100, 50)))],
                                           into: "assets")
        try await session.save()
        try await session.deleteAsset(at: orphan)
        #expect(!session.documentExists(at: orphan))
        try await session.undo()
        #expect(session.documentExists(at: orphan))
    }

    @Test("Import rejects duplicate destinations")
    @MainActor
    func importDuplicate() async throws {
        let session = try await makeSession("dupimport")
        do {
            _ = try await session.importAssets([(name: "hero.png", bytes: Data([1]))], into: "assets")
            Issue.record("Duplicate import must fail")
        } catch GameProjectError.destinationExists {}
    }

    @Test("Reference diagnostics report JSON paths and text lines")
    @MainActor
    func referenceDiagnostics() async throws {
        let session = try await makeSession("diag")
        let references = try await session.references(to: try GameRelativePath("assets/hero.png"))
        #expect(references.contains { $0.jsonPath?.components.contains(.key("heroSprite")) == true })
        #expect(references.contains { $0.referencingPath.value == "data/characters.json"
            && $0.jsonPath?.components.contains(.key("portrait")) == true })
        #expect(references.filter { $0.line != nil }.count == 2) // two lines in spawn.lua
    }
}
