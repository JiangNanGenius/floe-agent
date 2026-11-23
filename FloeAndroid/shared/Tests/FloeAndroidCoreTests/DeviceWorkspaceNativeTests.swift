// SPDX-License-Identifier: MPL-2.0
//
// Device-workspace sync — REAL trusted-host lane over a booted generation.
// Source authority, receive materialization, staged commit and conflict
// contracts run against the actual fixture workspace tree (no mocks); the
// epoch is the fixture's accepted root epoch, so every fence is the
// production fence.
import XCTest
import Foundation
import Crypto
import FloePersistence
@testable import FloeAndroidCore

final class DeviceWorkspaceNativeTests: XCTestCase {
    private var tracked: [Boot] = []

    private struct Boot {
        let epoch: UInt64
        let rootPath: String
        let token: String
        var retired = false
    }

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Generation fixture (same boot discipline as G04WorkspaceFacadeTests)

    private func bootInstalledGeneration() async throws -> Boot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-device-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = String((0 ..< 16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = UInt64(DispatchTime.now().uptimeNanoseconds)
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root.standardizedFileURL.path, ownerToken: token, epoch: epoch) else {
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, rootPath: root.standardizedFileURL.path, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let generation = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  generation.epoch == epoch else { throw TestError.bootstrap }
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == epoch,
               AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
               G02RuntimeComposition.shared.isExtensionAttached(G02DomainExtensionKey.workspace) {
                return boot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        struct Mutable { var retired: Bool }
        if let index = tracked.firstIndex(where: { $0.epoch == boot.epoch }) {
            tracked[index].retired = true
        }
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not close for epoch \(boot.epoch)")
    }

    private enum TestError: Error { case bootstrap, shape }

    // MARK: - Fixture helpers

    private func makeOrdinaryConversation(epoch: UInt64, title: String = "workspace fixture")
        async throws -> UUID {
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { throw TestError.bootstrap }
        let id = UUID()
        try await installed.cluster.conversationStore.saveConversation(ConversationRecord(
            id: id, title: title, createdAt: Date(), updatedAt: Date()))
        return id
    }

    private func workspaceRoot(epoch: UInt64, taskID: UUID) throws -> URL {
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { throw TestError.bootstrap }
        return URL(fileURLWithPath: installed.cluster.identity.root.path)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)", isDirectory: true)
    }

    private func writeFixtureFile(_ root: URL, _ relative: String, bytes: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    // MARK: - Facade drivers

    private typealias Facade = DeviceWorkspaceBridgeFacade

    private func command(_ operation: String, _ body: [String: Any]) throws -> (Int32, [String: Any]?) {
        let input = try XCTUnwrap(Facade.jsonData(body))
        let outcome = Facade.shared.command(operation: operation, input: input, replyCapacity: 4096)
        guard outcome.status >= 0 else { return (outcome.status, nil) }
        guard outcome.status > 0 else { return (0, [:]) }
        let object = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: outcome.reply) as? [String: Any])
        return (outcome.status, object)
    }

    private func readAll(ticket: Int64, index: Int, size: Int) throws -> Data {
        var out = Data()
        var offset: Int64 = 0
        while out.count < size {
            let outcome = Facade.shared.read(
                ticket: ticket, index: index, offset: offset, capacity: 65_536)
            guard outcome.status >= 0 else { throw TestError.shape }
            if outcome.status == 0 { break }
            out.append(outcome.bytes)
            offset += Int64(outcome.status)
        }
        guard out.count == size else { throw TestError.shape }
        return out
    }

    private let helloDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: - Tests

    func testTargetConvergencePreservesEditsAndMovesUnchangedFilesToRecovery() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)
        _ = try await installed.cluster.workspaceStore.ensureWorkspace(conversationID: taskID, title: "rename fixture")
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)
        let baseline = Data("hello".utf8)
        let localEdit = Data("local edit".utf8)
        try writeFixtureFile(root, "Notes/Old.txt", bytes: baseline)
        try writeFixtureFile(root, "Notes/Edited.txt", bytes: localEdit)
        try writeFixtureFile(root, "Notes/Occupied.txt", bytes: localEdit)
        let (_, binding) = try command("targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        let scope = try XCTUnwrap(binding?["scope"] as? String)
        let (_, opened) = try command("targetOpen", ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        let ticket = try XCTUnwrap((opened?["ticket"] as? NSNumber)?.int64Value)

        let (_, collision) = try command("targetMove", [
            "ticket": ticket, "key": "notes/old.txt", "digest": helloDigest, "to": "Notes/Occupied.txt",
        ])
        XCTAssertEqual(collision?["outcome"] as? String, "preserved")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Notes/Occupied.txt")), localEdit)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Notes/Old.txt")), baseline)

        let (_, moved) = try command("targetMove", [
            "ticket": ticket, "key": "notes/old.txt", "digest": helloDigest, "to": "Notes/New.txt",
        ])
        XCTAssertEqual(moved?["outcome"] as? String, "moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/Old.txt").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Notes/New.txt")), baseline)

        let (_, edited) = try command("targetTrash", [
            "ticket": ticket, "key": "notes/edited.txt", "digest": helloDigest, "pathHint": "Notes/Edited.txt",
        ])
        XCTAssertEqual(edited?["outcome"] as? String, "preserved")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Notes/Edited.txt")), localEdit)
        let (_, removed) = try command("targetTrash", ["ticket": ticket, "key": "notes/new.txt", "digest": helloDigest])
        XCTAssertEqual(removed?["outcome"] as? String, "removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/New.txt").path))
        let recovery = root.appendingPathComponent("Floe Sync Conflicts/Removed")
        let copies = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(copies.first).appendingPathComponent("Notes/New.txt")), baseline)
        let (_, replay) = try command("targetTrash", ["ticket": ticket, "key": "notes/new.txt", "digest": helloDigest])
        XCTAssertEqual(replay?["outcome"] as? String, "preserved")
    }

    func testReceiveBindingMaterializesMissingWorkspaceAndSourceStaysReadOnly() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)

        // A persisted binding WITHOUT a materialized root: the source side
        // fails closed (read-only authority never materializes), the receive
        // side materializes through the original authority.
        _ = try await installed.cluster.workspaceStore.ensureWorkspace(
            conversationID: taskID, title: "receive fixture")
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let (sourceStatus, _) = try command(
            "binding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertEqual(sourceStatus, -805)

        let (targetStatus, targetReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertEqual(targetStatus, Int32(targetStatus))  // >= 0
        let scope = try XCTUnwrap(targetReply?["scope"] as? String)
        XCTAssertTrue(scope.hasPrefix("floe.workspace.v1."))
        XCTAssertFalse(scope.contains("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        // Idempotent: a second receive binding returns the SAME scope and
        // never re-points the existing binding.
        let (againStatus, againReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertEqual(againStatus, targetStatus)
        XCTAssertEqual(againReply?["scope"] as? String, scope)

        // Now that the root is present, the source side admits it too and
        // both scopes agree (same workspace + same root identity).
        let (sourceStatus2, sourceReply) = try command(
            "binding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(sourceStatus2, 0)
        XCTAssertEqual(sourceReply?["scope"] as? String, scope)
    }

    func testSourceOpenReadVerifyAndConflictOnChange() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)
        _ = try await installed.cluster.workspaceStore.ensureWorkspace(
            conversationID: taskID, title: "source fixture")
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFixtureFile(root, "Notes/todo.txt", bytes: Data("hello".utf8))
        try writeFixtureFile(root, "data/blob.bin", bytes: Data([0, 1, 2, 3, 4]))
        try writeFixtureFile(root, "empty.bin", bytes: Data())
        // Excluded material never enters the manifest.
        try writeFixtureFile(root, ".git/config", bytes: Data("x".utf8))
        try writeFixtureFile(root, ".env.local", bytes: Data("SECRET".utf8))
        try writeFixtureFile(root, "secret.pem", bytes: Data("KEY".utf8))
        try writeFixtureFile(root, "node_modules/lib/index.js", bytes: Data("x".utf8))

        let (bindingStatus, bindingReply) = try command(
            "binding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(bindingStatus, 0)
        let scope = try XCTUnwrap(bindingReply?["scope"] as? String)

        let (openStatus, openReply) = try command(
            "sourceOpen",
            ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        XCTAssertGreaterThanOrEqual(openStatus, 0)
        let ticket = try XCTUnwrap(openReply?["ticket"] as? Int64)
        let manifestSize = try XCTUnwrap(openReply?["manifestSize"] as? Int)
        XCTAssertGreaterThan(manifestSize, 0)

        let manifestData = try readAll(ticket: ticket, index: -1, size: manifestSize)
        let manifest = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let paths = entries.compactMap { $0["path"] as? String }
        XCTAssertEqual(paths, ["Notes", "Notes/todo.txt", "data", "data/blob.bin", "empty.bin"])
        let fileRow = try XCTUnwrap(entries.first {
            ($0["path"] as? String) == "Notes/todo.txt" && ($0["kind"] as? String) == "file"
        })
        XCTAssertEqual(fileRow["size"] as? Int, 5)
        XCTAssertEqual(fileRow["digest"] as? String, helloDigest)
        let emptyRow = try XCTUnwrap(entries.first {
            ($0["path"] as? String) == "empty.bin" && ($0["kind"] as? String) == "file"
        })
        XCTAssertEqual(emptyRow["size"] as? Int, 0)
        XCTAssertEqual(emptyRow["digest"] as? String, emptyDigest)

        // Manifest + file reads through the 64 KiB page channel.
        let fileIndex = try XCTUnwrap(entries.firstIndex { ($0["path"] as? String) == "Notes/todo.txt" })
        let bytes = try readAll(ticket: ticket, index: fileIndex, size: 5)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello")

        // Confirmation accepts the untouched snapshot (zero-byte included)...
        let (verifyStatus, _) = try command(
            "sourceVerify", ["ticket": ticket, "index": fileIndex])
        XCTAssertEqual(verifyStatus, 0)
        let emptyIndex = try XCTUnwrap(entries.firstIndex { ($0["path"] as? String) == "empty.bin" })
        let (verifyEmpty, _) = try command(
            "sourceVerify", ["ticket": ticket, "index": emptyIndex])
        XCTAssertEqual(verifyEmpty, 0)

        // ...and refuses after a content change.
        try writeFixtureFile(root, "Notes/todo.txt", bytes: Data("changed".utf8))
        let (verifyChanged, _) = try command(
            "sourceVerify", ["ticket": ticket, "index": fileIndex])
        XCTAssertEqual(verifyChanged, -806)

        let (closeStatus, _) = try command("close", ["ticket": ticket])
        XCTAssertEqual(closeStatus, 0)
        let (closeAgain, _) = try command("close", ["ticket": ticket])
        XCTAssertEqual(closeAgain, 0)
        let (unknownRead) = Facade.shared.read(ticket: ticket, index: 0, offset: 0, capacity: 16)
        XCTAssertEqual(unknownRead.status, -802)  // retired ticket fences as stale
    }

    func testSourceOpenRefusesForeignScopeAndStaleEpoch() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)
        _ = try await installed.cluster.workspaceStore.ensureWorkspace(
            conversationID: taskID, title: "scope fixture")
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let (foreign, _) = try command(
            "sourceOpen",
            ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": "floe.workspace.v1.deadbeef"])
        XCTAssertEqual(foreign, -805)

        let (stale, _) = try command(
            "binding", ["epoch": boot.epoch &+ 1, "taskID": taskID.uuidString])
        XCTAssertEqual(stale, -802)
        let (zero, _) = try command("binding", ["epoch": 0, "taskID": taskID.uuidString])
        XCTAssertEqual(zero, -801)
        let (badTask, _) = try command(
            "binding", ["epoch": boot.epoch, "taskID": "not-a-uuid"])
        XCTAssertEqual(badTask, -105)
    }

    func testTargetExclusiveCreateReplaceAndOldBytesPreservedOnFailure() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)

        let (bindingStatus, bindingReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(bindingStatus, 0)
        let scope = try XCTUnwrap(bindingReply?["scope"] as? String)
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)

        let (openStatus, openReply) = try command(
            "targetOpen", ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        XCTAssertGreaterThanOrEqual(openStatus, 0)
        let ticket = try XCTUnwrap(openReply?["ticket"] as? Int64)

        let (missing, missingReply) = try command(
            "targetInfo", ["ticket": ticket, "path": "docs/readme.md"])
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(missingReply?["kind"] as? String, "missing")

        // Exclusive create.
        let hello = Data("hello".utf8)
        let (stageStatus, stageReply) = try command("targetStage", ["ticket": ticket])
        XCTAssertGreaterThanOrEqual(stageStatus, 0)
        let stage = try XCTUnwrap(stageReply?["ticket"] as? Int64)
        let page = Data((0..<5).map { _ in UInt8(ascii: "h") })
        // Staged append in two chunks to exercise the page channel.
        XCTAssertEqual(Facade.shared.write(ticket: stage, bytes: hello.subdata(in: 0..<2)), 0)
        XCTAssertEqual(Facade.shared.write(ticket: stage, bytes: hello.subdata(in: 2..<5)), 0)
        let (commitStatus, _) = try command(
            "targetCommit",
            ["ticket": stage, "path": "docs/readme.md", "digest": helloDigest, "size": 5])
        XCTAssertEqual(commitStatus, 0)
        let landed = try Data(contentsOf: root.appendingPathComponent("docs/readme.md"))
        XCTAssertEqual(String(data: landed, encoding: .utf8), "hello")

        // A second exclusive create conflicts and touches nothing.
        let (stage2Status, stage2Reply) = try command("targetStage", ["ticket": ticket])
        let stage2 = try XCTUnwrap(stage2Reply?["ticket"] as? Int64)
        XCTAssertEqual(Facade.shared.write(ticket: stage2, bytes: hello), 0)
        let (dupe, _) = try command(
            "targetCommit",
            ["ticket": stage2, "path": "docs/readme.md", "digest": helloDigest, "size": 5])
        XCTAssertEqual(dupe, -806)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/readme.md")), "hello")

        // Replace with a wrong previous digest conflicts; old bytes survive.
        let world = Data("world!".utf8)
        let worldDigest = SHA256.hash(data: world).map { String(format: "%02x", $0) }.joined()
        let (stage3Status, stage3Reply) = try command("targetStage", ["ticket": ticket])
        let stage3 = try XCTUnwrap(stage3Reply?["ticket"] as? Int64)
        XCTAssertEqual(Facade.shared.write(ticket: stage3, bytes: world), 0)
        let wrong = String(repeating: "0", count: 64)
        let (wrongReplace, _) = try command(
            "targetCommit",
            ["ticket": stage3, "path": "docs/readme.md", "digest": worldDigest, "size": 6,
             "expectedDigest": wrong])
        XCTAssertEqual(wrongReplace, -806)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/readme.md")), "hello")

        // Replace with the exact previous digest lands the new bytes.
        let (stage4Status, stage4Reply) = try command("targetStage", ["ticket": ticket])
        let stage4 = try XCTUnwrap(stage4Reply?["ticket"] as? Int64)
        XCTAssertEqual(Facade.shared.write(ticket: stage4, bytes: world), 0)
        let (replace, _) = try command(
            "targetCommit",
            ["ticket": stage4, "path": "docs/readme.md", "digest": worldDigest, "size": 6,
             "expectedDigest": helloDigest])
        XCTAssertEqual(replace, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/readme.md")), "world!")

        let (closeStatus, _) = try command("close", ["ticket": ticket])
        XCTAssertEqual(closeStatus, 0)
    }

    func testTargetDeterministicConflictStorage() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let (bindingStatus, bindingReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(bindingStatus, 0)
        let scope = try XCTUnwrap(bindingReply?["scope"] as? String)
        let (_, openReply) = try command(
            "targetOpen", ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        let ticket = try XCTUnwrap(openReply?["ticket"] as? Int64)
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)

        let bytes = Data("peer version".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let (stageStatus, stageReply) = try command("targetStage", ["ticket": ticket])
        let stage = try XCTUnwrap(stageReply?["ticket"] as? Int64)
        XCTAssertGreaterThanOrEqual(stageStatus, 0)
        XCTAssertEqual(Facade.shared.write(ticket: stage, bytes: bytes), 0)
        let (commit, _) = try command(
            "targetCommit",
            ["ticket": stage, "path": "docs/readme.md", "digest": digest, "size": Int64(bytes.count),
             "conflictDigest": digest])
        XCTAssertEqual(commit, 0)

        let conflictURL = root.appendingPathComponent("Floe Sync Conflicts/\(digest)/docs/readme.md")
        XCTAssertEqual(try String(contentsOf: conflictURL), "peer version")

        // The scoped probe finds the stored copy again.
        let (probe, probeReply) = try command(
            "targetInfo",
            ["ticket": ticket, "path": "docs/readme.md", "conflictDigest": digest])
        XCTAssertEqual(probe, 0)
        XCTAssertEqual(probeReply?["kind"] as? String, "file")
        XCTAssertEqual(probeReply?["digest"] as? String, digest)
    }

    func testTargetDirectoryAndBlockedStructuralCollision() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let (bindingStatus, bindingReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(bindingStatus, 0)
        let scope = try XCTUnwrap(bindingReply?["scope"] as? String)
        let (_, openReply) = try command(
            "targetOpen", ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        let ticket = try XCTUnwrap(openReply?["ticket"] as? Int64)
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)

        // Directory creation chains parents; a repeat is idempotent success.
        let (mkdir, _) = try command("targetDirectory", ["ticket": ticket, "path": "a/b/c"])
        XCTAssertEqual(mkdir, 0)
        let (mkdirAgain, _) = try command("targetDirectory", ["ticket": ticket, "path": "a/b/c"])
        XCTAssertEqual(mkdirAgain, 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("a/b/c").path, isDirectory: &isDirectory) && isDirectory.boolValue)

        // A structural collision (a file where a directory must go) is a
        // preserved conflict, never a write-through.
        try writeFixtureFile(root, "blocked/file", bytes: Data("x".utf8))
        let (blocked, _) = try command("targetDirectory", ["ticket": ticket, "path": "blocked/file/inner"])
        XCTAssertEqual(blocked, -806)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("blocked/file")), "x")
    }

    func testTargetDirectoryConflictCopyUsesPathDigest() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let (bindingStatus, bindingReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(bindingStatus, 0)
        let scope = try XCTUnwrap(bindingReply?["scope"] as? String)
        let (_, openReply) = try command(
            "targetOpen", ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        let ticket = try XCTUnwrap(openReply?["ticket"] as? Int64)
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)

        // The deterministic conflict-directory chain for an (empty)
        // directory entry is scoped by sha256(raw UTF-8 original path).
        let path = "designs/moodboard"
        let pathDigest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let (mkdir, _) = try command(
            "targetDirectory",
            ["ticket": ticket, "path": path, "conflictDigest": pathDigest])
        XCTAssertEqual(mkdir, 0)
        var isDirectory: ObjCBool = false
        let conflictLeaf = root.appendingPathComponent("Floe Sync Conflicts/\(pathDigest)/\(path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictLeaf.path, isDirectory: &isDirectory)
                      && isDirectory.boolValue)

        // A mismatched digest is invalid and creates nothing.
        let wrong = String(repeating: "0", count: 64)
        let (bad, _) = try command(
            "targetDirectory",
            ["ticket": ticket, "path": "other/dir", "conflictDigest": wrong])
        XCTAssertEqual(bad, -105)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Floe Sync Conflicts/\(wrong)").path))
    }

    func testZeroByteTargetCommit() async throws {
        let boot = try await bootInstalledGeneration()
        let taskID = try await makeOrdinaryConversation(epoch: boot.epoch)
        let (bindingStatus, bindingReply) = try command(
            "targetBinding", ["epoch": boot.epoch, "taskID": taskID.uuidString])
        XCTAssertGreaterThanOrEqual(bindingStatus, 0)
        let scope = try XCTUnwrap(bindingReply?["scope"] as? String)
        let (_, openReply) = try command(
            "targetOpen", ["epoch": boot.epoch, "taskID": taskID.uuidString, "scope": scope])
        let ticket = try XCTUnwrap(openReply?["ticket"] as? Int64)
        let root = try workspaceRoot(epoch: boot.epoch, taskID: taskID)

        let (stageStatus, stageReply) = try command("targetStage", ["ticket": ticket])
        let stage = try XCTUnwrap(stageReply?["ticket"] as? Int64)
        XCTAssertGreaterThanOrEqual(stageStatus, 0)
        // No writes at all: seal of the empty staged file.
        let (commit, _) = try command(
            "targetCommit",
            ["ticket": stage, "path": "zero.bin", "digest": emptyDigest, "size": 0])
        XCTAssertEqual(commit, 0)
        let url = root.appendingPathComponent("zero.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }
}
