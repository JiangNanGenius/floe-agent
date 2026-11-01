// SPDX-License-Identifier: MPL-2.0
//
// C06 mail domain tests. Authored source; NOT RUN by this lane.
// The real C06MailDomain runs over injected stores/credentials/transport; no
// socket, credential, device, account or mail provider participates.

import Foundation
import Testing
import FloeCore
import FloePersistence
@testable import FloeAndroidCore
@testable import FloeAndroidMail

private actor FakeMailAccountStore: C06MailAccountStoring {
    private var records: [UUID: C06MailAccountRecord] = [:]
    private var schema = true
    func setSchemaReady(_ value: Bool) { schema = value }
    func seed(_ record: C06MailAccountRecord) { records[record.account.id] = record }

    func schemaReady() async throws -> Bool { schema }
    func accounts() async throws -> [C06MailAccountRecord] {
        records.values.sorted { $0.displayName < $1.displayName }
    }
    func account(id: UUID) async throws -> C06MailAccountRecord? { records[id] }
    func save(_ record: C06MailAccountRecord) async throws { records[record.account.id] = record }
    func delete(id: UUID) async throws { records.removeValue(forKey: id) }
}

private actor FakeMailCredentials {
    private var values: [String: Data] = [:]
    func read(_ reference: String) -> Data? { values[reference] }
    func write(_ reference: String, _ data: Data) { values[reference] = data }
    func delete(_ reference: String) { values.removeValue(forKey: reference) }
    func contains(_ reference: String) -> Bool { values[reference] != nil }
}

private final class FakeMailTransport: MailTransporting, @unchecked Sendable {
    var testCount = 0
    var sendCount = 0
    var moveCount = 0
    var cancelAllCount = 0
    var sentDrafts: [MailDraft] = []
    var sendError: MailFailure?
    var moveError: MailFailure?
    var reconcileResult: MailMoveReconciliation = .ambiguous(reason: "test")
    var rawMessage: Data
    var listing = MailListing(
        folder: "INBOX",
        mailboxVersion: "100",
        messages: [MailMessageReference(id: "9", byteCount: 123, flags: [])],
        hasMore: false
    )

    init(rawMessage: Data) { self.rawMessage = rawMessage }

    func test(server: MailServer, protocolName: String, password: String) async throws {
        testCount += 1
        if password.isEmpty { throw MailFailure.authenticationFailed }
    }

    func folders(account: MailAccount, password: String,
                 cancelled: @escaping @Sendable () -> Bool) async throws -> [String] {
        ["INBOX", "Archive"]
    }

    func foldersWithAttributes(account: MailAccount, password: String,
                               cancelled: @escaping @Sendable () -> Bool) async throws -> [MailFolderInfo] {
        [
            MailFolderInfo(name: "INBOX", attributes: []),
            MailFolderInfo(name: "Archive", attributes: ["\\Archive"]),
        ]
    }

    func list(account: MailAccount, password: String, folder: String, afterUID: UInt32,
              limit: Int, beforeMessageID: String?,
              cancelled: @escaping @Sendable () -> Bool) async throws -> MailListing {
        listing
    }

    func search(account: MailAccount, password: String, folder: String,
                criteria: MailSearchCriteria, cursor: String?, limit: Int,
                cancelled: @escaping @Sendable () -> Bool) async throws -> MailSearchPage {
        MailSearchPage(
            folder: folder,
            mailboxVersion: "100",
            messages: listing.messages,
            hasMore: false,
            nextCursor: nil,
            totalMatched: 1
        )
    }

    func specialFolder(account: MailAccount, password: String, kind: MailSpecialFolder,
                       cancelled: @escaping @Sendable () -> Bool) async throws -> String? {
        "Archive"
    }

    func move(account: MailAccount, password: String, requestID: UUID, uid: String,
              folder: String, destination: String, mailboxVersion: String,
              cancelled: @escaping @Sendable () -> Bool) async throws -> MailMoveOutcome {
        moveCount += 1
        if let moveError { throw moveError }
        return MailMoveOutcome(
            requestID: requestID,
            uid: uid,
            sourceFolder: folder,
            destination: destination,
            mailboxVersion: mailboxVersion,
            destinationUID: "77",
            destinationMailboxVersion: "200",
            expunged: "targeted",
            destinationVerified: true
        )
    }

    func messageIdentity(account: MailAccount, password: String, folder: String,
                         uid: String, mailboxVersion: String,
                         cancelled: @escaping @Sendable () -> Bool) async throws -> MailMessageIdentity {
        MailMessageIdentity(messageID: "<id@example>", byteCount: 123)
    }

    func reconcileMove(account: MailAccount, password: String,
                       provenance: MailMutationJournal.Provenance,
                       cancelled: @escaping @Sendable () -> Bool) async throws -> MailMoveReconciliation {
        reconcileResult
    }

    func message(account: MailAccount, password: String, id: String, folder: String,
                 mailboxVersion: String?,
                 cancelled: @escaping @Sendable () -> Bool) async throws -> Data {
        rawMessage
    }

    func setRead(account: MailAccount, password: String, id: String, folder: String,
                 mailboxVersion: String, read: Bool,
                 cancelled: @escaping @Sendable () -> Bool) async throws {}

    func send(account: MailAccount, password: String, draft: MailDraft, messageID: UUID,
              cancelled: @escaping @Sendable () -> Bool) async throws {
        sendCount += 1
        if let sendError { throw sendError }
        sentDrafts.append(draft)
    }

    func cancelAll() { cancelAllCount += 1 }
    var isIdle: Bool { true }
}

private func rawMailMessage() -> Data {
    Data("""
    Subject: Hello\r
    From: a@example.com\r
    To: b@example.com\r
    Date: now\r
    Content-Type: multipart/mixed; boundary="b"\r
    \r
    --b\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    Body\r
    --b\r
    Content-Type: application/octet-stream\r
    Content-Disposition: attachment; filename="a.bin"\r
    Content-Transfer-Encoding: base64\r
    \r
    AAEC\r
    --b--\r
    """.utf8)
}

private struct Harness {
    let store = FakeMailAccountStore()
    let credentials = FakeMailCredentials()
    let transport: FakeMailTransport
    let root: URL
    let domain: C06MailDomain
    let owner = C06MailOwner(token: "host-token-123", nativeEpoch: 7)

    init() throws {
        transport = FakeMailTransport(rawMessage: rawMailMessage())
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-c06-domain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = self.store
        let credentials = self.credentials
        let transport = self.transport
        let root = self.root
        domain = C06MailDomain(
            storeProvider: { _ in store },
            transportProvider: { _ in transport },
            readiness: { (ready: true, epoch: 7) },
            credentialReader: { reference in await credentials.read(reference) },
            credentialWriter: { reference, value in await credentials.write(reference, value) },
            credentialDeleter: { reference in await credentials.delete(reference) },
            credentialReady: { true },
            rootProvider: { _ in root },
            transportReady: { _ in true },
            closeTransport: { _ in true }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func draft(
        id: UUID? = nil,
        incomingHost: String = "imap.example.com",
        outgoingHost: String = "smtp.example.com",
        incomingSecret: String? = "incoming-pass",
        outgoingSecret: String? = "outgoing-pass"
    ) -> C06MailAccountDraft {
        C06MailAccountDraft(
            id: id,
            displayName: "Test account",
            address: "user@example.com",
            incomingProtocol: .imap,
            incoming: MailServer(host: incomingHost, port: 993, tls: .implicitTLS, username: "user"),
            outgoing: MailServer(host: outgoingHost, port: 465, tls: .implicitTLS, username: "user"),
            incomingSecret: incomingSecret.map { Data($0.utf8) },
            outgoingSecret: outgoingSecret.map { Data($0.utf8) }
        )
    }
}

@Suite("C06 mail account/credential authority")
struct C06MailAccountDomainTests {
    @Test("Account save writes only credential references and lists non-secret settings")
    func saveAndList() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let saved = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        #expect(saved.address == "user@example.com")
        #expect(saved.incoming.host == "imap.example.com")
        let records = try await harness.store.accounts()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.incomingCredentialAccount.hasPrefix("floe.mail."))
        #expect(record.outgoingCredentialAccount.hasPrefix("floe.mail."))
        let hasIncoming = await harness.credentials.contains(record.incomingCredentialAccount)
        let hasOutgoing = await harness.credentials.contains(record.outgoingCredentialAccount)
        #expect(hasIncoming)
        #expect(hasOutgoing)

        let listed = try await harness.domain.listAccounts(owner: harness.owner)
        #expect(listed.count == 1)
        #expect(listed.first?.address == "user@example.com")
    }

    @Test("Changed endpoint without a new password fails before replacing the account")
    func changedEndpointRequiresSecret() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let saved = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        await #expect(throws: C06MailError.self) {
            try await harness.domain.saveAccount(
                harness.draft(
                    id: saved.id,
                    incomingHost: "new-imap.example.com",
                    incomingSecret: nil,
                    outgoingSecret: nil
                ),
                owner: harness.owner
            )
        }
        let after = try await harness.store.account(id: saved.id)
        #expect(after?.account.incoming.host == "imap.example.com")
    }

    @Test("Missing saved credential is typed, not a fake login")
    func missingCredential() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let saved = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let loadedRecord = try await harness.store.account(id: saved.id)
        let record = try #require(loadedRecord)
        await harness.credentials.delete(record.incomingCredentialAccount)
        await #expect(throws: C06MailError.self) {
            try await harness.domain.folders(accountID: saved.id, owner: harness.owner)
        }
        #expect(harness.transport.testCount == 0)
    }

    @Test("Account deletion closes operations and removes both credentials")
    func deleteAccount() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let saved = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let deleted = try await harness.domain.deleteAccount(id: saved.id, owner: harness.owner)
        #expect(deleted)
        let remaining = try await harness.store.accounts()
        #expect(remaining.isEmpty)
        #expect(harness.transport.cancelAllCount >= 1)
    }

    @Test("Temporary and stale owners are refused")
    func ownerFences() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let temporary = C06MailOwner(token: "temporary-token", nativeEpoch: 7, temporary: true)
        await #expect(throws: C06MailError.self) {
            try await harness.domain.listAccounts(owner: temporary)
        }
        let stale = C06MailOwner(token: "stale-token-123", nativeEpoch: 6)
        await #expect(throws: C06MailError.self) {
            try await harness.domain.listAccounts(owner: stale)
        }
    }

    @Test("Root stop drains the domain and retires the owner epoch")
    func rootStop() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        _ = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let report = await harness.domain.rootStop(expectedEpoch: 7)
        #expect(report.drained)
        await #expect(throws: C06MailError.self) {
            try await harness.domain.listAccounts(owner: harness.owner)
        }
    }

    @Test("Real account store round-trips the v51 table")
    func databaseSchemaRoundTrip() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let store = C06MailAccountStore(database: manager)
        let account = MailAccount(
            address: "db@example.com",
            incomingProtocol: .imap,
            incoming: MailServer(host: "imap.example.com", port: 993, tls: .implicitTLS, username: "db"),
            outgoing: MailServer(host: "smtp.example.com", port: 465, tls: .implicitTLS, username: "db")
        )
        let now = Date()
        let record = C06MailAccountRecord(
            account: account,
            displayName: "Database",
            incomingCredentialAccount: "floe.mail.db.incoming.r1",
            outgoingCredentialAccount: "floe.mail.db.outgoing.r1",
            revision: 1,
            createdAt: now,
            updatedAt: now
        )
        try await store.save(record)
        let loaded = try await store.account(id: account.id)
        #expect(loaded?.displayName == "Database")
        #expect(loaded?.account.incoming.host == "imap.example.com")
        try await store.delete(id: account.id)
        let deleted = try await store.account(id: account.id)
        #expect(deleted == nil)
    }
}

@Suite("C06 mail send/move no-replay")
struct C06MailSendMoveDomainTests {
    @Test("Accepted send records one receipt and never resends the same request")
    func sendReplay() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let request = UUID()
        let first = try await harness.domain.send(
            accountID: account.id,
            requestID: request,
            recipients: ["to@example.com"],
            subject: "Hello",
            body: "Body",
            attachments: [],
            draftHandles: [],
            owner: harness.owner
        )
        #expect(first.status == .acceptedByServer)
        #expect(harness.transport.sendCount == 1)
        let second = try await harness.domain.send(
            accountID: account.id,
            requestID: request,
            recipients: ["to@example.com"],
            subject: "Hello",
            body: "Body",
            attachments: [],
            draftHandles: [],
            owner: harness.owner
        )
        #expect(second.status == .acceptedByServer)
        #expect(second.replayed)
        #expect(harness.transport.sendCount == 1)
    }

    @Test("Delivery-unknown is never retried automatically")
    func sendUnknown() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        harness.transport.sendError = .deliveryUnknown
        let request = UUID()
        let first = try await harness.domain.send(
            accountID: account.id,
            requestID: request,
            recipients: ["to@example.com"],
            subject: "Unknown",
            body: "Body",
            attachments: [],
            draftHandles: [],
            owner: harness.owner
        )
        #expect(first.status == .deliveryUnknown)
        let second = try await harness.domain.send(
            accountID: account.id,
            requestID: request,
            recipients: ["to@example.com"],
            subject: "Unknown",
            body: "Body",
            attachments: [],
            draftHandles: [],
            owner: harness.owner
        )
        #expect(second.status == .deliveryUnknownReplay)
        #expect(harness.transport.sendCount == 1)
    }

    @Test("Move is journaled and replayed without a second mutation")
    func moveReplay() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let request = UUID()
        let first = try await harness.domain.move(
            accountID: account.id,
            requestID: request,
            messageID: "9",
            folder: "INBOX",
            mailboxVersion: "100",
            action: "archive",
            destination: nil,
            owner: harness.owner
        )
        #expect(first.status == .completed)
        #expect(harness.transport.moveCount == 1)
        let second = try await harness.domain.move(
            accountID: account.id,
            requestID: request,
            messageID: "9",
            folder: "INBOX",
            mailboxVersion: "100",
            action: "archive",
            destination: nil,
            owner: harness.owner
        )
        #expect(second.status == .completed)
        #expect(second.replayed)
        #expect(harness.transport.moveCount == 1)
    }

    @Test("An unconfirmed move stays mutationUnknown and is not repeated")
    func moveUnknown() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        harness.transport.moveError = .mutationUnknown
        let request = UUID()
        let first = try await harness.domain.move(
            accountID: account.id,
            requestID: request,
            messageID: "9",
            folder: "INBOX",
            mailboxVersion: "100",
            action: "move",
            destination: "Archive",
            owner: harness.owner
        )
        #expect(first.status == .mutationUnknown)
        let second = try await harness.domain.move(
            accountID: account.id,
            requestID: request,
            messageID: "9",
            folder: "INBOX",
            mailboxVersion: "100",
            action: "move",
            destination: "Archive",
            owner: harness.owner
        )
        #expect(second.status == .mutationUnknown)
        #expect(harness.transport.moveCount == 1)
    }

    @Test("Staged compose attachment is verified and sent once")
    func stagedAttachmentSend() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let payload = Data([1, 2, 3, 4, 5])
        let handle = try await harness.domain.beginDraftAttachment(
            accountID: account.id,
            filename: "file.bin",
            byteCount: payload.count,
            sha256: FloeDigest.sha256Hex(payload),
            owner: harness.owner
        )
        try await harness.domain.writeDraftAttachment(
            handle: handle.handle, offset: 0, data: payload, owner: harness.owner
        )
        let finished = try await harness.domain.finishDraftAttachment(
            handle: handle.handle, owner: harness.owner
        )
        #expect(finished.byteCount == payload.count)
        let result = try await harness.domain.send(
            accountID: account.id,
            requestID: UUID(),
            recipients: ["to@example.com"],
            subject: "With attachment",
            body: "Body",
            attachments: [],
            draftHandles: [finished.handle],
            owner: harness.owner
        )
        #expect(result.status == .acceptedByServer)
        #expect(harness.transport.sentDrafts.first?.attachments.first?.data == payload)
    }
}

@Suite("C06 mail read/attachment domain")
struct C06MailReadAttachmentDomainTests {
    @Test("Body page is bounded valid JSON and attachment bytes stream")
    func messageAndAttachment() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let raw = rawMailMessage()
        let page = try await harness.domain.messagePage(
            accountID: account.id,
            folder: "INBOX",
            messageID: "9",
            mailboxVersion: "100",
            bodyCursor: nil,
            owner: harness.owner
        )
        #expect(page.contains("\"contentTrust\":\"untrustedEmail\""))
        #expect(page.contains("\"subject\":\"Hello\""))

        let handle = try await harness.domain.openAttachment(
            accountID: account.id,
            folder: "INBOX",
            messageID: "9",
            mailboxVersion: "100",
            messageSHA256: FloeDigest.sha256Hex(raw),
            attachmentIndex: 0,
            owner: harness.owner
        )
        #expect(handle.filename == "a.bin")
        let byteCount = try await harness.domain.attachmentByteCount(
            handle: handle.handle, owner: harness.owner
        )
        #expect(byteCount == 3)
        let first = try await harness.domain.readAttachment(
            handle: handle.handle, offset: 0, length: 2, owner: harness.owner
        )
        #expect(first == Data([0, 1]))
        let second = try await harness.domain.readAttachment(
            handle: handle.handle, offset: 2, length: 2, owner: harness.owner
        )
        #expect(second == Data([2]))
        await harness.domain.closeAttachment(handle: handle.handle, owner: harness.owner)
    }

    @Test("A changed message digest is rejected before attachment bytes are staged")
    func changedMessageDigest() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        await #expect(throws: C06MailError.self) {
            try await harness.domain.openAttachment(
                accountID: account.id,
                folder: "INBOX",
                messageID: "9",
                mailboxVersion: "100",
                messageSHA256: String(repeating: "0", count: 64),
                attachmentIndex: 0,
                owner: harness.owner
            )
        }
    }

    @Test("Folder/list/search return real typed data")
    func foldersListSearch() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let account = try await harness.domain.saveAccount(harness.draft(), owner: harness.owner)
        let folders = try await harness.domain.folders(accountID: account.id, owner: harness.owner)
        #expect(folders.map(\.name) == ["INBOX", "Archive"])
        let listing = try await harness.domain.list(
            accountID: account.id, folder: "INBOX", afterUID: 0, limit: 20,
            beforeMessageID: nil, owner: harness.owner
        )
        #expect(listing.messages.map(\.id) == ["9"])
        let search = try await harness.domain.search(
            accountID: account.id,
            folder: "INBOX",
            criteria: MailSearchCriteria(text: "body"),
            cursor: nil,
            limit: 20,
            owner: harness.owner
        )
        #expect(search.contains("\"messages\""))
        #expect(search.contains("\"mailboxVersion\":\"100\""))
    }
}
