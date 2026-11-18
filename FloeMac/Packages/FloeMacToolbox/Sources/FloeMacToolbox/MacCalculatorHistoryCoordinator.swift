import Foundation
import CryptoKit
import Darwin
import FloeToolboxCore
import FloeToolboxUtilities
import Combine

/// The application owns history writes even when the calculator view closes.
/// Admissions are synchronous on MainActor; termination closes admissions
/// before awaiting the final queued write.
@MainActor
final class MacCalculatorHistoryCoordinator: ObservableObject {
    typealias RecoveryCreator = @Sendable (URL, URL) async throws -> (backup: URL, active: URL)
    private struct Pending {
        let operation: @Sendable (EverydayCalculatorHistoryStore) async throws -> [EverydayCalculatorHistoryEntry]
        let completion: @MainActor (Result<[EverydayCalculatorHistoryEntry], any Error>) -> Void
    }
    private(set) var store: EverydayCalculatorHistoryStore
    private let baseURL: URL?
    private var lockFD: Int32
    private var ownershipResolved: Bool
    private(set) var storageUnavailable: Bool
    private var tail: Task<Void, Never>?
    private var drainTask: Task<Bool, Never>?
    private var admissionsClosed = false
    private var failedWrites: [Pending] = []
    @Published private(set) var recoveryRevision = 0
    private(set) var recoveryInProgress = false
    private var recoveryBackup: URL?
    private let recoveryCreator: RecoveryCreator
    var hasPendingRecovery: Bool { recoveryBackup != nil || recoveryInProgress }

    init(store: EverydayCalculatorHistoryStore,
         recoveryCreator: @escaping RecoveryCreator = { original, base in
             try await Task.detached(priority: .userInitiated) {
                 try MacCalculatorHistoryCoordinator.makeRecoveryArchive(original: original, base: base)
             }.value
         }) {
        self.store = store
        self.baseURL = nil
        self.lockFD = -1
        self.ownershipResolved = true
        self.storageUnavailable = false
        self.recoveryCreator = recoveryCreator
    }

    /// All instances of this Mac host acquire the same exclusive lock before
    /// selecting an archive or admitting writes. Legacy writers may still use
    /// the old file; recovery never replaces that old file.
    init(baseURL: URL) {
        self.baseURL = baseURL
        self.lockFD = -1
        self.ownershipResolved = false
        self.store = EverydayCalculatorHistoryStore(url: baseURL)
        self.storageUnavailable = false
        self.recoveryCreator = { original, base in
            try await Task.detached(priority: .userInitiated) {
                try Self.makeRecoveryArchive(original: original, base: base)
            }.value
        }
    }

    /// Lazily open storage only when a calculator is actually used; merely
    /// constructing a toolbox service does not touch the filesystem.
    @discardableResult
    func ensureOwnership() -> Bool {
        if ownershipResolved { return !storageUnavailable }
        ownershipResolved = true
        guard let baseURL else { return true }
        let fd = Self.acquireLock(for: baseURL)
        lockFD = fd
        do {
            guard fd >= 0 else { throw RecoveryError.ownershipUnavailable }
            store = EverydayCalculatorHistoryStore(url: try Self.selectedArchive(baseURL))
            storageUnavailable = false
        } catch {
            storageUnavailable = true
        }
        return !storageUnavailable
    }

    func retryOwnership() {
        guard storageUnavailable else { return }
        if lockFD >= 0 { _ = Darwin.close(lockFD); lockFD = -1 }
        ownershipResolved = false
        storageUnavailable = false
    }

    deinit { if lockFD >= 0 { _ = Darwin.close(lockFD) } }

    @discardableResult
    func enqueue(_ operation: @escaping @Sendable (EverydayCalculatorHistoryStore) async throws -> [EverydayCalculatorHistoryEntry],
                 completion: @escaping @MainActor (Result<[EverydayCalculatorHistoryEntry], any Error>) -> Void) -> Bool {
        guard !admissionsClosed, ensureOwnership() else { return false }
        let item = Pending(operation: operation, completion: completion)
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            if !failedWrites.isEmpty {
                failedWrites.append(item)
                _ = await retryFailedWrites()
            } else if !(await execute(item)) {
                failedWrites.append(item)
            }
        }
        return true
    }

    private func execute(_ item: Pending) async -> Bool {
        do {
            let entries = try await item.operation(store)
            item.completion(.success(entries))
            return true
        } catch {
            item.completion(.failure(error))
            return false
        }
    }

    func closeAdmissions() { admissionsClosed = true }

    /// An explicit user action preserves the unreadable archive, creates a
    /// separate history and retries admitted writes in their original order.
    /// Failed preservation never replaces the archive or discards the queue.
    @discardableResult
    func recoverCorruptHistory(completion: @escaping @MainActor (Result<URL, any Error>) -> Void) -> Bool {
        guard !admissionsClosed, !recoveryInProgress, ensureOwnership() else { return false }
        recoveryInProgress = true
        recoveryRevision &+= 1
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            defer { recoveryInProgress = false; recoveryRevision &+= 1 }
            do {
                let backup: URL
                if let existingBackup = recoveryBackup {
                    backup = existingBackup
                } else {
                    do {
                        _ = try await store.load()
                        throw RecoveryError.archiveNotCorrupt
                    } catch ToolboxError.corruptStore {
                        // Continue only for an actual unreadable archive.
                    } catch ToolboxError.limit(_) {
                        // Oversized archives are also preserved before reset.
                    }
                    let original = await store.url
                    let base = baseURL ?? original
                    let recovered = try await recoveryCreator(original, base)
                    backup = recovered.backup
                    store = EverydayCalculatorHistoryStore(url: recovered.active)
                    recoveryBackup = backup
                }
                guard await retryFailedWrites() else { throw RecoveryError.retryFailed }
                recoveryBackup = nil
                completion(.success(backup))
            } catch {
                completion(.failure(error))
            }
        }
        return true
    }

    private enum RecoveryError: Error { case archiveNotCorrupt, sourceChanged, retryFailed, ownershipUnavailable, invalidPointer }

    private struct RecoveryPointer: Codable { let version: Int; let filename: String }

    nonisolated private static func markerURL(_ base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + ".recovered.active")
    }

    nonisolated private static func acquireLock(for base: URL) -> Int32 {
        let directory = base.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return -1 }
        let path = directory.appendingPathComponent(base.lastPathComponent + ".lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return -1 }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { _ = Darwin.close(fd); return -1 }
        return fd
    }

    nonisolated private static func selectedArchive(_ base: URL) throws -> URL {
        var current = base
        for _ in 0..<8 {
            guard let next = try nextArchive(current) else { return current }
            current = next
        }
        guard try nextArchive(current) == nil else { throw RecoveryError.invalidPointer }
        return current
    }

    nonisolated private static func nextArchive(_ base: URL) throws -> URL? {
        let marker = markerURL(base)
        var markerInfo = stat()
        if lstat(marker.path, &markerInfo) != 0 {
            if errno == ENOENT { return nil }
            throw RecoveryError.invalidPointer
        }
        let metadata = try marker.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let size = metadata.fileSize, size <= 4096 else { throw RecoveryError.invalidPointer }
        let pointer = try JSONDecoder().decode(RecoveryPointer.self, from: Data(contentsOf: marker))
        let prefix = "FloeCalculatorHistory-recovered-"
        guard pointer.version == 1, pointer.filename.hasPrefix(prefix),
              UUID(uuidString: String(pointer.filename.dropFirst(prefix.count))) != nil else { throw RecoveryError.invalidPointer }
        let selected = base.deletingLastPathComponent().appendingPathComponent(pointer.filename)
        let info = try selected.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw RecoveryError.invalidPointer }
        return selected
    }

    nonisolated static func makeRecoveryArchive(original: URL, base: URL) throws -> (backup: URL, active: URL) {
        var current = base
        var depth = 0
        while let next = try nextArchive(current) {
            depth += 1
            guard depth < 8 else { throw RecoveryError.invalidPointer }
            current = next
        }
        guard current.standardizedFileURL == original.standardizedFileURL else { throw RecoveryError.invalidPointer }
        // Never replace the old archive. A competing/older process can change
        // it without recovery overwriting its data.
        let backup = try preserveArchive(original)
        let active = original.deletingLastPathComponent()
            .appendingPathComponent("FloeCalculatorHistory-recovered-" + UUID().uuidString)
        try Data("[]".utf8).write(to: active, options: .withoutOverwriting)
        let pointer = RecoveryPointer(version: 1, filename: active.lastPathComponent)
        // Exclusive creation prevents two recoveries from silently selecting
        // different archives. A partial pointer fails closed on next launch.
        try JSONEncoder().encode(pointer).write(to: markerURL(original), options: .withoutOverwriting)
        return (backup, active)
    }

    nonisolated private static func preserveArchive(_ original: URL) throws -> URL {
        let values = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RecoveryError.sourceChanged }
        let backup = original.deletingLastPathComponent()
            .appendingPathComponent(original.lastPathComponent + ".corrupt-" + UUID().uuidString + ".backup")
        let before = try digest(original)
        try FileManager.default.copyItem(at: original, to: backup)
        guard try digest(backup) == before, try digest(original) == before else { throw RecoveryError.sourceChanged }
        return backup
    }

    nonisolated private static func digest(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize()
    }

    func drain() async -> Bool {
        guard admissionsClosed else { return false }
        if let drainTask { return await drainTask.value }
        let task = Task { @MainActor in
            await tail?.value
            return await retryFailedWrites()
        }
        drainTask = task
        let result = await task.value
        drainTask = nil
        return result
    }

    private func retryFailedWrites() async -> Bool {
        while let first = failedWrites.first {
            guard await execute(first) else { return false }
            failedWrites.removeFirst()
        }
        return true
    }

    func resumeAfterCancelledTermination() {
        admissionsClosed = false
    }
}
