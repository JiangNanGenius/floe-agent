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
    /// No repair exclusion exists for the environment, so an explicit
    /// restore/discard resolution has nothing to resolve: thrown instead of
    /// silently succeeding, so a UI can never present a no-op as a repair.
    case repairResolutionUnavailable(environmentID: String, reason: String)
    case leaseHeld(environmentID: String, runtimeID: String)
    case leaseNotHeld(environmentID: String)
    case queueFull(limit: Int)
    case queueTimedOut(environmentID: String, seconds: Int)
    case migrationFailed(id: String, phase: String, reason: String)
    case insufficientSpace(required: Int64, available: Int64)
    case templateNotFound(templateID: String, version: Int)
    case templateNotVerified(templateID: String, version: Int, reason: String?)
    case templateVersionImmutable(templateID: String, version: Int, existingDigest: String, newDigest: String)
    case templateBuildInFlight(templateID: String, version: Int)
    case templateParentDigestChanged(templateID: String, version: Int, recorded: String, resolved: String)
    case templatePinUnavailable(environmentID: String, templateID: String, version: Int, reason: String)
    case templateBaseImageMismatch(environmentID: String, templateBaseImage: String, environmentBaseImage: String)
    case templateRecipeInvalid(reason: String)
    case templateInstallerUnverified(reason: String)
    case templateRequirementMissing(templateID: String, version: Int, missing: [String])
    case templateNotOfficial(templateID: String)
    case templateEnvironmentRunning(environmentID: String)
    case environmentNotFound(String)
    case deltaTemplateConflict(environmentID: String, recorded: String, verified: String)
    /// A legacy environment disk exists but cannot be proven to descend from
    /// the verified base (no readable origin record): it is quarantined and
    /// the environment marked repairRequired, never captured as if compatible.
    case diskOriginUnverifiable(environmentID: String, reason: String)
    /// A leftover working directory does not carry the durable provenance
    /// (template pin + boot base digest) needed to capture it against the
    /// exact base it was cloned from.
    case workingDirectoryProvenanceUnavailable(environmentID: String, reason: String)
    /// The provenance recorded at boot no longer matches the live registry
    /// (pin moved, template re-verified to different bytes, base image
    /// changed). Capturing against the new identity would rewrite shared
    /// template bytes as private state, so it is refused outright.
    case bootProvenanceMismatch(environmentID: String, recorded: String, current: String)

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
        case .repairResolutionUnavailable(let environmentID, let reason):
            return "environment \(environmentID) has no repair exclusion to resolve: \(reason); nothing was changed"
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
        case .templateNotFound(let templateID, let version):
            return "no software template '\(templateID)' version \(version)"
        case .templateNotVerified(let templateID, let version, let reason):
            return "software template '\(templateID)' version \(version) is not verified and can never be booted\(reason.map { ": \($0)" } ?? "")"
        case .templateVersionImmutable(let templateID, let version, let existingDigest, let newDigest):
            return "software template '\(templateID)' version \(version) is immutable: recorded \(existingDigest.prefix(16))… but the new build produced \(newDigest.prefix(16))…; a new version is required"
        case .templateBuildInFlight(let templateID, let version):
            return "software template '\(templateID)' version \(version) already has a build in flight; nothing was started"
        case .templateParentDigestChanged(let templateID, let version, let recorded, let resolved):
            return "software template '\(templateID)' version \(version) recorded parent \(recorded.prefix(16))… but the resolved parent is \(resolved.prefix(16))…; the build was refused (no illegal rebase)"
        case .templatePinUnavailable(let environmentID, let templateID, let version, let reason):
            return "environment \(environmentID) is pinned to software template '\(templateID)' version \(version) which is unavailable: \(reason); the environment was not booted on a different base"
        case .templateBaseImageMismatch(let environmentID, let templateBaseImage, let environmentBaseImage):
            return "environment \(environmentID) boots base image '\(environmentBaseImage)' but its pinned template was built on '\(templateBaseImage)'; booting that combination is refused"
        case .templateRecipeInvalid(let reason):
            return "software template recipe is invalid: \(reason)"
        case .templateInstallerUnverified(let reason):
            return "the template installer did not verify the installation: \(reason); the template was not registered as verified"
        case .templateRequirementMissing(let templateID, let version, let missing):
            return "software template '\(templateID)' version \(version) does not satisfy its recipe; missing/unobtainable: \(missing.joined(separator: ", "))"
        case .templateNotOfficial(let templateID):
            return "'\(templateID)' is not an official software template; nothing was registered"
        case .templateEnvironmentRunning(let environmentID):
            return "environment \(environmentID) still holds a live lease; the template pin cannot be changed while it is running"
        case .environmentNotFound(let environmentID):
            return "no Runtime v2 environment registered as '\(environmentID)'"
        case .deltaTemplateConflict(let environmentID, let recorded, let verified):
            return "system delta for \(environmentID) was captured from \(recorded) but the boot base is \(verified); the delta was not applied (no rebase across template versions)"
        case .diskOriginUnverifiable(let environmentID, let reason):
            return "the existing disk for environment \(environmentID) cannot be proven to descend from the verified base: \(reason); it was quarantined, not destroyed, and the environment was marked repairRequired"
        case .workingDirectoryProvenanceUnavailable(let environmentID, let reason):
            return "environment \(environmentID) has a leftover working disk whose boot base cannot be proven: \(reason); the disk was preserved and the environment was marked repairRequired"
        case .bootProvenanceMismatch(let environmentID, let recorded, let current):
            return "environment \(environmentID) booted \(recorded) but the live base is now \(current); the working disk was preserved and no delta was written across the two identities"
        }
    }
}

/// Validates every identifier that becomes a path component under the runtime
/// root. Identifiers come from environment records, image manifests and
/// workspace ids, all of which are untrusted as path input.
public enum RuntimeV2Identifier {
    public enum Kind: String, Sendable {
        case image, environment, workspace, runtime, migration, scratch, template
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

    /// The durable, non-expiring repair exclusion for an environment. Unlike
    /// the lease sidecar this marker carries NO TTL: it survives process
    /// death, TTL expiry and stale-lease reclamation, and every start /
    /// recovery path must consult it BEFORE reclaiming a lease or preparing a
    /// disk. It is cleared only by an explicit repair acknowledgement.
    public func environmentRepairHoldURL(environmentID: String) throws -> URL {
        try environmentDirectory(environmentID: environmentID).appendingPathComponent("repair-hold.json")
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

    /// Validates a layout-relative preserved-bytes path — which comes from a
    /// repair hold sidecar and is therefore UNTRUSTED content — and returns
    /// its symlink-resolved directory URL. Only the two supported physical
    /// evidence shapes are accepted, each a single path component deep:
    ///   - `recovery/quarantine/runtime-vm-<entry>` (a preserved quarantine
    ///     entry written by a stop/recovery),
    ///   - `runtime/vm/<runtimeID>` (a preserved in-place working disk).
    /// Absolute paths, `..`/`.` components, any other prefix, or a path whose
    /// SYMLINK RESOLUTION lands anywhere other than exactly the resolved
    /// runtime root + the given relative path (a symlink inside the root
    /// pointing at a foreign location changes the resolved path) are refused
    /// with `pathEscapesRoot`. Callers must use this for every path that a
    /// hold sidecar names before reading, capturing or MOVING anything.
    public func preservedRuntimeDirectory(_ preservedPath: String) throws -> URL {
        let prefix: String
        if preservedPath.hasPrefix("recovery/quarantine/runtime-vm-") {
            prefix = "recovery/quarantine/runtime-vm-"
        } else if preservedPath.hasPrefix("runtime/vm/") {
            prefix = "runtime/vm/"
        } else {
            throw RuntimeV2Error.pathEscapesRoot(preservedPath)
        }
        let components = preservedPath.split(separator: "/", omittingEmptySubsequences: false)
        let relative = String(preservedPath.dropFirst(prefix.count))
        guard !preservedPath.hasPrefix("/"),
              components.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }),
              !relative.isEmpty,
              !relative.contains("/")
        else { throw RuntimeV2Error.pathEscapesRoot(preservedPath) }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let expected = resolvedRoot.appendingPathComponent(preservedPath).standardizedFileURL
        let resolved = root.appendingPathComponent(preservedPath)
            .resolvingSymlinksInPath().standardizedFileURL
        // Exact equality (not prefix containment) both pins the path inside
        // the root and proves no symlink component redirected it: any
        // internal symlink or traversal resolves to a different absolute
        // path and fails here.
        guard resolved.path == expected.path else {
            throw RuntimeV2Error.pathEscapesRoot(preservedPath)
        }
        return resolved
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

    /// Deterministic quarantine slot for a reclaimed blob's physical bytes.
    /// Content-addressed bytes have exactly one quarantine slot per digest, so
    /// a consumer that finds the canonical path empty can restore the exact
    /// bytes back (and racing re-placements of identical content are
    /// indistinguishable anyway). GC never hard-deletes blob bytes; it moves
    /// them here so a racing stage/ingest can always recover.
    public func blobQuarantineURL(digest: String) throws -> URL {
        let normalized = digest.lowercased()
        guard normalized.count == 128, normalized.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeV2Error.invalidIdentifier(kind: "blob-digest", value: String(digest.prefix(24)))
        }
        return quarantineDirectory.appendingPathComponent("blob-\(normalized)")
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
