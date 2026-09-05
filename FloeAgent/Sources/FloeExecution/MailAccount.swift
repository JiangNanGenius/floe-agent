import Foundation

public enum MailIncomingProtocol: String, Codable, Sendable, CaseIterable { case imap, pop3 }
public enum MailTLSMode: String, Codable, Sendable, CaseIterable { case implicitTLS, startTLS }

public struct MailServer: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var tls: MailTLSMode
    public var username: String
    public init(host: String = "", port: Int, tls: MailTLSMode = .implicitTLS, username: String = "") {
        self.host = host; self.port = port; self.tls = tls; self.username = username
    }
    public func validate() throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              (1...65535).contains(port), !username.isEmpty,
              username.utf8.count <= 320, !username.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw MailFailure.invalidConfiguration
        }
    }
}

/// Non-secret settings only. Passwords are resolved by the app from Keychain.
public struct MailAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var address: String
    public var incomingProtocol: MailIncomingProtocol
    public var incoming: MailServer
    public var outgoing: MailServer
    public init(id: UUID = UUID(), address: String = "", incomingProtocol: MailIncomingProtocol = .imap,
                incoming: MailServer = .init(port: 993), outgoing: MailServer = .init(port: 465)) {
        self.id = id; self.address = address; self.incomingProtocol = incomingProtocol
        self.incoming = incoming; self.outgoing = outgoing
    }
    public func validate() throws {
        try Self.validateAddress(address); try incoming.validate(); try outgoing.validate()
    }
    public static func validateAddress(_ value: String) throws {
        // Deliberately support bare ASCII addr-spec, not raw header or SMTP syntax.
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.utf8.count <= 254, parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              !value.contains(where: { "<>(),;:\\[]\"".contains($0) }) else {
            throw MailFailure.invalidAddress
        }
    }
}

/// Never include server-controlled text, command arguments or credentials in errors.
public enum MailFailure: String, Error, Sendable, LocalizedError {
    case invalidConfiguration, invalidAddress, connectionFailed, tlsFailed, timedOut
    case authenticationFailed, protocolRejected, responseTooLarge, invalidMessage
    case messageNotFound, mailboxChanged, deliveryUnknown, cancelled, busy
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Check the mail host, port, encryption mode and username."
        case .invalidAddress: "Use a bare email address without display names or control characters."
        case .connectionFailed: "Mail connection failed. Check the configured server and network."
        case .tlsFailed: "Secure mail connection failed. Certificate validation cannot be disabled."
        case .timedOut: "Mail operation timed out."
        case .authenticationFailed: "Mail authentication failed. Check the app password and provider policy; OAuth-only accounts are not supported."
        case .protocolRejected: "The mail server rejected the operation or does not support it."
        case .responseTooLarge: "Mail response exceeds the safety limit. Narrow the query or choose a smaller message."
        case .invalidMessage: "Invalid mail message or attachment."
        case .messageNotFound: "Message no longer exists. Refresh the message list."
        case .mailboxChanged: "Mailbox identity changed. Refresh before acting on messages."
        case .deliveryUnknown: "Delivery status is unknown. Do not automatically resend; check the recipient or server first."
        case .cancelled: "Mail operation cancelled."
        case .busy: "Another mail operation is running. Wait for it to finish."
        }
    }
}

public struct MailMessageReference: Codable, Sendable, Equatable {
    public var id: String
    public var byteCount: Int
    public var flags: [String]
    public init(id: String, byteCount: Int, flags: [String] = []) {
        self.id = id; self.byteCount = byteCount; self.flags = flags
    }
}

public struct MailListing: Codable, Sendable {
    public var folder: String
    public var mailboxVersion: String?
    public var messages: [MailMessageReference]
    public var hasMore: Bool
    public var nextBeforeMessageID: String?
    public init(folder: String, mailboxVersion: String?, messages: [MailMessageReference], hasMore: Bool, nextBeforeMessageID: String? = nil) {
        self.folder = folder; self.mailboxVersion = mailboxVersion; self.messages = messages; self.hasMore = hasMore
        self.nextBeforeMessageID = nextBeforeMessageID
    }
}

public struct MailAttachment: Sendable {
    public var filename: String
    public var data: Data
    public init(filename: String, data: Data) { self.filename = filename; self.data = data }
}

public struct MailDraft: Sendable {
    public var recipients: [String]
    public var subject: String
    public var body: String
    public var attachments: [MailAttachment]
    public init(recipients: [String], subject: String, body: String, attachments: [MailAttachment] = []) {
        self.recipients = recipients; self.subject = subject; self.body = body; self.attachments = attachments
    }
    public func validate() throws {
        guard !recipients.isEmpty, recipients.count <= 50, subject.utf8.count <= 512,
              !subject.contains(where: { $0.isNewline || $0 == "\0" }), body.utf8.count <= 1_000_000,
              attachments.count <= 10, attachments.reduce(0, { $0 + $1.data.count }) <= 10_000_000 else {
            throw MailFailure.invalidMessage
        }
        for address in recipients { try MailAccount.validateAddress(address) }
        for attachment in attachments {
            guard !attachment.filename.isEmpty, attachment.filename.utf8.count <= 180,
                  !attachment.filename.contains(where: { $0.isNewline || $0 == "\0" || "/\\".contains($0) }) else {
                throw MailFailure.invalidMessage
            }
        }
    }
    public func encoded(from: String, messageID: UUID) throws -> Data {
        try validate(); try MailAccount.validateAddress(from)
        func encodedWord(_ string: String) -> String {
            // Each UTF-8 encoded word is <= 72 characters, without splitting a scalar.
            var words: [String] = []; var chunk = Data()
            for scalar in string.unicodeScalars {
                let next = Data(String(scalar).utf8)
                if chunk.count + next.count > 42 {
                    words.append("=?UTF-8?B?\(chunk.base64EncodedString())?="); chunk = Data()
                }
                chunk.append(next)
            }
            if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
            return words.joined(separator: "\r\n ")
        }
        func base64(_ data: Data) -> String {
            data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        }
        let boundary = "floe-\(messageID.uuidString)"
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var text = "From: \(from)\r\nTo: \(recipients.joined(separator: ",\r\n "))\r\nSubject: \(encodedWord(subject))\r\n"
        text += "Date: \(date.string(from: Date()))\r\nMessage-ID: <\(messageID.uuidString)@floe.local>\r\nMIME-Version: 1.0\r\n"
        text += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        text += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(Data(body.utf8)))\r\n"
        for attachment in attachments {
            let filename = attachment.filename.utf8.map { String(format: "%%%02X", $0) }.joined()
            text += "--\(boundary)\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment;\r\n filename*=UTF-8''\(filename)\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(attachment.data))\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }
}
