import Foundation

/// One bounded operation at a time; CFStream work never runs on Swift's
/// cooperative executor or on the main thread. Sessions are not pooled/replayed.
public final class MailClient: @unchecked Sendable {
    public static let shared = MailClient()
    private let lock = NSLock()
    private var running = false
    private let queue = DispatchQueue(label: "org.floeagent.mail", qos: .utility)
    public init() {}

    private func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }; running = true; return true
    }
    private func release() { lock.lock(); running = false; lock.unlock() }
    private func perform<T: Sendable>(server: MailServer, cancelled: @escaping @Sendable () -> Bool,
                                      operation: @escaping @Sendable (MailProtocolSession) throws -> T) async throws -> T {
        guard acquire() else { throw MailFailure.busy }
        let cancellation = MailOperationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { release() }
                    do {
                        let wire = try MailStreamWire(server: server, cancelled: { cancellation.isCancelled || cancelled() })
                        defer { wire.close() }
                        continuation.resume(returning: try operation(MailProtocolSession(wire: wire)))
                    } catch let error as MailFailure { continuation.resume(throwing: error) }
                    catch { continuation.resume(throwing: MailFailure.connectionFailed) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    public func test(server: MailServer, protocolName: String, password: String) async throws {
        try await perform(server: server, cancelled: { false }) { session in
            switch protocolName {
            case "smtp": try session.loginSMTP(server: server, password: password)
            case "imap": try session.loginIMAP(server: server, password: password)
            case "pop3": try session.loginPOP(server: server, password: password)
            default: throw MailFailure.invalidConfiguration
            }
        }
    }
    public func folders(account: MailAccount, password: String, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> [String] {
        try account.validate()
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            if account.incomingProtocol == .pop3 {
                try session.loginPOP(server: account.incoming, password: password); return ["INBOX"]
            }
            try session.loginIMAP(server: account.incoming, password: password)
            let reply = try session.imap("LIST \"\" \"*\"")
            guard reply.literals.isEmpty else { throw MailFailure.protocolRejected }
            return try reply.lines.filter { $0.uppercased().hasPrefix("* LIST ") }.map { line in
                guard let name = Self.matches(#"^\* LIST \([^)]*\) (?:NIL|\"(?:[^\"\\]|\\.)*\") (.+)$"#, line).first?.first else {
                    throw MailFailure.protocolRejected
                }
                if name.hasPrefix("\""), name.hasSuffix("\"") {
                    return String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                return name
            }
        }
    }
    public func list(account: MailAccount, password: String, folder: String = "INBOX", afterUID: UInt32 = 0,
                     limit: Int = 20, beforeMessageID: String? = nil, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MailListing {
        try account.validate()
        guard (1...50).contains(limit), afterUID < UInt32.max else { throw MailFailure.invalidConfiguration }
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            if account.incomingProtocol == .pop3 {
                guard folder == "INBOX", afterUID == 0 else { throw MailFailure.invalidConfiguration }
                try session.loginPOP(server: account.incoming, password: password)
                let ids = try Self.popIDs(session)
                let sizes = try session.popLines("LIST").map { line -> (Int, Int) in
                    let parts = line.split(separator: " "); guard parts.count == 2, let index = Int(parts[0]), index > 0, let size = Int(parts[1]), size >= 0 else { throw MailFailure.protocolRejected }
                    return (index, size)
                }
                return try Self.popPage(ids: ids, sizes: sizes, before: beforeMessageID, limit: limit)
            }
            guard beforeMessageID == nil else { throw MailFailure.invalidConfiguration }
            try session.loginIMAP(server: account.incoming, password: password)
            let selected = try session.imap("EXAMINE \(MailProtocolSession.quoted(folder))")
            let version = try Self.uidValidity(selected)
            let search = try session.imap("UID SEARCH UID \(afterUID + 1):*")
            let ids = search.lines.filter { $0.hasPrefix("* SEARCH") }.flatMap {
                $0.split(separator: " ").dropFirst(2).compactMap { UInt32($0) }
            }.filter { $0 > afterUID }.sorted()
            // Ascending pages make afterUID a monotonic, lossless cursor.
            let page = Array(ids.prefix(limit))
            guard !page.isEmpty else { return MailListing(folder: folder, mailboxVersion: version, messages: [], hasMore: false) }
            let fetched = try session.imap("UID FETCH \(page.map(String.init).joined(separator: ",")) (UID RFC822.SIZE FLAGS)")
            var entries: [MailMessageReference] = []
            for line in fetched.lines where line.contains(" FETCH ") {
                guard let uid = Self.matches(#"\bUID (\d+)"#, line).first?.first,
                      let sizeText = Self.matches(#"RFC822\.SIZE (\d+)"#, line).first?.first,
                      let size = Int(sizeText) else { throw MailFailure.protocolRejected }
                let flags = Self.matches(#"FLAGS \(([^)]*)\)"#, line).first?.first?.split(separator: " ").map(String.init) ?? []
                entries.append(.init(id: uid, byteCount: size, flags: flags))
            }
            return MailListing(folder: folder, mailboxVersion: version, messages: entries, hasMore: ids.count > limit)
        }
    }
    public func message(account: MailAccount, password: String, id: String, folder: String = "INBOX", mailboxVersion: String?,
                        cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Data {
        try account.validate()
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            if account.incomingProtocol == .pop3 {
                guard folder == "INBOX" else { throw MailFailure.invalidConfiguration }
                try session.loginPOP(server: account.incoming, password: password)
                guard let index = try Self.popIDs(session).first(where: { $0.value == id })?.key else { throw MailFailure.messageNotFound }
                let sizeLine = try session.pop("LIST \(index)")
                guard let size = Int(sizeLine.split(separator: " ").last ?? ""), size <= 16_000_000 else { throw MailFailure.responseTooLarge }
                return try session.popMessage(index)
            }
            guard let uid = UInt32(id), uid > 0, let mailboxVersion else { throw MailFailure.invalidConfiguration }
            try session.loginIMAP(server: account.incoming, password: password)
            guard try Self.uidValidity(session.imap("EXAMINE \(MailProtocolSession.quoted(folder))")) == mailboxVersion else { throw MailFailure.mailboxChanged }
            let reply = try session.imap("UID FETCH \(uid) (BODY.PEEK[])")
            let returnedUIDs = Self.matches(#"\bUID (\d+)"#, reply.lines.joined(separator: " ")).compactMap(\.first)
            guard reply.literals.count == 1, returnedUIDs == [String(uid)] else { throw MailFailure.messageNotFound }
            return reply.literals[0]
        }
    }
    public func setRead(account: MailAccount, password: String, id: String, folder: String, mailboxVersion: String, read: Bool,
                        cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try account.validate()
        guard account.incomingProtocol == .imap, let uid = UInt32(id), uid > 0 else { throw MailFailure.invalidConfiguration }
        try await perform(server: account.incoming, cancelled: cancelled) { session in
            try session.loginIMAP(server: account.incoming, password: password)
            guard try Self.uidValidity(session.imap("SELECT \(MailProtocolSession.quoted(folder))")) == mailboxVersion else { throw MailFailure.mailboxChanged }
            try session.setRead(uid: uid, read: read)
            // Socket close, not CLOSE/EXPUNGE: never commit unrelated deleted mail.
        }
    }
    static func popPage(ids: [Int: String], sizes: [(Int, Int)], before: String?, limit: Int) throws -> MailListing {
        guard Set(sizes.map(\.0)).count == sizes.count, Set(sizes.map(\.0)) == Set(ids.keys) else { throw MailFailure.protocolRejected }
        let ceiling: Int
        if let before {
            guard let index = ids.first(where: { $0.value == before })?.key else { throw MailFailure.mailboxChanged }
            ceiling = index
        } else { ceiling = Int.max }
        let remaining = sizes.filter { $0.0 < ceiling }.sorted { $0.0 > $1.0 }
        let entries = remaining.prefix(limit).map { MailMessageReference(id: ids[$0.0]!, byteCount: $0.1) }
        let more = remaining.count > limit
        return MailListing(folder: "INBOX", mailboxVersion: nil, messages: entries, hasMore: more, nextBeforeMessageID: more ? entries.last?.id : nil)
    }
    public func send(account: MailAccount, password: String, draft: MailDraft, messageID: UUID,
                     cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try account.validate(); try draft.validate()
        try await perform(server: account.outgoing, cancelled: cancelled) { session in
            try session.loginSMTP(server: account.outgoing, password: password)
            try session.send(from: account.address, draft: draft, messageID: messageID)
        }
    }
    private static func popIDs(_ session: MailProtocolSession) throws -> [Int: String] {
        var result: [Int: String] = [:]; var seen = Set<String>()
        for line in try session.popLines("UIDL") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let index = Int(parts[0]), index > 0, parts[1].utf8.count <= 70,
                  result[index] == nil, seen.insert(String(parts[1])).inserted else { throw MailFailure.protocolRejected }
            result[index] = String(parts[1])
        }
        return result
    }
    private static func uidValidity(_ reply: MailProtocolSession.IMAPReply) throws -> String {
        guard let value = matches(#"\[UIDVALIDITY (\d+)\]"#, reply.lines.joined(separator: "\n")).first?.first else {
            throw MailFailure.protocolRejected
        }
        return value
    }
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
}

private final class MailOperationCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
