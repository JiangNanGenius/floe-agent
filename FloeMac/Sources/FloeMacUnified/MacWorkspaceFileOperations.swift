// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

@MainActor
enum MacExternalFileOpening {
    static var codeApplication: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCodeInsiders")
    }

    static func chooseApplication(for item: URL, isCurrent: @escaping () -> Bool = { true }) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "mac.external.openWith")
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let application = panel.url, isCurrent() else { return }
            open(item, in: application)
        }
    }

    static func open(_ item: URL, in application: URL) {
        Task {
            do {
                _ = try await NSWorkspace.shared.open([item], withApplicationAt: application,
                                                       configuration: NSWorkspace.OpenConfiguration())
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "mac.external.openFailed")
                alert.alertStyle = .warning
                if let window = NSApp.keyWindow {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    _ = alert.runModal()
                }
            }
        }
    }
}

/// Names and identities are captured when the user opens the action, then
/// checked again through the pinned directory when they confirm it.
struct MacWorkspaceFileOperations: Sendable {
    struct Identity: Sendable, Equatable, Codable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t
        let birthSeconds: Int
        let birth: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            type = info.st_mode & S_IFMT
            birthSeconds = info.st_birthtimespec.tv_sec
            birth = info.st_birthtimespec.tv_nsec
        }
    }

    struct Item: Sendable, Codable {
        let name: String
        let identity: Identity
    }

    struct TrashReceipt: Identifiable, Sendable {
        let id: UUID
        let original: MacWorkspaceFileOperations
        let item: Item
        let trashed: URL
        let history: URL?
        let trashDirectoryIdentity: Identity
    }

    /// Why one item of a batch trash could not be moved. The case set is
    /// deliberately small so the UI can phrase one honest sentence per
    /// survivor; the item itself stays in place for every kind.
    enum TrashFailureKind: String, Sendable, Codable {
        /// A draft attachment, the managed conversations root or one of its
        /// task folders still references the item or its directory.
        case protected
        /// The pinned identity no longer matches: the item changed or was
        /// replaced after the user opened the action.
        case changed
        /// The item is no longer at its captured name.
        case missing
        /// Any other filesystem refusal (permissions, locks, ...).
        case denied
    }

    struct TrashBatchFailure: Sendable, Equatable {
        let name: String
        let kind: TrashFailureKind
    }

    /// Batch outcome keeps successes and failures apart so the caller can
    /// report both honestly; every failed item is still at its origin.
    /// `moved` counts every item the system Trash accepted, independent of
    /// `receipts`: Finder can take an item yet deny the app read-back, so a
    /// verifiable receipt is never required for a truthful moved count.
    struct TrashBatchOutcome: Sendable {
        var moved: [String] = []
        var receipts: [TrashReceipt] = []
        var failures: [TrashBatchFailure] = []
    }

    let directory: URL
    private let root: MacAgentWorkspaceRoot
    private let directoryPath: String
    let directoryIdentity: Identity
    var rootURL: URL? { root.physicalPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    init(root rootURL: URL, directory dirURL: URL, managedConversationsRoot: URL?) throws {
        let root = MacAgentWorkspaceRoot(rootURL)
        guard let base = root.physicalPath,
              let folder = MacAgentWorkspacePinSupport.physicalPath(dirURL.path),
              Self.canonicalInput(rootURL.path, matches: base), Self.canonicalInput(dirURL.path, matches: folder),
              base != "/", MacAgentWorkspacePinSupport.isContained(folder, in: base)
        else { throw CocoaError(.fileWriteNoPermission) }
        if let managedConversationsRoot,
           let protected = MacAgentWorkspacePinSupport.physicalPath(managedConversationsRoot.path),
           folder == protected { throw CocoaError(.fileWriteNoPermission) }
        self.root = root
        self.directory = URL(fileURLWithPath: folder, isDirectory: true)
        let relative = URL(fileURLWithPath: folder).pathComponents.dropFirst(URL(fileURLWithPath: base).pathComponents.count)
        self.directoryPath = (Array(relative) + ["floe-entry"]).joined(separator: "/")
        _ = try MacAgentWorkspacePinSupport.standardizedRelativePath(directoryPath)
        directoryIdentity = try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: base, relative: directoryPath, root: root) { pin in
            var info = stat()
            guard fstat(pin.parentFileDescriptor, &info) == 0 else { throw CocoaError(.fileReadNoPermission) }
            return Identity(info)
        }
    }

    private static func canonicalInput(_ path: String, matches actual: String) -> Bool {
        path == actual || (["/tmp", "/var"].contains { path == $0 || path.hasPrefix($0 + "/") } && "/private" + path == actual)
    }

    private func withParent<T>(_ work: (Int32) throws -> T) throws -> T {
        guard let base = root.physicalPath else { throw CocoaError(.fileWriteNoPermission) }
        return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: base, relative: directoryPath, root: root) { pin in
            var info = stat()
            guard fstat(pin.parentFileDescriptor, &info) == 0, Identity(info) == directoryIdentity else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return try work(pin.parentFileDescriptor)
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") && !name.contains("\\")
            && name.utf8.count <= 255 && (try? MacAgentWorkspacePinSupport.standardizedRelativePath(name)) == name
    }

    /// Active or saved draft attachments, their containing directories, and
    /// the app-owned conversation roots cannot be renamed or trashed here.
    static func canMove(_ url: URL, protecting files: Set<URL>, managedConversationsRoot: URL?) -> Bool {
        let source = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !files.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: source) }) else { return false }
        if let managed = managedConversationsRoot?.resolvingSymlinksInPath().standardizedFileURL.pathComponents {
            if managed.starts(with: source) || Array(source.dropLast()) == managed { return false }
        }
        return true
    }

    private static func identity(at name: String, in parent: Int32) throws -> Identity {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || (type == S_IFREG && info.st_nlink == 1) else { throw CocoaError(.fileWriteNoPermission) }
        return Identity(info)
    }

    private static func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    func capture(_ name: String) throws -> Item {
        guard Self.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        return try withParent { Item(name: name, identity: try Self.identity(at: name, in: $0)) }
    }

    func createFolder(_ name: String) throws {
        guard Self.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try withParent { parent in
            guard mkdirat(parent, name, 0o700) == 0 else { throw Self.failure() }
        }
    }

    /// Exclusive publish with before/after identity validation. If another
    /// process substituted an item, put it back only into a vacant slot.
    private static func move(_ item: Item, from source: Int32, to target: Int32, name: String) throws {
        guard try identity(at: item.name, in: source) == item.identity else { throw CocoaError(.fileWriteFileExists) }
        guard renameatx_np(source, item.name, target, name, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
        guard (try? identity(at: name, in: target)) == item.identity else {
            _ = renameatx_np(target, name, source, item.name, UInt32(RENAME_EXCL))
            throw CocoaError(.fileWriteFileExists)
        }
    }

    func rename(_ item: Item, to name: String) throws {
        guard Self.validName(name), item.name != name else { throw CocoaError(.fileWriteInvalidFileName) }
        try withParent { try Self.move(item, from: $0, to: $0, name: name) }
    }

    func move(_ item: Item, to destination: Self, protecting files: Set<URL>, managedConversationsRoot: URL?) throws {
        let source = directory.appendingPathComponent(item.name)
        guard root.physicalPath == destination.root.physicalPath, directoryIdentity != destination.directoryIdentity,
              Self.canMove(source, protecting: files, managedConversationsRoot: managedConversationsRoot),
              !destination.directory.pathComponents.starts(with: source.pathComponents) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Space can display the parent of several managed task folders.
        // A move must retain the conversation that owns those files.
        if let managed = managedConversationsRoot?.resolvingSymlinksInPath().standardizedFileURL.pathComponents {
            func taskFolder(_ url: URL) -> String? {
                let path = url.pathComponents
                return path.starts(with: managed) ? path.dropFirst(managed.count).first : nil
            }
            guard taskFolder(directory) == taskFolder(destination.directory) else { throw CocoaError(.fileWriteNoPermission) }
        }
        try withParent { from in
            try destination.withParent { to in try Self.move(item, from: from, to: to, name: item.name) }
        }
    }

    /// Copy a regular file through held descriptors, preserving its contents
    /// and metadata. Publish only a complete copy and never replace a name.
    func duplicate(_ item: Item, suffix: String) throws -> String {
        guard item.identity.type == S_IFREG, Self.validName(suffix) else { throw CocoaError(.fileWriteNoPermission) }
        return try withParent { parent in
            let source = openat(parent, item.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard source >= 0 else { throw Self.failure() }
            defer { close(source) }
            var before = stat()
            guard fstat(source, &before) == 0, Identity(before) == item.identity, before.st_nlink == 1 else {
                throw CocoaError(.fileReadNoPermission)
            }
            let stage = ".floe-duplicate-" + UUID().uuidString
            let copy = openat(parent, stage, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard copy >= 0 else { throw Self.failure() }
            defer {
                var held = stat(), named = stat()
                if fstat(copy, &held) == 0, fstatat(parent, stage, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   Identity(held) == Identity(named) { _ = unlinkat(parent, stage, 0) }
                close(copy)
            }
            guard fcopyfile(source, copy, nil, copyfile_flags_t(COPYFILE_ALL)) == 0, fsync(copy) == 0 else { throw Self.failure() }
            var after = stat(), copied = stat()
            guard fstat(source, &after) == 0, after.st_nlink == 1,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                  try Self.identity(at: item.name, in: parent) == item.identity,
                  fstat(copy, &copied) == 0, copied.st_size == before.st_size else { throw CocoaError(.fileReadCorruptFile) }
            let staged = Item(name: stage, identity: Identity(copied))
            let extensionText = (item.name as NSString).pathExtension
            let ending = extensionText.isEmpty ? "" : "." + extensionText
            let stem = (item.name as NSString).deletingPathExtension
            for number in 1...Int.max {
                let tail = " " + suffix + (number == 1 ? "" : " " + String(number)) + ending
                var prefix = stem
                while !prefix.isEmpty && prefix.utf8.count + tail.utf8.count > 255 { prefix.removeLast() }
                let name = prefix + tail
                guard Self.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
                do {
                    try withParent { target in try Self.move(staged, from: parent, to: target, name: name) }
                    return name
                } catch let cause as NSError where cause.domain == NSPOSIXErrorDomain && cause.code == Int(EEXIST) {
                    continue
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
    }

    func trash(_ item: Item, recordingIn history: URL? = nil) throws -> TrashReceipt? {
        // FileManager's Trash API accepts URLs. A private staging directory
        // lets us hand it the checked inode under its original display name.
        try withParent { parent in
            let id = UUID()
            var trashedBySystem = false
            defer {
                if !trashedBySystem, let history { MacWorkspaceTrashRecord.forget(id, in: history) }
            }
            // Journal before moving. A bookmark can follow the original inode
            // even if the process exits before Trash returns its collision name.
            var record: MacWorkspaceTrashRecord?
            if let history {
                record = try MacWorkspaceTrashRecord(id: id, original: self, item: item)
                try record?.save(in: history)
            }
            let stage = "Floe Recovery " + UUID().uuidString
            guard mkdirat(parent, stage, 0o700) == 0 else { throw Self.failure() }
            defer { _ = unlinkat(parent, stage, AT_REMOVEDIR) } // only if empty
            let fd = openat(parent, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.failure() }
            defer { close(fd) }
            try Self.move(item, from: parent, to: fd, name: item.name)
            let staged = directory.appendingPathComponent(stage, isDirectory: true).appendingPathComponent(item.name)
            var resulting: NSURL?
            do {
                guard let reference = (staged as NSURL).fileReferenceURL(),
                      try Self.identity(at: item.name, in: fd) == item.identity else { throw CocoaError(.fileReadNoPermission) }
                try FileManager.default.trashItem(at: reference, resultingItemURL: &resulting)
                trashedBySystem = true
            } catch {
                // Preserve a recoverable copy in the recovery folder if the
                // original name has meanwhile been claimed.
                try Self.move(item, from: fd, to: parent, name: item.name)
                throw error
            }
            let trashed = resulting as URL?
            if let history, var record {
                // The system move has committed. Metadata is best-effort now:
                // never report a failed delete or try to move the item again
                // merely because Trash is private to Finder on this Mac.
                record.didTrash(to: trashed)
                try? record.save(in: history)
            }
            guard let trashed, trashed.isFileURL else { return nil }
            guard let trashDirectoryIdentity = Self.readableTrashDirectory(trashed.deletingLastPathComponent()) else { return nil }
            var info = stat()
            guard lstat(trashed.path, &info) == 0, Identity(info) == item.identity else { return nil }
            let receipt = TrashReceipt(id: id, original: self, item: item, trashed: trashed, history: history,
                                       trashDirectoryIdentity: trashDirectoryIdentity)
            return receipt
        }
    }

    /// Batch move to the system Trash reuses the single-item `trash` path for
    /// every entry: same pinned-identity staging, same journaling, same
    /// exclusive publish. One item's failure never aborts the remaining items
    /// and never hides them; the origin of every failed item is untouched, so
    /// the caller can keep reporting it (and the user can retry) after a
    /// partial run. Successful items are recoverable through the same
    /// receipts and history records as a single trash.
    func trashBatch(_ items: [Item], protecting files: Set<URL>,
                    managedConversationsRoot: URL?, recordingIn history: URL?) -> TrashBatchOutcome {
        var outcome = TrashBatchOutcome()
        var seen = Set<String>()
        for item in items where seen.insert(item.name).inserted {
            let url = directory.appendingPathComponent(item.name)
            guard Self.canMove(url, protecting: files, managedConversationsRoot: managedConversationsRoot) else {
                outcome.failures.append(.init(name: item.name, kind: .protected))
                continue
            }
            do {
                if let receipt = try trash(item, recordingIn: history) {
                    outcome.receipts.append(receipt)
                }
                // A nil receipt still means the system Trash accepted the
                // item: only the private receipt could not be verified.
                // Never report that as a failure or move anything back.
                outcome.moved.append(item.name)
            } catch let error as NSError {
                let kind: TrashFailureKind
                if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
                    || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue) {
                    kind = .missing
                } else if (error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST))
                    || (error.domain == NSCocoaErrorDomain
                        && (error.code == CocoaError.fileWriteFileExists.rawValue
                            || error.code == CocoaError.fileReadNoPermission.rawValue
                            || error.code == CocoaError.fileWriteNoPermission.rawValue)) {
                    // Identity mismatch and guard refusals both surface as
                    // "changed or protected"; phrase it as a refresh hint.
                    kind = .changed
                } else {
                    kind = .denied
                }
                outcome.failures.append(.init(name: item.name, kind: kind))
            }
        }
        return outcome
    }

    static func readableTrashDirectory(_ directory: URL) -> Identity? {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return Identity(info)
    }

    static func restore(_ receipt: TrashReceipt) throws {
        let trashParent = receipt.trashed.deletingLastPathComponent()
        guard let actual = MacAgentWorkspacePinSupport.physicalPath(trashParent.path),
              canonicalInput(trashParent.path, matches: actual) else { throw CocoaError(.fileWriteNoPermission) }
        // The system .Trashes ancestor on external volumes is search-only.
        // Open the user-specific directory directly, then bind the actual
        // descriptor to the captured identity before touching its entries.
        let source = open(actual, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw failure() }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, Identity(info) == receipt.trashDirectoryIdentity else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try receipt.original.withParent { destination in
            try move(Item(name: receipt.trashed.lastPathComponent, identity: receipt.item.identity),
                     from: source, to: destination, name: receipt.item.name)
        }
        if let history = receipt.history {
            MacWorkspaceTrashRecord.forget(receipt.id, in: history)
        }
    }
}

#if FLOE_MAC_HOST_SMOKE
enum MacWorkspaceFileOperationsSmoke {
    static func verifyTransfers(in root: URL) throws -> Bool {
        let fm = FileManager.default
        let base = root.appendingPathComponent("Transfers-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: base) }
        let from = try MacWorkspaceFileOperations(root: base, directory: base, managedConversationsRoot: nil)
        try from.createFolder("Destination")
        let folder = base.appendingPathComponent("Destination", isDirectory: true)
        let into = try MacWorkspaceFileOperations(root: base, directory: folder, managedConversationsRoot: nil)
        let file = base.appendingPathComponent("example.dat"), bytes = Data([0, 0xff, 7, 12])
        try bytes.write(to: file)
        let item = try from.capture("example.dat")
        let copy = try from.duplicate(item, suffix: "copy")
        let next = try from.duplicate(item, suffix: "copy")
        guard copy == "example copy.dat", next == "example copy 2.dat",
              try Data(contentsOf: base.appendingPathComponent(copy)) == bytes,
              try Data(contentsOf: base.appendingPathComponent(next)) == bytes else { return false }
        func rejected(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        let target = folder.appendingPathComponent(item.name)
        let otherBytes = Data([0x18])
        try otherBytes.write(to: target)
        guard rejected({ try from.move(item, to: into, protecting: [], managedConversationsRoot: nil) }),
              try Data(contentsOf: target) == otherBytes, try Data(contentsOf: file) == bytes else { return false }
        try fm.removeItem(at: target)
        let differentRoot = try MacWorkspaceFileOperations(root: folder, directory: folder, managedConversationsRoot: nil)
        guard rejected({ try from.move(item, to: differentRoot, protecting: [], managedConversationsRoot: nil) }),
              rejected({ try from.move(item, to: into, protecting: [file], managedConversationsRoot: nil) }),
              rejected({ try from.move(try from.capture("Destination"), to: into, protecting: [], managedConversationsRoot: nil) }),
              rejected({ _ = try from.duplicate(try from.capture("Destination"), suffix: "copy") }) else { return false }
        try from.move(item, to: into, protecting: [], managedConversationsRoot: nil)
        try bytes.write(to: file)
        guard try Data(contentsOf: target) == bytes,
              rejected({ _ = try from.duplicate(item, suffix: "copy") }),
              rejected({ try from.move(item, to: into, protecting: [], managedConversationsRoot: nil) }) else { return false }
        try into.createFolder("Nested")
        let nested = try into.capture("Nested"), held = folder.appendingPathComponent("Nested/attached.txt")
        try bytes.write(to: held)
        guard rejected({ try into.move(nested, to: from, protecting: [held], managedConversationsRoot: nil) }) else { return false }
        try into.move(nested, to: from, protecting: [], managedConversationsRoot: nil)
        let alias = base.appendingPathComponent("Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: folder)
        return try Data(contentsOf: base.appendingPathComponent("Nested/attached.txt")) == bytes
            && rejected({ _ = try from.capture("Alias") })
            && rejected({ _ = try MacWorkspaceFileOperations(root: base, directory: alias, managedConversationsRoot: nil) })
    }

    /// Synthetic batch-trash checks against the same fixture style as the
    /// single-item path: everything lives under a unique temporary root and
    /// is removed on return; the real Trash and user folders are untouched.
    static func verifyBatchTrash(in root: URL) throws -> Bool {
        func fail(_ label: String, _ detail: String = "") -> Bool {
            FileHandle.standardError.write(Data("Batch trash fixture \(label): \(detail)\n".utf8))
            return false
        }
        let fm = FileManager.default
        let base = root.appendingPathComponent("BatchTrash-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: base) }
        let ops = try MacWorkspaceFileOperations(root: base, directory: base, managedConversationsRoot: nil)
        // Unique fixture names keep the real system Trash scoped to this run.
        let tag = String(UUID().uuidString.prefix(8))
        // Each phase journals in its own history directory so a phase that
        // legitimately leaves records (restricted Trash introspection) can
        // never contaminate another phase's assertions.
        let history1 = base.appendingPathComponent("History1", isDirectory: true)
        let history2 = base.appendingPathComponent("History2", isDirectory: true)
        let history3 = base.appendingPathComponent("History3", isDirectory: true)

        // Full success. Hosts whose privacy settings deny Trash introspection
        // still journal confirmed records but can hand back zero (or only
        // some) receipts; the moved count must be truthful in every mix, and
        // put-back is exercised only when every receipt verified.
        var names: [String] = []
        var captured: [MacWorkspaceFileOperations.Item] = []
        for index in 0..<3 {
            let name = "Batch \(index) \(tag).dat"
            try Data([UInt8(index)]).write(to: base.appendingPathComponent(name))
            names.append(name)
            captured.append(try ops.capture(name))
        }
        let outcome = ops.trashBatch(captured, protecting: [], managedConversationsRoot: nil, recordingIn: history1)
        guard outcome.failures.isEmpty else {
            return fail("full.failures", outcome.failures.map { "\($0.name):\($0.kind.rawValue)" }.joined(separator: ","))
        }
        guard outcome.moved.count == 3 else {
            return fail("full.moved", "moved=\(outcome.moved.count) receipts=\(outcome.receipts.count)")
        }
        for name in names where fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            return fail("full.stillAtOrigin", name)
        }
        var records = try MacWorkspaceTrashRecord.entries(for: base, in: history1)
        guard records.count == 3 else { return fail("full.records", "count=\(records.count)") }
        guard records.allSatisfy(\.confirmedBySystem) else { return fail("full.unconfirmed") }
        if outcome.receipts.count == 3 {
            for name in names {
                guard let record = records.first(where: { $0.name == name }) else { return fail("full.recordMissing", name) }
                do { try record.restore(root: base, history: history1, managed: nil) }
                catch { return fail("full.restore", "\(name): \(error)") }
            }
            for (index, name) in names.enumerated() {
                let bytes = try Data(contentsOf: base.appendingPathComponent(name))
                guard bytes == Data([UInt8(index)]) else { return fail("full.bytes", "\(name): \(bytes.count)B") }
            }
            records = try MacWorkspaceTrashRecord.entries(for: base, in: history1)
            guard records.isEmpty else { return fail("full.recordsLeft", "count=\(records.count)") }

            // Partial failure: one captured item is replaced before the
            // batch runs. It alone fails (kind .changed) and stays at the
            // origin with the replacement bytes; the other item still
            // reaches the Trash and restores cleanly.
            let doomed = "Doomed \(tag).dat", healthy = "Healthy \(tag).dat"
            try Data("original".utf8).write(to: base.appendingPathComponent(doomed))
            try Data("fine".utf8).write(to: base.appendingPathComponent(healthy))
            let batch = [try ops.capture(doomed), try ops.capture(healthy)]
            // Atomic replace yields a new inode/birth, so the pinned identity
            // no longer matches the name — the same guard a real swap trips.
            try Data("replacement".utf8).write(to: base.appendingPathComponent(doomed), options: .atomic)
            let partial = ops.trashBatch(batch, protecting: [], managedConversationsRoot: nil, recordingIn: history2)
            guard partial.failures.count == 1, partial.failures.first?.name == doomed,
                  partial.failures.first?.kind == .changed else {
                return fail("partial.failures", partial.failures.map { "\($0.name):\($0.kind.rawValue)" }.joined(separator: ","))
            }
            guard partial.moved == [healthy] else { return fail("partial.moved", partial.moved.joined(separator: ",")) }
            guard partial.receipts.count == 1 else { return fail("partial.receipts", "count=\(partial.receipts.count)") }
            let doomedBytes = try Data(contentsOf: base.appendingPathComponent(doomed))
            guard doomedBytes == Data("replacement".utf8) else { return fail("partial.doomedBytes") }
            guard !fm.fileExists(atPath: base.appendingPathComponent(healthy).path) else { return fail("partial.healthyAtOrigin") }
            guard let healthyRecord = try MacWorkspaceTrashRecord.entries(for: base, in: history2).first,
                  healthyRecord.name == healthy else { return fail("partial.recordMissing") }
            do { try healthyRecord.restore(root: base, history: history2, managed: nil) }
            catch { return fail("partial.restore", String(describing: error)) }
            guard try Data(contentsOf: base.appendingPathComponent(healthy)) == Data("fine".utf8) else {
                return fail("partial.healthyBytes")
            }
        } else if outcome.receipts.isEmpty {
            FileHandle.standardError.write(Data(("Batch trash fixture: restricted Trash read-back; "
                                                + "skipped put-back checks, \(names.count) uniquely named "
                                                + "items remain in the system Trash.\n").utf8))
        } else {
            FileHandle.standardError.write(Data(("Batch trash fixture: mixed Trash read-back "
                                                + "(\(outcome.receipts.count)/3); skipped put-back checks.\n").utf8))
        }

        // Protection guard: an item referenced by the protected set is
        // reported as .protected, kept in place, and never journaled. This
        // phase never depends on Trash introspection.
        let held = "Held \(tag).dat"
        let heldURL = base.appendingPathComponent(held)
        try Data("held".utf8).write(to: heldURL)
        let blocked = ops.trashBatch([try ops.capture(held)], protecting: [heldURL],
                                     managedConversationsRoot: nil, recordingIn: history3)
        guard blocked.moved.isEmpty else { return fail("protected.moved", blocked.moved.joined(separator: ",")) }
        guard blocked.receipts.isEmpty else { return fail("protected.receipts") }
        guard blocked.failures == [.init(name: held, kind: .protected)] else {
            return fail("protected.failures", blocked.failures.map { "\($0.name):\($0.kind.rawValue)" }.joined(separator: ","))
        }
        guard try Data(contentsOf: heldURL) == Data("held".utf8) else { return fail("protected.bytes") }
        guard try MacWorkspaceTrashRecord.entries(for: base, in: history3).isEmpty else { return fail("protected.journaled") }
        return true
    }

    static func verify(in root: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            func fail(_ error: Error? = nil, line: Int = #line) -> Bool {
                let detail = error.map { String(describing: $0) } ?? "unexpected file state"
                FileHandle.standardError.write(Data("File actions fixture line \(line): \(detail)\n".utf8))
                return false
            }
            let fm = FileManager.default
            let base = root.appendingPathComponent("FileActions-" + UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: base, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: base) }
                let ops = try MacWorkspaceFileOperations(root: base, directory: base, managedConversationsRoot: nil)
                guard try verifyTransfers(in: base) else { return fail() }
                guard try verifyBatchTrash(in: base) else { return fail() }
                try ops.createFolder("Input")
                try ops.createFolder("Other")
                do { try ops.createFolder("Input"); return fail() } catch {}
                do { try ops.createFolder("../outside"); return fail() } catch {}
                let source = try ops.capture("Input")
                do { try ops.rename(source, to: "Other"); return fail() } catch {}
                let original = base.appendingPathComponent("Input", isDirectory: true)
                let held = original.appendingPathComponent("note.txt")
                try Data("Original fixture".utf8).write(to: held)
                guard !MacWorkspaceFileOperations.canMove(original, protecting: [held], managedConversationsRoot: nil),
                      !MacWorkspaceFileOperations.canMove(original, protecting: [], managedConversationsRoot: base) else { return fail() }
                try ops.rename(source, to: "Renamed")
                try ops.createFolder("Input") // Replacement at the old path.
                do { try ops.rename(source, to: "Wrong"); return fail() } catch {}
                let name = "Floe fixture " + UUID().uuidString
                try ops.rename(ops.capture("Renamed"), to: name)
                let target = base.appendingPathComponent(name, isDirectory: true)
                let symlink = base.appendingPathComponent("Link")
                try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
                let history = base.appendingPathComponent("History", isDirectory: true)
                guard (try? ops.capture("Link")) == nil,
                      (try? MacWorkspaceFileOperations(root: base, directory: symlink, managedConversationsRoot: nil)) == nil else { return fail() }
                guard let receipt = try ops.trash(ops.capture(name), recordingIn: history) else {
                    let entries = try MacWorkspaceTrashRecord.entries(for: base, in: history)
                    guard !fm.fileExists(atPath: target.path), entries.count == 1,
                          let entry = entries.first, entry.name == name, entry.confirmedBySystem,
                          case .unavailable = entry.availability(root: base, history: history, managed: nil)
                    else { return fail() }
                    FileHandle.standardError.write(Data("Verified Finder recovery with restricted Trash access.\n".utf8))
                    return true
                }
                defer {
                    if !fm.fileExists(atPath: target.path) { try? MacWorkspaceFileOperations.restore(receipt) }
                }
                // Reopen only durable metadata: the live receipt is never
                // passed to the restore being exercised here.
                guard !fm.fileExists(atPath: target.path),
                      let reopened = try MacWorkspaceTrashRecord.entries(for: base, in: history).first,
                      reopened.id == receipt.id,
                      try MacWorkspaceTrashRecord.entries(for: original, in: history).isEmpty,
                      case .unavailable = reopened.availability(root: base.appendingPathComponent("Offline"), history: history, managed: nil)
                else { return fail() }
                try ops.createFolder(name)
                do { try reopened.restore(root: base, history: history, managed: nil); return fail() } catch {}
                guard try MacWorkspaceTrashRecord.entries(for: base, in: history).count == 1 else { return fail() }
                try ops.rename(ops.capture(name), to: "Collision kept")
                try reopened.restore(root: base, history: history, managed: nil)
                guard try MacWorkspaceTrashRecord.entries(for: base, in: history).isEmpty else { return fail() }

                // Simulate Finder moving or emptying only this test's items.
                for moveAway in [true, false] {
                    let leaf = "Floe file actions " + UUID().uuidString
                    let url = base.appendingPathComponent(leaf)
                    try Data("Fixture".utf8).write(to: url)
                    guard let moved = try ops.trash(ops.capture(leaf), recordingIn: history),
                          let remembered = try MacWorkspaceTrashRecord.entries(for: base, in: history).first else { return fail() }
                    let elsewhere = base.appendingPathComponent("Finder " + leaf)
                    if moveAway { try fm.moveItem(at: moved.trashed, to: elsewhere) }
                    else { try fm.removeItem(at: moved.trashed) }
                    do { try remembered.restore(root: base, history: history, managed: nil); return fail() }
                    catch MacWorkspaceTrashRecord.HistoryError.removed {}
                    guard !fm.fileExists(atPath: url.path), try MacWorkspaceTrashRecord.entries(for: base, in: history).isEmpty,
                          !moveAway || (try? Data(contentsOf: elsewhere)) == Data("Fixture".utf8) else { return fail() }
                }
                return try Data(contentsOf: target.appendingPathComponent("note.txt")) == Data("Original fixture".utf8)
                    && fm.fileExists(atPath: base.appendingPathComponent("Other").path)
                    && fm.fileExists(atPath: base.appendingPathComponent("Input").path)
                    && fm.fileExists(atPath: base.appendingPathComponent("Collision kept").path)
            } catch { return fail(error) }
        }.value
    }
}
#endif
