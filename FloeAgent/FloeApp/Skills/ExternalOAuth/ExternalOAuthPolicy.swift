import Foundation

enum ExternalOAuthProvider: String, Codable, Sendable, CaseIterable {
    case google, microsoft

    var title: String { self == .google ? "Google" : "Microsoft" }
}

enum ExternalOAuthFailure: Error, Sendable, Equatable {
    case invalidAuthorization, invalidCallback, denied, cancelled, timedOut, pluginUnavailable, storageUnavailable
}

/// Private native/plugin messages. These are never tool results or model input.
struct ExternalOAuthOffer: Sendable {
    enum Kind: Sendable { case authorization, device }
    let kind: Kind
    let url: URL
    let userCode: String?
    let completeURL: URL?
    let expiresIn: TimeInterval?

    init(kind: Kind, url: URL, userCode: String?, completeURL: URL? = nil, expiresIn: TimeInterval? = nil) {
        self.kind = kind; self.url = url; self.userCode = userCode
        self.completeURL = completeURL; self.expiresIn = expiresIn
    }
}

enum ExternalOAuthProgress: Sendable {
    case pending, issued, failed
}

protocol ExternalOAuthPluginTransport: Sendable {
    var credentialContext: ExternalOAuthCredentialContext { get }
    func begin(client: ExternalOAuthClientProfile, redirectURI: URL?) async throws -> ExternalOAuthOffer
    func resume(callback: URL) async throws
    func status() async throws -> ExternalOAuthProgress
    func refresh(client: ExternalOAuthClientProfile) async throws
    func cancel() async
}

/// The plugin retains PKCE and tokens. Native code accepts only the exact
/// provider page and callback of the current flow; it never rewrites its URL.
struct ExternalOAuthAuthorizationPolicy: Sendable {
    private let redirect: URL
    private let state: String

    init(authorizationURL url: URL, client: ExternalOAuthClientProfile, redirect: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == client.authorizationEndpoint.scheme,
              parts.host == client.authorizationEndpoint.host, parts.port == nil,
              parts.path == client.authorizationEndpoint.path,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems,
              items.filter({ $0.name == "resource" }).allSatisfy({ $0.value != nil }),
              let values = Self.uniqueQuery(items.filter({ $0.name != "resource" })),
              values["client_id"] == client.clientID,
              values["response_type"] == "code", values["code_challenge_method"] == "S256",
              let challenge = values["code_challenge"], challenge.utf8.count == 43,
              challenge.utf8.allSatisfy(Self.isBase64URL),
              let state = values["state"], (16...512).contains(state.utf8.count),
              let receivedRedirect = values["redirect_uri"], URL(string: receivedRedirect) == redirect,
              Self.isLoopbackRedirect(redirect),
              let scopes = values["scope"],
              Set(scopes.split(separator: " ").map(String.init)) == client.scopes,
              client.resources == Set(items.filter({ $0.name == "resource" }).compactMap(\.value)),
              Set(values.keys).subtracting(["client_id", "response_type", "code_challenge_method",
                  "code_challenge", "state", "redirect_uri", "scope", "resource"])
                    == Set(client.authorizationExtras.keys),
              client.authorizationExtras.allSatisfy({ values[$0.key] == $0.value }) else {
            throw ExternalOAuthFailure.invalidAuthorization
        }
        self.redirect = redirect
        self.state = state
    }

    static func validateDeviceOffer(_ offer: ExternalOAuthOffer, provider: ExternalOAuthProvider) throws {
        let url = offer.url
        guard offer.kind == .device, url.scheme == "https", url.port == nil,
              offer.expiresIn.map({ $0.isFinite && (1...3_600).contains($0) }) ?? true,
              url.user == nil, url.password == nil, url.fragment == nil,
              isDeviceVerificationPage(url, provider: provider),
              url.query == nil, let code = offer.userCode,
              (6...32).contains(code.utf8.count),
              code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || $0 == 45 }) else {
            throw ExternalOAuthFailure.invalidAuthorization
        }
        if let complete = offer.completeURL {
            guard complete.scheme == "https", complete.port == nil, complete.user == nil,
                  complete.password == nil, complete.fragment == nil,
                  isDeviceVerificationPage(complete, provider: provider),
                  let query = uniqueQuery(URLComponents(url: complete, resolvingAgainstBaseURL: false)?.queryItems),
                  query.count == 1, query["user_code"] == code || query["otc"] == code else {
                throw ExternalOAuthFailure.invalidAuthorization
            }
        }
    }

    private static func isDeviceVerificationPage(_ url: URL, provider: ExternalOAuthProvider) -> Bool {
        switch provider {
        case .microsoft:
            url.host == "login.microsoft.com" && url.path == "/device"
                || url.host == "microsoft.com" && url.path == "/devicelogin"
        case .google:
            ["google.com", "www.google.com"].contains(url.host ?? "") && url.path == "/device"
        }
    }

    func validate(callback url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == redirect.scheme, parts.host == redirect.host, parts.port == redirect.port,
              parts.path == redirect.path, parts.user == nil, parts.password == nil, parts.fragment == nil,
              let values = Self.uniqueQuery(parts.queryItems), values["state"] == state else {
            throw ExternalOAuthFailure.invalidCallback
        }
        if values["error"] != nil {
            guard values["code"] == nil else { throw ExternalOAuthFailure.invalidCallback }
            throw ExternalOAuthFailure.denied
        }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 8_192 else {
            throw ExternalOAuthFailure.invalidCallback
        }
    }

    static func isLoopbackRedirect(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && (url.port ?? 0) > 1_023
            && url.path == "/" && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil
    }

    private static func uniqueQuery(_ items: [URLQueryItem]?) -> [String: String]? {
        var values: [String: String] = [:]
        for item in items ?? [] {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        return values
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 95
    }
}
