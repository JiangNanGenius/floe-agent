import Foundation
import CoreFoundation

import FloeExecution

struct ExternalOAuthNativeAccessToken: Sendable, CustomDebugStringConvertible, CustomStringConvertible {
    let bytes: Data
    let expiresAt: Date
    var debugDescription: String { "ExternalOAuthNativeAccessToken(<private>)" }
    var description: String { "<private>" }
}

enum ExternalOAuthNativeTokenFailure: Error, Sendable { case changed, insufficientScope, needsRefresh }

/// Cached native use requires no Linux startup. The caller supplies the
/// existing approved native consumer/task and current Skill checks; refresh
/// goes through NativeExternalOAuthConnections with its explicit management
/// owner. This is not a model tool or a public token endpoint.
struct ExternalOAuthNativeTokenReader: Sendable {
    let persistence: any ExternalOAuthVaultPersistence
    let validateConsumer: @Sendable () async throws -> Void

    func read(reference: ExternalOAuthConnectionReference, provider: ExternalOAuthProvider,
              scopes: Set<String>, resources: Set<String> = [], now: Date = Date()) async throws -> ExternalOAuthNativeAccessToken {
        try await validateConsumer()
        let snapshot = try await persistence.snapshot()
        guard snapshot.installationID == reference.installationID, snapshot.revision == reference.revision,
              snapshot.credentialID == reference.credentialID,
              let grant = try ExternalOAuthSavedGrant.decode(snapshot.payload), grant.partition == reference.partition,
              grant.accountID == reference.accountID, grant.clientProfile.provider == provider,
              reference.target == "local-linux",
              reference.skillID == (provider == .google ? "floe-google-auth" : "floe-microsoft-auth") else {
            throw ExternalOAuthNativeTokenFailure.changed
        }
        let context = try ExternalOAuthCredentialContext(connectorID: reference.skillID,
            installationID: reference.installationID, profile: reference.profile, accountID: grant.accountID,
            location: grant.location, client: grant.clientProfile)
        guard context.vaultPartition == grant.partition,
              grant.registrationClientID == grant.clientProfile.clientID,
              grant.registrationIssuer == grant.clientProfile.authorizationEndpoint.absoluteString else {
            throw ExternalOAuthNativeTokenFailure.changed
        }
        guard !scopes.isEmpty, scopes.isSubset(of: grant.clientProfile.scopes),
              resources.isSubset(of: grant.clientProfile.resources) else { throw ExternalOAuthNativeTokenFailure.insufficientScope }
        guard let object = try? JSONSerialization.jsonObject(with: grant.token) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty, access.utf8.count <= 16_384,
              access.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              (object["token_type"] as? String)?.lowercased() == "bearer" else {
            throw ExternalOAuthNativeTokenFailure.changed
        }
        if let actualScope = object["scope"] as? String,
           !scopes.isSubset(of: Set(actualScope.split(separator: " ").map(String.init))) {
            throw ExternalOAuthNativeTokenFailure.insufficientScope
        }
        func positiveNumber(_ key: String) -> Double? {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.doubleValue
        }
        guard let issued = positiveNumber("issued_at"), let expires = positiveNumber("expires_in"),
              issued <= now.timeIntervalSince1970 + 60,
              (issued + expires).isFinite, issued + expires > now.timeIntervalSince1970 + 60 else {
            throw ExternalOAuthNativeTokenFailure.needsRefresh
        }
        try await validateConsumer()
        let current = try await persistence.snapshot()
        guard current.installationID == snapshot.installationID, current.revision == snapshot.revision,
              current.credentialID == snapshot.credentialID, current.payload == snapshot.payload else {
            throw ExternalOAuthNativeTokenFailure.changed
        }
        return .init(bytes: Data(access.utf8), expiresAt: Date(timeIntervalSince1970: issued + expires))
    }
}
