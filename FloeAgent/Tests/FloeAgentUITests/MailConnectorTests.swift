#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
import FloeSecurity
import FloeTools
@testable import FloeApp

/// Deterministic storage-failure tests, not evidence of device Keychain access.
private final class MailTestSecrets: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failSMTPWrite = false
    var failSMTPDelete = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failSMTPWrite, account.hasSuffix(".smtp") { throw KeychainStoreError.unexpectedStatus("fixture") }
        values[account] = secret
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[account] else { throw KeychainStoreError.itemNotFound }; return value
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failSMTPDelete, account.hasSuffix(".smtp") { throw KeychainStoreError.unexpectedStatus("fixture") }
        values[account] = nil
    }
}

@Suite("FloeApp.MailConnector", .serialized)
struct MailConnectorTests {
    @Test @MainActor func registrationsMatchEffectsAndSchemas() throws {
        let registry = ToolRunnerRegistry(); registerMailTools(registry: registry)
        for name in ["mail.accounts", "mail.read", "mail.setRead", "mail.download", "mail.send"] {
            let runner = try #require(registry.runner(named: name))
            #expect(ToolCatalog.allDescriptors.contains { $0.name == name })
            #expect((try? JSONSerialization.jsonObject(with: Data(runner.descriptor.parametersJSON.utf8))) != nil)
            #expect(runner.descriptor.isSideEffecting == !["mail.accounts", "mail.read"].contains(name))
        }
    }
    @Test @MainActor func credentialsAreNotInSettingsAndChangedHostRequiresNewPassword() throws {
        let suite = "floe.mail.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MailTestSecrets()
        let center = MailSettingsCenter(defaults: defaults, keychain: keychain)
        let account = MailAccount(address: "test@example.com", incoming: .init(host: "imap.example.com", port: 993, username: "test"), outgoing: .init(host: "smtp.example.com", port: 465, username: "test"))
        try center.save(account, incomingPassword: "fixture-incoming-secret", outgoingPassword: "fixture-outgoing-secret")
        defer { for item in center.accounts { try? center.remove(item) } }
        #expect(try center.password(for: account, outgoing: false) == "fixture-incoming-secret")
        let data = try #require(defaults.data(forKey: "floe.mail.accounts.v1"))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        var changed = account; changed.incoming.host = "another.example.com"
        #expect(throws: MailFailure.authenticationFailed) { try center.save(changed, incomingPassword: "", outgoingPassword: "") }
        #expect(center.accounts == [account])
        keychain.failSMTPWrite = true
        #expect(throws: KeychainStoreError.self) { try center.save(account, incomingPassword: "new-incoming", outgoingPassword: "new-outgoing") }
        #expect(keychain.count == 2)
        #expect(center.accounts == [account])
        #expect(try center.password(for: account, outgoing: false) == "fixture-incoming-secret")
        #expect(defaults.data(forKey: "floe.mail.accounts.v1") == data)
        keychain.failSMTPDelete = true
        #expect(throws: KeychainStoreError.self) { try center.remove(account) }
        #expect(center.accounts == [account])
        #expect(defaults.data(forKey: "floe.mail.accounts.v1") == data)
        #expect(keychain.count == 1)
        keychain.failSMTPDelete = false
        try center.remove(account)
        #expect(center.accounts.isEmpty)
        #expect(keychain.count == 0)
    }
    @Test @MainActor func corruptSettingsAreNotOverwritten() throws {
        let suite = "floe.mail.corrupt." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid-json".utf8); defaults.set(original, forKey: "floe.mail.accounts.v1")
        let center = MailSettingsCenter(defaults: defaults)
        #expect(center.error != nil)
        let account = MailAccount(address: "test@example.com", incoming: .init(host: "imap.example.com", port: 993, username: "test"), outgoing: .init(host: "smtp.example.com", port: 465, username: "test"))
        #expect(throws: MailFailure.invalidConfiguration) { try center.save(account, incomingPassword: "test", outgoingPassword: "test") }
        #expect(defaults.data(forKey: "floe.mail.accounts.v1") == original)
    }
    @Test @MainActor func sendWithoutApprovalFailsBeforeAccountOrNetworkAccess() async throws {
        let args = MailSendTool.Arguments(accountID: UUID(), requestID: UUID(), to: ["recipient@example.com"], subject: "test", body: "test", attachments: nil)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        await #expect(throws: FloeError.self) { try await MailSendTool().execute(args, context: context) }
    }
    @Test @MainActor func errorKeysResolveAndDoNotEchoSecrets() {
        let text = MailSettingsCenter.errorText(MailFailure.authenticationFailed)
        #expect(!text.contains("mail.error."))
        #expect(!text.isEmpty)
    }
}
#endif
