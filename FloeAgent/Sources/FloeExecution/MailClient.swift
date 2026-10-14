import Foundation

/// Structured, bounded IMAP search criteria. Every field is optional; at
/// least one criterion (or a cursor continuation) is required so a search can
/// never silently scan an entire mailbox. Queries are sent as quoted IMAP
/// strings; control characters and overlong values are rejected before any
/// wire write.
public struct MailSearchCriteria: Sendable, Equatable {
    public var from: String?
    public var to: String?
    public var subject: String?
    /// IMAP TEXT search (headers and body).
    public var text: String?
    public var seen: Bool?
    public var flagged: Bool?
    public var since: Date?
    public var until: Date?

    public init(
        from: String? = nil,
        to: String? = nil,
        subject: String? = nil,
        text: String? = nil,
        seen: Bool? = nil,
        flagged: Bool? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) {
        self.from = from
        self.to = to
        self.subject = subject
        self.text = text
        self.seen = seen
        self.flagged = flagged
        self.since = since
        self.until = until
    }

    public var isEmpty: Bool {
        from == nil && to == nil && subject == nil && text == nil
            && seen == nil && flagged == nil && since == nil && until == nil
    }
}

/// One stable, descending page of an IMAP search. `mailboxVersion` is the
/// folder's UIDVALIDITY at snapshot time; mutations must present it back.
public struct MailSearchPage: Codable, Sendable {
    public var folder: String
    public var mailboxVersion: String
    public var messages: [MailMessageReference]
    public var hasMore: Bool
    public var nextCursor: String?
    /// Total messages the server reported for this query.
    public var totalMatched: Int

    public init(
        folder: String,
        mailboxVersion: String,
        messages: [MailMessageReference],
        hasMore: Bool,
        nextCursor: String?,
        totalMatched: Int
    ) {
        self.folder = folder
        self.mailboxVersion = mailboxVersion
        self.messages = messages
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.totalMatched = totalMatched
    }
}

/// One IMAP folder with its LIST attributes (special-use flags included).
public struct MailFolderInfo: Codable, Sendable, Equatable {
    public var name: String
    public var attributes: [String]

    public init(name: String, attributes: [String]) {
        self.name = name
        self.attributes = attributes
    }
}

/// Verified outcome of one bounded move/archive/trash. `expunged` states the
/// exact source-side effect: `targeted` (UID EXPUNGE, or an atomic MOVE),
/// `notSupported` (marked \Deleted; the server has no targeted expunge, so no
/// global expunge is issued) or `notAttempted`.
public struct MailMoveOutcome: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var uid: String
    public var sourceFolder: String
    public var destination: String
    public var mailboxVersion: String
    public var destinationUID: String?
    public var destinationMailboxVersion: String?
    public var expunged: String
    public var destinationVerified: Bool

    public init(
        requestID: UUID,
        uid: String,
        sourceFolder: String,
        destination: String,
        mailboxVersion: String,
        destinationUID: String?,
        destinationMailboxVersion: String?,
        expunged: String,
        destinationVerified: Bool
    ) {
        self.requestID = requestID
        self.uid = uid
        self.sourceFolder = sourceFolder
        self.destination = destination
        self.mailboxVersion = mailboxVersion
        self.destinationUID = destinationUID
        self.destinationMailboxVersion = destinationMailboxVersion
        self.expunged = expunged
        self.destinationVerified = destinationVerified
    }
}

/// Stable, read-only identity of one message, captured BEFORE a mutation so an
/// ambiguous outcome can later be reconciled without repeating it.
public struct MailMessageIdentity: Codable, Sendable, Equatable {
    /// Message-ID header value (angle brackets stripped), or nil when the
    /// server rejects the header fetch or the header is unusable.
    public var messageID: String?
    public var byteCount: Int

    public init(messageID: String?, byteCount: Int) {
        self.messageID = messageID
        self.byteCount = byteCount
    }
}

/// Result of a bounded, read-only reconciliation of an ambiguous move.
public enum MailMoveReconciliation: Sendable, Equatable {
    /// Proven that no mutation reached the server: the source is intact and no
    /// destination copy with the persisted identity exists.
    case notSubmitted
    /// Proven that the destination copy exists and the source is gone or
    /// marked deleted.
    case completed(destinationUID: String?, destinationMailboxVersion: String?)
    /// Evidence is incomplete (missing identity, changed UIDVALIDITY, copy
    /// present but source intact). Explicitly unknown; never repeat.
    case ambiguous(reason: String)
}

/// Special folders a bounded mutation may target. Only server-declared
/// special-use attributes (RFC 6154) or the conventional folder name are
/// accepted; nothing is guessed.
public enum MailSpecialFolder: String, Sendable {
    case archive
    case trash

    fileprivate var attribute: String {
        switch self {
        case .archive: "\\Archive"
        case .trash: "\\Trash"
        }
    }

    fileprivate var conventionalName: String {
        switch self {
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }
}

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
        try await foldersWithAttributes(account: account, password: password, cancelled: cancelled)
            .map(\.name)
    }

    /// LISTS folders with their attributes, used to resolve special-use
    /// folders (archive/trash) without guessing. POP3 exposes only INBOX.
    public func foldersWithAttributes(account: MailAccount, password: String, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> [MailFolderInfo] {
        try account.validate()
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            if account.incomingProtocol == .pop3 {
                try session.loginPOP(server: account.incoming, password: password)
                return [MailFolderInfo(name: "INBOX", attributes: [])]
            }
            try session.loginIMAP(server: account.incoming, password: password)
            return try Self.folderInfos(session: session)
        }
    }

    /// Parses `* LIST` replies (with attributes) from an already-authenticated
    /// session. Internal so mock-session tests can exercise the exact parse.
    static func folderInfos(session: MailProtocolSession) throws -> [MailFolderInfo] {
        let reply = try session.imap("LIST \"\" \"*\"")
        guard reply.literals.isEmpty else { throw MailFailure.protocolRejected }
        return try reply.lines.filter { $0.uppercased().hasPrefix("* LIST ") }.map { line in
            guard let match = Self.matches(#"^\* LIST \(([^)]*)\) (?:NIL|\"(?:[^\"\\]|\\.)*\") (.+)$"#, line).first,
                  match.count == 2 else {
                throw MailFailure.protocolRejected
            }
            let flags = match[0].split(separator: " ").map { String($0).uppercased() }
            let name = match[1]
            if name.hasPrefix("\""), name.hasSuffix("\"") {
                let unquoted = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                return MailFolderInfo(name: unquoted, attributes: flags)
            }
            return MailFolderInfo(name: name, attributes: flags)
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

    // MARK: - Structured search (IMAP)

    /// Runs one bounded, newest-first IMAP search page. The cursor embeds the
    /// folder and UIDVALIDITY of the snapshot; presenting it after the mailbox
    /// changed fails with `mailboxChanged` instead of returning mixed data.
    /// POP3 reports an explicit unsupported failure, never an empty list.
    public func search(
        account: MailAccount,
        password: String,
        folder: String = "INBOX",
        criteria: MailSearchCriteria,
        cursor: String? = nil,
        limit: Int = 20,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailSearchPage {
        try account.validate()
        guard (1...50).contains(limit) else { throw MailFailure.invalidConfiguration }
        guard account.incomingProtocol == .imap else { throw MailFailure.unsupportedForPOP3 }
        // The cursor binds folder + UIDVALIDITY + last UID; the caller repeats
        // the same criteria so the re-evaluated search stays identical.
        guard !criteria.isEmpty else { throw MailFailure.invalidConfiguration }
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            try session.loginIMAP(server: account.incoming, password: password)
            return try Self.performSearch(
                session: session,
                accountID: account.id,
                folder: folder,
                criteria: criteria,
                cursor: cursor,
                limit: limit
            )
        }
    }

    /// The complete search conversation, separated from transport so mock
    /// sessions exercise the exact same commands and checks. The cursor binds
    /// the account identity, folder, UIDVALIDITY, last UID AND the canonical
    /// criteria command: drifting on any of them is an explicit failure.
    static func performSearch(
        session: MailProtocolSession,
        accountID: UUID,
        folder: String,
        criteria: MailSearchCriteria,
        cursor: String?,
        limit: Int
    ) throws -> MailSearchPage {
        let command = try Self.searchCommand(criteria)
        let selected = try session.imap("EXAMINE \(MailProtocolSession.quoted(folder))")
        let version = try Self.uidValidity(selected)
        var afterUID: UInt32 = .max
        if let cursor {
            let decoded = try Self.decodeSearchCursor(cursor)
            guard decoded.accountID == accountID,
                  decoded.folder == folder,
                  decoded.criteriaKey == command else {
                throw MailFailure.cursorMismatch
            }
            guard decoded.mailboxVersion == version else { throw MailFailure.mailboxChanged }
            afterUID = decoded.uid
        }
        let search = try session.imap(command)
        var ids: [UInt32] = []
        for line in search.lines where line.uppercased().hasPrefix("* SEARCH") {
            for token in line.split(separator: " ").dropFirst(2) {
                guard let value = UInt32(token), value > 0, value < afterUID else { continue }
                ids.append(value)
            }
        }
        ids.sort(by: >)
        let page = Array(ids.prefix(limit))
        let hasMore = ids.count > page.count
        let nextCursor = hasMore
            ? Self.encodeSearchCursor(Self.SearchCursor(
                v: 1,
                accountID: accountID,
                folder: folder,
                mailboxVersion: version,
                uid: page.last ?? 0,
                criteriaKey: command
            ))
            : nil
        let entries = try Self.fetchReferences(session, uids: page)
        return MailSearchPage(
            folder: folder,
            mailboxVersion: version,
            messages: entries,
            hasMore: hasMore,
            nextCursor: nextCursor,
            totalMatched: ids.count
        )
    }

    /// Resolves a server-declared special-use folder (or its conventional
    /// name). Nil means the account has no such folder; callers report that
    /// honestly instead of inventing one.
    public func specialFolder(
        account: MailAccount,
        password: String,
        kind: MailSpecialFolder,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> String? {
        guard account.incomingProtocol == .imap else { throw MailFailure.unsupportedForPOP3 }
        let folders = try await foldersWithAttributes(
            account: account,
            password: password,
            cancelled: cancelled
        )
        if let flagged = folders.first(where: {
            $0.attributes.contains { $0.caseInsensitiveCompare(kind.attribute) == .orderedSame }
        }) {
            return flagged.name
        }
        return folders.first {
            $0.name.caseInsensitiveCompare(kind.conventionalName) == .orderedSame
        }?.name
    }

    /// Moves one exact message (by UID) to another folder after binding the
    /// source folder's UIDVALIDITY. No global expunge and no permanent
    /// delete: a server without UIDPLUS/MOVE keeps the message visibly
    /// flagged \Deleted instead of expunging unrelated mail. Any connection
    /// loss after a mutating command throws `mutationUnknown` so callers
    /// reconcile before retrying.
    public func move(
        account: MailAccount,
        password: String,
        requestID: UUID,
        uid: String,
        folder: String,
        destination: String,
        mailboxVersion: String,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailMoveOutcome {
        try account.validate()
        guard account.incomingProtocol == .imap else { throw MailFailure.unsupportedForPOP3 }
        guard let numericUID = UInt32(uid), numericUID > 0,
              !folder.isEmpty, !destination.isEmpty,
              folder.utf8.count <= 1024, destination.utf8.count <= 1024,
              folder != destination else { throw MailFailure.invalidConfiguration }
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            try session.loginIMAP(server: account.incoming, password: password)
            return try Self.performMove(
                session: session,
                requestID: requestID,
                uid: uid,
                numericUID: numericUID,
                folder: folder,
                destination: destination,
                mailboxVersion: mailboxVersion
            )
        }
    }

    /// The complete mutation conversation, separated from transport so mock
    /// sessions exercise the exact commands, capability branching and
    /// unknown-outcome classification.
    static func performMove(
        session: MailProtocolSession,
        requestID: UUID,
        uid: String,
        numericUID: UInt32,
        folder: String,
        destination: String,
        mailboxVersion: String
    ) throws -> MailMoveOutcome {
        let capabilities = try Self.capabilities(session)
        let selected = try session.imap("SELECT \(MailProtocolSession.quoted(folder))")
        guard try Self.uidValidity(selected) == mailboxVersion else { throw MailFailure.mailboxChanged }
        guard try Self.fetchReferences(session, uids: [numericUID]).count == 1 else {
            throw MailFailure.messageNotFound
        }
        // Destination must exist; creating folders is out of scope.
        let listed = try session.imap("LIST \"\" \(MailProtocolSession.quoted(destination))")
        guard listed.lines.contains(where: { $0.uppercased().hasPrefix("* LIST ") }) else {
            throw MailFailure.invalidConfiguration
        }
        var mutationStarted = false
        do {
            let destinationUID: String?
            let expunged: String
            if capabilities.contains("MOVE") {
                mutationStarted = true
                let moved = try session.imap("UID MOVE \(numericUID) \(MailProtocolSession.quoted(destination))")
                destinationUID = Self.copyUID(moved, sourceUID: numericUID)
                // Atomic MOVE removes the source message; verify that.
                if try Self.fetchReferences(session, uids: [numericUID]).count == 1 {
                    throw MailFailure.mailboxChanged
                }
                expunged = "targeted"
            } else {
                mutationStarted = true
                let copied = try session.imap("UID COPY \(numericUID) \(MailProtocolSession.quoted(destination))")
                destinationUID = Self.copyUID(copied, sourceUID: numericUID)
                _ = try session.imap("UID STORE \(numericUID) +FLAGS.SILENT (\\Deleted)")
                let flags = try Self.fetchReferences(session, uids: [numericUID])
                guard flags.count == 1,
                      flags[0].flags.contains(where: { $0.caseInsensitiveCompare("\\Deleted") == .orderedSame }) else {
                    throw MailFailure.mailboxChanged
                }
                if capabilities.contains("UIDPLUS") {
                    _ = try session.imap("UID EXPUNGE \(numericUID)")
                    if try Self.fetchReferences(session, uids: [numericUID]).count == 1 {
                        throw MailFailure.mailboxChanged
                    }
                    expunged = "targeted"
                } else {
                    // No targeted expunge available: never issue a global
                    // EXPUNGE (it would commit unrelated deletions).
                    expunged = "notSupported"
                }
            }
            var destinationVersion: String?
            var destinationVerified = false
            if let destinationUID, let destinationNumeric = UInt32(destinationUID) {
                let destSelected = try session.imap("EXAMINE \(MailProtocolSession.quoted(destination))")
                destinationVersion = try? Self.uidValidity(destSelected)
                destinationVerified = try Self.fetchReferences(
                    session,
                    uids: [destinationNumeric]
                ).count == 1
            } else if let destinationVersionCandidate = try? Self.uidValidity(
                session.imap("EXAMINE \(MailProtocolSession.quoted(destination))")
            ) {
                // No UIDPLUS mapping: confirm the destination mailbox and
                // report the copy as unverified rather than guessing.
                destinationVersion = destinationVersionCandidate
                destinationVerified = false
            }
            return MailMoveOutcome(
                requestID: requestID,
                uid: uid,
                sourceFolder: folder,
                destination: destination,
                mailboxVersion: mailboxVersion,
                destinationUID: destinationUID,
                destinationMailboxVersion: destinationVersion,
                expunged: expunged,
                destinationVerified: destinationVerified
            )
        } catch let error as MailFailure {
            // A server NO/unsupported reply means the command definitively
            // did not complete. Transport loss after a mutating write is
            // unknown state and must never be retried automatically.
            if mutationStarted,
               error == .connectionFailed || error == .timedOut
                || error == .responseTooLarge || error == .cancelled {
                throw MailFailure.mutationUnknown
            }
            throw error
        } catch {
            if mutationStarted { throw MailFailure.mutationUnknown }
            throw error
        }
    }

    /// Reads one message's stable identity (Message-ID header when present and
    /// RFC822.SIZE) with read-only commands. Used to persist operation
    /// provenance BEFORE a mutation so an ambiguous outcome can later be
    /// reconciled without repeating COPY/MOVE/DELETE.
    public func messageIdentity(
        account: MailAccount,
        password: String,
        folder: String,
        uid: String,
        mailboxVersion: String,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailMessageIdentity {
        try account.validate()
        guard account.incomingProtocol == .imap,
              let numericUID = UInt32(uid), numericUID > 0,
              !folder.isEmpty, folder.utf8.count <= 1024 else {
            throw MailFailure.invalidConfiguration
        }
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            try session.loginIMAP(server: account.incoming, password: password)
            let selected = try session.imap("EXAMINE \(MailProtocolSession.quoted(folder))")
            guard try Self.uidValidity(selected) == mailboxVersion else {
                throw MailFailure.mailboxChanged
            }
            return try Self.performMessageIdentity(session: session, uid: numericUID)
        }
    }

    static func performMessageIdentity(
        session: MailProtocolSession,
        uid: UInt32
    ) throws -> MailMessageIdentity {
        let fetched: MailProtocolSession.IMAPReply
        do {
            fetched = try session.imap(
                "UID FETCH \(uid) (UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"
            )
        } catch MailFailure.protocolRejected {
            // Some servers reject HEADER.FIELDS fetches; the size alone still
            // lets reconciliation be explicit, just without a copy proof.
            let sizeOnly = try session.imap("UID FETCH \(uid) (UID RFC822.SIZE)")
            guard let size = Self.sizeFromFetch(sizeOnly, uid: uid) else {
                throw MailFailure.messageNotFound
            }
            return MailMessageIdentity(messageID: nil, byteCount: size)
        }
        guard let size = Self.sizeFromFetch(fetched, uid: uid) else {
            throw MailFailure.messageNotFound
        }
        let header = fetched.literals.first.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return MailMessageIdentity(messageID: Self.messageIDHeader(in: header), byteCount: size)
    }

    /// One bounded, READ-ONLY reconciliation of an ambiguous move: examines the
    /// source flags and searches the destination by the persisted Message-ID
    /// (matching the persisted byte count). Never issues COPY/MOVE/STORE/
    /// EXPUNGE/DELETE.
    ///
    /// Outcomes:
    ///  * `.notSubmitted` — the source is intact (no \Deleted) and no
    ///    destination copy with the same identity exists; the operation may
    ///    proceed exactly once.
    ///  * `.completed(...)` — the destination copy is proven and the source is
    ///    gone or marked \Deleted.
    ///  * `.ambiguous(reason)` — evidence is incomplete (identity missing,
    ///    UIDVALIDITY changed, copy present but source intact); never repeat.
    public func reconcileMove(
        account: MailAccount,
        password: String,
        provenance: MailMutationJournal.Provenance,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailMoveReconciliation {
        try account.validate()
        guard account.incomingProtocol == .imap,
              let numericUID = UInt32(provenance.uid), numericUID > 0,
              !provenance.sourceFolder.isEmpty, !provenance.destination.isEmpty,
              provenance.sourceFolder.utf8.count <= 1024,
              provenance.destination.utf8.count <= 1024 else {
            throw MailFailure.invalidConfiguration
        }
        return try await perform(server: account.incoming, cancelled: cancelled) { session in
            try session.loginIMAP(server: account.incoming, password: password)
            return try Self.performReconcileMove(
                session: session,
                uid: numericUID,
                provenance: provenance
            )
        }
    }

    static func performReconcileMove(
        session: MailProtocolSession,
        uid: UInt32,
        provenance: MailMutationJournal.Provenance
    ) throws -> MailMoveReconciliation {
        let selected = try session.imap("EXAMINE \(MailProtocolSession.quoted(provenance.sourceFolder))")
        let sourceVersion = try Self.uidValidity(selected)
        guard sourceVersion == provenance.mailboxVersion else {
            return .ambiguous(reason: "source mailbox identity changed")
        }
        let source = try Self.fetchReferences(session, uids: [uid])
        let sourcePresent = source.count == 1
        let sourceDeleted = source.first?.flags.contains {
            $0.caseInsensitiveCompare("\\Deleted") == .orderedSame
        } ?? false

        var destinationUID: String?
        var destinationVersion: String?
        if let messageID = provenance.messageID, !messageID.isEmpty {
            let destSelected = try session.imap("EXAMINE \(MailProtocolSession.quoted(provenance.destination))")
            destinationVersion = try? Self.uidValidity(destSelected)
            let search = try session.imap(
                "UID SEARCH HEADER Message-ID \(MailProtocolSession.quoted(messageID))"
            )
            var candidateIDs: [UInt32] = []
            for line in search.lines where line.uppercased().hasPrefix("* SEARCH") {
                for token in line.split(separator: " ").dropFirst(2) {
                    if let value = UInt32(token), value > 0 { candidateIDs.append(value) }
                }
            }
            if !candidateIDs.isEmpty {
                let references = try Self.fetchReferences(session, uids: candidateIDs)
                destinationUID = references.first {
                    $0.byteCount == provenance.byteCount
                }?.id
            }
        }
        let copyProven = destinationUID != nil

        if !sourcePresent {
            guard copyProven else {
                return .ambiguous(reason: "source message is gone but no destination copy was proven")
            }
            return .completed(destinationUID: destinationUID, destinationMailboxVersion: destinationVersion)
        }
        if sourceDeleted {
            guard copyProven else {
                return .ambiguous(reason: "source message is marked deleted but no destination copy was proven")
            }
            return .completed(destinationUID: destinationUID, destinationMailboxVersion: destinationVersion)
        }
        if copyProven {
            // COPY applied but the source was never marked deleted: the move
            // is incomplete. Explicitly ambiguous, never repeated.
            return .ambiguous(reason: "destination copy exists but the source is not marked deleted")
        }
        guard provenance.messageID?.isEmpty == false else {
            // Without a stable identity a missing destination copy cannot be
            // proven; never guess and never repeat.
            return .ambiguous(reason: "no stable message identity was recorded")
        }
        return .notSubmitted
    }

    /// RFC822.SIZE of the requested UID from a FETCH reply, or nil when the
    /// reply does not contain that UID.
    static func sizeFromFetch(_ reply: MailProtocolSession.IMAPReply, uid: UInt32) -> Int? {
        for line in reply.lines where line.contains(" FETCH ") {
            guard matches(#"\bUID (\d+)"#, line).first?.first == String(uid),
                  let sizeText = matches(#"RFC822\.SIZE (\d+)"#, line).first?.first,
                  let size = Int(sizeText) else { continue }
            return size
        }
        return nil
    }

    /// Bounded Message-ID header value: single line, <= 512 characters, no
    /// control characters, angle brackets stripped.
    static func messageIDHeader(in header: String) -> String? {
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let range = line.range(of: "message-id:", options: [.caseInsensitive, .anchored]) else {
                continue
            }
            var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<") { value.removeFirst() }
            if value.hasSuffix(">") { value.removeLast() }
            guard !value.isEmpty, value.count <= 512,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        return nil
    }

    /// Parses `[COPYUID <uidvalidity> <source-set> <destination-set>]`.
    static func copyUID(_ reply: MailProtocolSession.IMAPReply, sourceUID: UInt32) -> String? {
        let text = reply.lines.joined(separator: "\n")
        guard let match = matches(#"\[COPYUID (\d+) (\d+(?:,\d+)*) (\d+(?:,\d+)*)\]"#, text).first,
              match.count == 3 else { return nil }
        let sources = match[1].split(separator: ",").compactMap { UInt32($0) }
        let destinations = match[2].split(separator: ",").compactMap { UInt32($0) }
        guard let index = sources.firstIndex(of: sourceUID), destinations.indices.contains(index) else {
            return nil
        }
        return String(destinations[index])
    }

    static func capabilities(_ session: MailProtocolSession) throws -> Set<String> {
        let reply = try session.imap("CAPABILITY")
        return Set(
            reply.lines
                .filter { $0.uppercased().hasPrefix("* CAPABILITY") }
                .flatMap { $0.split(separator: " ").dropFirst(2) }
                .map { String($0).uppercased() }
        )
    }

    static func fetchReferences(
        _ session: MailProtocolSession,
        uids: [UInt32]
    ) throws -> [MailMessageReference] {
        guard !uids.isEmpty else { return [] }
        let fetched = try session.imap(
            "UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID RFC822.SIZE FLAGS)"
        )
        var entries: [MailMessageReference] = []
        for line in fetched.lines where line.contains(" FETCH ") {
            guard let uid = matches(#"\bUID (\d+)"#, line).first?.first,
                  let sizeText = matches(#"RFC822\.SIZE (\d+)"#, line).first?.first,
                  let size = Int(sizeText) else { throw MailFailure.protocolRejected }
            let flags = matches(#"FLAGS \(([^)]*)\)"#, line).first?.first?.split(separator: " ").map(String.init) ?? []
            entries.append(MailMessageReference(id: uid, byteCount: size, flags: flags))
        }
        // Preserve the requested order for callers that page descending UIDs.
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uids.compactMap { byID[String($0)] }
    }

    /// Builds the UID SEARCH command. Non-ASCII criteria request CHARSET
    /// UTF-8 (RFC 6855 servers); ASCII-only criteria stay on the plain form
    /// for maximum compatibility. Quoted values reject control characters.
    static func searchCommand(_ criteria: MailSearchCriteria) throws -> String {
        var parts: [String] = []
        var needsUTF8 = false
        func appendQuoted(_ keyword: String, _ raw: String?) throws {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard trimmed.utf8.count <= 256 else { throw MailFailure.invalidConfiguration }
            if !trimmed.unicodeScalars.allSatisfy(\.isASCII) { needsUTF8 = true }
            parts.append("\(keyword) \(try MailProtocolSession.quoted(trimmed))")
        }
        try appendQuoted("FROM", criteria.from)
        try appendQuoted("TO", criteria.to)
        try appendQuoted("SUBJECT", criteria.subject)
        try appendQuoted("TEXT", criteria.text)
        if let seen = criteria.seen { parts.append(seen ? "SEEN" : "UNSEEN") }
        if let flagged = criteria.flagged { parts.append(flagged ? "FLAGGED" : "UNFLAGGED") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy"
        if let since = criteria.since { parts.append("SINCE \(formatter.string(from: since))") }
        if let until = criteria.until { parts.append("BEFORE \(formatter.string(from: until))") }
        guard !parts.isEmpty else { throw MailFailure.invalidConfiguration }
        let charset = needsUTF8 ? " CHARSET UTF-8" : ""
        return "UID SEARCH\(charset) " + parts.joined(separator: " ")
    }

    struct SearchCursor: Codable, Sendable {
        var v: Int
        var accountID: UUID
        var folder: String
        var mailboxVersion: String
        var uid: UInt32
        /// Canonical SEARCH command the page was produced with.
        var criteriaKey: String
    }

    static func encodeSearchCursor(_ cursor: SearchCursor) -> String {
        guard let data = try? JSONEncoder().encode(cursor) else { return "" }
        return "msc1." + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeSearchCursor(_ token: String) throws -> SearchCursor {
        guard token.hasPrefix("msc1.") else { throw MailFailure.invalidConfiguration }
        var text = String(token.dropFirst("msc1.".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let cursor = try? JSONDecoder().decode(SearchCursor.self, from: data),
              cursor.v == 1 else { throw MailFailure.invalidConfiguration }
        return cursor
    }

    /// Canonical criteria command used for cursor binding. Public so the tool
    /// layer hands the exact same key to the bounded page serializer.
    public static func canonicalSearchCriteriaKey(_ criteria: MailSearchCriteria) throws -> String {
        try searchCommand(criteria)
    }

    /// Bounded, valid JSON for the tool boundary. The runtime prefixes tool
    /// summaries to 4096 characters without a JSON-aware marker, so this
    /// serializer emits newest-first rows only while the serialized page keeps
    /// the budget. When rows are withheld the continuation cursor is
    /// recomputed from the LAST EMITTED UID (never the client's original
    /// cursor), so no UID is skipped; `returned`/`available`/`pageTruncated`
    /// state the truncation honestly. Per-row flags are bounded as well.
    public static func boundedSearchPageJSON(
        page: MailSearchPage,
        accountID: UUID,
        folder: String,
        criteriaKey: String,
        maximumCharacters: Int = 4_096
    ) -> String {
        func row(_ message: MailMessageReference) -> [String: Any] {
            var entry: [String: Any] = [
                "id": String(message.id.prefix(70)),
                "byteCount": message.byteCount,
                "flags": Array(message.flags.prefix(8)).map { String($0.prefix(24)) }
            ]
            if message.flags.count > 8 { entry["flagsTruncated"] = true }
            return entry
        }
        func payload(
            rows: [MailMessageReference],
            trimmed: Bool,
            cursor: String?,
            hasMore: Bool
        ) -> [String: Any] {
            [
                "folder": page.folder,
                "mailboxVersion": page.mailboxVersion,
                "messages": rows.map(row),
                "hasMore": hasMore,
                "nextCursor": cursor ?? "",
                "totalMatched": page.totalMatched,
                "returned": rows.count,
                "available": page.messages.count,
                "pageTruncated": trimmed
            ]
        }
        func serialize(_ value: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }

        let available = page.messages.count
        var count = available
        while count >= 1 {
            let rows = Array(page.messages.prefix(count))
            let trimmed = count < available
            var cursor = page.nextCursor
            var hasMore = page.hasMore
            if trimmed {
                if let lastUID = UInt32(rows[count - 1].id) {
                    cursor = encodeSearchCursor(SearchCursor(
                        v: 1,
                        accountID: accountID,
                        folder: folder,
                        mailboxVersion: page.mailboxVersion,
                        uid: lastUID,
                        criteriaKey: criteriaKey
                    ))
                    hasMore = true
                } else {
                    // Without a numeric UID no safe continuation exists; the
                    // page states the stop instead of guessing a position.
                    cursor = nil
                    hasMore = false
                }
            }
            let text = serialize(payload(rows: rows, trimmed: trimmed, cursor: cursor, hasMore: hasMore))
            if text.count <= maximumCharacters { return text }
            count -= 1
        }
        if available == 0 {
            return serialize(payload(
                rows: [],
                trimmed: false,
                cursor: page.nextCursor,
                hasMore: page.hasMore
            ))
        }
        // Even one bounded row cannot fit (extremely small budget): emit a
        // valid explicit error page, never truncated JSON.
        return serialize([
            "folder": page.folder,
            "mailboxVersion": page.mailboxVersion,
            "messages": [],
            "hasMore": false,
            "nextCursor": "",
            "totalMatched": page.totalMatched,
            "returned": 0,
            "available": available,
            "pageTruncated": true,
            "error": "pageRowExceedsBudget"
        ])
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
