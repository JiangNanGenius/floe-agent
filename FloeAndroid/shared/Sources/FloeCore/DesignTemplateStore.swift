import Foundation

// FloeCore — Design template library (safe persistence).
//
// Three template origins, one honest model:
//
// - `.builtIn`: read-only defaults compiled into the app; never written here.
// - `.user`: stored here under
//   `Application Support/FloeAgent/DesignTemplates/<id>/`; every version is an
//   immutable directory (`versions/<version>/manifest.json + payload.bin`),
//   and `current.json` is a small pointer swapped atomically. User templates
//   are independent of the app bundle and survive upgrades; rollback re-points
//   at a retained immutable version, so payload bytes always match the
//   manifest hash.
// - `.signedContent`: published through the existing signed content-update
//   service; the app layer maps installed signed entries (ContentUpdateStore,
//   whose digest-addressed machinery already provides version/hash/license)
//   onto `DesignTemplateManifest` read-only.
//
// Persistence rules (from critical review):
// - ids/versions are strictly validated before they ever reach a path; "..",
//   separators and empty names are rejected, and resolved paths must stay
//   inside the root after symlink resolution.
// - commits are atomic (staging file + `replaceItemAt`), never
//   remove-then-move; payload is written before the pointer changes so an
//   interrupted commit keeps the previous version current.
// - a missing or hash-mismatched payload is an error, never a silent empty;
//   corrupt or newer-schema state is never overwritten by a save.

public enum DesignTemplateStoreError: Error, Equatable {
    case invalidID(String)
    case invalidVersion(String)
    case templateNotFound(String)
    case versionNotFound(String, String)
    case newerSchema(String)
    case corrupt(String)
    case payloadMissing(String)
    case payloadHashMismatch(String)
    case versionCollision(String, String)
}

public struct DesignTemplateStore: Sendable {
    /// A resolved template: manifest + payload with a verified hash.
    public struct Record: Sendable, Equatable {
        public let manifest: DesignTemplateManifest
        public let payload: Data
        /// Retained previous versions (immutable), newest first.
        public let history: [DesignTemplateManifest]

        public init(manifest: DesignTemplateManifest, payload: Data, history: [DesignTemplateManifest] = []) {
            self.manifest = manifest
            self.payload = payload
            self.history = history
        }
    }

    public let root: URL
    /// Built-in defaults compiled with the app (read-only).
    public let builtIn: [DesignTemplateManifest]

    public init(root: URL, builtIn: [DesignTemplateManifest] = []) {
        self.root = root.standardizedFileURL
        self.builtIn = builtIn
    }

    public static func defaultRoot() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("DesignTemplates", isDirectory: true)
    }

    static let currentSchemaVersion = 1
    static let maxRetainedVersions = 5
    static let allowedID = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))

    // MARK: - Validation

    static func validateID(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 64,
              id != ".", id != "..",
              !id.contains("/"),
              id.unicodeScalars.allSatisfy(allowedID.contains) else {
            throw DesignTemplateStoreError.invalidID(id)
        }
        return id
    }

    static func validateVersion(_ version: String) throws -> String {
        guard !version.isEmpty, version.count <= 32,
              version != ".", version != "..",
              !version.contains("/"),
              version.unicodeScalars.allSatisfy(allowedID.contains) else {
            throw DesignTemplateStoreError.invalidVersion(version)
        }
        return version
    }

    /// Canonical directory for a validated id, guaranteed inside the root
    /// after symlink resolution.
    func templateDirectory(id: String) throws -> URL {
        let valid = try Self.validateID(id)
        let base = root.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent(valid, isDirectory: true)
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/") else {
            throw DesignTemplateStoreError.invalidID(id)
        }
        return directory
    }

    // MARK: - Read

    public func userTemplates() -> [Record] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var records: [Record] = []
        for id in ids.sorted() {
            if let record = try? loadUser(id: id) { records.append(record) }
        }
        return records
    }

    public func loadUser(id: String) throws -> Record {
        let directory = try templateDirectory(id: id)
        let pointerURL = directory.appendingPathComponent("current.json")
        guard let pointerData = try? Data(contentsOf: pointerURL) else {
            throw DesignTemplateStoreError.templateNotFound(id)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pointer: Pointer
        do {
            pointer = try decoder.decode(Pointer.self, from: pointerData)
        } catch {
            throw DesignTemplateStoreError.corrupt(id)
        }
        guard pointer.schemaVersion <= Self.currentSchemaVersion else {
            // Newer-schema state is never read partially and never overwritten.
            throw DesignTemplateStoreError.newerSchema(id)
        }
        let current = try loadVersion(id: id, version: pointer.version)
        var history: [DesignTemplateManifest] = []
        for version in pointer.history {
            if let loaded = try? loadVersion(id: id, version: version) {
                history.append(loaded.manifest)
            }
        }
        return Record(manifest: current.manifest, payload: current.payload, history: history)
    }

    private func loadVersion(id: String, version: String) throws -> (manifest: DesignTemplateManifest, payload: Data) {
        let validVersion = try Self.validateVersion(version)
        let directory = try templateDirectory(id: id)
        let versionDirectory = directory
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(validVersion, isDirectory: true)
        let manifestURL = versionDirectory.appendingPathComponent("manifest.json")
        let payloadURL = versionDirectory.appendingPathComponent("payload.bin")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw DesignTemplateStoreError.versionNotFound(id, version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: DesignTemplateManifest
        do {
            manifest = try decoder.decode(DesignTemplateManifest.self, from: manifestData)
        } catch {
            throw DesignTemplateStoreError.corrupt(id)
        }
        // Payload must exist and match the manifest hash; anything else is an
        // error rather than a silent empty template.
        guard let payload = try? Data(contentsOf: payloadURL), !payload.isEmpty else {
            throw DesignTemplateStoreError.payloadMissing(id)
        }
        let digest = FloeDigest.sha256Hex(payload)
        guard digest == manifest.contentSHA256.lowercased() else {
            throw DesignTemplateStoreError.payloadHashMismatch(id)
        }
        return (manifest, payload)
    }

    // MARK: - Write

    /// Saves a new or updated user template. The previous version stays
    /// immutable in `versions/`, so the update can be rolled back. Commits are
    /// atomic; an interrupted save leaves the previous version current.
    @discardableResult
    public func saveUser(manifest input: DesignTemplateManifest, payload: Data) throws -> DesignTemplateManifest {
        var manifest = input
        manifest.contentSHA256 = FloeDigest.sha256Hex(payload)
        // Callers choose the origin (user / signedContent); the store never
        // silently relabels signed records as user templates.
        if manifest.origin == .builtIn { manifest.origin = .user }
        _ = try Self.validateID(manifest.id)
        _ = try Self.validateVersion(manifest.version)
        guard !payload.isEmpty else { throw DesignTemplateStoreError.payloadMissing(manifest.id) }

        let directory = try templateDirectory(id: manifest.id)
        let versionsDirectory = directory.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)

        let previous: Record?
        do {
            previous = try loadUser(id: manifest.id)
        } catch DesignTemplateStoreError.newerSchema {
            // Never overwrite state this build cannot read.
            throw DesignTemplateStoreError.newerSchema(manifest.id)
        } catch DesignTemplateStoreError.corrupt {
            throw DesignTemplateStoreError.corrupt(manifest.id)
        } catch {
            previous = nil
        }

        // Write the immutable version directory first (idempotent per
        // content). A same-version directory holding different content is a
        // collision, never a merge.
        let versionDirectory = versionsDirectory.appendingPathComponent(manifest.version, isDirectory: true)
        let manifestURL = versionDirectory.appendingPathComponent("manifest.json")
        let payloadURL = versionDirectory.appendingPathComponent("payload.bin")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let existing = try Data(contentsOf: manifestURL)
            let existingPayload = (try? Data(contentsOf: payloadURL)) ?? Data()
            guard existing == manifestData, FloeDigest.sha256Hex(existingPayload) == manifest.contentSHA256 else {
                throw DesignTemplateStoreError.versionCollision(manifest.id, manifest.version)
            }
            // Identical re-save: only the pointer/history may need an update.
        } else {
            try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            // Stage payload and manifest, then publish both with renames.
            let staging = versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try payload.write(to: staging.appendingPathComponent("payload.bin"), options: .atomic)
            try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            let stagedDigest = try FloeDigest.sha256Hex(ofFileAt: staging.appendingPathComponent("payload.bin"))
            guard stagedDigest == manifest.contentSHA256 else {
                try? FileManager.default.removeItem(at: staging)
                throw DesignTemplateStoreError.payloadHashMismatch(manifest.id)
            }
            try FileManager.default.moveItem(
                at: staging.appendingPathComponent("payload.bin"),
                to: payloadURL
            )
            try FileManager.default.moveItem(
                at: staging.appendingPathComponent("manifest.json"),
                to: manifestURL
            )
            try? FileManager.default.removeItem(at: staging)
        }

        // Swap the pointer atomically. Payload+manifest for the new version
        // are already durable, so any interruption here keeps the old current.
        var history: [String] = []
        if let previous {
            if previous.manifest.version != manifest.version {
                history = [previous.manifest.version]
                    + previous.history.filter { $0.version != previous.manifest.version && $0.version != manifest.version }
                        .map(\.version)
            } else {
                history = previous.history.map(\.version)
            }
        }
        let pointer = Pointer(schemaVersion: Self.currentSchemaVersion, id: manifest.id, version: manifest.version, history: Array(history.prefix(Self.maxRetainedVersions)))
        let pointerData = try encoder.encode(pointer)
        let pointerURL = directory.appendingPathComponent("current.json")
        let stagingPointer = directory.appendingPathComponent(".current-\(UUID().uuidString.lowercased()).staging")
        try pointerData.write(to: stagingPointer, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(pointerURL, withItemAt: stagingPointer)
        } catch {
            try? FileManager.default.removeItem(at: stagingPointer)
            throw error
        }
        return manifest
    }

    /// Rolls a user template back to a retained immutable version; the current
    /// version is kept in history so the rollback is reversible.
    @discardableResult
    public func rollbackUser(id: String, toVersion version: String) throws -> DesignTemplateManifest {
        _ = try Self.validateVersion(version)
        let record = try loadUser(id: id)
        guard record.history.contains(where: { $0.version == version }) || record.manifest.version == version else {
            throw DesignTemplateStoreError.versionNotFound(id, version)
        }
        var restored = try loadVersion(id: id, version: version).manifest
        restored.rollbackVersion = record.manifest.version
        restored.rollbackContentSHA256 = record.manifest.contentSHA256
        let directory = try templateDirectory(id: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var history = record.history.filter { $0.version != version }
        if !history.contains(where: { $0.version == record.manifest.version }) {
            history.insert(record.manifest, at: 0)
        }
        let pointer = Pointer(
            schemaVersion: Self.currentSchemaVersion,
            id: id,
            version: version,
            history: history.prefix(Self.maxRetainedVersions).map(\.version)
        )
        let staging = directory.appendingPathComponent(".current-\(UUID().uuidString.lowercased()).staging")
        try encoder.encode(pointer).write(to: staging, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(
                directory.appendingPathComponent("current.json"),
                withItemAt: staging
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return restored
    }

    /// Removes a user template entirely. The id is validated before any path
    /// is built; symlinked directories are resolved and still must live
    /// inside the root.
    public func removeUser(id: String) throws {
        let directory = try templateDirectory(id: id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Pointer

    struct Pointer: Codable {
        let schemaVersion: Int
        let id: String
        let version: String
        let history: [String]
    }
}
