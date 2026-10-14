// FloeWorkspaceTests — Ordinary-write freeze barrier: while a design task
// has a pending candidate, the model's workspace write tools MUST NOT
// overwrite the frozen original (write/overwrite/patch/delete/move/copy),
// reads stay open, new files elsewhere stay allowed, and every alias dodge
// (symlink, replaced file, hard link) is caught by the canonical + inode
// identity check. The trusted adoption path (ungated service) still
// commits, and the freeze lifts after adoption/rejection.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeModels
import FloeTools

@Suite("FloeWorkspace.DesignFreezeWriteGate")
struct DesignFreezeWriteGateTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let registry: DesignFreezeRegistry
        let environment: WorkspaceToolEnvironment
        let context: ToolContext

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-freeze-gate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let storeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-freeze-store-\(UUID().uuidString)", isDirectory: true)
            registry = DesignFreezeRegistry(store: .init(directory: storeDirectory))
            environment = WorkspaceToolEnvironment(rootProvider: { [root] in root })
            context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var gatedService: WorkspaceFileService {
            get throws {
                let service = try environment.makeService(context: context)
                // makeService wires .shared; rebind to the fixture registry.
                return WorkspaceFileService(
                    guard: service.guardResolver,
                    mutationGuard: WorkspaceToolEnvironment.designFreezeGate(registry: registry))
            }
        }

        /// The trusted adoption path: same guard, NO gate.
        var trustedService: WorkspaceFileService {
            WorkspaceFileService(
                guard: WorkspacePathGuard(rootURL: root),
                mutationGuard: nil)
        }

        func write(_ relative: String, _ content: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test("the FIRST ordinary write to a frozen original is refused")
    func firstWriteIsRefused() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        let original = fixture.root.appendingPathComponent("site/index.html")
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")

        let service = try fixture.gatedService
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/index.html", content: "<h1>v2</h1>")
        }
        // The original is untouched.
        #expect(try String(contentsOf: original, encoding: .utf8) == "<h1>v1</h1>")
    }

    @Test("create-overwrite, patch, delete, move and copy-dst are all refused")
    func everyMutationKindIsRefused() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        try fixture.write("site/other.txt", "keep")
        let original = fixture.root.appendingPathComponent("site/index.html")
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")

        let service = try fixture.gatedService
        #expect(throws: DesignFreezeError.self) {
            _ = try service.createFile("site/index.html", content: "x", overwrite: true)
        }
        #expect(throws: DesignFreezeError.self) {
            _ = try service.applyPatch(
                "site/index.html",
                patch: "--- a/site/index.html\n+++ b/site/index.html\n@@ -1 +1 @@\n-<h1>v1</h1>\n+<h1>v2</h1>\n")
        }
        #expect(throws: DesignFreezeError.self) {
            try service.delete("site/index.html")
        }
        #expect(throws: DesignFreezeError.self) {
            try service.move("site/index.html", to: "site/moved.html")
        }
        // Copy onto the existing frozen path is refused by the exists guard
        // before any byte moves.
        #expect(throws: WorkspaceToolError.self) {
            try service.copy("site/other.txt", to: "site/index.html")
        }
        // A frozen path whose file was removed still blocks a copy landing on it.
        try FileManager.default.removeItem(at: original)
        fixture.registry.unprotect(original)
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")
        #expect(throws: DesignFreezeError.self) {
            try service.copy("site/other.txt", to: "site/index.html")
        }
        try fixture.write("site/index.html", "<h1>v1</h1>")
        // createBinaryFile (native writer route) is refused too.
        #expect(throws: DesignFreezeError.self) {
            _ = try service.createBinaryFile(
                "site/index.html", data: Data("<h1>v2</h1>".utf8), overwrite: true)
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "<h1>v1</h1>")
    }

    @Test("reads and new files elsewhere stay allowed")
    func readsAndNewFilesStayAllowed() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        let original = fixture.root.appendingPathComponent("site/index.html")
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")

        let service = try fixture.gatedService
        let read = try service.readFile("site/index.html")
        #expect(read.text == "<h1>v1</h1>")
        _ = try service.createFile("site/draft-candidate.html", content: "<h1>v2</h1>")
        _ = try service.createDirectory("assets")
        // Reading the frozen file through the tools stays open.
        let metadata = try service.metadata("site/index.html")
        #expect(metadata.sha256 == FloeDigest.sha256Hex(Data("<h1>v1</h1>".utf8)))
    }

    @Test("symlink, replaced-file and hard-link aliases cannot dodge the freeze")
    func aliasesCannotDodge() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        let original = fixture.root.appendingPathComponent("site/index.html")
        let service = try fixture.gatedService

        // Symlink alias: a NEW link to the frozen inode+path.
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")
        let link = fixture.root.appendingPathComponent("site/alias.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/alias.html", content: "x")
        }

        // Hard link alias: same inode under another name.
        let hard = fixture.root.appendingPathComponent("site/hard.txt")
        try FileManager.default.linkItem(at: original, to: hard)
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/hard.txt", content: "z")
        }

        // Replaced file: same path, new inode. The path match still holds.
        fixture.registry.unprotect(original)
        fixture.registry.protect(original, conversationID: "task-2", frozenSHA256: "sha")
        try FileManager.default.removeItem(at: original)
        try "<h1>attacked</h1>".write(to: original, atomically: true, encoding: .utf8)
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/index.html", content: "y")
        }
    }

    @Test("the trusted adoption path commits and the freeze lifts")
    func trustedAdoptionCommitsAndLifts() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        let original = fixture.root.appendingPathComponent("site/index.html")
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")

        // Trusted commit (no gate): the verified adoption overwrites.
        let outcome = try fixture.trustedService.createBinaryFile(
            "site/index.html", data: Data("<h1>adopted</h1>".utf8), overwrite: true)
        #expect(outcome.sha256 == FloeDigest.sha256Hex(Data("<h1>adopted</h1>".utf8)))

        // Simulate the commit-port release, then ordinary writes flow again.
        fixture.registry.unprotect(original)
        let service = try fixture.gatedService
        _ = try service.writeFile("site/index.html", content: "<h1>next</h1>")
        #expect(try String(contentsOf: original, encoding: .utf8) == "<h1>next</h1>")
    }

    @Test("mid-commit failure preserves the original and the freeze")
    func failurePreservesOriginal() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        let original = fixture.root.appendingPathComponent("site/index.html")
        fixture.registry.protect(original, conversationID: "task-1", frozenSHA256: "sha")
        let service = try fixture.gatedService

        // A failed (frozen) write leaves bytes and freeze intact; a fresh
        // unprotected write to the same path is still refused afterwards.
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/index.html", content: "clobber")
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "<h1>v1</h1>")
        #expect(fixture.registry.protection(for: original) != nil)
    }

    @Test("unrelated conversations keep their own freezes independent")
    func freezesArePerConversation() throws {
        let fixture = try Fixture()
        try fixture.write("a.txt", "a")
        try fixture.write("b.txt", "b")
        fixture.registry.protect(
            fixture.root.appendingPathComponent("a.txt"), conversationID: "task-a", frozenSHA256: "1")
        fixture.registry.protect(
            fixture.root.appendingPathComponent("b.txt"), conversationID: "task-b", frozenSHA256: "2")
        let service = try fixture.gatedService
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("a.txt", content: "x")
        }
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("b.txt", content: "x")
        }
        fixture.registry.unprotectAll(conversationID: "task-a")
        _ = try service.writeFile("a.txt", content: "ok")
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("b.txt", content: "x")
        }
    }

    @Test("two tasks freezing the SAME original: one owner's release leaves the other frozen")
    func sharedOriginalMultiOwner() throws {
        let fixture = try Fixture()
        try fixture.write("shared.html", "v1")
        let shared = fixture.root.appendingPathComponent("shared.html")
        fixture.registry.protect(shared, conversationID: "task-a", frozenSHA256: "1")
        fixture.registry.protect(shared, conversationID: "task-b", frozenSHA256: "1")
        let service = try fixture.gatedService
        // Task A ends/adopts: its freeze lifts…
        fixture.registry.unprotect(shared, conversationID: "task-a")
        // …but the original is still frozen for task B's pending candidate.
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("shared.html", content: "x")
        }
        fixture.registry.unprotectAll(conversationID: "task-b")
        _ = try service.writeFile("shared.html", content: "now free")
    }

    @Test("deleting or renaming the PARENT directory of a frozen original is refused")
    func parentDirectoryMutationsAreRefused() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        fixture.registry.protect(
            fixture.root.appendingPathComponent("site/index.html"),
            conversationID: "task-1", frozenSHA256: "sha")
        let service = try fixture.gatedService
        #expect(throws: DesignFreezeError.self) {
            try service.delete("site", recursive: true)
        }
        #expect(throws: DesignFreezeError.self) {
            try service.move("site", to: "old-site")
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("site/index.html").path))
        // A sibling directory under the same root stays mutable.
        try fixture.write("other/note.txt", "n")
        try service.delete("other", recursive: true)
    }

    @Test("a frozen webroot refuses overwrites of its files but allows NEW staging paths")
    func webrootTreeFreeze() throws {
        let fixture = try Fixture()
        try fixture.write("site/index.html", "<h1>v1</h1>")
        try fixture.write("site/style.css", "body{}")
        let site = fixture.root.appendingPathComponent("site")
        fixture.registry.protect(site, conversationID: "task-1", frozenSHA256: "")
        let service = try fixture.gatedService
        // Existing originals inside the tree are frozen…
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/index.html", content: "clobber")
        }
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("site/style.css", content: "clobber")
        }
        // …the webroot itself cannot be deleted…
        #expect(throws: DesignFreezeError.self) {
            try service.delete("site", recursive: true)
        }
        // …while a NEW staging file inside the webroot stays writable, and
        // repeated writes to it keep working (no half-frozen state).
        _ = try service.createFile("site/candidate-stage.html", content: "<h1>draft</h1>")
        _ = try service.writeFile("site/candidate-stage.html", content: "<h1>draft v2</h1>")
    }
}
