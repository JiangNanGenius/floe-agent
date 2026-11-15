// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameRGSS
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded storage for standard RGSS save files. The root is an explicitly
/// owned save layer outside the immutable source; every write is atomic and
/// every multi-file operation is one journaled, recoverable transaction.
///
/// All public reads and mutations take one cross-process lock located beside
/// the save root. Another store instance, the run stager's collect path and a
/// UI action therefore serialize on the same layer. A pending transaction is
/// recovered before the requested operation.
public struct RGSSGuestSaveStore: Sendable {
    public let root: URL
    public let engine: GameEngineID
    public let sourceRoot: URL

    let control: RGSSGuestSaveControl
    let limits: RGSSGuestSaveLimitsOverride
    let hooks: RGSSGuestSaveTransactionHooks

    public init(root: URL, engine: GameEngineID, sourceRoot: URL) throws {
        try self.init(root: root, engine: engine, sourceRoot: sourceRoot,
                      qualificationLimits: .standard, hooks: .none)
    }

    /// Qualification seam. Production always uses the public initializer;
    /// the override may only lower the package limits.
    init(root: URL, engine: GameEngineID, sourceRoot: URL,
         qualificationLimits: RGSSGuestSaveLimitsOverride,
         hooks: RGSSGuestSaveTransactionHooks) throws {
        guard root.isFileURL, sourceRoot.isFileURL, RGSSEngineProfiles.isRGSS(engine) else {
            throw RGSSGuestRunError.saveLayerViolation("invalid save store identity")
        }
        let save = root.standardizedFileURL.resolvingSymlinksInPath()
        let source = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard save.path != source.path,
              !RGSSGuestRootResolver.isDescendant(save, of: source),
              !RGSSGuestRootResolver.isDescendant(source, of: save) else {
            throw RGSSGuestRunError.saveLayerViolation("save layer must be outside the source root")
        }
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        let values = try save.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RGSSGuestRunError.saveLayerViolation("save layer is not a regular directory")
        }
        let control = try RGSSGuestSaveControl(root: save)
        guard control.directory.path != source.path,
              !RGSSGuestRootResolver.isDescendant(control.directory, of: source),
              !RGSSGuestRootResolver.isDescendant(source, of: control.directory) else {
            throw RGSSGuestRunError.saveLayerViolation(
                "save transaction control directory is inside the source root")
        }
        self.root = save
        self.engine = engine
        self.sourceRoot = source
        self.control = control
        self.limits = qualificationLimits
        self.hooks = hooks
    }

    // MARK: - Reads

    public func list() throws -> [RGSSGuestSaveDescriptor] {
        try withExclusive { try listLocked() }
    }

    public func read(_ name: String) throws -> Data {
        guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        return try withExclusive {
            try RGSSGuestAtomicFile.read(root.appendingPathComponent(name),
                                         maximumBytes: limits.maximumFileBytes)
        }
    }

    /// A consistent point-in-time copy used by checkpoints. The whole layer is
    /// read under the same lock, so a concurrent UI write cannot mix revisions.
    public func snapshot() throws -> [RGSSGuestSaveSnapshotFile] {
        try withExclusive {
            var result: [RGSSGuestSaveSnapshotFile] = []
            for descriptor in try listLocked() {
                let data = try RGSSGuestAtomicFile.read(
                    root.appendingPathComponent(descriptor.name),
                    maximumBytes: limits.maximumFileBytes)
                guard data.count == descriptor.bytes,
                      GameDigest.sha256(data) == descriptor.sha256 else {
                    throw RGSSGuestRunError.saveBytesMismatch(descriptor.name)
                }
                result.append(.init(descriptor: descriptor, data: data))
            }
            return result
        }
    }

    // MARK: - Mutations

    public func write(_ data: Data, name: String) throws {
        _ = try write(data, name: name, expectedSHA256: nil)
    }

    @discardableResult
    public func write(_ data: Data, name: String,
                      expectedSHA256: String?) throws -> RGSSGuestSaveMutationReceipt {
        guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        guard data.count <= limits.maximumFileBytes else {
            throw RGSSGuestRunError.saveLimitExceeded(name)
        }
        return try withExclusive {
            let inventory = try listLocked()
            let existing = inventory.first { $0.name == name }
            if let expectedSHA256 {
                guard let existing else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) does not exist; expected \(expectedSHA256)")
                }
                guard existing.sha256 == expectedSHA256 else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) changed; expected \(expectedSHA256), found \(existing.sha256)")
                }
            }
            let currentBytes = inventory.reduce(0) { $0 + $1.bytes }
            let existingBytes = existing?.bytes ?? 0
            guard currentBytes - existingBytes
                    <= limits.maximumTotalBytes - data.count else {
                throw RGSSGuestRunError.saveLimitExceeded("save layer total bytes")
            }
            if existing == nil, inventory.count >= limits.maximumFiles {
                throw RGSSGuestRunError.saveLimitExceeded("save layer file count")
            }
            let digest = GameDigest.sha256(data)
            let preserved = inventory.map(\.name).filter { $0 != name }
            if let existing, existing.sha256 == digest, existing.bytes == data.count {
                return RGSSGuestSaveMutationReceipt(
                    outcome: .alreadySatisfied, operation: "write", transactionID: nil,
                    unchangedNames: [name], preservedNames: preserved,
                    inventory: inventory)
            }
            let destination = root.appendingPathComponent(name)
            if RGSSGuestSaveFileOps.exists(destination.path) {
                guard RGSSGuestSaveFileOps.isRegularFile(destination.path),
                      !RGSSGuestSaveFileOps.isSymbolicLink(destination.path) else {
                    throw RGSSGuestRunError.saveLayerViolation(
                        "save entry is not a regular file: \(name)")
                }
            }
            try RGSSGuestAtomicFile.write(data, to: destination, insideRoot: root)
            // Build the receipt from the pre-write inventory. Re-reading after
            // the atomic rename could observe cancellation and throw after the
            // bytes were already committed.
            var after = inventory.filter { $0.name != name }
            after.append(.init(name: name, bytes: data.count, sha256: digest,
                               modifiedAt: Date()))
            after.sort { $0.name < $1.name }
            return RGSSGuestSaveMutationReceipt(
                outcome: .committed, operation: "write", transactionID: nil,
                createdNames: existing == nil ? [name] : [],
                replacedNames: existing == nil ? [] : [name],
                unchangedNames: [], preservedNames: preserved,
                inventory: after)
        }
    }

    public func delete(_ name: String) throws {
        _ = try delete(name, expectedSHA256: nil)
    }

    @discardableResult
    public func delete(_ name: String,
                       expectedSHA256: String?) throws -> RGSSGuestSaveMutationReceipt {
        guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        return try withExclusive {
            let inventory = try listLocked()
            guard let existing = inventory.first(where: { $0.name == name }) else {
                throw RGSSGuestRunError.invalidSaveName(name)
            }
            if let expectedSHA256, existing.sha256 != expectedSHA256 {
                throw RGSSGuestRunError.savePreconditionFailed(
                    "\(name) changed; expected \(expectedSHA256), found \(existing.sha256)")
            }
            let url = root.appendingPathComponent(name)
            guard RGSSGuestSaveFileOps.isRegularFile(url.path),
                  !RGSSGuestSaveFileOps.isSymbolicLink(url.path) else {
                throw RGSSGuestRunError.saveLayerViolation(
                    "save entry is not a regular file: \(name)")
            }
            try RGSSGuestSaveFileOps.remove(url.path)
            RGSSGuestSaveFileOps.syncDirectory(root.path)
            let after = inventory.filter { $0.name != name }
            return RGSSGuestSaveMutationReceipt(
                outcome: .committed, operation: "delete", transactionID: nil,
                removedNames: [name], preservedNames: after.map(\.name),
                inventory: after)
        }
    }

    public func rename(_ name: String, to newName: String) throws {
        let receipt = try renameTransaction(name, to: newName, expectedSHA256: nil)
        if receipt.outcome == .requiresRetry {
            throw RGSSGuestRunError.saveRenameRetryRequired(source: name, destination: newName)
        }
    }

    /// A rename is a same-directory hard link followed by unlinking the old
    /// name. If the unlink is interrupted, both names contain the same inode;
    /// `.requiresRetry` reports that safe duplicate explicitly. Repeating the
    /// call removes the source without overwriting different bytes.
    @discardableResult
    public func renameTransaction(_ name: String, to newName: String,
                                  expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine),
              RGSSGuestSaveLimits.isValidSaveName(newName, engine: engine) else {
            throw RGSSGuestRunError.invalidSaveName("\(name) -> \(newName)")
        }
        guard name != newName else {
            return RGSSGuestSaveMutationReceipt(
                outcome: .alreadySatisfied, operation: "rename", transactionID: nil,
                unchangedNames: [name])
        }
        guard name.lowercased() != newName.lowercased() else {
            throw RGSSGuestRunError.invalidSaveName(
                "case-only rename is not supported by case-insensitive save volumes")
        }
        return try withExclusive {
            let inventory = try listLocked()
            guard let source = inventory.first(where: { $0.name == name }) else {
                throw RGSSGuestRunError.invalidSaveName(name)
            }
            if let expectedSHA256, source.sha256 != expectedSHA256 {
                throw RGSSGuestRunError.savePreconditionFailed(
                    "\(name) changed; expected \(expectedSHA256), found \(source.sha256)")
            }
            let sourceURL = root.appendingPathComponent(name)
            let destinationURL = root.appendingPathComponent(newName)
            let preserved = inventory.map(\.name).filter { $0 != name && $0 != newName }

            func inventoryAfterRename() -> [RGSSGuestSaveDescriptor] {
                var after = inventory.filter { $0.name != name && $0.name != newName }
                after.append(.init(name: newName, bytes: source.bytes,
                                   sha256: source.sha256,
                                   modifiedAt: source.modifiedAt ?? Date()))
                after.sort { $0.name < $1.name }
                return after
            }

            func finished(_ message: String?) -> RGSSGuestSaveMutationReceipt {
                RGSSGuestSaveMutationReceipt(
                    outcome: .committed, operation: "rename", transactionID: nil,
                    createdNames: [newName], removedNames: [name],
                    unchangedNames: [], preservedNames: preserved,
                    inventory: inventoryAfterRename(), message: message)
            }

            func duplicateInventory() -> [RGSSGuestSaveDescriptor] {
                var after = inventory
                after.append(.init(name: newName, bytes: source.bytes,
                                   sha256: source.sha256,
                                   modifiedAt: source.modifiedAt ?? Date()))
                after.sort { $0.name < $1.name }
                return after
            }

            if RGSSGuestSaveFileOps.exists(destinationURL.path) {
                guard RGSSGuestSaveFileOps.isRegularFile(destinationURL.path),
                      !RGSSGuestSaveFileOps.isSymbolicLink(destinationURL.path),
                      RGSSGuestSaveFileOps.sameFile(sourceURL.path, destinationURL.path) else {
                    throw RGSSGuestRunError.saveDestinationExists(newName)
                }
                // Finish a previously interrupted link+unlink rename.
                try RGSSGuestSaveFileOps.remove(sourceURL.path)
                RGSSGuestSaveFileOps.syncDirectory(root.path)
                return finished("finished an interrupted rename")
            }
            if inventory.count == limits.maximumFiles {
                // A link+unlink interruption would create a 65th slot and
                // make the strict inventory unreadable. Use the platform's
                // atomic non-replacing rename while the layer is at capacity.
                #if canImport(Darwin)
                guard Darwin.renamex_np(sourceURL.path, destinationURL.path,
                                         UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw RGSSGuestRunError.saveDestinationExists(newName) }
                    throw RGSSGuestRunError.saveLayerViolation("cannot atomically rename a full save layer")
                }
                RGSSGuestSaveFileOps.syncDirectory(root.path)
                return finished(nil)
                #else
                throw RGSSGuestRunError.saveLimitExceeded("rename needs a spare slot on this filesystem")
                #endif
            }
            guard link(sourceURL.path, destinationURL.path) == 0 else {
                if errno == EEXIST,
                   RGSSGuestSaveFileOps.sameFile(sourceURL.path, destinationURL.path) {
                    try RGSSGuestSaveFileOps.remove(sourceURL.path)
                    RGSSGuestSaveFileOps.syncDirectory(root.path)
                    return finished("finished an interrupted rename")
                }
                throw RGSSGuestRunError.saveLayerViolation("cannot link the save name")
            }
            RGSSGuestSaveFileOps.syncDirectory(root.path)
            do {
                try hooks.hit(.renameLinked, name: newName)
            } catch let crash as RGSSGuestSaveInjectedCrash {
                throw crash
            } catch {
                return RGSSGuestSaveMutationReceipt(
                    outcome: .requiresRetry, operation: "rename", transactionID: nil,
                    unchangedNames: [name, newName], preservedNames: preserved,
                    inventory: duplicateInventory(),
                    message: "both \(name) and \(newName) exist with identical bytes; "
                        + "repeat the rename to remove the source")
            }
            guard unlink(sourceURL.path) == 0 else {
                return RGSSGuestSaveMutationReceipt(
                    outcome: .requiresRetry, operation: "rename", transactionID: nil,
                    unchangedNames: [name, newName], preservedNames: preserved,
                    inventory: duplicateInventory(),
                    message: "both \(name) and \(newName) exist with identical bytes; "
                        + "repeat the rename to remove the source")
            }
            RGSSGuestSaveFileOps.syncDirectory(root.path)
            return finished(nil)
        }
    }

    @discardableResult
    public func importContent(_ data: Data, name: String,
                              policy: RGSSGuestSaveImportPolicy) throws
        -> RGSSGuestSaveMutationReceipt {
        guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        guard data.count <= limits.maximumFileBytes else {
            throw RGSSGuestRunError.saveLimitExceeded(name)
        }
        return try withExclusive {
            let inventory = try listLocked()
            let existing = inventory.first { $0.name == name }
            var backup: RGSSGuestSaveRawBackup?
            switch policy {
            case .rejectExisting:
                if existing != nil {
                    throw RGSSGuestRunError.saveDestinationExists(name)
                }
            case .replace(let expectedSHA256):
                guard let existing else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) does not exist; expected \(expectedSHA256)")
                }
                guard existing.sha256 == expectedSHA256 else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) changed; expected \(expectedSHA256), found \(existing.sha256)")
                }
            case .replaceKeepingBackup:
                if let existing {
                    let oldData = try RGSSGuestAtomicFile.read(
                        root.appendingPathComponent(name),
                        maximumBytes: limits.maximumFileBytes)
                    guard GameDigest.sha256(oldData) == existing.sha256 else {
                        throw RGSSGuestRunError.savePreconditionFailed(
                            "\(name) changed while the import backup was prepared")
                    }
                    backup = try writeBackup(oldData, name: name,
                                             sha256: existing.sha256)
                }
            case .replaceKeepingBackupVerified(let expectedSHA256):
                // The row may have been displayed before the confirmation
                // alert. Re-check the current digest under the save lock, then
                // retain those exact old bytes before replacing them.
                guard let existing else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) does not exist; expected \(expectedSHA256)")
                }
                guard existing.sha256 == expectedSHA256 else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) changed; expected \(expectedSHA256), found \(existing.sha256)")
                }
                let oldData = try RGSSGuestAtomicFile.read(
                    root.appendingPathComponent(name),
                    maximumBytes: limits.maximumFileBytes)
                guard GameDigest.sha256(oldData) == expectedSHA256 else {
                    throw RGSSGuestRunError.savePreconditionFailed(
                        "\(name) changed while the import backup was prepared")
                }
                backup = try writeBackup(oldData, name: name, sha256: expectedSHA256)
            }
            let receipt = try applyPutsLocked([(name: name, data: data)],
                                              operation: "import",
                                              checkpointRevision: nil,
                                              backupDirectory: backup?.url,
                                              rawBackupID: backup?.id)
            if let backup {
                control.pruneBackups(keeping: backup.url)
            }
            return receipt
        }
    }

    /// Stable convenience spelling for the root save panel: replace only if
    /// the current bytes still match the row digest, and retain a verified raw
    /// backup of those old bytes. This path does not use the 4 MiB checkpoint
    /// envelope, so a legitimate 16 MiB raw save is supported.
    @discardableResult
    public func importContent(_ data: Data, name: String,
                              expectedSHA256: String, keepBackup: Bool) throws
        -> RGSSGuestSaveMutationReceipt {
        let policy: RGSSGuestSaveImportPolicy = keepBackup
            ? .replaceKeepingBackupVerified(expectedSHA256: expectedSHA256)
            : .replace(expectedSHA256: expectedSHA256)
        return try importContent(data, name: name, policy: policy)
    }

    /// Newest first. Malformed backup directories are skipped; a corrupted
    /// backup is still reported by `restoreRawBackup` when selected.
    public func listRawBackups() throws -> [RGSSGuestSaveRawBackupDescriptor] {
        try withExclusive { try listRawBackupsLocked() }
    }

    public func latestRawBackup(for name: String) throws
        -> RGSSGuestSaveRawBackupDescriptor? {
        try withExclusive {
            try listRawBackupsLocked().first { $0.name == name }
        }
    }

    /// Restores one retained raw backup through the same journaled transaction
    /// as checkpoint restore. If the live file differs, the bytes being
    /// replaced are themselves retained as a new raw backup first, so this
    /// operation is reversible.
    @discardableResult
    public func restoreRawBackup(id: UUID,
                                 expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        try withExclusive {
            try restoreRawBackupLocked(id: id, expectedSHA256: expectedSHA256)
        }
    }

    @discardableResult
    public func restoreLatestRawBackup(for name: String,
                                       expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        try withExclusive {
            guard let latest = try listRawBackupsLocked().first(where: { $0.name == name }) else {
                throw RGSSGuestRunError.saveRawBackupMissingForName(name)
            }
            return try restoreRawBackupLocked(id: latest.id,
                                              expectedSHA256: expectedSHA256)
        }
    }

    // MARK: - Run copy

    /// Copies the owned save layer into a freshly staged run directory. The
    /// source run/root relationship is checked, and the whole layer is read
    /// under one lock so a concurrent UI mutation cannot mix revisions.
    @discardableResult
    public func stage(into runRoot: URL) throws -> [String] {
        let run = runRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard run.path != sourceRoot.path,
              !RGSSGuestRootResolver.isDescendant(run, of: sourceRoot) else {
            throw RGSSGuestRunError.runLayerViolation("run root is inside the source")
        }
        try RGSSGuestRootResolver.requireOutside(run, source: root, kind: "run copy")
        return try withExclusive {
            var names: [String] = []
            for file in try listLocked() {
                let data = try RGSSGuestAtomicFile.read(
                    root.appendingPathComponent(file.name),
                    maximumBytes: limits.maximumFileBytes)
                try RGSSGuestAtomicFile.write(data,
                                              to: run.appendingPathComponent(file.name),
                                              insideRoot: run)
                names.append(file.name)
            }
            return names
        }
    }

    /// Collects standard saves written by the engine from the run copy back
    /// into the owned save layer. All accepted files are one transaction: a
    /// name/limit failure imports nothing. Unknown files are reported, never
    /// renamed or deleted.
    @discardableResult
    public func collect(from runRoot: URL) throws -> RGSSGuestSaveCollection {
        let run = runRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard run.path != sourceRoot.path,
              !RGSSGuestRootResolver.isDescendant(run, of: sourceRoot) else {
            throw RGSSGuestRunError.runLayerViolation("run root is inside the source")
        }
        try RGSSGuestRootResolver.requireOutside(run, source: root, kind: "run copy")
        let names = try FileManager.default.contentsOfDirectory(atPath: run.path)
        var puts: [(name: String, data: Data)] = []
        var skipped: [String] = []
        var digests: [String: String] = [:]
        var total = 0
        var seen = Set<String>()
        for name in names.sorted() {
            guard !RGSSGuestSafeTree.isAdministrative(name) else { continue }
            let url = run.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine) else {
                skipped.append(name)
                continue
            }
            let data = try RGSSGuestAtomicFile.read(url,
                                                    maximumBytes: limits.maximumFileBytes)
            guard total <= limits.maximumTotalBytes - data.count else {
                throw RGSSGuestRunError.saveLimitExceeded("collected save total bytes")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw RGSSGuestRunError.saveDuplicateName(name)
            }
            total += data.count
            puts.append((name: name, data: data))
            digests[name] = GameDigest.sha256(data)
        }
        _ = try withExclusive {
            try applyPutsLocked(puts, operation: "collect",
                                checkpointRevision: nil, backupDirectory: nil)
        }
        return .init(names: puts.map { $0.name }, bytes: total,
                     digests: digests, skipped: skipped)
    }

    // MARK: - Recovery

    /// Recovers every pending transaction and returns its id. The next public
    /// operation also performs this recovery automatically.
    @discardableResult
    public func recoverPendingTransactions() throws -> [UUID] {
        try control.withLock { try recoverPendingLocked() }
    }

    // MARK: - Locked internals

    func withExclusive<T>(_ body: () throws -> T) throws -> T {
        try control.withLock {
            _ = try recoverPendingLocked()
            return try body()
        }
    }

    func listLocked() throws -> [RGSSGuestSaveDescriptor] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var result: [RGSSGuestSaveDescriptor] = []
        var total = 0
        for name in names.sorted() {
            guard RGSSGuestSaveLimits.isValidSaveName(name, engine: engine) else { continue }
            let url = root.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                          .isSymbolicLinkKey,
                                                          .fileSizeKey,
                                                          .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RGSSGuestRunError.saveLayerViolation("save entry is not a regular file")
            }
            let data = try RGSSGuestAtomicFile.read(url,
                                                    maximumBytes: limits.maximumFileBytes)
            guard total <= limits.maximumTotalBytes - data.count else {
                throw RGSSGuestRunError.saveLimitExceeded("save layer total bytes")
            }
            total += data.count
            result.append(.init(name: name, bytes: data.count,
                                sha256: GameDigest.sha256(data),
                                modifiedAt: values.contentModificationDate))
            guard result.count <= limits.maximumFiles else {
                throw RGSSGuestRunError.saveLimitExceeded("save layer file count")
            }
        }
        return result
    }

    func applyPuts(_ puts: [(name: String, data: Data)], operation: String,
                   checkpointRevision: UInt64?) throws -> RGSSGuestSaveMutationReceipt {
        try withExclusive {
            try applyPutsLocked(puts, operation: operation,
                                checkpointRevision: checkpointRevision,
                                backupDirectory: nil)
        }
    }

    func writeBackup(_ data: Data, name: String,
                     sha256: String) throws -> RGSSGuestSaveRawBackup {
        let backup = try control.makeBackupDirectory()
        let file = backup.url.appendingPathComponent(name)
        do {
            try RGSSGuestSaveFileOps.writeExclusive(data, to: file.path)
            let verified = try RGSSGuestSaveFileOps.read(
                file.path, maximumBytes: limits.maximumFileBytes)
            guard verified == data, GameDigest.sha256(verified) == sha256 else {
                throw RGSSGuestRunError.saveBytesMismatch(name)
            }
            let manifest = RGSSGuestSaveBackupManifest(
                format: RGSSGuestSaveBackupManifest.format,
                version: RGSSGuestSaveBackupManifest.version,
                id: backup.id, name: name, sha256: sha256,
                bytes: data.count, createdAt: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try RGSSGuestSaveFileOps.atomicWrite(
                try encoder.encode(manifest),
                to: backup.url.appendingPathComponent("manifest.json"))
            RGSSGuestSaveFileOps.syncDirectory(backup.url.path)
            return backup
        } catch {
            try? RGSSGuestSaveFileOps.removeTree(backup.url)
            throw error
        }
    }
}

/// Explicit checkpoint history for the whole save layer. It deliberately uses
/// the existing `FileGameSaveRepository` (project/owner-scoped, CAS-style
/// revision fence) and stores a JSON envelope of base64 save bytes.
public actor RGSSGuestSaveManager {
    public let store: RGSSGuestSaveStore
    public let checkpointRepository: FileGameSaveRepository?

    private struct CheckpointFile: Codable, Sendable {
        let name: String
        let sha256: String
        let data: String
    }
    private struct Checkpoint: Codable, Sendable {
        let format: String
        let version: Int
        let engine: GameEngineID
        let files: [CheckpointFile]
    }

    public init(store: RGSSGuestSaveStore,
                checkpointRepository: FileGameSaveRepository? = nil) {
        self.store = store
        self.checkpointRepository = checkpointRepository
    }

    /// `false` means checkpoint/restore is not wired on this host. The UI must
    /// show that limitation; it must not present `nil` as an empty checkpoint.
    public nonisolated var supportsCheckpoints: Bool {
        checkpointRepository != nil
    }

    public nonisolated var checkpointAvailability: RGSSGuestCheckpointAvailability {
        checkpointRepository == nil
            ? .unsupported("Checkpoint storage is not configured for this save layer.")
            : .supported
    }

    public func list() throws -> [RGSSGuestSaveDescriptor] { try store.list() }
    public func read(_ name: String) throws -> Data { try store.read(name) }
    public func write(_ data: Data, name: String) throws { try store.write(data, name: name) }
    public func delete(_ name: String) throws { try store.delete(name) }
    public func rename(_ name: String, to newName: String) throws {
        try store.rename(name, to: newName)
    }

    @discardableResult
    public func write(_ data: Data, name: String,
                      expectedSHA256: String?) throws -> RGSSGuestSaveMutationReceipt {
        try store.write(data, name: name, expectedSHA256: expectedSHA256)
    }

    @discardableResult
    public func delete(_ name: String,
                       expectedSHA256: String?) throws -> RGSSGuestSaveMutationReceipt {
        try store.delete(name, expectedSHA256: expectedSHA256)
    }

    @discardableResult
    public func renameTransaction(_ name: String, to newName: String,
                                  expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        try store.renameTransaction(name, to: newName, expectedSHA256: expectedSHA256)
    }

    public func importFile(from source: URL) throws -> RGSSGuestSaveDescriptor {
        let receipt = try importFile(from: source, policy: .rejectExisting)
        let name = source.lastPathComponent
        guard let descriptor = receipt.inventory.first(where: { $0.name == name }) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        return descriptor
    }

    @discardableResult
    public func importFile(from source: URL,
                           policy: RGSSGuestSaveImportPolicy) throws
        -> RGSSGuestSaveMutationReceipt {
        let request = try importRequest(from: source)
        return try store.importContent(request.data, name: request.name, policy: policy)
    }

    @discardableResult
    public func importFile(from source: URL,
                           expectedSHA256: String) throws
        -> RGSSGuestSaveMutationReceipt {
        try importFile(from: source, policy: .replace(expectedSHA256: expectedSHA256))
    }

    /// Atomic CAS + retained raw backup replacement for a save-panel row. The
    /// current digest is rechecked under the save lock and the exact old bytes
    /// are retained before the new bytes commit. This does not use the 4 MiB
    /// checkpoint envelope.
    @discardableResult
    public func importFile(from source: URL,
                           expectedSHA256: String,
                           keepBackup: Bool) throws
        -> RGSSGuestSaveMutationReceipt {
        let request = try importRequest(from: source)
        return try store.importContent(request.data, name: request.name,
                                       expectedSHA256: expectedSHA256,
                                       keepBackup: keepBackup)
    }

    public func listRawBackups() throws -> [RGSSGuestSaveRawBackupDescriptor] {
        try store.listRawBackups()
    }

    public func latestRawBackup(for name: String) throws
        -> RGSSGuestSaveRawBackupDescriptor? {
        try store.latestRawBackup(for: name)
    }

    @discardableResult
    public func restoreRawBackup(id: UUID,
                                 expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        try store.restoreRawBackup(id: id, expectedSHA256: expectedSHA256)
    }

    @discardableResult
    public func restoreLatestRawBackup(for name: String,
                                       expectedSHA256: String?) throws
        -> RGSSGuestSaveMutationReceipt {
        try store.restoreLatestRawBackup(for: name, expectedSHA256: expectedSHA256)
    }

    public func exportFile(_ name: String, to destination: URL) throws -> RGSSGuestSaveDescriptor {
        guard destination.isFileURL else {
            throw RGSSGuestRunError.invalidSaveName(destination.lastPathComponent)
        }
        let data = try store.read(name)
        let values = try destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RGSSGuestRunError.saveLayerViolation("export destination")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".floe-rgss-export-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: [.atomic])
            #if canImport(Darwin)
            let renamed = Darwin.rename(temporary.path, destination.path)
            #else
            let renamed = Glibc.rename(temporary.path, destination.path)
            #endif
            guard renamed == 0 else {
                throw RGSSGuestRunError.saveLayerViolation("cannot export save")
            }
        } catch let error as RGSSGuestRunError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw RGSSGuestRunError.saveLayerViolation("cannot export save")
        }
        return .init(name: name, bytes: data.count, sha256: GameDigest.sha256(data),
                     modifiedAt: Date())
    }

    /// Saves a checkpoint only when the whole envelope fits the existing save
    /// repository's 4 MiB state ceiling. Larger save layers keep their files
    /// and report the limitation instead of silently truncating.
    @discardableResult
    public func checkpoint() async throws -> UInt64? {
        guard let repository = checkpointRepository else { return nil }
        let snapshot = try store.snapshot()
        var records: [CheckpointFile] = []
        var names = Set<String>()
        var total = 0
        for file in snapshot {
            guard names.insert(file.descriptor.name.lowercased()).inserted else {
                throw RGSSGuestRunError.saveDuplicateName(file.descriptor.name)
            }
            guard total <= RGSSGuestSaveLimits.maximumTotalBytes - file.data.count else {
                throw RGSSGuestRunError.saveLimitExceeded("checkpoint total bytes")
            }
            total += file.data.count
            records.append(.init(name: file.descriptor.name,
                                 sha256: file.descriptor.sha256,
                                 data: file.data.base64EncodedString()))
        }
        let checkpoint = Checkpoint(format: "floe-rgss-guest-saves", version: 1,
                                    engine: store.engine, files: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checkpoint)
        let maximumStateBytes = await repository.maximumStateBytes
        guard data.count <= maximumStateBytes else {
            throw RGSSGuestRunError.saveLimitExceeded(
                "checkpoint is \(data.count) bytes; this host supports \(maximumStateBytes)")
        }
        let current: GameSaveCheckpoint?
        do {
            current = try await repository.load()
        } catch {
            throw RGSSGuestRunError.saveCheckpointCorrupt(
                "checkpoint repository read failed: \(String(describing: error))")
        }
        let saved = try await repository.save(data, expectedRevision: current?.revision ?? 0)
        return saved.revision
    }

    /// Restores the latest checkpoint and returns the exact names that changed.
    /// Unrelated standard saves, unknown files and the `Checkpoints` directory
    /// are preserved. The full receipt is available from
    /// `restoreCheckpointTransaction()`.
    @discardableResult
    public func restoreCheckpoint() async throws -> [String] {
        let receipt = try await restoreCheckpointTransaction()
        return receipt.changedNames
    }

    /// Validates the whole checkpoint before touching the save layer, then
    /// commits every file in one journaled transaction. A missing checkpoint,
    /// damaged identity, duplicate name, digest mismatch or capacity failure is
    /// actionable and leaves every previous byte in place.
    @discardableResult
    public func restoreCheckpointTransaction() async throws -> RGSSGuestSaveMutationReceipt {
        guard let repository = checkpointRepository else {
            throw RGSSGuestRunError.saveCheckpointUnsupported
        }
        let stored: GameSaveCheckpoint?
        do {
            stored = try await repository.load()
        } catch {
            throw RGSSGuestRunError.saveCheckpointCorrupt(
                "checkpoint repository read failed: \(String(describing: error))")
        }
        guard let stored else {
            throw RGSSGuestRunError.saveCheckpointMissing
        }
        let checkpoint: Checkpoint
        do {
            checkpoint = try JSONDecoder().decode(Checkpoint.self, from: stored.state)
        } catch {
            throw RGSSGuestRunError.saveCheckpointCorrupt("checkpoint JSON is damaged")
        }
        guard checkpoint.format == "floe-rgss-guest-saves",
              checkpoint.version == 1,
              checkpoint.engine == store.engine,
              checkpoint.files.count <= RGSSGuestSaveLimits.maximumFiles else {
            throw RGSSGuestRunError.saveCheckpointCorrupt(
                "checkpoint format, engine or file count is not valid for this save layer")
        }
        var records: [(name: String, data: Data)] = []
        var names = Set<String>()
        var total = 0
        for record in checkpoint.files {
            guard RGSSGuestSaveLimits.isValidSaveName(record.name, engine: store.engine) else {
                throw RGSSGuestRunError.invalidSaveName(record.name)
            }
            guard names.insert(record.name.lowercased()).inserted else {
                throw RGSSGuestRunError.saveCheckpointDuplicateName(record.name)
            }
            guard let data = Data(base64Encoded: record.data) else {
                throw RGSSGuestRunError.saveBytesMismatch(record.name)
            }
            guard data.count <= RGSSGuestSaveLimits.maximumFileBytes else {
                throw RGSSGuestRunError.saveLimitExceeded(record.name)
            }
            guard GameDigest.sha256(data) == record.sha256 else {
                throw RGSSGuestRunError.saveBytesMismatch(record.name)
            }
            guard total <= RGSSGuestSaveLimits.maximumTotalBytes - data.count else {
                throw RGSSGuestRunError.saveLimitExceeded("checkpoint restore total bytes")
            }
            total += data.count
            records.append((name: record.name, data: data))
        }
        return try store.applyPuts(records, operation: "restore",
                                   checkpointRevision: stored.revision)
    }

    @discardableResult
    public func recoverPendingTransactions() throws -> [UUID] {
        try store.recoverPendingTransactions()
    }

    private func importRequest(from source: URL) throws -> (name: String, data: Data) {
        guard source.isFileURL else {
            throw RGSSGuestRunError.invalidSaveName(source.lastPathComponent)
        }
        let name = source.lastPathComponent
        guard RGSSGuestSaveLimits.isValidSaveName(name, engine: store.engine) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        guard RGSSGuestSaveFileOps.isRegularFile(source.path),
              !RGSSGuestSaveFileOps.isSymbolicLink(source.path) else {
            throw RGSSGuestRunError.invalidSaveName(name)
        }
        let data = try RGSSGuestAtomicFile.read(source,
                                                maximumBytes: RGSSGuestSaveLimits.maximumFileBytes)
        return (name, data)
    }
}
