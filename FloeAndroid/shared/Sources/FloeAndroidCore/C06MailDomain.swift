// SPDX-License-Identifier: MPL-2.0
//
// C06 — real generic IMAP/POP3 + SMTP mail authority for Android.
//
// This file owns only the trusted host channel / model-tool composition:
// account rows, approved credential gateway access, owned journal/staging
// directories and the exact mail operations. Protocol framing, MIME, body
// paging and no-replay receipts are the bounded `FloeAndroidMail` module.
//
// Security boundaries:
//   * an account stores non-secret settings plus two credential *references*;
//     passwords live only in `SecretGatewayRegistry`;
//   * every call is fenced by the accepted native Root epoch and an opaque
//     App-controller/tool owner token;
//   * the platform transport lane is explicit: an unbind lane is a typed
//     failure and never a plaintext fallback;
//   * staged attachments/drafts live under the accepted owned root, are
//     bounded, and are removed on close/RootStop;
//   * email and attachment content is untrusted data. It never authorizes a
//     tool and is never rendered as HTML.

import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAndroidMail

// MARK: - Bounds

public enum C06MailWire {
    public static let version = 12
    public static let schema = "floe.mail/12"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 49_152
    public static let maximumAccounts = 20
    public static let maximumMessageBytes = 16_000_000
    public static let maximumAttachmentBytes = 10_000_000
    public static let maximumAttachmentsPerMessage = 10
    public static let maximumDraftAttachments = 10
    public static let maximumLiveAttachmentHandles = 4
    public static let maximumLiveDraftHandles = 10
    public static let maximumChunkBytes = 24_576
    public static let maximumBodyPageCharacters = 24_000
    public static let maximumSearchPageCharacters = 40_000
    public static let modelBodyPageCharacters = 4_000
    public static let modelSearchPageCharacters = 4_096
    public static let attachmentHandleLifetime: TimeInterval = 600
    public static let draftHandleLifetime: TimeInterval = 1_800
    public static let operationTimeout: TimeInterval = 60
    public static let modelTools = true
}

// MARK: - Owner / errors

public struct C06MailOwner: Sendable, Equatable {
    public let token: String
    public let nativeEpoch: UInt64
    public let taskID: UUID?
    public let temporary: Bool

    public init(token: String, nativeEpoch: UInt64, taskID: UUID? = nil, temporary: Bool = false) {
        self.token = token
        self.nativeEpoch = nativeEpoch
        self.taskID = taskID
        self.temporary = temporary
    }

    public func validate() throws {
        guard (8...128).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({
                  $0.value < 128
                      && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C06MailError(.invalidOwner, "invalidOwnerToken")
        }
        guard nativeEpoch > 0 else {
            throw C06MailError(.invalidOwner, "invalidNativeEpoch")
        }
        if temporary {
            // Mail is private account data, not a public-web retrieval.
            // Temporary chat is text-only/public-web and must not reach it.
            throw C06MailError(.invalidOwner, "temporaryOwnerCannotUseMail")
        }
    }
}

public enum C06MailErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case unsupportedOperation
    case responseTooLarge
    case invalidOwner
    case invalidAccount
    case accountNotFound
    case accountLimit
    case credentialMissing
    case credentialInvalid
    case gatewayUnavailable
    case storageUnavailable
    case transportUnavailable
    case authenticationFailed
    case connectionRefused
    case hostNotFound
    case timedOut
    case networkUnreachable
    case transportFailed
    case tlsFailed
    case protocolRejected
    case messageNotFound
    case mailboxChanged
    case unsupportedForPOP3
    case deliveryUnknown
    case mutationUnknown
    case cursorMismatch
    case attachmentNotFound
    case attachmentTooLarge
    case draftNotFound
    case draftIncomplete
    case cancelled
    case busy
    case localNetworkPermissionRequired
    case cleanupIncomplete
    case internalFailure
}

public struct C06MailError: Error, Sendable, Equatable {
    public let code: C06MailErrorCode
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let stage: String?

    public init(
        _ code: C06MailErrorCode,
        _ reason: String? = nil,
        retryable: Bool = false,
        detail: String? = nil,
        stage: String? = nil
    ) {
        self.code = code
        self.reason = String((reason ?? code.rawValue).prefix(120))
        self.retryable = retryable
        self.detail = detail.map { String(SecretRedactor.redact($0).prefix(240)) }
        self.stage = stage.map { String($0.prefix(32)) }
    }
}

// MARK: - Value surface

public struct C06MailAccountSummary: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let address: String
    public let incomingProtocol: MailIncomingProtocol
    public let incoming: MailServer
    public let outgoing: MailServer
    public let revision: Int
    public let updatedAt: Date
}

public struct C06MailAccountDraft: Sendable, Equatable {
    public var id: UUID?
    public var displayName: String
    public var address: String
    public var incomingProtocol: MailIncomingProtocol
    public var incoming: MailServer
    public var outgoing: MailServer
    public var incomingSecret: Data?
    public var outgoingSecret: Data?

    public init(
        id: UUID? = nil,
        displayName: String = "",
        address: String = "",
        incomingProtocol: MailIncomingProtocol = .imap,
        incoming: MailServer = .init(port: 993),
        outgoing: MailServer = .init(port: 465),
        incomingSecret: Data? = nil,
        outgoingSecret: Data? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.incomingProtocol = incomingProtocol
        self.incoming = incoming
        self.outgoing = outgoing
        self.incomingSecret = incomingSecret
        self.outgoingSecret = outgoingSecret
    }

    public var account: MailAccount {
        MailAccount(
            id: id ?? UUID(),
            address: address,
            incomingProtocol: incomingProtocol,
            incoming: incoming,
            outgoing: outgoing
        )
    }
}

public struct C06MailTestReport: Sendable, Equatable {
    public let incoming: String
    public let outgoing: String
}

public enum C06MailMoveStatus: String, Sendable, Equatable {
    case completed
    case notStarted
    case mutationUnknown
    case unsupported
}

public struct C06MailMoveResult: Sendable, Equatable {
    public let status: C06MailMoveStatus
    public let requestID: UUID
    public let messageID: String
    public let sourceFolder: String
    public let destination: String?
    public let destinationUID: String?
    public let destinationMailboxVersion: String?
    public let expunged: String?
    public let destinationVerified: Bool
    public let replayed: Bool
    public let reconciled: Bool
    public let receiptPersisted: Bool
    public let reason: String?
    public let warning: String?
}

public enum C06MailSendStatus: String, Sendable, Equatable {
    case acceptedByServer
    case deliveryUnknown
    case deliveryUnknownReplay
    case notSubmitted
}

public struct C06MailSendResult: Sendable, Equatable {
    public let status: C06MailSendStatus
    public let requestID: UUID
    public let replayed: Bool
    public let receiptPersisted: Bool
    public let warning: String?
}

public struct C06MailAttachmentHandle: Sendable, Equatable {
    public let handle: String
    public let filename: String
    public let byteCount: Int
    public let sha256: String
}

public struct C06MailDraftHandle: Sendable, Equatable {
    public let handle: String
    public let filename: String
    public let byteCount: Int
    public let sha256: String
}

public struct C06MailCancelReport: Sendable, Equatable {
    public let cancelledOperations: Int
    public let complete: Bool
}

public struct C06MailRootStopReport: Sendable, Equatable {
    public let drained: Bool
    public let cancelledOperations: Int
    public let removedAttachmentHandles: Int
    public let removedDraftHandles: Int
}

public struct C06MailCapabilities: Sendable, Equatable {
    public let coreReady: Bool
    public let epoch: UInt64?
    public let credentialGatewayReady: Bool
    public let schemaReady: Bool
    public let transportReady: Bool
    public let accountCount: Int
    public let maximumAccounts: Int
    public let maximumMessageBytes: Int
    public let maximumAttachmentBytes: Int
    public let maximumChunkBytes: Int
    public let modelTools: Bool
}

// MARK: - Availability mirror (sync for tool discovery)

public final class C06MailAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    private var accounts = 0
    private var epoch: UInt64?

    public init() {}

    public func update(available: Bool, accounts: Int, epoch: UInt64?) {
        lock.lock()
        self.available = available
        self.accounts = accounts
        self.epoch = epoch
        lock.unlock()
    }

    public var snapshot: (available: Bool, accounts: Int, epoch: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        return (available, accounts, epoch)
    }
}

// MARK: - Schema

public enum C06MailSchema {
    /// Registered by Main as the ONE next additive Android position (v51).
    /// The store never creates schema implicitly; an unmigrated App reports
    /// `storageUnavailable` instead of writing a partial table.
    public static let requiredVersion = 51
    public static let table = "mail_accounts"

    public static let createTableSQL = """
        CREATE TABLE IF NOT EXISTS mail_accounts (
            id TEXT PRIMARY KEY NOT NULL,
            address TEXT NOT NULL,
            display_name TEXT NOT NULL,
            incoming_protocol TEXT NOT NULL,
            incoming_host TEXT NOT NULL,
            incoming_port INTEGER NOT NULL,
            incoming_tls TEXT NOT NULL,
            incoming_username TEXT NOT NULL,
            incoming_credential_account TEXT NOT NULL,
            outgoing_host TEXT NOT NULL,
            outgoing_port INTEGER NOT NULL,
            outgoing_tls TEXT NOT NULL,
            outgoing_username TEXT NOT NULL,
            outgoing_credential_account TEXT NOT NULL,
            revision INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """

    public static let createIndexSQL = """
        CREATE INDEX IF NOT EXISTS mail_accounts_updated_at
        ON mail_accounts(updated_at)
        """

    public static let statements = [createTableSQL, createIndexSQL]
}

public struct C06MailAccountRecord: Sendable, Equatable {
    public var account: MailAccount
    public var displayName: String
    public var incomingCredentialAccount: String
    public var outgoingCredentialAccount: String
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        account: MailAccount,
        displayName: String,
        incomingCredentialAccount: String,
        outgoingCredentialAccount: String,
        revision: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.account = account
        self.displayName = displayName
        self.incomingCredentialAccount = incomingCredentialAccount
        self.outgoingCredentialAccount = outgoingCredentialAccount
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var summary: C06MailAccountSummary {
        C06MailAccountSummary(
            id: account.id,
            displayName: displayName,
            address: account.address,
            incomingProtocol: account.incomingProtocol,
            incoming: account.incoming,
            outgoing: account.outgoing,
            revision: revision,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Store

public protocol C06MailAccountStoring: Sendable {
    func schemaReady() async throws -> Bool
    func accounts() async throws -> [C06MailAccountRecord]
    func account(id: UUID) async throws -> C06MailAccountRecord?
    func save(_ record: C06MailAccountRecord) async throws
    func delete(id: UUID) async throws
}

public actor C06MailAccountStore: C06MailAccountStoring {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func schemaReady() async throws -> Bool {
        try await database.reader { db in
            try db.tableExists(C06MailSchema.table)
        }
    }

    public func accounts() async throws -> [C06MailAccountRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM mail_accounts ORDER BY display_name, id"
            ).map(Self.decode)
        }
    }

    public func account(id: UUID) async throws -> C06MailAccountRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM mail_accounts WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func save(_ record: C06MailAccountRecord) async throws {
        let formatter = ISO8601DateFormatter()
        let createdAt = formatter.string(from: record.createdAt)
        let updatedAt = formatter.string(from: record.updatedAt)
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO mail_accounts (
                        id, address, display_name, incoming_protocol,
                        incoming_host, incoming_port, incoming_tls, incoming_username,
                        incoming_credential_account,
                        outgoing_host, outgoing_port, outgoing_tls, outgoing_username,
                        outgoing_credential_account, revision, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        address = excluded.address,
                        display_name = excluded.display_name,
                        incoming_protocol = excluded.incoming_protocol,
                        incoming_host = excluded.incoming_host,
                        incoming_port = excluded.incoming_port,
                        incoming_tls = excluded.incoming_tls,
                        incoming_username = excluded.incoming_username,
                        incoming_credential_account = excluded.incoming_credential_account,
                        outgoing_host = excluded.outgoing_host,
                        outgoing_port = excluded.outgoing_port,
                        outgoing_tls = excluded.outgoing_tls,
                        outgoing_username = excluded.outgoing_username,
                        outgoing_credential_account = excluded.outgoing_credential_account,
                        revision = excluded.revision,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    record.account.id.uuidString,
                    record.account.address,
                    record.displayName,
                    record.account.incomingProtocol.rawValue,
                    record.account.incoming.host,
                    record.account.incoming.port,
                    record.account.incoming.tls.rawValue,
                    record.account.incoming.username,
                    record.incomingCredentialAccount,
                    record.account.outgoing.host,
                    record.account.outgoing.port,
                    record.account.outgoing.tls.rawValue,
                    record.account.outgoing.username,
                    record.outgoingCredentialAccount,
                    record.revision,
                    createdAt,
                    updatedAt,
                ]
            )
        }
    }

    public func delete(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM mail_accounts WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    private static func decode(_ row: Row) throws -> C06MailAccountRecord {
        guard let id = UUID(uuidString: row["id"]),
              let protocolValue = MailIncomingProtocol(rawValue: row["incoming_protocol"]),
              let incomingTLS = MailTLSMode(rawValue: row["incoming_tls"]),
              let outgoingTLS = MailTLSMode(rawValue: row["outgoing_tls"]),
              let createdAt = ISO8601DateFormatter().date(from: row["created_at"]),
              let updatedAt = ISO8601DateFormatter().date(from: row["updated_at"]) else {
            throw C06MailError(.storageUnavailable, "corruptMailAccountRow")
        }
        let account = MailAccount(
            id: id,
            address: row["address"],
            incomingProtocol: protocolValue,
            incoming: MailServer(
                host: row["incoming_host"],
                port: row["incoming_port"],
                tls: incomingTLS,
                username: row["incoming_username"]
            ),
            outgoing: MailServer(
                host: row["outgoing_host"],
                port: row["outgoing_port"],
                tls: outgoingTLS,
                username: row["outgoing_username"]
            )
        )
        return C06MailAccountRecord(
            account: account,
            displayName: row["display_name"],
            incomingCredentialAccount: row["incoming_credential_account"],
            outgoingCredentialAccount: row["outgoing_credential_account"],
            revision: row["revision"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Production wiring

enum C06MailProductionWiring {
    static func readiness() -> (ready: Bool, epoch: UInt64?) {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            return (false, nil)
        }
        return (true, composition.epoch)
    }

    static func store(epoch: UInt64) throws -> C06MailAccountStore {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C06MailError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C06MailError(.staleEpoch, "staleNativeEpoch")
        }
        return C06MailAccountStore(database: composition.cluster.database)
    }

    static func ownedRoot(epoch: UInt64) throws -> URL {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C06MailError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C06MailError(.staleEpoch, "staleNativeEpoch")
        }
        return composition.cluster.identity.root.artifactStoreURL
    }

    static func credentialRead(_ opaque: String) async throws -> Data? {
        guard SecretGatewayRegistry.shared.isRegistered else {
            throw C06MailError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        return try await SecretGatewayRegistry.shared.read(reference: opaque)
    }

    static func credentialWrite(_ opaque: String, _ value: Data) async throws {
        guard SecretGatewayRegistry.shared.isRegistered else {
            throw C06MailError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        try await SecretGatewayRegistry.shared.write(reference: opaque, value: value)
    }

    static func credentialDelete(_ opaque: String) async throws {
        guard SecretGatewayRegistry.shared.isRegistered else {
            throw C06MailError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        try await SecretGatewayRegistry.shared.delete(reference: opaque)
    }

    static func transportReady(epoch: UInt64) -> Bool {
        let mailbox = MailTransportMailbox.shared
        return mailbox.isReady && mailbox.epoch == epoch
    }
}

// MARK: - Staged transfer values

private struct C06StagedAttachment {
    let handle: String
    let filename: String
    let byteCount: Int
    let sha256: String
    let url: URL
    let createdAt: Date
    var lastAccess: Date

    var info: C06MailAttachmentHandle {
        C06MailAttachmentHandle(
            handle: handle,
            filename: filename,
            byteCount: byteCount,
            sha256: sha256
        )
    }
}

private struct C06DraftAttachment {
    let handle: String
    let accountID: UUID
    let filename: String
    let byteCount: Int
    let expectedSHA256: String
    let url: URL
    let directory: URL
    let createdAt: Date
    var written: Int
    var ready: Bool
    var lastAccess: Date

    var info: C06MailDraftHandle {
        C06MailDraftHandle(
            handle: handle,
            filename: filename,
            byteCount: byteCount,
            sha256: expectedSHA256
        )
    }
}

private struct C06MailDestinationUnavailable: Error {
    let action: String
}

// MARK: - Domain

public actor C06MailDomain {
    public static let shared = C06MailDomain(
        storeProvider: { epoch in try C06MailProductionWiring.store(epoch: epoch) },
        transportProvider: { _ in MailClient.shared },
        readiness: { C06MailProductionWiring.readiness() },
        credentialReader: { opaque in try await C06MailProductionWiring.credentialRead(opaque) },
        credentialWriter: { opaque, value in
            try await C06MailProductionWiring.credentialWrite(opaque, value)
        },
        credentialDeleter: { opaque in try await C06MailProductionWiring.credentialDelete(opaque) },
        credentialReady: { SecretGatewayRegistry.shared.isRegistered },
        rootProvider: { epoch in try C06MailProductionWiring.ownedRoot(epoch: epoch) },
        transportReady: { epoch in C06MailProductionWiring.transportReady(epoch: epoch) }
    )

    public static let availability = C06MailAvailability()

    private let storeProvider: @Sendable (UInt64) async throws -> any C06MailAccountStoring
    private let transportProvider: @Sendable (UInt64) throws -> any MailTransporting
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)
    private let credentialReader: @Sendable (String) async throws -> Data?
    private let credentialWriter: @Sendable (String, Data) async throws -> Void
    private let credentialDeleter: @Sendable (String) async throws -> Void
    private let credentialReady: @Sendable () -> Bool
    private let rootProvider: @Sendable (UInt64) throws -> URL
    private let transportReadyCheck: @Sendable (UInt64) -> Bool
    private let closeTransport: @Sendable (TimeInterval) -> Bool
    private let now: @Sendable () -> Date

    private final class OperationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    private struct ActiveOperation {
        let ownerToken: String
        let token: OperationToken
    }

    private var activeOperation: ActiveOperation?
    private var retiredThroughEpoch: UInt64 = 0
    private var attachments: [String: C06StagedAttachment] = [:]
    private var drafts: [String: C06DraftAttachment] = [:]
    private var mutationJournals: [String: MailMutationJournal] = [:]
    private var deliveryJournals: [String: MailDeliveryJournal] = [:]
    private var cachedEpoch: UInt64 = 0

    public init(
        storeProvider: @escaping @Sendable (UInt64) async throws -> any C06MailAccountStoring,
        transportProvider: @escaping @Sendable (UInt64) throws -> any MailTransporting,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?),
        credentialReader: @escaping @Sendable (String) async throws -> Data?,
        credentialWriter: @escaping @Sendable (String, Data) async throws -> Void,
        credentialDeleter: @escaping @Sendable (String) async throws -> Void,
        credentialReady: @escaping @Sendable () -> Bool = { false },
        rootProvider: @escaping @Sendable (UInt64) throws -> URL,
        transportReady: @escaping @Sendable (UInt64) -> Bool = { _ in true },
        closeTransport: @escaping @Sendable (TimeInterval) -> Bool = { timeout in
            MailTransportMailbox.shared.closeAll(timeout: timeout)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeProvider = storeProvider
        self.transportProvider = transportProvider
        self.readiness = readiness
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.credentialDeleter = credentialDeleter
        self.credentialReady = credentialReady
        self.rootProvider = rootProvider
        self.transportReadyCheck = transportReady
        self.closeTransport = closeTransport
        self.now = now
    }

    // MARK: Capabilities

    public func capabilities() async -> C06MailCapabilities {
        let current = readiness()
        var schema = false
        var accounts = 0
        if current.ready, let epoch = current.epoch {
            if let store = try? await storeProvider(epoch) {
                schema = (try? await store.schemaReady()) ?? false
                accounts = ((try? await store.accounts()) ?? []).count
            }
            C06MailDomain.availability.update(
                available: schema && accounts > 0 && transportReadyCheck(epoch),
                accounts: accounts,
                epoch: epoch
            )
        } else {
            C06MailDomain.availability.update(available: false, accounts: 0, epoch: nil)
        }
        return C06MailCapabilities(
            coreReady: current.ready,
            epoch: current.epoch,
            credentialGatewayReady: credentialReady(),
            schemaReady: schema,
            transportReady: current.epoch.map { transportReadyCheck($0) } ?? false,
            accountCount: accounts,
            maximumAccounts: C06MailWire.maximumAccounts,
            maximumMessageBytes: C06MailWire.maximumMessageBytes,
            maximumAttachmentBytes: C06MailWire.maximumAttachmentBytes,
            maximumChunkBytes: C06MailWire.maximumChunkBytes,
            modelTools: C06MailWire.modelTools
        )
    }

    public func refreshAvailability(epoch: UInt64) async {
        guard let store = try? await storeProvider(epoch),
              (try? await store.schemaReady()) == true else {
            C06MailDomain.availability.update(available: false, accounts: 0, epoch: epoch)
            return
        }
        let count = ((try? await store.accounts()) ?? []).count
        C06MailDomain.availability.update(
            available: count > 0 && transportReadyCheck(epoch),
            accounts: count,
            epoch: epoch
        )
    }

    // MARK: Accounts

    public func listAccounts(owner: C06MailOwner) async throws -> [C06MailAccountSummary] {
        let context = try await storeContext(owner)
        let records = try await context.store.accounts()
        C06MailDomain.availability.update(
            available: !records.isEmpty && transportReadyCheck(owner.nativeEpoch),
            accounts: records.count,
            epoch: owner.nativeEpoch
        )
        return records.map(\.summary)
    }

    public func accountDetail(id: UUID, owner: C06MailOwner) async throws -> C06MailAccountSummary {
        let context = try await storeContext(owner)
        guard let record = try await context.store.account(id: id) else {
            throw C06MailError(.accountNotFound, "accountNotFound")
        }
        return record.summary
    }

    public func saveAccount(
        _ draft: C06MailAccountDraft,
        owner: C06MailOwner
    ) async throws -> C06MailAccountSummary {
        let context = try await storeContext(owner)
        try validateDisplayName(draft.displayName)
        let account = draft.account
        do {
            try account.validate()
        } catch {
            throw C06MailError(.invalidAccount, "invalidAccount", detail: error.localizedDescription)
        }
        let existing: C06MailAccountRecord?
        if let id = draft.id {
            existing = try await context.store.account(id: id)
        } else {
            existing = nil
        }
        if existing == nil {
            let count = try await context.store.accounts().count
            guard count < C06MailWire.maximumAccounts else {
                throw C06MailError(.accountLimit, "accountLimitReached")
            }
        }
        let revision = (existing?.revision ?? 0) + 1
        let incomingChanged = existing?.account.incoming != account.incoming
        let outgoingChanged = existing?.account.outgoing != account.outgoing
        let incomingSecret = try validatedSecret(draft.incomingSecret)
        let outgoingSecret = try validatedSecret(draft.outgoingSecret)
        if existing == nil {
            guard incomingSecret != nil, outgoingSecret != nil else {
                throw C06MailError(.credentialMissing, "credentialsRequired")
            }
        } else {
            if incomingChanged && incomingSecret == nil {
                throw C06MailError(.credentialMissing, "incomingCredentialRequired")
            }
            if outgoingChanged && outgoingSecret == nil {
                throw C06MailError(.credentialMissing, "outgoingCredentialRequired")
            }
        }
        let incomingReference = incomingSecret == nil
            ? existing?.incomingCredentialAccount
                ?? Self.credentialAccount(account.id, .incoming, revision)
            : Self.credentialAccount(account.id, .incoming, revision)
        let outgoingReference = outgoingSecret == nil
            ? existing?.outgoingCredentialAccount
                ?? Self.credentialAccount(account.id, .outgoing, revision)
            : Self.credentialAccount(account.id, .outgoing, revision)

        var wroteIncoming = false
        var wroteOutgoing = false
        do {
            if let incomingSecret {
                try await writeSecret(incomingSecret, account: incomingReference)
                wroteIncoming = true
            }
            if let outgoingSecret {
                try await writeSecret(outgoingSecret, account: outgoingReference)
                wroteOutgoing = true
            }
            let timestamp = now()
            let record = C06MailAccountRecord(
                account: account,
                displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                incomingCredentialAccount: incomingReference,
                outgoingCredentialAccount: outgoingReference,
                revision: revision,
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: timestamp
            )
            try await context.store.save(record)
            if let old = existing?.incomingCredentialAccount, old != incomingReference {
                try? await deleteSecret(account: old)
            }
            if let old = existing?.outgoingCredentialAccount, old != outgoingReference {
                try? await deleteSecret(account: old)
            }
            let count = (try? await context.store.accounts().count) ?? 1
            C06MailDomain.availability.update(
                available: transportReadyCheck(owner.nativeEpoch),
                accounts: count,
                epoch: owner.nativeEpoch
            )
            return record.summary
        } catch {
            if wroteIncoming { try? await deleteSecret(account: incomingReference) }
            if wroteOutgoing { try? await deleteSecret(account: outgoingReference) }
            throw mapped(error)
        }
    }

    public func deleteAccount(id: UUID, owner: C06MailOwner) async throws -> Bool {
        let context = try await storeContext(owner)
        guard let record = try await context.store.account(id: id) else {
            throw C06MailError(.accountNotFound, "accountNotFound")
        }
        if let transport = try? transportProvider(owner.nativeEpoch) {
            transport.cancelAll()
            let idle = await waitIdle(transport, timeout: 5)
            guard idle else {
                throw C06MailError(.cleanupIncomplete, "mailOperationStillActive", retryable: true)
            }
        }
        do {
            try await deleteSecret(account: record.incomingCredentialAccount)
            try await deleteSecret(account: record.outgoingCredentialAccount)
        } catch {
            // Keep the row when its secrets could not be removed, so the user
            // can retry rather than leaving unreachable credentials.
            throw mapped(error)
        }
        do {
            try await context.store.delete(id: id)
        } catch {
            throw C06MailError(.storageUnavailable, "accountDeleteFailed", retryable: true)
        }
        let count = (try? await context.store.accounts().count) ?? 0
        C06MailDomain.availability.update(
            available: count > 0 && transportReadyCheck(owner.nativeEpoch),
            accounts: count,
            epoch: owner.nativeEpoch
        )
        return true
    }

    public func testAccount(
        draft: C06MailAccountDraft?,
        accountID: UUID?,
        owner: C06MailOwner
    ) async throws -> C06MailTestReport {
        let context = try await networkContext(owner)
        let account: MailAccount
        let incoming: String
        let outgoing: String
        if let draft {
            try validateDisplayName(draft.displayName)
            account = draft.account
            do { try account.validate() } catch {
                throw C06MailError(.invalidAccount, "invalidAccount", detail: error.localizedDescription)
            }
            let existing: C06MailAccountRecord?
            if let id = draft.id {
                existing = try await context.store.account(id: id)
            } else {
                existing = nil
            }
            if let incomingSecret = try validatedSecret(draft.incomingSecret) {
                incoming = try secretString(incomingSecret)
            } else if let existing, existing.account.incoming == account.incoming {
                incoming = try await password(
                    reference: existing.incomingCredentialAccount,
                    context: context
                )
            } else {
                throw C06MailError(.credentialMissing, "incomingCredentialRequired")
            }
            if let outgoingSecret = try validatedSecret(draft.outgoingSecret) {
                outgoing = try secretString(outgoingSecret)
            } else if let existing, existing.account.outgoing == account.outgoing {
                outgoing = try await password(
                    reference: existing.outgoingCredentialAccount,
                    context: context
                )
            } else {
                throw C06MailError(.credentialMissing, "outgoingCredentialRequired")
            }
        } else if let accountID {
            guard let record = try await context.store.account(id: accountID) else {
                throw C06MailError(.accountNotFound, "accountNotFound")
            }
            account = record.account
            incoming = try await password(reference: record.incomingCredentialAccount, context: context)
            outgoing = try await password(reference: record.outgoingCredentialAccount, context: context)
        } else {
            throw C06MailError(.invalidRequest, "accountOrDraftRequired")
        }
        do {
            try await context.transport.test(
                server: account.incoming,
                protocolName: account.incomingProtocol.rawValue,
                password: incoming
            )
        } catch {
            throw mapped(error, stage: "incoming")
        }
        do {
            try await context.transport.test(
                server: account.outgoing,
                protocolName: "smtp",
                password: outgoing
            )
        } catch {
            throw mapped(error, stage: "outgoing")
        }
        return C06MailTestReport(incoming: "authenticated", outgoing: "authenticated")
    }

    // MARK: Read operations

    public func folders(accountID: UUID, owner: C06MailOwner) async throws -> [MailFolderInfo] {
        let context = try await authorized(accountID: accountID, owner: owner)
        return try await withOperation(owner) { cancel in
            do {
                let folders = try await context.transport.foldersWithAttributes(
                    account: context.record.account,
                    password: context.incomingPassword,
                    cancelled: cancel
                )
                return Array(folders.prefix(512))
            } catch { throw Self.mapped(error) }
        }
    }

    public func list(
        accountID: UUID,
        folder: String,
        afterUID: UInt32,
        limit: Int,
        beforeMessageID: String?,
        owner: C06MailOwner
    ) async throws -> MailListing {
        let context = try await authorized(accountID: accountID, owner: owner)
        guard (1...50).contains(limit), folder.utf8.count <= 1024 else {
            throw C06MailError(.invalidRequest, "invalidPagingArguments")
        }
        return try await withOperation(owner) { cancel in
            do {
                return try await context.transport.list(
                    account: context.record.account,
                    password: context.incomingPassword,
                    folder: folder,
                    afterUID: afterUID,
                    limit: limit,
                    beforeMessageID: beforeMessageID,
                    cancelled: cancel
                )
            } catch { throw Self.mapped(error) }
        }
    }

    public func search(
        accountID: UUID,
        folder: String,
        criteria: MailSearchCriteria,
        cursor: String?,
        limit: Int,
        maximumCharacters: Int = C06MailWire.maximumSearchPageCharacters,
        owner: C06MailOwner
    ) async throws -> String {
        let context = try await authorized(accountID: accountID, owner: owner)
        guard !criteria.isEmpty, (1...50).contains(limit),
              folder.utf8.count <= 1024,
              cursor.map({ !$0.isEmpty }) ?? true else {
            throw C06MailError(.invalidRequest, "invalidSearchArguments")
        }
        return try await withOperation(owner) { cancel in
            do {
                let page = try await context.transport.search(
                    account: context.record.account,
                    password: context.incomingPassword,
                    folder: folder,
                    criteria: criteria,
                    cursor: cursor,
                    limit: limit,
                    cancelled: cancel
                )
                let key = try MailClient.canonicalSearchCriteriaKey(criteria)
                return MailClient.boundedSearchPageJSON(
                    page: page,
                    accountID: context.record.account.id,
                    folder: folder,
                    criteriaKey: key,
                    maximumCharacters: maximumCharacters
                )
            } catch { throw Self.mapped(error) }
        }
    }

    public func messagePage(
        accountID: UUID,
        folder: String,
        messageID: String,
        mailboxVersion: String?,
        bodyCursor: String?,
        maximumCharacters: Int = C06MailWire.maximumBodyPageCharacters,
        owner: C06MailOwner
    ) async throws -> String {
        let context = try await authorized(accountID: accountID, owner: owner)
        guard !folder.isEmpty, folder.utf8.count <= 1024,
              messageID.utf8.count <= 70,
              bodyCursor.map({ !$0.isEmpty }) ?? true else {
            throw C06MailError(.invalidRequest, "invalidMessageArguments")
        }
        return try await withOperation(owner) { cancel in
            do {
                let data = try await context.transport.message(
                    account: context.record.account,
                    password: context.incomingPassword,
                    id: messageID,
                    folder: folder,
                    mailboxVersion: mailboxVersion,
                    cancelled: cancel
                )
                let message = try MailMIME.decode(data)
                let binding = MailBodyPaging.Binding(
                    accountID: context.record.account.id,
                    folder: folder,
                    uid: messageID,
                    snapshotSHA256: FloeDigest.sha256Hex(data)
                )
                if let bodyCursor {
                    return try MailBodyPaging.continuationPageJSON(
                        cursorToken: bodyCursor,
                        binding: binding,
                        text: message.text,
                        html: message.html,
                        maximumCharacters: maximumCharacters
                    )
                }
                let rows = message.attachments.enumerated().map { index, attachment in
                    MailBodyPaging.Attachment(
                        index: index,
                        filename: attachment.filename,
                        byteCount: attachment.data.count,
                        sha256: FloeDigest.sha256Hex(attachment.data)
                    )
                }
                return try MailBodyPaging.initialPageJSON(
                    binding: binding,
                    subject: message.subject,
                    from: message.from,
                    to: message.to,
                    date: message.date,
                    text: message.text,
                    html: message.html,
                    attachments: rows,
                    maximumCharacters: maximumCharacters
                )
            } catch { throw Self.mapped(error) }
        }
    }

    public func rawMessage(
        accountID: UUID,
        folder: String,
        messageID: String,
        mailboxVersion: String?,
        owner: C06MailOwner
    ) async throws -> Data {
        let context = try await authorized(accountID: accountID, owner: owner)
        return try await withOperation(owner) { cancel in
            do {
                return try await context.transport.message(
                    account: context.record.account,
                    password: context.incomingPassword,
                    id: messageID,
                    folder: folder,
                    mailboxVersion: mailboxVersion,
                    cancelled: cancel
                )
            } catch { throw Self.mapped(error) }
        }
    }

    public func setRead(
        accountID: UUID,
        messageID: String,
        folder: String,
        mailboxVersion: String,
        read: Bool,
        owner: C06MailOwner
    ) async throws {
        let context = try await authorized(accountID: accountID, owner: owner)
        guard let uid = UInt32(messageID), uid > 0,
              !folder.isEmpty, folder.utf8.count <= 1024,
              !mailboxVersion.isEmpty else {
            throw C06MailError(.invalidRequest, "invalidSetReadArguments")
        }
        guard context.record.account.incomingProtocol == .imap else {
            throw C06MailError(.unsupportedForPOP3, "unsupportedForPOP3")
        }
        try await withOperation(owner) { cancel in
            do {
                try await context.transport.setRead(
                    account: context.record.account,
                    password: context.incomingPassword,
                    id: messageID,
                    folder: folder,
                    mailboxVersion: mailboxVersion,
                    read: read,
                    cancelled: cancel
                )
            } catch { throw Self.mapped(error) }
        }
    }

    // MARK: Mutation

    public func move(
        accountID: UUID,
        requestID: UUID,
        messageID: String,
        folder: String,
        mailboxVersion: String,
        action: String,
        destination: String?,
        owner: C06MailOwner
    ) async throws -> C06MailMoveResult {
        let context = try await authorized(accountID: accountID, owner: owner)
        guard ["move", "archive", "trash"].contains(action),
              let uid = UInt32(messageID), uid > 0,
              !folder.isEmpty, folder.utf8.count <= 1024,
              !mailboxVersion.isEmpty, mailboxVersion.utf8.count <= 70 else {
            throw C06MailError(.invalidRequest, "invalidMoveArguments")
        }
        if action == "move" {
            guard let destination, !destination.isEmpty,
                  destination.utf8.count <= 1024, destination != folder else {
                throw C06MailError(.invalidRequest, "invalidMoveDestination")
            }
        } else if destination != nil {
            throw C06MailError(.invalidRequest, "specialFolderDestinationForbidden")
        }
        let journal = try mutationJournal(epoch: owner.nativeEpoch)
        let request = MailMoveRequest(
            requestID: requestID,
            accountID: context.record.account.id,
            action: action,
            sourceFolder: folder,
            uid: messageID,
            mailboxVersion: mailboxVersion,
            destination: action == "move" ? destination : nil
        )
        return try await withOperation(owner) { cancel in
            let orchestration = MailMoveOrchestration(
                journal: journal,
                seams: MailMoveOrchestration.Seams(
                    identity: { operation in
                        do {
                            let identity = try await context.transport.messageIdentity(
                                account: context.record.account,
                                password: context.incomingPassword,
                                folder: operation.sourceFolder,
                                uid: operation.uid,
                                mailboxVersion: operation.mailboxVersion,
                                cancelled: cancel
                            )
                            return MailMutationJournal.StableIdentity(
                                messageID: identity.messageID,
                                byteCount: identity.byteCount
                            )
                        } catch { throw Self.mapped(error) }
                    },
                    reconcile: { provenance in
                        do {
                            switch try await context.transport.reconcileMove(
                                account: context.record.account,
                                password: context.incomingPassword,
                                provenance: provenance,
                                cancelled: cancel
                            ) {
                            case .notSubmitted:
                                return .notSubmitted
                            case .completed(let destinationUID, let version):
                                return .completed(
                                    destinationUID: destinationUID,
                                    destinationMailboxVersion: version
                                )
                            case .ambiguous(let reason):
                                return .ambiguous(reason: reason)
                            }
                        } catch { throw Self.mapped(error) }
                    }
                )
            )
            let preparation: MailMovePreparation
            do {
                preparation = try await orchestration.prepare(request) { request in
                    let kind: MailSpecialFolder = request.action == "archive" ? .archive : .trash
                    do {
                        guard let resolved = try await context.transport.specialFolder(
                            account: context.record.account,
                            password: context.incomingPassword,
                            kind: kind,
                            cancelled: cancel
                        ) else {
                            throw C06MailDestinationUnavailable(action: request.action)
                        }
                        return resolved
                    } catch let error as C06MailDestinationUnavailable {
                        throw error
                    } catch { throw Self.mapped(error) }
                }
            } catch let unavailable as C06MailDestinationUnavailable {
                return C06MailMoveResult(
                    status: .unsupported,
                    requestID: requestID,
                    messageID: messageID,
                    sourceFolder: folder,
                    destination: nil,
                    destinationUID: nil,
                    destinationMailboxVersion: nil,
                    expunged: nil,
                    destinationVerified: false,
                    replayed: false,
                    reconciled: false,
                    receiptPersisted: true,
                    reason: unavailable.action == "archive" ? "noArchiveFolder" : "noTrashFolder",
                    warning: nil
                )
            } catch { throw Self.mapped(error) }
            let operation: MailMoveOperation
            switch preparation {
            case .ready(let ready):
                operation = ready
            case .uncertain(let reason):
                return C06MailMoveResult(
                    status: .mutationUnknown,
                    requestID: requestID,
                    messageID: messageID,
                    sourceFolder: folder,
                    destination: nil,
                    destinationUID: nil,
                    destinationMailboxVersion: nil,
                    expunged: nil,
                    destinationVerified: false,
                    replayed: false,
                    reconciled: false,
                    receiptPersisted: true,
                    reason: reason,
                    warning: nil
                )
            }
            do {
                let outcome = try await orchestration.execute(operation)
                switch outcome {
                case .firstAttempt(let attempt):
                    defer { attempt.release() }
                    let result: MailMoveOutcome
                    do {
                        result = try await context.transport.move(
                            account: context.record.account,
                            password: context.incomingPassword,
                            requestID: requestID,
                            uid: operation.uid,
                            folder: operation.sourceFolder,
                            destination: operation.destination,
                            mailboxVersion: operation.mailboxVersion,
                            cancelled: cancel
                        )
                    } catch let failure as MailFailure where failure == .mutationUnknown {
                        try? journal.finish(
                            requestID: attempt.requestID,
                            digest: attempt.digest,
                            state: .mutationUnknown
                        )
                        return C06MailMoveResult(
                            status: .mutationUnknown,
                            requestID: requestID,
                            messageID: messageID,
                            sourceFolder: folder,
                            destination: operation.destination,
                            destinationUID: nil,
                            destinationMailboxVersion: nil,
                            expunged: nil,
                            destinationVerified: false,
                            replayed: false,
                            reconciled: false,
                            receiptPersisted: true,
                            reason: "mutationUnknown",
                            warning: nil
                        )
                    } catch let failure as MailFailure {
                        if Self.definitelyNotSubmitted(failure) {
                            try? journal.finish(
                                requestID: attempt.requestID,
                                digest: attempt.digest,
                                state: .notStarted
                            )
                        }
                        throw Self.mapped(failure)
                    } catch {
                        throw C06MailError(.mutationUnknown, "mutationUnknown", detail: error.localizedDescription)
                    }
                    var persisted = true
                    do {
                        try journal.finish(
                            requestID: attempt.requestID,
                            digest: attempt.digest,
                            state: .completed
                        )
                    } catch {
                        persisted = false
                    }
                    return C06MailMoveResult(
                        status: .completed,
                        requestID: requestID,
                        messageID: messageID,
                        sourceFolder: folder,
                        destination: operation.destination,
                        destinationUID: result.destinationUID,
                        destinationMailboxVersion: result.destinationMailboxVersion,
                        expunged: result.expunged,
                        destinationVerified: result.destinationVerified,
                        replayed: false,
                        reconciled: false,
                        receiptPersisted: persisted,
                        warning: persisted ? nil : Self.receiptWriteWarning
                    )
                case .replay(let state):
                    return C06MailMoveResult(
                        status: C06MailMoveStatus(rawValue: state.rawValue) ?? .mutationUnknown,
                        requestID: requestID,
                        messageID: messageID,
                        sourceFolder: folder,
                        destination: operation.destination,
                        destinationUID: nil,
                        destinationMailboxVersion: nil,
                        expunged: nil,
                        destinationVerified: false,
                        replayed: true,
                        reconciled: false,
                        receiptPersisted: state == .completed,
                        warning: nil
                    )
                case .reconciledCompleted(let destinationUID, let destinationVersion, let persisted):
                    return C06MailMoveResult(
                        status: .completed,
                        requestID: requestID,
                        messageID: messageID,
                        sourceFolder: folder,
                        destination: operation.destination,
                        destinationUID: destinationUID,
                        destinationMailboxVersion: destinationVersion,
                        expunged: nil,
                        destinationVerified: destinationUID != nil,
                        replayed: false,
                        reconciled: true,
                        receiptPersisted: persisted,
                        warning: persisted ? nil : Self.receiptWriteWarning
                    )
                case .uncertain(let reason):
                    return C06MailMoveResult(
                        status: .mutationUnknown,
                        requestID: requestID,
                        messageID: messageID,
                        sourceFolder: folder,
                        destination: operation.destination,
                        destinationUID: nil,
                        destinationMailboxVersion: nil,
                        expunged: nil,
                        destinationVerified: false,
                        replayed: false,
                        reconciled: false,
                        receiptPersisted: true,
                        reason: reason,
                        warning: nil
                    )
                }
            } catch let error as C06MailError {
                throw error
            } catch let failure as MailFailure {
                throw Self.mapped(failure)
            } catch {
                throw C06MailError(.internalFailure, "moveFailed", detail: error.localizedDescription)
            }
        }
    }

    // MARK: Send

    public func send(
        accountID: UUID,
        requestID: UUID,
        recipients: [String],
        subject: String,
        body: String,
        attachments: [MailAttachment],
        draftHandles: [String],
        owner: C06MailOwner
    ) async throws -> C06MailSendResult {
        let context = try await authorizedOutgoing(accountID: accountID, owner: owner)
        var resolved = attachments
        let staged = draftHandles
        if !draftHandles.isEmpty {
            for handle in draftHandles {
                guard let draft = drafts[handle], draft.ready,
                      draft.accountID == accountID else {
                    throw C06MailError(.draftNotFound, "draftNotFound")
                }
                let data = try Data(contentsOf: draft.url, options: .mappedIfSafe)
                guard data.count == draft.byteCount,
                      FloeDigest.sha256Hex(data) == draft.expectedSHA256 else {
                    throw C06MailError(.draftIncomplete, "draftDigestMismatch")
                }
                resolved.append(MailAttachment(filename: draft.filename, data: data))
            }
        }
        let draft = MailDraft(
            recipients: recipients,
            subject: subject,
            body: body,
            attachments: resolved
        )
        do {
            try draft.validate()
        } catch {
            throw C06MailError(.invalidAccount, "invalidMessage", detail: error.localizedDescription)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode([
            "account": accountID.uuidString,
            "to": recipients.joined(separator: "\n"),
            "subject": subject,
            "body": body,
            "attachments": resolved.map {
                $0.filename + ":" + FloeDigest.sha256Hex($0.data)
            }.joined(separator: "\n"),
        ])
        let digest = FloeDigest.sha256Hex(metadata)
        let journal = try deliveryJournal(epoch: owner.nativeEpoch)
        // Acquire the single-operation right BEFORE reserving the receipt. A
        // busy call must not mint a deliveryUnknown receipt it never sent.
        let token = try beginOperation(owner)
        defer { endOperation(token) }
        let cancel: @Sendable () -> Bool = { token.isCancelled }
        var reserved: MailDeliveryJournal.State? = nil
        do {
            reserved = try journal.reserve(requestID: requestID, digest: digest)
        } catch {
            throw Self.mapped(error)
        }
        if let state = reserved {
            let status: C06MailSendStatus
            let replayed: Bool
            switch state {
            case .acceptedByServer:
                status = .acceptedByServer
                replayed = true
            case .deliveryUnknown:
                status = .deliveryUnknownReplay
                replayed = true
            case .notSubmitted:
                status = .notSubmitted
                replayed = true
            }
            if state == .acceptedByServer { discardDrafts(staged) }
            return C06MailSendResult(
                status: status,
                requestID: requestID,
                replayed: replayed,
                receiptPersisted: true,
                warning: state == .deliveryUnknown
                    ? "This send has no confirmed outcome. Do not resend automatically; check the Sent folder first."
                    : nil
            )
        }
        do {
            try await context.transport.send(
                account: context.record.account,
                password: context.outgoingPassword ?? "",
                draft: draft,
                messageID: requestID,
                cancelled: cancel
            )
        } catch let failure as MailFailure {
            // MailProtocolSession.send converts EVERY failure at/after the
            // DATA command into deliveryUnknown. A different failure is
            // therefore provably pre-submission and safe to record as
            // notSubmitted (never as a success).
            if failure == .deliveryUnknown {
                return C06MailSendResult(
                    status: .deliveryUnknown,
                    requestID: requestID,
                    replayed: false,
                    receiptPersisted: true,
                    warning: "The server did not confirm delivery. Do not resend automatically; check the Sent folder first."
                )
            }
            try? journal.finish(requestID: requestID, digest: digest, state: .notSubmitted)
            throw Self.mapped(failure)
        } catch let error as C06MailError {
            if error.code == .deliveryUnknown {
                return C06MailSendResult(
                    status: .deliveryUnknown,
                    requestID: requestID,
                    replayed: false,
                    receiptPersisted: true,
                    warning: "The server did not confirm delivery. Do not resend automatically; check the Sent folder first."
                )
            }
            if error.code == .cancelled || error.code == .timedOut
                || error.code == .transportFailed {
                return C06MailSendResult(
                    status: .deliveryUnknown,
                    requestID: requestID,
                    replayed: false,
                    receiptPersisted: true,
                    warning: "The connection ended after the message was submitted. Do not resend automatically; check the Sent folder first."
                )
            }
            try? journal.finish(requestID: requestID, digest: digest, state: .notSubmitted)
            throw error
        } catch {
            // A failure that is not provably pre-submission stays unknown:
            // never mark notSubmitted and never offer an automatic resend.
            return C06MailSendResult(
                status: .deliveryUnknown,
                requestID: requestID,
                replayed: false,
                receiptPersisted: true,
                warning: "Delivery could not be confirmed. Do not resend automatically; check the Sent folder first."
            )
        }
        var persisted = true
        do {
            try journal.finish(requestID: requestID, digest: digest, state: .acceptedByServer)
        } catch {
            persisted = false
        }
        discardDrafts(staged)
        return C06MailSendResult(
            status: .acceptedByServer,
            requestID: requestID,
            replayed: false,
            receiptPersisted: persisted,
            warning: persisted ? nil : "The server accepted the message, but the local receipt could not be saved. Do not resend; check the Sent folder."
        )
    }

    // MARK: Attachment streaming

    public func openAttachment(
        accountID: UUID,
        folder: String,
        messageID: String,
        mailboxVersion: String?,
        messageSHA256: String,
        attachmentIndex: Int,
        owner: C06MailOwner
    ) async throws -> C06MailAttachmentHandle {
        let context = try await authorized(accountID: accountID, owner: owner)
        guard (0..<100).contains(attachmentIndex),
              messageSHA256.utf8.count == 64 else {
            throw C06MailError(.invalidRequest, "invalidAttachmentArguments")
        }
        sweepTransfers()
        guard attachments.count < C06MailWire.maximumLiveAttachmentHandles else {
            throw C06MailError(.attachmentTooLarge, "tooManyAttachmentHandles", retryable: true)
        }
        let data = try await withOperation(owner) { cancel in
            do {
                return try await context.transport.message(
                    account: context.record.account,
                    password: context.incomingPassword,
                    id: messageID,
                    folder: folder,
                    mailboxVersion: mailboxVersion,
                    cancelled: cancel
                )
            } catch { throw Self.mapped(error) }
        }
        guard FloeDigest.sha256Hex(data) == messageSHA256 else {
            throw C06MailError(.mailboxChanged, "messageContentChanged")
        }
        let message = try Self.mappedMIME { try MailMIME.decode(data) }
        guard message.attachments.indices.contains(attachmentIndex) else {
            throw C06MailError(.attachmentNotFound, "attachmentNotFound")
        }
        let attachment = message.attachments[attachmentIndex]
        guard attachment.data.count <= C06MailWire.maximumAttachmentBytes else {
            throw C06MailError(.attachmentTooLarge, "attachmentTooLarge")
        }
        let handle = UUID().uuidString
        let directory = try transferDirectory(epoch: owner.nativeEpoch)
        let url = directory.appendingPathComponent(handle, isDirectory: false)
        do {
            try attachment.data.write(to: url, options: .withoutOverwriting)
        } catch {
            throw C06MailError(.storageUnavailable, "attachmentStageFailed")
        }
        let staged = C06StagedAttachment(
            handle: handle,
            filename: attachment.filename,
            byteCount: attachment.data.count,
            sha256: FloeDigest.sha256Hex(attachment.data),
            url: url,
            createdAt: now(),
            lastAccess: now()
        )
        attachments[handle] = staged
        return staged.info
    }

    public func readAttachment(
        handle: String,
        offset: Int,
        length: Int,
        owner: C06MailOwner
    ) throws -> Data {
        try requireOwner(owner)
        guard offset >= 0, (1...C06MailWire.maximumChunkBytes).contains(length),
              var staged = attachments[handle],
              offset < staged.byteCount else {
            throw C06MailError(.attachmentNotFound, "attachmentHandleNotFound")
        }
        let count = min(length, staged.byteCount - offset)
        do {
            let file = try FileHandle(forReadingFrom: staged.url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(offset))
            guard let data = try file.read(upToCount: count), data.count == count else {
                throw C06MailError(.attachmentNotFound, "attachmentReadShort")
            }
            staged.lastAccess = now()
            attachments[handle] = staged
            return data
        } catch let error as C06MailError {
            throw error
        } catch {
            throw C06MailError(.storageUnavailable, "attachmentReadFailed")
        }
    }

    public func attachmentByteCount(handle: String, owner: C06MailOwner) throws -> Int {
        try requireOwner(owner)
        guard let staged = attachments[handle] else {
            throw C06MailError(.attachmentNotFound, "attachmentHandleNotFound")
        }
        return staged.byteCount
    }

    public func closeAttachment(handle: String, owner: C06MailOwner) {
        guard (try? requireOwner(owner)) != nil else { return }
        if let staged = attachments.removeValue(forKey: handle) {
            try? FileManager.default.removeItem(at: staged.url)
        }
    }

    // MARK: Draft staging (compose attachments)

    public func beginDraftAttachment(
        accountID: UUID,
        filename: String,
        byteCount: Int,
        sha256: String,
        owner: C06MailOwner
    ) async throws -> C06MailDraftHandle {
        _ = try await storeContext(owner)
        guard (1...C06MailWire.maximumAttachmentBytes).contains(byteCount),
              sha256.utf8.count == 64,
              Self.validAttachmentName(filename) else {
            throw C06MailError(.invalidRequest, "invalidDraftAttachment")
        }
        sweepDrafts()
        guard drafts.count < C06MailWire.maximumLiveDraftHandles,
              drafts.values.reduce(0, { $0 + $1.byteCount }) + byteCount <= 20_000_000 else {
            throw C06MailError(.attachmentTooLarge, "draftStagingLimit", retryable: true)
        }
        let handle = UUID().uuidString
        let directory = try draftDirectory(epoch: owner.nativeEpoch)
            .appendingPathComponent(handle, isDirectory: true)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw C06MailError(.storageUnavailable, "draftCreateFailed")
            }
        } catch let error as C06MailError {
            throw error
        } catch {
            throw C06MailError(.storageUnavailable, "draftCreateFailed")
        }
        let draft = C06DraftAttachment(
            handle: handle,
            accountID: accountID,
            filename: filename,
            byteCount: byteCount,
            expectedSHA256: sha256,
            url: url,
            directory: directory,
            createdAt: now(),
            written: 0,
            ready: false,
            lastAccess: now()
        )
        drafts[handle] = draft
        return draft.info
    }

    public func writeDraftAttachment(
        handle: String,
        offset: Int,
        data: Data,
        owner: C06MailOwner
    ) throws {
        try requireOwner(owner)
        guard !data.isEmpty, data.count <= C06MailWire.maximumChunkBytes,
              var draft = drafts[handle],
              !draft.ready,
              offset == draft.written,
              draft.written + data.count <= draft.byteCount else {
            throw C06MailError(.draftIncomplete, "invalidDraftChunk")
        }
        do {
            let file = try FileHandle(forWritingTo: draft.url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: data)
            try file.synchronize()
        } catch {
            throw C06MailError(.storageUnavailable, "draftWriteFailed")
        }
        draft.written += data.count
        draft.lastAccess = now()
        drafts[handle] = draft
    }

    public func finishDraftAttachment(
        handle: String,
        owner: C06MailOwner
    ) throws -> C06MailDraftHandle {
        try requireOwner(owner)
        guard var draft = drafts[handle], !draft.ready else {
            throw C06MailError(.draftNotFound, "draftNotFound")
        }
        guard draft.written == draft.byteCount else {
            throw C06MailError(.draftIncomplete, "draftIncomplete")
        }
        let data: Data
        do {
            data = try Data(contentsOf: draft.url, options: .mappedIfSafe)
        } catch {
            throw C06MailError(.storageUnavailable, "draftReadFailed")
        }
        guard data.count == draft.byteCount,
              FloeDigest.sha256Hex(data) == draft.expectedSHA256 else {
            throw C06MailError(.draftIncomplete, "draftDigestMismatch")
        }
        draft.ready = true
        draft.lastAccess = now()
        drafts[handle] = draft
        return draft.info
    }

    public func discardDraftAttachment(handle: String, owner: C06MailOwner) {
        guard (try? requireOwner(owner)) != nil else { return }
        if let draft = drafts.removeValue(forKey: handle) {
            try? FileManager.default.removeItem(at: draft.directory)
        }
    }

    // MARK: Lifecycle

    public func cancel(owner: C06MailOwner) async throws -> C06MailCancelReport {
        try requireOwner(owner)
        var count = 0
        if let active = activeOperation, active.ownerToken == owner.token {
            active.token.cancel()
            count = 1
        }
        let transport = try transportProvider(owner.nativeEpoch)
        transport.cancelAll()
        let complete = await waitIdle(transport, timeout: 5)
        return C06MailCancelReport(cancelledOperations: count, complete: complete)
    }

    public func rootStop(expectedEpoch: UInt64) async -> C06MailRootStopReport {
        retiredThroughEpoch = max(retiredThroughEpoch, expectedEpoch)
        var cancelled = 0
        if let active = activeOperation {
            active.token.cancel()
            cancelled = 1
            activeOperation = nil
        }
        var drained = true
        if let transport = try? transportProvider(expectedEpoch) {
            transport.cancelAll()
            drained = await waitIdle(transport, timeout: 5)
        }
        drained = drained && closeTransport(6)
        let removedAttachments = attachments.count
        for staged in attachments.values {
            try? FileManager.default.removeItem(at: staged.url)
        }
        attachments.removeAll()
        let removedDrafts = drafts.count
        for draft in drafts.values {
            try? FileManager.default.removeItem(at: draft.directory)
        }
        drafts.removeAll()
        C06MailDomain.availability.update(available: false, accounts: 0, epoch: nil)
        return C06MailRootStopReport(
            drained: drained,
            cancelledOperations: cancelled,
            removedAttachmentHandles: removedAttachments,
            removedDraftHandles: removedDrafts
        )
    }

    // MARK: Internals

    private struct StoreContext: Sendable {
        let store: any C06MailAccountStoring
    }

    private struct NetworkContext: Sendable {
        let store: any C06MailAccountStoring
        let transport: any MailTransporting
    }

    private struct Context: Sendable {
        let store: any C06MailAccountStoring
        let transport: any MailTransporting
        let record: C06MailAccountRecord
        let incomingPassword: String
        let outgoingPassword: String?
    }

    /// Account settings/list/delete do not need the network lane. This keeps
    /// configuration usable before the first connection and lets the user
    /// repair an account whose transport is unavailable.
    private func storeContext(_ owner: C06MailOwner) async throws -> StoreContext {
        try requireOwner(owner)
        guard let current = readiness().epoch, current == owner.nativeEpoch else {
            throw C06MailError(.staleEpoch, "staleNativeEpoch")
        }
        let store = try await storeProvider(owner.nativeEpoch)
        guard (try? await store.schemaReady()) == true else {
            throw C06MailError(.storageUnavailable, "mailSchemaNotReady", retryable: true)
        }
        return StoreContext(store: store)
    }

    private func networkContext(_ owner: C06MailOwner) async throws -> NetworkContext {
        let store = try await storeContext(owner)
        guard transportReadyCheck(owner.nativeEpoch) else {
            throw C06MailError(.transportUnavailable, "mailTransportUnavailable", retryable: true)
        }
        return NetworkContext(
            store: store.store,
            transport: try transportProvider(owner.nativeEpoch)
        )
    }

    private func authorized(
        accountID: UUID,
        owner: C06MailOwner,
        needsOutgoing: Bool = false
    ) async throws -> Context {
        let network = try await networkContext(owner)
        guard let record = try await network.store.account(id: accountID) else {
            throw C06MailError(.accountNotFound, "accountNotFound")
        }
        let incoming = try await password(
            reference: record.incomingCredentialAccount,
            context: network
        )
        let outgoing = needsOutgoing
            ? try await password(reference: record.outgoingCredentialAccount, context: network)
            : nil
        return Context(
            store: network.store,
            transport: network.transport,
            record: record,
            incomingPassword: incoming,
            outgoingPassword: outgoing
        )
    }

    /// SMTP-only context: a broken incoming credential must not block sending.
    private func authorizedOutgoing(
        accountID: UUID,
        owner: C06MailOwner
    ) async throws -> Context {
        let network = try await networkContext(owner)
        guard let record = try await network.store.account(id: accountID) else {
            throw C06MailError(.accountNotFound, "accountNotFound")
        }
        let outgoing = try await password(
            reference: record.outgoingCredentialAccount,
            context: network
        )
        return Context(
            store: network.store,
            transport: network.transport,
            record: record,
            incomingPassword: "",
            outgoingPassword: outgoing
        )
    }

    private func beginOperation(_ owner: C06MailOwner) throws -> OperationToken {
        try requireOwner(owner)
        guard activeOperation == nil else {
            throw C06MailError(.busy, "mailOperationBusy", retryable: true)
        }
        let token = OperationToken()
        activeOperation = ActiveOperation(ownerToken: owner.token, token: token)
        return token
    }

    private func endOperation(_ token: OperationToken) {
        if activeOperation?.token === token {
            activeOperation = nil
        }
    }

    /// The async operation helper. Only one mail operation is active at a time
    /// because MailClient itself is serial; the token still lets the explicit
    /// host Cancel and RootStop interrupt the current wire wait.
    private func withOperation<T: Sendable>(
        _ owner: C06MailOwner,
        _ body: @escaping @Sendable (@escaping @Sendable () -> Bool) async throws -> T
    ) async throws -> T {
        let token = try beginOperation(owner)
        defer { endOperation(token) }
        return try await body({ token.isCancelled })
    }

    private func requireOwner(_ owner: C06MailOwner) throws {
        try owner.validate()
        let current = readiness()
        guard current.ready else {
            throw C06MailError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard current.epoch == owner.nativeEpoch else {
            throw C06MailError(.staleEpoch, "staleNativeEpoch")
        }
        guard owner.nativeEpoch > retiredThroughEpoch else {
            throw C06MailError(.staleEpoch, "mailEpochRetired")
        }
    }

    private func password(reference: String, context: NetworkContext) async throws -> String {
        guard credentialReady() else {
            throw C06MailError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        let opaque = SecretGatewayNaming.opaqueReference(for: SecretReference(
            keychainAccount: reference,
            synchronizable: false
        ))
        do {
            guard let data = try await credentialReader(opaque),
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                throw C06MailError(.credentialMissing, "credentialMissing")
            }
            guard value.utf8.count <= 1024,
                  !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw C06MailError(.credentialInvalid, "credentialInvalid")
            }
            return value
        } catch let error as C06MailError {
            throw error
        } catch {
            throw C06MailError(.gatewayUnavailable, "credentialReadFailed", retryable: true)
        }
    }

    private func writeSecret(_ data: Data, account: String) async throws {
        let reference = SecretReference(keychainAccount: account, synchronizable: false)
        let opaque = SecretGatewayNaming.opaqueReference(for: reference)
        do {
            try await credentialWriter(opaque, data)
        } catch let error as C06MailError {
            throw error
        } catch {
            throw C06MailError(.gatewayUnavailable, "credentialWriteFailed", retryable: true)
        }
    }

    private func deleteSecret(account: String) async throws {
        let reference = SecretReference(keychainAccount: account, synchronizable: false)
        let opaque = SecretGatewayNaming.opaqueReference(for: reference)
        do {
            try await credentialDeleter(opaque)
        } catch let error as C06MailError {
            throw error
        } catch {
            throw C06MailError(.gatewayUnavailable, "credentialDeleteFailed", retryable: true)
        }
    }

    private func validatedSecret(_ data: Data?) throws -> Data? {
        guard let data else { return nil }
        guard !data.isEmpty, data.count <= 1024,
              String(data: data, encoding: .utf8) != nil else {
            throw C06MailError(.credentialInvalid, "credentialInvalid")
        }
        return data
    }

    private func secretString(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw C06MailError(.credentialInvalid, "credentialInvalid")
        }
        return value
    }

    private func validateDisplayName(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.utf8.count),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C06MailError(.invalidAccount, "invalidDisplayName")
        }
    }

    private static func credentialAccount(
        _ id: UUID,
        _ direction: CredentialDirection,
        _ revision: Int
    ) -> String {
        "floe.mail.\(id.uuidString).\(direction.rawValue).r\(revision)"
    }

    private enum CredentialDirection: String {
        case incoming
        case outgoing
    }

    private func mutationJournal(epoch: UInt64) throws -> MailMutationJournal {
        if cachedEpoch != epoch {
            mutationJournals.removeAll()
            deliveryJournals.removeAll()
            cachedEpoch = epoch
        }
        let key = "mutation"
        if let existing = mutationJournals[key] { return existing }
        let directory = try rootProvider(epoch)
            .appendingPathComponent("MailMutations", isDirectory: true)
        let journal = MailMutationJournal(directory: directory)
        mutationJournals[key] = journal
        return journal
    }

    private func deliveryJournal(epoch: UInt64) throws -> MailDeliveryJournal {
        if cachedEpoch != epoch {
            mutationJournals.removeAll()
            deliveryJournals.removeAll()
            cachedEpoch = epoch
        }
        let key = "delivery"
        if let existing = deliveryJournals[key] { return existing }
        let directory = try rootProvider(epoch)
            .appendingPathComponent("MailDelivery", isDirectory: true)
        let journal = MailDeliveryJournal(directory: directory)
        deliveryJournals[key] = journal
        return journal
    }

    private func transferDirectory(epoch: UInt64) throws -> URL {
        let directory = try rootProvider(epoch)
            .appendingPathComponent("MailTransfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw C06MailError(.storageUnavailable, "transferDirectoryUnavailable")
        }
        return directory
    }

    private func draftDirectory(epoch: UInt64) throws -> URL {
        let directory = try rootProvider(epoch)
            .appendingPathComponent("MailDrafts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw C06MailError(.storageUnavailable, "draftDirectoryUnavailable")
        }
        return directory
    }

    private func sweepTransfers() {
        let current = now()
        let expired = attachments.compactMap { handle, staged -> String? in
            current.timeIntervalSince(staged.lastAccess) > C06MailWire.attachmentHandleLifetime
                ? handle : nil
        }
        for handle in expired {
            if let staged = attachments.removeValue(forKey: handle) {
                try? FileManager.default.removeItem(at: staged.url)
            }
        }
    }

    private func sweepDrafts() {
        let current = now()
        let expired = drafts.compactMap { handle, draft -> String? in
            current.timeIntervalSince(draft.lastAccess) > C06MailWire.draftHandleLifetime
                ? handle : nil
        }
        for handle in expired {
            if let draft = drafts.removeValue(forKey: handle) {
                try? FileManager.default.removeItem(at: draft.directory)
            }
        }
    }

    private func discardDrafts(_ handles: [String]) {
        for handle in handles {
            if let draft = drafts.removeValue(forKey: handle) {
                try? FileManager.default.removeItem(at: draft.directory)
            }
        }
    }

    private static func validAttachmentName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 180
            && !value.contains(where: { $0.isNewline || $0 == "\0" || "/\\".contains($0) })
    }

    private func waitIdle(_ transport: any MailTransporting, timeout: TimeInterval) async -> Bool {
        let deadline = now().addingTimeInterval(max(0.1, timeout))
        while now() < deadline {
            if transport.isIdle { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return transport.isIdle
    }

    private nonisolated static func mapped(_ error: Error, stage: String? = nil) -> C06MailError {
        if let error = error as? C06MailError { return error }
        guard let failure = error as? MailFailure else {
            return C06MailError(.internalFailure, "mailOperationFailed", detail: error.localizedDescription, stage: stage)
        }
        let code: C06MailErrorCode
        switch failure {
        case .invalidConfiguration, .invalidAddress: code = .invalidAccount
        case .connectionFailed: code = .connectionRefused
        case .tlsFailed: code = .tlsFailed
        case .timedOut: code = .timedOut
        case .authenticationFailed: code = .authenticationFailed
        case .protocolRejected: code = .protocolRejected
        case .responseTooLarge: code = .responseTooLarge
        case .invalidMessage: code = .protocolRejected
        case .messageNotFound: code = .messageNotFound
        case .mailboxChanged: code = .mailboxChanged
        case .deliveryUnknown: code = .deliveryUnknown
        case .cancelled: code = .cancelled
        case .busy: code = .busy
        case .localNetworkPermissionRequired: code = .localNetworkPermissionRequired
        case .unsupportedForPOP3: code = .unsupportedForPOP3
        case .mutationUnknown: code = .mutationUnknown
        case .cursorMismatch: code = .cursorMismatch
        case .transportUnavailable: code = .transportUnavailable
        case .storageUnavailable: code = .storageUnavailable
        case .accountNotFound: code = .accountNotFound
        case .accountLimit: code = .accountLimit
        case .credentialMissing: code = .credentialMissing
        case .attachmentNotFound: code = .attachmentNotFound
        case .attachmentTooLarge: code = .attachmentTooLarge
        case .draftNotFound: code = .draftNotFound
        case .draftIncomplete: code = .draftIncomplete
        }
        return C06MailError(code, failure.rawValue, retryable: false, stage: stage)
    }

    private nonisolated static func mappedMIME<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw C06MailError(.protocolRejected, "invalidMessage")
        }
    }

    private static func definitelyNotSubmitted(_ failure: MailFailure) -> Bool {
        switch failure {
        case .invalidConfiguration, .invalidAddress, .connectionFailed, .tlsFailed,
             .timedOut, .authenticationFailed, .protocolRejected, .invalidMessage,
             .messageNotFound, .mailboxChanged, .cancelled, .busy, .unsupportedForPOP3,
             .cursorMismatch, .transportUnavailable, .storageUnavailable,
             .accountNotFound, .accountLimit, .credentialMissing, .attachmentNotFound,
             .attachmentTooLarge, .draftNotFound, .draftIncomplete,
             .localNetworkPermissionRequired:
            return true
        case .responseTooLarge, .deliveryUnknown, .mutationUnknown:
            return false
        }
    }

    private static let receiptWriteWarning =
        "The mailbox change is complete and verified on the server, but the local recovery record could not be saved. Retry with the SAME requestID to check the mailbox read-only; do not repeat the move."
}
