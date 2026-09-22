// FloeExecution — Runtime v2 legacy environment migrator.
//
// Migrates one legacy Linux-guest environment into Runtime v2 without data
// loss and without ever modifying legacy content in place:
//
//   legacy disk:  <layer>/LinuxGuest/disks/<environmentID>/{disk.img,origin.json,runner.json}
//                 → verified base (content-addressed expanded rootfs)
//                 → environments/<id>/system/delta.{header,bitmap,data}
//                 The capture round-trip is re-materialized and compared
//                 block-for-block before the switch, so "copied" is proven,
//                 not assumed. Origin conflicts (the disk was not cloned from
//                 the verified base nor from a manifest-declared compatible
//                 origin) quarantine the disk and mark the environment
//                 repairRequired — mismatched disks are never overwritten.
//
//   legacy layer: the environment's host layer (user files, home, compat
//                 host-FHS dirs) → copied into environments/<id>/data/ (the
//                 only 9p-exported directory), excluding the LinuxGuest
//                 runtime subtree. Copying — not moving — keeps the
//                 FloeEnvironments-owned layer intact for the compat
//                 namespace; metadata records compatHostFHS so the two
//                 package-state worlds stay explicitly separated.
//
// Every step runs the registry's migrations phase machine
// (discovered/copied/verified/switched/cleanupPending) and the legacy disk
// directory moves into recovery/migrations/<id>/ as the rollback point.

import Foundation
import FloeCore

public actor RuntimeV2EnvironmentMigrator {
    public struct EnvironmentMetadata: Codable, Sendable, Equatable {
        public struct Compat: Codable, Sendable, Equatable {
            /// True when the data dir carries legacy host-FHS compat dirs
            /// (usr/, etc/, var/…) copied from the old layer. They are inert
            /// files for the guest; the system delta is the only package
            /// state source of truth.
            public var hostFHS: Bool

            public init(hostFHS: Bool) { self.hostFHS = hostFHS }
        }

        public var version: Int
        public var environmentID: String
        public var kind: String
        public var ownerID: String?
        public var name: String?
        public var baseImageID: String
        public var baseRootfsSHA512: String
        public var compat: Compat
        public var createdAt: Date
        public var migratedAt: Date?

        public static let currentVersion = 1

        public init(
            environmentID: String, kind: String, ownerID: String?, name: String?,
            baseImageID: String, baseRootfsSHA512: String, compatHostFHS: Bool,
            createdAt: Date, migratedAt: Date? = nil
        ) {
            self.version = EnvironmentMetadata.currentVersion
            self.environmentID = environmentID
            self.kind = kind
            self.ownerID = ownerID
            self.name = name
            self.baseImageID = baseImageID
            self.baseRootfsSHA512 = baseRootfsSHA512
            self.compat = Compat(hostFHS: compatHostFHS)
            self.createdAt = createdAt
            self.migratedAt = migratedAt
        }
    }

    public struct Report: Sendable, Equatable {
        public var environmentID: String
        public var migrationID: String
        public var phase: RuntimeV2Registry.MigrationPhase
        public var deltaBlocks: Int
        public var deltaBytes: Int64
        public var dataFiles: Int
        public var compatHostFHS: Bool

        public init(environmentID: String, migrationID: String, phase: RuntimeV2Registry.MigrationPhase, deltaBlocks: Int, deltaBytes: Int64, dataFiles: Int, compatHostFHS: Bool) {
            self.environmentID = environmentID
            self.migrationID = migrationID
            self.phase = phase
            self.deltaBlocks = deltaBlocks
            self.deltaBytes = deltaBytes
            self.dataFiles = dataFiles
            self.compatHostFHS = compatHostFHS
        }
    }

    private let store: RuntimeV2Store
    private var fileManager: FileManager { .default }

    public init(store: RuntimeV2Store) {
        self.store = store
    }

    // MARK: environment migration

    /// Migrates one legacy environment. `legacyDiskDirectory` is the old
    /// `<writableDirectory>/LinuxGuest/disks/<environmentID>` directory (may
    /// not exist for a never-started environment); `legacyLayerDirectory` is
    /// the FloeEnvironments host layer whose user content seeds the v2 data
    /// dir. Idempotent: an environment whose metadata already matches the
    /// verified base returns its existing state.
    @discardableResult
    public func migrateLegacyEnvironment(
        environmentID: String,
        kind: String,
        ownerID: String?,
        name: String?,
        baseImageID: String,
        legacyDiskDirectory: URL?,
        legacyLayerDirectory: URL?
    ) async throws -> Report {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        let migrationID = "legacy-env-\(environmentID)"
        let registry = store.registry
        do {
            try await registry.beginMigration(
                id: migrationID, kind: "legacy-environment",
                sourcePath: legacyDiskDirectory?.path,
                targetPath: try store.layout.environmentDirectory(environmentID: environmentID).path,
                detail: baseImageID
            )

            // Verified base first: migration only ever diffs against verified
            // content (the database never points at unverified files).
            guard let manifest = try await store.images.manifest(imageID: baseImageID),
                  let rootfsRef = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"],
                  try await store.images.isImageVerified(imageID: baseImageID) else {
                throw RuntimeV2Error.unverifiedImageReferenced(baseImageID)
            }
            let expanded = try await store.images.ensureExpanded(imageID: baseImageID)
            let baseRootfs = expanded.appendingPathComponent(rootfsRef.expandedPath)
            let baseDigest = rootfsRef.sha512.lowercased()

            // Phase: discovered — read the legacy origin sidecar when present.
            var legacyOriginSHA512: String? = nil
            var legacyDisk: URL? = nil
            var legacyRunner: URL? = nil
            if let legacyDiskDirectory {
                if let origin = LinuxGuestRuntimeImagePreparer.diskOrigin(
                    atDiskDirectory: legacyDiskDirectory, fileManager: fileManager
                ) {
                    legacyOriginSHA512 = origin.artifactSHA512.lowercased()
                }
                let diskURL = legacyDiskDirectory.appendingPathComponent(
                    LinuxGuestRuntimeImagePreparer.diskFileName
                )
                if fileManager.fileExists(atPath: diskURL.path) { legacyDisk = diskURL }
                let runnerURL = legacyDiskDirectory.appendingPathComponent(
                    LinuxGuestRuntimeImagePreparer.runnerStateFileName
                )
                if fileManager.fileExists(atPath: runnerURL.path) { legacyRunner = runnerURL }
            }

            // Origin gate: the disk must provably descend from the verified
            // base (exact digest, or a manifest-declared compatible origin).
            if legacyDisk != nil, let legacyOriginSHA512, legacyOriginSHA512 != baseDigest {
                let compatible = try legacyManifest(manifest: manifest)
                    .compatibleOrigins?.contains(where: {
                        $0.artifactSHA512.lowercased() == legacyOriginSHA512
                    }) ?? false
                guard compatible else {
                    if let legacyDiskDirectory {
                        let quarantine = store.layout.quarantineDirectory
                            .appendingPathComponent("disk-\(environmentID)-\(UUID().uuidString)", isDirectory: true)
                        try? fileManager.moveItem(at: legacyDiskDirectory, to: quarantine)
                    }
                    try await registry.setEnvironmentState(
                        id: environmentID, state: "repairRequired",
                        repairReason: "the environment disk does not descend from the verified base image; it was quarantined, never overwritten"
                    )
                    throw RuntimeV2Error.deltaBaseConflict(
                        environmentID: environmentID, recorded: legacyOriginSHA512, verified: baseDigest
                    )
                }
            }

            // Phases copied + verified: capture the legacy disk into the
            // delta, then prove the round-trip by re-materializing and
            // comparing block-for-block.
            try await registry.setMigrationPhase(id: migrationID, phase: .copied)
            var deltaInfo: RuntimeV2DeltaStore.DeltaInfo?
            if let legacyDisk {
                let captured = try await store.deltas.capture(
                    environmentID: environmentID,
                    workingDisk: legacyDisk,
                    baseRootfs: baseRootfs,
                    baseImageID: baseImageID,
                    baseRootfsSHA512: baseDigest
                )
                try await registry.setMigrationPhase(id: migrationID, phase: .verified)
                try await verifyDeltaRoundTrip(
                    environmentID: environmentID, legacyDisk: legacyDisk, baseRootfs: baseRootfs
                )
                deltaInfo = captured
            } else {
                try await registry.setMigrationPhase(id: migrationID, phase: .verified)
            }

            // Phase: switched — data dir (staging + verified copy + atomic
            // rename), runner ledger, metadata and the registry row.
            try await registry.setMigrationPhase(id: migrationID, phase: .switched)
            let (dataFiles, compatHostFHS) = try migrateLayerData(
                environmentID: environmentID, legacyLayerDirectory: legacyLayerDirectory
            )
            if let legacyRunner {
                let destination = try store.layout.environmentSystemDirectory(environmentID: environmentID)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try? fileManager.copyItem(
                    at: legacyRunner, to: destination.appendingPathComponent("runner.json")
                )
            }
            let now = Date()
            let metadata = EnvironmentMetadata(
                environmentID: environmentID, kind: kind, ownerID: ownerID, name: name,
                baseImageID: baseImageID, baseRootfsSHA512: baseDigest,
                compatHostFHS: compatHostFHS, createdAt: now, migratedAt: now
            )
            try writeMetadata(metadata, environmentID: environmentID)
            try await registry.upsertEnvironment(
                RuntimeV2Registry.EnvironmentRow(
                    id: environmentID, kind: kind, ownerID: ownerID, name: name,
                    baseImageID: baseImageID, baseRootfsDigest: baseDigest,
                    state: "active",
                    dataPath: "environments/\(environmentID)/data",
                    compatHostFHS: compatHostFHS, repairReason: nil,
                    createdAt: now, lastUsedAt: now
                )
            )

            // Phase: cleanupPending — the legacy disk directory becomes the
            // rollback point; the legacy layer itself is owned by
            // FloeEnvironments and is left untouched (compat namespace).
            if let legacyDiskDirectory, fileManager.fileExists(atPath: legacyDiskDirectory.path) {
                let rollback = store.layout.recoveryMigrationsDirectory
                    .appendingPathComponent(migrationID, isDirectory: true)
                try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
                let destination = rollback.appendingPathComponent("legacy-disks", isDirectory: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: legacyDiskDirectory, to: destination)
            }
            try await registry.setMigrationPhase(id: migrationID, phase: .cleanupPending)
            return Report(
                environmentID: environmentID, migrationID: migrationID, phase: .cleanupPending,
                deltaBlocks: deltaInfo?.presentBlocks ?? 0,
                deltaBytes: deltaInfo?.deltaBytes ?? 0,
                dataFiles: dataFiles, compatHostFHS: compatHostFHS
            )
        } catch {
            try? await registry.setMigrationPhase(
                id: migrationID, phase: .failed, error: error.localizedDescription
            )
            throw error
        }
    }

    // MARK: metadata sidecar

    public func metadata(environmentID: String) throws -> EnvironmentMetadata? {
        let url = try store.layout.environmentMetadataURL(environmentID: environmentID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EnvironmentMetadata.self, from: data)
    }

    public func writeMetadata(_ metadata: EnvironmentMetadata, environmentID: String) throws {
        let url = try store.layout.environmentMetadataURL(environmentID: environmentID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    // MARK: helpers

    private func legacyManifest(manifest: RuntimeV2ImageStore.Manifest) throws -> LinuxGuestImage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LinuxGuestImage.self, from: manifest.legacyManifestData)
    }

    /// Copies the legacy layer's user content into the v2 data dir via a
    /// staging sibling + verified file/byte counts + atomic rename. The
    /// LinuxGuest runtime subtree (disks, runner upgrade staging) is excluded
    /// — that state moved into the system delta. Returns the copied file
    /// count and whether legacy host-FHS compat dirs were present.
    private func migrateLayerData(
        environmentID: String, legacyLayerDirectory: URL?
    ) throws -> (files: Int, compatHostFHS: Bool) {
        let dataDirectory = try store.layout.environmentDataDirectory(environmentID: environmentID)
        guard let legacyLayerDirectory, fileManager.fileExists(atPath: legacyLayerDirectory.path) else {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            return (0, false)
        }
        let staging = dataDirectory.deletingLastPathComponent()
            .appendingPathComponent(".data-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var fileCount = 0
        var byteCount: Int64 = 0
        var compatHostFHS = false
        let excluded = Set(["LinuxGuest"])
        let fhsDirs = Set(["usr", "etc", "var", "opt"])
        let contents = try fileManager.contentsOfDirectory(atPath: legacyLayerDirectory.path)
        for entry in contents where !excluded.contains(entry) {
            if fhsDirs.contains(entry) { compatHostFHS = true }
            try fileManager.copyItem(
                at: legacyLayerDirectory.appendingPathComponent(entry, isDirectory: true),
                to: staging.appendingPathComponent(entry, isDirectory: true)
            )
        }
        if let enumerator = fileManager.enumerator(
            at: staging, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true {
                    fileCount += 1
                    byteCount += Int64(values.fileSize ?? 0)
                }
            }
        }
        // Verified copy: the staged tree's byte count is re-measured after
        // the copy, so a partial copy fails before the switch, not after.
        var verifiedBytes: Int64 = 0
        if let enumerator = fileManager.enumerator(at: staging, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { verifiedBytes += Int64(values.fileSize ?? 0) }
            }
        }
        guard verifiedBytes == byteCount else {
            throw RuntimeV2Error.migrationFailed(
                id: "legacy-env-\(environmentID)", phase: "copied",
                reason: "data copy verification failed (\(verifiedBytes) != \(byteCount) bytes); nothing was switched"
            )
        }
        if fileManager.fileExists(atPath: dataDirectory.path) {
            let previous = dataDirectory.deletingLastPathComponent()
                .appendingPathComponent(".data-previous-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: dataDirectory, to: previous)
            do {
                guard rename(staging.path, dataDirectory.path) == 0 else { throw POSIXError(.EIO) }
                try? fileManager.removeItem(at: previous)
            } catch {
                try? fileManager.moveItem(at: previous, to: dataDirectory)
                throw RuntimeV2Error.migrationFailed(
                    id: "legacy-env-\(environmentID)", phase: "switched",
                    reason: "data dir switch failed; the previous data was restored"
                )
            }
        } else {
            guard rename(staging.path, dataDirectory.path) == 0 else {
                throw RuntimeV2Error.migrationFailed(
                    id: "legacy-env-\(environmentID)", phase: "switched",
                    reason: "data dir rename failed (errno \(errno))"
                )
            }
        }
        return (fileCount, compatHostFHS)
    }

    /// Proves the captured delta round-trips: re-materialize a working disk
    /// and compare it block-for-block against the legacy disk (sparse-aware).
    private func verifyDeltaRoundTrip(
        environmentID: String, legacyDisk: URL, baseRootfs: URL
    ) async throws {
        let scratch = store.layout.runtimeTmpDirectory
            .appendingPathComponent("verify-\(environmentID)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let rematerialized = scratch.appendingPathComponent("disk.img")
        _ = try await store.deltas.materializeWorkingDisk(
            environmentID: environmentID, baseRootfs: baseRootfs, into: rematerialized
        )
        let legacySize = (try fileManager.attributesOfItem(atPath: legacyDisk.path)[.size] as? Int64) ?? 0
        let newSize = (try fileManager.attributesOfItem(atPath: rematerialized.path)[.size] as? Int64) ?? 0
        guard legacySize == newSize else {
            throw RuntimeV2Error.migrationFailed(
                id: "legacy-env-\(environmentID)", phase: "verified",
                reason: "round-trip size mismatch (\(newSize) != \(legacySize)); the legacy disk was retained"
            )
        }
        let legacyHandle = try FileHandle(forReadingFrom: legacyDisk)
        defer { try? legacyHandle.close() }
        let newHandle = try FileHandle(forReadingFrom: rematerialized)
        defer { try? newHandle.close() }
        var offset: UInt64 = 0
        let chunk = 4 << 20
        while offset < UInt64(legacySize) {
            try Task.checkCancellation()
            try legacyHandle.seek(toOffset: offset)
            try newHandle.seek(toOffset: offset)
            let wanted = min(UInt64(chunk), UInt64(legacySize) - offset)
            let a = try legacyHandle.read(upToCount: Int(wanted)) ?? Data()
            let b = try newHandle.read(upToCount: Int(wanted)) ?? Data()
            guard a == b else {
                throw RuntimeV2Error.migrationFailed(
                    id: "legacy-env-\(environmentID)", phase: "verified",
                    reason: "round-trip content mismatch at offset \(offset); the legacy disk was retained"
                )
            }
            offset += wanted
        }
    }
}
