// FloeExecutionTests — Structured IMAP search and bounded mutations.
//
// All sessions are scripted in-memory wires: no network, no credentials, no
// real mailbox. The tests pin the exact command sequence, the cursor and
// UIDVALIDITY binding, the no-global-expunge guarantee and the unknown-outcome
// classification that the mail tools depend on.

import Foundation
import Testing
@testable import FloeExecution

private final class MutationMailWire: MailWire {
    var lines: [String]
    var chunks: [Data] = []
    var sent: [String] = []
    var secured = false
    init(_ lines: [String]) { self.lines = lines }
    func line() throws -> String {
        guard !lines.isEmpty else { throw MailFailure.connectionFailed }
        return lines.removeFirst()
    }
    func bytes(_ count: Int) throws -> Data {
        guard !chunks.isEmpty, chunks[0].count == count else { throw MailFailure.connectionFailed }
        return chunks.removeFirst()
    }
    func write(_ data: Data) throws { sent.append(String(decoding: data, as: UTF8.self)) }
    func secure() throws { secured = true }
    func close() {}
}

private let imapAccount = MailAccount(
    address: "user@example.com",
    incomingProtocol: .imap,
    incoming: MailServer(host: "imap.example.com", port: 993, username: "user"),
    outgoing: MailServer(host: "smtp.example.com", port: 465, username: "user")
)

private let popAccount = MailAccount(
    address: "user@example.com",
    incomingProtocol: .pop3,
    incoming: MailServer(host: "pop.example.com", port: 995, username: "user"),
    outgoing: MailServer(host: "smtp.example.com", port: 465, username: "user")
)

@Suite("FloeExecution.MailSearchMutation")
struct MailSearchMutationTests {

    // MARK: - Search command construction

    @Test func searchCommandIsStructuredAndBounded() throws {
        let ascii = MailSearchCriteria(
            from: "boss@example.com",
            subject: "Report",
            seen: false,
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let command = try MailClient.searchCommand(ascii)
        #expect(command.hasPrefix("UID SEARCH "))
        #expect(command.contains("FROM \"boss@example.com\""))
        #expect(command.contains("SUBJECT \"Report\""))
        #expect(command.contains("UNSEEN"))
        #expect(command.contains("SINCE 14-Nov-2023"))
        #expect(!command.contains("CHARSET"))

        let unicode = MailSearchCriteria(text: "会议纪要")
        let utf8Command = try MailClient.searchCommand(unicode)
        #expect(utf8Command.hasPrefix("UID SEARCH CHARSET UTF-8 "))
        #expect(utf8Command.contains("TEXT "))

        for hostile in ["line\r\nbreak", "nul\0byte"] {
            #expect(throws: MailFailure.self) {
                try MailClient.searchCommand(MailSearchCriteria(subject: hostile))
            }
        }
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailClient.searchCommand(MailSearchCriteria())
        }
    }

    @Test func searchCursorRoundTripsAndRejectsTampering() throws {
        let cursor = MailClient.SearchCursor(
            v: 1,
            accountID: UUID(),
            folder: "INBOX",
            mailboxVersion: "777",
            uid: 42,
            criteriaKey: "UID SEARCH SUBJECT \"Report\""
        )
        let token = MailClient.encodeSearchCursor(cursor)
        #expect(token.hasPrefix("msc1."))
        #expect(try MailClient.decodeSearchCursor(token).uid == 42)
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailClient.decodeSearchCursor("not-a-cursor")
        }
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailClient.decodeSearchCursor("msc1." + Data("garbage".utf8).base64EncodedString())
        }
    }

    // MARK: - Search conversation

    @Test func searchPagesDescendingWithUidValidityBinding() throws {
        let wire = MutationMailWire([
            "* 5 EXISTS", "[UIDVALIDITY 777]", "F1 OK [UIDVALIDITY 777] selected",
            "* SEARCH 3 5 7 9 11", "F2 OK search done",
            "* 1 FETCH (UID 11 RFC822.SIZE 100 FLAGS (\\Seen))",
            "* 2 FETCH (UID 9 RFC822.SIZE 90 FLAGS ())",
            "F3 OK fetch done"
        ])
        let page = try MailClient.performSearch(
            session: MailProtocolSession(wire: wire),
            accountID: imapAccount.id,
            folder: "INBOX",
            criteria: MailSearchCriteria(subject: "Report"),
            cursor: nil,
            limit: 2
        )
        #expect(page.mailboxVersion == "777")
        #expect(page.messages.map(\.id) == ["11", "9"])
        #expect(page.hasMore)
        #expect(page.totalMatched == 5)
        let cursor = try #require(page.nextCursor)

        // Continuation uses the same UIDVALIDITY and resumes below the last
        // returned UID.
        let wire2 = MutationMailWire([
            "* 5 EXISTS", "[UIDVALIDITY 777]", "F1 OK [UIDVALIDITY 777] selected",
            "* SEARCH 3 5 7 9 11", "F2 OK search done",
            "* 1 FETCH (UID 7 RFC822.SIZE 70 FLAGS ())",
            "* 2 FETCH (UID 5 RFC822.SIZE 50 FLAGS ())",
            "F3 OK fetch done"
        ])
        let second = try MailClient.performSearch(
            session: MailProtocolSession(wire: wire2),
            accountID: imapAccount.id,
            folder: "INBOX",
            criteria: MailSearchCriteria(subject: "Report"),
            cursor: cursor,
            limit: 2
        )
        #expect(second.messages.map(\.id) == ["7", "5"])
        #expect(second.hasMore)

        // A changed mailbox identity is an explicit failure, not mixed data.
        let wire3 = MutationMailWire([
            "* 5 EXISTS", "[UIDVALIDITY 888]", "F1 OK [UIDVALIDITY 888] selected"
        ])
        #expect(throws: MailFailure.mailboxChanged) {
            try MailClient.performSearch(
                session: MailProtocolSession(wire: wire3),
                accountID: imapAccount.id,
                folder: "INBOX",
                criteria: MailSearchCriteria(subject: "Report"),
                cursor: cursor,
                limit: 2
            )
        }

        // Account drift and criteria drift are explicit mismatches.
        let wire4 = MutationMailWire([
            "* 5 EXISTS", "[UIDVALIDITY 777]", "F1 OK [UIDVALIDITY 777] selected"
        ])
        #expect(throws: MailFailure.cursorMismatch) {
            try MailClient.performSearch(
                session: MailProtocolSession(wire: wire4),
                accountID: UUID(),
                folder: "INBOX",
                criteria: MailSearchCriteria(subject: "Report"),
                cursor: cursor,
                limit: 2
            )
        }
        let wire5 = MutationMailWire([
            "* 5 EXISTS", "[UIDVALIDITY 777]", "F1 OK [UIDVALIDITY 777] selected"
        ])
        #expect(throws: MailFailure.cursorMismatch) {
            try MailClient.performSearch(
                session: MailProtocolSession(wire: wire5),
                accountID: imapAccount.id,
                folder: "INBOX",
                criteria: MailSearchCriteria(subject: "Different"),
                cursor: cursor,
                limit: 2
            )
        }
        let wire6 = MutationMailWire([
            "* 5 EXISTS", "[UIDVALIDITY 777]", "F1 OK [UIDVALIDITY 777] selected"
        ])
        #expect(throws: MailFailure.cursorMismatch) {
            try MailClient.performSearch(
                session: MailProtocolSession(wire: wire6),
                accountID: imapAccount.id,
                folder: "Archive",
                criteria: MailSearchCriteria(subject: "Report"),
                cursor: cursor,
                limit: 2
            )
        }
    }

    // MARK: - Move conversation

    @Test func atomicMoveUsesMoveExtension() throws {
        let wire = MutationMailWire([
            "* CAPABILITY IMAP4rev1 MOVE UIDPLUS", "F1 OK cap",
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F2 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F3 OK fetch",
            "* LIST (\\HasNoChildren) \"/\" \"Archive\"", "F4 OK list",
            "* OK [COPYUID 55 7 3] moved", "F5 OK move",
            "F6 OK no match",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F7 OK [UIDVALIDITY 55] selected",
            "* 1 FETCH (UID 3 RFC822.SIZE 100 FLAGS ())", "F8 OK fetch"
        ])
        let outcome = try MailClient.performMove(
            session: MailProtocolSession(wire: wire),
            requestID: UUID(),
            uid: "7",
            numericUID: 7,
            folder: "INBOX",
            destination: "Archive",
            mailboxVersion: "42"
        )
        #expect(outcome.expunged == "targeted")
        #expect(outcome.destinationUID == "3")
        #expect(outcome.destinationMailboxVersion == "55")
        #expect(outcome.destinationVerified)
        #expect(wire.sent.contains { $0.contains("UID MOVE 7") })
        #expect(!wire.sent.contains { $0.uppercased().contains("EXPUNGE") })
    }

    @Test func copyPathUsesTargetedExpungeWhenUidPlusIsAvailable() throws {
        let wire = MutationMailWire([
            "* CAPABILITY IMAP4rev1 UIDPLUS", "F1 OK cap",
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F2 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F3 OK fetch",
            "* LIST (\\HasNoChildren) \"/\" \"Archive\"", "F4 OK list",
            "* OK [COPYUID 55 7 9] copied", "F5 OK copy",
            "F6 OK stored",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS (\\Deleted))", "F7 OK fetch",
            "F8 OK expunged",
            "F9 OK no match",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F10 OK [UIDVALIDITY 55] selected",
            "* 1 FETCH (UID 9 RFC822.SIZE 100 FLAGS ())", "F11 OK fetch"
        ])
        let outcome = try MailClient.performMove(
            session: MailProtocolSession(wire: wire),
            requestID: UUID(),
            uid: "7",
            numericUID: 7,
            folder: "INBOX",
            destination: "Archive",
            mailboxVersion: "42"
        )
        #expect(outcome.expunged == "targeted")
        #expect(outcome.destinationUID == "9")
        #expect(outcome.destinationVerified)
        #expect(wire.sent.contains("F6 UID STORE 7 +FLAGS.SILENT (\\Deleted)\r\n"))
        #expect(wire.sent.contains("F8 UID EXPUNGE 7\r\n"))
        #expect(!wire.sent.contains("F8 EXPUNGE\r\n"))
    }

    @Test func withoutUidPlusNoExpungeIsEverSent() throws {
        let wire = MutationMailWire([
            "* CAPABILITY IMAP4rev1", "F1 OK cap",
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F2 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F3 OK fetch",
            "* LIST (\\HasNoChildren) \"/\" \"Archive\"", "F4 OK list",
            "F5 OK copied",
            "F6 OK stored",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS (\\Deleted))", "F7 OK fetch",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F8 OK [UIDVALIDITY 55] selected"
        ])
        let outcome = try MailClient.performMove(
            session: MailProtocolSession(wire: wire),
            requestID: UUID(),
            uid: "7",
            numericUID: 7,
            folder: "INBOX",
            destination: "Archive",
            mailboxVersion: "42"
        )
        #expect(outcome.expunged == "notSupported")
        #expect(outcome.destinationUID == nil)
        #expect(!outcome.destinationVerified)
        #expect(!wire.sent.contains { $0.uppercased().contains("EXPUNGE") })
    }

    @Test func transportLossAfterMutationIsUnknownNotFailure() {
        // The COPY reply never arrives: the command may have reached the
        // server, so the outcome must be `mutationUnknown`.
        let wire = MutationMailWire([
            "* CAPABILITY IMAP4rev1", "F1 OK cap",
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F2 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F3 OK fetch",
            "* LIST (\\HasNoChildren) \"/\" \"Archive\"", "F4 OK list"
        ])
        #expect(throws: MailFailure.mutationUnknown) {
            try MailClient.performMove(
                session: MailProtocolSession(wire: wire),
                requestID: UUID(),
                uid: "7",
                numericUID: 7,
                folder: "INBOX",
                destination: "Archive",
                mailboxVersion: "42"
            )
        }
    }

    @Test func moveFailsBeforeMutationOnChangedMailbox() {
        let wire = MutationMailWire([
            "* CAPABILITY IMAP4rev1", "F1 OK cap",
            "* 2 EXISTS", "[UIDVALIDITY 43]", "F2 OK [UIDVALIDITY 43] selected"
        ])
        #expect(throws: MailFailure.mailboxChanged) {
            try MailClient.performMove(
                session: MailProtocolSession(wire: wire),
                requestID: UUID(),
                uid: "7",
                numericUID: 7,
                folder: "INBOX",
                destination: "Archive",
                mailboxVersion: "42"
            )
        }
        #expect(!wire.sent.contains { $0.contains("COPY") || $0.contains("MOVE ") || $0.contains("STORE") })
    }

    // MARK: - Folder attributes and POP3 honesty

    @Test func folderAttributesParseSpecialUseAndQuotedNames() throws {
        let wire = MutationMailWire([
            "* LIST (\\HasNoChildren \\Trash) \"/\" \"Trash\"",
            "* LIST (\\HasNoChildren) \"/\" \"Archive\"",
            "* LIST () \"/\" \"My \\\"Quoted\\\" Folder\"",
            "F1 OK list"
        ])
        let folders = try MailClient.folderInfos(session: MailProtocolSession(wire: wire))
        #expect(folders.count == 3)
        #expect(folders[0].name == "Trash")
        #expect(folders[0].attributes.contains("\\TRASH"))
        #expect(folders[1].name == "Archive")
        #expect(folders[2].name == "My \"Quoted\" Folder")
    }

    @Test func pop3ReportsUnsupportedWithoutOpeningASession() async {
        let client = MailClient()
        await #expect(throws: MailFailure.unsupportedForPOP3) {
            _ = try await client.search(
                account: popAccount,
                password: "fixture-secret",
                criteria: MailSearchCriteria(subject: "x")
            )
        }
        await #expect(throws: MailFailure.unsupportedForPOP3) {
            _ = try await client.specialFolder(
                account: popAccount,
                password: "fixture-secret",
                kind: .trash
            )
        }
        await #expect(throws: MailFailure.unsupportedForPOP3) {
            _ = try await client.move(
                account: popAccount,
                password: "fixture-secret",
                requestID: UUID(),
                uid: "7",
                folder: "INBOX",
                destination: "Archive",
                mailboxVersion: "42"
            )
        }
    }

    @Test func searchGuardsRunBeforeAnyTransport() async {
        let client = MailClient()
        await #expect(throws: MailFailure.invalidConfiguration) {
            _ = try await client.search(
                account: imapAccount,
                password: "fixture-secret",
                criteria: MailSearchCriteria(subject: "x"),
                limit: 51
            )
        }
        await #expect(throws: MailFailure.invalidConfiguration) {
            _ = try await client.search(
                account: imapAccount,
                password: "fixture-secret",
                criteria: MailSearchCriteria()
            )
        }
        // A cursor page must repeat the criteria; an empty continuation is a
        // definite configuration error, never an implicit stored query.
        await #expect(throws: MailFailure.invalidConfiguration) {
            _ = try await client.search(
                account: imapAccount,
                password: "fixture-secret",
                criteria: MailSearchCriteria(),
                cursor: "msc1.abc"
            )
        }
    }

    // MARK: - Mutation journal

    @Test func mutationJournalNeverAuthorizesBlindReplay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mail-mutation-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "a", count: 64)
        let journal = MailMutationJournal(directory: root)
        let id = UUID()
        #expect(try journal.reserve(requestID: id, digest: digest) == nil)
        #expect(try journal.reserve(requestID: id, digest: digest) == .mutationUnknown)
        try journal.finish(requestID: id, digest: digest, state: .completed)
        #expect(try journal.reserve(requestID: id, digest: digest) == .completed)
        #expect(throws: MailFailure.invalidMessage) {
            try journal.reserve(requestID: id, digest: String(repeating: "b", count: 64))
        }
    }

    @Test func mutationJournalCorruptReceiptFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mail-mutation-corrupt-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let file = root.appendingPathComponent("mutation-" + id.uuidString + ".json")
        try Data("partial".utf8).write(to: file)
        #expect(throws: MailFailure.invalidMessage) {
            try MailMutationJournal(directory: root).reserve(
                requestID: id,
                digest: String(repeating: "a", count: 64)
            )
        }
        #expect(try Data(contentsOf: file) == Data("partial".utf8))
    }

    // MARK: - Message identity

    @Test func messageIdentityParsesHeaderAndSize() throws {
        let header = "Message-ID: <stable-id@example.com>\r\n\r\n"
        let chunk = Data(header.utf8)
        let wire = MutationMailWire([
            "* 1 FETCH (UID 7 RFC822.SIZE 4242 BODY[HEADER.FIELDS (MESSAGE-ID)] {\(chunk.count)}",
            "F1 OK fetch"
        ])
        wire.chunks = [chunk]
        let identity = try MailClient.performMessageIdentity(
            session: MailProtocolSession(wire: wire),
            uid: 7
        )
        #expect(identity.messageID == "stable-id@example.com")
        #expect(identity.byteCount == 4242)
    }

    @Test func messageIdentityFallsBackToSizeWhenHeaderFetchIsRejected() throws {
        let wire = MutationMailWire([
            "F1 NO unsupported",
            "* 1 FETCH (UID 7 RFC822.SIZE 99)",
            "F2 OK fetch"
        ])
        let identity = try MailClient.performMessageIdentity(
            session: MailProtocolSession(wire: wire),
            uid: 7
        )
        #expect(identity.messageID == nil)
        #expect(identity.byteCount == 99)
    }

    // MARK: - Move reconciliation (read-only)

    private let provenance = MailMutationJournal.Provenance(
        accountID: UUID(),
        action: "move",
        sourceFolder: "INBOX",
        destination: "Archive",
        uid: "7",
        mailboxVersion: "42",
        messageID: "stable-id@example.com",
        byteCount: 100
    )

    @Test func reconcileProvesNotSubmittedWhenNothingCopied() throws {
        let wire = MutationMailWire([
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F1 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F2 OK fetch",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F3 OK [UIDVALIDITY 55] selected",
            "* SEARCH", "F4 OK search"
        ])
        let result = try MailClient.performReconcileMove(
            session: MailProtocolSession(wire: wire),
            uid: 7,
            provenance: provenance
        )
        #expect(result == .notSubmitted)
        #expect(!wire.sent.contains { $0.contains("COPY") || $0.contains("MOVE ") || $0.contains("STORE") || $0.uppercased().contains("EXPUNGE") })
    }

    @Test func reconcileProvesCompletedWhenSourceGoneAndCopyFound() throws {
        let wire = MutationMailWire([
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F1 OK [UIDVALIDITY 42] selected",
            "F2 OK no match",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F3 OK [UIDVALIDITY 55] selected",
            "* SEARCH 12", "F4 OK search",
            "* 1 FETCH (UID 12 RFC822.SIZE 100 FLAGS ())", "F5 OK fetch"
        ])
        let result = try MailClient.performReconcileMove(
            session: MailProtocolSession(wire: wire),
            uid: 7,
            provenance: provenance
        )
        #expect(result == .completed(destinationUID: "12", destinationMailboxVersion: "55"))
    }

    @Test func reconcileProvesCompletedWhenSourceDeletedAndCopyFound() throws {
        let wire = MutationMailWire([
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F1 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS (\\Deleted))", "F2 OK fetch",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F3 OK [UIDVALIDITY 55] selected",
            "* SEARCH 12", "F4 OK search",
            "* 1 FETCH (UID 12 RFC822.SIZE 100 FLAGS ())", "F5 OK fetch"
        ])
        let result = try MailClient.performReconcileMove(
            session: MailProtocolSession(wire: wire),
            uid: 7,
            provenance: provenance
        )
        #expect(result == .completed(destinationUID: "12", destinationMailboxVersion: "55"))
    }

    @Test func reconcileStaysAmbiguousWhenCopyExistsButSourceIntact() throws {
        let wire = MutationMailWire([
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F1 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F2 OK fetch",
            "* 1 EXISTS", "[UIDVALIDITY 55]", "F3 OK [UIDVALIDITY 55] selected",
            "* SEARCH 12", "F4 OK search",
            "* 1 FETCH (UID 12 RFC822.SIZE 100 FLAGS ())", "F5 OK fetch"
        ])
        guard case .ambiguous(let reason) = try MailClient.performReconcileMove(
            session: MailProtocolSession(wire: wire),
            uid: 7,
            provenance: provenance
        ) else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(reason.contains("not marked deleted"))
    }

    @Test func reconcileStaysAmbiguousOnMailboxChangeOrMissingIdentity() throws {
        let changed = MutationMailWire([
            "* 2 EXISTS", "[UIDVALIDITY 43]", "F1 OK [UIDVALIDITY 43] selected"
        ])
        guard case .ambiguous(let changedReason) = try MailClient.performReconcileMove(
            session: MailProtocolSession(wire: changed),
            uid: 7,
            provenance: provenance
        ) else {
            Issue.record("expected ambiguous on mailbox change")
            return
        }
        #expect(changedReason.contains("identity changed"))

        var noIdentity = provenance
        noIdentity.messageID = nil
        let noIdentityWire = MutationMailWire([
            "* 2 EXISTS", "[UIDVALIDITY 42]", "F1 OK [UIDVALIDITY 42] selected",
            "* 1 FETCH (UID 7 RFC822.SIZE 100 FLAGS ())", "F2 OK fetch"
        ])
        guard case .ambiguous(let identityReason) = try MailClient.performReconcileMove(
            session: MailProtocolSession(wire: noIdentityWire),
            uid: 7,
            provenance: noIdentity
        ) else {
            Issue.record("expected ambiguous without identity")
            return
        }
        #expect(identityReason.contains("no stable message identity"))
    }

    // MARK: - Journal provenance and the single safe-clear path

    @Test func journalPersistsProvenanceAndOnlyClearsProvenNotStarted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mail-mutation-prov-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "a", count: 64)
        let journal = MailMutationJournal(directory: root)
        let id = UUID()
        #expect(try journal.reserve(requestID: id, digest: digest, provenance: provenance) == nil)
        #expect(try journal.provenance(requestID: id, digest: digest) == provenance)

        // Unknown state can never be cleared.
        #expect(throws: MailFailure.invalidMessage) {
            try journal.clear(requestID: id, digest: digest)
        }
        // Only a proven notSubmitted receipt can be cleared, once.
        try journal.finish(requestID: id, digest: digest, state: .notStarted)
        try journal.clear(requestID: id, digest: digest)
        #expect(try journal.reserve(requestID: id, digest: digest, provenance: provenance) == nil)
    }

    @Test func legacyReceiptWithoutProvenanceStillFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mail-mutation-legacy-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let digest = String(repeating: "a", count: 64)
        let legacy = Data("{\"digest\":\"\(digest)\",\"state\":\"mutationUnknown\"}".utf8)
        try legacy.write(to: root.appendingPathComponent("mutation-" + id.uuidString + ".json"))
        let journal = MailMutationJournal(directory: root)
        #expect(try journal.reserve(requestID: id, digest: digest) == .mutationUnknown)
        #expect(try journal.provenance(requestID: id, digest: digest) == nil)
    }

    // MARK: - Bounded tool-boundary JSON

    private func searchPage(
        ids: [UInt32],
        flags: [String] = []
    ) -> MailSearchPage {
        MailSearchPage(
            folder: "INBOX",
            mailboxVersion: "777",
            messages: ids.map {
                MailMessageReference(id: String($0), byteCount: 1_000, flags: flags)
            },
            hasMore: false,
            nextCursor: nil,
            totalMatched: ids.count
        )
    }

    @Test func boundedSearchPageJSONKeepsValidJSONAndCursorAligned() throws {
        let accountID = UUID()
        let key = "UID SEARCH SUBJECT \"Report\""

        // Normal small page: unchanged fields, complete rows.
        let small = searchPage(ids: [11, 9, 7, 5, 3])
        let smallText = MailClient.boundedSearchPageJSON(
            page: small, accountID: accountID, folder: "INBOX", criteriaKey: key
        )
        #expect(smallText.count <= 4_096)
        let smallObject = try #require(
            try JSONSerialization.jsonObject(with: Data(smallText.utf8)) as? [String: Any]
        )
        #expect(smallObject["returned"] as? Int == 5)
        #expect(smallObject["available"] as? Int == 5)
        #expect(smallObject["pageTruncated"] as? Bool == false)
        #expect(smallObject["mailboxVersion"] as? String == "777")
        #expect((smallObject["messages"] as? [[String: Any]])?.count == 5)

        // 50 rows with long flag lists: the JSON stays valid and bounded, and
        // the continuation cursor is recomputed from the LAST EMITTED UID so
        // the withheld messages are not skipped.
        let longFlags = (0..<20).map { "\\VeryLongFlagNameNumber\($0)" }
        let large = searchPage(ids: (0..<50).map { 1_000 - UInt32($0) }, flags: longFlags)
        let largeText = MailClient.boundedSearchPageJSON(
            page: large, accountID: accountID, folder: "INBOX", criteriaKey: key
        )
        #expect(largeText.count <= 4_096)
        let largeObject = try #require(
            try JSONSerialization.jsonObject(with: Data(largeText.utf8)) as? [String: Any]
        )
        let returned = try #require(largeObject["returned"] as? Int)
        #expect(returned < 50)
        #expect(largeObject["pageTruncated"] as? Bool == true)
        #expect(largeObject["hasMore"] as? Bool == true)
        let rows = try #require(largeObject["messages"] as? [[String: Any]])
        #expect(rows.count == returned)
        let cursorToken = try #require(largeObject["nextCursor"] as? String)
        let cursor = try MailClient.decodeSearchCursor(cursorToken)
        #expect(cursor.uid == UInt32(rows.last?["id"] as? String ?? ""))
        #expect(cursor.mailboxVersion == "777")
        #expect(cursor.accountID == accountID)
        #expect(cursor.criteriaKey == key)
        // Every withheld UID is strictly below the cursor: continuing cannot
        // skip them.
        let emitted = Set(rows.compactMap { $0["id"] as? String })
        let withheld = large.messages.map(\.id).filter { !emitted.contains($0) }
        #expect(withheld.allSatisfy { (UInt32($0) ?? 0) < cursor.uid })
        #expect(emitted.count + withheld.count == 50)
    }
}
