import Foundation
import Testing
import FloeCore
import FloeExecution
@testable import FloeApp

private actor MailGrantFixture: ExternalOAuthVaultPersistence {
    enum RefreshBehavior: Equatable { case update, unchanged, replaceBinding }
    let reference: ExternalOAuthConnectionReference
    private var value: ExternalOAuthVaultSnapshot
    var checks = 0, madeReaders = 0, refreshes = 0
    var refreshBehavior: RefreshBehavior = .update
    init(provider: ExternalOAuthProvider = .google, scopes: Set<String>? = nil, resources: Set<String> = [], expires: TimeInterval? = 3600) throws {
        let client = try ExternalOAuthClientProfile(provider: provider,
            clientID: provider == .google ? "synthetic.apps.googleusercontent.com" : UUID().uuidString,
            authorizationEndpoint: URL(string: provider == .google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            scopes: scopes ?? (provider == .google ? ["https://mail.google.com/"] : ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send"]), resources: resources)
        let account = UUID(), credential = UUID()
        let context = try ExternalOAuthCredentialContext(connectorID: provider == .google ? "floe-google-auth" : "floe-microsoft-auth", installationID: "fixture-install", profile: "default", accountID: account, location: .linuxEnvironment("fixture-environment"), client: client)
        reference = .init(skillID: context.connectorID, installationID: context.installationID, profile: "default", target: "local-linux", accountID: account, credentialID: credential, revision: 4, partition: context.vaultPartition)
        var token: [String: Any] = ["access_token": "synthetic-native-access-token", "token_type": "Bearer", "scope": client.scopes.sorted().joined(separator: " ")]
        if let expires { token["issued_at"] = Date().timeIntervalSince1970; token["expires_in"] = expires }
        let grant = ExternalOAuthSavedGrant(schemaVersion: 1, partition: context.vaultPartition, accountID: account,
            registrationClientID: client.clientID, registrationIssuer: client.authorizationEndpoint.absoluteString,
            clientProfile: client, location: context.location, token: try JSONSerialization.data(withJSONObject: token), clientSecret: nil)
        value = .init(installationID: reference.installationID, revision: reference.revision, credentialID: credential, payload: try JSONEncoder().encode(grant))
    }
    func snapshot() async throws -> ExternalOAuthVaultSnapshot { value }
    func save(_ data: Data, replacing expected: ExternalOAuthVaultSnapshot) async throws -> ExternalOAuthVaultSnapshot { throw ExternalOAuthFailure.storageUnavailable }
    func refresh(_ data: Data, replacing expected: ExternalOAuthVaultSnapshot) async throws -> ExternalOAuthVaultSnapshot { throw ExternalOAuthFailure.storageUnavailable }
    func validate() throws { checks += 1 }
    func reader() -> ExternalOAuthNativeTokenReader {
        madeReaders += 1
        return .init(persistence: self, validateConsumer: { try await self.validate() })
    }
    func setRefreshBehavior(_ behavior: RefreshBehavior) { refreshBehavior = behavior }
    func quietRefresh() throws {
        refreshes += 1
        if refreshBehavior == .unchanged { return }
        guard let grant = try ExternalOAuthSavedGrant.decode(value.payload) else { throw ExternalOAuthFailure.storageUnavailable }
        let token = try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-refreshed-access-token", "token_type": "Bearer", "scope": grant.clientProfile.scopes.sorted().joined(separator: " "), "issued_at": Date().timeIntervalSince1970, "expires_in": 3600])
        let updated = ExternalOAuthSavedGrant(schemaVersion: grant.schemaVersion, partition: grant.partition, accountID: grant.accountID,
            registrationClientID: grant.registrationClientID, registrationIssuer: grant.registrationIssuer,
            clientProfile: grant.clientProfile, location: grant.location, token: token, clientSecret: grant.clientSecret)
        value = .init(installationID: value.installationID, revision: value.revision,
            credentialID: refreshBehavior == .replaceBinding ? UUID() : value.credentialID, payload: try JSONEncoder().encode(updated))
    }
    nonisolated func consumer(validateUse: NativeMailOAuthConsumer.Validate? = nil) -> NativeMailOAuthConsumer {
        .init(makeReader: { _,_ in await self.reader() },
              validateUse: validateUse ?? { _,_ in try await self.validate() },
              quietRefresh: { _,_ in try await self.quietRefresh() })
    }
}
private final class MailMemoryKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads = 0, stores = 0
    func read(account: String) throws -> Data {
        try lock.withLock { reads += 1; guard let value = values[account] else { throw MailFailure.authenticationFailed }; return value }
    }
    func store(account: String, secret: Data) throws { lock.withLock { stores += 1; values[account] = secret } }
    func delete(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
    var counts: (reads: Int, stores: Int) { lock.withLock { (reads, stores) } }
}
private actor MailConsumerGate {
    var paused: CheckedContinuation<Void, Never>?
    var arrived = false
    var released = false
    var arrivals: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        arrived = true
        let listeners = arrivals; arrivals.removeAll(); for listener in listeners { listener.resume() }
        await withCheckedContinuation { paused = $0 }
    }
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { released = true; paused?.resume(); paused = nil }
}

@Suite("Native Mail OAuth consumer", .serialized)
struct NativeMailOAuthConsumerTests {
    private func endpoint(_ provider: MailOAuthProvider = .google, outgoing: Bool = false) -> MailServer {
        .init(host: provider == .google ? (outgoing ? "smtp.gmail.com" : "imap.gmail.com") : (outgoing ? "smtp.office365.com" : "outlook.office365.com"),
              port: outgoing ? (provider == .google ? 465 : 587) : 993,
              tls: provider == .microsoft && outgoing ? .startTLS : .implicitTLS, username: "manually-configured@example.com")
    }
    private func use(_ operation: NativeMailOAuthUse.Operation = .read, approved: Bool = false) -> NativeMailOAuthUse {
        .init(operation: operation, runID: UUID(), conversationID: UUID(), approvalGrantID: approved ? UUID() : nil, checkCancellation: {})
    }
    @Test func cachedGrantNeedsNoRefreshAndReturnsOnlyNativeCredential() async throws {
        for provider in [ExternalOAuthProvider.google, .microsoft] {
            let fixture = try MailGrantFixture(provider: provider)
            let core: MailOAuthProvider = provider == .google ? .google : .microsoft
            let value = try await fixture.consumer().credential(reference: fixture.reference, server: endpoint(core), service: .imap, use: use())
            #expect(String(reflecting: value) == "<private mail credential>")
            let refreshes = await fixture.refreshes
            #expect(refreshes == 0)
        }
    }
    @Test func nearExpiryOrMissingExpiryRefreshesExactlyOnceOnSameBinding() async throws {
        for expiry: TimeInterval? in [20, nil] {
            let fixture = try MailGrantFixture(expires: expiry)
            _ = try await fixture.consumer().credential(reference: fixture.reference, server: endpoint(), service: .imap, use: use())
            let refreshes = await fixture.refreshes
            let snapshot = try await fixture.snapshot()
            #expect(refreshes == 1)
            #expect(snapshot.credentialID == fixture.reference.credentialID)
            #expect(snapshot.revision == fixture.reference.revision)
        }
    }
    @Test func changedBindingAndUnrefreshableExpiryFailWithoutInteractiveFallback() async throws {
        for behavior in [MailGrantFixture.RefreshBehavior.replaceBinding, .unchanged] {
            let fixture = try MailGrantFixture(expires: 10); await fixture.setRefreshBehavior(behavior)
            await #expect(throws: MailFailure.authenticationFailed) {
                _ = try await fixture.consumer().credential(reference: fixture.reference, server: endpoint(), service: .imap, use: use())
            }
            let refreshes = await fixture.refreshes
            #expect(refreshes == 1)
        }
    }
    @Test func foreignEndpointMissingApprovalGraphAndIdentityGrantsReject() async throws {
        let endpointFixture = try MailGrantFixture()
        var foreign = endpoint(); foreign.host = "attacker.example"
        await #expect(throws: MailFailure.oauthServerMismatch) {
            _ = try await endpointFixture.consumer().credential(reference: endpointFixture.reference, server: foreign, service: .imap, use: use())
        }
        await #expect(throws: MailFailure.authenticationFailed) {
            _ = try await endpointFixture.consumer().credential(reference: endpointFixture.reference, server: endpoint(outgoing: true), service: .smtp, use: use(.send))
        }
        let made = await endpointFixture.madeReaders
        #expect(made == 0)
        for fixture in [try MailGrantFixture(scopes: ["openid", "email"]),
                        try MailGrantFixture(provider: .microsoft, scopes: ["https://graph.microsoft.com/Mail.Read"]),
                        try MailGrantFixture(resources: ["https://graph.microsoft.com/"])] {
            let core: MailOAuthProvider = fixture.reference.skillID == "floe-google-auth" ? .google : .microsoft
            await #expect(throws: MailFailure.authenticationFailed) {
                _ = try await fixture.consumer().credential(reference: fixture.reference, server: endpoint(core), service: .imap, use: use())
            }
            let refreshes = await fixture.refreshes
            #expect(refreshes == 0)
        }
    }
    @Test @MainActor func settingsPersistReferenceOnlyAndPasswordAccountsReopen() async throws {
        let name = "Floe.NativeMailOAuth.Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let keychain = MailMemoryKeychain()
        let center = MailSettingsCenter(defaults: defaults, keychain: keychain)
        let fixture = try MailGrantFixture()
        center.configureOAuth(consumer: fixture.consumer(), connections: [.init(reference: fixture.reference, title: "Google profile")])
        let account = MailAccount(address: "manually-configured@example.com", incoming: endpoint(), outgoing: endpoint(outgoing: true), oauthConnection: fixture.reference)
        try center.save(account, incomingPassword: "", outgoingPassword: "")
        let bytes = try #require(defaults.data(forKey: "floe.mail.accounts.v1"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("access-token"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("access_token"))
        #expect(keychain.counts.reads == 0 && keychain.counts.stores == 0)
        let restored = MailSettingsCenter(defaults: defaults, keychain: keychain)
        #expect(restored.accounts.first?.oauthConnection == fixture.reference)
        try center.remove(account)
        #expect(center.accounts.isEmpty)
        #expect(keychain.counts.reads == 0 && keychain.counts.stores == 0)
        let stillConnected = try await fixture.snapshot()
        #expect(stillConnected.credentialID == fixture.reference.credentialID)
        let legacy = MailAccount(address: "legacy@example.com", incoming: endpoint(), outgoing: endpoint(outgoing: true))
        try center.save(legacy, incomingPassword: "synthetic-incoming", outgoingPassword: "synthetic-outgoing")
        let password = try await center.credential(for: legacy, outgoing: false, use: use())
        #expect(String(reflecting: password) == "<private mail credential>")
        #expect(try MailSettingsCenter(defaults: defaults, keychain: keychain).password(for: legacy, outgoing: false) == "synthetic-incoming")
    }
    @Test @MainActor func replacementOrDisableDuringCredentialReadCannotReturnLateCredential() async throws {
        for disable in [false, true] {
            let name = "Floe.NativeMailOAuth.CAS.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
            let center = MailSettingsCenter(defaults: defaults, keychain: MailMemoryKeychain())
            let fixture = try MailGrantFixture(), gate = MailConsumerGate()
            let consumer = fixture.consumer(validateUse: { _,_ in await gate.wait() })
            center.configureOAuth(consumer: consumer, connections: [])
            let account = MailAccount(address: "configured@example.com", incoming: endpoint(), outgoing: endpoint(outgoing: true), oauthConnection: fixture.reference)
            try center.save(account, incomingPassword: "", outgoingPassword: "")
            let task = Task { try await center.credential(for: account, outgoing: false, use: use()) }
            await gate.waitForArrival()
            if disable { center.configureOAuth(consumer: nil, connections: []) }
            else { var updated = account; updated.address = "edited@example.com"; try center.save(updated, incomingPassword: "", outgoingPassword: "") }
            await gate.release()
            await #expect(throws: MailFailure.authenticationFailed) { _ = try await task.value }
        }
    }
}
