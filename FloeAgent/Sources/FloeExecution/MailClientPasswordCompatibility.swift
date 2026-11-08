import Foundation

/// Existing password API delegates to the same implementation, never treats a bearer as a password.
extension MailClient {
    public func test(server: MailServer, protocolName: String, password: String) async throws {
        try await test(server: server, protocolName: protocolName, credential: .password(password))
    }

    public func folders(account: MailAccount, password: String, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> [String] {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await folders(account: account, credential: .password(password), cancelled: cancelled)
    }

    public func foldersWithAttributes(account: MailAccount, password: String, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> [MailFolderInfo] {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await foldersWithAttributes(account: account, credential: .password(password), cancelled: cancelled)
    }

    public func list(account: MailAccount, password: String, folder: String = "INBOX", afterUID: UInt32 = 0,
                     limit: Int = 20, beforeMessageID: String? = nil, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MailListing {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await list(account: account, credential: .password(password), folder: folder, afterUID: afterUID, limit: limit, beforeMessageID: beforeMessageID, cancelled: cancelled)
    }

    public func search(
        account: MailAccount,
        password: String,
        folder: String = "INBOX",
        criteria: MailSearchCriteria,
        cursor: String? = nil,
        limit: Int = 20,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailSearchPage {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await search(account: account, credential: .password(password), folder: folder, criteria: criteria, cursor: cursor, limit: limit, cancelled: cancelled)
    }

    public func specialFolder(
        account: MailAccount,
        password: String,
        kind: MailSpecialFolder,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> String? {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await specialFolder(account: account, credential: .password(password), kind: kind, cancelled: cancelled)
    }

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
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await move(account: account, credential: .password(password), requestID: requestID, uid: uid, folder: folder, destination: destination, mailboxVersion: mailboxVersion, cancelled: cancelled)
    }

    public func messageIdentity(
        account: MailAccount,
        password: String,
        folder: String,
        uid: String,
        mailboxVersion: String,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailMessageIdentity {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await messageIdentity(account: account, credential: .password(password), folder: folder, uid: uid, mailboxVersion: mailboxVersion, cancelled: cancelled)
    }

    public func reconcileMove(
        account: MailAccount,
        password: String,
        provenance: MailMutationJournal.Provenance,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MailMoveReconciliation {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await reconcileMove(account: account, credential: .password(password), provenance: provenance, cancelled: cancelled)
    }

    public func message(account: MailAccount, password: String, id: String, folder: String = "INBOX", mailboxVersion: String?,
                        cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Data {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        return try await message(account: account, credential: .password(password), id: id, folder: folder, mailboxVersion: mailboxVersion, cancelled: cancelled)
    }

    public func setRead(account: MailAccount, password: String, id: String, folder: String, mailboxVersion: String, read: Bool,
                        cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        try await setRead(account: account, credential: .password(password), id: id, folder: folder, mailboxVersion: mailboxVersion, read: read, cancelled: cancelled)
    }

    public func send(account: MailAccount, password: String, draft: MailDraft, messageID: UUID,
                     cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        try await send(account: account, credential: .password(password), draft: draft, messageID: messageID, cancelled: cancelled)
    }
}
