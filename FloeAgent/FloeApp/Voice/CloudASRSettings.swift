// FloeApp — Multi-profile cloud speech-recognition settings and migration.
//
// SPDX-License-Identifier: MPL-2.0
//
// One App-owned store for every cloud recognition profile (OpenAI-compatible,
// Volcengine, Alibaba) shared by dictation, continuous voice, file tools and
// video captions. Only profile METADATA is persisted here; credentials live in
// the scoped Keychain item named by `ASRCredentialReference` and are read only
// at request time. No account/membership/developer-test flag exists: a profile
// with supplied configuration is callable by default and real provider errors
// take the ordinary redacted error/fallback path.
//
// The legacy single OpenAI-compatible profile (`voice.assistantAudio.v1` plus
// the App's existing `org.floeagent.ios.assistant-audio` Keychain item) is
// migrated ONCE into a stable UUID profile. The secret is copied, never
// rewritten, logged or exposed; the legacy item is retained so a downgrade
// never loses it. An explicitly stored `whisper-1` model stays `whisper-1`.

import Foundation
import Combine
import FloeCore
import FloeSecurity

@MainActor
final class CloudASRSettingsStore: ObservableObject {
    enum StoreError: Error, Equatable {
        case profileNotFound
        case credentialMissing
        case credentialChangedRequiresNewKey
        case invalidConfiguration(String)
        case keychainUnavailable
    }

    struct PersistedState: Codable, Equatable {
        var schemaVersion: Int
        var profiles: [ASRProfile]
        var primaryProfileID: UUID?
        var legacyAliasProfileID: UUID?
        var migrationCompleted: Bool

        static let empty = PersistedState(
            schemaVersion: 1,
            profiles: [],
            primaryProfileID: nil,
            legacyAliasProfileID: nil,
            migrationCompleted: false)
    }

    /// Minimal decoder for the previous App preference payload. Unknown
    /// fields are ignored; no key is ever present in this JSON.
    private struct LegacyAssistantAudioPreferences: Decodable {
        var asrBaseURL: String?
        var asrModelID: String?
    }

    static let shared = CloudASRSettingsStore()

    static let storageKey = "voice.cloudASR.profiles.v1"
    static let keychainService = "org.floeagent.ios.cloud-asr"
    static let legacyPreferencesKey = "voice.assistantAudio.v1"
    static let legacyKeychainService = "org.floeagent.ios.assistant-audio"
    static let legacyKeychainAccount = "asr.openai-compatible.payAsYouGo"
    static let legacyServiceID = "asr.cloud.openai-compatible"

    @Published private(set) var profiles: [ASRProfile] = []
    @Published private(set) var primaryProfileID: UUID?
    @Published private(set) var legacyAliasProfileID: UUID?

    private let defaults: UserDefaults
    private let keychain: any KeychainProbeStore
    private let legacyKeychain: any KeychainProbeStore
    private var persisted = PersistedState.empty

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainProbeStore = KeychainStore(
            service: CloudASRSettingsStore.keychainService, synchronizable: false),
        legacyKeychain: any KeychainProbeStore = KeychainStore(
            service: CloudASRSettingsStore.legacyKeychainService, synchronizable: false)
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.legacyKeychain = legacyKeychain
        load()
    }

    // MARK: - Read surface

    /// Profiles whose local configuration is valid AND whose key exists.
    /// This is readiness from supplied configuration only: no provider probe,
    /// no account check and no "verified" switch.
    var readyProfiles: [ASRProfile] {
        profiles.filter { isReady($0) }
    }

    var hasAnyReadyProfile: Bool { !readyProfiles.isEmpty }

    func profile(id: UUID?) -> ASRProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func profile(forServiceID serviceID: String) -> ASRProfile? {
        if serviceID == Self.legacyServiceID,
           let alias = legacyAliasProfileID,
           let profile = profile(id: alias) {
            return profile
        }
        let prefix = "asr.cloud."
        guard serviceID.hasPrefix(prefix),
              let id = UUID(uuidString: String(serviceID.dropFirst(prefix.count))) else {
            return nil
        }
        return profile(id: id)
    }

    func serviceID(for profile: ASRProfile) -> String {
        if profile.id == legacyAliasProfileID { return Self.legacyServiceID }
        return "asr.cloud.\(profile.id.uuidString.lowercased())"
    }

    var primaryProfile: ASRProfile? {
        profile(id: primaryProfileID)
    }

    func isReady(_ profile: ASRProfile) -> Bool {
        profile.validationProblem() == nil && hasCredential(for: profile)
    }

    func hasCredential(for profile: ASRProfile) -> Bool {
        guard let reference = profile.credentialReference else { return false }
        guard let data = try? keychain(for: reference).read(account: reference.account) else {
            return false
        }
        guard let value = String(data: data, encoding: .utf8) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reads the secret for one profile at request time. The value never
    /// enters persisted state, logs or descriptions.
    func credential(for profile: ASRProfile) throws -> String {
        guard let reference = profile.credentialReference else {
            throw StoreError.credentialMissing
        }
        let data: Data
        do {
            data = try keychain(for: reference).read(account: reference.account)
        } catch {
            throw StoreError.credentialMissing
        }
        guard let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.credentialMissing
        }
        return value
    }

    // MARK: - Mutation

    @discardableResult
    func addProfile(
        _ profile: ASRProfile,
        credential: String?
    ) throws -> ASRProfile {
        // A duplicate id is an EDIT, never a bypass of the origin/key binding.
        if profiles.contains(where: { $0.id == profile.id }) {
            return try updateProfile(profile, credential: credential)
        }
        var next = try normalized(profile)
        next.credentialReference = reference(for: next.id)
        try storeCredential(credential, for: next)
        profiles.append(next)
        if primaryProfileID == nil { primaryProfileID = next.id }
        persist()
        return next
    }

    @discardableResult
    func updateProfile(
        _ profile: ASRProfile,
        credential: String?
    ) throws -> ASRProfile {
        guard let existing = self.profile(id: profile.id) else {
            throw StoreError.profileNotFound
        }
        var next = try normalized(profile)
        next.credentialReference = existing.credentialReference ?? reference(for: next.id)
        let originChanged = Self.originChanged(from: existing, to: next)
        let trimmedKey = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if originChanged, trimmedKey.isEmpty {
            // A key is bound to a host/provider. Never silently reuse it for a
            // different origin; the user must supply the key for the new one.
            throw StoreError.credentialChangedRequiresNewKey
        }
        if !trimmedKey.isEmpty {
            next.credentialReference = try storeUpdatedCredential(
                trimmedKey, for: next, existing: existing)
        }
        if let index = profiles.firstIndex(where: { $0.id == next.id }) {
            profiles[index] = next
        }
        persist()
        return next
    }

    func removeProfile(id: UUID) {
        guard let existing = profile(id: id) else { return }
        if let reference = existing.credentialReference,
           reference.service == Self.keychainService {
            try? keychain.delete(account: reference.account)
        }
        profiles.removeAll { $0.id == id }
        if primaryProfileID == id {
            primaryProfileID = profiles.first?.id
        }
        if legacyAliasProfileID == id {
            legacyAliasProfileID = nil
        }
        persist()
    }

    func setPrimary(_ id: UUID?) {
        guard let id else {
            primaryProfileID = nil
            persist()
            return
        }
        guard profile(id: id) != nil else { return }
        primaryProfileID = id
        persist()
    }

    // MARK: - Legacy compatibility

    /// Legacy `AssistantAudioService.saveASRProfile(baseURL:modelID:credential:)`
    /// bridge. Updates the migrated legacy profile when present, otherwise
    /// creates one under the stable legacy alias so old service ids keep
    /// resolving.
    func saveLegacyProfile(baseURL: String, modelID: String, credential: String) throws {
        let endpoint: String?
        do {
            endpoint = try OpenAITranscriptionEndpoint.normalized(baseURL)
        } catch {
            throw StoreError.invalidConfiguration("endpoint must be a valid HTTPS address")
        }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 128 else {
            throw StoreError.invalidConfiguration("transcription model is required")
        }
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = legacyAliasProfileID, let existing = profile(id: alias) {
            var next = existing
            next.fileModelID = model
            next.fileEndpoint = endpoint
            if Self.endpointOrigin(existing.fileEndpoint) != Self.endpointOrigin(endpoint),
               key.isEmpty {
                throw StoreError.credentialChangedRequiresNewKey
            }
            // Pass the supplied key through ONE update path: an endpoint
            // origin change is allowed because this call supplies the new
            // key, and the store routes the write to the reference it keeps.
            _ = try updateProfile(next, credential: key)
            return
        }
        let next = ASRProfile.openAICompatible(
            id: legacyAliasProfileID ?? UUID(),
            name: Self.defaultLegacyProfileName,
            fileModelID: model,
            liveModelID: nil,
            fileEndpoint: endpoint,
            liveEndpoint: nil)
        if key.isEmpty { throw StoreError.credentialMissing }
        _ = try addProfile(next, credential: key)
        legacyAliasProfileID = next.id
        if primaryProfileID == nil { primaryProfileID = next.id }
        persist()
    }

    func removeLegacyProfile() {
        guard let alias = legacyAliasProfileID else { return }
        removeProfile(id: alias)
    }

    var legacyValidationProblem: String? {
        guard let alias = legacyAliasProfileID, let profile = profile(id: alias) else {
            return nil
        }
        return profile.validationProblem()
    }

    var hasLegacyProfile: Bool {
        guard let alias = legacyAliasProfileID else { return false }
        return profile(id: alias) != nil
    }

    // MARK: - Presets

    enum ProviderPreset: String, CaseIterable, Sendable {
        case openAI
        case volcenginePayAsYouGo
        case volcengineAgentPlan
        case alibabaPayAsYouGo
        case alibabaTokenPlan

        var provider: ASRProviderKind {
            switch self {
            case .openAI: return .openaiCompatible
            case .volcenginePayAsYouGo, .volcengineAgentPlan: return .volcengine
            case .alibabaPayAsYouGo, .alibabaTokenPlan: return .alibaba
            }
        }

        var route: ASRBillingRoute {
            switch self {
            case .openAI, .volcenginePayAsYouGo, .alibabaPayAsYouGo:
                return .payAsYouGo
            case .volcengineAgentPlan: return .agentPlan
            case .alibabaTokenPlan: return .tokenPlan
            }
        }

        func makeProfile() -> ASRProfile {
            switch self {
            case .openAI:
                return ASRProfile.openAICompatible(
                    name: "OpenAI", fileEndpoint: ASRProviderRouting.openAIFileBase)
            case .volcenginePayAsYouGo:
                return ASRProfile.volcengine(
                    name: "Volcengine", billingRoute: .payAsYouGo)
            case .volcengineAgentPlan:
                return ASRProfile.volcengine(
                    name: "Volcengine Agent Plan", billingRoute: .agentPlan)
            case .alibabaPayAsYouGo:
                return ASRProfile.alibaba(
                    name: "Alibaba", billingRoute: .payAsYouGo)
            case .alibabaTokenPlan:
                // Batch file route by default; a user may explicitly configure
                // a streaming model and live endpoint in the editor.
                return ASRProfile.alibaba(
                    name: "Alibaba Token Plan", billingRoute: .tokenPlan)
            }
        }

        static func preset(for profile: ASRProfile) -> ProviderPreset? {
            switch (profile.provider, profile.billingRoute) {
            case (.openaiCompatible, .payAsYouGo):
                return .openAI
            case (.volcengine, .payAsYouGo): return .volcenginePayAsYouGo
            case (.volcengine, .agentPlan): return .volcengineAgentPlan
            case (.alibaba, .payAsYouGo): return .alibabaPayAsYouGo
            case (.alibaba, .tokenPlan): return .alibabaTokenPlan
            default: return nil
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            migrateLegacyIfNeeded()
            return
        }
        persisted = decoded
        profiles = decoded.profiles
        primaryProfileID = decoded.primaryProfileID
        legacyAliasProfileID = decoded.legacyAliasProfileID
        if !decoded.migrationCompleted {
            persisted.migrationCompleted = true
            persist()
        }
    }

    private func migrateLegacyIfNeeded() {
        var state = PersistedState.empty
        var migratedProfile: ASRProfile?
        if let legacyData = defaults.data(forKey: Self.legacyPreferencesKey),
           let legacy = try? JSONDecoder().decode(
               LegacyAssistantAudioPreferences.self, from: legacyData) {
            let key = (try? legacyKeychain.read(account: Self.legacyKeychainAccount))
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = legacy.asrModelID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = legacy.asrBaseURL?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let configured = !key.isEmpty || !(base ?? "").isEmpty
            if configured {
                let id = UUID()
                var profile = ASRProfile.openAICompatible(
                    id: id,
                    name: Self.defaultLegacyProfileName,
                    fileModelID: (model?.isEmpty == false ? model! : "whisper-1"),
                    liveModelID: nil,
                    fileEndpoint: (base?.isEmpty == false ? base : nil),
                    liveEndpoint: nil)
                var reference = ASRCredentialReference(
                    service: Self.keychainService,
                    account: Self.scopedAccount(for: id))
                // Copy (never move) the legacy secret into the scoped item.
                // If the copy fails, point at the legacy item so the key is
                // still usable rather than silently losing configurability.
                if !key.isEmpty {
                    do {
                        try keychain.store(account: reference.account, secret: Data(key.utf8))
                    } catch {
                        reference = ASRCredentialReference(
                            service: Self.legacyKeychainService,
                            account: Self.legacyKeychainAccount)
                    }
                }
                profile.credentialReference = reference
                migratedProfile = profile
                state.profiles = [profile]
                state.primaryProfileID = id
                state.legacyAliasProfileID = id
            }
        }
        state.migrationCompleted = true
        persisted = state
        profiles = state.profiles
        primaryProfileID = state.primaryProfileID
        legacyAliasProfileID = state.legacyAliasProfileID
        // Only write once there is something to remember (a configured legacy
        // profile or an explicit later mutation). A fresh install stays
        // storage-free until the user adds a profile.
        if migratedProfile != nil {
            persist()
        }
    }

    private func persist() {
        persisted.schemaVersion = 1
        persisted.profiles = profiles
        persisted.primaryProfileID = primaryProfileID
        persisted.legacyAliasProfileID = legacyAliasProfileID
        persisted.migrationCompleted = true
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Helpers

    private static let defaultLegacyProfileName = "OpenAI"

    private func reference(for id: UUID) -> ASRCredentialReference {
        ASRCredentialReference(
            service: Self.keychainService,
            account: Self.scopedAccount(for: id))
    }

    private static func scopedAccount(for id: UUID) -> String {
        "profile.\(id.uuidString.lowercased())"
    }

    private func keychain(for reference: ASRCredentialReference) -> any KeychainProbeStore {
        reference.service == Self.legacyKeychainService ? legacyKeychain : keychain
    }

    /// Writes a newly supplied secret for an edit. If the existing profile
    /// still points at the legacy Keychain item (migration copy failed), a
    /// successful scoped write atomically moves the reference so later reads
    /// see the new secret. A failed scoped write keeps/uses the existing
    /// reference instead of splitting the credential across two stores.
    private func storeUpdatedCredential(
        _ key: String,
        for profile: ASRProfile,
        existing: ASRProfile
    ) throws -> ASRCredentialReference {
        let scoped = reference(for: profile.id)
        if existing.credentialReference?.service == Self.keychainService {
            do {
                try keychain.store(account: scoped.account, secret: Data(key.utf8))
                return scoped
            } catch {
                throw StoreError.keychainUnavailable
            }
        }
        do {
            try keychain.store(account: scoped.account, secret: Data(key.utf8))
            return scoped
        } catch {
            // The scoped store is unavailable; keep the already-working
            // legacy reference rather than writing a secret nothing reads.
            if let legacy = existing.credentialReference {
                do {
                    try legacyKeychain.store(account: legacy.account, secret: Data(key.utf8))
                    return legacy
                } catch {
                    throw StoreError.keychainUnavailable
                }
            }
            throw StoreError.keychainUnavailable
        }
    }

    private func storeCredential(_ credential: String?, for profile: ASRProfile) throws {
        let key = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, let reference = profile.credentialReference else { return }
        do {
            try keychain(for: reference).store(account: reference.account, secret: Data(key.utf8))
        } catch {
            throw StoreError.keychainUnavailable
        }
    }

    private func normalized(_ profile: ASRProfile) throws -> ASRProfile {
        var next = profile
        next.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.name.isEmpty { next.name = profile.provider.defaultProfileName }
        next.fileModelID = profile.fileModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        next.liveModelID = Self.normalizedOptional(profile.liveModelID)
        next.fileEndpoint = Self.normalizedOptional(profile.fileEndpoint)
        next.liveEndpoint = Self.normalizedOptional(profile.liveEndpoint)
        next.resourceID = Self.normalizedOptional(profile.resourceID)
        if let problem = next.validationProblem() {
            throw StoreError.invalidConfiguration(problem)
        }
        return next
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func originChanged(from old: ASRProfile, to new: ASRProfile) -> Bool {
        old.provider != new.provider
            || old.billingRoute != new.billingRoute
            || endpointOrigin(old.resolvedFileEndpoint) != endpointOrigin(new.resolvedFileEndpoint)
            || endpointOrigin(old.resolvedLiveEndpoint) != endpointOrigin(new.resolvedLiveEndpoint)
    }

    /// Scheme/host/port only. Path changes (a different relay prefix on the
    /// same host) are not an origin change; a different host is.
    static func endpointOrigin(_ raw: String?) -> String? {
        guard let raw = normalizedOptional(raw),
              let components = URLComponents(string: raw),
              let host = components.host?.lowercased() else { return nil }
        let scheme = components.scheme?.lowercased() ?? ""
        let port = components.port.map(String.init) ?? ""
        return "\(scheme)://\(host):\(port)"
    }
}

// Keep the public surface small and explicit: every caller receives profile
// metadata only, and reads the secret through the store at request time.
extension CloudASRSettingsStore.StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "The recognition profile no longer exists."
        case .credentialMissing:
            return "This recognition profile has no credential."
        case .credentialChangedRequiresNewKey:
            return "The endpoint changed. Enter the key for the new endpoint."
        case .invalidConfiguration(let reason):
            return reason
        case .keychainUnavailable:
            return "The credential could not be stored in the Keychain."
        }
    }
}
