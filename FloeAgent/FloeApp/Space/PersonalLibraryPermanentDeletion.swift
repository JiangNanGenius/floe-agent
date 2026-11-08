// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin
import FloeBiologyCore

nonisolated enum PersonalPermanentDeleteError: String, Error, LocalizedError, Sendable {
    case changed, incomplete, unsupportedOriginal, tooLarge
    var errorDescription: String? {
        switch self {
        case .changed: IDELanguageRunText.t("所选内容已改变，请刷新后重新选择。", "The selected content changed. Refresh and select it again.")
        case .incomplete: IDELanguageRunText.t("清理尚未完成，剩余文件仍保留。请重新选择并重试删除。", "Cleanup is incomplete. Remaining files are kept. Select the item again to retry deletion.")
        case .unsupportedOriginal: IDELanguageRunText.t("这项内容暂不支持永久删除，原件仍保留。", "Permanent deletion is unavailable for this item. Its original is kept.")
        case .tooLarge: IDELanguageRunText.t("这项内容的文件结构过大，暂时无法清理。", "This item has too many file entries to clean up here.")
        }
    }
}

/// Native confirmation snapshot, never Codable or a path-taking tool argument.
nonisolated struct PersonalPermanentDeletePlan: Hashable, Identifiable, Sendable {
    let entry: PersonalLibraryTrashEntry
    let coveredEntries: [PersonalLibraryTrashEntry]
    let members: [PersonalContentRecord]
    let identity: String
    fileprivate let wrapperIdentity: String
    let biologySources: [PersonalBiologyPermanentDeletionSource]
    let fileCount: Int
    let logicalBytes: Int64
    let cleanupPending: Bool
    fileprivate let rootIdentity: String
    fileprivate let directoryIdentity: String
    fileprivate let treeIdentity: String
    fileprivate let physicalPath: String
    fileprivate let journal: PersonalLibraryPurgeJournal?
    var id: UUID { entry.id }
    var requiresPreparation: Bool { physicalPath == entry.relativePath }
    var wrapperRemovalStarted: Bool { journal?.phase == .removing }
    func physicalRelativePath(for record: PersonalContentRecord) throws -> String {
        guard members.contains(record), record.relativePath == entry.relativePath || record.relativePath.hasPrefix(entry.relativePath + "/") else { throw PersonalPermanentDeleteError.changed }
        return physicalPath + record.relativePath.dropFirst(entry.relativePath.count)
    }
    func biologyDeletionIdentity() throws -> String? {
        guard !biologySources.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(biologySources)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func includingBiology(_ sources: [PersonalBiologyPermanentDeletionSource]) throws -> Self {
        let ordered = sources.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
        let ids = Set(members.filter { $0.kind == .biology }.map(\.id))
        guard Set(ordered.map(\.projectID)) == ids, ordered.count == ids.count,
              ordered.allSatisfy({ $0.native.projectID == $0.projectID && $0.native.transactionID == entry.id }) else { throw PersonalPermanentDeleteError.changed }
        if let saved = journal?.biologySources {
            guard saved.count == ordered.count, saved.allSatisfy({ old in ordered.contains { $0.projectID == old.projectID && $0.bindingSHA256 == old.bindingSHA256 && $0.native.sourceIdentity == old.native.sourceIdentity } }) else { throw PersonalPermanentDeleteError.changed }
        }
        struct Pin: Encodable { let wrapper: String; let biology: [PersonalBiologyPermanentDeletionSource] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Pin(wrapper: wrapperIdentity, biology: ordered))
        let pin = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(entry: entry, coveredEntries: coveredEntries, members: members, identity: ordered.isEmpty ? wrapperIdentity : pin,
            wrapperIdentity: wrapperIdentity, biologySources: ordered, fileCount: fileCount, logicalBytes: logicalBytes,
            cleanupPending: cleanupPending, rootIdentity: rootIdentity, directoryIdentity: directoryIdentity, treeIdentity: treeIdentity, physicalPath: physicalPath, journal: journal)
    }
    var protectedRelativePaths: [String] { Array(Set([entry.relativePath, physicalPath])) }
}
nonisolated struct PersonalPermanentDeleteReceipt: Sendable {
    let entryID: UUID
    let removedEntryIDs: [UUID]
    let projectIDs: [UUID]
    /// Logical selected data, not exclusive APFS blocks or measured free space.
    let logicalBytes: Int64
    let privateJournalCleanupPending: Bool
}
nonisolated struct PersonalPermanentDeleteBatchResult: Sendable {
    struct Failure: Sendable { let entryID: UUID; let code: String; let message: String }
    var deleted: [PersonalPermanentDeleteReceipt] = []
    var failed: [Failure] = []
}
nonisolated enum PersonalPermanentDeleteCheckpoint: Sendable {
    case staged, beforeIrreversible, removedNode(String), beforeIndexCommit
}

/// A durable retry record remains until physical removal AND the original
/// atomic trash-index update succeed. Partial removal is never called Restore.
fileprivate nonisolated struct PersonalLibraryPurgeJournal: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable { case staged, awaitingBiology, removing }
    var schemaVersion = 1
    let entry: PersonalLibraryTrashEntry
    let coveredEntries: [PersonalLibraryTrashEntry]
    let members: [PersonalContentRecord]
    let rootIdentity: String
    let directoryIdentity: String
    let stagedPath: String
    var phase: Phase
    var biologySources: [PersonalBiologyPermanentDeletionSource]?
    var originalTreeIdentity: String?
}

extension PersonalContentLibrary {
    /// Resolves exactly the selected entry snapshots. A selected folder covers
    /// its contents; independently deleted descendants are frozen into its plan.
    func permanentDeletionPlans(_ selected: [PersonalLibraryTrashEntry]) throws -> [PersonalPermanentDeletePlan] {
        try permanentDeletionProposals(selected, allowBiology: false)
    }
    /// Native coordinator preflight only. Proposals cannot delete Biology on
    /// their own; native snapshots and real completion receipts are required.
    func permanentDeletionProposals(_ selected: [PersonalLibraryTrashEntry], allowBiology: Bool = true) throws -> [PersonalPermanentDeletePlan] {
        guard !selected.isEmpty, selected.count <= 128, Set(selected.map(\.id)).count == selected.count else { throw PersonalPermanentDeleteError.changed }
        return try PersonalLibraryPurgeIO.locked(root: root) { fd in
            let state = try PersonalLibraryPurgeIO.trash(fd)
            guard selected.allSatisfy({ state.entries.contains($0) }) else { throw PersonalPermanentDeleteError.changed }
            let roots = selected.filter { item in !selected.contains { parent in
                parent.kind == .folder && parent.id != item.id && item.relativePath.hasPrefix(parent.relativePath + "/")
            } }.sorted { $0.relativePath < $1.relativePath }
            let records = try self.records(includingDeleted: true)
            return try roots.map { try PersonalLibraryPurgeIO.plan(root: root, fd: fd, entry: $0, state: state, records: records, allowBiology: allowBiology) }
        }
    }
    func permanentDeletionPendingIDs() throws -> Set<UUID> {
        try PersonalLibraryPurgeIO.locked(root: root) { fd in
            var ids = Set<UUID>()
            for entry in try PersonalLibraryPurgeIO.trash(fd).entries {
                if let pending = try PersonalLibraryPurgeIO.journal(fd, entryID: entry.id),
                   !(try PersonalLibraryPurgeIO.isUnstarted(fd, pending)) {
                    ids.formUnion(pending.coveredEntries.map(\.id))
                }
            }
            return ids
        }
    }
    func pendingPermanentDeletionRecords() throws -> [PersonalContentRecord] {
        try PersonalLibraryPurgeIO.locked(root: root) { fd in
            var records: [PersonalContentRecord] = []
            for entry in try PersonalLibraryPurgeIO.trash(fd).entries {
                if let pending = try PersonalLibraryPurgeIO.journal(fd, entryID: entry.id) { records += pending.members }
            }
            return records
        }
    }
    func permanentlyDelete(_ selected: PersonalPermanentDeletePlan,
        checkpoint: (@Sendable (PersonalPermanentDeleteCheckpoint) throws -> Void)? = nil) throws -> PersonalPermanentDeleteReceipt {
        try Task.checkCancellation()
        return try PersonalLibraryPurgeIO.locked(root: root) { fd in
            let state = try PersonalLibraryPurgeIO.trash(fd)
            let current = try PersonalLibraryPurgeIO.plan(root: root, fd: fd, entry: selected.entry, state: state,
                records: self.records(includingDeleted: true))
            guard current == selected else { throw PersonalPermanentDeleteError.changed }
            try Task.checkCancellation()
            return try PersonalLibraryPurgeIO.remove(root: root, fd: fd, plan: current, state: state, checkpoint: checkpoint)
        }
    }
    func stageBiologyPermanentDeletion(_ selected: PersonalPermanentDeletePlan) throws {
        try Task.checkCancellation()
        try PersonalLibraryPurgeIO.locked(root: root) { fd in
            let state = try PersonalLibraryPurgeIO.trash(fd)
            let current = try PersonalLibraryPurgeIO.plan(root: root, fd: fd, entry: selected.entry, state: state,
                records: self.records(includingDeleted: true), allowBiology: true).includingBiology(selected.biologySources)
            guard current == selected, !selected.biologySources.isEmpty else { throw PersonalPermanentDeleteError.changed }
            try PersonalLibraryPurgeIO.stageBiology(root: root, fd: fd, plan: current)
        }
    }
    func rollbackBiologyPermanentDeletion(_ selected: PersonalPermanentDeletePlan) throws {
        try PersonalLibraryPurgeIO.locked(root: root) { fd in try PersonalLibraryPurgeIO.rollbackBiology(fd: fd, plan: selected) }
    }
    func finishBiologyPermanentDeletion(_ selected: PersonalPermanentDeletePlan,
        receipts: [BiologyPermanentDeletionReceipt], checkpoint: (@Sendable (PersonalPermanentDeleteCheckpoint) throws -> Void)? = nil) throws -> PersonalPermanentDeleteReceipt {
        // Actual native completion is irreversible; no post-commit cancellation
        // check may turn it into a claimed zero-write cancellation.
        try PersonalLibraryPurgeIO.locked(root: root) { fd in
            let state = try PersonalLibraryPurgeIO.trash(fd)
            let current = try PersonalLibraryPurgeIO.plan(root: root, fd: fd, entry: selected.entry, state: state,
                records: self.records(includingDeleted: true), allowBiology: true, checkCancellation: false)
                .includingBiology(selected.biologySources)
            try PersonalLibraryPurgeIO.verifyBiologyCompletion(current, receipts: receipts)
            return try PersonalLibraryPurgeIO.remove(root: root, fd: fd, plan: current, state: state, checkpoint: checkpoint, biologyCompleted: true)
        }
    }
}

/// Uses the SAME library mutation flock, fd-anchored NOFOLLOW traversal,
/// exclusive sibling staging and unlinkat. No host path or external executor.
nonisolated enum PersonalLibraryPurgeIO {
    private static let maximumNodes = 200_000
    private static let maximumJournalBytes = 16 * 1_024 * 1_024
    private static func fail() throws -> Never { throw PersonalPermanentDeleteError.changed }
    private static func identity(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)"
    }
    private static func statFD(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { try fail() }; return value
    }
    static func resourceIdentity(root: URL, path: String) throws -> String {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { try fail() }; defer { Darwin.close(fd) }
        let directory = try openPath(fd, path); defer { Darwin.close(directory) }
        return identity(try statFD(directory))
    }
    static func locked<T>(root: URL, _ body: (Int32) throws -> T) throws -> T {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PersonalPermanentDeleteError.changed }; defer { Darwin.close(fd) }
        let lock = openat(fd, ".FloeLibraryMutation.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw PersonalContentError.storageUnavailable }; defer { Darwin.close(lock) }
        while flock(lock, LOCK_EX) != 0 { if errno != EINTR { throw PersonalContentError.storageUnavailable } }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(fd)
    }
    private static func checkRoot(_ root: URL, _ fd: Int32) throws {
        let current = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { try fail() }; defer { Darwin.close(current) }
        guard identity(try statFD(current)) == identity(try statFD(fd)) else { try fail() }
    }
    private static func openPath(_ root: Int32, _ path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 64, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") }) else { try fail() }
        var current = Darwin.dup(root); guard current >= 0 else { try fail() }
        for part in components {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(current); guard next >= 0 else { try fail() }; current = next
        }
        return current
    }
    private static func exists(_ root: Int32, _ path: String) throws -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { try fail() }
        let parent = parts.count == 1 ? Darwin.dup(root) : try openPath(root, parts.dropLast().joined(separator: "/"))
        guard parent >= 0 else { try fail() }; defer { Darwin.close(parent) }
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { try fail() }; return false
    }
    private static func read(_ fd: Int32, name: String, maximum: Int) throws -> Data? {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 { if errno == ENOENT { return nil }; try fail() }
        defer { Darwin.close(file) }
        let info = try statFD(file)
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximum else { try fail() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; try fail() }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximum else { try fail() }
        }
        return data
    }
    private static func write(_ fd: Int32, name: String, bytes: Data) throws {
        let temporary = ".FloePurgeWrite-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard file >= 0 else { throw PersonalContentError.storageUnavailable }
        defer { Darwin.close(file); _ = unlinkat(fd, temporary, 0) }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw PersonalContentError.storageUnavailable }
                guard count > 0 else { throw PersonalContentError.storageUnavailable }; offset += count
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0 else { throw PersonalContentError.storageUnavailable }
        _ = fsync(fd)
    }
    static func trash(_ fd: Int32) throws -> PersonalLibraryTrashStore.State {
        guard let bytes = try read(fd, name: PersonalLibraryTrashStore.fileName, maximum: 4 * 1_024 * 1_024) else { return .init() }
        return try PersonalLibraryTrashStore.decode(bytes)
    }
    static func requireNoJournal(root: URL, entryID: UUID) throws {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { try fail() }; defer { Darwin.close(fd) }
        guard let pending = try journal(fd, entryID: entryID) else { return }
        let state = try trash(fd)
        guard state.entries.contains(pending.entry), affected(state, entry: pending.entry) == pending.coveredEntries,
              try isUnstarted(fd, pending) else { throw PersonalPermanentDeleteError.incomplete }
        // Exit after the journal write but before rename removed no body bytes.
        // Restore may discard only that exact owned, unstarted intent.
        guard unlinkat(fd, journalName(entryID), 0) == 0 else { throw PersonalContentError.storageUnavailable }
        _ = fsync(fd)
    }
    fileprivate static func isUnstarted(_ fd: Int32, _ pending: PersonalLibraryPurgeJournal) throws -> Bool {
        guard pending.phase == .staged, identity(try statFD(fd)) == pending.rootIdentity,
              try exists(fd, pending.entry.relativePath), !(try exists(fd, pending.stagedPath)) else { return false }
        let directory = try openPath(fd, pending.entry.relativePath); defer { Darwin.close(directory) }
        return identity(try statFD(directory)) == pending.directoryIdentity
    }
    private static func journalName(_ id: UUID) -> String { ".FloeLibraryPurge-" + id.uuidString + ".json" }
    fileprivate static func journal(_ fd: Int32, entryID: UUID) throws -> PersonalLibraryPurgeJournal? {
        guard let data = try read(fd, name: journalName(entryID), maximum: maximumJournalBytes) else { return nil }
        let value = try JSONDecoder().decode(PersonalLibraryPurgeJournal.self, from: data)
        guard value.schemaVersion == 1, value.entry.id == entryID,
              value.stagedPath == stagePath(value.entry), value.coveredEntries.contains(value.entry),
              Set(value.members.map(\.id)).count == value.members.count else { try fail() }
        for member in value.members {
            _ = try PersonalLibraryTrashStore.components(member.relativePath)
            guard member.schemaVersion == 1,
                  (value.entry.kind == .work ? member.id == value.entry.projectID && member.relativePath == value.entry.relativePath && member.kind == value.entry.contentKind
                    : member.relativePath.hasPrefix(value.entry.relativePath + "/")) else { try fail() }
        }
        if let sources = value.biologySources {
            let ids = Set(value.members.filter { $0.kind == .biology }.map(\.id))
            guard !sources.isEmpty, sources.count == ids.count, Set(sources.map(\.projectID)) == ids,
                  sources.allSatisfy({ $0.native.projectID == $0.projectID && $0.native.transactionID == entryID && $0.bindingSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { try fail() }
        }
        return value
    }
    private static func save(_ value: PersonalLibraryPurgeJournal, fd: Int32) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximumJournalBytes else { throw PersonalPermanentDeleteError.tooLarge }
        try write(fd, name: journalName(value.entry.id), bytes: bytes)
    }
    private static func stagePath(_ entry: PersonalLibraryTrashEntry) -> String {
        (entry.relativePath.split(separator: "/").dropLast().map(String.init) + [".FloePurge-" + entry.id.uuidString]).joined(separator: "/")
    }
    private static func affected(_ state: PersonalLibraryTrashStore.State, entry: PersonalLibraryTrashEntry) -> [PersonalLibraryTrashEntry] {
        state.entries.filter { $0.id == entry.id || (entry.kind == .folder && $0.relativePath.hasPrefix(entry.relativePath + "/")) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
    fileprivate static func plan(root: URL, fd: Int32, entry: PersonalLibraryTrashEntry,
        state: PersonalLibraryTrashStore.State, records: [PersonalContentRecord], allowBiology: Bool = false, checkCancellation: Bool = true) throws -> PersonalPermanentDeletePlan {
        try checkRoot(root, fd); _ = try PersonalLibraryTrashStore.components(entry.relativePath)
        guard state.entries.contains(entry) else { try fail() }
        let pending = try journal(fd, entryID: entry.id), covered = affected(state, entry: entry)
        for child in covered where child.id != entry.id {
            guard try journal(fd, entryID: child.id) == nil else { throw PersonalPermanentDeleteError.incomplete }
        }
        let members: [PersonalContentRecord]
        let physical: String
        let rootID = identity(try statFD(fd))
        if let pending {
            guard pending.entry == entry, pending.coveredEntries == covered, pending.rootIdentity == rootID else { try fail() }
            if try isUnstarted(fd, pending) {
                members = records.filter { entry.kind == .folder ? $0.folders.starts(with: entry.relativePath.split(separator: "/").map(String.init)) : $0.id == entry.projectID }
                physical = entry.relativePath
            } else {
                guard !(try exists(fd, entry.relativePath)) else { try fail() }
                members = pending.members; physical = pending.stagedPath
            }
        } else {
            members = records.filter { entry.kind == .folder ? $0.folders.starts(with: entry.relativePath.split(separator: "/").map(String.init)) : $0.id == entry.projectID }
            physical = entry.relativePath
        }
        guard allowBiology || !members.contains(where: { $0.kind == .biology }) else { throw PersonalPermanentDeleteError.unsupportedOriginal }
        let tree: Tree
        let directoryID: String
        if let pending, !(try exists(fd, physical)) {
            guard pending.phase == .removing else { try fail() }
            directoryID = pending.directoryIdentity; tree = .init(digest: "removed", files: 0, bytes: 0)
        } else {
            let directory = try openPath(fd, physical); defer { Darwin.close(directory) }
            directoryID = identity(try statFD(directory))
            if let pending { guard directoryID == pending.directoryIdentity else { try fail() } }
            if pending == nil || physical == entry.relativePath {
                if let saved = entry.resourceIdentity { guard saved == directoryID else { try fail() } }
                if entry.kind == .work {
                    guard let data = try read(directory, name: "FloeProject.json", maximum: 65_536),
                          let record = try? JSONDecoder().decode(PersonalContentRecord.self, from: data),
                          record.id == entry.projectID, record.kind == entry.contentKind,
                          members.count == 1, members[0].relativePath == entry.relativePath else { try fail() }
                } else {
                    guard let data = try read(directory, name: PersonalLibraryTrashStore.folderMarker, maximum: 128),
                          try JSONDecoder().decode(UUID.self, from: data) == entry.folderID else { try fail() }
                }
            }
            if physical == entry.relativePath, entry.kind == .folder {
                try validateOriginals(directory, prefix: entry.relativePath, known: Set(members.map(\.relativePath)))
            }
            tree = try snapshot(directory, checkCancellation: checkCancellation)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        struct Pin: Encodable { let entry: PersonalLibraryTrashEntry; let covered: [PersonalLibraryTrashEntry]; let root: String; let directory: String; let tree: String; let pending: PersonalLibraryPurgeJournal? }
        let pin = try encoder.encode(Pin(entry: entry, covered: covered, root: rootID, directory: directoryID, tree: tree.digest, pending: pending))
        let wrapperPin = hash(pin)
        return .init(entry: entry, coveredEntries: covered, members: members, identity: wrapperPin, wrapperIdentity: wrapperPin,
            biologySources: pending?.biologySources ?? [], fileCount: tree.files,
            logicalBytes: tree.bytes, cleanupPending: pending != nil, rootIdentity: rootID, directoryIdentity: directoryID,
            treeIdentity: tree.digest, physicalPath: physical, journal: pending)
    }
    static func biologyBindingDigest(root: URL, relativePath: String, projectID: UUID) throws -> String {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { try fail() }; defer { Darwin.close(fd) }
        let directory = try openPath(fd, relativePath); defer { Darwin.close(directory) }
        guard let data = try read(directory, name: "biology-binding.json", maximum: 4_096) else { try fail() }
        try BiologyOriginalBinding.validate(data, id: projectID); return hash(data)
    }
    fileprivate static func stageBiology(root: URL, fd: Int32, plan: PersonalPermanentDeletePlan) throws {
        guard !plan.biologySources.isEmpty else { try fail() }
        var pending = plan.journal ?? .init(entry: plan.entry, coveredEntries: plan.coveredEntries, members: plan.members,
            rootIdentity: plan.rootIdentity, directoryIdentity: plan.directoryIdentity, stagedPath: stagePath(plan.entry), phase: .staged,
            biologySources: plan.biologySources, originalTreeIdentity: plan.treeIdentity)
        guard pending.biologySources != nil else { try fail() }
        if plan.requiresPreparation {
            pending.phase = .staged; pending.biologySources = plan.biologySources; pending.originalTreeIdentity = plan.treeIdentity
            try save(pending, fd: fd)
            let parts = plan.entry.relativePath.split(separator: "/").map(String.init)
            let parent = parts.count == 1 ? Darwin.dup(fd) : try openPath(fd, parts.dropLast().joined(separator: "/"))
            guard parent >= 0 else { try fail() }; defer { Darwin.close(parent) }
            let staged = String(pending.stagedPath.split(separator: "/").last!)
            guard renameatx_np(parent, parts.last!, parent, staged, UInt32(RENAME_EXCL)) == 0 else { _ = unlinkat(fd, journalName(plan.id), 0); try fail() }
            do {
                let directory = try openPath(fd, pending.stagedPath); defer { Darwin.close(directory) }
                guard identity(try statFD(directory)) == pending.directoryIdentity, try snapshot(directory).digest == plan.treeIdentity else { try fail() }
                try Task.checkCancellation(); pending.phase = .awaitingBiology; try save(pending, fd: fd)
            } catch {
                if renameatx_np(parent, staged, parent, parts.last!, UInt32(RENAME_EXCL)) == 0 { _ = unlinkat(fd, journalName(plan.id), 0) }
                throw error
            }
        } else if pending.phase == .staged {
            pending.phase = .awaitingBiology; try save(pending, fd: fd)
        }
    }
    fileprivate static func rollbackBiology(fd: Int32, plan: PersonalPermanentDeletePlan) throws {
        guard let pending = try journal(fd, entryID: plan.id), pending.entry == plan.entry,
              pending.phase != .removing, !(try exists(fd, plan.entry.relativePath)) else { try fail() }
        let directory = try openPath(fd, pending.stagedPath); defer { Darwin.close(directory) }
        guard identity(try statFD(directory)) == pending.directoryIdentity,
              try snapshot(directory, checkCancellation: false).digest == pending.originalTreeIdentity else { try fail() }
        let parts = plan.entry.relativePath.split(separator: "/").map(String.init)
        let parent = parts.count == 1 ? Darwin.dup(fd) : try openPath(fd, parts.dropLast().joined(separator: "/"))
        guard parent >= 0 else { try fail() }; defer { Darwin.close(parent) }
        guard renameatx_np(parent, String(pending.stagedPath.split(separator: "/").last!), parent, parts.last!, UInt32(RENAME_EXCL)) == 0 else { try fail() }
        guard unlinkat(fd, journalName(plan.id), 0) == 0 else { try fail() }
    }
    fileprivate static func verifyBiologyCompletion(_ plan: PersonalPermanentDeletePlan, receipts: [BiologyPermanentDeletionReceipt]) throws {
        guard let pending = plan.journal, let sources = pending.biologySources, !sources.isEmpty,
              Set(receipts.map(\.projectID)).count == receipts.count, receipts.count == sources.count,
              sources.allSatisfy({ source in receipts.contains { $0.projectID == source.projectID && $0.transactionID == plan.id && $0.sourceIdentity == source.native.sourceIdentity } }),
              pending.phase == .removing || plan.treeIdentity == pending.originalTreeIdentity else { try fail() }
    }
    private struct Tree { let digest: String; let files: Int; let bytes: Int64 }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func names(_ fd: Int32) throws -> [String] {
        guard let stream = fdopendir(Darwin.dup(fd)) else { try fail() }; defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0; guard let entry = readdir(stream) else { guard errno == 0 else { try fail() }; break }
            let capacity = Int(entry.pointee.d_namlen) + 1
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }) else { try fail() }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= maximumNodes else { throw PersonalPermanentDeleteError.tooLarge }
        }
        return result.sorted()
    }
    /// A folder cannot silently bypass lifecycle checks by containing a
    /// damaged/unrecognized native wrapper. Once inside a recognized work,
    /// its package directories are ordinary owned resources.
    private static func validateOriginals(_ fd: Int32, prefix: String, known: Set<String>, depth: Int = 0) throws {
        guard depth <= 64 else { throw PersonalPermanentDeleteError.tooLarge }
        for name in try names(fd) {
            var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { try fail() }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let path = prefix + "/" + name
            if (name as NSString).pathExtension.lowercased() == "floeproject" {
                guard known.contains(path) else { throw PersonalContentError.invalidProject }
            } else {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { try fail() }; defer { Darwin.close(child) }
                guard identity(try statFD(child)) == identity(info) else { try fail() }
                try validateOriginals(child, prefix: path, known: known, depth: depth + 1)
            }
        }
        // fdopendir operates on its duplicated descriptor's shared offset.
        // Rewind before the same original FD is fingerprinted below.
        guard lseek(fd, 0, SEEK_SET) >= 0 else { try fail() }
    }
    private static func snapshot(_ fd: Int32, checkCancellation: Bool = true) throws -> Tree {
        var hasher = SHA256(), count = 0, files = 0, bytes: Int64 = 0
        func visit(_ directory: Int32, path: String, depth: Int) throws {
            guard depth <= 256 else { throw PersonalPermanentDeleteError.tooLarge }
            let own = try statFD(directory)
            // Renaming the root changes ctime, but not its identity/content.
            hasher.update(data: Data("D\0\(path)\0\(identity(own))\0\(own.st_mode)\0\(own.st_mtimespec.tv_sec):\(own.st_mtimespec.tv_nsec)\n".utf8))
            for name in try names(directory) {
                if checkCancellation { try Task.checkCancellation() }; count += 1
                guard count <= maximumNodes else { throw PersonalPermanentDeleteError.tooLarge }
                var info = stat(); guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { try fail() }
                let relative = path.isEmpty ? name : path + "/" + name
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { try fail() }; defer { Darwin.close(child) }
                    guard identity(try statFD(child)) == identity(info) else { try fail() }
                    try visit(child, path: relative, depth: depth + 1)
                } else {
                    files += 1; let (sum, overflow) = bytes.addingReportingOverflow(max(0, Int64(info.st_size)))
                    guard !overflow else { throw PersonalPermanentDeleteError.tooLarge }; bytes = sum
                    hasher.update(data: Data("F\0\(relative)\0\(identity(info))\0\(info.st_mode)\0\(info.st_size)\0\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)\0\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n".utf8))
                }
            }
        }
        try visit(fd, path: "", depth: 0)
        return .init(digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), files: files, bytes: bytes)
    }
    fileprivate static func remove(root: URL, fd: Int32, plan: PersonalPermanentDeletePlan,
        state: PersonalLibraryTrashStore.State, checkpoint: (@Sendable (PersonalPermanentDeleteCheckpoint) throws -> Void)?, biologyCompleted: Bool = false) throws -> PersonalPermanentDeleteReceipt {
        guard biologyCompleted || !plan.members.contains(where: { $0.kind == .biology }) else { throw PersonalPermanentDeleteError.unsupportedOriginal }
        let needsStaging = plan.requiresPreparation
        var pending = (needsStaging ? nil : plan.journal) ?? .init(entry: plan.entry, coveredEntries: plan.coveredEntries, members: plan.members,
            rootIdentity: plan.rootIdentity, directoryIdentity: plan.directoryIdentity, stagedPath: stagePath(plan.entry), phase: .staged)
        let parts = plan.entry.relativePath.split(separator: "/").map(String.init), name = parts.last!
        let parent = parts.count == 1 ? Darwin.dup(fd) : try openPath(fd, parts.dropLast().joined(separator: "/"))
        guard parent >= 0 else { try fail() }; defer { Darwin.close(parent) }
        let staged = pending.stagedPath.split(separator: "/").last.map(String.init)!
        if needsStaging {
            try save(pending, fd: fd)
            guard renameatx_np(parent, name, parent, staged, UInt32(RENAME_EXCL)) == 0 else {
                _ = unlinkat(fd, journalName(plan.id), 0); try fail()
            }
            do {
                let moved = try openPath(fd, pending.stagedPath); defer { Darwin.close(moved) }
                guard identity(try statFD(moved)) == plan.directoryIdentity, try snapshot(moved).digest == plan.treeIdentity else { try fail() }
                try checkpoint?(.staged); try Task.checkCancellation(); try checkpoint?(.beforeIrreversible)
            } catch {
                // No unlink has occurred: restore the exact staged directory
                // only if its original name is still free, never clobber.
                if renameatx_np(parent, staged, parent, name, UInt32(RENAME_EXCL)) == 0 { _ = unlinkat(fd, journalName(plan.id), 0) }
                throw error
            }
        }
        do {
            if !biologyCompleted { try Task.checkCancellation() }
            pending.phase = .removing; try save(pending, fd: fd)
        } catch {
            if needsStaging,
               renameatx_np(parent, staged, parent, name, UInt32(RENAME_EXCL)) == 0 {
                _ = unlinkat(fd, journalName(plan.id), 0)
            }
            throw error
        }
        // Atomic irreversible boundary: cancellation is observed before this
        // point. Afterwards finish/read back; never claim cancellation after
        // actual removal or abandon its durable index transaction.
        do {
            if try exists(fd, pending.stagedPath) {
                let directory = try openPath(fd, pending.stagedPath); defer { Darwin.close(directory) }
                guard identity(try statFD(directory)) == plan.directoryIdentity else { try fail() }
                func erase(_ target: Int32, path: String, depth: Int) throws {
                    guard depth <= 256 else { throw PersonalPermanentDeleteError.tooLarge }
                    try checkRoot(root, fd)
                    for childName in try names(target) {
                        var info = stat(); guard fstatat(target, childName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { try fail() }
                        let relative = path + "/" + childName
                        if (info.st_mode & S_IFMT) == S_IFDIR {
                            let child = openat(target, childName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            guard child >= 0 else { try fail() }; defer { Darwin.close(child) }
                            guard identity(try statFD(child)) == identity(info) else { try fail() }
                            try erase(child, path: relative, depth: depth + 1)
                            var current = stat(); guard fstatat(target, childName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                                identity(current) == identity(info), unlinkat(target, childName, AT_REMOVEDIR) == 0 else { try fail() }
                        } else { guard unlinkat(target, childName, 0) == 0 else { throw PersonalPermanentDeleteError.incomplete } }
                        try checkpoint?(.removedNode(relative))
                    }
                }
                try erase(directory, path: "", depth: 0)
                var current = stat(); guard fstatat(parent, staged, &current, AT_SYMLINK_NOFOLLOW) == 0,
                    identity(current) == plan.directoryIdentity, unlinkat(parent, staged, AT_REMOVEDIR) == 0 else { try fail() }
            }
            try checkRoot(root, fd)
            guard !(try exists(fd, plan.entry.relativePath)), !(try exists(fd, pending.stagedPath)) else { try fail() }
            try checkpoint?(.beforeIndexCommit)
            var updated = try trash(fd)
            guard affected(updated, entry: plan.entry) == plan.coveredEntries else { try fail() }
            let removed = Set(plan.coveredEntries.map(\.id)); updated.entries.removeAll { removed.contains($0.id) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(updated)
            guard bytes.count <= 4 * 1_024 * 1_024 else { throw PersonalContentError.storageUnavailable }
            try write(fd, name: PersonalLibraryTrashStore.fileName, bytes: bytes)
            let cleanup = unlinkat(fd, journalName(plan.id), 0) != 0
            return .init(entryID: plan.id, removedEntryIDs: removed.sorted { $0.uuidString < $1.uuidString },
                projectIDs: plan.members.map(\.id), logicalBytes: plan.logicalBytes, privateJournalCleanupPending: cleanup)
        } catch { throw PersonalPermanentDeleteError.incomplete }
    }
}
