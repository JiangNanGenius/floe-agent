import Foundation
import Testing
@testable import FloeExecution

private final class ScriptedMailWire: MailWire {
    var lines: [String]
    var chunks: [Data] = []
    var sent: [String] = []
    var secured = false
    var failTLS = false
    init(_ lines: [String]) { self.lines = lines }
    func line() throws -> String {
        guard !lines.isEmpty else { throw MailFailure.connectionFailed }; return lines.removeFirst()
    }
    func bytes(_ count: Int) throws -> Data {
        guard !chunks.isEmpty, chunks[0].count == count else { throw MailFailure.connectionFailed }
        return chunks.removeFirst()
    }
    func write(_ data: Data) throws { sent.append(String(decoding: data, as: UTF8.self)) }
    func secure() throws { if failTLS { throw MailFailure.tlsFailed }; secured = true }
    func close() {}
}

@Suite("FloeExecution.MailProtocol")
struct MailProtocolTests {
    @Test func endpointValidation() throws {
        try MailServer(host: "mail.example.com", port: 993, username: "test@example.com").validate()
        for host in ["", "https://mail.example.com", "user@mail.example.com", "x\r\nNOOP", "a/b", "mail\0.example.com"] {
            #expect(throws: MailFailure.invalidConfiguration) { try MailServer(host: host, port: 993, username: "user").validate() }
        }
        #expect(throws: MailFailure.invalidConfiguration) { try MailServer(host: "mail.example.com", port: 65536, username: "user").validate() }
    }
    @Test func commandInjectionRejected() throws {
        #expect(throws: MailFailure.invalidMessage) { try MailProtocolSession.quoted("INBOX\r\nDELETE INBOX") }
        #expect(throws: MailFailure.invalidAddress) { try MailAccount.validateAddress("a@b>\r\nRCPT TO:<c@d") }
        #expect(try MailProtocolSession.quoted("a\\b\"c") == "\"a\\\\b\\\"c\"")
    }
    @Test func imapStartTLSBeforeAuthentication() throws {
        let wire = ScriptedMailWire(["* OK ready", "F1 OK TLS", "F2 OK login"])
        try MailProtocolSession(wire: wire).loginIMAP(server: .init(host: "mail.example.com", port: 143, tls: .startTLS, username: "user"), password: "test-password")
        #expect(wire.secured)
        #expect(wire.sent.first == "F1 STARTTLS\r\n")
        #expect(wire.sent.last?.hasPrefix("F2 LOGIN") == true)
    }
    @Test func failedTLSNeverSendsPassword() {
        let wire = ScriptedMailWire(["* OK ready", "F1 OK TLS"]); wire.failTLS = true
        #expect(throws: MailFailure.tlsFailed) {
            try MailProtocolSession(wire: wire).loginIMAP(server: .init(host: "example.com", port: 143, tls: .startTLS, username: "user"), password: "test-secret")
        }
        #expect(wire.sent == ["F1 STARTTLS\r\n"])
    }
    @Test func authenticationFailureDoesNotLeakServerEcho() {
        let wire = ScriptedMailWire(["* OK ready", "F1 NO test-secret was rejected"])
        #expect(throws: MailFailure.authenticationFailed) {
            try MailProtocolSession(wire: wire).loginIMAP(server: .init(host: "example.com", port: 993, username: "user"), password: "test-secret")
        }
        #expect(!MailFailure.authenticationFailed.localizedDescription.contains("test-secret"))
    }
    @Test func imapLiteralFramingAndLimits() throws {
        let wire = ScriptedMailWire(["* 1 FETCH (BODY[] {5}", ")", "F1 OK done"])
        wire.chunks = [Data("hello".utf8)]
        #expect(try MailProtocolSession(wire: wire).imap("UID FETCH 1 (BODY.PEEK[])").literals == [Data("hello".utf8)])
        let oversized = ScriptedMailWire(["* 1 FETCH (BODY[] {99999999}"])
        #expect(throws: MailFailure.responseTooLarge) { try MailProtocolSession(wire: oversized).imap("UID FETCH 1 (BODY.PEEK[])") }
    }
    @Test func popDotUnstuffingAndNoDelete() throws {
        let wire = ScriptedMailWire(["+OK ready", "+OK TLS", "+OK user", "+OK pass", "+OK data", "..first", "body", "."])
        let session = MailProtocolSession(wire: wire)
        try session.loginPOP(server: .init(host: "example.com", port: 110, tls: .startTLS, username: "user"), password: "test")
        #expect(try session.popLines("RETR 1") == [".first", "body"])
        #expect(wire.secured)
        #expect(!wire.sent.contains(where: { $0.hasPrefix("DELE") }))
    }
    @Test func smtpStartTLSRechecksCapabilities() throws {
        let wire = ScriptedMailWire(["220 ready", "250-example.com", "250 STARTTLS", "220 upgrade", "250-example.com", "250 AUTH PLAIN", "334 ", "235 accepted"])
        try MailProtocolSession(wire: wire).loginSMTP(server: .init(host: "example.com", port: 587, tls: .startTLS, username: "user"), password: "test")
        #expect(wire.sent.filter { $0.hasPrefix("EHLO") }.count == 2)
        #expect(wire.secured)
    }
    @Test func smtpRefusesMissingTLS() {
        let wire = ScriptedMailWire(["220 ready", "250 AUTH PLAIN"])
        #expect(throws: MailFailure.tlsFailed) {
            try MailProtocolSession(wire: wire).loginSMTP(server: .init(host: "example.com", port: 587, tls: .startTLS, username: "user"), password: "test")
        }
        #expect(!wire.sent.contains(where: { $0.contains("AUTH") }))
    }
    @Test func smtpSendAcceptedAndUnknownAreDifferent() throws {
        let draft = MailDraft(recipients: ["recipient@example.com"], subject: "Hello", body: ".\r\nTest")
        let success = ScriptedMailWire(["250 sender", "250 recipient", "354 send", "250 queued"])
        try MailProtocolSession(wire: success).send(from: "sender@example.com", draft: draft, messageID: UUID())
        #expect(success.sent.last == ".\r\n")
        let unknown = ScriptedMailWire(["250 sender", "250 recipient", "354 send"])
        #expect(throws: MailFailure.deliveryUnknown) {
            try MailProtocolSession(wire: unknown).send(from: "sender@example.com", draft: draft, messageID: UUID())
        }
    }
    @Test func rejectsDraftHeaderInjection() {
        #expect(throws: MailFailure.invalidMessage) {
            try MailDraft(recipients: ["a@b.com"], subject: "test\r\nBcc: hidden@example.com", body: "").validate()
        }
    }
    @Test func mimePreservesUnicodeAndBinaryAttachment() throws {
        let draft = MailDraft(recipients: ["a@example.com"], subject: String(repeating: "邮件", count: 30), body: "你好",
                              attachments: [.init(filename: "资料.bin", data: Data([0, 255, 1]))])
        let text = String(decoding: try draft.encoded(from: "b@example.com", messageID: UUID()), as: UTF8.self)
        #expect(text.contains("5L2g5aW9")); #expect(text.contains("AP8B"))
        #expect(text.contains("filename*=UTF-8''"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count < 998 })
        let decoded = try MailMIME.decode(Data(text.utf8))
        #expect(decoded.subject == draft.subject)
        #expect(decoded.text.trimmingCharacters(in: .whitespacesAndNewlines) == "你好")
        #expect(decoded.attachments.count == 1)
        #expect(decoded.attachments.first?.filename == "资料.bin")
        #expect(decoded.attachments.first?.data == Data([0, 255, 1]))
    }
    @Test func mimeQuotedPrintableAndInertHTML() throws {
        let text = "Subject: =?UTF-8?B?5L2g5aW9?=\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<img src=3D\"https://example.com/tracker\">=E4=BD=A0=E5=A5=BD"
        let decoded = try MailMIME.decode(Data(text.utf8))
        #expect(decoded.subject == "你好")
        #expect(decoded.html.contains("<img src=\"https://example.com/tracker\">你好"))
        #expect(decoded.text.isEmpty)
    }
    @Test func mimeRejectsBrokenBoundaryAndDuplicateStructuralHeader() {
        for text in ["Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nmissing closing boundary",
                     "Content-Type: text/plain\r\nContent-Type: text/html\r\n\r\ntest"] {
            #expect(throws: MailFailure.invalidMessage) { try MailMIME.decode(Data(text.utf8)) }
        }
    }

    @Test func imapReadStateRequiresReadback() throws {
        let wire = ScriptedMailWire(["F1 OK stored", "* 1 FETCH (UID 8 FLAGS (\\Seen))", "F2 OK fetched"])
        try MailProtocolSession(wire: wire).setRead(uid: 8, read: true)
        #expect(wire.sent.last == "F2 UID FETCH 8 (UID FLAGS)\r\n")
        let missing = ScriptedMailWire(["F1 OK stored", "F2 OK no matches"])
        #expect(throws: MailFailure.messageNotFound) { try MailProtocolSession(wire: missing).setRead(uid: 8, read: true) }
        let unchanged = ScriptedMailWire(["F1 OK stored", "* 1 FETCH (UID 8 FLAGS ())", "F2 OK fetched"])
        #expect(throws: MailFailure.mailboxChanged) { try MailProtocolSession(wire: unchanged).setRead(uid: 8, read: true) }
    }

    @Test func popStableCursorAndDeletionConflict() throws {
        let ids = [1: "one", 2: "two", 3: "three"]
        let first = try MailClient.popPage(ids: ids, sizes: [(1, 1), (2, 2), (3, 3)], before: nil, limit: 2)
        #expect(first.messages.map(\.id) == ["three", "two"])
        #expect(first.nextBeforeMessageID == "two")
        let second = try MailClient.popPage(ids: ids, sizes: [(1, 1), (2, 2), (3, 3)], before: "two", limit: 2)
        #expect(second.messages.map(\.id) == ["one"]); #expect(!second.hasMore)
        #expect(throws: MailFailure.mailboxChanged) { try MailClient.popPage(ids: [1: "one"], sizes: [(1, 1)], before: "two", limit: 2) }
    }
}
