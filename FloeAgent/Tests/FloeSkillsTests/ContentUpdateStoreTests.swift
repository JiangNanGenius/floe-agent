// FloeSkillsTests — transactional content store: atomic batch commit,
// immutability, pinning, rollback and run snapshots. Fixtures are built
// in-process; no network and no shared state.

import Foundation
import Testing
import Crypto
import ZIPFoundation
@testable import FloeSkills

@Suite("Content update store")
struct ContentUpdateStoreTests {

    static func zip(_ files: [String: Data]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for name in files.keys.sorted() {
            let bytes = files[name] ?? Data()
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(bytes.count)
            ) { position, size in
                bytes.subdata(in: Int(position)..<min(Int(position) + size, bytes.count))
            }
        }
        return try #require(archive.data)
    }

    static func package(_ id: String, version: String) throws -> (entry: SignedContentEntry, zip: Data) {
        let files = [
            "content.json": Data(#"{"schemaVersion":1,"id":"\#(id)","version":"\#(version)"}"#.utf8),
            "index.md": Data("payload \(version)".utf8)
        ]
        let zip = try zip(files)
        let entry = SignedContentEntry(
            id: id,
            kind: .prompts,
            version: version,
            schemaVersion: 1,
            minimumAppVersion: "1.7.0",
            requiredCapabilities: [],
            dependencies: [],
            path: "content-hub/packages/\(id)/\(version)/\(id).zip",
            size: zip.count,
            sha256: SignedContentArchive.sha256Hex(zip),
            contentDigest: SignedContentArchive.canonicalDigest(files),
            releaseNotes: ["en": "Release", "zh-Hans": "发布"],
            sourceRevision: "",
            containsScripts: false
        )
        return (entry, zip)
    }

    static func makeStore() throws -> ContentUpdateStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-store-test-\(UUID().uuidString)", isDirectory: true)
        return try ContentUpdateStore(root: root)
    }

    static let acceptingValidator: @Sendable (SignedContentEntry, [String: Data]) throws -> Void = { _, files in
        guard files["content.json"] != nil else {
            throw ContentUpdateStoreError.staging("content.json missing")
        }
    }

    @Test("A batch commits only when every package stages, and a failure leaves no active change")
    func batchAtomicity() async throws {
        let store = try Self.makeStore()
        let good = try Self.package("floe.prompts.core", version: "1.0.0")
        var bad = try Self.package("floe.help.quickstart", version: "1.0.0")
        // Corrupt the second archive after its digest was computed.
        var tampered = bad.zip
        tampered[tampered.startIndex] ^= 0xFF
        bad = (bad.entry, tampered)

        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [
                    ContentUpdateStore.BatchItem(entry: good.entry, zip: good.zip),
                    ContentUpdateStore.BatchItem(entry: bad.entry, zip: bad.zip)
                ],
                appVersion: "1.7.0",
                allowedCapabilities: [],
                domainValidate: Self.acceptingValidator
            )
        }
        let state = await store.currentState()
        #expect(state.entries.isEmpty)
        #expect(state.revision == 0)
        // No staged version directory may survive a failed batch (empty id
        // parents are harmless, leaf version dirs are not).
        let versions = store.root.appendingPathComponent("versions", isDirectory: true)
        let leftovers = (try? FileManager.default.subpaths(atPath: versions.path)) ?? []
        #expect(!leftovers.contains { $0.split(separator: "/").count >= 2 })
    }

    @Test("Same version different bytes is immutable and downgrades are rejected")
    func immutableAndDowngrade() async throws {
        let store = try Self.makeStore()
        let first = try Self.package("floe.prompts.core", version: "1.1.0")
        _ = try await store.commit(
            [.init(entry: first.entry, zip: first.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )

        // Same version, different bytes.
        var rewriteFiles = ["content.json": Data(#"{"id":"floe.prompts.core","version":"1.1.0"}"#.utf8)]
        rewriteFiles["extra.md"] = Data("changed".utf8)
        let rewriteZip = try Self.zip(rewriteFiles)
        let rewrite = SignedContentEntry(
            id: "floe.prompts.core", kind: .prompts, version: "1.1.0", schemaVersion: 1,
            minimumAppVersion: "1.7.0", requiredCapabilities: [], dependencies: [],
            path: "content-hub/packages/floe.prompts.core/1.1.0/floe.prompts.core.zip",
            size: rewriteZip.count, sha256: SignedContentArchive.sha256Hex(rewriteZip),
            contentDigest: SignedContentArchive.canonicalDigest(rewriteFiles),
            releaseNotes: ["en": "x", "zh-Hans": "x"], sourceRevision: "", containsScripts: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [.init(entry: rewrite, zip: rewriteZip)],
                appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
            )
        }

        // Explicit downgrade.
        let older = try Self.package("floe.prompts.core", version: "1.0.0")
        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [.init(entry: older.entry, zip: older.zip)],
                appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
            )
        }
        let state = await store.currentState()
        #expect(state.entries["floe.prompts.core"]?.entry.version == "1.1.0")
    }

    @Test("A pin blocks automatic overwrite and rollback restores the real previous package")
    func pinAndRollback() async throws {
        let store = try Self.makeStore()
        let v1 = try Self.package("floe.prompts.core", version: "1.0.0")
        let v2 = try Self.package("floe.prompts.core", version: "1.1.0")
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        _ = try await store.commit(
            [.init(entry: v2.entry, zip: v2.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        _ = try await store.rollback(id: "floe.prompts.core", appVersion: "1.7.0")
        var state = await store.currentState()
        #expect(state.entries["floe.prompts.core"]?.entry.version == "1.0.0")
        #expect(state.pinned["floe.prompts.core"] == "1.0.0")
        // Rolled-back content is real, not synthesized.
        let files = try await store.files(id: "floe.prompts.core")
        #expect(String(data: files["index.md"] ?? Data(), encoding: .utf8) == "payload 1.0.0")

        // Pinned version refuses the newer release.
        let v3 = try Self.package("floe.prompts.core", version: "1.2.0")
        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [.init(entry: v3.entry, zip: v3.zip)],
                appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
            )
        }
        state = await store.currentState()
        #expect(state.entries["floe.prompts.core"]?.entry.version == "1.0.0")
    }

    @Test("A run snapshot keeps its original version after an update")
    func runSnapshotPinsVersion() async throws {
        let store = try Self.makeStore()
        let v1 = try Self.package("floe.prompts.core", version: "1.0.0")
        let v2 = try Self.package("floe.prompts.core", version: "1.1.0")
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        let runID = UUID()
        let snapshot = try await store.runSnapshot(
            runID: runID, builtInVersions: ["floe.providers.compatibility": "1.0.0"]
        )
        let oldDirectory = try #require(snapshot.directories["floe.prompts.core"])

        _ = try await store.commit(
            [.init(entry: v2.entry, zip: v2.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        let files = try await store.files(directory: oldDirectory)
        #expect(String(data: files["index.md"] ?? Data(), encoding: .utf8) == "payload 1.0.0")
        // Repeated snapshots for the same run stay frozen and keep the
        // built-in baseline metadata.
        let again = try await store.runSnapshot(runID: runID)
        #expect(again.directories["floe.prompts.core"] == oldDirectory)
        #expect(again.builtInVersions?["floe.providers.compatibility"] == "1.0.0")
        // Explicit release is the only lifecycle that drops a snapshot.
        _ = try await store.releaseRunSnapshot(runID: runID)
        #expect(await store.currentState().runSnapshots[runID.uuidString] == nil)
    }

    @Test("A version digest stays immutable after rollback (persistent ledger)")
    func ledgerBlocksRecycledVersion() async throws {
        let store = try Self.makeStore()
        let v1 = try Self.package("floe.prompts.core", version: "1.0.0")
        let v2 = try Self.package("floe.prompts.core", version: "1.1.0")
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        _ = try await store.commit(
            [.init(entry: v2.entry, zip: v2.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        _ = try await store.rollback(id: "floe.prompts.core", appVersion: "1.7.0")
        #expect(await store.currentState().entries["floe.prompts.core"]?.entry.version == "1.0.0")

        // A different payload claiming the rolled-back version must fail even
        // though the version is no longer active.
        let files = ["content.json": Data(#"{"id":"floe.prompts.core","version":"1.1.0"}"#.utf8),
                     "other.md": Data("different".utf8)]
        let rewriteZip = try Self.zip(files)
        let rewrite = SignedContentEntry(
            id: "floe.prompts.core", kind: .prompts, version: "1.1.0", schemaVersion: 1,
            minimumAppVersion: "1.7.0", requiredCapabilities: [], dependencies: [],
            path: "content-hub/packages/floe.prompts.core/1.1.0/floe.prompts.core.zip",
            size: rewriteZip.count, sha256: SignedContentArchive.sha256Hex(rewriteZip),
            contentDigest: SignedContentArchive.canonicalDigest(files),
            releaseNotes: ["en": "x", "zh-Hans": "x"], sourceRevision: "", containsScripts: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [.init(entry: rewrite, zip: rewriteZip)],
                appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
            )
        }
    }

    @Test("Reused staging directories still run the domain validator")
    func reusedDirectoryRevalidates() async throws {
        let store = try Self.makeStore()
        let v1 = try Self.package("floe.prompts.core", version: "1.0.0")
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        // Roll back to the same version would be a no-op, so force reuse by
        // deactivating and re-committing the identical version; staging must
        // still call the validator.
        _ = try await store.deactivate(id: "floe.prompts.core")
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()
        let counting: @Sendable (SignedContentEntry, [String: Data]) throws -> Void = { _, files in
            counter.increment()
            guard files["content.json"] != nil else {
                throw ContentUpdateStoreError.staging("content.json missing")
            }
        }
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: counting
        )
        #expect(counter.count == 1)
        #expect(await store.currentState().entries["floe.prompts.core"]?.entry.version == "1.0.0")
    }

    @Test("Rollback verifies app compatibility and stored directories cannot escape the root")
    func rollbackContractAndPathSafety() async throws {
        let store = try Self.makeStore()
        let v1 = try Self.package("floe.prompts.core", version: "1.0.0")
        let v2 = try Self.package("floe.prompts.core", version: "1.1.0")
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "2.0.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        _ = try await store.commit(
            [.init(entry: v2.entry, zip: v2.zip)],
            appVersion: "2.0.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        // The running app is older than the retained version's contract.
        await #expect(throws: (any Error).self) {
            _ = try await store.rollback(id: "floe.prompts.core", appVersion: "1.0.0")
        }
        // Manifest directory references are untrusted.
        #expect(throws: (any Error).self) {
            _ = try ContentUpdateStore.resolve(directory: "../escape", under: store.root)
        }
        #expect(throws: (any Error).self) {
            _ = try ContentUpdateStore.resolve(directory: "/absolute", under: store.root)
        }
    }

    @Test("A run snapshot freezes built-in bytes so an app upgrade cannot substitute them")
    func runSnapshotFreezesBuiltInPayload() async throws {
        let store = try Self.makeStore()
        let runID = UUID()
        let original = Data("catalog-v1".utf8)
        let providerID = "floe.providers.compatibility"
        let snapshot = try await store.runSnapshot(
            runID: runID,
            builtInVersions: [providerID: "1.1.0"],
            builtInPayloads: [providerID: original]
        )
        let directory = try #require(snapshot.builtInDirectories?[providerID])
        let files = try await store.files(directory: directory)
        #expect(files["payload"] == original)

        // Re-requesting with new bytes must return the frozen snapshot.
        let again = try await store.runSnapshot(
            runID: runID,
            builtInVersions: [providerID: "2.0.0"],
            builtInPayloads: [providerID: Data("catalog-v2".utf8)]
        )
        #expect(again.builtInDirectories?[providerID] == directory)
        #expect(try await store.files(directory: directory)["payload"] == original)
        #expect(again.builtInVersions?[providerID] == "1.1.0")
    }

    @Test("Prompt packages may only declare the three replaceable sections")
    func promptCodecRejectsFixedSections() throws {
        func entry(version: String) -> SignedContentEntry {
            SignedContentEntry(
                id: "floe.prompts.core", kind: .prompts, version: version, schemaVersion: 1,
                minimumAppVersion: "1.7.0", requiredCapabilities: [], dependencies: [],
                path: "content-hub/packages/floe.prompts.core/\(version)/floe.prompts.core.zip",
                size: 1, sha256: String(repeating: "a", count: 64),
                contentDigest: String(repeating: "b", count: 64),
                releaseNotes: ["en": "x", "zh-Hans": "x"], sourceRevision: "", containsScripts: false
            )
        }
        let forbidden = Data(#"{"schemaVersion":1,"id":"floe.prompts.core","version":"1.0.0","sections":[{"id":"floe.prompts.core.tool-discipline","title":{"en":"T","zh-Hans":"T"},"body":{"en":"body","zh-Hans":"body"}}]}"#.utf8)
        #expect(throws: (any Error).self) {
            try ContentPackageCodec(kind: .prompts).validate(
                entry: entry(version: "1.0.0"), files: ["content.json": forbidden]
            )
        }

        let allowed = Data(#"{"schemaVersion":1,"id":"floe.prompts.core","version":"1.0.0","sections":[{"id":"floe.prompts.core.method","title":{"en":"M","zh-Hans":"方法"},"body":{"en":"Act directly.","zh-Hans":"直接执行。"}},{"id":"floe.prompts.core.delivery","title":{"en":"D","zh-Hans":"交付"},"body":{"en":"Verify first.","zh-Hans":"先核对。"}}]}"#.utf8)
        let files = ["content.json": allowed]
        try ContentPackageCodec(kind: .prompts).validate(entry: entry(version: "1.0.0"), files: files)
        let overlay = try ContentPackageCodec.runtimePromptOverlay(in: files, locale: "zh-Hans")
        #expect(overlay.method == "直接执行。")
        #expect(overlay.delivery == "先核对。")
        #expect(overlay.communication == nil)
    }

    @Test("Missing dependencies and unsupported capabilities fail before staging")
    func dependencyAndCapabilityGates() async throws {
        let store = try Self.makeStore()
        let package = try Self.package("floe.prompts.core", version: "1.0.0")
        var dependent = package.entry
        dependent = SignedContentEntry(
            id: "floe.models.catalog-metadata", kind: .models, version: "1.0.0", schemaVersion: 1,
            minimumAppVersion: "1.7.0", requiredCapabilities: [], dependencies: ["floe.providers.compatibility"],
            path: "content-hub/packages/floe.models.catalog-metadata/1.0.0/floe.models.catalog-metadata.zip",
            size: package.entry.size, sha256: package.entry.sha256,
            contentDigest: package.entry.contentDigest,
            releaseNotes: package.entry.releaseNotes, sourceRevision: "", containsScripts: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [.init(entry: dependent, zip: package.zip)],
                appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
            )
        }

        let credential = SignedContentEntry(
            id: "floe.prompts.core", kind: .prompts, version: "1.0.0", schemaVersion: 1,
            minimumAppVersion: "1.7.0", requiredCapabilities: ["credentials"], dependencies: [],
            path: package.entry.path, size: package.entry.size, sha256: package.entry.sha256,
            contentDigest: package.entry.contentDigest,
            releaseNotes: package.entry.releaseNotes, sourceRevision: "", containsScripts: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await store.commit(
                [.init(entry: credential, zip: package.zip)],
                appVersion: "1.7.0", allowedCapabilities: ["credentials"], domainValidate: Self.acceptingValidator
            )
        }
        #expect(await store.currentState().entries.isEmpty)
    }

    @Test("Deactivation keeps bytes in history for rollback")
    func deactivationKeepsHistory() async throws {
        let store = try Self.makeStore()
        let v1 = try Self.package("floe.providers.compatibility", version: "1.0.0")
        _ = try await store.commit(
            [.init(entry: v1.entry, zip: v1.zip)],
            appVersion: "1.7.0", allowedCapabilities: [], domainValidate: Self.acceptingValidator
        )
        _ = try await store.deactivate(id: "floe.providers.compatibility")
        var state = await store.currentState()
        #expect(state.entries["floe.providers.compatibility"] == nil)
        #expect(state.history["floe.providers.compatibility"]?.first?.entry.version == "1.0.0")

        _ = try await store.rollback(id: "floe.providers.compatibility", appVersion: "1.7.0")
        state = await store.currentState()
        #expect(state.entries["floe.providers.compatibility"]?.entry.version == "1.0.0")
    }
}
