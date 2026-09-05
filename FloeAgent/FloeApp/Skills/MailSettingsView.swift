#if canImport(UIKit)
import SwiftUI
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
        let data = try keychain.read(account: key(account.id, outgoing))
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw MailFailure.authenticationFailed }
        return value
    }
    private func key(_ id: UUID, _ outgoing: Bool) -> String { "\(id.uuidString).\(outgoing ? "smtp" : "incoming")" }
    func save(_ account: MailAccount, incomingPassword: String, outgoingPassword: String) throws {
        try account.validate()
        guard !loadFailed else { throw MailFailure.invalidConfiguration }
        guard accounts.count < 20 || accounts.contains(where: { $0.id == account.id }) else { throw MailFailure.invalidConfiguration }
        let previous = accounts.first { $0.id == account.id }
        // A changed endpoint must not silently receive a previous server's secret.
        guard (!incomingPassword.isEmpty || previous?.incoming == account.incoming),
              (!outgoingPassword.isEmpty || previous?.outgoing == account.outgoing) else { throw MailFailure.authenticationFailed }
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
        defaults.set(try JSONEncoder().encode(updated), forKey: settingsKey); accounts = updated
        try keychain.delete(account: key(account.id, false)); try keychain.delete(account: key(account.id, true))
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

struct MailSettingsView: View {
    @ObservedObject var center: MailSettingsCenter = .shared
    @State private var editing: MailAccount?
    @State private var removing: MailAccount?
    var body: some View {
        List {
            Section {
                ForEach(center.accounts) { account in
                    Button { editing = account } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.address).foregroundStyle(.primary)
                            Text("\(account.incomingProtocol.rawValue.uppercased()) + SMTP · \(account.incoming.host)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("action.delete", role: .destructive) { removing = account } }
                }
                Button("mail.settings.add", systemImage: "plus") { editing = MailAccount() }
            } footer: { Text("mail.settings.footer") }
            if let error = center.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("mail.settings.title")
        .sheet(item: $editing) { account in MailAccountEditor(center: center, initial: account) }
        .alert("mail.settings.remove", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("action.cancel", role: .cancel) { removing = nil }
            Button("action.delete", role: .destructive) {
                guard let removing else { return }
                do { try center.remove(removing) } catch { center.error = MailSettingsCenter.errorText(error) }
                self.removing = nil
            }
        } message: { Text("mail.settings.remove_detail") }
    }
}

private struct MailAccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: MailSettingsCenter
    @State private var account: MailAccount
    @State private var incomingPassword = ""
    @State private var outgoingPassword = ""
    @State private var busy = false
    @State private var result: String?
    @State private var testTask: Task<Void, Never>?
    init(center: MailSettingsCenter, initial: MailAccount) {
        self.center = center; _account = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("mail.settings.identity") {
                    TextField("mail.settings.address", text: $account.address).keyboardType(.emailAddress)
                    Picker("mail.settings.protocol", selection: $account.incomingProtocol) {
                        Text("IMAP").tag(MailIncomingProtocol.imap)
                        Text("POP3").tag(MailIncomingProtocol.pop3)
                    }.onChange(of: account.incomingProtocol) { _, value in
                        account.incoming.port = account.incoming.tls == .implicitTLS ? (value == .imap ? 993 : 995) : (value == .imap ? 143 : 110)
                    }
                }
                serverSection(title: "mail.settings.incoming", server: $account.incoming, password: $incomingPassword)
                serverSection(title: "mail.settings.outgoing", server: $account.outgoing, password: $outgoingPassword)
                Section {
                    Button("mail.settings.test") { test() }
                    if busy { ProgressView() }
                    if let result { Text(result).font(.footnote).accessibilityIdentifier("mail.test.result") }
                } footer: { Text("mail.settings.test_detail") }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(busy)
            .navigationTitle("mail.settings.title").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { testTask?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        do {
                            try center.save(account, incomingPassword: incomingPassword, outgoingPassword: outgoingPassword)
                            incomingPassword = ""; outgoingPassword = ""; dismiss()
                        } catch { result = MailSettingsCenter.errorText(error) }
                    }.disabled(busy)
                }
            }
        }
        .onDisappear { testTask?.cancel(); incomingPassword = ""; outgoingPassword = "" }
    }
    private func serverSection(title: LocalizedStringKey, server: Binding<MailServer>, password: Binding<String>) -> some View {
        Section(title) {
            TextField("mail.settings.host", text: server.host).keyboardType(.URL)
            TextField("mail.settings.port", value: server.port, format: .number.grouping(.never)).keyboardType(.numberPad)
            Picker("mail.settings.tls", selection: server.tls) {
                Text("SSL/TLS").tag(MailTLSMode.implicitTLS)
                Text("STARTTLS").tag(MailTLSMode.startTLS)
            }
            TextField("mail.settings.username", text: server.username)
            SecureField("mail.settings.password", text: password)
        }
    }
    private func test() {
        busy = true; result = nil
        testTask = Task {
            defer { busy = false }
            do {
                try account.validate()
                let incoming = incomingPassword.isEmpty ? try center.password(for: account, outgoing: false) : incomingPassword
                let outgoing = outgoingPassword.isEmpty ? try center.password(for: account, outgoing: true) : outgoingPassword
                // Do not resolve a saved password for an edited server during testing.
                if let old = center.accounts.first(where: { $0.id == account.id }) {
                    guard !incomingPassword.isEmpty || old.incoming == account.incoming,
                          !outgoingPassword.isEmpty || old.outgoing == account.outgoing else { throw MailFailure.authenticationFailed }
                }
                try await MailClient.shared.test(server: account.incoming, protocolName: account.incomingProtocol.rawValue, password: incoming)
                try Task.checkCancellation()
                try await MailClient.shared.test(server: account.outgoing, protocolName: "smtp", password: outgoing)
                result = String(localized: "mail.settings.test_success")
            } catch { if !Task.isCancelled { result = MailSettingsCenter.errorText(error) } }
        }
    }
}
#endif
