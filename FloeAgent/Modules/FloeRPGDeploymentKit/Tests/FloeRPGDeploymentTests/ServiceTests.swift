// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeRPGDeployment

struct ImportedFixture: Sendable {
    let root: URL
    let repository: FileGameProjectRepository
    let context: GameProjectContext
    let imported: GameStoredProject
    let service: RPGDeploymentService
}

func importedFixture(media: String? = nil, looseCollision: Bool = false) async throws -> ImportedFixture {
    let root = try testDirectory(), source = root.appendingPathComponent("source")
    if let media {
        try FileManager.default.copyItem(at: fixture("media/" + media), to: source)
    } else {
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Nested/Game"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("xp.rgssad"), to: source.appendingPathComponent("Nested/Game/Game.rgssad"))
        if looseCollision {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("Nested/Game/Data"), withIntermediateDirectories: true)
            try Data("loose-original".utf8).write(to: source.appendingPathComponent("Nested/Game/Data/Actors.rxdata"))
        }
    }
    try Data("user-defined terms, unchanged".utf8).write(to: source.appendingPathComponent("LICENSE"))
    try Data([1, 2, 3, 0, 255]).write(to: source.appendingPathComponent(".unknown"))
    let repository = try FileGameProjectRepository(directory: root.appendingPathComponent("repository"))
    let id = UUID(), owner = GameProjectOwner.space(recordID: id)
    let created = try await repository.createProject(projectID: id, owner: owner, title: "Imported original")
    let imported = try await repository.importContents(from: source, into: id, owner: owner, expectedRevision: created.revision)
    let context = try GameProjectContext(projectID: id, owner: owner, rootURL: source,
                                         savedRevision: imported.revision, environmentID: "host-resolved-guest")
    return try ImportedFixture(root: root, repository: repository, context: context, imported: imported,
        service: RPGDeploymentService(repository: repository, workspace: root.appendingPathComponent("staging")))
}

func read(_ fixture: ImportedFixture, _ path: String, revision: String) async throws -> Data {
    try await fixture.repository.read(fixture.context.projectID, owner: fixture.context.owner, revision: revision, path: GameRelativePath(path))
}

@Suite struct ServiceTests {
    @Test func exportArchiveCopiesOnlyForSelectedEngineAndRoot() async throws {
        let f = try await importedFixture(looseCollision: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let root = try GameRelativePath("Nested/Game")
        let selection = RPGDeploymentSelection.rgssArchive(try GameRelativePath("Nested/Game/Game.rgssad"))
        #expect(RPGDeploymentService.availableAssets(in: f.imported, engine: .rpgMakerXP, selectedRoot: root) == [selection])
        #expect(RPGDeploymentService.availableAssets(in: f.imported, engine: .rpgMakerXP, selectedRoot: nil).isEmpty)
        #expect(RPGDeploymentService.availableAssets(in: f.imported, engine: .rpgMakerVXAce, selectedRoot: root).isEmpty)
        let list = try await f.service.readAssets(context: f.context, current: f.context, engine: .rpgMakerXP,
                                                  selectedRoot: root, selection: selection, export: false)
        #expect(list.directory == nil)
        #expect(list.files.contains { $0.path.value == "Data/Map001.rxdata" })
        let copy = try await f.service.readAssets(context: f.context, current: f.context, engine: .rpgMakerXP,
                                                  selectedRoot: root, selection: selection, export: true)
        #expect(copy.files == list.files)
        let directory = try #require(copy.directory)
        let actors = try Data(contentsOf: directory.appendingPathComponent("Data/Actors.rxdata"))
        #expect(try actors == Data(contentsOf: fixture("plain/xp/Data/Actors.rxdata")))
        #expect(try await read(f, "Nested/Game/Data/Actors.rxdata", revision: f.imported.revision) == Data("loose-original".utf8))
        #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == f.imported)
        let savedArchive = try await read(f, selection.path.value, revision: f.imported.revision)
        #expect(try savedArchive == Data(contentsOf: fixture("xp.rgssad")))
        try await f.service.discardAssetCopy(copy.id)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: RPGDeploymentError.invalidSelection) {
            try await f.service.readAssets(context: f.context, current: f.context, engine: .rpgMakerVX,
                                           selectedRoot: root, selection: selection, export: true)
        }
    }

    @Test func exportMediaPreservesSystemAndRejectsStaleRevision() async throws {
        for (name, engine, other) in [("mv", GameEngineID.rpgMakerMV, GameEngineID.rpgMakerMZ),
                                     ("mz", .rpgMakerMZ, .rpgMakerMV)] {
            let f = try await importedFixture(media: name)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let selection = try #require(RPGDeploymentService.availableAssets(in: f.imported, engine: engine,
                                                                             selectedRoot: nil).first)
            #expect(RPGDeploymentService.availableAssets(in: f.imported, engine: other, selectedRoot: nil).isEmpty)
            let list = try await f.service.readAssets(context: f.context, current: f.context, engine: engine,
                                                      selectedRoot: nil, selection: selection, export: false)
            #expect(list.files.count == 3)
            let copy = try await f.service.readAssets(context: f.context, current: f.context, engine: engine,
                                                       selectedRoot: nil, selection: selection, export: true)
            let directory = try #require(copy.directory)
            #expect(copy.files == list.files)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data/System.json").path))
            let png = try Data(contentsOf: directory.appendingPathComponent("img/pictures/original.png"))
            #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == f.imported)
            #expect(try await read(f, "data/System.json", revision: f.imported.revision) == Data(contentsOf: fixture("media/" + name + "/data/System.json")))
            try await f.service.discardAssetCopy(copy.id)
            _ = try await f.repository.commit(f.context.projectID, owner: f.context.owner, expectedRevision: f.context.savedRevision,
                                              changes: [.write(try GameRelativePath("new.txt"), Data([1]))])
            await #expect(throws: GameProjectError.self) {
                try await f.service.readAssets(context: f.context, current: f.context, engine: engine,
                                               selectedRoot: nil, selection: selection, export: true)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("staging").path).isEmpty)
        }
    }

    @Test func interruptedOrInvalidMediaExportRemovesPartialCopies() async throws {
        let f = try await importedFixture(media: "mv")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let system = try GameRelativePath("data/System.json")
        let selected = RPGDeploymentSelection.encryptedMedia(systemJSON: system)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.service.readAssets(context: f.context, current: f.context, engine: .rpgMakerMV,
                                                  selectedRoot: nil, selection: selected, export: true)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let bad = try await f.repository.commit(f.context.projectID, owner: f.context.owner, expectedRevision: f.context.savedRevision,
                                                changes: [.write(try GameRelativePath("img/pictures/original.rpgmvp"), Data(repeating: 0, count: 64))])
        let context = try GameProjectContext(projectID: f.context.projectID, owner: f.context.owner, rootURL: f.context.rootURL,
                                             savedRevision: bad.revision, environmentID: f.context.environmentID)
        await #expect(throws: RPGDeploymentError.invalidMediaHeader) {
            try await f.service.readAssets(context: context, current: context, engine: .rpgMakerMV,
                                           selectedRoot: nil, selection: selected, export: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("staging").path).isEmpty)
        #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == bad)
    }
    @Test func rawImportFirstThenReviewedCASWithArchiveBackupAndReopenUndo() async throws {
        let f = try await importedFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let preparation = try await f.service.prepare(context: f.context, current: f.context,
                                                       selection: .rgssArchive(GameRelativePath("Nested/Game/Game.rgssad")))
        #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == f.imported)
        let committed = try await f.service.commit(preparation.id, current: f.context)
        #expect(committed.project.parent == f.imported.revision)
        #expect(committed.activeGameRoot?.value == "Nested/Game")
        #expect(!committed.project.files.contains { $0.path.value == "Nested/Game/Game.rgssad" })
        #expect(try await read(f, committed.originalBackupRoot.value + "/Archive/Nested/Game/Game.rgssad", revision: committed.project.revision) == Data(contentsOf: fixture("xp.rgssad")))
        #expect(try await read(f, "Nested/Game/Data/Actors.rxdata", revision: committed.project.revision) == Data(contentsOf: fixture("plain/xp/Data/Actors.rxdata")))
        #expect(try await read(f, "LICENSE", revision: committed.project.revision) == Data("user-defined terms, unchanged".utf8))
        #expect(try await read(f, ".unknown", revision: committed.project.revision) == Data([1, 2, 3, 0, 255]))
        let reopened = try FileGameProjectRepository(directory: f.root.appendingPathComponent("repository"))
        #expect(try await reopened.open(f.context.projectID, owner: f.context.owner) == committed.project)
        let restored = try await reopened.restore(f.context.projectID, owner: f.context.owner,
            expectedRevision: committed.project.revision, historicalRevision: f.imported.revision)
        #expect(restored.files == f.imported.files)
        #expect(try await read(f, "Nested/Game/Game.rgssad", revision: restored.revision) == Data(contentsOf: fixture("xp.rgssad")))
    }

    @Test func looseConflictRequiresChoiceAndBothChoicesPreserveOriginals() async throws {
        for policy in [RPGDeploymentCollisionPolicy.fail, .preferLoose, .preferDecoded] {
            let f = try await importedFixture(looseCollision: true); defer { try? FileManager.default.removeItem(at: f.root) }
            do {
                let plan = try await f.service.prepare(context: f.context, current: f.context,
                    selection: .rgssArchive(GameRelativePath("Nested/Game/Game.rgssad")), collisionPolicy: policy)
                #expect(policy != .fail)
                let committed = try await f.service.commit(plan.id, current: f.context)
                let actual = try await read(f, "Nested/Game/Data/Actors.rxdata", revision: committed.project.revision)
                if policy == .preferLoose { #expect(actual == Data("loose-original".utf8)) }
                else {
                    #expect(try actual == Data(contentsOf: fixture("plain/xp/Data/Actors.rxdata")))
                    #expect(try await read(f, plan.originalBackupRoot.value + "/Loose/Nested/Game/Data/Actors.rxdata", revision: committed.project.revision) == Data("loose-original".utf8))
                }
            } catch {
                #expect(policy == .fail)
                #expect(error is RPGDeploymentError)
                #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == f.imported)
            }
        }
    }

    @Test func staleRevisionRejectsCommitAndRetainsRecovery() async throws {
        let f = try await importedFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = try await f.service.prepare(context: f.context, current: f.context,
                                               selection: .rgssArchive(GameRelativePath("Nested/Game/Game.rgssad")))
        let changed = try await f.repository.commit(f.context.projectID, owner: f.context.owner,
                                                     expectedRevision: f.imported.revision, changes: [], title: "Other edit")
        do { _ = try await f.service.commit(plan.id, current: f.context); Issue.record("Accepted stale import") }
        catch let error as GameProjectError {
            #expect(error == .conflict(expected: f.imported.revision, actual: changed.revision))
        }
        #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == changed)
        #expect(FileManager.default.fileExists(atPath: plan.stagingDirectory.path))
        try await f.service.discard(plan.id)
        #expect(!FileManager.default.fileExists(atPath: plan.stagingDirectory.path))
    }

    @Test func environmentSwitchAndOwnershipCannotRedirectPreparedWrites() async throws {
        let f = try await importedFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = try await f.service.prepare(context: f.context, current: f.context,
                                               selection: .rgssArchive(GameRelativePath("Nested/Game/Game.rgssad")))
        let switched = try GameProjectContext(projectID: f.context.projectID, owner: f.context.owner,
            rootURL: f.context.rootURL, savedRevision: f.context.savedRevision, environmentID: "different-guest")
        do { _ = try await f.service.commit(plan.id, current: switched); Issue.record("Accepted switched environment") }
        catch let error as GameProjectError { #expect(error == .contextChanged(.environment)) }
        let otherID = UUID()
        let other = try GameProjectContext(projectID: otherID, owner: .space(recordID: otherID), rootURL: f.context.rootURL,
                                           savedRevision: f.context.savedRevision, environmentID: f.context.environmentID)
        do { _ = try await f.service.commit(plan.id, current: other); Issue.record("Accepted switched owner") }
        catch let error as GameProjectError { #expect(error == .contextChanged(.project)) }
        #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == f.imported)
        try await f.service.discard(plan.id)
    }

    @Test func lateStagingTamperAndSymlinkRejectWithoutSourceWrite() async throws {
        for symlink in [false, true] {
            let f = try await importedFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let plan = try await f.service.prepare(context: f.context, current: f.context,
                                                   selection: .rgssArchive(GameRelativePath("Nested/Game/Game.rgssad")))
            let target = plan.stagingDirectory.appendingPathComponent("write-0")
            if symlink {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture("manifest.json"))
            } else { try Data("late mutation".utf8).write(to: target) }
            do { _ = try await f.service.commit(plan.id, current: f.context); Issue.record("Accepted tampered staged file") }
            catch let error as RPGDeploymentError { #expect(error == .sourceChanged) }
            #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == f.imported)
            try await f.service.discard(plan.id)
        }
    }

    @Test func bothWebGenerationsKeepEncryptedOriginalsAndDisableOnlyPreparedFlags() async throws {
        for engine in ["mv", "mz"] {
            let f = try await importedFixture(media: engine); defer { try? FileManager.default.removeItem(at: f.root) }
            let oldSystem = try await read(f, "data/System.json", revision: f.imported.revision)
            var originalBytes: [GameRelativePath: Data] = [:]
            for file in f.imported.files {
                originalBytes[file.path] = try await read(f, file.path.value, revision: f.imported.revision)
            }
            let plan = try await f.service.prepare(context: f.context, current: f.context,
                                                   selection: .encryptedMedia(systemJSON: GameRelativePath("data/System.json")))
            let committed = try await f.service.commit(plan.id, current: f.context)
            let system = try await read(f, "data/System.json", revision: committed.project.revision)
            let json = try #require(JSONSerialization.jsonObject(with: system) as? [String: Any])
            #expect(json["hasEncryptedImages"] as? Bool == false)
            #expect(json["hasEncryptedAudio"] as? Bool == false)
            #expect((json["unknownPlugin"] as? [String: Any])?["keep"] != nil)
            #expect(try await read(f, plan.originalBackupRoot.value + "/System/data/System.json", revision: committed.project.revision) == oldSystem)
            #expect(try await read(f, "img/pictures/original.png", revision: committed.project.revision) == Data(contentsOf: fixture("plain-media/\(engine)/img/pictures/original.png")))
            for file in f.imported.files where file.path.value != "data/System.json" {
                #expect(try await read(f, file.path.value, revision: committed.project.revision) == originalBytes[file.path])
            }
        }
    }

    @Test func nestedMediaRootUsesOwnKeyAndIsLeftIntact() async throws {
        let f = try await importedFixture(media: "mv"); defer { try? FileManager.default.removeItem(at: f.root) }
        let second = try await f.repository.commit(f.context.projectID, owner: f.context.owner,
            expectedRevision: f.imported.revision, changes: [
                .write(GameRelativePath("Other/data/System.json"), Data("{\"encryptionKey\":\"different-root-key\"}".utf8)),
                .write(GameRelativePath("Other/img/secret.png_"), Data("nonstandard-external-data".utf8))])
        let context = try GameProjectContext(projectID: f.context.projectID, owner: f.context.owner,
            rootURL: f.context.rootURL, savedRevision: second.revision, environmentID: f.context.environmentID)
        let plan = try await f.service.prepare(context: context, current: context,
                                               selection: .encryptedMedia(systemJSON: GameRelativePath("data/System.json")))
        #expect(!plan.files.contains { $0.path.value.hasPrefix("Other/") })
        _ = try await f.service.commit(plan.id, current: context)
    }

    @Test func invalidArchiveRetainsWholeRawImportAndFailureReceipt() async throws {
        let f = try await importedFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let changed = try await f.repository.commit(f.context.projectID, owner: f.context.owner,
            expectedRevision: f.imported.revision, changes: [.write(GameRelativePath("Nested/Game/Game.rgssad"), Data("unknown protection".utf8))])
        let context = try GameProjectContext(projectID: f.context.projectID, owner: f.context.owner,
            rootURL: f.context.rootURL, savedRevision: changed.revision, environmentID: f.context.environmentID)
        do {
            _ = try await f.service.prepare(context: context, current: context, selection: .rgssArchive(GameRelativePath("Nested/Game/Game.rgssad")))
            Issue.record("Accepted nonstandard archive")
        } catch { #expect(error is RPGDeploymentError) }
        #expect(try await f.repository.open(f.context.projectID, owner: f.context.owner) == changed)
        let stages = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("staging"), includingPropertiesForKeys: nil)
        #expect(stages.count == 1)
        #expect(FileManager.default.fileExists(atPath: stages[0].appendingPathComponent("FAILURE.json").path))
        #expect(try Data(contentsOf: stages[0].appendingPathComponent("original.rgss")) == Data("unknown protection".utf8))
    }
}
