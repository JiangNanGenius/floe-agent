import Foundation
import FloeCore

/// Recoverable per-file journal. All backups are persisted before the first mutation.
/// Transactions leave a journal on recovery failure so a retry cannot silently discard data.
public final class EnvironmentFileTransaction {
    private struct Entry: Codable {
        var path: String
        var backup: String?
    }
    private struct Journal: Codable {
        var entries: [Entry]
        var committed: Bool
    }
    private let root: URL
    private let directory: URL
    private var journal: Journal
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

    public init(root: URL, paths: [String]) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.directory = try Self.location(Self.directoryName, root: self.root)
        self.journal = Journal(entries: [], committed: false)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FloeError.validationFailed("Recover the interrupted package transaction before installing")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (index, path) in Set(paths).sorted().enumerated() {
                guard !path.hasPrefix(Self.directoryName + "/"), path != Self.directoryName else { throw FloeError.validationFailed("Package transaction namespace is reserved") }
                let url = try Self.location(path, root: self.root)
                let exists = FileManager.default.fileExists(atPath: url.path)
                if exists {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FloeError.validationFailed("Package mutation requires a regular file: \(path)") }
                    let backup = "backup-\(index)"
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(backup))
                    let backupHandle = try FileHandle(forWritingTo: directory.appendingPathComponent(backup))
                    try backupHandle.synchronize()
                    try backupHandle.close()
                    journal.entries.append(Entry(path: path, backup: backup))
                } else { journal.entries.append(Entry(path: path, backup: nil)) }
            }
            try persist()
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    public func write(_ data: Data, to path: String, mode: Int? = nil) throws {
        guard journal.entries.contains(where: { $0.path == path }) else { throw FloeError.validationFailed("Unjournaled package write") }
        let url = try Self.location(path, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: url.path) }
    }

    /// Stages large package files on disk, then atomically replaces the target.
    public func copy(from source: URL, to path: String, digest: String, mode: Int) throws {
        guard journal.entries.contains(where: { $0.path == path }) else { throw FloeError.validationFailed("Unjournaled package write") }
        let destination = try Self.location(path, root: root)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("staged-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        guard try FloeDigest.sha256Hex(ofFileAt: staged) == digest else {
            throw FloeError.validationFailed("Package changed during promotion")
        }
        try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
    }

    public func remove(_ path: String) throws {
        guard journal.entries.contains(where: { $0.path == path }) else { throw FloeError.validationFailed("Unjournaled package removal") }
        let url = try Self.location(path, root: root)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func commit() throws {
        journal.committed = true
        do { try persist() } catch { journal.committed = false; throw error }
        // The committed journal is safe to remove on the next startup if cleanup fails.
        try? FileManager.default.removeItem(at: directory)
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(journal)
        let url = directory.appendingPathComponent("journal.json")
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Replays an interrupted transaction backwards. Missing backups fail closed.
    @discardableResult
    public static func recover(root: URL) throws -> Bool {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = try location(directoryName, root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let journalURL = try location("journal.json", root: directory)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            // Initialization persists the complete journal before allowing mutations.
            try FileManager.default.removeItem(at: directory)
            return true
        }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        // Validate the whole journal before changing any file during recovery.
        guard Set(journal.entries.map(\.path)).count == journal.entries.count else {
            throw FloeError.validationFailed("Duplicate package recovery target")
        }
        for entry in journal.entries {
            guard entry.path != directoryName, !entry.path.hasPrefix(directoryName + "/") else {
                throw FloeError.validationFailed("Reserved package recovery target")
            }
            _ = try location(entry.path, root: root)
            if !journal.committed, let backup = entry.backup {
                guard backup.hasPrefix("backup-"), !backup.contains("/") else {
                    throw FloeError.validationFailed("Invalid package recovery backup")
                }
                let source = try location(backup, root: directory)
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw FloeError.validationFailed("Package recovery backup is not a regular file")
                }
            }
        }
        if !journal.committed {
            for entry in journal.entries.reversed() {
                let destination = try location(entry.path, root: root)
                if let backup = entry.backup {
                    let source = try location(backup, root: directory)
                    let data = try Data(contentsOf: source)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                    if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path) }
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FloeError.validationFailed("Recovery target is no longer a regular file") }
                    try FileManager.default.removeItem(at: destination)
                }
            }
        }
        try FileManager.default.removeItem(at: directory)
        return true
    }
}
