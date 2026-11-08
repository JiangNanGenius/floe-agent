import Foundation
import FloeCore

enum NativeExternalOAuthCopy {
    static func text(_ en: String, _ zh: String) -> String { FloeL10n.isChinese ? zh : en }
}

/// Transient native form state. Never encoded, logged, synced or persisted to
/// preferences; the optional secret enters the existing vault only on grant.
struct NativeExternalOAuthDraft {
    let provider: ExternalOAuthProvider
    var clientID = ""
    var tenant = "common"
    var scopes = ""
    var resources = ""
    var grant = ExternalOAuthClientProfile.Grant.authorizationCode
    var keepSignedIn = true
    var environmentID = ""
    var clientSecret = ""

    init(provider: ExternalOAuthProvider) { self.provider = provider }

    mutating func restore(client: ExternalOAuthClientProfile, environmentID: String) {
        clientID = client.clientID; grant = client.grant
        tenant = client.authorizationEndpoint.path.split(separator: "/").first.map(String.init) ?? "common"
        keepSignedIn = provider == .google ? client.authorizationExtras["access_type"] == "offline"
            : client.scopes.contains("offline_access")
        scopes = client.scopes.subtracting(provider == .microsoft ? ["offline_access"] : []).sorted().joined(separator: "\n")
        resources = client.resources.sorted().joined(separator: "\n")
        self.environmentID = environmentID; clientSecret = ""
    }

    func profile() throws -> ExternalOAuthClientProfile {
        guard scopes.utf8.count <= 32_768, resources.utf8.count <= 8_192,
              clientSecret.utf8.count <= 3_072 else { throw ExternalOAuthFailure.invalidAuthorization }
        var requested = Set(scopes.split(whereSeparator: \.isWhitespace).map(String.init))
        guard !requested.isEmpty else { throw ExternalOAuthFailure.invalidAuthorization }
        let extras: [String: String]
        let endpoint: URL
        switch provider {
        case .google:
            endpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            extras = keepSignedIn && grant == .authorizationCode ? ["access_type": "offline"] : [:]
        case .microsoft:
            let value = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["common", "organizations", "consumers"].contains(value) || UUID(uuidString: value) != nil,
                  let url = URL(string: "https://login.microsoftonline.com/\(value)/oauth2/v2.0/authorize") else {
                throw ExternalOAuthFailure.invalidAuthorization
            }
            endpoint = url; extras = [:]
            if keepSignedIn { requested.insert("offline_access") }
        }
        return try .init(provider: provider, clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            authorizationEndpoint: endpoint, scopes: requested,
            resources: Set(resources.split(whereSeparator: \.isWhitespace).map(String.init)),
            grant: grant, authorizationExtras: extras)
    }
}
