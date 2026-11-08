import Foundation
import CryptoKit

/// Constructed by an audited native integration or explicit native settings,
/// never by model-authored URLs or a claimed Skill identifier.
struct ExternalOAuthClientProfile: Sendable, Equatable, Codable {
    enum Grant: String, Sendable, Codable { case authorizationCode, device }
    let provider: ExternalOAuthProvider
    let clientID: String
    let authorizationEndpoint: URL
    let scopes: Set<String>
    let resources: Set<String>
    let grant: Grant
    let authorizationExtras: [String: String]

    private enum CodingKeys: String, CodingKey {
        case provider, clientID, authorizationEndpoint, scopes, resources, grant, authorizationExtras
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: values.decode(ExternalOAuthProvider.self, forKey: .provider),
            clientID: values.decode(String.self, forKey: .clientID),
            authorizationEndpoint: values.decode(URL.self, forKey: .authorizationEndpoint),
            scopes: values.decode(Set<String>.self, forKey: .scopes),
            resources: values.decode(Set<String>.self, forKey: .resources),
            grant: values.decode(Grant.self, forKey: .grant),
            authorizationExtras: values.decode([String: String].self, forKey: .authorizationExtras))
    }

    init(provider: ExternalOAuthProvider, clientID: String, authorizationEndpoint: URL,
         scopes: Set<String>, resources: Set<String> = [], grant: Grant = .authorizationCode,
         authorizationExtras: [String: String] = [:]) throws {
        let url = authorizationEndpoint
        guard !clientID.isEmpty, clientID.utf8.count <= 256,
              !clientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              !scopes.isEmpty, scopes.count <= 64,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512
                  && !$0.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) }),
              resources.count <= 8,
              resources.allSatisfy({ value in
                  guard let resource = URL(string: value) else { return false }
                  return resource.scheme == "https" && resource.host != nil && resource.user == nil
                      && resource.password == nil && resource.fragment == nil
              }),
              authorizationExtras.count <= 8,
              authorizationExtras.allSatisfy({ key, value in
                  ["access_type", "prompt", "login_hint", "response_mode"].contains(key)
                      && !value.isEmpty && value.utf8.count <= 512
                      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { throw ExternalOAuthFailure.invalidAuthorization }
        switch provider {
        case .google:
            guard clientID.hasSuffix(".apps.googleusercontent.com"), url.host == "accounts.google.com",
                  ["/o/oauth2/auth", "/o/oauth2/v2/auth"].contains(url.path) else {
                throw ExternalOAuthFailure.invalidAuthorization
            }
        case .microsoft:
            let path = url.path.split(separator: "/").map(String.init)
            guard UUID(uuidString: clientID) != nil, url.host == "login.microsoftonline.com",
                  path.count == 4, Array(path.suffix(3)) == ["oauth2", "v2.0", "authorize"],
                  ["common", "organizations", "consumers"].contains(path[0]) || UUID(uuidString: path[0]) != nil else {
                throw ExternalOAuthFailure.invalidAuthorization
            }
        }
        self.provider = provider; self.clientID = clientID
        self.authorizationEndpoint = authorizationEndpoint; self.scopes = scopes
        self.resources = resources; self.grant = grant; self.authorizationExtras = authorizationExtras
    }
}

/// A partition key for the EXISTING native credential vault, not a second
/// credential store. The vault adapter must additionally retain its existing
/// installation/revision/CAS checks before returning or replacing token bytes.
struct ExternalOAuthCredentialContext: Sendable, Equatable {
    enum Location: Codable, Sendable, Equatable {
        case nativeDevice
        case linuxEnvironment(String)
    }
    private struct Partition: Codable {
        let schemaVersion: Int
        let connectorID: String
        let installationID: String
        let profile: String
        let accountID: UUID
        let location: Location
        let provider: ExternalOAuthProvider
        let clientID: String
        let authorizationEndpoint: String
        let scopes: [String]
        let resources: [String]
    }
    let vaultPartition: String
    let client: ExternalOAuthClientProfile
    let connectorID: String
    let installationID: String
    let profileName: String
    let accountID: UUID
    let location: Location

    init(connectorID: String, installationID: String, profile: String, accountID: UUID,
         location: Location, client: ExternalOAuthClientProfile) throws {
        for value in [connectorID, installationID, profile] {
            guard !value.isEmpty, value.utf8.count <= 256,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ExternalOAuthFailure.storageUnavailable
            }
        }
        if case .linuxEnvironment(let id) = location {
            guard !id.isEmpty, id.utf8.count <= 256,
                  !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ExternalOAuthFailure.storageUnavailable
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Partition(schemaVersion: 1, connectorID: connectorID,
            installationID: installationID, profile: profile, accountID: accountID,
            location: location, provider: client.provider, clientID: client.clientID,
            authorizationEndpoint: client.authorizationEndpoint.absoluteString,
            scopes: client.scopes.sorted(), resources: client.resources.sorted()))
        vaultPartition = "external-oauth-v1-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.client = client
        self.connectorID = connectorID; self.installationID = installationID
        self.profileName = profile; self.accountID = accountID; self.location = location
    }
}
