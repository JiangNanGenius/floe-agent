import Foundation
import XCTest
@testable import FloeExecution

private final class OAuthMailWire: MailWire, @unchecked Sendable {
    var replies: [String]
    var sent: [Data] = []
    var secureAt: Int?
    var failTLS = false
    var closeCount = 0
    init(_ replies: [String]) { self.replies = replies }
    func line() throws -> String {
        guard !replies.isEmpty else { throw MailFailure.connectionFailed }
        return replies.removeFirst()
    }
    func bytes(_ count: Int) throws -> Data { throw MailFailure.protocolRejected }
    func write(_ data: Data) throws { sent.append(data) }
    func secure() throws { if failTLS { throw MailFailure.tlsFailed }; secureAt = sent.count }
    func close() { closeCount += 1 }
    var text: [String] { sent.map { String(decoding: $0, as: UTF8.self) } }
}

final class MailOAuthProtocolTests: XCTestCase, @unchecked Sendable {
    private let bearer = Data("synthetic-native-mail-bearer".utf8)
    private func server(_ provider: MailOAuthProvider = .google, _ service: MailOAuthService = .imap) -> MailServer {
        .init(host: provider == .google ? (service == .imap ? "imap.gmail.com" : "smtp.gmail.com") : (service == .imap ? "outlook.office365.com" : "smtp.office365.com"),
              port: service == .imap ? 993 : provider == .google ? 465 : 587,
              tls: provider == .microsoft && service == .smtp ? .startTLS : .implicitTLS, username: "configured@example.com")
    }
    private func credential(_ endpoint: MailServer, provider: MailOAuthProvider = .google, service: MailOAuthService = .imap) throws -> MailCredential {
        try .xoauth2(accessToken: bearer, provider: provider, service: service, server: endpoint)
    }
    private func reference() -> ExternalOAuthConnectionReference {
        .init(skillID: "floe-google-auth", installationID: "fixture-install", profile: "default", target: "local-linux",
              accountID: UUID(), credentialID: UUID(), revision: 2, partition: "opaque-fixture-partition")
    }
    private func encoded(_ endpoint: MailServer) -> String {
        Data(("user=" + endpoint.username + "\u{1}auth=Bearer " + String(decoding: bearer, as: UTF8.self) + "\u{1}\u{1}").utf8).base64EncodedString()
    }
    func testLegacyAccountAndOpaqueReferenceRoundtripNeverPersistBearer() throws {
        let old = MailAccount(address: "configured@example.com", incoming: server(), outgoing: server(.google, .smtp))
        let legacy = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(MailAccount.self, from: legacy)
        XCTAssertNil(decoded.oauthConnection)
        var connected = old; connected.oauthConnection = reference()
        let data = try JSONEncoder().encode(connected)
        XCTAssertEqual(try JSONDecoder().decode(MailAccount.self, from: data), connected)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(decoding: bearer, as: UTF8.self)))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("access_token"))
        let value = try credential(server())
        XCTAssertFalse(String(describing: value).contains("synthetic"))
        XCTAssertFalse(String(reflecting: value).contains("synthetic"))
        XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
    }
    func testEndpointPortTLSUsernameAndProtocolBindingFailClosed() throws {
        for provider in [MailOAuthProvider.google, .microsoft] {
            for service in [MailOAuthService.imap, .smtp] {
                let good = server(provider, service)
                try MailOAuthPolicy.validate(server: good, provider: provider, service: service)
                for bad in [MailServer(host: good.host + ".attacker.example", port: good.port, tls: good.tls, username: good.username),
                            MailServer(host: "127.0.0.1", port: good.port, tls: good.tls, username: good.username),
                            MailServer(host: good.host, port: 80, tls: good.tls, username: good.username),
                            MailServer(host: good.host, port: good.port, tls: good.tls == .startTLS ? .implicitTLS : .startTLS, username: good.username)] {
                    XCTAssertThrowsError(try credential(bad, provider: provider, service: service))
                }
            }
        }
        let value = try credential(server())
        var edited = server(); edited.username = "different@example.com"
        XCTAssertThrowsError(try value.validate(server: edited, protocolName: "imap"))
        XCTAssertThrowsError(try value.validate(server: server(.google, .smtp), protocolName: "smtp"))
        XCTAssertEqual(MailOAuthPolicy.scopes(provider: .google, service: .imap), ["https://mail.google.com/"])
        XCTAssertEqual(MailOAuthPolicy.scopes(provider: .microsoft, service: .smtp), ["https://outlook.office.com/SMTP.Send"])
        var pop = MailAccount(address: "configured@example.com", incomingProtocol: .pop3, incoming: server(), outgoing: server(.google, .smtp))
        pop.oauthConnection = reference()
        XCTAssertThrowsError(try pop.validate())
    }
    func testIMAPSASLInitialResponseUsesExactBearerFraming() throws {
        let wire = OAuthMailWire(["* OK ready", "* CAPABILITY IMAP4rev1 SASL-IR AUTH=XOAUTH2", "F1 OK capability", "F2 OK authenticated"])
        let endpoint = server()
        try MailProtocolSession(wire: wire).loginIMAP(server: endpoint, credential: credential(endpoint))
        XCTAssertEqual(wire.text, ["F1 CAPABILITY\r\n", "F2 AUTHENTICATE XOAUTH2 " + encoded(endpoint) + "\r\n"])
        XCTAssertFalse(wire.text.contains(where: { $0.contains("LOGIN ") || $0.contains("PLAIN") }))
    }
    func testIMAPContinuationAndErrorChallengeNeverRepeatBearer() throws {
        let endpoint = server(.microsoft)
        let success = OAuthMailWire(["* OK ready", "* CAPABILITY AUTH=XOAUTH2", "F1 OK capability", "+ ", "F2 OK authenticated"])
        try MailProtocolSession(wire: success).loginIMAP(server: endpoint, credential: credential(endpoint, provider: .microsoft))
        XCTAssertEqual(success.text, ["F1 CAPABILITY\r\n", "F2 AUTHENTICATE XOAUTH2\r\n", encoded(endpoint) + "\r\n"])
        let rejected = OAuthMailWire(["* OK ready", "* CAPABILITY AUTH=XOAUTH2", "F1 OK capability", "+ ", "+ provider-error-echo", "F2 NO synthetic-native-mail-bearer"])
        XCTAssertThrowsError(try MailProtocolSession(wire: rejected).loginIMAP(server: endpoint, credential: credential(endpoint, provider: .microsoft))) { error in
            XCTAssertEqual(error as? MailFailure, .authenticationFailed)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-native-mail-bearer"))
        }
        XCTAssertEqual(rejected.text.filter { $0.contains(encoded(endpoint)) }.count, 1)
        XCTAssertEqual(rejected.text.last, "\r\n")
    }
    func testSMTPSTARTTLSRechecksXOAUTH2AfterUpgrade() throws {
        let endpoint = server(.microsoft, .smtp)
        let wire = OAuthMailWire(["220 ready", "250-AUTH LOGIN XOAUTH2", "250 STARTTLS", "220 upgrade", "250-AUTH XOAUTH2", "250 SIZE 100000", "235 authenticated"])
        try MailProtocolSession(wire: wire).loginSMTP(server: endpoint, credential: credential(endpoint, provider: .microsoft, service: .smtp))
        XCTAssertEqual(wire.secureAt, 2)
        XCTAssertEqual(wire.text, ["EHLO floe.local\r\n", "STARTTLS\r\n", "EHLO floe.local\r\n", "AUTH XOAUTH2 " + encoded(endpoint) + "\r\n"])
    }
    func testTLSAndMissingMechanismNeverTransmitBearer() throws {
        let endpoint = server(.microsoft, .smtp)
        for (lines, tlsFailure) in [(["220 ready", "250 STARTTLS", "220 upgrade"], true),
                                  (["220 ready", "250 STARTTLS", "220 upgrade", "250 AUTH LOGIN PLAIN"], false),
                                  (["220 ready", "250 AUTH XOAUTH2"], false)] {
            let wire = OAuthMailWire(lines); wire.failTLS = tlsFailure
            XCTAssertThrowsError(try MailProtocolSession(wire: wire).loginSMTP(server: endpoint, credential: credential(endpoint, provider: .microsoft, service: .smtp)))
            XCTAssertFalse(wire.text.contains(where: { $0.hasPrefix("AUTH ") || $0.contains(encoded(endpoint)) }))
        }
        let imap = OAuthMailWire(["* OK ready", "* CAPABILITY AUTH=XOAUTH2X", "F1 OK capability"])
        XCTAssertThrowsError(try MailProtocolSession(wire: imap).loginIMAP(server: server(), credential: credential(server())))
        XCTAssertEqual(imap.text, ["F1 CAPABILITY\r\n"])
    }
    func testSMTPErrorChallengeSendsEmptyReplyAndNoPasswordFallback() throws {
        let endpoint = server(.google, .smtp)
        let wire = OAuthMailWire(["220 ready", "250 AUTH LOGIN PLAIN XOAUTH2", "334 private-provider-error", "535-first private error", "535 authentication failed"])
        XCTAssertThrowsError(try MailProtocolSession(wire: wire).loginSMTP(server: endpoint, credential: credential(endpoint, service: .smtp))) { error in
            XCTAssertEqual(error as? MailFailure, .authenticationFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-provider-error"))
        }
        XCTAssertEqual(wire.text.last, "\r\n")
        XCTAssertEqual(wire.text.filter { $0.hasPrefix("AUTH ") }.count, 1)
        XCTAssertFalse(wire.text.contains(where: { $0.hasPrefix("AUTH LOGIN") || $0.hasPrefix("AUTH PLAIN") }))
    }
    func testActualMailClientReadsAndSendsWithSameSerialTransport() async throws {
        var account = MailAccount(address: "configured@example.com", incoming: server(), outgoing: server(.google, .smtp))
        account.oauthConnection = reference()
        let read = OAuthMailWire(["* OK ready", "* CAPABILITY SASL-IR AUTH=XOAUTH2", "F1 OK capability", "F2 OK authenticated", "* OK [UIDVALIDITY 9]", "F3 OK selected", "* SEARCH", "F4 OK searched"])
        let page = try await MailClient(wireFactory: { _,_ in read }).list(account: account, credential: credential(account.incoming))
        XCTAssertTrue(page.messages.isEmpty); XCTAssertEqual(page.mailboxVersion, "9"); XCTAssertEqual(read.closeCount, 1)
        let send = OAuthMailWire(["220 ready", "250 AUTH XOAUTH2", "235 authenticated", "250 sender", "250 recipient", "354 send", "250 queued"])
        try await MailClient(wireFactory: { _,_ in send }).send(account: account, credential: credential(account.outgoing, service: .smtp),
            draft: .init(recipients: ["recipient@example.com"], subject: "Synthetic", body: "fixture"), messageID: UUID())
        XCTAssertEqual(send.closeCount, 1)
        XCTAssertEqual(send.text.filter { $0.hasPrefix("MAIL FROM:") }.count, 1)
        XCTAssertEqual(send.text.filter { $0.hasPrefix("AUTH XOAUTH2 ") }.count, 1)
    }
    func testActualMailClientRejectsChangedEndpointAndKeepsPasswordAPI() async throws {
        let endpoint = server()
        let value = try credential(endpoint)
        let unexpected = OAuthMailWire([])
        var changed = endpoint; changed.host = "attacker.example"
        do { try await MailClient(wireFactory: { _,_ in unexpected }).test(server: changed, protocolName: "imap", credential: value); XCTFail("Changed endpoint accepted") }
        catch { XCTAssertEqual(error as? MailFailure, .oauthServerMismatch) }
        XCTAssertTrue(unexpected.sent.isEmpty)
        let legacy = OAuthMailWire(["* OK ready", "F1 OK TLS", "F2 OK authenticated"])
        try await MailClient(wireFactory: { _,_ in legacy }).test(server: .init(host: "password-mail.example", port: 143, tls: .startTLS, username: "legacy-user"), protocolName: "imap", password: "synthetic-password")
        XCTAssertEqual(legacy.text, ["F1 STARTTLS\r\n", "F2 LOGIN \"legacy-user\" \"synthetic-password\"\r\n"])
    }
}
