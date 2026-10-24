import Foundation
import Testing
import ZIPFoundation
@testable import FloeSkills

@Suite("Content update actions")
struct ContentUpdateActionTests: Sendable {
    private let appVersion = "1.7.0"
    private let id = "floe.help.quickstart"
    private static let validator: @Sendable (SignedContentEntry, [String: Data]) throws -> Void = { _, files in
        guard files["content.json"] != nil else { throw SignedContentFailure.archive }
    }

    private func entry(_ version: String, files: [String: Data], minimum: String = "1.7.0", dependencies: [String] = [], size: Int = 0, zipHash: String = "") -> SignedContentEntry {
        .init(id: id, kind: .help, version: version, schemaVersion: 1,
              minimumAppVersion: minimum, requiredCapabilities: [], dependencies: dependencies,
              path: "content-hub/packages/\(id)/\(version)/\(id).zip", size: size, sha256: zipHash,
              contentDigest: SignedContentArchive.canonicalDigest(files), releaseNotes: [:], sourceRevision: "", containsScripts: false)
    }

    private func payload(_ version: String) -> [String: Data] {
        ["content.json": Data("{\"id\":\"\(id)\",\"version\":\"\(version)\"}".utf8)]
    }

    private func archive(_ files: [String: Data]) throws -> Data {
        let zip = try Archive(data: Data(), accessMode: .create)
        for path in files.keys.sorted() {
            let bytes = files[path]!
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<min(Int(position) + size, bytes.count))
            }
        }
        return try #require(zip.data)
    }

    private func package(_ version: String) throws -> ContentUpdateStore.BatchItem {
        let files = payload(version)
        let zip = try archive(files)
        return .init(entry: entry(version, files: files, size: zip.count, zipHash: SignedContentArchive.sha256Hex(zip)), zip: zip)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-actions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ files: [String: Data], directory: String, root: URL) throws {
        let folder = root.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in files { try data.write(to: folder.appendingPathComponent(path)) }
    }

    private func stored(_ version: String, minimum: String = "1.7.0", dependencies: [String] = []) -> ContentUpdateState.StoredEntry {
        .init(entry: entry(version, files: payload(version), minimum: minimum, dependencies: dependencies),
              directory: "versions/\(id)/\(version)", installedAt: Date(timeIntervalSince1970: 0))
    }

    private func seed(_ state: ContentUpdateState, root: URL, tamperedVersions: Set<String> = []) throws -> ContentUpdateStore {
        for stored in Array(state.entries.values) + state.history.values.flatMap({ $0 }) {
            let bytes = tamperedVersions.contains(stored.entry.version)
                ? ["content.json": Data("tampered".utf8)] : payload(stored.entry.version)
            try write(bytes, directory: stored.directory, root: root)
        }
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("active.json"))
        return try ContentUpdateStore(root: root)
    }

    @Test("A bundle-only baseline and a first downloaded version have no invented rollback")
    func noInventedHistory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try ContentUpdateStore(root: root)
        let bundled = await empty.actionSnapshot(appVersion: appVersion, builtInBaselines: [id: "1.0.0"], domainValidate: Self.validator)
        #expect(bundled.rollbackTargets.isEmpty)
        var state = ContentUpdateState()
        state.entries[id] = stored("2.0.0")
        let store = try seed(state, root: root)
        let firstInstall = await store.actionSnapshot(appVersion: appVersion, builtInBaselines: [id: "1.0.0"], domainValidate: Self.validator)
        #expect(firstInstall.rollbackTargets.isEmpty)
    }

    @Test("Only a real older readable package becomes the rollback target")
    func realOlderHistory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ContentUpdateState()
        state.entries[id] = stored("3.0.0")
        state.history[id] = [stored("2.0.0"), stored("1.0.0")]
        let store = try seed(state, root: root, tamperedVersions: ["2.0.0"])
        let actions = await store.actionSnapshot(appVersion: appVersion, domainValidate: Self.validator)
        #expect(actions.rollbackTargets[id]?.entry.version == "1.0.0")
        #expect(actions.state.history[id]?.count == 2)
        let restored = try await store.rollback(id: id, appVersion: appVersion, toVersion: actions.rollbackTargets[id]?.entry.version)
        #expect(restored.entries[id]?.entry.version == "1.0.0")
        #expect(try await store.files(id: id) == payload("1.0.0"))
    }

    @Test("Incompatible, missing-dependency and ineffective below-bundle history are hidden")
    func unusableHistory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ContentUpdateState()
        state.entries[id] = stored("4.0.0")
        state.history[id] = [stored("3.0.0", minimum: "9.0.0"), stored("2.0.0", dependencies: ["missing"]), stored("1.0.0")]
        let store = try seed(state, root: root)
        let actions = await store.actionSnapshot(appVersion: appVersion, builtInBaselines: [id: "2.0.0"], domainValidate: Self.validator)
        #expect(actions.rollbackTargets[id] == nil)
    }

    @Test("A corrupt or currently unreadable domain is never advertised as usable")
    func rejectedDomain() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ContentUpdateState()
        state.entries[id] = stored("2.0.0")
        state.history[id] = [stored("1.0.0")]
        let store = try seed(state, root: root)
        let actions = await store.actionSnapshot(appVersion: appVersion) { _, _ in throw SignedContentFailure.incompatible }
        #expect(actions.rollbackTargets[id] == nil)
    }

    @Test("Higher retained versions protect automatic rollback but never become a rollback button")
    func higherHistoryIsNotRollback() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ContentUpdateState()
        state.entries[id] = stored("1.0.0")
        state.history[id] = [stored("2.0.0")]
        let store = try seed(state, root: root)
        let actions = await store.actionSnapshot(appVersion: appVersion, domainValidate: Self.validator)
        #expect(actions.rollbackTargets[id] == nil)
        #expect(!ContentUpdateActionPolicy.automaticUpdateAllowed(id: id, version: "2.0.0", state: actions.state))
        #expect(ContentUpdateActionPolicy.automaticUpdateAllowed(id: id, version: "3.0.0", state: actions.state))
    }

    @Test("Removing old pins persists without erasing packages, history, ledger or run snapshots")
    func legacyPinMigration() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ContentUpdateState()
        state.entries[id] = stored("2.0.0")
        state.history[id] = [stored("1.0.0")]
        state.pinned[id] = "2.0.0"
        state.pinned["old-removed-entry"] = "1.0.0"
        state.runSnapshots["run"] = .init(directories: [id: stored("1.0.0").directory], createdAt: Date(timeIntervalSince1970: 0))
        let store = try seed(state, root: root)
        let before = await store.currentState()
        let after = try await store.removeVersionPins()
        #expect(after.pinned.isEmpty)
        #expect(after.entries == before.entries)
        #expect(after.history == before.history)
        #expect(after.ledger == before.ledger)
        #expect(after.runSnapshots == before.runSnapshots)
        #expect(try await store.removeVersionPins().revision == after.revision)
        let reloaded = try ContentUpdateStore(root: root)
        #expect(await reloaded.currentState().pinned.isEmpty)
    }

    @Test("Real 2-to-1 rollback blocks automatic 2, allows explicit 2, and allows automatic 3")
    func rollbackAutomaticAndExplicitInstall() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentUpdateStore(root: root)
        let v1 = try package("1.0.0"), v2 = try package("2.0.0"), v3 = try package("3.0.0")
        _ = try await store.commit([v1], appVersion: appVersion, allowedCapabilities: [], domainValidate: Self.validator)
        _ = try await store.commit([v2], appVersion: appVersion, allowedCapabilities: [], domainValidate: Self.validator)
        _ = try await store.rollback(id: id, appVersion: appVersion)
        let restored = try await store.removeVersionPins()
        #expect(restored.entries[id]?.entry.version == "1.0.0")
        #expect(restored.pinned.isEmpty)
        await #expect(throws: ContentUpdateStoreError.self) {
            _ = try await store.commitAutomatically([v2], appVersion: appVersion, allowedCapabilities: [], domainValidate: Self.validator)
        }
        #expect(await store.currentState().entries[id]?.entry.version == "1.0.0")
        let explicit = try await store.commit([v2], appVersion: appVersion, allowedCapabilities: [], domainValidate: Self.validator)
        #expect(explicit.entries[id]?.entry.version == "2.0.0")
        _ = try await store.rollback(id: id, appVersion: appVersion)
        _ = try await store.removeVersionPins()
        let updated = try await store.commitAutomatically([v3], appVersion: appVersion, allowedCapabilities: [], domainValidate: Self.validator)
        #expect(updated.entries[id]?.entry.version == "3.0.0")
        #expect(try await store.files(id: id) == payload("3.0.0"))
    }
}
