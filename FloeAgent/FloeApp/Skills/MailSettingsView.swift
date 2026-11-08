#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeExecution
import FloeSecurity


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
        .task { await center.refreshOAuthConnections?() }
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
                MailIdentitySection(address: $account.address, incomingProtocol: $account.incomingProtocol, usesOAuth: account.oauthConnection != nil)
                    .onChange(of: account.incomingProtocol, updateIncomingPort)
                    .onChange(of: account.oauthConnection) { if account.oauthConnection != nil { account.incomingProtocol = .imap } }
                Section {
                    Picker("mail.settings.authentication", selection: Binding(get: { account.oauthConnection == nil ? "password" : "oauth" }, set: { mode in
                        incomingPassword = ""; outgoingPassword = ""
                        if mode == "password" { account.oauthConnection = nil }
                        else if let first = center.oauthConnections.first { account.oauthConnection = first.reference }
                    })) {
                        Text("mail.settings.password").tag("password")
                        if !center.oauthConnections.isEmpty || account.oauthConnection != nil { Text("mail.settings.connected_account").tag("oauth") }
                    }
                    if account.oauthConnection != nil {
                        Picker("mail.settings.connected_account", selection: Binding(get: { selectedConnectionID }, set: { id in
                            if let choice = center.oauthConnections.first(where: { $0.id == id }) { account.oauthConnection = choice.reference }
                        })) {
                            if let current = account.oauthConnection, !center.oauthConnections.contains(where: { $0.reference == current }) {
                                Text("mail.settings.connection_unavailable").tag("unavailable")
                            }
                            ForEach(center.oauthConnections) { choice in Text(choice.title).tag(choice.id) }
                        }
                        Text("mail.settings.oauth_address_detail").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                MailServerSection(title: "mail.settings.incoming", server: $account.incoming, password: $incomingPassword, usesOAuth: account.oauthConnection != nil)
                MailServerSection(title: "mail.settings.outgoing", server: $account.outgoing, password: $outgoingPassword, usesOAuth: account.oauthConnection != nil)
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
                    Button("action.save", action: save).disabled(busy)
                }
            }
        }
        .onDisappear { testTask?.cancel(); incomingPassword = ""; outgoingPassword = "" }
    }
    private var selectedConnectionID: String {
        center.oauthConnections.first(where: { $0.reference == account.oauthConnection })?.id ?? "unavailable"
    }
    private func updateIncomingPort() {
        switch (account.incomingProtocol, account.incoming.tls) {
        case (.imap, .implicitTLS): account.incoming.port = 993
        case (.imap, .startTLS): account.incoming.port = 143
        case (.pop3, .implicitTLS): account.incoming.port = 995
        case (.pop3, .startTLS): account.incoming.port = 110
        }
    }
    private func save() {
        do {
            try center.save(account, incomingPassword: incomingPassword, outgoingPassword: outgoingPassword)
            incomingPassword = ""; outgoingPassword = ""; dismiss()
        } catch { result = MailSettingsCenter.errorText(error) }
    }
    private func test() {
        busy = true; result = nil
        testTask = Task {
            defer { busy = false }
            do {
                try account.validate()
                if account.oauthConnection != nil {
                    let incoming = try await center.credential(for: account, outgoing: false, use: .settingsTest)
                    try await MailClient.shared.test(server: account.incoming, protocolName: account.incomingProtocol.rawValue, credential: incoming)
                    try Task.checkCancellation()
                    let outgoing = try await center.credential(for: account, outgoing: true, use: .settingsTest)
                    try await MailClient.shared.test(server: account.outgoing, protocolName: "smtp", credential: outgoing)
                    if !Task.isCancelled { result = String(localized: "mail.settings.test_success") }
                    return
                }
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

private struct MailIdentitySection: View {
    @Binding var address: String
    @Binding var incomingProtocol: MailIncomingProtocol
    var usesOAuth = false
    var body: some View {
        Section("mail.settings.identity") {
            TextField("mail.settings.address", text: $address).keyboardType(.emailAddress)
            Picker("mail.settings.protocol", selection: $incomingProtocol) {
                Text("IMAP").tag(MailIncomingProtocol.imap)
                if !usesOAuth { Text("POP3").tag(MailIncomingProtocol.pop3) }
            }
        }
    }
}

private struct MailServerSection: View {
    let title: LocalizedStringKey
    @Binding var server: MailServer
    @Binding var password: String
    var usesOAuth = false
    var body: some View {
        Section(title) {
            TextField("mail.settings.host", text: $server.host).keyboardType(.URL)
            TextField("mail.settings.port", value: $server.port, format: .number.grouping(.never)).keyboardType(.numberPad)
            Picker("mail.settings.tls", selection: $server.tls) {
                Text("SSL/TLS").tag(MailTLSMode.implicitTLS)
                Text("STARTTLS").tag(MailTLSMode.startTLS)
            }
            TextField("mail.settings.username", text: $server.username)
            if !usesOAuth { SecureField("mail.settings.password", text: $password) }
        }
    }
}
#endif
