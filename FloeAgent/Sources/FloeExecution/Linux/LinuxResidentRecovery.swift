// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Receipt for an explicitly requested fresh resident environment. A retained
/// directory is a recovery copy, never a cache or an automatic deletion target.
public struct LinuxResidentRecoveryReceipt: Codable, Equatable, Sendable {
    public var recoveryID: UUID
    public var imageID: String
    public var preservedRelativePath: String?
    public var environmentIDs: [String]
    public var runtimeGeneration: String { LinuxResidentRuntimeGeneration.value(recoveryID: recoveryID) }

    public init(recoveryID: UUID, imageID: String, preservedRelativePath: String?, environmentIDs: [String] = []) {
        self.recoveryID = recoveryID
        self.imageID = imageID
        self.preservedRelativePath = preservedRelativePath
        self.environmentIDs = environmentIDs
    }
}

/// Native-only admission guard held through an explicit task-pin CAS. It
/// prevents another physical rebuild from changing the confirmed generation
/// between verification and database commit. It grants no tool permission.
public final class LinuxResidentRecoveryGuard: @unchecked Sendable {
    public let receipt: LinuxResidentRecoveryReceipt?
    private let lock = NSLock()
    private var descriptor: Int32
    init(receipt: LinuxResidentRecoveryReceipt?, descriptor: Int32) {
        self.receipt = receipt; self.descriptor = descriptor
    }
    public func finish() {
        let fd = lock.withLock { let value = descriptor; descriptor = -1; return value }
        if fd >= 0 { _ = close(fd) }
    }
    deinit { finish() }
}

enum LinuxResidentRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case busy, invalidStorage, interrupted, identityChanged, persistence, unsupported

    var errorDescription: String? {
        let zh = FloeL10n.isChinese
        switch self {
        case .busy:
            return zh ? "运行环境仍在使用中，请稍后重试。已有资料已保留。" : "The runtime is still in use. Try again later. Existing data was kept."
        case .invalidStorage, .identityChanged:
            return zh ? "无法安全恢复运行环境，已有资料已保留。" : "The runtime could not be recovered safely. Existing data was kept."
        case .interrupted, .persistence:
            return zh ? "环境恢复尚未完成，请重试。已有资料已保留。" : "Runtime recovery is incomplete. Try again. Existing data was kept."
        case .unsupported:
            return zh ? "当前设备暂不支持保留资料重建环境。" : "Rebuilding while retaining data is unavailable on this device."
        }
    }
}

/// One lock domain for the ONE physical resident disk. It is not the legacy
/// Runtime-v2 maintenance authority. Every factory holds an exclusive use FD
/// before preparing/opening a disk, until its actual machine worker has joined.
/// A process-wide strong retainer deliberately leaks an unclosed claim instead
/// of releasing it when an owner disappears without proving worker shutdown.
enum LinuxResidentDiskBarrier {
    private final class Retainer: @unchecked Sendable {
        let lock = NSLock()
        var claims: [UUID: Use] = [:]
        func retain(_ use: Use) { lock.withLock { claims[use.id] = use } }
        func remove(_ id: UUID) { _ = lock.withLock { claims.removeValue(forKey: id) } }
    }
    private static let retainer = Retainer()

    final class Use: @unchecked Sendable {
        fileprivate let id = UUID()
        private let lock = NSLock()
        private var descriptor: Int32
        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        /// Called only before a machine exists, or after machine.stop() has
        /// returned .stopped. A timeout/failed join must retain this claim.
        func releaseAfterConfirmedClose() {
            let fd = lock.withLock { let value = descriptor; descriptor = -1; return value }
            if fd >= 0 { _ = close(fd) }
            LinuxResidentDiskBarrier.retainer.remove(id)
        }
    }

    static func withExclusiveAccess<T>(root: URL, _ body: () throws -> T) throws -> T {
        let store = try LinuxResidentRecoveryStore(root: root)
        let gate = try store.lockFile("admission.lock", operation: LOCK_EX | LOCK_NB)
        defer { _ = close(gate) }
        let disk = try store.lockFile("disk-use.lock", operation: LOCK_EX | LOCK_NB)
        defer { _ = close(disk) }
        _ = try store.recoverPending()
        return try body()
    }

    /// Service-owned reconciliation after a crash. A pending exchange may be
    /// converged only under physical exclusion; a running VM keeps that closed.
    /// Normal reads inspect only bounded sidecars and physical inode identity,
    /// never hash the intentionally mutable resident disk.
    /// Pending convergence never upgrades a held SH lock. Drop it first,
    /// acquire EX + the physical-use lock, converge, release, then take SH.
    /// A nested VM start under a tool's SH guard sees no pending intent and
    /// only takes another SH lock; it cannot deadlock on its own EX upgrade.
    private static func admissionRead(_ store: LinuxResidentRecoveryStore) throws -> Int32 {
        let pending = store.state.appendingPathComponent("pending.json")
        for _ in 0..<2 {
            let readGate = try store.lockFile("admission.lock", operation: LOCK_SH | LOCK_NB)
            do {
                if try LinuxResidentRecoveryStore.Node.read(pending) == nil { return readGate }
            } catch { _ = close(readGate); throw error }
            _ = close(readGate)
            let recoveryGate = try store.lockFile("admission.lock", operation: LOCK_EX | LOCK_NB)
            do {
                let disk = try store.lockFile("disk-use.lock", operation: LOCK_EX | LOCK_NB)
                defer { _ = close(disk) }
                _ = try store.recoverPending()
            } catch { _ = close(recoveryGate); throw error }
            _ = close(recoveryGate)
        }
        throw LinuxResidentRecoveryError.busy
    }

    static func acquireRecoveryGuard(root: URL) throws -> LinuxResidentRecoveryGuard {
        let store = try LinuxResidentRecoveryStore(root: root)
        let gate = try admissionRead(store)
        do { return LinuxResidentRecoveryGuard(receipt: try store.currentCommittedReceipt(), descriptor: gate) }
        catch { _ = close(gate); throw error }
    }

    static func currentRecoveryReceipt(root: URL) throws -> LinuxResidentRecoveryReceipt? {
        let pending = root.appendingPathComponent(".resident-recovery/pending.json")
        let origin = LinuxResidentDiskStorage.directory(in: root).appendingPathComponent(LinuxResidentDiskStorage.originFileName)
        guard try LinuxResidentRecoveryStore.Node.read(pending) != nil
            || LinuxResidentRecoveryStore.Node.read(origin) != nil else { return nil }
        let lease = try acquireRecoveryGuard(root: root)
        defer { lease.finish() }
        return lease.receipt
    }

    static func acquireUse(root: URL) throws -> Use {
        let store = try LinuxResidentRecoveryStore(root: root)
        let gate = try admissionRead(store)
        defer { _ = close(gate) }
        let disk = try store.lockFile("disk-use.lock", operation: LOCK_EX | LOCK_NB)
        let use = Use(descriptor: disk)
        retainer.retain(use)
        return use
    }

}

/// Small, fixed-path transaction for replacing the resident directory. No disk
/// contents are rewritten: RENAME_SWAP retains the old directory (same inode)
/// under recovery/<id>/previous. No deferred cleanup reaches that directory.
/// All methods run with admission and physical-disk exclusion held.
struct LinuxResidentRecoveryStore {
    struct Node: Codable, Equatable {
        var device: UInt64
        var inode: UInt64
        var mode: UInt32
        var size: Int64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64

        static func read(_ url: URL) throws -> Node? {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw LinuxResidentRecoveryError.invalidStorage
            }
            #if canImport(Darwin)
            let modified = info.st_mtimespec
            #else
            let modified = info.st_mtim
            #endif
            return Node(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                mode: UInt32(info.st_mode), size: Int64(info.st_size),
                modificationSeconds: Int64(modified.tv_sec), modificationNanoseconds: Int64(modified.tv_nsec))
        }
        var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
        var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
        func sameDirectory(as other: Node) -> Bool {
            isDirectory && other.isDirectory && device == other.device && inode == other.inode
        }
    }

    struct Tree: Codable, Equatable {
        var directory: Node
        var disk: Node?
        var origin: Node?
        static func read(_ url: URL) throws -> Tree? {
            guard let directory = try Node.read(url) else { return nil }
            guard directory.isDirectory else { throw LinuxResidentRecoveryError.invalidStorage }
            return Tree(directory: directory,
                disk: try Node.read(url.appendingPathComponent(LinuxResidentDiskStorage.diskFileName)),
                origin: try Node.read(url.appendingPathComponent(LinuxResidentDiskStorage.originFileName)))
        }
        func matches(_ other: Tree?) -> Bool {
            guard let other else { return false }
            return directory.sameDirectory(as: other.directory) && disk == other.disk && origin == other.origin
        }
    }

    enum Phase: String, Codable { case planned, prepared, swapped, committed, aborted }
    struct Record: Codable {
        var version = 1
        var id: UUID
        var imageID: String
        var createdAt: Date
        var phase: Phase = .planned
        var oldObserved = false
        var old: Tree?
        var fresh: Tree?
        var preservesInstalledSoftware = true
        var receipt: LinuxResidentRecoveryReceipt {
            .init(recoveryID: id, imageID: imageID,
                preservedRelativePath: old == nil ? nil : "recovery/\(id.uuidString.lowercased())/previous")
        }
    }
    private struct Pending: Codable { var version = 1; var id: UUID }

    enum Event: Sendable { case candidateDurable, beforeExchange, afterExchange, committedRecordWritten, beforePendingRemoval }
    struct Hooks: Sendable {
        var event: @Sendable (Event) throws -> Void = { _ in }
    }
    let hooks: Hooks
    let root: URL
    let state: URL
    let recovery: URL
    var current: URL { LinuxResidentDiskStorage.directory(in: root) }
    private var pending: URL { state.appendingPathComponent("pending.json") }

    init(root: URL, hooks: Hooks = .init()) throws {
        self.hooks = hooks
        self.root = root.standardizedFileURL
        state = self.root.appendingPathComponent(".resident-recovery", isDirectory: true)
        recovery = self.root.appendingPathComponent("recovery", isDirectory: true)
        try Self.ensureDirectory(self.root)
        try Self.ensureDirectory(state)
        try Self.ensureDirectory(recovery)
        // Walk the fixed resident path without following a child symlink.
        var cursor = self.root
        for component in [LinuxResidentDiskStorage.containerDirectoryName, "disks"] {
            cursor.appendPathComponent(component, isDirectory: true)
            try Self.ensureDirectory(cursor)
        }
    }

    private func operation(_ id: UUID) -> URL { recovery.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func index(_ id: UUID) -> URL { operation(id).appendingPathComponent("record.json") }
    private func previous(_ id: UUID) -> URL { operation(id).appendingPathComponent("previous", isDirectory: true) }

    func lockFile(_ name: String, operation: Int32) throws -> Int32 {
        let file = state.appendingPathComponent(name)
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LinuxResidentRecoveryError.invalidStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            _ = close(fd); throw LinuxResidentRecoveryError.invalidStorage
        }
        guard flock(fd, operation) == 0 else { _ = close(fd); throw LinuxResidentRecoveryError.busy }
        return fd
    }

    /// Acquires the admission fence before the owner awaits physical shutdown.
    /// The exclusive disk-use claim is acquired only after that shutdown joins.
    func begin(imageID: String) throws -> Transaction {
        guard !imageID.isEmpty, imageID.utf8.count <= 240,
              !imageID.contains("/"), !imageID.contains("\\"), !imageID.contains("\0") else {
            throw LinuxResidentRecoveryError.invalidStorage
        }
        let gate = try lockFile("admission.lock", operation: LOCK_EX | LOCK_NB)
        do {
            let hasPending = try Node.read(pending) != nil
            if !hasPending {
                let record = Record(id: UUID(), imageID: imageID, createdAt: Date())
                try Self.ensureDirectory(operation(record.id))
                try persist(record)
                try write(Pending(id: record.id), to: pending)
            }
            return Transaction(store: self, gate: gate, imageID: imageID, resumed: hasPending)
        } catch { _ = close(gate); throw error }
    }

    final class Transaction: @unchecked Sendable {
        private let store: LinuxResidentRecoveryStore
        private var gate: Int32
        private let imageID: String
        private let resumed: Bool
        fileprivate init(store: LinuxResidentRecoveryStore, gate: Int32, imageID: String, resumed: Bool) {
            self.store = store; self.gate = gate; self.imageID = imageID; self.resumed = resumed
        }
        deinit { endAdmission() }
        func endAdmission() {
            if gate >= 0 { _ = close(gate); gate = -1 }
        }

        /// The prepare closure is App-owned and uses the verified image
        /// preparer. It returns the fresh fixed disk directory inside build.
        func replace(onPhase: @Sendable (LinuxGuestImageTransferPhase) -> Void = { _ in },
                     prepare: (URL) throws -> URL) throws -> LinuxResidentRecoveryReceipt {
            let disk = try store.lockFile("disk-use.lock", operation: LOCK_EX | LOCK_NB)
            defer { _ = close(disk) }
            if resumed, let receipt = try store.recoverPending() { return receipt }
            var record: Record
            if let pointer: Pending = try store.read(Pending.self, from: store.pending) {
                record = try store.requiredRecord(pointer.id)
            } else {
                record = Record(id: UUID(), imageID: imageID, createdAt: Date())
                try LinuxResidentRecoveryStore.ensureDirectory(store.operation(record.id))
                try store.persist(record)
                try store.write(Pending(id: record.id), to: store.pending)
            }
            guard record.phase == .planned, record.imageID == imageID else {
                throw LinuxResidentRecoveryError.interrupted
            }
            record.old = try Tree.read(store.current)
            record.oldObserved = true
            try store.persist(record)
            do {
                try Task.checkCancellation()
                let build = store.operation(record.id).appendingPathComponent("build", isDirectory: true)
                try LinuxResidentRecoveryStore.ensureDirectory(build)
                onPhase(.creatingEnvironment)
                let fresh = try prepare(build)
                let expected = LinuxResidentDiskStorage.directory(in: build)
                guard fresh.standardizedFileURL == expected.standardizedFileURL else {
                    throw LinuxResidentRecoveryError.invalidStorage
                }
                try store.markCandidateOrigin(fresh, recoveryID: record.id, imageID: record.imageID)
                guard let tree = try Tree.read(fresh), tree.disk?.isRegular == true,
                      tree.origin?.isRegular == true else { throw LinuxResidentRecoveryError.invalidStorage }
                try LinuxResidentRecoveryStore.syncFile(fresh.appendingPathComponent(LinuxResidentDiskStorage.diskFileName), expected: tree.disk!)
                try LinuxResidentRecoveryStore.syncFile(fresh.appendingPathComponent(LinuxResidentDiskStorage.originFileName), expected: tree.origin!)
                try LinuxResidentRecoveryStore.syncDirectory(fresh)
                // Move only the newly prepared directory. It becomes the old
                // retained directory after the atomic exchange below.
                guard try Node.read(store.previous(record.id)) == nil,
                      rename(fresh.path, store.previous(record.id).path) == 0 else {
                    throw LinuxResidentRecoveryError.persistence
                }
                try LinuxResidentRecoveryStore.syncDirectory(fresh.deletingLastPathComponent())
                try LinuxResidentRecoveryStore.syncDirectory(store.operation(record.id))
                record.fresh = try Tree.read(store.previous(record.id))
                record.phase = .prepared
                try store.persist(record)
                try store.hooks.event(.candidateDurable)
                try Task.checkCancellation()
                let observed = try Tree.read(store.current)
                guard record.old.map({ $0.matches(observed) }) ?? (observed == nil) else {
                    throw LinuxResidentRecoveryError.identityChanged
                }
                if record.old != nil { onPhase(.retainingEnvironment) }
                try store.hooks.event(.beforeExchange)
                #if canImport(Darwin)
                let flags = record.old == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
                guard renameatx_np(AT_FDCWD, store.previous(record.id).path,
                    AT_FDCWD, store.current.path, flags) == 0 else {
                    throw LinuxResidentRecoveryError.persistence
                }
                #else
                throw LinuxResidentRecoveryError.unsupported
                #endif
                try store.hooks.event(.afterExchange)
                // No cancellation point after exchange. Finish the durable
                // receipt, or leave the durable fence for identity recovery.
                return try store.finishCommitted(&record)
            } catch {
                // A post-exchange error leaves the durable fence intact. Do
                // not immediately retry fsync/journal writes and conceal it.
                let observed = try Tree.read(store.current)
                let intact = record.old.map({ $0.matches(observed) }) ?? (record.oldObserved && observed == nil)
                if intact {
                    record.phase = .aborted
                    do { try store.persist(record); try store.clearPending() }
                    catch { throw LinuxResidentRecoveryError.interrupted }
                }
                throw error
            }
        }
    }

    /// Requires BOTH locks. Returns a committed receipt after an exchanged
    /// directory, or aborts an intact pre-exchange candidate. Never deletes a
    /// disk, recovery record, build directory, unknown replacement or sidecar.
    @discardableResult
    func recoverPending() throws -> LinuxResidentRecoveryReceipt? {
        guard let pointer: Pending = try read(Pending.self, from: pending) else { return nil }
        guard pointer.version == 1 else { throw LinuxResidentRecoveryError.interrupted }
        var record = try requiredRecord(pointer.id)
        let observed = try Tree.read(current)
        let retained = try Tree.read(previous(record.id))
        if let fresh = record.fresh, fresh.matches(observed),
           record.old.map({ $0.matches(retained) }) ?? (retained == nil) {
            return try finishCommitted(&record)
        }
        let oldStillCurrent = record.oldObserved
            ? (record.old.map({ $0.matches(observed) }) ?? (observed == nil))
            : (record.phase == .planned || record.phase == .aborted) && record.fresh == nil
        guard oldStillCurrent, [.planned, .prepared, .aborted].contains(record.phase),
              record.fresh.map({ $0.matches(retained) }) ?? true else {
            throw LinuxResidentRecoveryError.identityChanged
        }
        record.phase = .aborted
        try persist(record)
        try clearPending()
        return nil
    }

    private func finishCommitted(_ record: inout Record) throws -> LinuxResidentRecoveryReceipt {
        let observed = try Tree.read(current)
        let retained = try Tree.read(previous(record.id))
        guard let fresh = record.fresh, fresh.matches(observed),
              record.old.map({ $0.matches(retained) }) ?? (retained == nil) else {
            throw LinuxResidentRecoveryError.identityChanged
        }
        try Self.syncDirectory(current.deletingLastPathComponent())
        try Self.syncDirectory(operation(record.id))
        record.phase = .committed
        try persist(record)
        try hooks.event(.committedRecordWritten)
        try clearPending()
        return record.receipt
    }

    private func markCandidateOrigin(_ directory: URL, recoveryID: UUID, imageID: String) throws {
        let path = directory.appendingPathComponent(LinuxResidentDiskStorage.originFileName)
        guard var origin: LinuxGuestRuntimeDiskOrigin = try read(LinuxGuestRuntimeDiskOrigin.self, from: path),
              origin.imageID == imageID else { throw LinuxResidentRecoveryError.invalidStorage }
        origin.residentRecoveryID = recoveryID
        try write(origin, to: path)
    }

    /// A committed marker survives application restart and ordinary guest
    /// writes/growth. Only physical directory/disk identity is immutable;
    /// mtime and logical length deliberately change during actual use.
    func currentCommittedReceipt() throws -> LinuxResidentRecoveryReceipt? {
        guard let observed = try Tree.read(current) else { return nil }
        let path = current.appendingPathComponent(LinuxResidentDiskStorage.originFileName)
        guard let origin: LinuxGuestRuntimeDiskOrigin = try read(LinuxGuestRuntimeDiskOrigin.self, from: path),
              let id = origin.residentRecoveryID else { return nil }
        let record = try requiredRecord(id)
        guard record.phase == .committed, origin.imageID == record.imageID,
              let fresh = record.fresh,
              fresh.directory.sameDirectory(as: observed.directory),
              let originalDisk = fresh.disk, let currentDisk = observed.disk,
              originalDisk.isRegular, currentDisk.isRegular,
              originalDisk.device == currentDisk.device, originalDisk.inode == currentDisk.inode else {
            throw LinuxResidentRecoveryError.identityChanged
        }
        return record.receipt
    }

    private func requiredRecord(_ id: UUID) throws -> Record {
        guard let value: Record = try read(Record.self, from: index(id)),
              value.version == 1, value.id == id else { throw LinuxResidentRecoveryError.interrupted }
        return value
    }
    private func persist(_ record: Record) throws { try write(record, to: index(record.id)) }
    private func clearPending() throws {
        try hooks.event(.beforePendingRemoval)
        guard unlink(pending.path) == 0 else { throw LinuxResidentRecoveryError.persistence }
        try Self.syncDirectory(state)
    }
    private static func ensureDirectory(_ path: URL) throws {
        if let node = try Node.read(path) {
            guard node.isDirectory else { throw LinuxResidentRecoveryError.invalidStorage }
        } else {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            guard try Node.read(path)?.isDirectory == true else { throw LinuxResidentRecoveryError.invalidStorage }
            try syncDirectory(path)
            try syncDirectory(path.deletingLastPathComponent())
        }
    }
    private static func syncFile(_ url: URL, expected: Node) throws {
        let fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw LinuxResidentRecoveryError.persistence }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, UInt64(bitPattern: Int64(info.st_dev)) == expected.device,
              UInt64(info.st_ino) == expected.inode, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size == expected.size, fsync(fd) == 0 else {
            throw LinuxResidentRecoveryError.persistence
        }
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw LinuxResidentRecoveryError.persistence }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw LinuxResidentRecoveryError.persistence }
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw LinuxResidentRecoveryError.invalidStorage
        }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 64 * 1024 else {
            throw LinuxResidentRecoveryError.invalidStorage
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw LinuxResidentRecoveryError.invalidStorage }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw LinuxResidentRecoveryError.interrupted }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= 64 * 1024 else { throw LinuxResidentRecoveryError.persistence }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LinuxResidentRecoveryError.persistence }
        var closed = false
        defer { if !closed { _ = close(fd) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                #else
                let count = Glibc.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LinuxResidentRecoveryError.persistence }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw LinuxResidentRecoveryError.persistence }
        let status = close(fd); closed = true
        guard status == 0, rename(temporary.path, url.path) == 0 else { throw LinuxResidentRecoveryError.persistence }
        try Self.syncDirectory(url.deletingLastPathComponent())
    }
}
