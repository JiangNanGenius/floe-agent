// FloeCore — durable, atomic journal for one sparse-rewrite job.
//
// The journal is a service-owned JSON record in a caller-supplied directory.
// Every update is written to a fresh same-directory temporary name, fsynced,
// renamed over the exact job file, and followed by a directory fsync. Old
// bytes are never truncated in place. A crash can therefore leave either the
// previous complete record or the next complete record, never a spliced one.
//
// The record binds the source inode (S), stage inode (T), parent directory
// inode, exact relative path and job identifier. Recovery uses these inode
// bindings; it never assumes a filename is enough. No absolute path is ever
// placed in a public report or error message.

#if canImport(Darwin)
import Foundation
import Darwin
import Crypto

enum StorageSparseDiskRewritePhase: String, Codable, Sendable, Hashable {
    case intent
    case counting
    case staging
    case verified
    case swapIntent
    case swapped
    case rollbackIntent
    case committed
    case retired
    case aborted
    case failed
}

struct StorageSparseDiskRewriteJournalRecord: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var jobID: String
    var maintenanceLeaseID: String
    var holdGeneration: Int64
    var jobGeneration: UInt64
    var rootPath: String
    var relativePath: String
    var parentDevice: UInt64
    var parentInode: UInt64
    var source: StorageSparseDiskIdentity
    var stageName: String?
    var stage: StorageSparseDiskIdentity?
    var logicalBytes: Int64
    var requestedMode: StorageSparseDiskRewriteMode
    var modeUsed: StorageSparseDiskRewriteMode?
    var fallbackReason: String?
    var phase: StorageSparseDiskRewritePhase
    var sourceDigestSHA512: String?
    var stageDigestSHA512: String?
    var metadataFingerprint: String?
    var protectionClass: Int32?
    var skippedXattrNames: [String]
    var nonzeroBytes: Int64?
    var zeroBytes: Int64?
    var punchedBytes: Int64?
    var sourceAllocatedBytesBefore: Int64?
    var stageAllocatedBytesAtVerification: Int64?
    var retiredSourceAllocatedBytes: Int64?
    var volumeAvailableBytesBefore: Int64?
    var volumeAvailableBytesAtCommit: Int64?
    var volumeAvailableBytesAfter: Int64?
    var postSwapSource: StorageSparseDiskIdentity?
    var postSwapStage: StorageSparseDiskIdentity?
    var stageRetired: Bool
    var stageRetained: Bool
    var createdAtMilliseconds: Int64
    var updatedAtMilliseconds: Int64
    var lastError: String?
    var resolution: String?

    init(
        jobID: String,
        maintenanceLeaseID: String,
        holdGeneration: Int64,
        jobGeneration: UInt64,
        rootPath: String,
        relativePath: String,
        parentDevice: UInt64,
        parentInode: UInt64,
        source: StorageSparseDiskIdentity,
        stageName: String,
        logicalBytes: Int64,
        requestedMode: StorageSparseDiskRewriteMode,
        protectionClass: Int32?,
        skippedXattrNames: [String],
        nowMilliseconds: Int64
    ) {
        self.schemaVersion = 2
        self.jobID = jobID
        self.maintenanceLeaseID = maintenanceLeaseID
        self.holdGeneration = holdGeneration
        self.jobGeneration = jobGeneration
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.parentDevice = parentDevice
        self.parentInode = parentInode
        self.source = source
        self.stageName = stageName
        self.stage = nil
        self.logicalBytes = logicalBytes
        self.requestedMode = requestedMode
        self.modeUsed = nil
        self.fallbackReason = nil
        self.phase = .intent
        self.sourceDigestSHA512 = nil
        self.stageDigestSHA512 = nil
        self.metadataFingerprint = nil
        self.protectionClass = protectionClass
        self.skippedXattrNames = skippedXattrNames
        self.nonzeroBytes = nil
        self.zeroBytes = nil
        self.punchedBytes = nil
        self.sourceAllocatedBytesBefore = nil
        self.stageAllocatedBytesAtVerification = nil
        self.retiredSourceAllocatedBytes = nil
        self.volumeAvailableBytesBefore = nil
        self.volumeAvailableBytesAtCommit = nil
        self.volumeAvailableBytesAfter = nil
        self.postSwapSource = nil
        self.postSwapStage = nil
        self.stageRetired = false
        self.stageRetained = false
        self.createdAtMilliseconds = nowMilliseconds
        self.updatedAtMilliseconds = nowMilliseconds
        self.lastError = nil
        self.resolution = nil
    }
}

enum StorageSparseDiskJournalCoding {
    static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000.0).rounded(.down))
    }

    static func encode(_ record: StorageSparseDiskRewriteJournalRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> StorageSparseDiskRewriteJournalRecord {
        let decoder = JSONDecoder()
        let record: StorageSparseDiskRewriteJournalRecord
        do {
            record = try decoder.decode(StorageSparseDiskRewriteJournalRecord.self, from: data)
        } catch {
            throw StorageSparseDiskRewriteError.journalCorrupt("decode")
        }
        guard record.schemaVersion == 2 else {
            throw StorageSparseDiskRewriteError.journalCorrupt("schema")
        }
        return record
    }
}

/// One open journal directory. All journal file operations are relative to
/// this fd; no absolute path is re-resolved after admission.
final class StorageSparseDiskRewriteJournalHandle {
    let directoryFD: Int32
    let jobID: String
    private let fileName: String
    private var closed = false

    init(directoryURL: URL, jobID: String) throws {
        try StorageSparseDiskPOSIX.validateJobID(jobID)
        let fd = try StorageSparseDiskPOSIX.openDirectory(directoryURL)
        self.directoryFD = fd
        self.jobID = jobID
        self.fileName = jobID + ".json"
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(directoryFD)
    }

    /// Read the durable record, or nil when this job has no journal file.
    func read() throws -> StorageSparseDiskRewriteJournalRecord? {
        let fd = fileName.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw StorageSparseDiskRewriteError.journalOpenFailed(errno: code)
        }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw StorageSparseDiskRewriteError.journalOpenFailed(errno: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw StorageSparseDiskRewriteError.journalCorrupt("not-regular")
        }
        guard info.st_size > 0, info.st_size <= 1_048_576 else {
            throw StorageSparseDiskRewriteError.journalCorrupt("size")
        }
        let data = try StorageSparseDiskPOSIX.readAll(fd: fd, maxBytes: 1_048_576)
        return try StorageSparseDiskJournalCoding.decode(data)
    }

    /// Create the first record with O_EXCL. An existing job file is never
    /// overwritten by a new operation; the caller must run recovery first.
    func create(_ record: StorageSparseDiskRewriteJournalRecord) throws {
        let fd = fileName.withCString {
            openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fd >= 0 else {
            let code = errno
            if code == EEXIST {
                throw StorageSparseDiskRewriteError.journalExists(jobID)
            }
            throw StorageSparseDiskRewriteError.journalOpenFailed(errno: code)
        }
        var succeeded = false
        defer {
            _ = Darwin.close(fd)
            if !succeeded {
                _ = fileName.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }
        let data = try StorageSparseDiskJournalCoding.encode(record)
        try StorageSparseDiskPOSIX.writeAll(fd: fd, data: data)
        try StorageSparseDiskPOSIX.fsyncFD(fd)
        try StorageSparseDiskPOSIX.fsyncDirectory(directoryFD)
        succeeded = true
    }

    /// Atomically replace the record. The temp name is exact-job-scoped and
    /// created O_EXCL; cleanup only ever removes that temp name.
    func update(_ record: StorageSparseDiskRewriteJournalRecord) throws {
        var updated = record
        updated.updatedAtMilliseconds = StorageSparseDiskJournalCoding.nowMilliseconds()
        let data = try StorageSparseDiskJournalCoding.encode(updated)
        let tempName = fileName + ".tmp-" + StorageSparseDiskPOSIX.randomHexToken()
        let fd = tempName.withCString {
            openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fd >= 0 else {
            throw StorageSparseDiskRewriteError.journalOpenFailed(errno: errno)
        }
        var renamed = false
        defer {
            _ = Darwin.close(fd)
            if !renamed {
                _ = tempName.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }
        try StorageSparseDiskPOSIX.writeAll(fd: fd, data: data)
        try StorageSparseDiskPOSIX.fsyncFD(fd)
        let result = tempName.withCString { temp in
            fileName.withCString { final in
                renameat(directoryFD, temp, directoryFD, final)
            }
        }
        guard result == 0 else {
            throw StorageSparseDiskRewriteError.journalWriteFailed(errno: errno)
        }
        try StorageSparseDiskPOSIX.fsyncDirectory(directoryFD)
        renamed = true
    }
}

#endif
