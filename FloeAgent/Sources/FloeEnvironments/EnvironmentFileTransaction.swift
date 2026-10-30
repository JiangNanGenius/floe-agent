import Foundation
import FloeCore
import FloeTools

/// Recoverable per-file journal. All backups are persisted before the first mutation.
/// Transactions leave a journal on recovery failure so a retry cannot silently discard data.
///
/// New journals carry a per-file receipt: the preimage digest/mode captured with
/// the backup and the intended postimage digest/mode (or removal). Recovery uses
/// those receipts to distinguish "the transaction mutated this file" from "a
/// person changed it after the crash". An independently changed file is never
/// overwritten: the current file, the backup and the journal are all preserved
/// and the recovery reports that exact path as a conflict.
public final class EnvironmentFileTransaction {
    public struct PendingTransaction: Sendable, Equatable {
        public var version: Int?
        public var id: String?
        public var owner: String?
        public var committed: Bool
        public var hasJournal: Bool
        public var isActive: Bool

        public init(version: Int? = nil, id: String? = nil, owner: String?, committed: Bool,
                    hasJournal: Bool, isActive: Bool) {
            self.version = version
            self.id = id
            self.owner = owner
            self.committed = committed
            self.hasJournal = hasJournal
            self.isActive = isActive
        }
    }

    private struct Entry: Codable {
        var path: String
        var backup: String?
        /// Receipt fields. They are optional so journals written by older
        /// releases still decode and keep their original rollback contract.
        var preimageDigest: String?
        var preimageMode: Int?
        var postimageDigest: String?
        var postimageMode: Int?
        var intendedRemoval: Bool?
    }

    private struct Journal: Codable {
        var entries: [Entry]
        var committed: Bool
        var version: Int?
        var owner: String?
        var id: String?
    }

    private struct FileState: Equatable {
        var digest: String
        /// `nil` on a recorded receipt means "do not compare mode"; a real
        /// current file always has a concrete mode.
        var mode: Int?
    }

    private enum RecoveryAction {
        case none
        case restore(path: String, backup: URL, destination: URL, expectedDigest: String?, mode: Int?, expectedCurrent: FileState?)
        case remove(path: String, destination: URL, expectedCurrent: FileState?)
    }

    private final class ActiveRootRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: Set<String> = []

        func insert(_ root: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return roots.insert(root).inserted
        }

        func remove(_ root: String) {
            lock.lock(); defer { lock.unlock() }
            roots.remove(root)
        }

        func contains(_ root: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return roots.contains(root)
        }
    }

    private static let activeRegistry = ActiveRootRegistry()
    private static let ownerFileName = "owner"
    private static let journalVersion = 2
    private static let maxJournalBytes: Int64 = 64 * 1024 * 1024

    private let root: URL
    private let directory: URL
    private let rootKey: String
    private var journal: Journal
    private var registered = false

    public static let directoryName = ".floe-package-transaction"

    public static func location(_ relative: String, root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              !relative.contains("\0"), !relative.contains("\n"), !relative.contains("\r"),
              !components.contains(".."), !components.contains("."), !components.contains("") else {
            throw FloeError.validationFailed("Invalid package path: \(relative)")
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var current = root
        for component in components {
            current.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw FloeError.validationFailed("Package path crosses a symbolic link: \(relative)")
            }
        }
        guard current.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed("Package path escapes layer") }
        return current
    }

    public init(root: URL, paths: [String], owner: String? = nil) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.directory = try Self.location(Self.directoryName, root: self.root)
        self.rootKey = self.root.path
        let owner = owner?.isEmpty == true ? nil : owner
        // CAS receipts are owned by the task-workspace mirror. Existing
        // generic callers keep their historical blind-rollback journal schema
        // and do not pay to re-hash every preimage at transaction start.
        let receipts = owner != nil
        self.journal = Journal(entries: [], committed: false,
            version: receipts ? Self.journalVersion : 1,
            owner: owner, id: UUID().uuidString)
        if let owner {
            guard owner.utf8.count <= 128, !owner.contains("\n"), !owner.contains("\r") else {
                throw FloeError.validationFailed("Invalid package transaction owner")
            }
        }
        if FileManager.default.fileExists(atPath: directory.path),
           !Self.activeRegistry.contains(rootKey),
           (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            // An empty reserved directory has no journal or payload; it is the
            // last remnant of a committed cleanup and is safe to reclaim.
            try? FileManager.default.removeItem(at: directory)
        }
        if FileManager.default.fileExists(atPath: directory.path),
           let pending = try? Self.pendingTransaction(root: self.root),
           pending.committed, !pending.isActive {
            // A commit that crashed during cleanup leaves a committed journal.
            // Its files are final, so discarding the journal is not a rollback.
            try? Self.recover(root: self.root)
        }
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FloeError.validationFailed("Recover the interrupted package transaction before installing")
        }
        guard Self.activeRegistry.insert(rootKey) else {
            throw FloeError.validationFailed("A package transaction is already active for this location")
        }
        registered = true
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let owner {
                let marker = directory.appendingPathComponent(Self.ownerFileName)
                try Data(owner.utf8).write(to: marker, options: .atomic)
                try Self.synchronizeFile(at: marker)
            }
            for (index, path) in Set(paths).sorted().enumerated() {
                guard !path.hasPrefix(Self.directoryName + "/"), path != Self.directoryName else { throw FloeError.validationFailed("Package transaction namespace is reserved") }
                let url = try Self.location(path, root: self.root)
                let mode = try Self.existingRegularMode(at: url, path: path)
                if let mode {
                    let backup = "backup-\(index)"
                    let backupURL = directory.appendingPathComponent(backup)
                    try FileManager.default.copyItem(at: url, to: backupURL)
                    try Self.synchronizeFile(at: backupURL)
                    let digest = receipts ? try FloeDigest.sha256Hex(ofFileAt: backupURL) : nil
                    journal.entries.append(Entry(path: path, backup: backup, preimageDigest: digest,
                        preimageMode: receipts ? mode : nil, postimageDigest: nil, postimageMode: nil,
                        intendedRemoval: nil))
                } else {
                    journal.entries.append(Entry(path: path, backup: nil, preimageDigest: nil,
                        preimageMode: nil, postimageDigest: nil, postimageMode: nil, intendedRemoval: nil))
                }
            }
            try persist()
        } catch {
            Self.activeRegistry.remove(rootKey)
            registered = false
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        if registered { Self.activeRegistry.remove(rootKey) }
    }

    /// Reads the transaction state without changing any file. A missing journal
    /// is reported rather than deleted so an unmarked directory is never
    /// mistaken for a mirror-owned crash journal.
    public static func pendingTransaction(root: URL) throws -> PendingTransaction? {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = try location(directoryName, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            throw FloeError.validationFailed("The package transaction path is not a directory")
        }
        let active = activeRegistry.contains(root.path)
        let journalURL = try location("journal.json", root: directory)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try decodeJournal(at: journalURL)
            return PendingTransaction(version: journal.version, id: journal.id, owner: journal.owner,
                committed: journal.committed, hasJournal: true, isActive: active)
        }
        return PendingTransaction(owner: try readOwner(at: directory), committed: false,
            hasJournal: false, isActive: active)
    }

    public func write(_ data: Data, to path: String, mode: Int? = nil) throws {
        guard let index = journal.entries.firstIndex(where: { $0.path == path }) else { throw FloeError.validationFailed("Unjournaled package write") }
        let url = try Self.location(path, root: root)
        let effectiveMode = (mode ?? journal.entries[index].preimageMode ?? 0o644) & 0o777
        let staged = directory.appendingPathComponent("write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: effectiveMode], ofItemAtPath: staged.path)
        try Self.synchronizeFile(at: staged)
        try updateReceipt(index: index, digest: FloeDigest.sha256Hex(data), mode: effectiveMode, removal: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: url)
        }
    }

    /// Stages large package files on disk, then atomically replaces the target.
    public func copy(from source: URL, to path: String, digest: String, mode: Int) throws {
        guard let index = journal.entries.firstIndex(where: { $0.path == path }) else { throw FloeError.validationFailed("Unjournaled package write") }
        let destination = try Self.location(path, root: root)
        let staged = directory.appendingPathComponent("staged-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        guard try FloeDigest.sha256Hex(ofFileAt: staged) == digest else {
            throw FloeError.validationFailed("Package changed during promotion")
        }
        try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: staged.path)
        try Self.synchronizeFile(at: staged)
        try updateReceipt(index: index, digest: digest, mode: mode & 0o777, removal: false)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
    }

    public func remove(_ path: String) throws {
        guard let index = journal.entries.firstIndex(where: { $0.path == path }) else { throw FloeError.validationFailed("Unjournaled package removal") }
        let url = try Self.location(path, root: root)
        try updateReceipt(index: index, digest: nil, mode: nil, removal: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func commit() throws {
        journal.committed = true
        do { try persist() } catch { journal.committed = false; throw error }
        // Cleanup is ordered: payload/stage files first, then the committed
        // journal, then the owner marker. A process death at any point leaves
        // either a committed journal or an owned/empty directory that the next
        // recovery can finish without rolling committed files back.
        Self.cleanupCommittedDirectory(directory)
        Self.activeRegistry.remove(rootKey)
        registered = false
    }

    private static func cleanupCommittedDirectory(_ directory: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != "journal.json" && name != ownerFileName {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        guard let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path),
              remaining.allSatisfy({ $0 == "journal.json" || $0 == ownerFileName }) else { return }
        do { try fileManager.removeItem(at: directory.appendingPathComponent("journal.json")) }
        catch { return }
        // The journal is gone; only an owner marker may remain. Removing the
        // marker could leave an empty unmarked directory if the final step is
        // interrupted, so the mirror helper also reclaims an empty reserved
        // directory. Never remove the marker while a journal still exists.
        if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.allSatisfy({ $0 == ownerFileName }) == true {
            try? fileManager.removeItem(at: directory.appendingPathComponent(ownerFileName))
            if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    /// Rolls back this live transaction before a caller rethrows its original
    /// error. The instance must still own the exact journal: a replaced,
    /// foreign or already-committed journal fails closed and stays on disk.
    @discardableResult
    public func rollback() throws -> Bool {
        guard registered else { return false }
        guard let pending = try Self.pendingTransaction(root: root),
              pending.hasJournal, pending.isActive,
              let journalID = journal.id, pending.id == journalID,
              pending.owner == journal.owner else {
            throw FloeError.validationFailed("The package transaction is no longer owned by this operation")
        }
        // Ownership is proven. End it before replay so a static recovery call
        // can never mistake this live instance for a foreign owner, then
        // restore ownership only if the journal could not be replayed.
        Self.activeRegistry.remove(rootKey)
        registered = false
        do {
            return try Self.recover(root: root)
        } catch {
            if Self.activeRegistry.insert(rootKey) { registered = true }
            throw error
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(journal)
        let url = directory.appendingPathComponent("journal.json")
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func updateReceipt(index: Int, digest: String?, mode: Int?, removal: Bool) throws {
        let previous = journal.entries[index]
        journal.entries[index].postimageDigest = digest
        journal.entries[index].postimageMode = mode
        journal.entries[index].intendedRemoval = removal
        do { try persist() } catch {
            journal.entries[index] = previous
            throw error
        }
    }

    /// Replays an interrupted transaction backwards. Missing backups fail closed.
    ///
    /// Journals with receipts only undo a file when its current digest/mode is
    /// the recorded preimage (no mutation landed) or the recorded postimage
    /// (this transaction landed). Any other current state is an independent
    /// change: the journal, backup and current file are preserved and the
    /// recovery throws with the exact path.
    @discardableResult
    public static func recover(root: URL) throws -> Bool {
        try recover(root: root, cancellation: nil)
    }

    /// Owner-level recovery with an explicit cooperative cancellation token.
    /// Rollback must finish even when the job's Task was cancelled; only this
    /// token may interrupt it. Callers that must stop on Task cancellation
    /// check that before calling this method.
    @discardableResult
    public static func recover(root: URL, cancellation: CancellationToken?) throws -> Bool {
        try cancellation?.throwIfCancelled()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = try location(directoryName, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else {
            throw FloeError.validationFailed("The package transaction path is not a directory")
        }
        let journalURL = try location("journal.json", root: directory)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            // Initialization persists the complete journal before allowing mutations.
            try FileManager.default.removeItem(at: directory)
            return true
        }
        let journal = try decodeJournal(at: journalURL)
        if journal.committed {
            // Committed files are final. Cleanup may already have removed some
            // backups or target paths may have moved, so no receipt is needed
            // to discard this journal; only the transaction directory changes.
            try FileManager.default.removeItem(at: directory)
            return true
        }
        let receipted = (journal.version ?? 1) >= journalVersion
        // Validate the whole journal before changing any file during recovery.
        guard Set(journal.entries.map(\.path)).count == journal.entries.count else {
            throw FloeError.validationFailed("Duplicate package recovery target")
        }
        for entry in journal.entries {
            try cancellation?.throwIfCancelled()
            guard entry.path != directoryName, !entry.path.hasPrefix(directoryName + "/") else {
                throw FloeError.validationFailed("Reserved package recovery target")
            }
            _ = try location(entry.path, root: root)
        }
        for entry in journal.entries {
            try cancellation?.throwIfCancelled()
            if let backup = entry.backup {
                guard backup.hasPrefix("backup-"), !backup.contains("/") else {
                    throw FloeError.validationFailed("Invalid package recovery backup")
                }
                let source = try location(backup, root: directory)
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw FloeError.validationFailed("Package recovery backup is not a regular file")
                }
            }
            if receipted { try validateReceipt(entry) }
        }
        let actions = try recoveryActions(journal: journal, receipted: receipted,
            root: root, directory: directory, cancellation: cancellation)
        for action in actions {
            try cancellation?.throwIfCancelled()
            switch action {
            case .none:
                continue
            case .restore(let path, let backup, let destination, let expectedDigest, let mode, let expectedCurrent):
                if let expectedCurrent {
                    guard let current = try fileState(at: destination, path: path), current == expectedCurrent else {
                        throw FloeError.validationFailed("A file changed while recovering an interrupted package write. Both copies were preserved: \(path)")
                    }
                }
                try restoreFile(backup: backup, to: destination, expectedDigest: expectedDigest, mode: mode)
            case .remove(let path, let destination, let expectedCurrent):
                guard let current = try fileState(at: destination, path: path) else { continue }
                if let expectedCurrent, current != expectedCurrent {
                    throw FloeError.validationFailed("A file changed while recovering an interrupted package write. Both copies were preserved: \(path)")
                }
                try FileManager.default.removeItem(at: destination)
            }
        }
        try FileManager.default.removeItem(at: directory)
        return true
    }

    private static func recoveryActions(journal: Journal, receipted: Bool, root: URL, directory: URL,
                                        cancellation: CancellationToken?) throws -> [RecoveryAction] {
        var actions: [RecoveryAction] = []
        for entry in journal.entries.reversed() {
            try cancellation?.throwIfCancelled()
            let destination = try location(entry.path, root: root)
            if !receipted {
                // Journals written before receipts keep the historical rollback
                // contract. New mirror journals always carry receipts.
                if let backup = entry.backup {
                    let source = try location(backup, root: directory)
                    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
                    actions.append(.restore(path: entry.path, backup: source, destination: destination,
                        expectedDigest: nil, mode: mode, expectedCurrent: nil))
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    actions.append(.remove(path: entry.path, destination: destination, expectedCurrent: nil))
                } else {
                    actions.append(.none)
                }
                continue
            }
            let current = try fileState(at: destination, path: entry.path)
            let preimage = state(digest: entry.preimageDigest, mode: entry.preimageMode)
            let intended: FileState?
            if entry.intendedRemoval == true {
                intended = nil
            } else if let digest = entry.postimageDigest {
                intended = FileState(digest: digest, mode: entry.postimageMode)
            } else {
                // No mutation receipt was persisted: the intended rollback
                // state is still the preimage.
                intended = preimage
            }
            if matches(current, preimage) {
                actions.append(.none)
            } else if matches(current, intended) {
                if let backup = entry.backup {
                    guard let digest = entry.preimageDigest else {
                        throw FloeError.validationFailed("The package recovery receipt is incomplete: \(entry.path)")
                    }
                    let source = try location(backup, root: directory)
                    actions.append(.restore(path: entry.path, backup: source, destination: destination,
                        expectedDigest: digest, mode: entry.preimageMode, expectedCurrent: current))
                } else if current != nil {
                    actions.append(.remove(path: entry.path, destination: destination, expectedCurrent: current))
                } else {
                    actions.append(.none)
                }
            } else {
                throw FloeError.validationFailed("A file changed independently after an interrupted package write. Both copies were preserved: \(entry.path)")
            }
        }
        return actions
    }

    private static func validateReceipt(_ entry: Entry) throws {
        if let digest = entry.preimageDigest, !isSHA256(digest) {
            throw FloeError.validationFailed("Invalid package recovery preimage digest: \(entry.path)")
        }
        if let digest = entry.postimageDigest, !isSHA256(digest) {
            throw FloeError.validationFailed("Invalid package recovery postimage digest: \(entry.path)")
        }
        if entry.preimageDigest != nil, entry.backup == nil {
            throw FloeError.validationFailed("Package recovery preimage has no backup: \(entry.path)")
        }
        if entry.preimageDigest == nil, entry.backup != nil {
            throw FloeError.validationFailed("Package recovery backup has no preimage: \(entry.path)")
        }
        if entry.intendedRemoval == true, entry.postimageDigest != nil || entry.postimageMode != nil {
            throw FloeError.validationFailed("Package recovery entry is both a write and a removal: \(entry.path)")
        }
        if entry.preimageMode != nil, entry.preimageDigest == nil {
            throw FloeError.validationFailed("Package recovery preimage mode has no digest: \(entry.path)")
        }
        if entry.postimageMode != nil, entry.postimageDigest == nil {
            throw FloeError.validationFailed("Package recovery postimage mode has no digest: \(entry.path)")
        }
        if let mode = entry.preimageMode, mode < 0 || mode > 0o777 {
            throw FloeError.validationFailed("Invalid package recovery preimage mode: \(entry.path)")
        }
        if let mode = entry.postimageMode, mode < 0 || mode > 0o777 {
            throw FloeError.validationFailed("Invalid package recovery postimage mode: \(entry.path)")
        }
    }

    private static func restoreFile(backup: URL, to destination: URL, expectedDigest: String?, mode: Int?) throws {
        let staged = backup.deletingLastPathComponent().appendingPathComponent("restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: backup, to: staged)
        if let expectedDigest {
            guard try FloeDigest.sha256Hex(ofFileAt: staged) == expectedDigest else {
                throw FloeError.storageCorrupted("The package recovery backup does not match its receipt")
            }
        }
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: staged.path)
        }
        try synchronizeFile(at: staged)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    private static func state(digest: String?, mode: Int?) -> FileState? {
        guard let digest else { return nil }
        return FileState(digest: digest, mode: mode)
    }

    private static func matches(_ current: FileState?, _ expected: FileState?) -> Bool {
        switch (current, expected) {
        case (nil, nil):
            return true
        case (let current?, let expected?):
            guard current.digest == expected.digest else { return false }
            if let mode = expected.mode, current.mode != mode { return false }
            return true
        default:
            return false
        }
    }

    private static func fileState(at url: URL, path: String? = nil) throws -> FileState? {
        guard let mode = try existingRegularMode(at: url, path: path ?? url.lastPathComponent) else { return nil }
        return FileState(digest: try FloeDigest.sha256Hex(ofFileAt: url), mode: mode)
    }

    private static func existingRegularMode(at url: URL, path: String) throws -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw FloeError.validationFailed("Package target is unreadable: \(path)")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FloeError.validationFailed("Package mutation requires a regular file: \(path)")
        }
        return Int(info.st_mode) & 0o777
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func decodeJournal(at url: URL) throws -> Journal {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, Int64(info.st_size) <= maxJournalBytes else {
            throw FloeError.storageCorrupted("The package transaction journal is unreadable")
        }
        do {
            return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        } catch {
            throw FloeError.storageCorrupted("The package transaction journal is unreadable")
        }
    }

    private static func readOwner(at directory: URL) throws -> String? {
        let url = try location(ownerFileName, root: directory)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw FloeError.validationFailed("Package transaction ownership is unreadable")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0, info.st_size <= 256,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8),
              !text.contains("\n"), !text.contains("\r") else {
            throw FloeError.validationFailed("Package transaction ownership is invalid")
        }
        return text
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
