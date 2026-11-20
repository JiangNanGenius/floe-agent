// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeMacSelfCore
import FloeProviders

struct HostProviderAccount: Codable, Identifiable {
    static let providerCatalog = ProviderCatalogIndex.loadBundled()
    var profile: ProviderProfile
    var apiKey: String
    var presetID: String?
    var initialRole: ProviderCatalogServiceRole?
    var models: [ModelProfile]
    var id: UUID { profile.id }
    var name: String { profile.displayName ?? profile.baseURL.host ?? profile.kind.rawValue }

    init(profile: ProviderProfile, apiKey: String, presetID: String?, models: [ModelProfile] = []) {
        self.profile = profile
        self.apiKey = apiKey
        self.presetID = presetID
        self.models = models
    }

    init(_ record: HostAgentProvider) {
        self.init(profile: record.profile, apiKey: record.apiKey, presetID: record.presetID, models: [record.model])
    }

    static func configured(name: String?, endpoint: String, protocolKind: ModelProtocol,
                           apiKey: String, presetID: String?, allowsPlainHTTP: Bool) throws -> Self {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FloeError.invalidConfiguration("Invalid provider URL")
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.rangeOfCharacter(from: .controlCharacters) == nil else { throw FloeError.invalidConfiguration("Invalid API key") }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = presetID.flatMap { providerCatalog?.entry(presetID: $0) }
        let kind = ProviderPreset.all.first { $0.id.rawValue == presetID }?.kind ?? entry?.kind ?? .custom
        var profile = ProviderProfile(kind: kind, wireProtocol: protocolKind, baseURL: url,
                                      displayName: label?.isEmpty == false ? label : nil, presetID: presetID)
        profile.toolNameCompatibility = entry?.toolNameCompatibility == true || presetID == "deepseek"
        profile.allowsPlainHTTP = allowsPlainHTTP
        try ProviderConfigurationValidation.validate(profile)
        return Self(profile: profile, apiKey: key, presetID: presetID)
    }

    func profileForEdit(_ draft: ProviderProfile) -> ProviderProfile {
        var edited = draft
        if profile.baseURL == draft.baseURL && profile.wireProtocol == draft.wireProtocol {
            edited = profile
            if profile.presetID != draft.presetID || profile.kind == .custom { edited.kind = draft.kind }
            edited.displayName = draft.displayName
            edited.presetID = draft.presetID
            edited.allowsPlainHTTP = draft.allowsPlainHTTP
        }
        edited.id = id
        edited.isEnabled = profile.isEnabled
        edited.updatedAt = Date()
        return edited
    }

    func record(_ model: ModelProfile) -> HostAgentProvider {
        HostAgentProvider(profile: profile, model: model, apiKey: apiKey, presetID: presetID)
    }
}

extension ProviderCatalogServiceRole {
    func includes(_ model: ModelProfile) -> Bool {
        switch self {
        case .conversation: model.supportsChatAgentSurface
        case .image: model.supportsImageGenerationSurface
        case .video: model.supportsVideoGenerationSurface
        }
    }

    /// In a media editor a manually adopted ID represents this exact media
    /// role, regardless of generic chat metadata returned by a models listing.
    func configureNewModel(_ model: inout ModelProfile) {
        guard self != .conversation else { return }
        model.capabilities = self == .image ? [.imageGeneration, .imageEditing] : [.videoGeneration]
        model.useSurfaces = self == .image ? .imageGeneration : .videoGeneration
        model.isHiddenFromPrimaryPicker = true
        model.explicitCapabilities = nil
    }
}

struct ProviderListEnvelope: Codable {
    static let currentVersion = 2
    var accounts: [HostProviderAccount]
    var selectedModelID: UUID?
    var providers: [HostAgentProvider] { accounts.flatMap { account in account.models.map(account.record) } }
    var selected: HostAgentProvider? { providers.first { $0.model.id == selectedModelID && $0.canSelectAsPrimary } }

    private enum CodingKeys: String, CodingKey { case version, accounts, selectedModelID, providers, selectedProviderID }

    init(accounts: [HostProviderAccount] = [], selectedModelID: UUID? = nil) {
        self.accounts = accounts
        self.selectedModelID = selectedModelID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Int.self, forKey: .version) {
        case 1:
            let records = try values.decode([HostAgentProvider].self, forKey: .providers)
            let selectedProviderID = try values.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
            accounts = records.map(HostProviderAccount.init)
            selectedModelID = records.first { $0.profile.id == selectedProviderID }?.model.id
        case Self.currentVersion:
            accounts = try values.decode([HostProviderAccount].self, forKey: .accounts)
            selectedModelID = try values.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        default:
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported provider catalog")
        }
        try validate()
        normalizeSelection()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(accounts, forKey: .accounts)
        try values.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
    }

    func validate() throws {
        var accountIDs = Set<UUID>()
        var modelIDs = Set<UUID>()
        for account in accounts {
            try ProviderConfigurationValidation.validate(account.profile)
            guard accountIDs.insert(account.id).inserted else { throw ProviderStoreError.inconsistentCatalog }
            var remoteIDs = Set<String>()
            for model in account.models {
                try ProviderConfigurationValidation.validate(model)
                guard model.providerID == account.id, modelIDs.insert(model.id).inserted,
                      remoteIDs.insert(model.remoteModelID).inserted else { throw ProviderStoreError.inconsistentCatalog }
            }
        }
    }

    mutating func normalizeSelection() {
        if selected == nil { selectedModelID = providers.first(where: \.canSelectAsPrimary)?.model.id }
    }

    func accountIndex(_ id: UUID) throws -> Int {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { throw ProviderStoreError.missingRecord }
        return i
    }

    func indices(for modelID: UUID) throws -> (Int, Int) {
        for i in accounts.indices {
            if let j = accounts[i].models.firstIndex(where: { $0.id == modelID }) { return (i, j) }
        }
        throw ProviderStoreError.missingRecord
    }
}

enum ProviderStoreError: Error { case missingRecord, inconsistentCatalog }
