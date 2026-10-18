import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// Durable, non-secret receipts for ambiguous mailbox mutations (move,
/// archive, trash). A receipt — including the operation provenance needed for
/// later read-only reconciliation — is reserved BEFORE the first mutating IMAP
/// command; if the process dies or the connection drops mid-command, the
/// recorded `mutationUnknown` state is returned to every later call with the
/// same request identity so nothing is silently repeated. Corrupt receipts
/// fail closed and are preserved.
///
/// Single-active-owner model (non-preemptible): every granted attempt holds an
/// exclusive `flock(LOCK_EX)` on a stable per-request owner inode from before
/// the real mutation until its receipt is finalized. The kernel releases that
/// ownership only when the descriptor closes — a live attempt (however long it
/// takes, a paused process, or a clock jump) can never be preempted, and a
/// later call cannot reconcile an ambiguous receipt without first owning the
/// same lock. Cross-instance and cross-process exclusion is therefore kernel
/// enforced, including between separate `MailMutationJournal` instances over
/// the same directory. The in-process `MailClient` busy flag alone cannot
/// provide this: it only fails fast while a wire is actually open and does not
/// span the reserve → move → finalize ownership window.
public final class MailMutationJournal: @unchecked Sendable {
    public enum State: String, Codable, Sendable, Equatable { case mutationUnknown, completed, notStarted }

    /// Everything a later read-only reconciliation needs. Contains no
    /// credentials and no message content.
    public struct Provenance: Codable, Sendable, Equatable {
        public var accountID: UUID
        public var action: String
        public var sourceFolder: String
        public var destination: String
        public var uid: String
        public var mailboxVersion: String
        /// Message-ID header (brackets stripped) for a stable copy proof.
        public var messageID: String?
        /// RFC822.SIZE at reservation time.
        public var byteCount: Int

        public init(
            accountID: UUID,
            action: String,
            sourceFolder: String,
            destination: String,
            uid: String,
            mailboxVersion: String,
            messageID: String?,
            byteCount: Int
        ) {
            self.accountID = accountID
            self.action = action
            self.sourceFolder = sourceFolder
            self.destination = destination
            self.uid = uid
            self.mailboxVersion = mailboxVersion
            self.messageID = messageID
            self.byteCount = byteCount
        }
    }

    /// The stable read-only identity a reservation captures for later
    /// reconciliation. Deliberately independent of the live IMAP client so
    /// receipts and orchestration stay testable.
    public struct StableIdentity: Sendable, Equatable {
        public var messageID: String?
        public var byteCount: Int
        public init(messageID: String?, byteCount: Int) {
            self.messageID = messageID
            self.byteCount = byteCount
        }
    }

    /// The bounded read-only reconciliation verdict for an ambiguous receipt,
    /// mirrored from the IMAP layer's outcome vocabulary.
    public enum Reconciliation: Sendable, Equatable {
        case notSubmitted
        case completed(destinationUID: String?, destinationMailboxVersion: String?)
        case ambiguous(reason: String)
    }

    /// What a durable receipt currently says about one request identity,
    /// independent of any caller-supplied digest so the tool can bind an
    /// existing receipt to its request BEFORE resolving servers or reading
    /// credentials.
    public struct ReceiptDescriptor: Sendable, Equatable {
        public var digest: String
        public var state: State
        public var provenance: Provenance?

        public init(digest: String, state: State, provenance: Provenance?) {
            self.digest = digest
            self.state = state
            self.provenance = provenance
        }
    }

    /// What a durable receipt currently says about one request identity.
    public struct Snapshot: Sendable, Equatable {
        public var state: State
        /// Absent on receipts reserved before provenance was introduced; the
        /// caller must then stay explicitly uncertain, never re-move.
        public var provenance: Provenance?

        public init(state: State, provenance: Provenance?) {
            self.state = state
            self.provenance = provenance
        }
    }

    private struct Receipt: Codable {
        var digest: String
        var state: State
        /// Absent on receipts written before provenance was introduced.
        var provenance: Provenance?
    }

    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }

    /// Read-only receipt inspection for the resume-first ordering: it NEVER
    /// creates the journal directory or a receipt file, returns nil when no
    /// receipt exists for this request, and fails closed (preserving the
    /// file) on a corrupt receipt or a digest mismatch. Use this BEFORE any
    /// source-message read so a completed or unknown mutation of the same
    /// request can be recovered even when the source message is already gone.
    public func snapshot(requestID: UUID, digest: String) throws -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidDigest(digest) else { throw MailFailure.invalidMessage }
        let file = url(requestID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let receipt = try read(file)
        guard receipt.digest == digest else { throw MailFailure.invalidMessage }
        return Snapshot(state: receipt.state, provenance: receipt.provenance)
    }

    /// Read-only receipt lookup by request identity only (no digest). It
    /// never creates the journal directory or a file, returns nil when no
    /// receipt exists, and fails closed on corruption. Callers must bind the
    /// returned provenance to their own request facts and recompute the
    /// digest before using it; provenance is never trusted across requests.
    public func receiptDescriptor(requestID: UUID) throws -> ReceiptDescriptor? {
        lock.lock(); defer { lock.unlock() }
        let file = url(requestID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let receipt = try read(file)
        guard Self.isValidDigest(receipt.digest) else { throw MailFailure.invalidMessage }
        return ReceiptDescriptor(
            digest: receipt.digest,
            state: receipt.state,
            provenance: receipt.provenance
        )
    }

    /// nil authorizes the first attempt; a returned state is a replay, never
    /// an instruction to repeat the mutation. `provenance` is persisted with
    /// the reservation for later read-only reconciliation. Publication is
    /// atomic (create-if-absent), so concurrent calls — including calls
    /// through different `MailMutationJournal` instances over the same
    /// directory — produce exactly one winner.
    @discardableResult
    public func reserve(
        requestID: UUID,
        digest: String,
        provenance: Provenance? = nil
    ) throws -> State? {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidDigest(digest) else {
            throw MailFailure.invalidMessage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepStaleStagingFiles()
        do {
            try publishNew(
                Receipt(digest: digest, state: .mutationUnknown, provenance: provenance),
                to: url(requestID)
            )
            return nil
        } catch JournalPublishError.duplicate {
            // The claim already exists: this is a replay, never an
            // instruction to repeat the mutation.
            let existing = try read(url(requestID))
            guard existing.digest == digest else { throw MailFailure.invalidMessage }
            return existing.state
        }
    }

    public func finish(requestID: UUID, digest: String, state: State) throws {
        lock.lock(); defer { lock.unlock() }
        let file = url(requestID)
        let previous = try read(file)
        guard previous.digest == digest,
              previous.state == .mutationUnknown || previous.state == state else {
            throw MailFailure.invalidMessage
        }
        try write(
            Receipt(digest: digest, state: state, provenance: previous.provenance),
            to: file
        )
    }

    /// Read-only provenance lookup for reconciliation. Missing provenance on a
    /// legacy receipt returns nil; the caller must then stay explicitly
    /// ambiguous instead of retrying.
    public func provenance(requestID: UUID, digest: String) throws -> Provenance? {
        lock.lock(); defer { lock.unlock() }
        let receipt = try read(url(requestID))
        guard receipt.digest == digest else { throw MailFailure.invalidMessage }
        return receipt.provenance
    }

    /// Deletes a receipt ONLY when read-only reconciliation proved the target
    /// mutation never reached the server (`notStarted`). This is the single
    /// path that lets a proven-safe retry proceed; unknown/completed receipts
    /// can never be cleared.
    public func clear(requestID: UUID, digest: String) throws {
        lock.lock(); defer { lock.unlock() }
        let file = url(requestID)
        let receipt = try read(file)
        guard receipt.digest == digest, receipt.state == .notStarted else {
            throw MailFailure.invalidMessage
        }
        try FileManager.default.removeItem(at: file)
    }

    // MARK: - Attempt ownership (single active owner per request)

    /// An open, flock-held descriptor over the request's stable owner inode.
    /// The lock outlives any wall-clock deadline: the kernel releases it only
    /// when the last descriptor closes (explicit release, deinit, or process
    /// death). The inode itself is never unlinked or replaced while it may be
    /// acting as a lock, which would otherwise break mutual exclusion for
    /// callers holding the old inode.
    public final class MailOwnerLock: @unchecked Sendable {
        private let fd: Int32
        private let stateLock = NSLock()
        private var released = false

        init(fd: Int32) { self.fd = fd }

        public func release() {
            stateLock.lock(); defer { stateLock.unlock() }
            guard !released else { return }
            released = true
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }

        deinit { release() }
    }

    /// Why an owner-lock acquisition did not succeed. `activeOther` means a
    /// live attempt (any journal instance, any process) holds the owner
    /// inode; `storageUnavailable` means the lock could not be opened or
    /// `flock` failed for a reason other than contention. The two are never
    /// conflated: an I/O or permission failure is not proof of a concurrent
    /// mutation, and neither condition is ever bypassed by a wall-clock
    /// lease.
    internal enum OwnerLockAcquisition: Sendable {
        case acquired(MailOwnerLock)
        case activeOther
        case storageUnavailable
    }

    /// Tries to become the single active owner of this request and reports
    /// WHY acquisition failed. Non-preemptible: there is no lease expiry to
    /// reclaim.
    internal func acquireOwnerLockResult(requestID: UUID) -> OwnerLockAcquisition {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .storageUnavailable
        }
        let path = ownerLockURL(requestID).path
        let fd = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { return .storageUnavailable }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            _ = close(fd)
            // EWOULDBLOCK (== EAGAIN on Darwin) is the only proof that a live
            // owner exists; every other failure is a storage problem.
            return code == EWOULDBLOCK ? .activeOther : .storageUnavailable
        }
        return .acquired(MailOwnerLock(fd: fd))
    }

    /// Convenience wrapper for callers that only need a lock or nil.
    internal func acquireOwnerLock(requestID: UUID) -> MailOwnerLock? {
        switch acquireOwnerLockResult(requestID: requestID) {
        case .acquired(let owner): return owner
        case .activeOther, .storageUnavailable: return nil
        }
    }

    // MARK: - Storage primitives

    /// Internal control error: an exclusive publish found the target already
    /// exists. Never escapes this type's API.
    private enum JournalPublishError: Error {
        case duplicate
    }

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent("mutation-" + id.uuidString + ".json")
    }

    /// Stable per-request owner inode. It is created once and NEVER unlinked
    /// or replaced: unlinking an inode that may still be acting as a lock
    /// would let a second caller lock a fresh inode at the same path.
    private func ownerLockURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("mutation-" + id.uuidString + ".owner")
    }

    /// Writes `value` to a unique staging file and hard-links it into place.
    /// `linkItem` fails when the final name already exists, which makes
    /// creation atomic across threads, journal instances and processes
    /// without ever leaving a partially written final file behind.
    private func publishNew<T: Encodable>(_ value: T, to file: URL) throws {
        let data = try JSONEncoder().encode(value)
        let staging = directory.appendingPathComponent(
            file.lastPathComponent + ".staging-" + UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeData(data, to: staging)
        do {
            try FileManager.default.linkItem(at: staging, to: file)
        } catch {
            if FileManager.default.fileExists(atPath: file.path) {
                throw JournalPublishError.duplicate
            }
            // The staging file could not be linked and no claim exists:
            // surface a conservative failure, never a false grant.
            throw MailFailure.invalidMessage
        }
    }

    private func read(_ file: URL) throws -> Receipt {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8192 else {
            throw MailFailure.invalidMessage
        }
        do { return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file)) }
        catch { throw MailFailure.invalidMessage }
    }

    private func write(_ receipt: Receipt, to file: URL) throws {
        let data = try JSONEncoder().encode(receipt)
        try writeData(data, to: file)
    }

    private func writeData(_ data: Data, to file: URL) throws {
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    /// Removes staging artifacts left by a process that died between the
    /// staging write and the link. Only files older than a fixed safety
    /// horizon are touched, so live publishers are never disrupted.
    private func sweepStaleStagingFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where entry.contains(".staging-") {
            let file = directory.appendingPathComponent(entry)
            let age = ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate).map { Date().timeIntervalSince($0) } ?? 0
            if age > 600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func isValidDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The exact facts one mailbox mutation is bound to, plus its receipt digest.
/// The digest composition is byte-identical to the one MailTools used before
/// this type existed, so receipts reserved by earlier builds keep validating
/// after the resume ordering lands.
public struct MailMoveOperation: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var accountID: UUID
    public var action: String
    public var sourceFolder: String
    public var destination: String
    public var uid: String
    public var mailboxVersion: String

    public init(
        requestID: UUID,
        accountID: UUID,
        action: String,
        sourceFolder: String,
        destination: String,
        uid: String,
        mailboxVersion: String
    ) {
        self.requestID = requestID
        self.accountID = accountID
        self.action = action
        self.sourceFolder = sourceFolder
        self.destination = destination
        self.uid = uid
        self.mailboxVersion = mailboxVersion
    }

    public var digest: String {
        MailMutationDigest.sha256Hex(
            Data([accountID.uuidString, sourceFolder, uid, action, destination, mailboxVersion]
                .joined(separator: "\n").utf8)
        )
    }

    public func provenance(from identity: MailMutationJournal.StableIdentity) -> MailMutationJournal.Provenance {
        MailMutationJournal.Provenance(
            accountID: accountID,
            action: action,
            sourceFolder: sourceFolder,
            destination: destination,
            uid: uid,
            mailboxVersion: mailboxVersion,
            messageID: identity.messageID,
            byteCount: identity.byteCount
        )
    }
}

/// A granted, kernel-owned right to perform exactly one mutation attempt.
/// The holder must keep it across the real `MailClient.move` and the receipt
/// `finish`, then release it. Ownership is an open `flock` descriptor: it is
/// never revoked by wall-clock time, only by this release (or process death,
/// when the kernel closes the descriptor). Releasing is idempotent.
public struct MailMoveAttempt: Sendable {
    public let provenance: MailMutationJournal.Provenance
    public let requestID: UUID
    public let digest: String
    private let owner: MailMutationJournal.MailOwnerLock

    init(
        provenance: MailMutationJournal.Provenance,
        requestID: UUID,
        digest: String,
        owner: MailMutationJournal.MailOwnerLock
    ) {
        self.provenance = provenance
        self.requestID = requestID
        self.digest = digest
        self.owner = owner
    }

    /// Ends the active-owner claim. Ordinary code paths call this after the
    /// receipt reaches its terminal state (or the attempt failed without
    /// submitting); the journal keeps a `mutationUnknown` receipt until a
    /// later read-only reconciliation resolves it. A dead process releases
    /// ownership implicitly when the kernel closes the descriptor.
    public func release() {
        owner.release()
    }
}

/// Caller facts for one mutation request, before any server or credential
/// access. `destination` is present only for an explicit `move`; archive and
/// trash resolve their destination from the server (or reuse the one stored
/// in an existing receipt).
public struct MailMoveRequest: Sendable, Equatable {
    public var requestID: UUID
    public var accountID: UUID
    public var action: String
    public var sourceFolder: String
    public var uid: String
    public var mailboxVersion: String
    public var destination: String?

    public init(
        requestID: UUID,
        accountID: UUID,
        action: String,
        sourceFolder: String,
        uid: String,
        mailboxVersion: String,
        destination: String? = nil
    ) {
        self.requestID = requestID
        self.accountID = accountID
        self.action = action
        self.sourceFolder = sourceFolder
        self.uid = uid
        self.mailboxVersion = mailboxVersion
        self.destination = destination
    }

    public func operation(destination: String) -> MailMoveOperation {
        MailMoveOperation(
            requestID: requestID,
            accountID: accountID,
            action: action,
            sourceFolder: sourceFolder,
            destination: destination,
            uid: uid,
            mailboxVersion: mailboxVersion
        )
    }
}

public enum MailMovePreparation: Sendable {
    /// Bound to an existing receipt (destination reused from provenance), to a
    /// legacy terminal archive/trash receipt whose server folder was resolved
    /// once and whose original digest matched, or to a first request whose
    /// destination is now resolved.
    case ready(MailMoveOperation)
    /// A legacy receipt exists but cannot be bound to this request (still
    /// ambiguous, offline, no declared folder, or unverifiable facts). It
    /// must not be retried or moved, and no destination may be guessed.
    case uncertain(reason: String)
}

/// The production resume order for one mailbox-mutation request, separated
/// from the live IMAP session through injected seams so the exact sequence —
/// digest → read-only snapshot → replay/reconcile → only-then source identity
/// → reserve → owner → move — has behavioral test evidence:
///
///  * A receipt is recovered BEFORE anything touches the source message, so a
///    completed or ambiguous mutation whose source mail is already gone still
///    replays or reconciles instead of failing with a misleading notFound.
///  * `completed`/`notStarted` receipts replay with no network, credential or
///    source access. The single legacy exception is an archive/trash receipt
///    reserved before provenance existed: `prepare` may resolve the
///    server-declared folder ONCE to verify its original digest, after which
///    `execute` still reads no source and never repeats the mutation.
///  * `mutationUnknown` reconciles read-only from the PERSISTED provenance
///    and never re-issues the mutation blindly; a legacy `mutationUnknown`
///    without stored provenance stays explicitly uncertain (a terminal legacy
///    receipt is rebound only through the exception above).
///  * A first attempt whose source is missing fails honestly: no receipt is
///    minted from a fabricated success.
///  * If the source read fails in the window after the pre-snapshot (a
///    concurrent same-request execution moved the mail and finalized its
///    receipt), the newest receipt under the same digest is reclaimed and its
///    idempotent state is honored instead of reporting notFound.
///  * Every `.firstAttempt` is issued only while holding the non-preemptible
///    per-request owner `flock`, and reconciliation itself requires that same
///    ownership. A read-only "the target is not there yet" can therefore
///    never preempt a live mutation, however long the writer runs, and two
///    callers (even through separate journal instances) can never both hold
///    the right to write. Recovery after a crash happens because the kernel
///    released the dead process's descriptor — never by expiring a live one.
public struct MailMoveOrchestration: Sendable {
    public enum Outcome: Sendable {
        /// This call owns the one permitted mutation attempt: the receipt is
        /// reserved (freshly, or after the previous unknown was proven never
        /// submitted) AND the non-preemptible per-request owner is held. The
        /// caller performs the move exactly once, finalizes the receipt, then
        /// releases.
        case firstAttempt(MailMoveAttempt)
        /// A terminal receipt exists; return it without touching the server.
        case replay(MailMutationJournal.State)
        /// Read-only reconciliation proved the persisted mutation landed.
        /// `receiptPersisted` is false when the verified completion could
        /// not be written back to the receipt store: the server result stays
        /// authoritative and must be reported as success, with the failed
        /// local write made visible instead of silently claimed.
        case reconciledCompleted(
            destinationUID: String?,
            destinationMailboxVersion: String?,
            receiptPersisted: Bool
        )
        /// The outcome of a previous ambiguous attempt cannot be verified, or
        /// another attempt is actively owned. The mutation must NOT be
        /// repeated; the reason is user-safe.
        case uncertain(reason: String)
    }

    public struct Seams: Sendable {
        /// Read-only stable identity of the source message. Only first
        /// attempts may call it; it may throw (missing source, changed
        /// mailbox) and that failure must not fabricate any state.
        public var identity: @Sendable (MailMoveOperation) async throws -> MailMutationJournal.StableIdentity
        /// Bounded read-only reconciliation of persisted provenance. Never
        /// issues COPY/MOVE/STORE/EXPUNGE/DELETE.
        public var reconcile: @Sendable (MailMutationJournal.Provenance) async throws -> MailMutationJournal.Reconciliation

        public init(
            identity: @escaping @Sendable (MailMoveOperation) async throws -> MailMutationJournal.StableIdentity,
            reconcile: @escaping @Sendable (MailMutationJournal.Provenance) async throws -> MailMutationJournal.Reconciliation
        ) {
            self.identity = identity
            self.reconcile = reconcile
        }
    }

    private let journal: MailMutationJournal
    private let seams: Seams

    public init(journal: MailMutationJournal, seams: Seams) {
        self.journal = journal
        self.seams = seams
    }

    /// Receipt-first preparation for the real tool path:
    ///
    ///  * An existing receipt WITH provenance is bound to this call's own
    ///    request facts (account, action, source folder, UID, mailbox
    ///    version, and the explicit destination for `move`). The destination
    ///    stored in the receipt is reused, the digest is recomputed from
    ///    those facts and must match the stored one — another request's
    ///    provenance is never trusted and a mismatch fails closed. This path
    ///    never resolves a folder, reads credentials or touches the source.
    ///  * A legacy receipt (reserved before provenance existed) for an
    ///    explicit `move` is rebound offline from that destination.
    ///  * A legacy `completed`/`notStarted` receipt for `archive`/`trash` may
    ///    still be recoverable: the server-declared folder is resolved
    ///    EXACTLY ONCE, the original digest is rebuilt from this call's own
    ///    account, action, source folder, UID, mailbox version and the
    ///    resolved destination, and only an exact match authorizes `.ready`
    ///    (which then replays in `execute` with no source read and no
    ///    mutation). An offline/unavailable resolver or an unbound digest
    ///    stays an honest uncertainty/error; the old receipt is never
    ///    rewritten and no folder is guessed.
    ///  * A legacy `mutationUnknown` receipt is never resolved: a folder
    ///    cannot prove whether the mutation was submitted, so it remains
    ///    explicitly uncertain.
    ///  * `resolveDestination` is otherwise invoked only for a true first
    ///    archive/trash request (no receipt), which is the only other path
    ///    that needs credentials for this resolution.
    public func prepare(
        _ request: MailMoveRequest,
        resolveDestination: @Sendable (MailMoveRequest) async throws -> String
    ) async throws -> MailMovePreparation {
        if let descriptor = try journal.receiptDescriptor(requestID: request.requestID) {
            if let provenance = descriptor.provenance {
                guard provenance.accountID == request.accountID,
                      provenance.action == request.action,
                      provenance.sourceFolder == request.sourceFolder,
                      provenance.uid == request.uid,
                      provenance.mailboxVersion == request.mailboxVersion,
                      request.action != "move" || provenance.destination == request.destination,
                      request.action == "move" || request.destination == nil else {
                    throw MailFailure.invalidMessage
                }
                let operation = request.operation(destination: provenance.destination)
                guard operation.digest == descriptor.digest else { throw MailFailure.invalidMessage }
                return .ready(operation)
            }
            // Legacy receipt (reserved before provenance existed). An explicit
            // move carries enough offline facts to rebuild the digest;
            // nothing is resolved and no destination is invented.
            if request.action == "move", let destination = request.destination {
                let operation = request.operation(destination: destination)
                guard operation.digest == descriptor.digest else { throw MailFailure.invalidMessage }
                return .ready(operation)
            }
            // Only a terminal archive/trash receipt can be recovered, and only
            // by binding the server-declared folder to the ORIGINAL digest.
            // An ambiguous legacy receipt must never be resolved: a folder
            // lookup cannot prove whether the mutation was submitted.
            guard ["archive", "trash"].contains(request.action), request.destination == nil else {
                return .uncertain(reason: "legacyReceiptUnverifiable")
            }
            guard descriptor.state == .completed || descriptor.state == .notStarted else {
                return .uncertain(reason: "legacyReceiptNoProvenance")
            }
            let resolved: String
            do {
                resolved = try await resolveDestination(request)
            } catch {
                if error is CancellationError { throw error }
                // Offline/keychain failure or no declared folder: keep the old
                // receipt untouched and state the honest uncertainty.
                return .uncertain(reason: "legacyReceiptUnverifiable")
            }
            let operation = request.operation(destination: resolved)
            guard operation.digest == descriptor.digest else { throw MailFailure.invalidMessage }
            return .ready(operation)
        }
        let destination: String
        if request.action == "move" {
            guard let explicit = request.destination else { throw MailFailure.invalidConfiguration }
            destination = explicit
        } else {
            destination = try await resolveDestination(request)
        }
        return .ready(request.operation(destination: destination))
    }

    public func execute(_ operation: MailMoveOperation) async throws -> Outcome {
        let digest = operation.digest
        // 1. Digest + read-only snapshot FIRST: no directory or file is
        //    created here, and no source message must exist.
        if let receipt = try journal.snapshot(requestID: operation.requestID, digest: digest) {
            return try await resume(operation: operation, digest: digest, receipt: receipt)
        }
        // 2. First attempt: capture the stable identity BEFORE minting the
        //    receipt so an ambiguous outcome is always reconcilable.
        let identity: MailMutationJournal.StableIdentity
        do {
            identity = try await seams.identity(operation)
        } catch {
            // 3. Race window: a concurrent execution of the SAME request may
            //    have reserved, moved the mail and finalized its receipt in
            //    the meantime — which is exactly why the source is now
            //    unreadable. Reclaim the newest receipt under the same
            //    digest and honor its idempotent state before ever surfacing
            //    the source-read failure.
            let fresher: MailMutationJournal.Snapshot?
            do {
                fresher = try journal.snapshot(requestID: operation.requestID, digest: digest)
            } catch {
                throw error // corrupt or digest-mismatched receipt fails closed, not notFound.
            }
            if let fresher {
                return try await resume(operation: operation, digest: digest, receipt: fresher)
            }
            throw error // genuinely first request with a missing source: honest failure.
        }
        let provenance = operation.provenance(from: identity)
        if let raced = try journal.reserve(requestID: operation.requestID, digest: digest, provenance: provenance) {
            // Lost the reservation to a concurrent same-digest call: honor
            // its receipt instead of issuing a second mutation.
            var receipt = MailMutationJournal.Snapshot(state: raced, provenance: nil)
            if let fresh = try? journal.snapshot(requestID: operation.requestID, digest: digest) {
                receipt = fresh
            }
            return try await resume(operation: operation, digest: digest, receipt: receipt)
        }
        // Won the reservation; become the sole owner before the attempt is
        // granted. Ownership lasts until the caller finalizes and releases.
        switch journal.acquireOwnerLockResult(requestID: operation.requestID) {
        case .acquired(let owner):
            return .firstAttempt(MailMoveAttempt(
                provenance: provenance,
                requestID: operation.requestID,
                digest: digest,
                owner: owner
            ))
        case .activeOther:
            // A previous attempt still owns this request; the freshly
            // reserved receipt stays `mutationUnknown` and a later call
            // reconciles it once ownership is free.
            return .uncertain(reason: "concurrentAttemptActive")
        case .storageUnavailable:
            // No mutation right is granted and the honest storage problem is
            // reported instead of a false concurrent attempt.
            return .uncertain(reason: "storageUnavailable")
        }
    }

    private func resume(
        operation: MailMoveOperation,
        digest: String,
        receipt: MailMutationJournal.Snapshot
    ) async throws -> Outcome {
        switch receipt.state {
        case .completed, .notStarted:
            return .replay(receipt.state)
        case .mutationUnknown:
            // Reconciliation itself requires ownership: while any live
            // attempt holds the per-request owner flock, its move/ finish is
            // still possible, so a read-only "not submitted yet" verdict
            // must not be trusted and the receipt must not be rewritten.
            let owner: MailMutationJournal.MailOwnerLock
            switch journal.acquireOwnerLockResult(requestID: operation.requestID) {
            case .acquired(let acquired):
                owner = acquired
            case .activeOther:
                return .uncertain(reason: "concurrentAttemptActive")
            case .storageUnavailable:
                return .uncertain(reason: "storageUnavailable")
            }
            // Re-read under ownership: the receipt may have reached a
            // terminal state while this call was acquiring.
            let current: MailMutationJournal.Snapshot?
            do {
                current = try journal.snapshot(requestID: operation.requestID, digest: digest)
            } catch {
                owner.release()
                throw error
            }
            guard let current, current.state == .mutationUnknown else {
                owner.release()
                guard let current else { return .uncertain(reason: "receiptMissing") }
                return .replay(current.state)
            }
            guard let facts = current.provenance else {
                // Legacy receipt without persisted provenance: it cannot be
                // verified read-only, so state the uncertainty explicitly.
                // Never re-move, and never re-read the source to guess.
                owner.release()
                return .uncertain(reason: "legacyReceiptNoProvenance")
            }
            let reconciliation: MailMutationJournal.Reconciliation
            do {
                reconciliation = try await seams.reconcile(facts)
            } catch let failure as MailFailure {
                owner.release()
                return .uncertain(reason: failure.rawValue)
            } catch {
                owner.release()
                return .uncertain(reason: "failed")
            }
            switch reconciliation {
            case .notSubmitted:
                // Receipt rewriting stays inside the same ownership, so no
                // concurrent caller can slip a mutation attempt into the
                // reconcile → re-reserve window. Every write is checked: a
                // storage failure must never be reported as a concurrent
                // attempt and must never hand out mutation rights.
                do {
                    try journal.finish(requestID: operation.requestID, digest: digest, state: .notStarted)
                    try journal.clear(requestID: operation.requestID, digest: digest)
                } catch let failure as MailFailure {
                    owner.release()
                    throw failure
                } catch {
                    owner.release()
                    return .uncertain(reason: "storageUnavailable")
                }
                do {
                    if try journal.reserve(requestID: operation.requestID, digest: digest, provenance: facts) != nil {
                        // A writer outside this protocol re-reserved in
                        // between; do not stack a second attempt.
                        owner.release()
                        return .uncertain(reason: "concurrentReservation")
                    }
                } catch let failure as MailFailure {
                    owner.release()
                    throw failure
                } catch {
                    owner.release()
                    return .uncertain(reason: "storageUnavailable")
                }
                return .firstAttempt(MailMoveAttempt(
                    provenance: facts,
                    requestID: operation.requestID,
                    digest: digest,
                    owner: owner
                ))
            case .completed(let destinationUID, let destinationVersion):
                // The verified server result is authoritative. A failed local
                // write-back must not turn a completed mutation into an
                // execution failure or a silent claim that it was saved; the
                // receipt stays ambiguous and a later retry reconciles again.
                let persisted: Bool
                do {
                    try journal.finish(requestID: operation.requestID, digest: digest, state: .completed)
                    persisted = true
                } catch {
                    persisted = false
                }
                owner.release()
                return .reconciledCompleted(
                    destinationUID: destinationUID,
                    destinationMailboxVersion: destinationVersion,
                    receiptPersisted: persisted
                )
            case .ambiguous(let reason):
                owner.release()
                return .uncertain(reason: reason)
            }
        }
    }
}

/// Internal lowercase-hex SHA-256 helper. Formatting is identical to
/// `FloeCore.FloeDigest.sha256Hex`, so digests recorded by earlier tool
/// versions keep validating.
enum MailMutationDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
