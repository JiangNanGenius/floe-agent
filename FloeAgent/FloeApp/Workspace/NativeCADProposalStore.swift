// SPDX-License-Identifier: MPL-2.0
// FloeApp — durable store for native (.floecad) CAD proposals.
//
// A native proposal is the frozen typed operation the assistant drafted on a
// throwaway copy, bound to the exact owner/environment/canonical document/
// revision/SHA it was drafted against. The in-process proposal contexts did
// not survive an app restart: a relaunch lost pending proposals, applied
// receipts and the originating task never learned the outcome. This store
// persists all of it with the same write-ahead discipline as the 2D Drawing
// Assistant services:
//
//   * propose       -> record(status: .pending) BEFORE the reply returns;
//   * apply intent  -> status .applying written BEFORE the mutation runs;
//   * apply success -> receipt attached, status .applied;
//   * apply failure -> status back to .pending (the grant reservation was
//                      released, so an honest retry is still possible);
//   * UI reject     -> status .rejected;
//   * manual change -> status .superseded once the document no longer
//                      matches the recorded base revision/SHA.
//
// Persistence is defensive (review-hardened):
//
//   * Versioned envelope: an unknown-NEWER schema or a corrupt file is
//     REJECTED, never overwritten — the on-disk evidence is preserved and
//     every write throws a recoverable error until the state is quarantined
//     (`quarantineCorruptState()`), which moves the bytes aside explicitly.
//     A MISSING file is a clean slate, distinct from corruption.
//   * Bounded growth: pending+applying ("active") records are capped; when
//     the cap is reached a new proposal is REFUSED with a clear resource
//     error (the caller surfaces it; nothing is silently dropped). Settled
//     records (applied/rejected/superseded) prune oldest-first to satisfy
//     the total-count and total-byte budgets; ACTIVE RECORDS ARE NEVER
//     DROPPED, and the byte budget can always refuse instead.
//   * Writes never block the caller's thread: encode + atomic file I/O run
//     on a private serial queue.
//
// Grants and approval authority stay exclusively in CadDocumentCenter and the
// shared CadProposalGrantStore — this store is persistence, NOT a parallel
// approval model. Apply receipts are ALSO written to the shared
// CadAppliedReceiptJournal (reused from the 2D path), so one write-ahead
// journal serves both engines.
//

import Foundation
import FloeWorkbench

final class NativeCADProposalStore: @unchecked Sendable {

    enum Status: String, Codable, Sendable {
        case pending
        case applying
        /// The package advanced while this proposal was applying and no
        /// verified receipt exists: the outcome is UNKNOWN. Never implies a
        /// safe retry — the document must be re-read and the change
        /// re-drafted.
        case interrupted
        case applied
        case rejected
        case superseded
    }

    /// Why persisted state was rejected. Recoverable: the caller surfaces the
    /// error and the app keeps working in-memory; the evidence stays on disk.
    enum PersistenceError: Error, LocalizedError, Equatable {
        case corrupt(detail: String)
        case newerSchema(found: Int, supported: Int)
        case tooManyActiveProposals(limit: Int)
        case recordTooLarge(limitBytes: Int)
        case storeTooLarge(limitBytes: Int)

        var errorDescription: String? {
            switch self {
            case .corrupt(let detail):
                return "The saved native CAD proposal state is unreadable (\(detail)); "
                    + "it was preserved unchanged. Use document recovery to quarantine it."
            case .newerSchema(let found, let supported):
                return "The saved native CAD proposal state was written by a newer version "
                    + "(schema \(found), this build supports \(supported)); it was preserved unchanged."
            case .tooManyActiveProposals(let limit):
                return "Too many pending native CAD proposals (\(limit)); "
                    + "apply or discard some in the CAD UI before drafting more."
            case .recordTooLarge(let limit):
                return "A native CAD proposal record exceeds the \(limit)-byte persistence limit."
            case .storeTooLarge(let limit):
                return "The native CAD proposal store exceeds its \(limit)-byte budget; "
                    + "apply or discard pending proposals to make room."
            }
        }
    }

    struct AccessRecord: Codable, Sendable, Equatable {
        var environmentID: String?
        var workspacePath: String?
        var ownerKind: String?
        var ownerID: UUID?

        init(_ access: CadDocumentAccess) {
            self.environmentID = access.environmentID
            self.workspacePath = access.workspacePath
            self.ownerKind = access.ownerKind
            self.ownerID = access.ownerID
        }

        /// Exact tool-path equality: the SAME environment/owner/workspace must
        /// come back. (The interactive UI path is environment-agnostic by
        /// design and bypasses this check at the host, exactly like 2D.)
        func matches(_ access: CadDocumentAccess) -> Bool {
            environmentID == access.environmentID
                && workspacePath == access.workspacePath
                && ownerKind == access.ownerKind
                && ownerID == access.ownerID
        }

        /// The conversation that drafted the proposal, when it was a chat
        /// task; workspace/canvas owners have no conversation to notify.
        var originatingConversationID: UUID? {
            ownerKind == "chat" ? ownerID : nil
        }
    }

    struct ReceiptRecord: Codable, Sendable, Equatable {
        var revision: Int
        var contentSHA256: String
        var message: String
        var requestID: String
        var appliedAt: Date
    }

    struct Record: Codable, Sendable {
        var proposalID: UUID
        /// Canonical (symlink-resolved) package path; the authoritative target.
        var canonicalDocumentPath: String
        var access: AccessRecord
        var baseRevision: Int
        var baseContentSHA256: String
        var summary: String
        var operationJSON: String
        /// The full frozen proposal record (incl. the preview) as returned by
        /// the bridge at propose time — enough to restore the banner, serve
        /// preview and re-register the proposal after a restart.
        var proposalJSON: String
        var createdAt: Date
        var status: Status
        var statusNote: String?
        var receipt: ReceiptRecord?
        /// Durable transaction marker bound to the proposal: the package
        /// revision a successful commit of this proposal must produce
        /// (exactly one commit per apply). Reconciliation compares the
        /// verified store identity against it instead of trusting ordering.
        var expectedResultRevision: Int? = nil
    }

    /// Versioned on-disk envelope. A file whose schemaVersion is NEWER than
    /// this build understands is rejected (never overwritten), so a downgrade
    /// cannot destroy state written by a newer version.
    struct Envelope: Codable, Sendable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var records: [String: Record]
    }

    struct StoreFailure: Error, LocalizedError {
        var errorDescription: String? {
            "The native CAD proposal record could not be persisted."
        }
    }

    // MARK: - Limits (bounded growth; active records are never dropped)

    /// Pending + applying proposals per store. Past this a new proposal is
    /// refused with a clear resource error instead of growing forever.
    let maximumActiveRecords = 64
    /// Total records (active + settled). Oldest SETTLED records prune first.
    let maximumRecords = 200
    /// Total on-disk budget for the whole store.
    let maximumTotalBytes = 4 * 1024 * 1024
    /// One frozen record (operation + preview JSON) can never exceed this.
    let maximumRecordBytes = 256 * 1024

    // MARK: - State

    private let lock = NSLock()
    /// Serializes encode + atomic writes OFF the caller's thread.
    private let writeQueue = DispatchQueue(label: "floe.native-cad.proposals")
    private let fileURL: URL
    private var loaded = false
    private var records: [String: Record] = [:]
    /// Set when persisted state was rejected (corrupt/newer). While set, all
    /// writes throw `PersistenceError` and the on-disk bytes stay untouched.
    private(set) var stateError: PersistenceError?

    init(fileURL: URL = NativeCADProposalStore.defaultFileURL() ?? URL(fileURLWithPath: "/dev/null")) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("FloeAgent/NativeCAD", isDirectory: true)
            .appendingPathComponent("proposals.json")
    }

    var isDurable: Bool { fileURL.path != "/dev/null" }

    var recoveryHint: String? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return stateError?.errorDescription
    }

    /// User-directed recovery: moves the rejected state aside so persistence
    /// can resume on a clean slate. The preserved bytes stay next to the
    /// store for inspection (`proposals.json.corrupt-<timestamp>`).
    @discardableResult
    func quarantineCorruptState() -> URL? {
        lock.lock()
        let error = stateError
        lock.unlock()
        guard error != nil, isDurable,
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let sidecar = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: sidecar)
        } catch {
            // A volume may refuse the move; copy+remove preserves the same
            // quarantine semantics and keeps the evidence bytes identical.
            do {
                try FileManager.default.copyItem(at: fileURL, to: sidecar)
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                return nil
            }
        }
        lock.lock()
        stateError = nil
        loaded = true
        records = [:]
        lock.unlock()
        return sidecar
    }

    // MARK: - Load (missing = clean slate; corrupt/newer = reject, keep bytes)

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard isDurable else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            stateError = .corrupt(detail: "empty or unreadable file")
            records = [:]
            return
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            stateError = .corrupt(detail: "not a valid proposal envelope")
            records = [:]
            return
        }
        guard envelope.schemaVersion <= Envelope.currentSchemaVersion else {
            stateError = .newerSchema(found: envelope.schemaVersion,
                                      supported: Envelope.currentSchemaVersion)
            records = [:]
            return
        }
        records = envelope.records
    }

    // MARK: - Writes (serialized off-thread; never overwrite rejected state)

    /// Insert or replace one record. Throws (without touching disk) when the
    /// persisted state was rejected, the record exceeds the per-record byte
    /// limit, or the active-record cap is full. Settled records prune
    /// oldest-first to satisfy the total budgets; active records are never
    /// dropped, and when only-active overflow remains the write is refused.
    func save(_ record: Record) async throws {
        guard isDurable else { throw StoreFailure() }
        // Per-record byte budget before any queue hop (cheap UTF-8 count of
        // the two JSON payloads; the encoded envelope only adds fixed keys).
        let recordBytes = record.proposalJSON.utf8.count + record.operationJSON.utf8.count
        guard recordBytes <= maximumRecordBytes else {
            throw PersistenceError.recordTooLarge(limitBytes: maximumRecordBytes)
        }
        try await write { [maximumRecords, maximumTotalBytes, maximumActiveRecords] in
            self.loadLocked()
            if let stateError = self.stateError { throw stateError }
            var staged = self.records
            staged[record.proposalID.uuidString] = record
            // Prune oldest SETTLED records until the count budget holds.
            // `.interrupted` is terminal too: the outcome is unknown and the
            // change must be re-drafted, so old interrupted records prune
            // like other settled ones instead of pinning the active cap.
            let settled = { (record: Record) in
                record.status == .applied || record.status == .rejected
                    || record.status == .superseded || record.status == .interrupted
            }
            if staged.count > maximumRecords {
                let oldestFirst = staged.sorted { $0.value.createdAt < $1.value.createdAt }
                for key in oldestFirst.map(\.key) where staged.count > maximumRecords {
                    if staged[key].map(settled) == true { staged.removeValue(forKey: key) }
                }
            }
            // Active saturation: never drop pending/applying records; refuse.
            let activeCount = staged.values.filter { !settled($0) }.count
            guard activeCount <= maximumActiveRecords else {
                throw PersistenceError.tooManyActiveProposals(limit: maximumActiveRecords)
            }
            // Encode once; enforce the total byte budget before writing.
            let envelope = Envelope(schemaVersion: Envelope.currentSchemaVersion,
                                    records: staged)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= maximumTotalBytes else {
                // One retry path exists: prune settled (done above). If the
                // budget still does not fit, refuse honestly.
                throw PersistenceError.storeTooLarge(limitBytes: maximumTotalBytes)
            }
            try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: self.fileURL, options: .atomic)
            self.records = staged
        }
    }

    /// Serialized, off-caller-thread mutation: the body runs on the private
    /// queue under the lock, so encode + atomic write never block the main
    /// actor even with large frozen previews.
    private func write<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                self.lock.lock()
                defer { self.lock.unlock() }
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Serialized, off-caller-thread upsert: loads, validates persisted
    /// state, applies the value transform to one record, re-encodes and
    /// writes — all on the private queue, so encode + atomic file I/O never
    /// block the caller's thread even with large frozen previews.
    private func transform(_ proposalID: UUID,
                           _ change: @escaping @Sendable (Record) -> Record) async throws {
        guard isDurable else { throw StoreFailure() }
        try await write {
            self.loadLocked()
            if let stateError = self.stateError { throw stateError }
            guard let record = self.records[proposalID.uuidString] else { return }
            let updated = change(record)
            var staged = self.records
            staged[proposalID.uuidString] = updated
            let envelope = Envelope(schemaVersion: Envelope.currentSchemaVersion,
                                    records: staged)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= self.maximumTotalBytes else {
                throw PersistenceError.storeTooLarge(limitBytes: self.maximumTotalBytes)
            }
            try data.write(to: self.fileURL, options: .atomic)
            self.records = staged
        }
    }

    // MARK: - Reads (in-memory; unaffected by a rejected persisted state)

    func record(for proposalID: UUID) -> Record? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return records[proposalID.uuidString]
    }

    func allRecords() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return records.values.sorted { $0.createdAt > $1.createdAt }
    }

    func records(forCanonicalDocument path: String) -> [Record] {
        allRecords().filter { $0.canonicalDocumentPath == path }
    }

    // MARK: - Status transitions (each one durable before the next step runs)

    /// Write-ahead intent: call BEFORE the authorized mutation runs. The
    /// expected result revision binds the marker to the one commit this
    /// apply must produce, so recovery can tell "never committed" from
    /// "committed but unrecorded" from the verified store identity.
    func markApplying(_ proposalID: UUID, note: String? = nil,
                      expectedResultRevision: Int? = nil) async throws {
        try await transform(proposalID) { record in
            guard record.status == .pending else { return record }
            var copy = record
            copy.status = .applying
            copy.statusNote = note
            copy.expectedResultRevision = expectedResultRevision
            return copy
        }
    }

    func markApplied(_ proposalID: UUID, receipt: ReceiptRecord) async throws {
        try await transform(proposalID) { record in
            var copy = record
            copy.status = .applied
            copy.receipt = receipt
            copy.statusNote = nil
            return copy
        }
    }

    /// A failed apply goes back to pending: the reservation was released and
    /// the live document was rolled back, so an honest retry is possible. The
    /// failure itself is reported to the originating task through the shared
    /// decision outbox, not by poisoning the proposal record.
    func markApplyReturnedToPending(_ proposalID: UUID, note: String) async throws {
        try await transform(proposalID) { record in
            guard record.status == .applying else { return record }
            var copy = record
            copy.status = .pending
            copy.statusNote = note
            return copy
        }
    }

    func markRejected(_ proposalID: UUID) async throws {
        try await transform(proposalID) { record in
            guard record.status == .pending || record.status == .applying else { return record }
            var copy = record
            copy.status = .rejected
            copy.statusNote = nil
            return copy
        }
    }

    /// The document moved past the recorded base (manual edit or another
    /// applied change): this proposal can never be applied anymore.
    func markSuperseded(_ proposalID: UUID, note: String) async throws {
        try await transform(proposalID) { record in
            guard record.status == .pending || record.status == .applying else { return record }
            var copy = record
            copy.status = .superseded
            copy.statusNote = note
            return copy
        }
    }

    /// Recovery: an `.applying` record whose outcome was interrupted. Marks
    /// the record with the recovered status; the caller owns delivery. The
    /// post-write record is re-read so no mutable state crosses the
    /// serialized-write boundary.
    @discardableResult
    func markRecovered(_ proposalID: UUID, status: Status, note: String) async throws -> Record? {
        try await transform(proposalID) { record in
            guard record.status == .applying else { return record }
            var copy = record
            copy.status = status
            copy.statusNote = note
            return copy
        }
        guard let current = record(for: proposalID), current.status == status else { return nil }
        return current
    }
}
