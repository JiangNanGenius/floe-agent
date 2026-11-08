import Foundation
import Combine
import FloeCore
import FloeExecution
import FloeSecurity

@MainActor
final class MailSettingsCenter: ObservableObject {
    static let shared = MailSettingsCenter()
    @Published private(set) var accounts: [MailAccount] = []
    @Published var error: String?
    private let defaults: UserDefaults
    private let keychain: any KeychainProbeStore
    @Published private(set) var oauthConnections: [NativeMailOAuthConnectionChoice] = []
    var refreshOAuthConnections: (@MainActor @Sendable () async -> Void)?
    private var oauthConsumer: NativeMailOAuthConsumer?
    private var oauthGeneration = UUID()
    private var loadFailed = false
    private let settingsKey = "floe.mail.accounts.v1"
    init(defaults: UserDefaults = .standard, keychain: any KeychainProbeStore = KeychainStore(service: "org.floeagent.mail", synchronizable: false)) {
        self.defaults = defaults; self.keychain = keychain
        if let data = defaults.data(forKey: settingsKey) {
            do { accounts = try JSONDecoder().decode([MailAccount].self, from: data) }
            catch { self.loadFailed = true; self.error = String(localized: "mail.settings.load_error") }
        }
    }
    func password(for account: MailAccount, outgoing: Bool) throws -> String {
        guard account.oauthConnection == nil else { throw MailFailure.authenticationFailed }
        let data = try keychain.read(account: key(account.id, outgoing))
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw MailFailure.authenticationFailed }
        return value
    }
    /// Called by the existing native connection owner after connect/refresh,
    /// disable or disconnect. Construction/configuration starts no worker.
    func configureOAuth(consumer: NativeMailOAuthConsumer?, connections: [NativeMailOAuthConnectionChoice]) {
        oauthGeneration = UUID(); oauthConsumer = consumer
        oauthConnections = connections
    }
    func credential(for account: MailAccount, outgoing: Bool, use: NativeMailOAuthUse) async throws -> MailCredential {
        try use.validate()
        let original = accounts.first { $0.id == account.id }
        if use.operation != .settingsTest { guard original == account else { throw MailFailure.invalidConfiguration } }
        guard let reference = account.oauthConnection else { return .password(try password(for: account, outgoing: outgoing)) }
        guard let consumer = oauthConsumer else { throw MailFailure.authenticationFailed }
        try account.validate()
        let generation = oauthGeneration
        let credential = try await consumer.credential(reference: reference, server: outgoing ? account.outgoing : account.incoming,
            service: outgoing ? .smtp : .imap, use: use)
        try use.validate()
        guard generation == oauthGeneration, accounts.first(where: { $0.id == account.id }) == original else {
            throw MailFailure.authenticationFailed
        }
        return credential
    }
    private func key(_ id: UUID, _ outgoing: Bool) -> String { "\(id.uuidString).\(outgoing ? "smtp" : "incoming")" }
    func save(_ account: MailAccount, incomingPassword: String, outgoingPassword: String) throws {
        try account.validate()
        guard !loadFailed else { throw MailFailure.invalidConfiguration }
        guard accounts.count < 20 || accounts.contains(where: { $0.id == account.id }) else { throw MailFailure.invalidConfiguration }
        let previous = accounts.first { $0.id == account.id }
        if account.oauthConnection != nil {
            guard incomingPassword.isEmpty, outgoingPassword.isEmpty else { throw MailFailure.invalidConfiguration }
            // Same immutable account-ID edit semantics as password accounts;
            // only the opaque connection reference is persisted, never tokens.
            var saved = account
            if previous != nil { saved.id = UUID() }
            var updated = accounts.filter { $0.id != account.id }; updated.append(saved)
            let encoded = try JSONEncoder().encode(updated)
            defaults.set(encoded, forKey: settingsKey); accounts = updated
            if previous != nil {
                try? keychain.delete(account: key(account.id, false)); try? keychain.delete(account: key(account.id, true))
            }
            return
        }
        // A changed endpoint must not silently receive a previous server's secret.
        guard (!incomingPassword.isEmpty || previous?.oauthConnection == nil && previous?.incoming == account.incoming),
              (!outgoingPassword.isEmpty || previous?.oauthConnection == nil && previous?.outgoing == account.outgoing) else { throw MailFailure.authenticationFailed }
        let incoming = incomingPassword.isEmpty ? try password(for: account, outgoing: false) : incomingPassword
        let outgoing = outgoingPassword.isEmpty ? try password(for: account, outgoing: true) : outgoingPassword
        guard incoming.utf8.count <= 1024, outgoing.utf8.count <= 1024,
              !incoming.contains(where: { $0.isNewline || $0 == "\0" }),
              !outgoing.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailFailure.invalidConfiguration }
        // A new immutable ID on every edit keeps the old profile/credentials
        // usable if saving either new credential fails halfway through.
        var saved = account
        if previous != nil { saved.id = UUID() }
        var updated = accounts.filter { $0.id != account.id }; updated.append(saved)
        let encoded = try JSONEncoder().encode(updated)
        do {
            try keychain.store(account: key(saved.id, false), secret: Data(incoming.utf8))
            try keychain.store(account: key(saved.id, true), secret: Data(outgoing.utf8))
        } catch {
            try? keychain.delete(account: key(saved.id, false))
            try? keychain.delete(account: key(saved.id, true))
            throw error
        }
        defaults.set(encoded, forKey: settingsKey)
        accounts = updated
        if saved.id != account.id { try? keychain.delete(account: key(account.id, false)); try? keychain.delete(account: key(account.id, true)) }
    }
    func remove(_ account: MailAccount) throws {
        let updated = accounts.filter { $0.id != account.id }
        let encoded = try JSONEncoder().encode(updated)
        // Retain the profile until both deletions succeed so a locked/failing
        // Keychain leaves a retryable account, not unreachable stored secrets.
        if account.oauthConnection == nil {
            try keychain.delete(account: key(account.id, false)); try keychain.delete(account: key(account.id, true))
        }
        defaults.set(encoded, forKey: settingsKey); accounts = updated
    }
    func account(_ id: UUID) throws -> MailAccount {
        guard let account = accounts.first(where: { $0.id == id }) else { throw MailFailure.invalidConfiguration }
        return account
    }
    static func errorText(_ error: Error) -> String {
        guard let failure = error as? MailFailure else { return String(localized: "mail.settings.credentials_error") }
        let key = "mail.error." + failure.rawValue
        return String(localized: String.LocalizationValue(key))
    }
}
