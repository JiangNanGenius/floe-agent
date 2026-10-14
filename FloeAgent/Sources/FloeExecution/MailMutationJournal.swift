import Foundation

/// Durable, non-secret receipts for ambiguous mailbox mutations (move,
/// archive, trash). A receipt — including the operation provenance needed for
/// later read-only reconciliation — is reserved BEFORE the first mutating IMAP
/// command; if the process dies or the connection drops mid-command, the
/// recorded `mutationUnknown` state is returned to every later call with the
/// same request identity so nothing is silently repeated. Corrupt receipts
/// fail closed and are preserved.
public final class MailMutationJournal: @unchecked Sendable {
    public enum State: String, Codable, Sendable { case mutationUnknown, completed, notStarted }

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

    private struct Receipt: Codable {
        var digest: String
        var state: State
        /// Absent on receipts written before provenance was introduced.
        var provenance: Provenance?
    }

    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }

    /// nil authorizes the first attempt; a returned state is a replay, never
    /// an instruction to repeat the mutation. `provenance` is persisted with
    /// the reservation for later read-only reconciliation.
    @discardableResult
    public func reserve(
        requestID: UUID,
        digest: String,
        provenance: Provenance? = nil
    ) throws -> State? {
        lock.lock(); defer { lock.unlock() }
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MailFailure.invalidMessage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(requestID)
        if FileManager.default.fileExists(atPath: file.path) {
            let receipt = try read(file)
            guard receipt.digest == digest else { throw MailFailure.invalidMessage }
            return receipt.state
        }
        try write(Receipt(digest: digest, state: .mutationUnknown, provenance: provenance), to: file)
        return nil
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

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent("mutation-" + id.uuidString + ".json")
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
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}
