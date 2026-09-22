// FloeExecution — Runtime v2 storage layout (Build 222).
//
// The Runtime v2 root is `<Application Support>/Floe/Runtime/v2`. It owns the
// durable runtime substrate for Linux-guest environments:
//
//   layout.json                     layout version, creating/migrating build, state
//   registry/runtime.sqlite         transactional relations (Conversation,
//   registry/migrations/            Environment, Workspace, Image, Lease, Service,
//                                   Port, Queue, Migration) + applied-SQL audit files
//   images/manifests/<imageID>.json imageID → content-addressed artifact digests
//   images/blobs/sha512/<prefix>/<digest>   verified, read-only, deduplicated blobs
//   images/expanded/<imageID>/      rebuildable bootable view (bios/kernel/rootfs),
//                                   excluded from backup, re-cloned from blobs
//   environments/<environmentID>/   metadata.json, system/delta.{header,bitmap,data},
//                                   services.json, ports.json, state/last-shutdown.json,
//                                   data/ (the only per-environment 9p data export),
//                                   lease.json (durable single-writer ownership)
//   workspaces/owned/<id>/          internal workspaces (persistent)
//   workspaces/refs/<id>.json       external security-scoped references only;
//                                   external projects are never copied or moved
//   workspaces/scratch/<id>/        temporary workspaces
//   cache/{apt,pip,npm,cargo,staging}  shared download objects/indexes ONLY —
//                                   never environment install state; LRU-evicted;
//                                   excluded from backup
//   runtime/{vm/<runtimeID>,queues,downloads,scratch,tmp}
//                                   all temporary, never a state source; VM RAM is
//                                   never persisted; app restart recovers from the
//                                   registry + environment sidecars and marks
//                                   interrupted sessions explicitly
//   recovery/migrations/<id>/       per-migration rollback points (legacy content is
//   recovery/quarantine/<id>/       moved aside, never destroyed in place); quarantine
//   recovery/trash/                 is distinct from user-deletion trash
//   logs/                           bounded, redacted, exportable diagnostics
//
// Backup boundary: environments/*, workspaces/owned, workspaces/refs and the
// registry are persistent. Re-downloadable base blobs, images/expanded, cache,
// runtime, logs and everything under tmp are excluded from cloud backup.
// Credentials are never stored here; only opaque credential identifiers.

import Foundation
import FloeCore

/// Errors raised by the Runtime v2 substrate. Messages are diagnostic and
/// never contain credentials or host paths outside the runtime root.
public enum RuntimeV2Error: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentifier(kind: String, value: String)
    case pathEscapesRoot(String)
    case layoutVersionMismatch(found: Int, expected: Int)
    case layoutCorrupt(String)
    case registryCorrupt(String)
    case unverifiedImageReferenced(String)
    case imageNotFound(String)
    case blobDigestMismatch(expected: String, actual: String)
    case blobMissing(String)
    case deltaCorrupt(environmentID: String, reason: String)
    case deltaBaseConflict(environmentID: String, recorded: String, verified: String)
    case environmentRepairRequired(environmentID: String, reason: String?)
    case leaseHeld(environmentID: String, runtimeID: String)
    case leaseNotHeld(environmentID: String)
    case queueFull(limit: Int)
    case queueTimedOut(environmentID: String, seconds: Int)
    case migrationFailed(id: String, phase: String, reason: String)
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let kind, let value):
            return "invalid \(kind) identifier '\(value)': identifiers are 1-128 chars of [A-Za-z0-9._-], never '.', '..', empty or containing slashes/NUL"
        case .pathEscapesRoot(let path):
            return "path escapes the Runtime v2 root: \(path)"
        case .layoutVersionMismatch(let found, let expected):
            return "Runtime layout version \(found) is not supported by this build (expects \(expected)); data was retained"
        case .layoutCorrupt(let reason):
            return "Runtime layout is corrupt: \(reason); data was retained"
        case .registryCorrupt(let reason):
            return "Runtime registry is corrupt: \(reason); data was retained"
        case .unverifiedImageReferenced(let id):
            return "image '\(id)' has not passed digest verification; the registry never points at unverified files"
        case .imageNotFound(let id):
            return "no Runtime v2 image named '\(id)'"
        case .blobDigestMismatch(let expected, let actual):
            return "blob content digest mismatch (expected \(expected.prefix(16))…, got \(actual.prefix(16))…); the blob was not installed"
        case .blobMissing(let digest):
            return "verified blob \(digest.prefix(16))… is missing from the content store"
        case .deltaCorrupt(let environmentID, let reason):
            return "system delta for \(environmentID) is corrupt: \(reason); previous state was retained"
        case .deltaBaseConflict(let environmentID, let recorded, let verified):
            return "system delta for \(environmentID) was captured from base \(recorded.prefix(16))… but the verified base is \(verified.prefix(16))…; the delta was not applied or overwritten"
        case .environmentRepairRequired(let environmentID, let reason):
            return "environment \(environmentID) requires repair before it can boot: \(reason ?? "no reason recorded"); the preserved data was not overwritten"
        case .leaseHeld(let environmentID, let runtimeID):
            return "environment \(environmentID) is owned by live runtime \(runtimeID); a second writer is refused"
        case .leaseNotHeld(let environmentID):
            return "no lease is held for environment \(environmentID) by this runtime"
        case .queueFull(let limit):
            return "the guest start queue is full (limit \(limit)); stop a guest or wait for a queued start"
        case .queueTimedOut(let environmentID, let seconds):
            return "guest start for \(environmentID) waited \(seconds)s in the queue without a free slot; nothing was started"
        case .migrationFailed(let id, let phase, let reason):
            return "migration \(id) failed in phase \(phase): \(reason); the rollback point is preserved"
        case .insufficientSpace(let required, let available):
            return "insufficient storage: need \(required) bytes, \(available) available"
        }
    }
}

/// Validates every identifier that becomes a path component under the runtime
/// root. Identifiers come from environment records, image manifests and
/// workspace ids, all of which are untrusted as path input.
public enum RuntimeV2Identifier {
    public enum Kind: String, Sendable {
        case image, environment, workspace, runtime, migration, scratch
    }

    @discardableResult
    public static func validate(_ value: String, kind: Kind) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128,
              trimmed == value,
              trimmed != ".", trimmed != "..",
              !trimmed.hasPrefix("."),
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else {
            throw RuntimeV2Error.invalidIdentifier(kind: kind.rawValue, value: value)
        }
        return trimmed
    }
}

/// The versioned Runtime v2 directory tree. All path construction goes through
/// this type; nothing outside it may assemble runtime paths by string
/// concatenation, and every resolved path is proven to stay under the root
/// without crossing symlinks.
public struct RuntimeV2Layout: Sendable {
    public static let layoutVersion = 2

    /// layout.json marker: which build created the tree, which build last
    /// migrated it, and whether the tree is usable.
    public struct Marker: Codable, Sendable, Equatable {
        public var layoutVersion: Int
        public var createdByBuild: String
        public var migratedFromBuild: String?
        public var state: String // "active" | "migrating" | "degraded"
        public var createdAt: Date

        public init(layoutVersion: Int, createdByBuild: String, migratedFromBuild: String?, state: String, createdAt: Date) {
            self.layoutVersion = layoutVersion
            self.createdByBuild = createdByBuild
            self.migratedFromBuild = migratedFromBuild
            self.state = state
            self.createdAt = createdAt
        }
    }

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Production root: `<Application Support>/Floe/Runtime/v2`. Distinct from
    /// the legacy `<Application Support>/FloeAgent` artifact store; migration
    /// reads the legacy tree, never writes it in place.
    public static func production(fileManager: FileManager = .default) throws -> RuntimeV2Layout {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw RuntimeV2Error.layoutCorrupt("Application Support directory is unavailable")
        }
        return RuntimeV2Layout(
            root: support
                .appendingPathComponent("Floe", isDirectory: true)
                .appendingPathComponent("Runtime", isDirectory: true)
                .appendingPathComponent("v2", isDirectory: true)
        )
    }

    public var markerURL: URL { root.appendingPathComponent("layout.json") }

    public var registryDirectory: URL { root.appendingPathComponent("registry", isDirectory: true) }
    public var registryDatabaseURL: URL { registryDirectory.appendingPathComponent("runtime.sqlite") }
    public var registryMigrationsDirectory: URL { registryDirectory.appendingPathComponent("migrations", isDirectory: true) }

    public var imagesDirectory: URL { root.appendingPathComponent("images", isDirectory: true) }
    public var imageManifestsDirectory: URL { imagesDirectory.appendingPathComponent("manifests", isDirectory: true) }
    public var blobStoreDirectory: URL { imagesDirectory.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent("sha512", isDirectory: true) }
    public var expandedImagesDirectory: URL { imagesDirectory.appendingPathComponent("expanded", isDirectory: true) }

    public var environmentsDirectory: URL { root.appendingPathComponent("environments", isDirectory: true) }
    public var workspacesDirectory: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    public var ownedWorkspacesDirectory: URL { workspacesDirectory.appendingPathComponent("owned", isDirectory: true) }
    public var workspaceRefsDirectory: URL { workspacesDirectory.appendingPathComponent("refs", isDirectory: true) }
    public var scratchWorkspacesDirectory: URL { workspacesDirectory.appendingPathComponent("scratch", isDirectory: true) }

    public var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public static let cacheKinds = ["apt", "pip", "npm", "cargo", "staging"]
    public func cacheDirectory(kind: String) -> URL {
        cacheDirectory.appendingPathComponent(kind, isDirectory: true)
    }

    public var runtimeDirectory: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    public var runtimeVMDirectory: URL { runtimeDirectory.appendingPathComponent("vm", isDirectory: true) }
    public var runtimeQueuesDirectory: URL { runtimeDirectory.appendingPathComponent("queues", isDirectory: true) }
    public var runtimeDownloadsDirectory: URL { runtimeDirectory.appendingPathComponent("downloads", isDirectory: true) }
    public var runtimeScratchDirectory: URL { runtimeDirectory.appendingPathComponent("scratch", isDirectory: true) }
    public var runtimeTmpDirectory: URL { runtimeDirectory.appendingPathComponent("tmp", isDirectory: true) }

    public var recoveryDirectory: URL { root.appendingPathComponent("recovery", isDirectory: true) }
    public var recoveryMigrationsDirectory: URL { recoveryDirectory.appendingPathComponent("migrations", isDirectory: true) }
    public var quarantineDirectory: URL { recoveryDirectory.appendingPathComponent("quarantine", isDirectory: true) }
    public var trashDirectory: URL { recoveryDirectory.appendingPathComponent("trash", isDirectory: true) }

    public var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }

    // MARK: per-environment paths (the environment id lives only in the
    // parent directory — there is no second nesting level)

    public func environmentDirectory(environmentID: String) throws -> URL {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        return environmentsDirectory.appendingPathComponent(environmentID, isDirectory: true)
    }

    public func environmentMetadataURL(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("metadata.json")
    }

    public func environmentSystemDirectory(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("system", isDirectory: true)
    }

    public func environmentLeaseURL(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("lease.json")
    }

    public func environmentServicesURL(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("services.json")
    }

    public func environmentPortsURL(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("ports.json")
    }

    public func environmentStateDirectory(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("state", isDirectory: true)
    }

    public func environmentLastShutdownURL(environmentID: String) throws -> URL {
        try environmentStateDirectory(environmentID: environmentID).appendingPathComponent("last-shutdown.json")
    }

    /// The per-environment data directory: the ONLY part of an environment
    /// that may be exported over 9p. The system delta, metadata, leases and
    /// the registry are never exported.
    public func environmentDataDirectory(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("data", isDirectory: true)
    }

    public func runtimeVMDirectory(runtimeID: String) throws -> URL {
        try RuntimeV2Identifier.validate(runtimeID, kind: .runtime)
        return runtimeVMDirectory.appendingPathComponent(runtimeID, isDirectory: true)
    }

    public func expandedImageDirectory(imageID: String) throws -> URL {
        try RuntimeV2Identifier.validate(imageID, kind: .image)
        return expandedImagesDirectory.appendingPathComponent(imageID, isDirectory: true)
    }

    public func imageManifestURL(imageID: String) throws -> URL {
        try RuntimeV2Identifier.validate(imageID, kind: .image)
        return imageManifestsDirectory.appendingPathComponent("\(imageID).json")
    }

    /// Blob path for a SHA-512 digest: blobs/sha512/<first-2-hex>/<digest>.
    public func blobURL(digest: String) throws -> URL {
        let normalized = digest.lowercased()
        guard normalized.count == 128, normalized.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeV2Error.invalidIdentifier(kind: "blob-digest", value: String(digest.prefix(24)))
        }
        return blobStoreDirectory
            .appendingPathComponent(String(normalized.prefix(2)), isDirectory: true)
            .appendingPathComponent(normalized)
    }

    // MARK: containment

    /// Resolves `url` and proves it stays under the runtime root without
    /// crossing a symlink. Every file the substrate opens goes through here:
    /// app-owned roots never follow a symlink escape.
    public func contain(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw RuntimeV2Error.pathEscapesRoot(url.path)
        }
        // Walk existing components from the root down: none may be a symlink
        // that would redirect inside the tree to an outside target.
        var cursor = resolvedRoot
        let relative = resolved.path.dropFirst(resolvedRoot.path.count)
        for component in relative.split(separator: "/") {
            cursor = cursor.appendingPathComponent(String(component), isDirectory: false)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: cursor.path, isDirectory: &isDirectory) {
                if let type = try? fileManager.attributesOfItem(atPath: cursor.path)[.type] as? FileAttributeType,
                   type == .typeSymbolicLink {
                    throw RuntimeV2Error.pathEscapesRoot(url.path)
                }
            }
        }
        return resolved
    }

    // MARK: preparation + backup policy

    /// Directories excluded from cloud backup: re-downloadable base blobs,
    /// rebuildable expanded images, caches, everything under runtime/, logs
    /// and tmp. Environment deltas/metadata, the registry, owned workspaces
    /// and external references stay persistent.
    private var backupExcludedRoots: [URL] {
        [
            blobStoreDirectory,
            expandedImagesDirectory,
            cacheDirectory,
            runtimeDirectory,
            logsDirectory
        ]
    }

    /// Creates the whole tree (idempotent), writes layout.json on first use,
    /// applies the backup policy, and refuses a tree written by a newer
    /// layout version (data retained, never silently rewritten).
    @discardableResult
    public func prepare(build: String, fileManager: FileManager = .default) throws -> Marker {
        let directories: [URL] = [
            root, registryDirectory, registryMigrationsDirectory,
            imageManifestsDirectory, blobStoreDirectory, expandedImagesDirectory,
            environmentsDirectory,
            ownedWorkspacesDirectory, workspaceRefsDirectory, scratchWorkspacesDirectory,
            cacheDirectory,
            runtimeVMDirectory, runtimeQueuesDirectory, runtimeDownloadsDirectory,
            runtimeScratchDirectory, runtimeTmpDirectory,
            recoveryMigrationsDirectory, quarantineDirectory, trashDirectory,
            logsDirectory
        ] + RuntimeV2Layout.cacheKinds.map { cacheDirectory(kind: $0) }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for excluded in backupExcludedRoots {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? (excluded as NSURL).setResourceValue(values.isExcludedFromBackup, forKey: .isExcludedFromBackupKey)
        }

        if let data = try? Data(contentsOf: markerURL) {
            let marker: Marker
            do {
                marker = try Self.markerDecoder.decode(Marker.self, from: data)
            } catch {
                throw RuntimeV2Error.layoutCorrupt("layout.json does not decode: \(error.localizedDescription)")
            }
            guard marker.layoutVersion == RuntimeV2Layout.layoutVersion else {
                throw RuntimeV2Error.layoutVersionMismatch(
                    found: marker.layoutVersion,
                    expected: RuntimeV2Layout.layoutVersion
                )
            }
            return marker
        }

        let marker = Marker(
            layoutVersion: RuntimeV2Layout.layoutVersion,
            createdByBuild: build,
            migratedFromBuild: nil,
            state: "active",
            createdAt: Date()
        )
        try writeMarker(marker)
        return marker
    }

    public func loadMarker() throws -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try Self.markerDecoder.decode(Marker.self, from: data)
    }

    public func writeMarker(_ marker: Marker) throws {
        let data = try Self.markerEncoder.encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }

    static let markerEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let markerDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
