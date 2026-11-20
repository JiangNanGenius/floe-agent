// SPDX-License-Identifier: MPL-2.0
import FloeCore
import SwiftUI

struct MacProviderOptionsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let record: HostAgentProvider
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var compatibility: Bool
    @State private var headers: String
    @State private var name: String
    @State private var hidden: Bool
    @State private var omitReasoning: Bool
    @State private var error: String?

    init(workspace: HostAgentWorkspace, record: HostAgentProvider) {
        self.workspace = workspace
        self.record = record
        _enabled = State(initialValue: record.profile.isEnabled)
        _compatibility = State(initialValue: record.profile.toolNameCompatibility)
        _headers = State(initialValue: record.profile.nonSecretHeaders.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        _name = State(initialValue: record.model.displayName)
        _hidden = State(initialValue: record.model.isHiddenFromPrimaryPicker ?? false)
        _omitReasoning = State(initialValue: record.model.effectiveOmitReasoningParameters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("mac.provider.options").font(.headline).padding()
            Form {
                Section {
                    Toggle("mac.provider.enabled", isOn: $enabled)
                    Toggle("mac.provider.compatibleTools", isOn: $compatibility)
                    TextField("mac.provider.headers", text: $headers, axis: .vertical).lineLimit(2...5)
                        .font(.system(.body, design: .monospaced))
                } header: { Text(record.displayTitle) } footer: { Text("mac.provider.headersHelp") }
                Section {
                    TextField("mac.provider.modelName", text: $name)
                    Toggle("mac.provider.hidePrimary", isOn: $hidden)
                    Toggle("mac.provider.omitReasoning", isOn: $omitReasoning)
                } header: { Text(record.model.remoteModelID) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                Spacer()
                Button("mac.provider.optionsCancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("mac.provider.optionsSave", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isSending)
            }.padding()
        }.frame(minWidth: 450, minHeight: 340)
    }

    private func save() {
        guard let parsed = Self.parseHeaders(headers) else {
            error = String(localized: "mac.provider.invalidHeaders")
            return
        }
        var profile = record.profile
        profile.nonSecretHeaders = parsed
        if let issue = ProviderConfigurationValidation.issues(for: profile).first {
            let language = ProviderValidationLanguage.resolve(Bundle.main.preferredLocalizations.first ?? "en")
            error = ProviderConfigurationValidation.message(for: issue, language: language)
            return
        }
        if workspace.updateProviderOptions(providerID: record.profile.id, modelID: record.model.id, enabled: enabled,
            compatibility: compatibility, headers: parsed, displayName: name, hidden: hidden, omitReasoning: omitReasoning) {
            dismiss()
        } else { error = workspace.notice ?? String(localized: "host.chat.providerSaveFailed") }
    }

    /// All accepted names are HTTP tokens. Never let a repeated spelling alter the effective header.
    static func parseHeaders(_ text: String) -> [String: String]? {
        let tokenChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        var result: [String: String] = [:]
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.unicodeScalars.allSatisfy(tokenChars.contains),
                  !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil,
                  seen.insert(key.lowercased()).inserted else { return nil }
            result[key] = value
        }
        return result
    }
}
