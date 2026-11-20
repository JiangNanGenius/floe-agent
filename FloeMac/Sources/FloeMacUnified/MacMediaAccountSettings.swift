// SPDX-License-Identifier: MPL-2.0
import Combine
import FloeCore
import FloeProviders
import SwiftUI

/// Stable references only. Account edits, key rotation and model availability
/// are resolved against the same catalogue the provider editor updates.
struct MacMediaProviderSelection: Codable, Hashable {
    let accountID: UUID
    let modelID: UUID

    struct Resolved {
        let profile: ProviderProfile
        let model: ModelProfile
        let presetID: ProviderTemplateID
        let apiKey: String
    }

    private static func connection(_ account: HostProviderAccount, role: ProviderCatalogServiceRole) -> (profile: ProviderProfile, presetID: ProviderTemplateID)? {
        guard account.profile.isEnabled, !account.apiKey.isEmpty,
              !account.profile.baseURL.absoluteString.contains(account.apiKey) else { return nil }
        let preset = account.presetID.flatMap(ProviderTemplateID.init(rawValue:))
            .flatMap { id in ProviderPreset.all.first { $0.id == id } }
            ?? ProviderPreset.preset(for: account.profile.kind, baseURL: account.profile.baseURL)
        var profile = account.profile
        // Older Mac accounts kept the chat wire kind even for an explicit media preset.
        if profile.kind == .custom { profile.kind = preset.kind }
        guard ProviderConfigurationValidation.issues(for: profile).isEmpty else { return nil }
        switch role {
        case .image:
            guard ImageProviderAdapterFactory().adapter(for: profile)?.supports(.generate, for: profile) == true else { return nil }
        case .video:
            guard VideoProviderAdapterFactory().adapter(for: profile) != nil else { return nil }
        case .conversation: return nil
        }
        return (profile, preset.id)
    }

    private static func includes(_ model: ModelProfile, accountID: UUID, role: ProviderCatalogServiceRole) -> Bool {
        model.isEnabled && model.providerID == accountID && role.includes(model)
            && ProviderConfigurationValidation.issues(for: model).isEmpty
    }

    func resolve(in accounts: [HostProviderAccount], role: ProviderCatalogServiceRole) -> Resolved? {
        guard let account = accounts.first(where: { $0.id == accountID }),
              let model = account.models.first(where: { $0.id == modelID }),
              Self.includes(model, accountID: accountID, role: role),
              let connection = Self.connection(account, role: role) else { return nil }
        return .init(profile: connection.profile, model: model, presetID: connection.presetID, apiKey: account.apiKey)
    }

    struct Choice: Identifiable {
        let id: MacMediaProviderSelection
        let title: String
    }

    static func choices(in accounts: [HostProviderAccount], role: ProviderCatalogServiceRole) -> [Choice] {
        accounts.flatMap { account -> [Choice] in
            guard connection(account, role: role) != nil else { return [] }
            return account.models.compactMap { model -> Choice? in
                guard includes(model, accountID: account.id, role: role) else { return nil }
                return Choice(id: Self(accountID: account.id, modelID: model.id), title: account.name + " · " + model.displayName)
            }
        }
    }

    static func load(from preferences: UserDefaults, role: ProviderCatalogServiceRole) -> Self? {
        guard let data = preferences.data(forKey: preferenceKey(role)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(_ value: Self?, in preferences: UserDefaults, role: ProviderCatalogServiceRole) throws {
        if let value { preferences.set(try JSONEncoder().encode(value), forKey: preferenceKey(role)) }
        else { preferences.removeObject(forKey: preferenceKey(role)) }
    }

    private static func preferenceKey(_ role: ProviderCatalogServiceRole) -> String {
        "floe.mac.media.default." + role.rawValue
    }
}

struct MacMediaProviderConfiguration: Codable, Equatable {
    var presetID: ProviderTemplateID
    var endpoint: String
    var modelID: String
    var providerSelection: MacMediaProviderSelection? = nil

    init(presetID: ProviderTemplateID, endpoint: String, modelID: String,
         providerSelection: MacMediaProviderSelection? = nil) {
        self.presetID = presetID
        self.endpoint = endpoint
        self.modelID = modelID
        self.providerSelection = providerSelection
    }

    init(_ resolved: MacMediaProviderSelection.Resolved) {
        self.init(presetID: resolved.presetID, endpoint: resolved.profile.baseURL.absoluteString,
                  modelID: resolved.model.remoteModelID,
                  providerSelection: .init(accountID: resolved.profile.id, modelID: resolved.model.id))
    }
}

@MainActor
final class MacMediaProviderLink {
    private weak var workspace: HostAgentWorkspace?
    private let preferences: UserDefaults
    private let role: ProviderCatalogServiceRole
    private(set) var selection: MacMediaProviderSelection?
    private(set) var choices: [MacMediaProviderSelection.Choice] = []
    private var observation: AnyCancellable?
    var catalogueBecameAvailable: (() -> Void)?
    private var awaitingInitialAccounts = true
    var didChange: ((MacMediaProviderSelection.Resolved?) -> Void)?

    init(workspace: HostAgentWorkspace?, preferences: UserDefaults, role: ProviderCatalogServiceRole) {
        self.workspace = workspace
        self.preferences = preferences
        self.role = role
        selection = workspace == nil ? nil : MacMediaProviderSelection.load(from: preferences, role: role)
    }

    func observe(hasStandalone: @escaping () -> Bool) {
        observation = workspace?.$accounts.sink { [weak self] accounts in
            guard let self else { return }
            choices = MacMediaProviderSelection.choices(in: accounts, role: role)
            if selection == nil, !hasStandalone(), let first = choices.first {
                // @Published sends the new catalogue before workspace.accounts changes.
                do {
                    try MacMediaProviderSelection.save(first.id, in: preferences, role: role)
                    selection = first.id
                } catch { return }
            }
            didChange?(selection?.resolve(in: accounts, role: role))
            if awaitingInitialAccounts, !accounts.isEmpty {
                awaitingInitialAccounts = false
                catalogueBecameAvailable?()
            }
        }
    }

    func configuration(for selection: MacMediaProviderSelection) -> MacMediaProviderConfiguration? {
        selection.resolve(in: workspace?.accounts ?? [], role: role).map(MacMediaProviderConfiguration.init)
    }

    func choose(_ newValue: MacMediaProviderSelection?) throws {
        let resolved = newValue?.resolve(in: workspace?.accounts ?? [], role: role)
        guard newValue == nil || resolved != nil else { throw FloeError.invalidConfiguration(
            MacPermissionsText.t("这个模型当前不可用。", "This model is currently unavailable.")) }
        try MacMediaProviderSelection.save(newValue, in: preferences, role: role)
        selection = newValue
        didChange?(resolved)
    }

    /// Checks identity and the exact endpoint/model captured by a submitted
    /// operation. A changed account can serve new work; its key never follows
    /// an old request to the previous endpoint.
    func resolve(_ configuration: MacMediaProviderConfiguration) -> MacMediaProviderSelection.Resolved? {
        guard let ref = configuration.providerSelection,
              let resolved = ref.resolve(in: workspace?.accounts ?? [], role: role),
              MacMediaProviderConfiguration(resolved) == configuration else { return nil }
        return resolved
    }
}

struct MacMediaAccountSettings<Content: View>: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let role: ProviderCatalogServiceRole
    let hasStandaloneConfiguration: Bool
    let selection: () -> MacMediaProviderSelection?
    let bind: (UUID, UUID) throws -> Void
    let useStandalone: () throws -> Void
    let addProvider: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var message: String?
    @State private var selected: MacMediaProviderSelection?

    var body: some View {
        let choices = MacMediaProviderSelection.choices(in: workspace.accounts, role: role)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(role == .image ? MacPermissionsText.t("默认生图模型", "Default image model")
                                    : MacPermissionsText.t("默认视频模型", "Default video model"))
                    .font(.headline)
                Spacer()
                Button(action: addProvider) {
                    Label(MacPermissionsText.t("添加供应商", "Add Provider"), systemImage: "plus")
                }
                .accessibilityIdentifier("settings.providers.addForRole")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeMediaAddFrame = $0 })
                #endif
            }
            .padding()
            if let message { Text(verbatim: message).font(.callout).padding(.horizontal) }
            if choices.isEmpty && !hasStandaloneConfiguration {
                ContentUnavailableView(
                    selected == nil ? MacPermissionsText.t("还没有可用模型", "No models available")
                                    : MacPermissionsText.t("已选模型不可用", "Selected model unavailable"),
                    systemImage: role == .image ? "photo" : "film",
                    description: Text(MacPermissionsText.t("添加供应商，或在已有供应商中启用模型。",
                                                           "Add a provider or enable a model in an existing account.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if hasStandaloneConfiguration {
                        choiceRow(title: MacPermissionsText.t("独立配置", "Standalone configuration"), ref: nil)
                    }
                    if let selected, !choices.contains(where: { $0.id == selected }) {
                        Label(MacPermissionsText.t("已选模型不可用", "Selected model unavailable"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(choices) { choice in choiceRow(title: choice.title, ref: choice.id) }
                }
                .listStyle(.inset)
                if selected == nil && hasStandaloneConfiguration { content() }
            }
        }
        .onChange(of: selection(), initial: true) { _, value in selected = value }
        #if FLOE_MAC_HOST_SMOKE
        .onAppear { workspace.smokeMediaSettingsRole = role.rawValue }
        .onChange(of: role) { _, value in workspace.smokeMediaSettingsRole = value.rawValue }
        .onDisappear { if workspace.smokeMediaSettingsRole == role.rawValue { workspace.smokeMediaSettingsRole = nil } }
        #endif
    }

    private func choiceRow(title: String, ref: MacMediaProviderSelection?) -> some View {
        Button { choose(ref) } label: {
            HStack {
                Text(verbatim: title)
                Spacer()
                if ref == selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ref == selected ? .isSelected : [])
    }

    private func choose(_ ref: MacMediaProviderSelection?) {
        do {
            if let ref { try bind(ref.accountID, ref.modelID) }
            else { try useStandalone() }
            selected = selection()
            message = nil
        } catch { message = error.localizedDescription }
    }
}

/// A creative workbench owns this selection for its draft. Only the settings
/// screen writes the user's default provider.
struct MacCreativeModelMenu: View {
    let choices: [MacMediaProviderSelection.Choice]
    let defaultModelName: String?
    @Binding var selection: MacMediaProviderSelection?
    let openSettings: () -> Void

    private var unavailable: String { MacPermissionsText.t("所选模型不可用", "Selected model unavailable") }
    private var followDefault: String { MacPermissionsText.t("跟随默认模型", "Use default model") }

    var body: some View {
        Menu {
            Picker(MacPermissionsText.t("本次模型", "Model for this run"), selection: $selection) {
                Text(defaultModelName.map { followDefault + " · " + $0 } ?? followDefault)
                    .tag(Optional<MacMediaProviderSelection>.none)
                if let selection, !choices.contains(where: { $0.id == selection }) {
                    Text(unavailable).tag(Optional(selection))
                }
                ForEach(choices) { choice in Text(verbatim: choice.title).tag(Optional(choice.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button(MacPermissionsText.t("管理供应商和模型…", "Manage providers and models…"), action: openSettings)
        } label: {
            Label(title, systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(MacPermissionsText.t("本次模型", "Model for this run"))
        .accessibilityValue(title)
    }

    private var title: String {
        if let selection { return choices.first { $0.id == selection }?.title ?? unavailable }
        return defaultModelName ?? followDefault
    }
}
