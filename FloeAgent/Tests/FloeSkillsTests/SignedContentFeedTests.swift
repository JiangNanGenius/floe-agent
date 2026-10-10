// FloeSkillsTests — shared signed content update foundation.
//
// Covers the Ed25519 trust gate, structural feed validation, strict version
// and immutability policy, bounded archive extraction, and the atomic install
// transaction. Fixtures are generated in-process; no network.

import Foundation
import Testing
import Crypto
import ZIPFoundation
@testable import FloeSkills

@Suite("Signed content update foundation")
struct SignedContentFeedTests {

    // MARK: - Fixtures

    struct TestKey {
        let keyID: String
        let privateKey: Curve25519.Signing.PrivateKey
        var trusted: [String: Data] { [keyID: privateKey.publicKey.rawRepresentation] }
        var publicKey: Data { privateKey.publicKey.rawRepresentation }
    }

    static func makeKey(_ keyID: String = "test-key") -> TestKey {
        TestKey(keyID: keyID, privateKey: Curve25519.Signing.PrivateKey())
    }

    static func entry(
        id: String = "floe.prompts.core",
        kind: String = "prompts",
        version: String = "1.1.0",
        minimumAppVersion: String = "1.0.0",
        dependencies: [String] = [],
        path: String? = nil,
        size: Int = 100,
        sha256: String = String(repeating: "a", count: 64),
        contentDigest: String = String(repeating: "b", count: 64),
        notes: [String: String] = ["zh-Hans": "更新", "en": "Update"],
        sourceRevision: String = String(repeating: "c", count: 40),
        containsScripts: Bool = false
    ) -> [String: Any] {
        [
            "id": id,
            "kind": kind,
            "version": version,
            "schemaVersion": 1,
            "minimumAppVersion": minimumAppVersion,
            "requiredCapabilities": [],
            "dependencies": dependencies,
            "path": path ?? "content-hub/packages/\(id)/\(version)/\(id).zip",
            "size": size,
            "sha256": sha256,
            "contentDigest": contentDigest,
            "releaseNotes": notes,
            "sourceRevision": sourceRevision,
            "containsScripts": containsScripts
        ]
    }

    static func feedJSON(
        entries: [[String: Any]],
        publisher: String = OfficialContentHub.publisher,
        schemaVersion: Int = 1
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "publisher": publisher,
            "generatedAt": "2026-10-09T00:00:00Z",
            "entries": entries
        ], options: [.sortedKeys])
    }

    static func signedFeed(
        _ entries: [[String: Any]],
        key: TestKey
    ) throws -> (bytes: Data, signature: Data) {
        let bytes = try feedJSON(entries: entries)
        let proof = try key.privateKey.signature(for: bytes)
        let envelope: [String: String] = [
            "keyID": key.keyID,
            "signature": proof.base64EncodedString()
        ]
        let signature = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return (bytes, signature)
    }

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

    // MARK: - Version

    @Test("Strict three-part versions accept only the published shape")
    func strictVersions() throws {
        #expect(try SignedContentVersion("1.2.3") < SignedContentVersion("1.10.0"))
        #expect(try SignedContentVersion("2.0.0") > SignedContentVersion("1.99.99"))
        for invalid in ["1.2", "1.2.3.4", "01.2.3", "1.02.3", "v1.2.3", "1.2.3-beta", "", "1..2", "a.b.c"] {
            #expect(throws: SignedContentFailure.feed) {
                try SignedContentVersion(invalid)
            }
        }
    }

    // MARK: - Signature and structure

    @Test("A correctly signed feed verifies and preserves entry identity")
    func verifiesSignedFeed() throws {
        let key = Self.makeKey()
        let (bytes, signature) = try Self.signedFeed(
            [Self.entry(version: "1.1.0")], key: key
        )
        let feed = try SignedContentFeedVerifier.verify(
            feed: bytes, signature: signature, trustedKeys: key.trusted
        )
        #expect(feed.schemaVersion == 1)
        #expect(feed.entries.count == 1)
        #expect(feed.entries[0].id == "floe.prompts.core")
        #expect(feed.entries[0].kind == .prompts)
    }

    @Test("Tampered bytes, untrusted keys and unknown kinds fail closed")
    func signatureAndKindBoundaries() throws {
        let key = Self.makeKey()
        let (bytes, signature) = try Self.signedFeed([Self.entry()], key: key)

        #expect(throws: SignedContentFailure.signature) {
            try SignedContentFeedVerifier.verify(
                feed: bytes + Data(" ".utf8), signature: signature, trustedKeys: key.trusted
            )
        }
        #expect(throws: SignedContentFailure.signature) {
            try SignedContentFeedVerifier.verify(
                feed: bytes, signature: signature, trustedKeys: [:]
            )
        }
        let otherKey = Self.makeKey("other-key")
        #expect(throws: SignedContentFailure.signature) {
            try SignedContentFeedVerifier.verify(
                feed: bytes, signature: signature, trustedKeys: otherKey.trusted
            )
        }
        // A domain that does not understand this kind must reject the feed.
        #expect(throws: SignedContentFailure.feed) {
            try SignedContentFeedVerifier.verify(
                feed: bytes, signature: signature, trustedKeys: key.trusted,
                allowedKinds: [.help]
            )
        }
        // Unknown kind raw values do not decode.
        let (unknown, unknownSig) = try Self.signedFeed(
            [Self.entry(kind: "native-code")], key: key
        )
        #expect(throws: SignedContentFailure.feed) {
            try SignedContentFeedVerifier.verify(
                feed: unknown, signature: unknownSig, trustedKeys: key.trusted
            )
        }
    }

    @Test("Structurally invalid entries are rejected entry by entry")
    func invalidEntries() throws {
        let key = Self.makeKey()
        func rejects(_ entries: [[String: Any]]) throws {
            let (bytes, signature) = try Self.signedFeed(entries, key: key)
            #expect(throws: SignedContentFailure.feed) {
                try SignedContentFeedVerifier.verify(
                    feed: bytes, signature: signature, trustedKeys: key.trusted
                )
            }
        }
        // Unsigned/foreign publisher.
        let (foreignBytes, foreignSig) = try Self.signedFeed([Self.entry()], key: key)
        #expect(throws: SignedContentFailure.feed) {
            try SignedContentFeedVerifier.verify(
                feed: foreignBytes, signature: foreignSig, trustedKeys: key.trusted,
                publisher: "SomeoneElse"
            )
        }
        // Traversal path instead of the exact package path.
        try rejects([Self.entry(path: "content-hub/packages/../../etc/passwd")])
        // Wrong file name for the same id/version.
        try rejects([Self.entry(path: "content-hub/packages/floe.prompts.core/1.1.0/other.zip")])
        // Digest shapes.
        try rejects([Self.entry(sha256: String(repeating: "z", count: 64))])
        try rejects([Self.entry(contentDigest: "abc")])
        // Bilingual release notes are mandatory.
        try rejects([Self.entry(notes: ["en": "Update"])])
        // Duplicate identities.
        try rejects([Self.entry(), Self.entry()])
        // Self-dependency.
        try rejects([Self.entry(dependencies: ["floe.prompts.core"])])
        // Version drift.
        try rejects([Self.entry(version: "1.1")])
        // Zero size.
        try rejects([Self.entry(size: 0)])
    }

    // MARK: - Update policy

    @Test("Update policy is default-highest-compatible with immutability and pin rules")
    func updatePolicy() throws {
        let key = Self.makeKey()
        let (bytes, signature) = try Self.signedFeed([Self.entry(version: "1.2.0")], key: key)
        let feed = try SignedContentFeedVerifier.verify(
            feed: bytes, signature: signature, trustedKeys: key.trusted
        )
        let entry = feed.entries[0]

        // Newer remote version activates.
        #expect(try ContentVersionPolicy.decide(
            entry: entry, installedVersion: "1.1.0",
            installedDigest: String(repeating: "9", count: 64),
            appVersion: "1.7.0", availableDependencyIDs: []
        ).isUpdate)

        // Same version with the same digest is up to date.
        if case .upToDate(let version) = try ContentVersionPolicy.decide(
            entry: entry, installedVersion: "1.2.0",
            installedDigest: entry.contentDigest, appVersion: "1.7.0"
        ) {
            #expect(version == "1.2.0")
        } else {
            Issue.record("expected upToDate")
        }

        // Same version with different bytes is immutable, never overwritten.
        #expect(try ContentVersionPolicy.decide(
            entry: entry, installedVersion: "1.2.0",
            installedDigest: String(repeating: "9", count: 64),
            appVersion: "1.7.0"
        ) == .blocked(reason: .sameVersionDifferentContent, version: "1.2.0"))

        // Remote downgrade is rejected.
        #expect(try ContentVersionPolicy.decide(
            entry: entry, installedVersion: "2.0.0", installedDigest: nil,
            appVersion: "1.7.0"
        ) == .blocked(reason: .downgrade, version: "1.2.0"))

        // Pin/rollback wins over a newer remote.
        #expect(try ContentVersionPolicy.decide(
            entry: entry, installedVersion: "1.1.0",
            installedDigest: String(repeating: "9", count: 64),
            appVersion: "1.7.0", pinnedVersion: "1.1.0"
        ) == .blocked(reason: .pinned, version: "1.2.0"))

        // Incompatible app retains the old install, never activates.
        #expect(try ContentVersionPolicy.decide(
            entry: entry, installedVersion: nil, installedDigest: nil,
            appVersion: "0.9.0"
        ) == .blocked(reason: .incompatibleApp, version: "1.2.0"))

        // Missing dependency blocks the dependent without half-installing.
        let (depBytes, depSig) = try Self.signedFeed(
            [Self.entry(id: "floe.models.meta", kind: "models", version: "1.0.0",
                        dependencies: ["floe.providers.compat"])],
            key: key
        )
        let depFeed = try SignedContentFeedVerifier.verify(
            feed: depBytes, signature: depSig, trustedKeys: key.trusted
        )
        #expect(try ContentVersionPolicy.decide(
            entry: depFeed.entries[0], installedVersion: nil, installedDigest: nil,
            appVersion: "1.7.0", availableDependencyIDs: []
        ) == .blocked(reason: .missingDependency, version: "1.0.0"))
        #expect(try ContentVersionPolicy.decide(
            entry: depFeed.entries[0], installedVersion: nil, installedDigest: nil,
            appVersion: "1.7.0", availableDependencyIDs: ["floe.providers.compat"]
        ).isUpdate)
    }

    @Test("App-bundled copies only take over strictly newer or identical installs")
    func bundledTakeover() {
        #expect(ContentVersionPolicy.bundledTakesOver(
            installedVersion: "1.0.0", installedDigest: "a",
            bundledVersion: "1.1.0", bundledDigest: "b"
        ))
        #expect(ContentVersionPolicy.bundledTakesOver(
            installedVersion: "1.0.0", installedDigest: "a",
            bundledVersion: "1.0.0", bundledDigest: "a"
        ))
        #expect(!ContentVersionPolicy.bundledTakesOver(
            installedVersion: "1.0.0", installedDigest: "a",
            bundledVersion: "1.0.0", bundledDigest: "b"
        ))
        #expect(!ContentVersionPolicy.bundledTakesOver(
            installedVersion: "2.0.0", installedDigest: "a",
            bundledVersion: "1.9.0", bundledDigest: "b"
        ))
    }

    // MARK: - Archive bounds

    @Test("Archive extraction rejects traversal, collisions, dotfiles and oversize payloads")
    func archiveBounds() throws {
        let good = try Self.zip(["SKILL.md": Data("hello".utf8)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try SignedContentArchive.extract(good, at: root)
        #expect(files["SKILL.md"] == Data("hello".utf8))

        for names in [["../escape"], ["/absolute"], ["a/../escape"], [".hidden"], ["safe", "SAFE"]] {
            var payload: [String: Data] = [:]
            for name in names { payload[name] = Data("x".utf8) }
            let zip = try Self.zip(payload)
            let badRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            #expect(throws: SignedContentFailure.archive) {
                try SignedContentArchive.extract(zip, at: badRoot)
            }
            #expect(!FileManager.default.fileExists(atPath: badRoot.path))
        }

        // Top-level allow-list.
        let hidden = try Self.zip(["evil/payload": Data("x".utf8)])
        let allowRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: SignedContentFailure.archive) {
            try SignedContentArchive.extract(hidden, at: allowRoot, allowedTopLevel: ["SKILL.md"])
        }

        // Entry and byte limits.
        let twoFiles = try Self.zip(["a": Data("a".utf8), "b": Data("b".utf8)])
        let smallRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: SignedContentFailure.archive) {
            try SignedContentArchive.extract(
                twoFiles, at: smallRoot,
                limits: SignedContentArchiveLimits(maximumEntries: 1, maximumFileBytes: 1_024, maximumTotalBytes: 2_048)
            )
        }
    }

    @Test("Canonical digest is order-independent and content-sensitive")
    func canonicalDigest() {
        let a = SignedContentArchive.canonicalDigest(["a": Data("1".utf8), "b": Data("2".utf8)])
        let b = SignedContentArchive.canonicalDigest(["b": Data("2".utf8), "a": Data("1".utf8)])
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a != SignedContentArchive.canonicalDigest(["a": Data("1".utf8), "b": Data("3".utf8)]))
        #expect(a != SignedContentArchive.canonicalDigest(["a": Data("1".utf8)]))
    }

    // MARK: - Install transaction

    @Test("Staging verifies signed size/hash/digest and domain validation before install")
    func staging() throws {
        let key = Self.makeKey()
        let payload: [String: Data] = [
            "content.json": Data(#"{"schemaVersion":1,"id":"floe.prompts.core","version":"1.1.0"}"#.utf8),
            "index.md": Data("hello".utf8)
        ]
        let zip = try Self.zip(payload)
        let digest = SignedContentArchive.canonicalDigest(payload)
        let (bytes, signature) = try Self.signedFeed([
            Self.entry(version: "1.1.0", size: zip.count, sha256: SignedContentArchive.sha256Hex(zip),
                       contentDigest: digest)
        ], key: key)
        let feed = try SignedContentFeedVerifier.verify(
            feed: bytes, signature: signature, trustedKeys: key.trusted
        )
        let entry = feed.entries[0]

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var domainValidated = false
        let staged = try SignedContentInstaller.stage(
            zip: zip, entry: entry, at: root,
            domainValidate: { validatedEntry, files in
                domainValidated = validatedEntry.id == entry.id && files["content.json"] != nil
            }
        )
        #expect(domainValidated)
        #expect(staged.canonicalSHA256 == digest)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.md").path))

        // Tampered bytes never reach the domain validator.
        let tamperedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var tampered = zip
        tampered[tampered.startIndex] ^= 0xFF
        #expect(throws: (any Error).self) {
            try SignedContentInstaller.stage(zip: tampered, entry: entry, at: tamperedRoot) { _, _ in
                Issue.record("domain validation must not run for a rejected archive")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: tamperedRoot.path))

        // Wrong content digest is an immutability failure, not a silent pass.
        let (mismatchBytes, mismatchSig) = try Self.signedFeed([
            Self.entry(version: "1.1.0", size: zip.count, sha256: SignedContentArchive.sha256Hex(zip),
                       contentDigest: String(repeating: "0", count: 64))
        ], key: key)
        let mismatchFeed = try SignedContentFeedVerifier.verify(
            feed: mismatchBytes, signature: mismatchSig, trustedKeys: key.trusted
        )
        let mismatchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: SignedContentFailure.immutableVersion) {
            try SignedContentInstaller.stage(zip: zip, entry: mismatchFeed.entries[0], at: mismatchRoot)
        }
    }

    @Test("Activation replaces atomically and restores the previous install on failure")
    func activation() throws {
        let fileManager = FileManager.default
        let key = Self.makeKey()
        let payload = ["content.json": Data(#"{"id":"x","version":"2.0.0"}"#.utf8)]
        let zip = try Self.zip(payload)
        let digest = SignedContentArchive.canonicalDigest(payload)
        let (bytes, signature) = try Self.signedFeed([
            Self.entry(id: "floe.help.quickstart", kind: "help", version: "2.0.0",
                       size: zip.count, sha256: SignedContentArchive.sha256Hex(zip),
                       contentDigest: digest)
        ], key: key)
        let feed = try SignedContentFeedVerifier.verify(
            feed: bytes, signature: signature, trustedKeys: key.trusted
        )
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: base) }
        let destination = base.appendingPathComponent("active/help")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.txt"))

        let root = base.appendingPathComponent("staging/help")
        let staged = try SignedContentInstaller.stage(zip: zip, entry: feed.entries[0], at: root)
        try SignedContentInstaller.activate(staged, at: destination)
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("content.json").path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("old.txt").path))

        // A failing post-swap verification restores the previous install.
        let root2 = base.appendingPathComponent("staging2/help")
        let staged2 = try SignedContentInstaller.stage(zip: zip, entry: feed.entries[0], at: root2)
        #expect(throws: SignedContentFailure.feed) {
            try SignedContentInstaller.activate(staged2, at: destination) { _ in
                throw SignedContentFailure.feed
            }
        }
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("content.json").path))
    }
}
