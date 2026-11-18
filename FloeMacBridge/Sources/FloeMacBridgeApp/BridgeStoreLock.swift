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
/// the lock. They still bind the fixed loopback port 43871, and the current
/// host refuses to start/replace a foreign listener; that port exclusion is
/// the only protection against a pre-lock legacy process. The host and the new
/// standalone/embedded services must not treat the store as migration-safe
/// while such a legacy process is running.
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
        let values = try state.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BridgeStoreLockError.unsafeLocation(state.path)
        }
        let lockURL = state.appendingPathComponent("bridge-store.lock", isDirectory: false)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw BridgeStoreLockError.cannotOpen(lockURL.path, errno)
        }
        var details = stat()
        guard fstat(fd, &details) == 0, (details.st_mode & S_IFMT) == S_IFREG,
              details.st_uid == getuid() else {
            close(fd)
            throw BridgeStoreLockError.unsafeLocation(lockURL.path)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let existing = Self.readOwner(at: lockURL)
            close(fd)
            throw BridgeStoreLockError.alreadyOwned(existing)
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
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OwnerRecord.self, from: data)
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
