import Foundation
import CoreFoundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// Synchronous transport used only on MailClient's dedicated utility queue.
/// A scriptable boundary keeps protocol tests independent of real credentials.
protocol MailWire: AnyObject {
    func line() throws -> String
    func rawLine() throws -> Data
    func bytes(_ count: Int) throws -> Data
    func write(_ data: Data) throws
    func secure() throws
    func close()
}
extension MailWire {
    func rawLine() throws -> Data { Data(try line().utf8) }
    func command(_ value: String) throws {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailFailure.invalidMessage }
        try write(Data((value + "\r\n").utf8))
    }
}

#if canImport(CFNetwork)
final class MailStreamWire: MailWire {
    private let input: InputStream
    private let output: OutputStream
    private let server: MailServer
    private var buffer = Data()
    private var received = 0
    private let deadline = ProcessInfo.processInfo.systemUptime + 45
    private let cancelled: @Sendable () -> Bool

    init(server: MailServer, cancelled: @escaping @Sendable () -> Bool) throws {
        try server.validate()
        self.server = server; self.cancelled = cancelled
        var read: InputStream?; var write: OutputStream?
        Stream.getStreamsToHost(withName: server.host, port: server.port, inputStream: &read, outputStream: &write)
        guard let read, let write else { throw MailFailure.connectionFailed }
        input = read; output = write
        if server.tls == .implicitTLS { try secure() }
        input.open(); output.open()
    }
    deinit { close() }
    func close() { input.close(); output.close() }
    func secure() throws {
        guard buffer.isEmpty else { throw MailFailure.tlsFailed }
        let settings: [String: Any] = [
            kCFStreamSSLPeerName as String: server.host,
            kCFStreamSSLValidatesCertificateChain as String: true,
            kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL
        ]
        let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        guard input.setProperty(settings, forKey: key), output.setProperty(settings, forKey: key) else {
            throw MailFailure.tlsFailed
        }
    }
    private func check() throws {
        if cancelled() { throw MailFailure.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw MailFailure.timedOut }
        if input.streamStatus == .error || output.streamStatus == .error { throw MailFailure.connectionFailed }
    }
    private func receive() throws {
        while !input.hasBytesAvailable {
            try check()
            if input.streamStatus == .atEnd || input.streamStatus == .closed { throw MailFailure.connectionFailed }
            Thread.sleep(forTimeInterval: 0.005)
        }
        var chunk = [UInt8](repeating: 0, count: 8192)
        let count = input.read(&chunk, maxLength: chunk.count)
        guard count > 0 else { throw MailFailure.connectionFailed }
        received += count
        guard received <= 24_000_000 else { throw MailFailure.responseTooLarge }
        buffer.append(contentsOf: chunk.prefix(count))
    }
    func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= 16_000_000 else { throw MailFailure.responseTooLarge }
        while buffer.count < count { try receive() }
        let result = Data(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
    func line() throws -> String { String(decoding: try rawLine(), as: UTF8.self) }
    func rawLine() throws -> Data {
        let crlf = Data([13, 10])
        while true {
            if let range = buffer.range(of: crlf) {
                guard range.lowerBound <= 65_536 else { throw MailFailure.responseTooLarge }
                let line = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound); return line
            }
            guard buffer.count <= 65_536 else { throw MailFailure.responseTooLarge }
            try receive()
        }
    }
    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try check()
            guard output.hasSpaceAvailable else { Thread.sleep(forTimeInterval: 0.005); continue }
            let count = data.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), maxLength: min(8192, data.count - offset))
            }
            guard count > 0 else { throw MailFailure.connectionFailed }
            offset += count
        }
    }
}
#else
/// The device connector uses Apple's verified TLS transport. Other platforms
/// keep schema/model support but must not silently use an insecure transport.
final class MailStreamWire: MailWire {
    init(server: MailServer, cancelled: @escaping @Sendable () -> Bool) throws { throw MailFailure.protocolRejected }
    func line() throws -> String { throw MailFailure.protocolRejected }
    func bytes(_ count: Int) throws -> Data { throw MailFailure.protocolRejected }
    func write(_ data: Data) throws { throw MailFailure.protocolRejected }
    func secure() throws { throw MailFailure.protocolRejected }
    func close() {}
}
#endif

final class MailProtocolSession {
    let wire: MailWire
    private var tag = 0
    init(wire: MailWire) { self.wire = wire }
    static func quoted(_ value: String) throws -> String {
        guard value.utf8.count <= 1024, !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailFailure.invalidMessage }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    struct IMAPReply {
        var lines: [String] = []
        var literals: [Data] = []
    }
    func imap(_ command: String) throws -> IMAPReply {
        tag += 1; let prefix = "F\(tag)"
        try wire.command("\(prefix) \(command)")
        var reply = IMAPReply(); var total = 0
        for _ in 0..<20_000 {
            let line = try wire.line(); total += line.utf8.count
            guard total <= 20_000_000 else { throw MailFailure.responseTooLarge }
            if line.hasPrefix(prefix + " ") {
                guard line.uppercased().hasPrefix(prefix + " OK") else { throw MailFailure.protocolRejected }
                reply.lines.append(line); return reply
            }
            if line.hasPrefix("* BYE") { throw MailFailure.connectionFailed }
            reply.lines.append(line)
            if line.hasSuffix("}"), let start = line.lastIndex(of: "{"),
               let count = Int(line[line.index(after: start)..<line.index(before: line.endIndex)]) {
                guard count >= 0, count <= 16_000_000, total + count <= 20_000_000 else { throw MailFailure.responseTooLarge }
                reply.literals.append(try wire.bytes(count)); total += count
            }
        }
        throw MailFailure.responseTooLarge
    }
    func loginIMAP(server: MailServer, password: String) throws {
        guard try wire.line().uppercased().hasPrefix("* OK") else { throw MailFailure.protocolRejected }
        if server.tls == .startTLS { _ = try imap("STARTTLS"); try wire.secure() }
        do { _ = try imap("LOGIN \(Self.quoted(server.username)) \(Self.quoted(password))") }
        catch MailFailure.protocolRejected { throw MailFailure.authenticationFailed }
    }
    func setRead(uid: UInt32, read: Bool) throws {
        _ = try imap("UID STORE \(uid) \(read ? "+" : "-")FLAGS.SILENT (\\Seen)")
        let reply = try imap("UID FETCH \(uid) (UID FLAGS)")
        let matching = reply.lines.filter { line in
            MailClient.matches(#"\bUID (\d+)"#, line).first?.first == String(uid)
        }
        guard matching.count == 1 else { throw MailFailure.messageNotFound }
        guard let flags = MailClient.matches(#"FLAGS \(([^)]*)\)"#, matching[0]).first?.first else { throw MailFailure.protocolRejected }
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
        _ = try pop(command); var lines: [String] = []; var size = 0
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
        _ = try pop("RETR \(index)"); var data = Data()
        for _ in 0..<200_000 {
            var line = try wire.rawLine()
            if line == Data([46]) { return data }
            if line.starts(with: [46, 46]) { line.removeFirst() }
            guard data.count + line.count + 2 <= 16_000_000 else { throw MailFailure.responseTooLarge }
            data.append(line); data.append(contentsOf: [13, 10])
        }
        throw MailFailure.responseTooLarge
    }
    func loginPOP(server: MailServer, password: String) throws {
        _ = try pop()
        if server.tls == .startTLS { _ = try pop("STLS"); try wire.secure() }
        guard !password.contains(where: { $0.isNewline || $0 == "\0" }), password.utf8.count <= 1024 else { throw MailFailure.invalidConfiguration }
        do { _ = try pop("USER \(server.username)"); _ = try pop("PASS \(password)") }
        catch MailFailure.protocolRejected { throw MailFailure.authenticationFailed }
    }
    func smtp(_ command: String? = nil, expecting code: Int) throws -> [String] {
        if let command { try wire.command(command) }
        var lines: [String] = []
        for _ in 0..<100 {
            let line = try wire.line()
            guard line.count >= 4, Int(line.prefix(3)) == code else { throw MailFailure.protocolRejected }
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
            guard features.contains(where: { $0.uppercased().contains("STARTTLS") }) else { throw MailFailure.tlsFailed }
            _ = try smtp("STARTTLS", expecting: 220); try wire.secure()
            features = try smtp("EHLO floe.local", expecting: 250)
        }
        let mechanisms = features.filter { $0.uppercased().dropFirst(4).hasPrefix("AUTH") }.joined(separator: " ").uppercased()
        guard password.utf8.count <= 1024, !password.contains("\0") else { throw MailFailure.invalidConfiguration }
        do {
            if mechanisms.contains("PLAIN") {
                let token = Data(("\0" + server.username + "\0" + password).utf8).base64EncodedString()
                _ = try smtp("AUTH PLAIN", expecting: 334)
                _ = try smtp(token, expecting: 235)
            } else if mechanisms.contains("LOGIN") {
                _ = try smtp("AUTH LOGIN", expecting: 334)
                _ = try smtp(Data(server.username.utf8).base64EncodedString(), expecting: 334)
                _ = try smtp(Data(password.utf8).base64EncodedString(), expecting: 235)
            } else { throw MailFailure.authenticationFailed }
        } catch MailFailure.protocolRejected { throw MailFailure.authenticationFailed }
    }
    func send(from: String, draft: MailDraft, messageID: UUID) throws {
        let data = try draft.encoded(from: from, messageID: messageID)
        _ = try smtp("MAIL FROM:<\(from)>", expecting: 250)
        for recipient in draft.recipients { _ = try smtp("RCPT TO:<\(recipient)>", expecting: 250) }
        _ = try smtp("DATA", expecting: 354)
        // All body parts are base64 encoded; generated headers cannot begin with a dot.
        // Once DATA starts, connection loss cannot distinguish delivery from rejection.
        do { try wire.write(data); try wire.write(Data(".\r\n".utf8)); _ = try smtp(expecting: 250) }
        catch { throw MailFailure.deliveryUnknown }
    }
}
