// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Qualification seam

/// Bounds used by `RGSSGuestSaveStore`. Production always uses `.standard`;
/// the qualification initializer may only lower the values, never raise them.
struct RGSSGuestSaveLimitsOverride: Sendable, Equatable {
    let maximumFiles: Int
    let maximumFileBytes: Int
    let maximumTotalBytes: Int

    static let standard = RGSSGuestSaveLimitsOverride(
        uncheckedFiles: RGSSGuestSaveLimits.maximumFiles,
        fileBytes: RGSSGuestSaveLimits.maximumFileBytes,
        totalBytes: RGSSGuestSaveLimits.maximumTotalBytes)

    init(maximumFiles: Int, maximumFileBytes: Int, maximumTotalBytes: Int) throws {
        guard (1...RGSSGuestSaveLimits.maximumFiles).contains(maximumFiles),
              (1...RGSSGuestSaveLimits.maximumFileBytes).contains(maximumFileBytes),
              maximumTotalBytes >= maximumFileBytes,
              maximumTotalBytes <= RGSSGuestSaveLimits.maximumTotalBytes else {
            throw RGSSGuestRunError.invalidRequest("save limits override")
        }
        self.maximumFiles = maximumFiles
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    private init(uncheckedFiles: Int, fileBytes: Int, totalBytes: Int) {
        self.maximumFiles = uncheckedFiles
        self.maximumFileBytes = fileBytes
        self.maximumTotalBytes = totalBytes
    }
}

/// Named interruption points used by the focused regression sources. Production
/// stores pass `.none`; the hook is not an execution or scripting facility.
enum RGSSGuestSaveFailpoint: String, Sendable, Equatable {
    case stagingComplete
    case beforeCommit
    case backupMoved
    case newInstalled
    case commitComplete
    case renameLinked
}

/// Deliberately not an `RGSSGuestRunError`: tests throw it to simulate process
/// death, so the transaction must leave its journal and partial bytes in place
/// instead of performing an in-process rollback.
struct RGSSGuestSaveInjectedCrash: Error {}

/// A non-crash injected I/O failure. The transaction performs a real rollback.
struct RGSSGuestSaveInjectedIOFailure: Error {}

struct RGSSGuestSaveTransactionHooks: Sendable {
    var failpoint: (@Sendable (RGSSGuestSaveFailpoint, String) throws -> Void)?
    var availableBytes: (@Sendable (URL) throws -> Int64?)?

    static let none = RGSSGuestSaveTransactionHooks()

    init(failpoint: (@Sendable (RGSSGuestSaveFailpoint, String) throws -> Void)? = nil,
         availableBytes: (@Sendable (URL) throws -> Int64?)? = nil) {
        self.failpoint = failpoint
        self.availableBytes = availableBytes
    }

    func hit(_ point: RGSSGuestSaveFailpoint, name: String = "") throws {
        guard let failpoint else { return }
        try failpoint(point, name)
    }

    func freeBytes(at url: URL) -> Int64? {
        if let availableBytes { return try? availableBytes(url) }
        return RGSSGuestSaveFileOps.availableBytes(atPath: url.path)
    }
}

// MARK: - Control directory and cross-process lock

/// BSD `flock` locks are on files, not descriptors, so two independent store
/// instances in the same process can convert the same lock instead of waiting.
/// This small per-path NSLock serializes those instances first; the following
/// `flock` serializes other processes. Every public store operation uses both.
private final class RGSSGuestSaveProcessLockRegistry: @unchecked Sendable {
    static let shared = RGSSGuestSaveProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSLock()
        locks[path] = created
        return created
    }
}

/// The lock and journal live beside the owned save root, never inside it. A
/// save root replacement or a hostile entry inside the root therefore cannot
/// invalidate the lock identity. The directory name includes the canonical
/// root path digest, so two save layers in the same parent never share a lock.
struct RGSSGuestSaveControl: Sendable {
    static let directoryName = ".floe-rgss-save-control"

    let directory: URL
    let transactions: URL
    let backups: URL
    let lockFile: URL

    init(root: URL) throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path != "/", !canonical.lastPathComponent.isEmpty else {
            throw RGSSGuestRunError.saveLayerViolation("invalid save layer root")
        }
        let parent = canonical.deletingLastPathComponent()
        let digest = String(GameDigest.sha256(Data(canonical.path.utf8)).prefix(24))
        let base = parent.appendingPathComponent(Self.directoryName, isDirectory: true)
        let directory = base.appendingPathComponent(digest, isDirectory: true)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(base.path)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(directory.path)
        let transactions = directory.appendingPathComponent("transactions", isDirectory: true)
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(transactions.path)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(backups.path)
        self.directory = directory
        self.transactions = transactions
        self.backups = backups
        self.lockFile = directory.appendingPathComponent("lock")
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let processLock = RGSSGuestSaveProcessLockRegistry.shared.lock(for: lockFile.path)
        processLock.lock()
        defer { processLock.unlock() }
        let descriptor = open(lockFile.path,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw RGSSGuestRunError.saveLayerViolation("cannot open the save layer lock")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw RGSSGuestRunError.saveLayerViolation("save layer lock is not a regular file")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw RGSSGuestRunError.saveLayerViolation("cannot lock the save layer")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try body()
    }

    func makeTransactionDirectory() throws -> (id: UUID, url: URL) {
        let id = UUID()
        let url = transactions.appendingPathComponent(id.uuidString.lowercased(),
                                                      isDirectory: true)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(url.path)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(
            url.appendingPathComponent("new", isDirectory: true).path)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(
            url.appendingPathComponent("old", isDirectory: true).path)
        return (id, url)
    }

    func transactionDirectories() throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: transactions.path)
        var result: [URL] = []
        for name in names.sorted() {
            guard UUID(uuidString: name) != nil else {
                if name.hasPrefix(".") { continue }
                throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                    "unrecognized entry in the save transaction directory: \(name)")
            }
            let url = transactions.appendingPathComponent(name, isDirectory: true)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                    "save transaction entry is not a directory: \(name)")
            }
            result.append(url)
        }
        return result
    }

    /// Bounded raw replacement backup. The directory is outside the save root
    /// so it is never staged into a game run and never treated as a save.
    func makeBackupDirectory() throws -> RGSSGuestSaveRawBackup {
        let id = UUID()
        let url = backups.appendingPathComponent(id.uuidString.lowercased(),
                                                 isDirectory: true)
        try RGSSGuestSaveFileOps.ensurePrivateDirectory(url.path)
        return RGSSGuestSaveRawBackup(id: id, url: url)
    }

    func pruneBackups(keeping keep: URL, maximum: Int = 8) {
        guard maximum > 0 else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: [.contentModificationDateKey,
                                                      .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        var directories: [(url: URL, date: Date)] = []
        for entry in entries where entry.standardizedFileURL != keep.standardizedFileURL {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey,
                                                                  .contentModificationDateKey]),
                  values.isDirectory == true else { continue }
            directories.append((url: entry, date: values.contentModificationDate ?? .distantPast))
        }
        guard directories.count >= maximum else { return }
        directories.sort { $0.date < $1.date }
        let removeCount = directories.count - maximum + 1
        for entry in directories.prefix(removeCount) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}

// MARK: - Journal

struct RGSSGuestSaveJournal: Codable, Sendable {
    static let format = "floe-rgss-save-transaction"
    static let version = 1

    struct Entry: Codable, Sendable {
        let name: String
        let newSHA256: String
        let newBytes: Int
        let oldSHA256: String?
        let oldBytes: Int?
    }

    struct Inventory: Codable, Sendable, Equatable {
        let name: String
        let bytes: Int
        let sha256: String
    }

    let format: String
    let version: Int
    let transactionID: String
    let rootPath: String
    let engine: GameEngineID
    let operation: String
    let createdAt: Date
    let entries: [Entry]
    let preservedNames: [String]
    let before: [Inventory]
    let after: [Inventory]
}

/// Small public-safe manifest for one explicit raw replacement backup. The
/// backup directory sits in the transaction control area, never in the save
/// root, so it is not staged into a game run or listed as a save.
struct RGSSGuestSaveRawBackup: Sendable {
    let id: UUID
    let url: URL
}

struct RGSSGuestSaveRawBackupRecord: Sendable {
    let manifest: RGSSGuestSaveBackupManifest
    let directory: URL
}

struct RGSSGuestSaveBackupManifest: Codable, Sendable {
    static let format = "floe-rgss-save-backup"
    static let version = 1

    let format: String
    let version: Int
    let id: UUID
    let name: String
    let sha256: String
    let bytes: Int
    let createdAt: Date
}

// MARK: - POSIX helpers

enum RGSSGuestSaveFileOps {
    static func ensurePrivateDirectory(_ path: String) throws {
        if mkdir(path, 0o700) == 0 { return }
        guard errno == EEXIST else {
            throw RGSSGuestRunError.saveLayerViolation(
                "cannot create save control directory \(lastPath(path))")
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw RGSSGuestRunError.saveLayerViolation(
                "save control path is not a regular directory: \(lastPath(path))")
        }
    }

    static func writeExclusive(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw RGSSGuestRunError.saveLayerViolation("cannot stage \(lastPath(path))")
        }
        var closed = false
        defer { if !closed { close(descriptor) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = rgssTransactionWrite(descriptor,
                                                   raw.baseAddress!.advanced(by: offset),
                                                   raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw RGSSGuestRunError.saveLayerViolation("cannot write \(lastPath(path))")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RGSSGuestRunError.saveLayerViolation("cannot flush \(lastPath(path))")
        }
        close(descriptor)
        closed = true
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".floe-rgss-journal-" + UUID().uuidString)
        try writeExclusive(data, to: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw RGSSGuestRunError.saveLayerViolation("cannot replace the save journal")
        }
        syncDirectory(url.deletingLastPathComponent().path)
    }

    static func read(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RGSSGuestRunError.saveBytesMismatch(lastPath(path))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumBytes) else {
            throw RGSSGuestRunError.saveLimitExceeded(lastPath(path))
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            // Recovery and rollback must not stop between two byte moves because
            // the calling task was cancelled; the caller checks cancellation at
            // the explicit staging/pre-commit boundaries.
            let count = buffer.withUnsafeMutableBytes { raw in
                rgssTransactionRead(descriptor, raw.baseAddress!, raw.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RGSSGuestRunError.saveLayerViolation("cannot read \(lastPath(path))")
            }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else {
                throw RGSSGuestRunError.saveLimitExceeded(lastPath(path))
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }

    static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat()
        var right = stat()
        guard lstat(lhs, &left) == 0, lstat(rhs, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    static func move(_ from: String, to: String) throws {
        guard rename(from, to) == 0 else {
            throw RGSSGuestRunError.saveLayerViolation(
                "cannot move \(lastPath(from)) to \(lastPath(to))")
        }
    }

    static func remove(_ path: String) throws {
        guard unlink(path) == 0 || errno == ENOENT else {
            throw RGSSGuestRunError.saveLayerViolation("cannot remove \(lastPath(path))")
        }
    }

    static func removeTree(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RGSSGuestRunError.saveLayerViolation("save transaction is not a directory")
        }
        try FileManager.default.removeItem(at: url)
    }

    static func syncDirectory(_ path: String) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    static func availableBytes(atPath path: String) -> Int64? {
        var value = statvfs()
        guard statvfs(path, &value) == 0 else { return nil }
        let blocks = Int64(clamping: value.f_bavail)
        let size = Int64(clamping: value.f_frsize)
        guard blocks >= 0, size > 0, blocks <= Int64.max / size else { return nil }
        return blocks * size
    }

    static func lastPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

private func rgssTransactionRead(_ descriptor: Int32,
                                 _ buffer: UnsafeMutableRawPointer,
                                 _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
#else
    Glibc.read(descriptor, buffer, count)
#endif
}

private func rgssTransactionWrite(_ descriptor: Int32,
                                  _ buffer: UnsafeRawPointer,
                                  _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
#else
    Glibc.write(descriptor, buffer, count)
#endif
}

// MARK: - Store transaction internals

extension RGSSGuestSaveStore {
    /// Applies one or more complete saves as one recoverable transaction.
    /// Caller holds the exclusive save-layer lock.
    func applyPutsLocked(
        _ puts: [(name: String, data: Data)],
        operation: String,
        checkpointRevision: UInt64?,
        backupDirectory: URL?,
        rawBackupID: UUID? = nil
    ) throws -> RGSSGuestSaveMutationReceipt {
        guard !puts.isEmpty else {
            let inventory = try listLocked()
            return RGSSGuestSaveMutationReceipt(
                outcome: .alreadySatisfied, operation: operation, transactionID: nil,
                createdNames: [], replacedNames: [], removedNames: [],
                unchangedNames: [], preservedNames: inventory.map(\.name),
                inventory: inventory, checkpointRevision: checkpointRevision,
                backupDirectory: backupDirectory, rawBackupID: rawBackupID,
                message: nil)
        }
        var seen = Set<String>()
        for put in puts {
            guard RGSSGuestSaveLimits.isValidSaveName(put.name, engine: engine) else {
                throw RGSSGuestRunError.invalidSaveName(put.name)
            }
            guard put.data.count <= limits.maximumFileBytes else {
                throw RGSSGuestRunError.saveLimitExceeded(put.name)
            }
            guard seen.insert(put.name.lowercased()).inserted else {
                throw RGSSGuestRunError.saveDuplicateName(put.name)
            }
        }
        let before = try listLocked()
        var existingByName: [String: RGSSGuestSaveDescriptor] = [:]
        for descriptor in before { existingByName[descriptor.name] = descriptor }
        for put in puts {
            if let collision = before.first(where: {
                $0.name != put.name && $0.name.lowercased() == put.name.lowercased()
            }) {
                throw RGSSGuestRunError.saveDuplicateName("\(collision.name) / \(put.name)")
            }
        }
        var after: [String: RGSSGuestSaveDescriptor] = existingByName
        var changed: [(name: String, old: RGSSGuestSaveDescriptor?, data: Data)] = []
        var unchanged: [String] = []
        for put in puts {
            let digest = GameDigest.sha256(put.data)
            if let old = existingByName[put.name],
               old.sha256 == digest, old.bytes == put.data.count {
                unchanged.append(put.name)
                continue
            }
            changed.append((name: put.name, old: existingByName[put.name], data: put.data))
            after[put.name] = .init(name: put.name, bytes: put.data.count,
                                    sha256: digest, modifiedAt: Date())
        }
        let final = after.values.sorted { $0.name < $1.name }
        guard final.count <= limits.maximumFiles else {
            throw RGSSGuestRunError.saveLimitExceeded("save layer file count")
        }
        let finalBytes = final.reduce(0) { $0 + $1.bytes }
        guard finalBytes <= limits.maximumTotalBytes else {
            throw RGSSGuestRunError.saveLimitExceeded("save layer total bytes")
        }
        let requested = Set(puts.map { $0.name })
        let preserved = final.map(\.name).filter { !requested.contains($0) }
        if changed.isEmpty {
            return RGSSGuestSaveMutationReceipt(
                outcome: .alreadySatisfied, operation: operation, transactionID: nil,
                createdNames: [], replacedNames: [], removedNames: [],
                unchangedNames: unchanged, preservedNames: preserved,
                inventory: final, checkpointRevision: checkpointRevision,
                backupDirectory: backupDirectory, rawBackupID: rawBackupID,
                message: nil)
        }
        for entry in changed where entry.old == nil {
            guard !RGSSGuestSaveFileOps.exists(
                root.appendingPathComponent(entry.name).path) else {
                throw RGSSGuestRunError.saveDestinationExists(entry.name)
            }
        }
        let newBytes = changed.reduce(0) { $0 + $1.data.count }
        try requireAvailableBytes(newBytes + 262_144)

        let transaction = try control.makeTransactionDirectory()
        let newDirectory = transaction.url.appendingPathComponent("new", isDirectory: true)
        let oldDirectory = transaction.url.appendingPathComponent("old", isDirectory: true)
        var journalReady = false
        do {
            for entry in changed {
                try Task.checkCancellation()
                let staged = newDirectory.appendingPathComponent(entry.name)
                try RGSSGuestSaveFileOps.writeExclusive(entry.data, to: staged.path)
                let verified = try RGSSGuestSaveFileOps.read(
                    staged.path, maximumBytes: limits.maximumFileBytes)
                guard verified == entry.data,
                      GameDigest.sha256(verified) == GameDigest.sha256(entry.data) else {
                    throw RGSSGuestRunError.saveBytesMismatch(entry.name)
                }
            }
            try hooks.hit(.stagingComplete)
            let journal = RGSSGuestSaveJournal(
                format: RGSSGuestSaveJournal.format,
                version: RGSSGuestSaveJournal.version,
                transactionID: transaction.id.uuidString.lowercased(),
                rootPath: root.path,
                engine: engine,
                operation: operation,
                createdAt: Date(),
                entries: changed.map { entry in
                    RGSSGuestSaveJournal.Entry(
                        name: entry.name,
                        newSHA256: GameDigest.sha256(entry.data),
                        newBytes: entry.data.count,
                        oldSHA256: entry.old?.sha256,
                        oldBytes: entry.old?.bytes)
                },
                preservedNames: preserved,
                before: before.map {
                    RGSSGuestSaveJournal.Inventory(name: $0.name, bytes: $0.bytes,
                                                   sha256: $0.sha256)
                },
                after: final.map {
                    RGSSGuestSaveJournal.Inventory(name: $0.name, bytes: $0.bytes,
                                                   sha256: $0.sha256)
                })
            try writeJournal(journal, to: transaction.url)
            journalReady = true
            try hooks.hit(.beforeCommit)
            try Task.checkCancellation()

            for entry in changed where entry.old != nil {
                try RGSSGuestSaveFileOps.move(
                    root.appendingPathComponent(entry.name).path,
                    to: oldDirectory.appendingPathComponent(entry.name).path)
                RGSSGuestSaveFileOps.syncDirectory(root.path)
                try hooks.hit(.backupMoved, name: entry.name)
            }
            for entry in changed {
                let livePath = root.appendingPathComponent(entry.name).path
                guard !RGSSGuestSaveFileOps.exists(livePath) else {
                    throw RGSSGuestRunError.saveDestinationExists(entry.name)
                }
                try RGSSGuestSaveFileOps.move(
                    newDirectory.appendingPathComponent(entry.name).path,
                    to: livePath)
                RGSSGuestSaveFileOps.syncDirectory(root.path)
                try hooks.hit(.newInstalled, name: entry.name)
            }
            RGSSGuestSaveFileOps.syncDirectory(root.path)
            RGSSGuestSaveFileOps.syncDirectory(transaction.url.path)
            try hooks.hit(.commitComplete)
            // A committed marker makes cleanup failures deterministic: a later
            // recovery removes the transaction's backups instead of attempting
            // to roll back an already-committed live layer. Atomic placement
            // means a failed marker write cannot leave a misleading marker.
            try RGSSGuestSaveFileOps.atomicWrite(
                Data("committed\n".utf8),
                to: transaction.url.appendingPathComponent("COMMITTED"))
            try? RGSSGuestSaveFileOps.removeTree(transaction.url)
            // Do not re-read the layer after the irreversible commit point:
            // a cancelled task must still receive the truthful committed
            // inventory instead of throwing after the bytes changed.
            let inventory = final
            return RGSSGuestSaveMutationReceipt(
                outcome: .committed, operation: operation,
                transactionID: transaction.id,
                createdNames: changed.filter { $0.old == nil }.map { $0.name },
                replacedNames: changed.filter { $0.old != nil }.map { $0.name },
                removedNames: [], unchangedNames: unchanged,
                preservedNames: preserved, inventory: inventory,
                checkpointRevision: checkpointRevision,
                backupDirectory: backupDirectory, rawBackupID: rawBackupID,
                message: nil)
        } catch let crash as RGSSGuestSaveInjectedCrash {
            throw crash
        } catch {
            if journalReady {
                do {
                    try rollbackTransaction(at: transaction.url)
                    try? RGSSGuestSaveFileOps.removeTree(transaction.url)
                } catch {
                    throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                        "save transaction \(transaction.id.uuidString.lowercased()) "
                        + "could not be rolled back: \(String(describing: error))")
                }
            } else {
                try? RGSSGuestSaveFileOps.removeTree(transaction.url)
            }
            throw error
        }
    }

    func rollbackTransaction(at directory: URL) throws {
        let journal = try readJournal(at: directory)
        let oldDirectory = directory.appendingPathComponent("old", isDirectory: true)
        let newDirectory = directory.appendingPathComponent("new", isDirectory: true)
        var states: [String: RGSSGuestSaveJournalState] = [:]
        for entry in journal.entries {
            states[entry.name] = try classify(entry, oldDirectory: oldDirectory)
        }
        guard states.values.allSatisfy({ $0 != .ambiguous }) else {
            throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                "transaction \(journal.transactionID) has bytes that match neither "
                + "the old nor the new save inventory; no bytes were changed")
        }
        for entry in journal.entries {
            let live = root.appendingPathComponent(entry.name)
            let backup = oldDirectory.appendingPathComponent(entry.name)
            let staged = newDirectory.appendingPathComponent(entry.name)
            let state = states[entry.name]!
            if state == .new {
                if let oldSHA = entry.oldSHA256 {
                    guard RGSSGuestSaveFileOps.isRegularFile(backup.path),
                          GameDigest.sha256(try RGSSGuestSaveFileOps.read(
                            backup.path, maximumBytes: limits.maximumFileBytes)) == oldSHA else {
                        throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                            "transaction \(journal.transactionID) is missing the old bytes "
                            + "for \(entry.name)")
                    }
                    try RGSSGuestSaveFileOps.remove(live.path)
                    try RGSSGuestSaveFileOps.move(backup.path, to: live.path)
                } else {
                    try RGSSGuestSaveFileOps.remove(live.path)
                }
            } else if RGSSGuestSaveFileOps.isRegularFile(backup.path) {
                let backupDigest = GameDigest.sha256(try RGSSGuestSaveFileOps.read(
                    backup.path, maximumBytes: limits.maximumFileBytes))
                guard let oldSHA = entry.oldSHA256, backupDigest == oldSHA else {
                    throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                        "transaction \(journal.transactionID) has conflicting old bytes "
                        + "for \(entry.name)")
                }
                if RGSSGuestSaveFileOps.exists(live.path) {
                    // Live already holds the old bytes; the txn-owned backup is
                    // a duplicate and can be removed.
                    try RGSSGuestSaveFileOps.remove(backup.path)
                } else {
                    // The old file was moved aside and the new file was never
                    // installed; put the original bytes back.
                    try RGSSGuestSaveFileOps.move(backup.path, to: live.path)
                }
            } else if !RGSSGuestSaveFileOps.exists(live.path),
                      entry.oldSHA256 != nil {
                throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                    "transaction \(journal.transactionID) cannot restore \(entry.name): "
                    + "both the live file and its old-byte backup are missing")
            }
            if RGSSGuestSaveFileOps.exists(staged.path) {
                try RGSSGuestSaveFileOps.remove(staged.path)
            }
            RGSSGuestSaveFileOps.syncDirectory(root.path)
        }
    }

    func recoverTransaction(at directory: URL) throws {
        if RGSSGuestSaveFileOps.isRegularFile(
            directory.appendingPathComponent("COMMITTED").path) {
            // The marker is written only after every new file is installed and
            // the save root is synced. Cleanup is idempotent.
            try? RGSSGuestSaveFileOps.removeTree(directory)
            return
        }
        let journalURL = directory.appendingPathComponent("journal.json")
        guard RGSSGuestSaveFileOps.exists(journalURL.path) else {
            let oldDirectory = directory.appendingPathComponent("old", isDirectory: true)
            let oldNames = (try? FileManager.default.contentsOfDirectory(atPath: oldDirectory.path))
                ?? []
            if oldNames.isEmpty {
                try? RGSSGuestSaveFileOps.removeTree(directory)
                return
            }
            throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                "save transaction without a journal contains old-byte backups")
        }
        let journal: RGSSGuestSaveJournal
        do {
            journal = try readJournal(at: directory)
        } catch {
            // A journal is written before any live file is moved. If the
            // journal is unreadable and no old-byte backup exists, only the
            // transaction's private staging is present; removing it is safe.
            let oldDirectory = directory.appendingPathComponent("old", isDirectory: true)
            let oldNames = (try? FileManager.default.contentsOfDirectory(atPath: oldDirectory.path))
                ?? []
            if oldNames.isEmpty {
                try? RGSSGuestSaveFileOps.removeTree(directory)
                return
            }
            throw error
        }
        let oldDirectory = directory.appendingPathComponent("old", isDirectory: true)
        var states: [String: RGSSGuestSaveJournalState] = [:]
        for entry in journal.entries {
            states[entry.name] = try classify(entry, oldDirectory: oldDirectory)
        }
        if states.values.allSatisfy({ $0 == .new }) {
            // Every live byte is the committed value. Roll forward by removing
            // the transaction's own backups; live saves are not touched.
            try? RGSSGuestSaveFileOps.removeTree(directory)
            return
        }
        guard states.values.allSatisfy({ $0 != .ambiguous }) else {
            throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                "transaction \(journal.transactionID) has ambiguous save bytes; "
                + "all current bytes are preserved")
        }
        try rollbackTransaction(at: directory)
        try? RGSSGuestSaveFileOps.removeTree(directory)
    }

    func recoverPendingLocked() throws -> [UUID] {
        var recovered: [UUID] = []
        let directories = try control.transactionDirectories()
        for directory in directories {
            try recoverTransaction(at: directory)
            if let id = UUID(uuidString: directory.lastPathComponent) {
                recovered.append(id)
            }
        }
        return recovered
    }

    func writeJournal(_ journal: RGSSGuestSaveJournal, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(journal)
        guard data.count <= 1_048_576 else {
            throw RGSSGuestRunError.saveLayerViolation("save transaction journal is too large")
        }
        try RGSSGuestSaveFileOps.atomicWrite(
            data, to: directory.appendingPathComponent("journal.json"))
    }

    func readJournal(at directory: URL) throws -> RGSSGuestSaveJournal {
        let url = directory.appendingPathComponent("journal.json")
        let data: Data
        do {
            data = try RGSSGuestSaveFileOps.read(url.path, maximumBytes: 1_048_576)
        } catch {
            throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                "save transaction journal is unreadable")
        }
        let journal: RGSSGuestSaveJournal
        do {
            journal = try JSONDecoder().decode(RGSSGuestSaveJournal.self, from: data)
        } catch {
            throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                "save transaction journal is damaged")
        }
        guard journal.format == RGSSGuestSaveJournal.format,
              journal.version == RGSSGuestSaveJournal.version,
              journal.transactionID == directory.lastPathComponent,
              journal.rootPath == root.path,
              journal.engine == engine,
              journal.entries.count <= limits.maximumFiles else {
            throw RGSSGuestRunError.saveTransactionRecoveryRequired(
                "save transaction journal identity does not match this save layer")
        }
        return journal
    }

    enum RGSSGuestSaveJournalState: Sendable, Equatable {
        case old
        case new
        case ambiguous
    }

    func classify(_ entry: RGSSGuestSaveJournal.Entry,
                  oldDirectory: URL) throws -> RGSSGuestSaveJournalState {
        let live = root.appendingPathComponent(entry.name)
        let backup = oldDirectory.appendingPathComponent(entry.name)
        if RGSSGuestSaveFileOps.exists(live.path) {
            guard RGSSGuestSaveFileOps.isRegularFile(live.path),
                  !RGSSGuestSaveFileOps.isSymbolicLink(live.path) else {
                return .ambiguous
            }
            let digest = GameDigest.sha256(try RGSSGuestSaveFileOps.read(
                live.path, maximumBytes: limits.maximumFileBytes))
            if digest == entry.newSHA256 { return .new }
            if let oldSHA = entry.oldSHA256, digest == oldSHA { return .old }
            return .ambiguous
        }
        guard let oldSHA = entry.oldSHA256 else { return .old }
        guard RGSSGuestSaveFileOps.isRegularFile(backup.path),
              GameDigest.sha256(try RGSSGuestSaveFileOps.read(
                backup.path, maximumBytes: limits.maximumFileBytes)) == oldSHA else {
            return .ambiguous
        }
        return .old
    }

    /// Reads and validates one backup manifest without reading the save bytes.
    /// A directory whose name is not its manifest id is treated as corrupt.
    func readRawBackupManifestLocked(id: UUID) throws -> RGSSGuestSaveRawBackupRecord {
        let directory = control.backups.appendingPathComponent(
            id.uuidString.lowercased(), isDirectory: true)
        guard RGSSGuestSaveFileOps.isDirectory(directory.path),
              !RGSSGuestSaveFileOps.isSymbolicLink(directory.path) else {
            throw RGSSGuestRunError.saveRawBackupMissing(id)
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data: Data
        do {
            data = try RGSSGuestSaveFileOps.read(manifestURL.path, maximumBytes: 65_536)
        } catch {
            throw RGSSGuestRunError.saveRawBackupCorrupt(
                "backup \(id.uuidString.lowercased()) has no readable manifest")
        }
        let manifest: RGSSGuestSaveBackupManifest
        do {
            manifest = try JSONDecoder().decode(RGSSGuestSaveBackupManifest.self,
                                                from: data)
        } catch {
            throw RGSSGuestRunError.saveRawBackupCorrupt(
                "backup \(id.uuidString.lowercased()) manifest JSON is damaged")
        }
        guard manifest.format == RGSSGuestSaveBackupManifest.format,
              manifest.version == RGSSGuestSaveBackupManifest.version,
              manifest.id == id,
              RGSSGuestSaveLimits.isValidSaveName(manifest.name, engine: engine),
              manifest.bytes >= 0,
              manifest.bytes <= limits.maximumFileBytes,
              RGSSGuestSaveFileOps.isSHA256(manifest.sha256) else {
            throw RGSSGuestRunError.saveRawBackupCorrupt(
                "backup \(id.uuidString.lowercased()) manifest identity is invalid")
        }
        return RGSSGuestSaveRawBackupRecord(manifest: manifest, directory: directory)
    }

    func listRawBackupsLocked() throws -> [RGSSGuestSaveRawBackupDescriptor] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: control.backups.path)) ?? []
        var result: [RGSSGuestSaveRawBackupDescriptor] = []
        for name in names {
            guard let id = UUID(uuidString: name),
                  let record = try? readRawBackupManifestLocked(id: id) else { continue }
            result.append(RGSSGuestSaveRawBackupDescriptor(
                id: id, name: record.manifest.name,
                bytes: record.manifest.bytes,
                sha256: record.manifest.sha256,
                createdAt: record.manifest.createdAt))
        }
        result.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return result
    }

    func restoreRawBackupLocked(id: UUID,
                                expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        let record = try readRawBackupManifestLocked(id: id)
        let file = record.directory.appendingPathComponent(record.manifest.name)
        guard RGSSGuestSaveFileOps.isRegularFile(file.path),
              !RGSSGuestSaveFileOps.isSymbolicLink(file.path) else {
            throw RGSSGuestRunError.saveRawBackupCorrupt(
                "backup \(id.uuidString.lowercased()) file is missing")
        }
        let data: Data
        do {
            data = try RGSSGuestSaveFileOps.read(file.path,
                                                 maximumBytes: limits.maximumFileBytes)
        } catch {
            throw RGSSGuestRunError.saveRawBackupCorrupt(
                "backup \(id.uuidString.lowercased()) bytes are unreadable")
        }
        guard data.count == record.manifest.bytes,
              GameDigest.sha256(data) == record.manifest.sha256 else {
            throw RGSSGuestRunError.saveRawBackupCorrupt(
                "backup \(id.uuidString.lowercased()) bytes do not match the manifest")
        }
        let inventory = try listLocked()
        if let expectedSHA256 {
            guard let current = inventory.first(where: {
                $0.name == record.manifest.name
            }) else {
                throw RGSSGuestRunError.savePreconditionFailed(
                    "\(record.manifest.name) does not exist; expected \(expectedSHA256)")
            }
            guard current.sha256 == expectedSHA256 else {
                throw RGSSGuestRunError.savePreconditionFailed(
                    "\(record.manifest.name) changed; expected \(expectedSHA256), "
                    + "found \(current.sha256)")
            }
        }
        var safetyBackup: RGSSGuestSaveRawBackup?
        if let current = inventory.first(where: { $0.name == record.manifest.name }),
           current.sha256 != record.manifest.sha256 {
            let currentData = try RGSSGuestAtomicFile.read(
                root.appendingPathComponent(current.name),
                maximumBytes: limits.maximumFileBytes)
            guard GameDigest.sha256(currentData) == current.sha256 else {
                throw RGSSGuestRunError.saveBytesMismatch(current.name)
            }
            safetyBackup = try writeBackup(currentData, name: current.name,
                                           sha256: current.sha256)
        }
        let receipt = try applyPutsLocked(
            [(name: record.manifest.name, data: data)], operation: "restoreRawBackup",
            checkpointRevision: nil, backupDirectory: record.directory,
            rawBackupID: id)
        if let safetyBackup {
            control.pruneBackups(keeping: safetyBackup.url)
        }
        return receipt
    }

    func requireAvailableBytes(_ required: Int) throws {
        guard let available = hooks.freeBytes(at: root) else { return }
        guard available >= Int64(required) else {
            let clamped = available > Int64(Int.max) ? Int.max : Int(available)
            throw RGSSGuestRunError.saveInsufficientSpace(required: required,
                                                          available: clamped)
        }
    }
}
