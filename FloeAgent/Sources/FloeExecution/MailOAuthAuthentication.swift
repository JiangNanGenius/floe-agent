import Foundation

/// Opaque connection metadata only. It grants no credential or mail access.
public struct ExternalOAuthConnectionReference: Codable, Sendable, Equatable {
    public let skillID: String
    public let installationID: String
    public let profile: String
    public let target: String
    public let accountID: UUID
    public let credentialID: UUID
    public let revision: Int
    public let partition: String
    public init(skillID: String, installationID: String, profile: String, target: String,
                accountID: UUID, credentialID: UUID, revision: Int, partition: String) {
        self.skillID = skillID; self.installationID = installationID; self.profile = profile
        self.target = target; self.accountID = accountID; self.credentialID = credentialID
        self.revision = revision; self.partition = partition
    }
    public func validate() throws {
        guard revision >= 0, [skillID, installationID, profile, target, partition].allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw MailFailure.invalidConfiguration }
    }
}

public enum MailOAuthProvider: String, Sendable { case google, microsoft
    public init(reference: ExternalOAuthConnectionReference) throws {
        try reference.validate()
        guard reference.target == "local-linux" else { throw MailFailure.authenticationFailed }
        switch reference.skillID {
        case "floe-google-auth": self = .google
        case "floe-microsoft-auth": self = .microsoft
        default: throw MailFailure.authenticationFailed
        }
    }
}
public enum MailOAuthService: String, Sendable { case imap, smtp }

/// The provider's delegated mail service. Microsoft v2 names the Outlook
/// resource in each full scope URL; neither Graph nor identity scopes suffice.
public enum MailOAuthPolicy {
    public static func scopes(provider: MailOAuthProvider, service: MailOAuthService) -> Set<String> {
        switch provider {
        case .google: ["https://mail.google.com/"]
        case .microsoft: [service == .imap ? "https://outlook.office.com/IMAP.AccessAsUser.All" : "https://outlook.office.com/SMTP.Send"]
        }
    }
    public static func resource(provider: MailOAuthProvider) -> String {
        provider == .google ? "https://mail.google.com/" : "https://outlook.office.com/"
    }
    public static func validate(server: MailServer, provider: MailOAuthProvider, service: MailOAuthService) throws {
        try server.validate()
        try MailAccount.validateAddress(server.username)
        let host = server.host.lowercased()
        let allowed: Bool
        switch (provider, service) {
        case (.google, .imap): allowed = host == "imap.gmail.com" && server.port == 993 && server.tls == .implicitTLS
        case (.google, .smtp): allowed = host == "smtp.gmail.com" && ((server.port == 465 && server.tls == .implicitTLS) || (server.port == 587 && server.tls == .startTLS))
        case (.microsoft, .imap): allowed = host == "outlook.office365.com" && server.port == 993 && server.tls == .implicitTLS
        case (.microsoft, .smtp): allowed = ["smtp.office365.com", "smtp-mail.outlook.com"].contains(host) && server.port == 587 && server.tls == .startTLS
        }
        guard allowed else { throw MailFailure.oauthServerMismatch }
    }
}

/// Ephemeral native Mail input; never Codable, tool output or account state.
/// Bearer bytes are pinned to an exact server/username/service before use.
public struct MailCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Storage: Sendable {
        case password(String)
        case xoauth2(Data, MailOAuthProvider, MailOAuthService, MailServer)
    }
    private let storage: Storage
    public static func password(_ value: String) -> Self { Self(storage: .password(value)) }
    public static func xoauth2(accessToken: Data, provider: MailOAuthProvider, service: MailOAuthService, server: MailServer) throws -> Self {
        try MailOAuthPolicy.validate(server: server, provider: provider, service: service)
        guard !accessToken.isEmpty, accessToken.count <= 16_384,
              accessToken.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw MailFailure.authenticationFailed }
        return Self(storage: .xoauth2(accessToken, provider, service, server))
    }
    public var description: String { "<private mail credential>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    var passwordValue: String? { if case .password(let value) = storage { value } else { nil } }
    func validate(server: MailServer, protocolName: String) throws {
        switch storage {
        case .password: break
        case .xoauth2(_, let provider, let service, let bound):
            guard service.rawValue == protocolName, bound == server else { throw MailFailure.oauthServerMismatch }
            try MailOAuthPolicy.validate(server: server, provider: provider, service: service)
        }
    }
    func xoauth2Response(server: MailServer, service: MailOAuthService) throws -> String {
        try validate(server: server, protocolName: service.rawValue)
        guard case .xoauth2(let token, _, _, _) = storage else { throw MailFailure.authenticationFailed }
        var bytes = Data(("user=" + server.username + "\u{1}auth=Bearer ").utf8)
        bytes.append(token); bytes.append(contentsOf: [1, 1])
        return bytes.base64EncodedString()
    }
}
