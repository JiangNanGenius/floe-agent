// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — durable system document-open queue (S5 P3).
//
// Layout (all inside the app-owned Application Support root):
//   staging/<event>/{entry.json,payload.<ext>,.active}
//   pending/<event>/{entry.json,payload.<ext>,.claim}
//   completed/<event>/entry.json
//
// Invariants:
// * An entry becomes visible only after its payload and entry.json are
//   fsynced and the directory is atomically renamed from staging to pending.
// * A claim is an exclusive OS `flock` on pending/<id>/.claim. A live owner
//   cannot be stolen from; a killed process's lock is released by the kernel.
// * `markCommitted` writes the durable receipt before moving the directory to
//   completed. The payload copy is deleted only after that record exists.
// * The queue identity is the event UUID; the Notes identity is the exact
//   pre-allocated plannedRootDocumentID. No title/content comparison is used.
// * Nothing here reads, writes or deletes a provider URL. `discard` only
//   removes app-owned directories proven inside the queue root.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

actor DocumentIntakeQueue {
    nonisolated let root: URL
    nonisolated let limits: DocumentIntakeLimits
    private let now: @Sendable () -> Date

    init(
        root: URL,
        limits: DocumentIntakeLimits = .production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let canonical = root.standardizedFileURL
        self.root = canonical
        self.limits = limits
        self.now = now
        let manager = FileManager.default
        do { try manager.createDirectory(at: canonical, withIntermediateDirectories: true) }
        catch { throw DocumentIntakeError.queueUnavailable }
        for name in ["staging", "pending", "completed"] {
            let directory = canonical.appendingPathComponent(name, isDirectory: true)
            do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { throw DocumentIntakeError.queueUnavailable }
            guard DocumentIntakeStorage.isDirectoryNotSymlink(directory) else {
                throw DocumentIntakeError.queueUnavailable
            }
        }
        let lock = canonical.appendingPathComponent(".lock", isDirectory: false)
        if !manager.fileExists(atPath: lock.path) {
            guard manager.createFile(atPath: lock.path, contents: nil) else {
                throw DocumentIntakeError.queueUnavailable
            }
        }
    }

    // MARK: - Enqueue

    /// Atomically publishes one staged input. A duplicate in-flight/cold
    /// callback for the same verified bytes is coalesced; the newer staged
    /// copy is removed and the existing event returned. A changed document or
    /// a deliberate later reimport after commit is never suppressed.
    func enqueue(_ staged: DocumentIntakeStagedInput) throws -> DocumentIntakeRecord {
        defer { staged.activeLock?.close() }
        return try withGlobalLock {
            let record = try loadRecord(at: staged.directory)
            guard record.id == staged.record.id,
                  DocumentIntakeStorage.isContained(staged.directory, in: stagingRoot) else {
                throw DocumentIntakeError.corruptRecord
            }
            if let duplicate = try duplicateUnlocked(of: record, at: now()) {
                try? DocumentIntakeStorage.removeOwned(staged.directory, in: root)
                return duplicate
            }
            let existing = try pendingRecordsUnlocked().filter { $0.1.state != .committed }
            let queuedBytes = existing.reduce(Int64(0)) { $0 + $1.1.byteCount }
            guard existing.count < limits.maximumPendingEntries,
                  queuedBytes + record.byteCount <= limits.maximumQueuedBytes else {
                throw DocumentIntakeError.queueFull
            }
            let destination = pendingRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw DocumentIntakeError.queueUnavailable
            }
            do { try FileManager.default.moveItem(at: staged.directory, to: destination) }
            catch { throw DocumentIntakeError.ioFailure }
            // The kernel lease follows the open descriptor; the zero-byte
            // marker itself has no meaning once the entry is published.
            try? FileManager.default.removeItem(
                at: destination.appendingPathComponent(".active", isDirectory: false)
            )
            try? DocumentIntakeStorage.syncDirectory(pendingRoot)
            return record
        }
    }

    // MARK: - Read

    func record(id: UUID) throws -> DocumentIntakeRecord? {
        try withGlobalLock {
            guard let directory = directoryFor(id: id) else { return nil }
            return try loadRecord(at: directory)
        }
    }

    func snapshot() throws -> DocumentIntakeQueueSnapshot {
        try withGlobalLock {
            var records: [DocumentIntakeRecord] = []
            var corrupt = 0
            let pendingDirectories = directories(in: pendingRoot)
            let completedDirectories = Array(directories(in: completedRoot).prefix(200))
            for directory in pendingDirectories + completedDirectories {
                do { records.append(try loadRecord(at: directory)) }
                catch { corrupt += 1 }
            }
            records.sort { $0.updatedAt > $1.updatedAt }
            return DocumentIntakeQueueSnapshot(
                records: Array(records.prefix(40)),
                corruptCount: corrupt
            )
        }
    }

    /// `.importing` entries whose process lock is no longer held. Called after
    /// a cold launch; the center decides whether the exact Notes identity
    /// already committed or whether a canvas result is ambiguous.
    func interrupted() throws -> [DocumentIntakeRecord] {
        try withGlobalLock {
            var values: [DocumentIntakeRecord] = []
            for (directory, record) in try pendingRecordsUnlocked() where record.state == .importing {
                if claimIsFree(in: directory) { values.append(record) }
            }
            return values
        }
    }

    // MARK: - Claim

    func claimNext() throws -> DocumentIntakeClaim? {
        try withGlobalLock {
            for (directory, record) in try pendingRecordsUnlocked() where record.state == .pending {
                do {
                    return try claimUnlocked(directory: directory, record: record, at: now())
                } catch DocumentIntakeError.claimBusy {
                    continue
                } catch DocumentIntakeError.damaged {
                    try markFailedUnlocked(
                        directory: directory,
                        record: record,
                        code: .damaged,
                        detail: nil,
                        at: now()
                    )
                    continue
                }
            }
            return nil
        }
    }

    /// Reacquires an interrupted entry after restart. Returns nil when a live
    /// owner (or another recovering process) holds the claim.
    func takeRecoveryClaim(id: UUID) throws -> DocumentIntakeClaim? {
        try withGlobalLock {
            let directory = pendingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path),
                  var record = try? loadRecord(at: directory),
                  record.state == .importing else { return nil }
            let claimURL = directory.appendingPathComponent(".claim", isDirectory: false)
            let descriptor = claimURL.path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            }
            guard descriptor >= 0 else { throw DocumentIntakeError.ioFailure }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(descriptor)
                return nil
            }
            let payload: URL
            do {
                payload = try validatePayload(record, in: directory)
            } catch {
                // A damaged interrupted payload cannot be retried. Make the
                // recoverable state explicit instead of leaving an
                // `.importing` entry that would be re-examined forever. A
                // failure to persist even that state is surfaced to the
                // caller as a real save failure.
                record.state = .needsReview
                record.failureCode = DocumentIntakeFailure.damaged.rawValue
                record.failureDetail = nil
                record.claimToken = nil
                record.claimedAt = nil
                record.updatedAt = now()
                do {
                    try writeRecord(record, to: directory)
                } catch {
                    _ = flock(descriptor, LOCK_UN)
                    _ = Darwin.close(descriptor)
                    throw DocumentIntakeError.ioFailure
                }
                _ = flock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
                throw error
            }
            let token = UUID().uuidString
            record.claimToken = token
            record.claimedAt = now()
            record.updatedAt = now()
            do {
                try writeRecord(record, to: directory)
                return DocumentIntakeClaim(
                    record: record,
                    directory: directory,
                    payloadURL: payload,
                    token: token,
                    lock: DocumentIntakeFileLock(descriptor: descriptor)
                )
            } catch {
                _ = flock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
                throw error
            }
        }
    }

    // MARK: - Claim outcomes (CAS)

    func markCommitted(_ claim: DocumentIntakeClaim, commit: DocumentIntakeCommit) throws {
        try withGlobalLock {
            let directory = pendingRoot.appendingPathComponent(claim.record.id.uuidString, isDirectory: true)
            guard var record = try? loadRecord(at: directory),
                  record.state == .importing,
                  record.claimToken == claim.token else {
                throw DocumentIntakeError.claimLost
            }
            // The receipt must carry the exact pre-allocated Notes identity
            // or a real canvas identity. A mismatched commit is never stored.
            if record.kind.importsIntoNotes {
                guard commit.rootDocumentID == record.plannedRootDocumentID,
                      commit.canvasID == nil else {
                    throw DocumentIntakeError.importFailed
                }
            } else {
                guard commit.canvasID != nil, commit.rootDocumentID == nil else {
                    throw DocumentIntakeError.importFailed
                }
            }
            record.state = .committed
            record.commit = commit
            record.claimToken = nil
            record.claimedAt = nil
            record.failureCode = nil
            record.failureDetail = nil
            record.updatedAt = now()
            try writeRecord(record, to: directory)
            // The receipt is durable now. Only after it exists may this
            // process delete its own staged copy.
            let payload = directory.appendingPathComponent(record.stagedFileName, isDirectory: false)
            if DocumentIntakeStorage.isContained(payload, in: root) {
                try? FileManager.default.removeItem(at: payload)
            }
            let destination = completedRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.moveItem(at: directory, to: destination)
                    try? DocumentIntakeStorage.syncDirectory(completedRoot)
                } catch {
                    // A committed entry left in pending is archived by the
                    // next maintenance pass; its receipt is already durable.
                }
            }
            claim.lock.close()
        }
    }

    func markFailed(_ claim: DocumentIntakeClaim, code: DocumentIntakeFailure, detail: String?) throws {
        try finish(
            claim,
            state: .failed,
            code: code,
            detail: detail
        )
    }

    func markNeedsReview(_ claim: DocumentIntakeClaim, code: DocumentIntakeFailure, detail: String?) throws {
        try finish(
            claim,
            state: .needsReview,
            code: code,
            detail: detail
        )
    }

    func markCancelled(_ claim: DocumentIntakeClaim) throws {
        try finish(claim, state: .cancelled, code: nil, detail: nil)
    }

    /// Puts an uncommitted entry back without a result. Used only when an
    /// import was abandoned for a reason that is safe to retry (for example a
    /// not-yet-ready store after restart).
    func requeue(_ claim: DocumentIntakeClaim) throws {
        try finish(claim, state: .pending, code: nil, detail: nil)
    }

    // MARK: - Explicit user actions

    func cancel(id: UUID) throws -> DocumentIntakeCancelOutcome {
        try withGlobalLock {
            guard let directory = directoryFor(id: id),
                  var record = try? loadRecord(at: directory) else { return .notFound }
            if record.state == .committed {
                if let receipt = record.receipt { return .alreadyCommitted(receipt) }
                return .notFound
            }
            if record.state == .importing {
                guard claimIsFree(in: directory) else { return .busy }
            }
            record.state = .cancelled
            record.claimToken = nil
            record.claimedAt = nil
            record.failureCode = nil
            record.failureDetail = nil
            record.updatedAt = now()
            try writeRecord(record, to: directory)
            return .cancelled
        }
    }

    @discardableResult
    func retry(id: UUID) throws -> Bool {
        try withGlobalLock {
            guard let directory = pendingDirectoryIfExists(id: id),
                  var record = try? loadRecord(at: directory) else { return false }
            guard record.state == .failed
                    || record.state == .cancelled
                    || record.state == .needsReview else { return false }
            if record.state == .needsReview, !claimIsFree(in: directory) { return false }
            record.state = .pending
            record.claimToken = nil
            record.claimedAt = nil
            record.failureCode = nil
            record.failureDetail = nil
            record.updatedAt = now()
            try writeRecord(record, to: directory)
            return true
        }
    }

    /// Removes only this intake's app-owned folder and receipt. The imported
    /// Notes/Canvas document and the provider original are never touched.
    @discardableResult
    func discard(id: UUID) throws -> Bool {
        try withGlobalLock {
            var removed = false
            var target: DocumentIntakeRecord?
            if let directory = pendingDirectoryIfExists(id: id) {
                if let record = try? loadRecord(at: directory) {
                    target = record
                    if record.state == .importing, !claimIsFree(in: directory) {
                        return false
                    }
                }
                try? DocumentIntakeStorage.removeOwned(directory, in: root)
                removed = true
            }
            if let directory = completedDirectoryIfExists(id: id) {
                if target == nil { target = try? loadRecord(at: directory) }
                try? DocumentIntakeStorage.removeOwned(directory, in: root)
                removed = true
            }
            // Discard is an explicit user decision for these bytes. Abandoned
            // staging copies of the same content must not import later behind
            // that decision; a live staging attempt is left alone.
            if let target {
                for directory in directories(in: stagingRoot) {
                    guard stagingIsAbandoned(directory),
                          let staged = try? loadRecord(at: directory),
                          staged.id != target.id,
                          Self.sameContent(staged, target) else { continue }
                    try? DocumentIntakeStorage.removeOwned(directory, in: root)
                }
            }
            return removed
        }
    }

    // MARK: - Maintenance

    /// Recovers atomically-visible staging entries, never touches a live
    /// staging attempt, and expires only this feature's own payloads/receipts.
    func maintain(now: Date) throws -> DocumentIntakeMaintenanceReport {
        try withGlobalLock {
            var report = DocumentIntakeMaintenanceReport(
                recoveredStaging: 0,
                removedIncompleteStaging: 0,
                removedDuplicateStaging: 0,
                removedExpiredRecords: 0,
                removedReceipts: 0,
                corruptRecords: 0
            )
            let existing = try pendingRecordsUnlocked()
            var entryCount = existing.count
            var queuedBytes = existing.reduce(Int64(0)) { $0 + $1.1.byteCount }

            // A committed record whose directory move failed is archived here;
            // its receipt was already durable before the move was attempted.
            for (directory, record) in existing where record.state == .committed {
                let destination = completedRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
                let payload = directory.appendingPathComponent(record.stagedFileName, isDirectory: false)
                if DocumentIntakeStorage.isContained(payload, in: root) {
                    // A crash after the receipt was written but before the
                    // payload was deleted must not retain a full input copy.
                    try? FileManager.default.removeItem(at: payload)
                }
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    try? DocumentIntakeStorage.removeOwned(directory, in: root)
                    entryCount = max(0, entryCount - 1)
                    queuedBytes = max(0, queuedBytes - record.byteCount)
                    continue
                }
                try? FileManager.default.moveItem(at: directory, to: destination)
                try? DocumentIntakeStorage.syncDirectory(completedRoot)
                entryCount = max(0, entryCount - 1)
                queuedBytes = max(0, queuedBytes - record.byteCount)
            }

            for directory in directories(in: stagingRoot) {
                let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard stagingIsAbandoned(directory) else { continue }
                if let record = try? loadRecord(at: directory),
                   record.state == .pending,
                   let payloadSize = DocumentIntakeStorage.fileSize(
                       directory.appendingPathComponent(record.stagedFileName, isDirectory: false)
                   ),
                   payloadSize == record.byteCount {
                    // A staging copy whose content is already pending or
                    // committed must not import a second time after a reopen.
                    if try hasMatchingEntryUnlocked(record) {
                        if (try? DocumentIntakeStorage.removeOwned(directory, in: root)) != nil {
                            report.removedDuplicateStaging += 1
                        }
                        continue
                    }
                    // A valid, recoverable copy is kept even when capacity is
                    // temporarily full. Never delete recoverable user intake.
                    guard entryCount < limits.maximumPendingEntries,
                          queuedBytes + record.byteCount <= limits.maximumQueuedBytes else {
                        continue
                    }
                    let destination = pendingRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        do {
                            try FileManager.default.moveItem(at: directory, to: destination)
                            try? FileManager.default.removeItem(
                                at: destination.appendingPathComponent(".active", isDirectory: false)
                            )
                            try? DocumentIntakeStorage.syncDirectory(pendingRoot)
                            report.recoveredStaging += 1
                            entryCount += 1
                            queuedBytes += record.byteCount
                        } catch {
                            // Retry on the next launch; the valid payload is kept.
                        }
                    }
                    continue
                }
                if now.timeIntervalSince(modified) >= limits.incompleteStagingLifetime {
                    if (try? DocumentIntakeStorage.removeOwned(directory, in: root)) != nil {
                        report.removedIncompleteStaging += 1
                    }
                }
            }

            for (directory, record) in existing {
                guard record.state == .failed
                        || record.state == .needsReview
                        || record.state == .cancelled else { continue }
                guard now.timeIntervalSince(record.updatedAt) >= limits.recoverableLifetime else { continue }
                if (try? DocumentIntakeStorage.removeOwned(directory, in: root)) != nil {
                    report.removedExpiredRecords += 1
                }
            }

            for directory in directories(in: completedRoot).prefix(500) {
                let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let updated = (try? loadRecord(at: directory))?.updatedAt ?? modified
                guard now.timeIntervalSince(updated) >= limits.receiptLifetime else { continue }
                if (try? DocumentIntakeStorage.removeOwned(directory, in: root)) != nil {
                    report.removedReceipts += 1
                }
            }
            return report
        }
    }

    // MARK: - Paths

    private var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var pendingRoot: URL { root.appendingPathComponent("pending", isDirectory: true) }
    private var completedRoot: URL { root.appendingPathComponent("completed", isDirectory: true) }

    private func directoryFor(id: UUID) -> URL? {
        pendingDirectoryIfExists(id: id) ?? completedDirectoryIfExists(id: id)
    }

    private func pendingDirectoryIfExists(id: UUID) -> URL? {
        let directory = pendingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        return DocumentIntakeStorage.isDirectoryNotSymlink(directory) ? directory : nil
    }

    private func completedDirectoryIfExists(id: UUID) -> URL? {
        let directory = completedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        return DocumentIntakeStorage.isDirectoryNotSymlink(directory) ? directory : nil
    }

    private func directories(in parent: URL) -> [URL] {
        let values = (try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return values.filter {
            UUID(uuidString: $0.lastPathComponent) != nil
                && DocumentIntakeStorage.isDirectoryNotSymlink($0)
                && DocumentIntakeStorage.isContained($0, in: root)
        }
    }

    // MARK: - Records

    private func loadRecord(at directory: URL) throws -> DocumentIntakeRecord {
        guard DocumentIntakeStorage.isContained(directory, in: root),
              DocumentIntakeStorage.isDirectoryNotSymlink(directory),
              let id = UUID(uuidString: directory.lastPathComponent) else {
            throw DocumentIntakeError.corruptRecord
        }
        let entry = directory.appendingPathComponent("entry.json", isDirectory: false)
        guard DocumentIntakeStorage.isRegularFileNotSymlink(entry),
              let size = DocumentIntakeStorage.fileSize(entry),
              size > 0,
              size <= Int64(limits.maximumRecordBytes) else {
            throw DocumentIntakeError.corruptRecord
        }
        let data: Data
        do { data = try Data(contentsOf: entry, options: [.mappedIfSafe]) }
        catch { throw DocumentIntakeError.corruptRecord }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: DocumentIntakeRecord
        do { record = try decoder.decode(DocumentIntakeRecord.self, from: data) }
        catch { throw DocumentIntakeError.corruptRecord }
        guard record.schemaVersion == DocumentIntakeRecord.currentSchemaVersion,
              record.id == id,
              record.byteCount > 0,
              record.byteCount <= record.kind.maximumBytes,
              record.sha256.utf8.count == 64,
              record.sha256.allSatisfy({ $0.isHexDigit }),
              !record.displayName.isEmpty,
              record.displayName == (record.displayName as NSString).lastPathComponent,
              record.displayName.utf8.count <= 1_024,
              DocumentIntakeKind.isValidStagedFileName(record.stagedFileName, kind: record.kind),
              record.attemptCount >= 0 else {
            throw DocumentIntakeError.corruptRecord
        }
        switch record.state {
        case .committed:
            guard let commit = record.commit,
                  (commit.rootDocumentID != nil) != (commit.canvasID != nil) else {
                throw DocumentIntakeError.corruptRecord
            }
        default:
            guard record.commit == nil else { throw DocumentIntakeError.corruptRecord }
        }
        return record
    }

    private func writeRecord(_ record: DocumentIntakeRecord, to directory: URL) throws {
        guard DocumentIntakeStorage.isContained(directory, in: root),
              DocumentIntakeStorage.isDirectoryNotSymlink(directory) else {
            throw DocumentIntakeError.corruptRecord
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(record) }
        catch { throw DocumentIntakeError.ioFailure }
        guard data.count <= limits.maximumRecordBytes else { throw DocumentIntakeError.ioFailure }
        try DocumentIntakeStorage.writeDurably(
            data,
            to: directory.appendingPathComponent("entry.json", isDirectory: false)
        )
    }

    private func validatePayload(_ record: DocumentIntakeRecord, in directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent(record.stagedFileName, isDirectory: false)
        guard DocumentIntakeStorage.isContained(payload, in: root),
              DocumentIntakeStorage.isRegularFileNotSymlink(payload),
              let size = DocumentIntakeStorage.fileSize(payload),
              size == record.byteCount else {
            throw DocumentIntakeError.damaged
        }
        return payload
    }

    /// True when another queue/receipt entry already represents these exact
    /// bytes. Content identity plus kind, never a title comparison.
    private func hasMatchingEntryUnlocked(_ record: DocumentIntakeRecord) throws -> Bool {
        for (_, existing) in try pendingRecordsUnlocked() where existing.id != record.id {
            if Self.sameContent(existing, record) { return true }
        }
        for directory in directories(in: completedRoot).prefix(200) {
            guard let existing = try? loadRecord(at: directory), existing.id != record.id else { continue }
            if Self.sameContent(existing, record) { return true }
        }
        return false
    }

    private static func sameContent(_ lhs: DocumentIntakeRecord, _ rhs: DocumentIntakeRecord) -> Bool {
        lhs.kind == rhs.kind && lhs.byteCount == rhs.byteCount && lhs.sha256 == rhs.sha256
    }

    private func pendingRecordsUnlocked() throws -> [(URL, DocumentIntakeRecord)] {
        var values: [(URL, DocumentIntakeRecord)] = []
        for directory in directories(in: pendingRoot) {
            do { values.append((directory, try loadRecord(at: directory))) }
            catch { continue }
        }
        return values.sorted { $0.1.createdAt < $1.1.createdAt }
    }

    private func duplicateUnlocked(
        of record: DocumentIntakeRecord,
        at date: Date
    ) throws -> DocumentIntakeRecord? {
        for (_, existing) in try pendingRecordsUnlocked() {
            guard existing.state == .pending || existing.state == .importing,
                  existing.kind == record.kind,
                  existing.byteCount == record.byteCount,
                  existing.sha256 == record.sha256 else { continue }
            let age = date.timeIntervalSince(existing.createdAt)
            guard age <= limits.duplicateWindow, age >= -limits.duplicateWindow else { continue }
            return existing
        }
        return nil
    }

    // MARK: - Claim internals

    private func claimUnlocked(
        directory: URL,
        record: DocumentIntakeRecord,
        at date: Date
    ) throws -> DocumentIntakeClaim {
        guard record.state == .pending else { throw DocumentIntakeError.claimBusy }
        let payload = try validatePayload(record, in: directory)
        let claimURL = directory.appendingPathComponent(".claim", isDirectory: false)
        let descriptor = claimURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw DocumentIntakeError.ioFailure }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw DocumentIntakeError.claimBusy
        }
        let token = UUID().uuidString
        var updated = record
        updated.state = .importing
        updated.claimToken = token
        updated.claimedAt = date
        updated.updatedAt = date
        updated.attemptCount += 1
        do {
            try writeRecord(updated, to: directory)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            throw DocumentIntakeError.ioFailure
        }
        return DocumentIntakeClaim(
            record: updated,
            directory: directory,
            payloadURL: payload,
            token: token,
            lock: DocumentIntakeFileLock(descriptor: descriptor)
        )
    }

    private func finish(
        _ claim: DocumentIntakeClaim,
        state: DocumentIntakeState,
        code: DocumentIntakeFailure?,
        detail: String?
    ) throws {
        try withGlobalLock {
            let directory = pendingRoot.appendingPathComponent(claim.record.id.uuidString, isDirectory: true)
            guard var record = try? loadRecord(at: directory),
                  record.state == .importing,
                  record.claimToken == claim.token else {
                throw DocumentIntakeError.claimLost
            }
            record.state = state
            record.claimToken = nil
            record.claimedAt = nil
            record.failureCode = code?.rawValue
            record.failureDetail = detail
            record.updatedAt = now()
            try writeRecord(record, to: directory)
            claim.lock.close()
        }
    }

    private func markFailedUnlocked(
        directory: URL,
        record: DocumentIntakeRecord,
        code: DocumentIntakeFailure,
        detail: String?,
        at date: Date
    ) throws {
        var updated = record
        updated.state = .failed
        updated.failureCode = code.rawValue
        updated.failureDetail = detail
        updated.claimToken = nil
        updated.claimedAt = nil
        updated.attemptCount += 1
        updated.updatedAt = date
        try writeRecord(updated, to: directory)
    }

    /// True when no live process holds the entry's OS claim lock.
    private func claimIsFree(in directory: URL) -> Bool {
        let claimURL = directory.appendingPathComponent(".claim", isDirectory: false)
        let descriptor = claimURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(descriptor, LOCK_UN)
        return true
    }

    private func stagingIsAbandoned(_ directory: URL) -> Bool {
        let active = directory.appendingPathComponent(".active", isDirectory: false)
        let descriptor = active.path.withCString {
            Darwin.open($0, O_RDWR | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return true }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(descriptor, LOCK_UN)
        return true
    }

    // MARK: - Global lock

    private func withGlobalLock<T>(_ body: () throws -> T) throws -> T {
        let lock = root.appendingPathComponent(".lock", isDirectory: false)
        let descriptor = lock.path.withCString {
            Darwin.open($0, O_RDWR | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw DocumentIntakeError.queueUnavailable }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DocumentIntakeError.queueUnavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
#endif
