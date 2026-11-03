import Foundation

/// Durable, non-secret send receipts. Reserve before touching SMTP so process
/// termination or a resumed tool call cannot silently submit the same mail twice.
/// One process owns the journal; callers serialize admission through this object.
public final class MailDeliveryJournal: @unchecked Sendable {
    public enum State: String, Codable, Sendable { case deliveryUnknown, acceptedByServer, notSubmitted }
    private struct Receipt: Codable { var digest: String; var state: State }
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }

    /// nil authorizes the first attempt; a returned state is a replay, never an
    /// instruction to resend. Corrupt receipts fail closed and are preserved.
    public func reserve(requestID: UUID, digest: String) throws -> State? {
        lock.lock(); defer { lock.unlock() }
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MailFailure.invalidMessage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(requestID)
        if FileManager.default.fileExists(atPath: file.path) {
            let receipt = try read(file)
            guard receipt.digest == digest else { throw MailFailure.invalidMessage }
            return receipt.state
        }
        try write(Receipt(digest: digest, state: .deliveryUnknown), to: file)
        return nil
    }

    public func finish(requestID: UUID, digest: String, state: State) throws {
        lock.lock(); defer { lock.unlock() }
        let file = url(requestID)
        let previous = try read(file)
        guard previous.digest == digest, previous.state == .deliveryUnknown || previous.state == state else { throw MailFailure.invalidMessage }
        try write(Receipt(digest: digest, state: state), to: file)
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func read(_ file: URL) throws -> Receipt {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096 else { throw MailFailure.invalidMessage }
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
