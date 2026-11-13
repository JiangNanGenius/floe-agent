// Byte-preserving maintenance metadata for six fixed legacy image rollback files.
// No model path, deletion, deduplication or image-migration state mutation.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

public struct RuntimeV2MigrationSparseTarget: Codable, Sendable, Equatable {
    public enum Branch: String, Codable, Sendable { case expandedPrevious, legacyImage }
    public let imageID: String
    public let branch: Branch
    public var migrationID: String { "legacy-image-" + imageID }
    public var group: String { "recovery/migrations/" + migrationID }
    public var parent: String {
        group + (branch == .expandedPrevious ? "/expanded-previous" : "/legacy-images/" + imageID)
    }
    public var relativePath: String { parent + "/disk.img" }
}

enum RuntimeV2MigrationSparseCatalog {
    static let imageIDs = [
        "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1",
        "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b37171053949-1",
        "floe-debian13-riscv64-20260922.2",
        "floe-debian13-riscv64-basic-runner210-20261102-r36882693"
    ]
    static let targets: [RuntimeV2MigrationSparseTarget] = imageIDs.enumerated().flatMap { index, id in
        let branches: [RuntimeV2MigrationSparseTarget.Branch] = index < 2
            ? [.expandedPrevious, .legacyImage] : [.legacyImage]
        return branches.map { RuntimeV2MigrationSparseTarget(imageID: id, branch: $0) }
    }
    static func target(_ relative: String) -> RuntimeV2MigrationSparseTarget? {
        targets.first { $0.relativePath == relative }
    }
}

/// A transaction-consistent projection of native registry metadata. Its digest
/// is a generation guard, never evidence that a worker or descriptor stopped.
public struct RuntimeV2MigrationSparseBinding: Codable, Sendable, Equatable {
    public let migrationID: String
    public let imageID: String
    public let phase: String
    public let sourcePath: String
    public let targetPath: String
    public let createdAt: String
    public let updatedAt: String
    public let migrationRowFingerprint: String
    public let imageRowFingerprint: String
    public let imageRootfsDigest: String
    public let environmentRowFingerprints: [String]
    public let auxiliaryReferenceFingerprint: String

    func validateHistoricalPaths() throws {
        func hasSuffix(_ path: String, _ suffix: String) -> Bool {
            path.hasPrefix("/") && path.utf8.count <= 4_096 && !path.utf8.contains(0)
                && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
                && path.hasSuffix(suffix)
        }
        guard RuntimeV2MigrationSparseCatalog.imageIDs.contains(imageID),
              migrationID == "legacy-image-" + imageID,
              ["cleanupPending", "failed"].contains(phase),
              hasSuffix(sourcePath, "/Library/Application Support/FloeAgent/LinuxGuest/images/" + imageID),
              hasSuffix(targetPath, "/Library/Application Support/Floe/Runtime/v2/images/expanded/" + imageID),
              !createdAt.isEmpty, !updatedAt.isEmpty else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_binding_unknown"])
        }
        // Historical absolute paths above are compared as durable DB facts.
        // They are NEVER opened, rewritten or used as an alternate IO root.
    }
}

public struct RuntimeV2MigrationSparseProjection: Codable, Sendable, Equatable {
    public let bindings: [RuntimeV2MigrationSparseBinding]
    public func binding(imageID: String) throws -> RuntimeV2MigrationSparseBinding {
        let matches = bindings.filter { $0.imageID == imageID }
        guard matches.count == 1, let value = matches.first else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_binding_unknown"])
        }
        try value.validateHistoricalPaths()
        return value
    }
}

struct RuntimeV2MigrationSparseObservation: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case directory, file, absent }
    let relative: String
    let kind: Kind
    let identity: StorageSparseDiskIdentity?
    let sha256: String?
}

public struct RuntimeV2MigrationSparseRecord: Codable, Sendable {
    public let target: RuntimeV2MigrationSparseTarget
    public let source: StorageSparseDiskIdentity
    public let allocatedBytes: Int64
    let rootPath: String
    let rootDevice: UInt64
    let rootInode: UInt64
    let binding: RuntimeV2MigrationSparseBinding
    let observations: [RuntimeV2MigrationSparseObservation]
    let peerDisks: [String: StorageSparseDiskIdentity]

    func preservationFingerprint() throws -> String {
        struct Preservation: Encodable {
            let rootDevice: UInt64
            let rootInode: UInt64
            let target: RuntimeV2MigrationSparseTarget
            let binding: RuntimeV2MigrationSparseBinding
            let observations: [RuntimeV2MigrationSparseObservation]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // The physical root and stable relative names survive a container move.
        // Selected/peer disk identities are fenced separately; legitimate prior
        // sparse commits must not erase or invalidate another completed receipt.
        return FloeDigest.sha256Hex(try encoder.encode(Preservation(
            rootDevice: rootDevice, rootInode: rootInode, target: target,
            binding: binding, observations: observations)))
    }
}

public struct RuntimeV2MigrationSparseInventoryReport: Sendable {
    public let records: [RuntimeV2MigrationSparseRecord]
    public let blockedPaths: Int
    public let codes: [String]
    public var isComplete: Bool { codes.isEmpty }
}

enum RuntimeV2MigrationSparseInventory {
    #if canImport(Darwin)
    private static let worker = RuntimeV2OptimizationWorker("floe.legacy-migration.metadata")
    static func scan(domain: RuntimeV2MaintenanceDomain) async throws -> RuntimeV2MigrationSparseInventoryReport {
        let present = try await worker.run {
            guard let canonical = domain.root.path.withCString({ realpath($0, nil) }) else {
                throw RuntimeV2MaintenanceError.targetMissing("migration root unavailable")
            }
            defer { free(canonical) }
            let fd = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RuntimeV2MaintenanceError.targetMissing("migration root unavailable") }
            defer { close(fd) }
            var found = false
            for id in RuntimeV2MigrationSparseCatalog.imageIDs {
                if let group = try optionalDirectory(fd, "recovery/migrations/legacy-image-" + id) {
                    close(group); found = true
                }
            }
            return found
        }
        guard present else { return .init(records: [], blockedPaths: 0, codes: []) }
        let projection = try await RuntimeV2LegacyRegistryReader.readMigrationProjectionAsync(domain: domain)
        return try await worker.run {
            var records: [RuntimeV2MigrationSparseRecord] = [], blocked = 0
            var codes: Set<String> = []
            for target in RuntimeV2MigrationSparseCatalog.targets {
                do { records.append(try inspect(domain: domain, target: target, projection: projection)) }
                catch {
                    blocked += 1
                    codes.insert("migration_preservation_unavailable")
                }
            }
            return .init(records: records, blockedPaths: blocked, codes: codes.sorted())
        }
    }

    static func refresh(domain: RuntimeV2MaintenanceDomain, record: RuntimeV2MigrationSparseRecord,
                        excludingStage: String? = nil) async throws -> RuntimeV2MigrationSparseRecord {
        let projection = try await RuntimeV2LegacyRegistryReader.readMigrationProjectionAsync(domain: domain)
        return try await worker.run {
            try inspect(domain: domain, target: record.target, projection: projection, excludingStage: excludingStage)
        }
    }

    private static func inspect(domain: RuntimeV2MaintenanceDomain, target: RuntimeV2MigrationSparseTarget,
                                projection: RuntimeV2MigrationSparseProjection, excludingStage: String? = nil) throws -> RuntimeV2MigrationSparseRecord {
        guard RuntimeV2MigrationSparseCatalog.target(target.relativePath) == target else {
            throw RuntimeV2MaintenanceError.invalidTarget("not a fixed migration disk")
        }
        let binding = try projection.binding(imageID: target.imageID)
        let root = try RuntimeV2DiskIdentity.read(at: domain.root)
        guard let canonical = domain.root.path.withCString({ realpath($0, nil) }) else {
            throw RuntimeV2MaintenanceError.targetMissing("migration root unavailable")
        }
        defer { free(canonical) }
        let fd = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeV2MaintenanceError.targetMissing("migration root unavailable") }
        defer { close(fd) }
        let opened = try identity(fd)
        guard opened.device == root.device, opened.inode == root.inode else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration root changed")
        }
        var observations: [RuntimeV2MigrationSparseObservation] = []
        var peers: [String: StorageSparseDiskIdentity] = [:]
        var namesVisited = 0, sidecarBytes = 0
        func walk(_ directory: Int32, _ relative: String) throws {
            guard relative.split(separator: "/").count < 10 else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_metadata_bound"])
            }
            for name in try LinuxImageStageIO.names(in: directory, limit: 64) {
                namesVisited += 1
                guard namesVisited <= 96 else {
                    throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_metadata_bound"])
                }
                let path = relative + "/" + name
                if let excludingStage, path == target.parent + "/" + excludingStage {
                    guard excludingStage.hasPrefix("."), excludingStage != ".", excludingStage != "..",
                          !excludingStage.contains("/"), excludingStage.utf8.count <= 255 else {
                        throw RuntimeV2MaintenanceError.targetIdentityMismatch("unbound migration stage")
                    }
                    // The caller binds this one exact name to the current Core
                    // journal/claim. Core alone validates and retires that inode.
                    continue
                }
                guard let meta = try LinuxImageStageIO.observe(name, in: directory) else {
                    throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration entry vanished")
                }
                if meta.isDirectory {
                    guard let child = try LinuxImageStageIO.directory(name, in: directory, create: false) else {
                        throw RuntimeV2MaintenanceError.targetMissing("migration directory unavailable")
                    }
                    defer { close(child) }
                    guard try LinuxImageStageIO.identity(fd: child).sameInode(as: meta) else {
                        throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration directory changed")
                    }
                    let current = try identity(child)
                    observations.append(.init(relative: path, kind: .directory,
                        identity: directoryIdentity(current), sha256: nil))
                    try walk(child, path)
                    guard let named = try LinuxImageStageIO.observe(name, in: directory), named.sameInode(as: meta) else {
                        throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration directory moved during observation")
                    }
                } else {
                    guard meta.isRegular, meta.links == 1, meta.uid == UInt32(geteuid()) else {
                        throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_metadata_unknown"])
                    }
                    if RuntimeV2MigrationSparseCatalog.target(path) != nil {
                        let child = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { throw RuntimeV2MaintenanceError.targetMissing("migration peer unavailable") }
                        defer { close(child) }
                        guard try LinuxImageStageIO.identity(fd: child) == meta,
                              try LinuxImageStageIO.observe(name, in: directory) == meta else {
                            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration peer changed during observation")
                        }
                        peers[path] = try identity(child)
                        continue
                    }
                    let value = try readFile(parent: directory, name: name, hashSmall: meta.size <= 65_536)
                    if meta.size <= 65_536 { sidecarBytes += Int(meta.size) }
                    guard sidecarBytes <= 1_048_576 else {
                        throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_metadata_bound"])
                    }
                    observations.append(.init(relative: path, kind: .file, identity: value.0, sha256: value.1))
                }
            }
        }
        let group = try openDirectory(fd, target.group)
        defer { close(group) }
        observations.append(.init(relative: target.group, kind: .directory,
            identity: directoryIdentity(try identity(group)), sha256: nil))
        try walk(group, target.group)
        let manifestPath = target.parent + "/manifest.json"
        let manifest = try readSmall(fd, manifestPath)
        guard observations.first(where: { $0.relative == manifestPath })?.sha256 == FloeDigest.sha256Hex(manifest),
              let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["id"] as? String == target.imageID,
              let artifacts = object["artifacts"] as? [[String: Any]],
              let disk = artifacts.first(where: { $0["role"] as? String == "disk" }),
              disk["path"] as? String == "disk.img", let bytes = disk["bytes"] as? NSNumber,
              let digest = disk["sha512"] as? String, digest.utf8.count == 128,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let source = peers[target.relativePath], source.sizeBytes > 0,
              source.sizeBytes == bytes.int64Value else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_manifest_unknown"])
        }
        let v2Path = "images/manifests/" + target.imageID + ".json"
        let v2 = try readSmall(fd, v2Path)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let v2Manifest = try? decoder.decode(RuntimeV2ImageStore.Manifest.self, from: v2),
              v2Manifest.version == RuntimeV2ImageStore.Manifest.currentVersion,
              v2Manifest.imageID == target.imageID,
              v2Manifest.rootfsDigest == binding.imageRootfsDigest,
              let embedded = try? decoder.decode(LinuxGuestImage.self, from: v2Manifest.legacyManifestData),
              embedded.id == target.imageID else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_manifest_unknown"])
        }
        let v2Parent = try openDirectory(fd, "images/manifests"); defer { close(v2Parent) }
        let v2Observation = try readFile(parent: v2Parent, name: target.imageID + ".json", hashSmall: true)
        guard v2Observation.1 == FloeDigest.sha256Hex(v2) else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration manifest changed")
        }
        observations.append(.init(relative: v2Path, kind: .file,
                                  identity: v2Observation.0, sha256: v2Observation.1))
        // Current expanded target is observed as present-directory identity or
        // stable absence. The old absolute DB path is never opened.
        let expanded = "images/expanded/" + target.imageID
        if let expandedFD = try optionalDirectory(fd, expanded) {
            defer { close(expandedFD) }
            observations.append(.init(relative: expanded, kind: .directory,
                identity: directoryIdentity(try identity(expandedFD)), sha256: nil))
        } else {
            observations.append(.init(relative: expanded, kind: .absent, identity: nil, sha256: nil))
        }
        let inspected = try StorageSparseDiskRewrite.inspectSource(rootURL: domain.root, relativePath: target.relativePath)
        guard inspected.identity.matchesFully(source),
              domain.matchesRecordedRoot(domain.root.path, device: root.device, inode: root.inode) else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration source changed during inventory")
        }
        peers[target.relativePath] = nil
        return .init(target: target, source: source, allocatedBytes: inspected.allocatedBytes,
            rootPath: domain.root.path, rootDevice: root.device, rootInode: root.inode,
            binding: binding, observations: observations.sorted { $0.relative < $1.relative }, peerDisks: peers)
    }

    private static func directoryIdentity(_ value: StorageSparseDiskIdentity) -> StorageSparseDiskIdentity {
        .init(device: value.device, inode: value.inode, sizeBytes: 0, linkCount: 0,
              mode: value.mode, ownerUID: value.ownerUID, ownerGID: value.ownerGID, fileFlags: value.fileFlags,
              modificationSeconds: 0, modificationNanoseconds: 0, changeSeconds: 0, changeNanoseconds: 0)
    }
    private static func identity(_ fd: Int32) throws -> StorageSparseDiskIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw RuntimeV2MaintenanceError.targetMissing("migration metadata unavailable") }
        return .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
            sizeBytes: Int64(info.st_size), linkCount: UInt32(info.st_nlink), mode: UInt32(info.st_mode),
            ownerUID: UInt32(info.st_uid), ownerGID: UInt32(info.st_gid), fileFlags: UInt32(info.st_flags),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec), changeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
    private static func openDirectory(_ root: Int32, _ relative: String) throws -> Int32 {
        guard let directory = try optionalDirectory(root, relative) else {
            throw RuntimeV2MaintenanceError.targetMissing("migration directory unavailable")
        }
        return directory
    }
    private static func optionalDirectory(_ root: Int32, _ relative: String) throws -> Int32? {
        var current = dup(root)
        guard current >= 0 else { throw RuntimeV2MaintenanceError.targetMissing("migration directory unavailable") }
        do {
            for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
                guard let next = try LinuxImageStageIO.directory(String(part), in: current, create: false) else {
                    close(current); return nil
                }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    private static func readSmall(_ root: Int32, _ relative: String) throws -> Data {
        let parts = relative.split(separator: "/").map(String.init)
        let parent = try openDirectory(root, parts.dropLast().joined(separator: "/")); defer { close(parent) }
        guard let leaf = parts.last else { throw RuntimeV2MaintenanceError.invalidTarget("migration metadata path") }
        return try readFile(parent: parent, name: leaf, hashSmall: true).2
    }
    private static func readFile(parent: Int32, name: String, hashSmall: Bool)
        throws -> (StorageSparseDiskIdentity, String?, Data) {
        try LinuxImageStageIO.validate(name)
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeV2MaintenanceError.targetMissing("migration metadata unavailable") }
        defer { close(fd) }
        let before = try identity(fd)
        guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG), before.linkCount == 1,
              before.ownerUID == UInt32(geteuid()), before.sizeBytes >= 0,
              !hashSmall || before.sizeBytes <= 65_536 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["migration_metadata_unknown"])
        }
        var data = Data()
        if hashSmall {
            var buffer = [UInt8](repeating: 0, count: Int(before.sizeBytes))
            var offset = 0
            while offset < buffer.count {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration metadata changed") }
                offset += count
            }
            data = Data(buffer)
        }
        guard try identity(fd).matchesFully(before),
              let named = try LinuxImageStageIO.observe(name, in: parent),
              named.device == before.device, named.inode == before.inode else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration metadata changed")
        }
        return (before, hashSmall ? FloeDigest.sha256Hex(data) : nil, data)
    }
    #else
    static func scan(domain: RuntimeV2MaintenanceDomain) async throws -> RuntimeV2MigrationSparseInventoryReport {
        throw StorageSparseDiskRewriteError.unsupportedPlatform
    }
    static func refresh(domain: RuntimeV2MaintenanceDomain, record: RuntimeV2MigrationSparseRecord,
                        excludingStage: String? = nil) async throws -> RuntimeV2MigrationSparseRecord {
        throw StorageSparseDiskRewriteError.unsupportedPlatform
    }
    #endif
}
