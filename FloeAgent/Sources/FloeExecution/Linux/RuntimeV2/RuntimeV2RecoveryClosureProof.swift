// Native closure evidence for exactly the retired legacy recovery domain.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

public struct RuntimeV2RecoveryClosedReceipt: Codable, Sendable, Equatable {
    public let version: Int
    public let proofID: String
    public let isConvergenceProof: Bool
    public let domainKey: String
    public let rootDevice: UInt64
    public let rootInode: UInt64
    public let incarnation: String
    public let sourceGeneration: UInt64
    public let intentID: String
    public let holdGeneration: UInt64
    public let historicalLeaseEnvironmentIDs: [String]
    public let historicalRegistryLeaseEnvironmentIDs: [String]
    public let ownerEvidenceFingerprint: String
    public let legacyRegistryFingerprint: String
    public let inspectedDescriptorSlots: Int
    public let readOnlyMetadataDescriptors: Int
}

/// The first call runs while the coordinator already holds EXCLUSIVE admission
/// and flock and before Core has opened its own source/stage. Repeated fence
/// calls validate that exact receipt's incarnation/generation under the STILL
/// CLOSED gate; they do not scan or prefix-exempt Core's file descriptors.
public actor RuntimeV2RecoveryClosureAuthority {
    public let domain: RuntimeV2MaintenanceDomain
    private let directory: URL
    private var receipt: RuntimeV2RecoveryClosedReceipt?

    public init(domain: RuntimeV2MaintenanceDomain, stateDirectory: URL) {
        self.domain = domain
        self.directory = stateDirectory.appendingPathComponent("closed-receipts", isDirectory: true)
    }

    public func beginRecovery(
        coordinator: RuntimeV2MaintenanceCoordinator, intentID: String, generation: UInt64
    ) async throws {
        // The Core worker has returned/closed before the real coordinator can
        // enter this session. Re-audit with a new durable receipt; never reuse a
        // prior-process or prior-owner generation as closure permission.
        try await coordinator.validateRecoverySession(intentID: intentID, holdGeneration: generation)
        receipt = nil
    }

    public func proveClosed(
        evidence: RuntimeV2MaintenanceOwnerEvidence,
        intent: RuntimeV2MaintenanceIntentRecord,
        coordinator: RuntimeV2MaintenanceCoordinator
    ) async throws -> RuntimeV2MaintenanceOwnerEvidence {
        guard coordinator.domain == domain else {
            throw RuntimeV2MaintenanceError.claimInvalidated("closure authority domain mismatch")
        }
        let recovering = await coordinator.isNativeRecoverySession(intentID: intent.intentID)
        if recovering {
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
        }
        guard evidence.isComplete, evidence.references.isComplete,
              !evidence.references.fingerprint.isEmpty,
              let registryFingerprint = evidence.filesystem.legacyRegistryFingerprint,
              !registryFingerprint.isEmpty, !evidence.filesystem.leaseRegistryUnmeasured else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["closure_sources_incomplete"])
        }
        let before = try RuntimeV2RecoveryAdmission.snapshot(root: domain.root)
        guard before.coverageComplete, before.liveUses == 0, before.intentID == intent.intentID else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["closure_native_admission_not_exclusive"])
        }
        let root = try RuntimeV2DiskIdentity.read(at: domain.root)
        guard root.device == intent.domainDevice, root.inode == intent.domainInode else {
            throw RuntimeV2MaintenanceError.claimInvalidated("closure root identity changed")
        }

        // Do not hide ANY live, unknown, queued, preparing or quarantined owner.
        // Only durable historical lease rows/sidecars are classified separately,
        // after native closure is proven. Original files/rows are never changed.
        var classified = evidence
        classified.filesystem.leaseEnvironmentIDs = []
        classified.integrator.leaseRegistryEnvironments = []
        let blockers = recovering ? Self.convergenceBlockers(classified, domain: domain)
            : classified.quiescenceBlockers(domain: domain)
        guard blockers.isEmpty else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(
                blockers)
        }

        let leases = evidence.filesystem.leaseEnvironmentIDs.sorted()
        let integratorMatches = evidence.integrator.storeRootPath.map {
            RuntimeV2RecoveryAdmission.key(URL(fileURLWithPath: $0)) == RuntimeV2RecoveryAdmission.key(domain.root)
        } ?? false
        let registryLeases = integratorMatches ? evidence.integrator.leaseRegistryEnvironments.sorted() : []
        if let current = receipt, current.intentID == intent.intentID,
           current.incarnation == before.incarnation {
            guard current.version == 1, current.domainKey == domain.domainKey,
                  current.isConvergenceProof == recovering,
                  current.rootDevice == root.device, current.rootInode == root.inode,
                  current.sourceGeneration == before.sourceGeneration,
                  current.holdGeneration == intent.holdGeneration,
                  current.legacyRegistryFingerprint == registryFingerprint,
                  current.historicalLeaseEnvironmentIDs == leases,
                  current.historicalRegistryLeaseEnvironmentIDs == registryLeases else {
                throw RuntimeV2MaintenanceError.claimInvalidated("native closure generation changed")
            }
            return classified
        }

        let measured = try Self.auditDescriptors(domain: domain, selected: intent.targetIdentity)
        let after = try RuntimeV2RecoveryAdmission.snapshot(root: domain.root)
        guard before == after else {
            throw RuntimeV2MaintenanceError.claimInvalidated("native admission changed during closure audit")
        }
        let measuredReceipt = RuntimeV2RecoveryClosedReceipt(
            version: 1, proofID: UUID().uuidString, isConvergenceProof: recovering,
            domainKey: domain.domainKey, rootDevice: root.device, rootInode: root.inode,
            incarnation: before.incarnation, sourceGeneration: before.sourceGeneration,
            intentID: intent.intentID, holdGeneration: intent.holdGeneration,
            historicalLeaseEnvironmentIDs: leases,
            historicalRegistryLeaseEnvironmentIDs: registryLeases,
            ownerEvidenceFingerprint: evidence.fingerprint(domain: domain),
            legacyRegistryFingerprint: registryFingerprint,
            inspectedDescriptorSlots: measured.slots, readOnlyMetadataDescriptors: measured.metadata)
        // Durable receipt BEFORE classifying the lease files as historical.
        try RuntimeV2OptimizationJournalIO.writeOnce(
            measuredReceipt, directory: directory,
            name: "closure-" + intent.intentID + "-" + measuredReceipt.proofID + ".json")
        receipt = measuredReceipt
        return classified
    }

    /// New references can wait for this very barrier. They must block NEW
    /// optimization, but cannot prevent exact S/T terminal convergence forever.
    /// Preserve/refresh the complete reference snapshot and its fingerprint;
    /// ignore only future-reference busy counts for this check. Native owner,
    /// quarantine, FD, registry, unknown-source and completeness gates remain.
    static func convergenceBlockers(
        _ evidence: RuntimeV2MaintenanceOwnerEvidence, domain: RuntimeV2MaintenanceDomain
    ) -> [String] {
        var native = evidence
        native.references.activeEnvironmentIDs = []
        native.references.unknownEnvironmentIDs = []
        native.references.unattributedActiveCount = 0
        native.references.unattributedLiveUnknownCount = 0
        return native.quiescenceBlockers(domain: domain)
    }

    public func currentReceipt(intentID: String) throws -> RuntimeV2RecoveryClosedReceipt {
        guard let receipt, receipt.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("no exact native closure receipt")
        }
        let now = try RuntimeV2RecoveryAdmission.snapshot(root: domain.root)
        guard now.intentID == receipt.intentID, now.incarnation == receipt.incarnation,
              now.sourceGeneration == receipt.sourceGeneration, now.liveUses == 0,
              now.coverageComplete else {
            throw RuntimeV2MaintenanceError.claimInvalidated("native closure receipt invalidated")
        }
        return receipt
    }

    private static func auditDescriptors(
        domain: RuntimeV2MaintenanceDomain, selected: RuntimeV2DiskIdentity?
    ) throws -> (slots: Int, metadata: Int) {
        #if canImport(Darwin)
        let maximumSlots = 16_384
        let maximumSeconds: TimeInterval = 3
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur > 0 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_table_bound_unknown"])
        }
        let started = ProcessInfo.processInfo.systemUptime
        // A high process limit is common on macOS and in Simulator. The kernel's
        // descriptor directory enumerates open slots even when their numbers are sparse.
        let descriptors: [Int32]
        if limit.rlim_cur > UInt64(maximumSlots) {
            descriptors = try openDescriptors(maximum: maximumSlots, deadline: started + maximumSeconds)
        } else {
            descriptors = Array(0..<Int32(limit.rlim_cur))
        }
        let prefix = RuntimeV2RecoveryAdmission.key(domain.root) + "/"
        var metadata = 0
        for fd in descriptors {
            guard ProcessInfo.processInfo.systemUptime - started < maximumSeconds else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_audit_time_budget"])
            }
            var info = stat()
            if fstat(fd, &info) != 0 {
                if errno == EBADF { continue }
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_identity_unknown"])
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0 else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_flags_unknown"])
            }
            var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = pathBytes.withUnsafeMutableBufferPointer {
                fcntl(fd, F_GETPATH, $0.baseAddress!)
            }
            guard result == 0 else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_path_unknown"])
            }
            var second = stat()
            guard fstat(fd, &second) == 0, second.st_dev == info.st_dev,
                  second.st_ino == info.st_ino, second.st_mode == info.st_mode else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_instance_changed"])
            }
            // Physical identity catches a selected-disk alias/hard link even
            // when its displayed path is outside the legacy tree.
            if let selected,
               UInt64(bitPattern: Int64(info.st_dev)) == selected.device,
               UInt64(info.st_ino) == selected.inode {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["selected_disk_fd_open"])
            }
            let path = String(cString: pathBytes)
            let canonical = RuntimeV2RecoveryAdmission.key(URL(fileURLWithPath: path))
            guard canonical.hasPrefix(prefix) || canonical + "/" == prefix else { continue }
            if kind == S_IFDIR, flags & O_ACCMODE == O_RDONLY {
                metadata += 1; continue
            }
            let leaf = URL(fileURLWithPath: canonical).lastPathComponent
            let metadataNames: Set<String> = [
                "lease.json", "metadata.json", "runtime.json",
                "repair-hold.json", "repair-hold.generation", "layout.json"
            ]
            if kind == S_IFREG, flags & O_ACCMODE == O_RDONLY,
               info.st_size >= 0, info.st_size <= 16_384, metadataNames.contains(leaf) {
                metadata += 1; continue
            }
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_native_fd_still_open"])
        }
        return (descriptors.count, metadata)
        #else
        throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_audit_unsupported"])
        #endif
    }

    #if canImport(Darwin)
    private static func openDescriptors(maximum: Int, deadline: TimeInterval) throws -> [Int32] {
        let incomplete = RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_table_bound_unknown"])
        guard let directory = opendir("/dev/fd") else { throw incomplete }
        defer { closedir(directory) }
        var result: [Int32] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0, result.contains(dirfd(directory)) else { throw incomplete }
                return result
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            guard let fd = Int32(name), fd >= 0, result.count < maximum else { throw incomplete }
            result.append(fd)
        }
        throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fd_audit_time_budget"])
    }
    #endif
}

// Small service-owned receipts live OUTSIDE maintained bytes. No enumeration,
// content export, unbounded read or overwrite of an unknown existing receipt.
enum RuntimeV2OptimizationJournalIO {
    static func writeOnce<T: Encodable>(_ value: T, directory: URL, name: String) throws {
        #if canImport(Darwin)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 65_536, safeName(name) else {
            throw StorageSparseDiskRewriteError.invalidRequest("receipt-bound")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw StorageSparseDiskRewriteError.directoryOpenFailed(errno: errno) }
        defer { close(dir) }
        if let existing = try readData(directory: directory, name: name) {
            guard existing == data else { throw StorageSparseDiskRewriteError.journalConflict("service-receipt") }
            return
        }
        let temporary = "." + UUID().uuidString + ".tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw StorageSparseDiskRewriteError.journalWriteFailed(errno: errno) }
        defer { close(fd); _ = unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageSparseDiskRewriteError.journalWriteFailed(errno: errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw StorageSparseDiskRewriteError.fsyncFailed(errno: errno) }
        guard renameatx_np(dir, temporary, dir, name, UInt32(RENAME_EXCL)) == 0 else {
            throw StorageSparseDiskRewriteError.journalWriteFailed(errno: errno)
        }
        guard fsync(dir) == 0 else { throw StorageSparseDiskRewriteError.fsyncFailed(errno: errno) }
        #else
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }

    static func read<T: Decodable>(_ type: T.Type, directory: URL, name: String) throws -> T? {
        guard let data = try readData(directory: directory, name: name) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 200
            && !name.contains("/") && !name.utf8.contains(0)
    }

    private static func readData(directory: URL, name: String) throws -> Data? {
        #if canImport(Darwin)
        guard safeName(name) else { throw StorageSparseDiskRewriteError.invalidRequest("receipt-name") }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dir < 0 {
            if errno == ENOENT { return nil }
            throw StorageSparseDiskRewriteError.directoryOpenFailed(errno: errno)
        }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw StorageSparseDiskRewriteError.journalOpenFailed(errno: errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 65_536 else {
            throw StorageSparseDiskRewriteError.journalCorrupt("service-receipt-bound")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageSparseDiskRewriteError.journalCorrupt("service-receipt-read") }
            offset += count
        }
        var second = stat()
        guard fstat(fd, &second) == 0, second.st_dev == info.st_dev,
              second.st_ino == info.st_ino, second.st_size == info.st_size,
              second.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              second.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              second.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              second.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
            throw StorageSparseDiskRewriteError.journalCorrupt("service-receipt-changed")
        }
        return Data(bytes)
        #else
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }
}
