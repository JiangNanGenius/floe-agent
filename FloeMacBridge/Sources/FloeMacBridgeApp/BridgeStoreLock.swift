#if os(macOS)
import Darwin
import Foundation

/// Cross-process single-owner guard for one Bridge data root.
///
/// The real mutual exclusion is `flock(LOCK_EX | LOCK_NB)` on a regular file
/// in `<root>/State/`. A PID file, a preflight digest or a source attestation
/// alone cannot prevent two service processes from writing the same pairing
/// store; this descriptor stays open for the life of the service and the
/// kernel releases it on exit or crash.
///
/// Legacy standalone Floe Bridge builds that predate this file do not acquire
/// the lock. Even port preflight cannot prevent an older copy starting later;
/// this cooperative lock alone does not establish legacy migration safety.
final class BridgeStoreLock: @unchecked Sendable {
    struct OwnerRecord: Codable, Equatable, Sendable {
        var schema: String
        var pid: Int32
        var parentPID: Int32
        var bundleIdentifier: String?
        var version: String?
        var build: String?
        var storeRoot: String
        var startedAt: String
    }

    let url: URL
    let root: URL
    private let lock = NSLock()
    private var descriptor: Int32
    private var owner: OwnerRecord
    private var released = false

    /// Acquire the store lock without modifying an existing pairing store.
    /// Only the lock file itself is created. If another process holds it, this
    /// throws and the caller must fail closed without reading or writing the
    /// Pair/Tasks/Workspaces state.
    init(root: URL, bundle: Bundle = .main) throws {
        let rootURL = root.standardizedFileURL
        let state = rootURL.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(
            at: state,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stateFD = open(state.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stateFD >= 0 else {
            throw BridgeStoreLockError.unsafeLocation(state.path)
        }
        defer { close(stateFD) }
        var openedState = stat()
        var currentState = stat()
        guard fstat(stateFD, &openedState) == 0, lstat(state.path, &currentState) == 0,
              (openedState.st_mode & S_IFMT) == S_IFDIR,
              (currentState.st_mode & S_IFMT) == S_IFDIR,
              openedState.st_uid == getuid(), (openedState.st_mode & 0o022) == 0,
              openedState.st_dev == currentState.st_dev, openedState.st_ino == currentState.st_ino else {
            throw BridgeStoreLockError.unsafeLocation(state.path)
        }
        let lockURL = state.appendingPathComponent("bridge-store.lock", isDirectory: false)
        let fd = openat(stateFD, "bridge-store.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else {
            throw BridgeStoreLockError.cannotOpen(lockURL.path, errno)
        }
        guard Self.isSafeLock(fd: fd, path: lockURL.path, stateFD: stateFD, statePath: state.path) else {
            close(fd)
            throw BridgeStoreLockError.unsafeLocation(lockURL.path)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let existing = Self.readOwner(descriptor: fd)
            close(fd)
            throw BridgeStoreLockError.alreadyOwned(existing)
        }
        guard Self.isSafeLock(fd: fd, path: lockURL.path, stateFD: stateFD, statePath: state.path) else {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw BridgeStoreLockError.unsafeLocation(lockURL.path)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let record = OwnerRecord(
            schema: "floe-mac-bridge-store-owner-v1",
            pid: getpid(),
            parentPID: getppid(),
            bundleIdentifier: bundle.bundleIdentifier,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            storeRoot: rootURL.path,
            startedAt: now
        )
        do {
            try Self.write(record, descriptor: fd)
            guard Self.isSafeLock(fd: fd, path: lockURL.path, stateFD: stateFD, statePath: state.path) else {
                throw BridgeStoreLockError.unsafeLocation(lockURL.path)
            }
        } catch {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
        self.url = lockURL
        self.root = rootURL
        self.descriptor = fd
        self.owner = record
        lock.withLock { released = false }
    }

    deinit { release() }

    var ownerRecord: OwnerRecord { lock.withLock { owner } }
    var isHeld: Bool { lock.withLock { !released && descriptor >= 0 } }

    func release() {
        let fd: Int32 = lock.withLock {
            guard !released else { return -1 }
            released = true
            let current = descriptor
            descriptor = -1
            return current
        }
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    /// Informational only. The lock, not this record, determines ownership.
    static func readOwner(at url: URL) -> OwnerRecord? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { return nil }
        return readOwner(descriptor: fd)
    }

    private static func readOwner(descriptor: Int32) -> OwnerRecord? {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = bytes.withUnsafeMutableBytes { raw in
            pread(descriptor, raw.baseAddress, raw.count, 0)
        }
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(OwnerRecord.self, from: Data(bytes.prefix(count)))
    }

    private static func isSafeLock(fd: Int32, path: String, stateFD: Int32, statePath: String) -> Bool {
        var opened = stat(), named = stat(), openedState = stat(), namedState = stat()
        guard fstat(fd, &opened) == 0, lstat(path, &named) == 0,
              fstat(stateFD, &openedState) == 0, lstat(statePath, &namedState) == 0 else { return false }
        return (opened.st_mode & S_IFMT) == S_IFREG && (named.st_mode & S_IFMT) == S_IFREG &&
            opened.st_uid == getuid() && (opened.st_mode & 0o022) == 0 &&
            opened.st_nlink == 1 && named.st_nlink == 1 &&
            opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
            (openedState.st_mode & S_IFMT) == S_IFDIR && (namedState.st_mode & S_IFMT) == S_IFDIR &&
            openedState.st_uid == getuid() && (openedState.st_mode & 0o022) == 0 &&
            openedState.st_dev == namedState.st_dev && openedState.st_ino == namedState.st_ino
    }

    static func owner(at root: URL) -> OwnerRecord? {
        readOwner(at: root.standardizedFileURL
            .appendingPathComponent("State/bridge-store.lock", isDirectory: false))
    }

    private static func write(_ record: OwnerRecord, descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard ftruncate(descriptor, 0) == 0 else {
            throw BridgeStoreLockError.cannotWrite
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw BridgeStoreLockError.cannotWrite }
            offset += written
        }
        guard fsync(descriptor) == 0 else { throw BridgeStoreLockError.cannotWrite }
        _ = fchmod(descriptor, 0o600)
    }
}

enum BridgeStoreLockError: Error, LocalizedError, Sendable {
    case cannotOpen(String, Int32)
    case unsafeLocation(String)
    case cannotWrite
    case alreadyOwned(BridgeStoreLock.OwnerRecord?)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            return "The Bridge store lock cannot be opened at \(path) (errno \(code)). No Bridge data was modified."
        case .unsafeLocation(let path):
            return "The Bridge store lock path is not a regular file owned by this user: \(path). No Bridge data was modified."
        case .cannotWrite:
            return "The Bridge store owner record could not be written. The service did not start."
        case .alreadyOwned(let owner):
            if let owner {
                return "Another Floe Bridge service (PID \(owner.pid), bundle \(owner.bundleIdentifier ?? "unknown"), started \(owner.startedAt)) already owns this Bridge store. This service was not started and no pairing, task or workspace was modified."
            }
            return "Another Floe Bridge service already owns this Bridge store. This service was not started and no pairing, task or workspace was modified."
        }
    }
}
#endif
