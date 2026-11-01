// SPDX-License-Identifier: MPL-2.0
//
// Synchronous mail wire + protocol conversation (Android port).
//
// The fixed public donor used CFStream behind `canImport(CFNetwork)`. Android
// has no CFNetwork/Stream TLS transport, so the production wire is the
// Swift-owned, bounded `MailTransportMailbox` in
// `MailTransportMailbox.swift`: the trusted App host owns the platform
// SSLSocket lane and settles exactly one native ticket at a time. Protocol
// parsing, STARTTLS ordering and authentication below are the donor
// semantics and are identical for the production wire and scripted tests.

import Foundation

/// Synchronous transport used only on MailClient's dedicated utility queue.
/// A scriptable boundary keeps protocol tests independent of real
/// credentials and sockets.
public protocol MailWire: AnyObject {
    func line() throws -> String
    func rawLine() throws -> Data
    func bytes(_ count: Int) throws -> Data
    func write(_ data: Data) throws
    func secure() throws
    func close()
}

public extension MailWire {
    func rawLine() throws -> Data { Data(try line().utf8) }
    func command(_ value: String) throws {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw MailFailure.invalidMessage
        }
        try write(Data((value + "\r\n").utf8))
    }
}

/// Constructs one wire for one server/operation. Production uses the native
/// platform-TLS lane; host tests inject a scripted wire. A factory must never
/// return a plaintext fallback when implicit TLS or STARTTLS was requested.
public protocol MailWireFactory: Sendable {
    func makeWire(
        server: MailServer,
        cancelled: @escaping @Sendable () -> Bool
    ) throws -> any MailWire
}

public enum MailCancelledFlag {
    /// Shared bounded cancellation object used by MailClient. Kept here so
    /// the protocol layer and the transport lane use one spelling.
    public final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        public init() {}
        public var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        public func cancel() {
            lock.lock(); value = true; lock.unlock()
        }
    }
}

final class MailProtocolSession {
    let wire: any MailWire
    private var tag = 0
    init(wire: any MailWire) { self.wire = wire }
    static func quoted(_ value: String) throws -> String {
        guard value.utf8.count <= 1024,
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw MailFailure.invalidMessage
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    struct IMAPReply {
        var lines: [String] = []
        var literals: [Data] = []
    }
    func imap(_ command: String) throws -> IMAPReply {
        tag += 1
        let prefix = "F\(tag)"
        try wire.command("\(prefix) \(command)")
        var reply = IMAPReply()
        var total = 0
        for _ in 0..<20_000 {
            let line = try wire.line()
            total += line.utf8.count
            guard total <= 20_000_000 else { throw MailFailure.responseTooLarge }
            if line.hasPrefix(prefix + " ") {
                guard line.uppercased().hasPrefix(prefix + " OK") else {
                    throw MailFailure.protocolRejected
                }
                reply.lines.append(line)
                return reply
            }
            if line.hasPrefix("* BYE") { throw MailFailure.connectionFailed }
            reply.lines.append(line)
            if line.hasSuffix("}"), let start = line.lastIndex(of: "{"),
               let count = Int(line[line.index(after: start)..<line.index(before: line.endIndex)]) {
                guard count >= 0, count <= 16_000_000, total + count <= 20_000_000 else {
                    throw MailFailure.responseTooLarge
                }
                reply.literals.append(try wire.bytes(count))
                total += count
            }
        }
        throw MailFailure.responseTooLarge
    }
    func loginIMAP(server: MailServer, password: String) throws {
        guard try wire.line().uppercased().hasPrefix("* OK") else {
            throw MailFailure.protocolRejected
        }
        if server.tls == .startTLS {
            _ = try imap("STARTTLS")
            try wire.secure()
        }
        do {
            _ = try imap("LOGIN \(Self.quoted(server.username)) \(Self.quoted(password))")
        } catch MailFailure.protocolRejected {
            throw MailFailure.authenticationFailed
        }
    }
    func setRead(uid: UInt32, read: Bool) throws {
        _ = try imap("UID STORE \(uid) \(read ? "+" : "-")FLAGS.SILENT (\\Seen)")
        let reply = try imap("UID FETCH \(uid) (UID FLAGS)")
        let matching = reply.lines.filter { line in
            MailClient.matches(#"\bUID (\d+)"#, line).first?.first == String(uid)
        }
        guard matching.count == 1 else { throw MailFailure.messageNotFound }
        guard let flags = MailClient.matches(#"FLAGS \(([^)]*)\)"#, matching[0]).first?.first else {
            throw MailFailure.protocolRejected
        }
        let actual = flags.split(separator: " ").contains { $0.lowercased() == "\\seen" }
        guard actual == read else { throw MailFailure.mailboxChanged }
    }
    func pop(_ command: String? = nil) throws -> String {
        if let command { try wire.command(command) }
        let response = try wire.line()
        guard response.hasPrefix("+OK") else { throw MailFailure.protocolRejected }
        return response
    }
    func popLines(_ command: String) throws -> [String] {
        _ = try pop(command)
        var lines: [String] = []
        var size = 0
        for _ in 0..<200_000 {
            var line = try wire.line()
            if line == "." { return lines }
            if line.hasPrefix("..") { line.removeFirst() }
            size += line.utf8.count + 2
            guard size <= 16_000_000 else { throw MailFailure.responseTooLarge }
            lines.append(line)
        }
        throw MailFailure.responseTooLarge
    }
    func popMessage(_ index: Int) throws -> Data {
        _ = try pop("RETR \(index)")
        var data = Data()
        for _ in 0..<200_000 {
            var line = try wire.rawLine()
            if line == Data([46]) { return data }
            if line.starts(with: [46, 46]) { line.removeFirst() }
            guard data.count + line.count + 2 <= 16_000_000 else {
                throw MailFailure.responseTooLarge
            }
            data.append(line)
            data.append(contentsOf: [13, 10])
        }
        throw MailFailure.responseTooLarge
    }
    func loginPOP(server: MailServer, password: String) throws {
        _ = try pop()
        if server.tls == .startTLS {
            _ = try pop("STLS")
            try wire.secure()
        }
        guard !password.contains(where: { $0.isNewline || $0 == "\0" }),
              password.utf8.count <= 1024 else {
            throw MailFailure.invalidConfiguration
        }
        do {
            _ = try pop("USER \(server.username)")
            _ = try pop("PASS \(password)")
        } catch MailFailure.protocolRejected {
            throw MailFailure.authenticationFailed
        }
    }
    func smtp(_ command: String? = nil, expecting code: Int) throws -> [String] {
        if let command { try wire.command(command) }
        var lines: [String] = []
        for _ in 0..<100 {
            let line = try wire.line()
            guard line.count >= 4, Int(line.prefix(3)) == code else {
                throw MailFailure.protocolRejected
            }
            lines.append(line)
            let separator = line[line.index(line.startIndex, offsetBy: 3)]
            if separator == " " { return lines }
            guard separator == "-" else { throw MailFailure.protocolRejected }
        }
        throw MailFailure.responseTooLarge
    }
    func loginSMTP(server: MailServer, password: String) throws {
        _ = try smtp(expecting: 220)
        var features = try smtp("EHLO floe.local", expecting: 250)
        if server.tls == .startTLS {
            guard features.contains(where: { $0.uppercased().contains("STARTTLS") }) else {
                throw MailFailure.tlsFailed
            }
            _ = try smtp("STARTTLS", expecting: 220)
            try wire.secure()
            features = try smtp("EHLO floe.local", expecting: 250)
        }
        let mechanisms = features
            .filter { $0.uppercased().dropFirst(4).hasPrefix("AUTH") }
            .joined(separator: " ").uppercased()
        guard password.utf8.count <= 1024, !password.contains("\0") else {
            throw MailFailure.invalidConfiguration
        }
        do {
            if mechanisms.contains("PLAIN") {
                let token = Data(("\0" + server.username + "\0" + password).utf8)
                    .base64EncodedString()
                _ = try smtp("AUTH PLAIN", expecting: 334)
                _ = try smtp(token, expecting: 235)
            } else if mechanisms.contains("LOGIN") {
                _ = try smtp("AUTH LOGIN", expecting: 334)
                _ = try smtp(Data(server.username.utf8).base64EncodedString(), expecting: 334)
                _ = try smtp(Data(password.utf8).base64EncodedString(), expecting: 235)
            } else {
                throw MailFailure.authenticationFailed
            }
        } catch MailFailure.protocolRejected {
            throw MailFailure.authenticationFailed
        }
    }
    func send(from: String, draft: MailDraft, messageID: UUID) throws {
        let data = try draft.encoded(from: from, messageID: messageID)
        _ = try smtp("MAIL FROM:<\(from)>", expecting: 250)
        for recipient in draft.recipients {
            _ = try smtp("RCPT TO:<\(recipient)>", expecting: 250)
        }
        _ = try smtp("DATA", expecting: 354)
        // All body parts are base64 encoded; generated headers cannot begin
        // with a dot. Once DATA starts, connection loss cannot distinguish
        // delivery from rejection.
        do {
            try wire.write(data)
            try wire.write(Data(".\r\n".utf8))
            _ = try smtp(expecting: 250)
        } catch {
            throw MailFailure.deliveryUnknown
        }
    }
}

// MARK: - Native production wire

/// Production factory backed by the App-owned platform-TLS lane. The lane is
/// bound by RuntimeHost before any mail operation; an unbound lane returns a
/// typed failure and never opens a plaintext socket.
public struct MailNativeWireFactory: MailWireFactory {
    private let mailbox: MailTransportMailbox
    public init(mailbox: MailTransportMailbox = .shared) { self.mailbox = mailbox }
    public func makeWire(
        server: MailServer,
        cancelled: @escaping @Sendable () -> Bool
    ) throws -> any MailWire {
        try MailNativeWire(server: server, cancelled: cancelled, mailbox: mailbox)
    }
}

/// Bounded synchronous wire over the native mailbox. The mailbox performs the
/// real TCP/TLS work in the trusted App lane; this type only frames reads,
/// checks deadlines/cancellation and maps closed status to `MailFailure`.
final class MailNativeWire: MailWire {
    private let mailbox: MailTransportMailbox
    private let session: Int64
    private let cancelled: @Sendable () -> Bool
    private let deadline: Date
    private var buffer = Data()
    private var received = 0
    private var closed = false

    init(
        server: MailServer,
        cancelled: @escaping @Sendable () -> Bool,
        mailbox: MailTransportMailbox
    ) throws {
        try server.validate()
        self.mailbox = mailbox
        self.cancelled = cancelled
        self.deadline = Date().addingTimeInterval(60)
        self.session = try mailbox.open(
            host: server.host,
            port: server.port,
            tls: server.tls,
            deadline: deadline,
            cancelled: cancelled
        )
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        mailbox.close(session: session, timeout: 2)
    }

    private func check() throws {
        if cancelled() { throw MailFailure.cancelled }
        if Date() >= deadline { throw MailFailure.timedOut }
    }

    private func receive() throws {
        try check()
        let data = try mailbox.readSome(
            session: session,
            maximumBytes: 32 * 1024,
            deadline: deadline,
            cancelled: cancelled
        )
        guard !data.isEmpty else { throw MailFailure.connectionFailed }
        received += data.count
        guard received <= 24_000_000 else { throw MailFailure.responseTooLarge }
        buffer.append(data)
    }

    func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= 16_000_000 else { throw MailFailure.responseTooLarge }
        while buffer.count < count { try receive() }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    func line() throws -> String { String(decoding: try rawLine(), as: UTF8.self) }

    func rawLine() throws -> Data {
        let crlf = Data([13, 10])
        while true {
            if let range = buffer.range(of: crlf) {
                guard range.lowerBound <= 65_536 else { throw MailFailure.responseTooLarge }
                let line = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                return line
            }
            guard buffer.count <= 65_536 else { throw MailFailure.responseTooLarge }
            try receive()
        }
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try check()
            let end = min(data.count, offset + 64 * 1024)
            try mailbox.write(
                session: session,
                data: Data(data[offset..<end]),
                deadline: deadline,
                cancelled: cancelled
            )
            offset = end
        }
    }

    func secure() throws {
        guard buffer.isEmpty else { throw MailFailure.tlsFailed }
        try check()
        try mailbox.upgrade(session: session, deadline: deadline, cancelled: cancelled)
    }
}
