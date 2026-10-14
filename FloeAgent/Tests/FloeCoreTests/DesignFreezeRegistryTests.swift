// FloeCoreTests — Design freeze registry identity semantics and durability.
// The freeze must hold against the real alias/dodge patterns: `../`
// traversal, symlink swaps, file replacement (new inode at the same path)
// and hard links (same inode at another path).

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.DesignFreezeRegistry")
struct DesignFreezeRegistryTests {
    private func makeRegistry() throws -> (DesignFreezeRegistry, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-freeze-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = DesignFreezeRegistry(store: .init(directory: directory))
        return (registry, directory)
    }

    @Test("protect/unprotect round-trips through the durable store")
    func roundTrip() throws {
        let (registry, directory) = try makeRegistry()
        let root = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("index.html")
        try "<html></html>".write(to: file, atomically: true, encoding: .utf8)
        let sha = FloeDigest.sha256Hex(Data("<html></html>".utf8))

        registry.protect(file, conversationID: "task-a", frozenSHA256: sha)
        #expect(registry.protection(for: file)?.conversationID == "task-a")
        #expect(registry.protection(for: file)?.frozenSHA256 == sha)

        // Re-read from disk: a fresh registry over the same store sees it.
        let reloaded = DesignFreezeRegistry(store: .init(directory: directory))
        #expect(reloaded.protection(for: file)?.conversationID == "task-a")

        #expect(registry.unprotect(file) > 0)
        #expect(registry.protection(for: file) == nil)
        // The removal persisted: a fresh registry sees nothing.
        #expect(DesignFreezeRegistry(store: .init(directory: directory)).allProtections().isEmpty)
    }

    @Test("a replaced file (new inode, same path) stays frozen by path")
    func replacedFileStillFrozen() throws {
        let (registry, directory) = try makeRegistry()
        let file = directory.appendingPathComponent("site/style.css")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        registry.protect(file, conversationID: "task-a", frozenSHA256: "sha1")

        // Attacker dodge: delete and recreate the file (new inode).
        try FileManager.default.removeItem(at: file)
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        #expect(registry.protection(for: file) != nil)
    }

    @Test("a hard link alias (same inode, different path) is frozen")
    func hardLinkAliasIsFrozen() throws {
        let (registry, directory) = try makeRegistry()
        let original = directory.appendingPathComponent("original.txt")
        let alias = directory.appendingPathComponent("alias.txt")
        try "same inode".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: alias)
        registry.protect(original, conversationID: "task-a", frozenSHA256: "sha1")
        #expect(registry.protection(for: alias)?.conversationID == "task-a")
    }

    @Test("a symlink pointing at the frozen file is frozen")
    func symlinkAliasIsFrozen() throws {
        let (registry, directory) = try makeRegistry()
        let original = directory.appendingPathComponent("real.txt")
        let link = directory.appendingPathComponent("link.txt")
        try "bytes".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        registry.protect(original, conversationID: "task-a", frozenSHA256: "sha1")
        #expect(registry.protection(for: link)?.conversationID == "task-a")
    }

    @Test("unprotectAll releases only the owning conversation")
    func unprotectAllScopesByConversation() throws {
        let (registry, directory) = try makeRegistry()
        let a = directory.appendingPathComponent("a.txt")
        let b = directory.appendingPathComponent("b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        registry.protect(a, conversationID: "task-a", frozenSHA256: "1")
        registry.protect(b, conversationID: "task-b", frozenSHA256: "2")
        registry.unprotectAll(conversationID: "task-a")
        #expect(registry.protection(for: a) == nil)
        #expect(registry.protection(for: b) != nil)
    }

    @Test("removeWhere prunes stale entries")
    func removeWherePrunes() throws {
        let (registry, directory) = try makeRegistry()
        let file = directory.appendingPathComponent("c.txt")
        try "c".write(to: file, atomically: true, encoding: .utf8)
        registry.protect(file, conversationID: "gone", frozenSHA256: "3")
        let removed = registry.removeWhere { $0.conversationID == "gone" }
        #expect(removed.count == 1)
        #expect(registry.protection(for: file) == nil)
    }

    @Test("corrupt store decodes to no protections, never fabricated")
    func corruptStoreFailsClosed() throws {
        let (_, directory) = try makeRegistry()
        try "not json".write(
            to: directory.appendingPathComponent("DesignFreezeRegistry.json"),
            atomically: true, encoding: .utf8)
        let registry = DesignFreezeRegistry(store: .init(directory: directory))
        #expect(registry.allProtections().isEmpty)
    }

    // MARK: - Multi-owner sources

    @Test("one source frozen by two tasks: each owner's release is independent")
    func multiOwnerReleasesAreIndependent() throws {
        let (registry, directory) = try makeRegistry()
        let file = directory.appendingPathComponent("shared.html")
        try "shared".write(to: file, atomically: true, encoding: .utf8)
        registry.protect(file, conversationID: "task-a", frozenSHA256: "1")
        registry.protect(file, conversationID: "task-b", frozenSHA256: "1")
        #expect(registry.allProtections().count == 2)

        // Task A ends (adopts/rejects/ends): its freeze lifts, B's remains.
        #expect(registry.unprotect(file, conversationID: "task-a") == 1)
        let remaining = try #require(registry.protection(for: file))
        #expect(remaining.conversationID == "task-b")

        // Owner-scoped unprotectAll never touches another owner.
        registry.unprotectAll(conversationID: "task-b")
        #expect(registry.allProtections().isEmpty)
    }

    @Test("re-freezing the same source for the same owner replaces, never duplicates")
    func sameOwnerReprotectIsIdempotent() throws {
        let (registry, directory) = try makeRegistry()
        let file = directory.appendingPathComponent("idempotent.html")
        try "v".write(to: file, atomically: true, encoding: .utf8)
        registry.protect(file, conversationID: "task-a", frozenSHA256: "1")
        registry.protect(file, conversationID: "task-a", frozenSHA256: "2")
        #expect(registry.allProtections().count == 1)
        #expect(registry.protection(for: file)?.frozenSHA256 == "2")
    }

    // MARK: - Directory originals (webroots)

    @Test("a directory original freezes every EXISTING file in the tree but not new paths")
    func directoryOriginalTreeSemantics() throws {
        let (registry, directory) = try makeRegistry()
        let site = directory.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let index = site.appendingPathComponent("index.html")
        let style = site.appendingPathComponent("style.css")
        try "index".write(to: index, atomically: true, encoding: .utf8)
        try "style".write(to: style, atomically: true, encoding: .utf8)
        registry.protect(site, conversationID: "task-a", frozenSHA256: "")

        // Existing originals inside the tree are frozen.
        #expect(registry.protection(for: index)?.conversationID == "task-a")
        #expect(registry.protection(for: style)?.conversationID == "task-a")
        // The webroot itself is frozen against delete/move.
        #expect(registry.protection(ancestorOf: site) != nil)
        #expect(registry.protection(ancestorOf: directory)?.conversationID == "task-a")
        // A NEW staging path inside the webroot stays open.
        let novel = site.appendingPathComponent("candidate-new.html")
        try "new".write(to: novel, atomically: true, encoding: .utf8)
        #expect(registry.protection(for: novel) == nil)
    }

    @Test("deleting or renaming a PARENT directory of a frozen file is rejected")
    func ancestorMutationsAreRejected() throws {
        let (registry, directory) = try makeRegistry()
        let site = directory.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let index = site.appendingPathComponent("index.html")
        try "index".write(to: index, atomically: true, encoding: .utf8)
        registry.protect(index, conversationID: "task-a", frozenSHA256: "sha")

        // delete("site") or move("site", "old") would relocate the frozen
        // original under a new path (and new parent inode): the
        // ancestor-check rejects it.
        #expect(registry.protection(ancestorOf: site) != nil)
        #expect(registry.protection(ancestorOf: directory) != nil)
        // Sibling writes under OTHER directories stay open.
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(registry.protection(for: other) == nil)
        #expect(registry.protection(ancestorOf: other) == nil)
    }

    // MARK: - Durable persistence proof

    @Test("protect reports persistence and verifyPersisted proves the on-disk record")
    func persistenceIsProvable() throws {
        let (registry, directory) = try makeRegistry()
        let file = directory.appendingPathComponent("durably.html")
        try "d".write(to: file, atomically: true, encoding: .utf8)
        let outcome = registry.protect(file, conversationID: "task-a", frozenSHA256: "sha")
        #expect(outcome == .persisted)
        #expect(registry.verifyPersisted(file, conversationID: "task-a"))
        #expect(!registry.verifyPersisted(file, conversationID: "task-b"))
        // A fresh process over the same store proves it too.
        let reloaded = DesignFreezeRegistry(store: .init(directory: directory))
        #expect(reloaded.verifyPersisted(file, conversationID: "task-a"))
    }

    @Test("a save failure is reported (memoryOnly) and never passes verifyPersisted; cleanup removes the half-entry")
    func saveFailureFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-freeze-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Remove write permission so the staged save cannot complete.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let registry = DesignFreezeRegistry(store: .init(directory: directory))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeze-ro-target-\(UUID().uuidString).html")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let outcome = registry.protect(file, conversationID: "task-a", frozenSHA256: "sha")
        // Not persisted: in-memory only, and the durable proof fails.
        #expect(outcome != .persisted)
        #expect(!registry.verifyPersisted(file, conversationID: "task-a"))
        // Launch-fence recovery: drop the half-entry so the user's own
        // edits are never blocked by a freeze that does not durably exist.
        registry.unprotect(file, conversationID: "task-a")
        #expect(registry.protection(for: file) == nil)
    }
}
