// FloeApp — Explicit speech settings and Keychain-bound credentials.
#if canImport(UIKit)
import Foundation
import Combine
import FloeCore
import FloeSecurity
import FloeProviders

@MainActor
final class TTSSettingsService: ObservableObject {
    @Published private(set) var snapshot: TTSSettingsSnapshot
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let modelStore: LocalSpeechModelStore
    private let resolveConnection: @MainActor (UUID) async throws -> String
    private static let storageKey = "voice.output.settings.v1"
    private static let profilesKey = "voice.output.profiles.v1"
    private static let selectionRevisionKey = "voice.output.selectionRevision"
    private static let firstInstallKey = "voice.output.firstInstallSelection"
    private static let pendingSelectionKey = "voice.output.pendingSelection"
    private var installationObserver: AnyCancellable?
    private struct PendingSelection: Codable { let modelID: String; let revision: Int }
    private var profiles: [String: TTSSettingsSnapshot] = [:]

    init(defaults: UserDefaults = .standard,
         keychain: KeychainStore = KeychainStore(service: "org.floeagent.ios.tts", synchronizable: false),
         resolveConnection: @escaping @MainActor (UUID) async throws -> String = { _ in throw TTSSettingsFailure.missingCredential },
         modelStore: LocalSpeechModelStore = .shared) {
        self.defaults = defaults
        self.modelStore = modelStore
        self.keychain = keychain
        self.resolveConnection = resolveConnection
        profiles = defaults.data(forKey: Self.profilesKey).flatMap { try? JSONDecoder().decode([String: TTSSettingsSnapshot].self, from: $0) } ?? [:]
        snapshot = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(TTSSettingsSnapshot.self, from: $0) } ?? .systemDefault
        installationObserver = NotificationCenter.default.publisher(for: .localSpeechInstallationCompleted)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.finishFirstInstallationSelection() }
            }
        Task { [weak self] in await self?.finishFirstInstallationSelection() }
    }

    func update(_ change: (inout TTSSettingsSnapshot) -> Void) {
        var value = snapshot
        change(&value)
        value.speechRateRatio = min(2, max(0.5, value.speechRateRatio.isFinite ? value.speechRateRatio : 1))
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        defaults.set(encoded, forKey: Self.storageKey)
        profiles[binding(value.provider, value.billingRoute)] = value
        if let encodedProfiles = try? JSONEncoder().encode(profiles) { defaults.set(encodedProfiles, forKey: Self.profilesKey) }
        if snapshot.provider != value.provider || snapshot.modelID != value.modelID || snapshot.voiceID != value.voiceID || snapshot.language != value.language {
            defaults.set(defaults.integer(forKey: Self.selectionRevisionKey) + 1, forKey: Self.selectionRevisionKey)
        }
        snapshot = value
    }

    func voiceDisplayName(for value: TTSSettingsSnapshot) -> String? {
        defaults.dictionary(forKey: "voice.output.voiceNames.v1")?[profileID(value) + "/" + value.voiceID] as? String
    }
    func rememberVoiceName(_ name: String, for value: TTSSettingsSnapshot) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { return }
        var names = defaults.dictionary(forKey: "voice.output.voiceNames.v1") as? [String: String] ?? [:]
        names[profileID(value) + "/" + value.voiceID] = name
        objectWillChange.send()
        defaults.set(names, forKey: "voice.output.voiceNames.v1")
    }

    var configuredProfiles: [TTSSettingsSnapshot] {
        profiles.values.filter { $0.provider.requiresCloudCredential && (hasCredential(for: $0) || $0.connectionProviderID != nil) }
            .sorted { profileID($0) < profileID($1) }
    }
    func profileID(_ value: TTSSettingsSnapshot) -> String { binding(value.provider, value.billingRoute) }
    func profile(provider: TTSSpeakerProvider, route: TTSBillingRoute) -> TTSSettingsSnapshot {
        profiles[binding(provider, route)] ?? TTSSettingsSnapshot(provider: provider, billingRoute: route)
    }
    func hasCredential(for value: TTSSettingsSnapshot) -> Bool {
        (try? keychain.read(account: account(value)))?.isEmpty == false
    }
    func saveProfile(_ value: TTSSettingsSnapshot, credential: String) throws {
        var saved = value
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try keychain.store(account: account(saved), secret: Data(key.utf8)); saved.connectionProviderID = nil }
        guard hasCredential(for: saved) || saved.connectionProviderID != nil else { throw TTSSettingsFailure.missingCredential }
        objectWillChange.send()
        profiles[profileID(saved)] = saved
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        if snapshot.provider == saved.provider && snapshot.billingRoute == saved.billingRoute {
            saved.autoReadEnabled = snapshot.autoReadEnabled; saved.allowBargeIn = snapshot.allowBargeIn
            update { $0 = saved }
        }
    }
    func removeProfile(_ value: TTSSettingsSnapshot) throws {
        try keychain.delete(account: account(value))
        objectWillChange.send()
        profiles.removeValue(forKey: profileID(value))
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        if snapshot.provider == value.provider && snapshot.billingRoute == value.billingRoute {
            update { $0.provider = .apple; $0.voiceID = ""; $0.modelID = ""; $0.connectionProviderID = nil }
        }
    }
    func choose(_ value: TTSSettingsSnapshot) {
        var chosen = value
        chosen.autoReadEnabled = snapshot.autoReadEnabled; chosen.allowBargeIn = snapshot.allowBargeIn
        update { $0 = chosen }
    }
    func install(_ model: LocalSpeechModel) async {
        if model.engine == "qwen3TTS", !defaults.bool(forKey: Self.firstInstallKey) {
            let pending = PendingSelection(modelID: model.id, revision: defaults.integer(forKey: Self.selectionRevisionKey))
            defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingSelectionKey)
        }
        await modelStore.beginInstallation(model)
    }
    func cancelInstallation() async {
        defaults.removeObject(forKey: Self.pendingSelectionKey)
        await modelStore.cancelInstallation()
    }
    private func finishFirstInstallationSelection() async {
        guard !defaults.bool(forKey: Self.firstInstallKey),
              let bytes = defaults.data(forKey: Self.pendingSelectionKey),
              let pending = try? JSONDecoder().decode(PendingSelection.self, from: bytes),
              let model = try? await modelStore.catalog().first(where: { $0.id == pending.modelID }),
              await modelStore.isInstalled(model) else { return }
        defaults.set(true, forKey: Self.firstInstallKey)
        defaults.removeObject(forKey: Self.pendingSelectionKey)
        guard pending.revision == defaults.integer(forKey: Self.selectionRevisionKey) else { return }
        update {
            $0.provider = .onDevice; $0.modelID = model.id; $0.voiceID = "vivian"
            $0.language = nil; $0.connectionProviderID = nil; $0.billingRoute = .payAsYouGo
        }
    }

    func select(_ provider: TTSSpeakerProvider) {
        guard provider != snapshot.provider else { return }
        let route = provider.supportedBillingRoutes.first ?? .payAsYouGo
        restore(provider, route: route)
    }

    func select(_ route: TTSBillingRoute) {
        guard snapshot.provider.supportedBillingRoutes.contains(route), route != snapshot.billingRoute else { return }
        restore(snapshot.provider, route: route)
    }

    private func restore(_ provider: TTSSpeakerProvider, route: TTSBillingRoute) {
        var next = profiles[binding(provider, route)] ?? TTSSettingsSnapshot(provider: provider, billingRoute: route)
        next.autoReadEnabled = snapshot.autoReadEnabled
        next.allowBargeIn = snapshot.allowBargeIn
        update { $0 = next }
    }

    private func binding(_ provider: TTSSpeakerProvider, _ route: TTSBillingRoute) -> String {
        "\(provider.rawValue).\(route.rawValue)"
    }

    func saveCredential(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TTSSettingsFailure.missingCredential }
        try keychain.store(account: account(snapshot), secret: Data(value.utf8))
        update { $0.connectionProviderID = nil }
    }

    func deleteCredential() throws { try keychain.delete(account: account(snapshot)) }

    var hasDedicatedCredential: Bool { (try? keychain.read(account: account(snapshot)))?.isEmpty == false }

    func credential(for settings: TTSSettingsSnapshot) async throws -> String {
        guard settings.provider.requiresCloudCredential else { return "" }
        if let id = settings.connectionProviderID { return try await resolveConnection(id) }
        guard let data = try? keychain.read(account: account(settings)),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw TTSSynthesisError.credentialMissing(provider: settings.provider, route: settings.billingRoute)
        }
        return value
    }

    private func account(_ settings: TTSSettingsSnapshot) -> String {
        "tts.\(settings.provider.rawValue).\(settings.billingRoute.rawValue)"
    }
}

enum TTSSettingsFailure: Error { case missingCredential }

/// Freeze configuration for a spoken answer. Settings changes apply to the next
/// answer; an in-flight segment cannot silently move provider or billing route.
@MainActor
struct ConfiguredTTSSpeechSource {
    let snapshot: TTSSettingsSnapshot
    let settings: TTSSettingsService
    let service: TTSSpeechService
    var overrideCredential: String? = nil

    func synthesize(text: String, sessionID: UUID, segmentIndex: Int) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        let request = TTSSynthesisRequest(
            sessionID: sessionID, segmentIndex: segmentIndex,
            provider: snapshot.provider, billingRoute: snapshot.billingRoute,
            region: snapshot.alibabaRegion, modelID: snapshot.modelID,
            voiceID: snapshot.voiceID, text: text, speechRateRatio: snapshot.speechRateRatio, language: snapshot.language
        )
        let producer = Task { @MainActor in
            do {
                let credential: String
                if let overrideCredential { credential = overrideCredential }
                else { credential = try await settings.credential(for: snapshot) }
                try Task.checkCancellation()
                for try await chunk in service.synthesize(request, credential: credential) {
                    try Task.checkCancellation()
                    try await sender.send(chunk)
                }
                sender.finish()
            } catch { sender.finish(throwing: error) }
        }
        sender.attach(producer)
        return stream
    }
}
#endif
