import Foundation

/// An adapter seam to SkillConfigurationService, never a second credential store.
protocol ExternalOAuthVaultPersistence: Sendable {
    func snapshot() async throws -> ExternalOAuthVaultSnapshot
    func save(_ data: Data, replacing expected: ExternalOAuthVaultSnapshot) async throws -> ExternalOAuthVaultSnapshot
    func refresh(_ data: Data, replacing expected: ExternalOAuthVaultSnapshot) async throws -> ExternalOAuthVaultSnapshot
}

struct ExternalOAuthVaultSnapshot: Sendable, CustomDebugStringConvertible {
    let installationID: String
    let revision: Int?
    let credentialID: UUID?
    let payload: Data?
    var debugDescription: String { "ExternalOAuthVaultSnapshot(<private>)" }
}

/// Only read by native approved consumers. The Skill/model receives an opaque
/// connection reference from the existing configuration service instead.
struct ExternalOAuthSavedGrant: Codable, Sendable, CustomDebugStringConvertible {
    let schemaVersion: Int
    let partition: String
    let accountID: UUID
    let registrationClientID: String
    let registrationIssuer: String
    let clientProfile: ExternalOAuthClientProfile
    let location: ExternalOAuthCredentialContext.Location
    let token: Data
    let clientSecret: Data?
    var debugDescription: String { "ExternalOAuthSavedGrant(<private>)" }

    static func decode(_ data: Data?) throws -> Self? {
        guard let data else { return nil }
        guard data.count <= 32_768,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == 1, value.token.count <= 20_480,
              (value.clientSecret?.count ?? 0) <= 3_072 else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        return value
    }
}

/// One native, context-bound operation. invalidateAndJoin() fences new calls
/// and waits for writes already admitted before it returns. The App's existing
/// lifecycle calls this before uninstall/reconnect/disconnect changes bindings.
actor ExternalOAuthVaultAdapter {
    enum Operation: Sendable { case authorize, refresh }
    nonisolated let context: ExternalOAuthCredentialContext
    private let persistence: any ExternalOAuthVaultPersistence
    private let operation: Operation
    private var initialClientSecret: Data?
    private var expected: ExternalOAuthVaultSnapshot?
    private var active = true
    private var writes = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var didEstablishGrant = false

    init(context: ExternalOAuthCredentialContext, persistence: any ExternalOAuthVaultPersistence,
         operation: Operation, clientSecret: Data? = nil) throws {
        guard (clientSecret?.count ?? 0) <= 3_072 else { throw ExternalOAuthFailure.storageUnavailable }
        self.context = context; self.persistence = persistence; self.operation = operation
        initialClientSecret = clientSecret
    }

    func prepare() async throws {
        try requireActive()
        let snapshot = try await persistence.snapshot()
        try requireActive()
        guard snapshot.installationID == context.installationID else { throw ExternalOAuthFailure.storageUnavailable }
        if operation == .refresh {
            let grant = try ExternalOAuthSavedGrant.decode(snapshot.payload)
            guard grant?.partition == context.vaultPartition,
                  grant?.accountID == context.accountID,
                  snapshot.credentialID != nil else { throw ExternalOAuthFailure.storageUnavailable }
        }
        expected = snapshot
    }

    func readToken() async throws -> Data? {
        let snapshot = try await currentSnapshot()
        guard let grant = try ExternalOAuthSavedGrant.decode(snapshot.payload),
              grant.partition == context.vaultPartition, grant.accountID == context.accountID else {
            if operation == .refresh { throw ExternalOAuthFailure.storageUnavailable }
            return nil
        }
        return grant.token
    }

    func readClientSecret() async throws -> Data? {
        _ = try await currentSnapshot()
        if let initialClientSecret { return initialClientSecret }
        guard let snapshot = expected,
              let grant = try ExternalOAuthSavedGrant.decode(snapshot.payload),
              grant.registrationClientID == context.client.clientID,
              grant.registrationIssuer == context.client.authorizationEndpoint.absoluteString else { return nil }
        return grant.clientSecret
    }

    func writeToken(_ token: Data) async throws {
        try requireActive()
        guard !token.isEmpty, token.count <= 20_480,
              let object = try? JSONSerialization.jsonObject(with: token) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        guard writes == 0 else { throw ExternalOAuthFailure.storageUnavailable }
        writes += 1
        defer {
            writes -= 1
            if writes == 0 {
                let waiters = drainWaiters; drainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let before = try await currentSnapshot()
        let secret = try await readClientSecret()
        try requireActive()
        let grant = ExternalOAuthSavedGrant(schemaVersion: 1, partition: context.vaultPartition,
            accountID: context.accountID, registrationClientID: context.client.clientID,
            registrationIssuer: context.client.authorizationEndpoint.absoluteString,
            clientProfile: context.client, location: context.location, token: token, clientSecret: secret)
        let data = try JSONEncoder().encode(grant)
        guard data.count <= 32_768 else { throw ExternalOAuthFailure.storageUnavailable }
        let after: ExternalOAuthVaultSnapshot
        if operation == .authorize && !didEstablishGrant {
            after = try await persistence.save(data, replacing: before)
        } else {
            guard before.credentialID != nil else { throw ExternalOAuthFailure.storageUnavailable }
            after = try await persistence.refresh(data, replacing: before)
        }
        guard after.installationID == context.installationID else { throw ExternalOAuthFailure.storageUnavailable }
        expected = after; didEstablishGrant = true
        try requireActive()
    }

    func hasPersistedGrant() -> Bool { didEstablishGrant }

    func invalidateAndJoin() async {
        active = false; initialClientSecret = nil
        if writes > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
        expected = nil
    }

    private func currentSnapshot() async throws -> ExternalOAuthVaultSnapshot {
        try requireActive()
        guard let expected else { throw ExternalOAuthFailure.storageUnavailable }
        let current = try await persistence.snapshot()
        try requireActive()
        guard current.installationID == context.installationID,
              current.revision == expected.revision,
              current.credentialID == expected.credentialID,
              current.payload == expected.payload else { throw ExternalOAuthFailure.storageUnavailable }
        return current
    }

    private func requireActive() throws {
        guard active, !Task.isCancelled else { throw ExternalOAuthFailure.cancelled }
    }
}
