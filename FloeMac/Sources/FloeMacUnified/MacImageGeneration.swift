// SPDX-License-Identifier: MPL-2.0

import Combine
import Darwin
import FloeCore
import FloeProviders
import FloeSecurity
import Foundation
import ImageIO

/// Durable local image generation for the unified Mac workspace.
///
/// Keeps the provider selection and its key in one device-bound Keychain item.
/// Verified images and generation history live in the app's private directory.
@MainActor
final class MacImageGeneration: ObservableObject {

    struct Configuration: Codable, Equatable {
        var presetID: ProviderTemplateID
        var endpoint: String
        var modelID: String
    }

    struct ResultItem: Codable, Equatable, Identifiable {
        let id: UUID
        let prompt: String
        let createdAt: Date
        let filename: String
    }

    /// Failure surface for `save(_:apiKey:)`; generation failures are
    /// reported through `notice` instead of thrown errors.
    enum MacImageGenerationError: Error, Equatable {
        /// Endpoint, model id or key failed the shared save-rule audit.
        case invalidConfiguration
        /// No key was supplied and the stored one cannot be reused for this
        /// endpoint + preset pair.
        case keyRequired
        /// The Keychain item could not be read or written.
        case keychainUnavailable
        /// The workspace refused admission (shutdown/update in progress).
        case admissionRefused
        /// A generation owns the service; configuration is momentarily frozen.
        case busy
        /// Provider bytes failed verification or exceeded the size bound.
        case unsupportedResult
        /// Result state could not be written to disk.
        case storageFailed
    }

    private struct StoredSettings: Codable {
        let configuration: Configuration
        let apiKey: String
    }

    @Published private(set) var configuration: Configuration?
    @Published private(set) var hasCredential = false
    @Published private(set) var history: [ResultItem] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var notice: String?

    private let directory: URL
    private let vault: KeychainStore?
    private let admitWork: HostAgentWorkspace.AdmitWork
    /// Smoke stand-in used only when Keychain is disabled; never persisted.
    private var sessionKey: String?
    private var generationTask: Task<Void, Never>?

    private static let configFileName = "config.json"
    private static let historyFileName = "history.json"
    private static let keychainAccount = "image-generation.v1"
    private static let historyEnvelopeVersion = 1
    private static let maximumHistoryCount = 200
    private static let maximumHistoryBytes = 1_048_576
    private static let maximumImageBytes = 32 * 1_048_576

    init(directory: URL, namespace: String, useKeychain: Bool,
         admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.directory = directory
        self.vault = useKeychain
            ? KeychainStore(service: namespace + ".image", synchronizable: false,
                            accessibility: .whenUnlockedThisDeviceOnly)
            : nil
        self.admitWork = admitWork
        loadPersistedState()
        hasCredential = currentKey() != nil
    }

    // MARK: - Configuration

    /// Changing the endpoint or preset requires a key for the new connection.
    func save(_ config: Configuration, apiKey: String?) throws {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw MacImageGenerationError.invalidConfiguration }
        guard let endpointURL = URL(string: endpoint),
              let scheme = endpointURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              endpointURL.host?.isEmpty == false else {
            throw MacImageGenerationError.invalidConfiguration
        }
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providedKey = trimmedKey.flatMap { $0.isEmpty ? nil : $0 }
        if let providedKey, providedKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw MacImageGenerationError.invalidConfiguration
        }
        guard !isGenerating else { throw MacImageGenerationError.busy }

        let route = Self.makeRoute(presetID: config.presetID, endpoint: endpointURL, modelID: modelID,
                                   allowLoopbackHTTP: Self.admitsLoopbackHTTP(with: vault))
        let issues = ProviderConfigurationValidation.issues(for: route.profile)
            + ProviderConfigurationValidation.issues(for: route.model)
        guard issues.isEmpty,
              ImageProviderAdapterFactory().adapter(for: route.profile)?.supports(.generate, for: route.profile) == true,
              providedKey.map({ !endpoint.contains($0) }) ?? true else {
            throw MacImageGenerationError.invalidConfiguration
        }

        let prepared = Configuration(presetID: config.presetID, endpoint: endpoint, modelID: modelID)
        guard let release = admit() else { throw MacImageGenerationError.admissionRefused }
        defer { release() }

        let key: String
        if let providedKey {
            key = providedKey
        } else if configuration?.endpoint == prepared.endpoint, configuration?.presetID == prepared.presetID,
                  let previousKey = currentKey() {
            key = previousKey
        } else {
            throw MacImageGenerationError.keyRequired
        }
        if let vault {
            do {
                try vault.store(account: Self.keychainAccount,
                                secret: JSONEncoder().encode(StoredSettings(configuration: prepared, apiKey: key)))
            } catch {
                throw MacImageGenerationError.keychainUnavailable
            }
        } else {
            do { try persistConfiguration(prepared) } catch { throw MacImageGenerationError.storageFailed }
            sessionKey = key
        }
        configuration = prepared
        hasCredential = true
        notice = nil
    }

    // MARK: - Generation

    func generate(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard let config = configuration, let apiKey = currentKey() else {
            hasCredential = false
            notice = String(localized: "mac.images.keyUnavailable")
            return
        }
        guard let endpointURL = URL(string: config.endpoint) else {
            notice = String(localized: "mac.images.invalidConfiguration")
            return
        }
        let route = Self.makeRoute(presetID: config.presetID, endpoint: endpointURL, modelID: config.modelID,
                                   allowLoopbackHTTP: Self.admitsLoopbackHTTP(with: vault))
        let adapter = ImageProviderAdapterFactory().adapter(for: route.profile)
        guard let adapter, adapter.supports(.generate, for: route.profile),
              ProviderConfigurationValidation.issues(for: route.profile).isEmpty,
              ProviderConfigurationValidation.issues(for: route.model).isEmpty else {
            notice = String(localized: "mac.images.invalidConfiguration")
            return
        }
        let selection = ImageGenerationPresetResolver.applyingDefaults(
            ImageGenerationSelection(), provider: route.profile, model: route.model, operation: .generate)
        guard let release = admit() else { return }
        isGenerating = true
        notice = nil
        let modelID = config.modelID
        generationTask = Task { [weak self] in
            guard let self else { release(); return }
            defer { generationTask = nil; isGenerating = false; release() }
            do {
                try ImageGenerationPresetResolver.validateSelection(
                    selection, provider: route.profile, model: route.model,
                    operation: .generate, count: 1, referenceCount: 0)
                let result = try await adapter.perform(RemoteImageRequest(
                    operation: .generate, prompt: text, selection: selection, count: 1,
                    modelRemoteID: modelID), provider: route.profile,
                    credentials: ProviderCredentials(apiKey: apiKey))
                try Task.checkCancellation()
                guard let data = result.images.first else { throw MacImageGenerationError.unsupportedResult }
                let item = try storeResult(data: data, prompt: text)
                history.insert(item, at: 0)
                if history.count > Self.maximumHistoryCount {
                    history = Array(history.prefix(Self.maximumHistoryCount))
                }
                notice = nil
            } catch {
                applyGenerationFailure(error)
            }
        }
    }

    func cancel() {
        generationTask?.cancel()
    }

    /// Location of one durable result; the file may be absent (for example
    /// after manual cleanup), which callers surface as an unavailable image.
    func imageURL(for result: ResultItem) -> URL {
        directory.appendingPathComponent(result.filename)
    }

    func imageData(for result: ResultItem) -> Data? {
        guard Self.isCanonical(result),
              let data = try? Self.readFile(imageURL(for: result), limit: Self.maximumImageBytes),
              Self.verifiedImageFormat(data) != nil else { return nil }
        return data
    }

    // MARK: - Failure surface

    private func applyGenerationFailure(_ error: Error) {
        switch error {
        case is CancellationError:
            notice = String(localized: "mac.images.cancelled")
        case let urlError as URLError where urlError.code == .cancelled:
            notice = String(localized: "mac.images.cancelled")
        case let floeError as FloeError where floeError == .cancelled:
            notice = String(localized: "mac.images.cancelled")
        case MacImageGenerationError.unsupportedResult:
            notice = String(localized: "mac.images.unsupportedResult")
        case MacImageGenerationError.storageFailed:
            notice = String(localized: "mac.images.storageFailed")
        case RemoteImageError.providerRejected(let code, _):
            notice = String(localized: "mac.images.providerRejected \(code)")
        default:
            notice = String(localized: "mac.images.failed")
        }
    }

    // MARK: - Result persistence

    /// Verifies provider bytes, writes the image atomically, then commits the
    /// history record. The image lands under a fresh id so a failed or
    /// superseded run can never clobber a previous result.
    private func storeResult(data: Data, prompt: String) throws -> ResultItem {
        guard data.count <= Self.maximumImageBytes,
              let format = Self.verifiedImageFormat(data) else {
            throw MacImageGenerationError.unsupportedResult
        }
        do { try Self.ensurePrivateDirectory(directory) } catch { throw MacImageGenerationError.storageFailed }
        let id = UUID()
        let item = ResultItem(id: id, prompt: prompt, createdAt: Date(),
                              filename: "\(id.uuidString).\(format.fileExtension)")
        var results = history
        results.insert(item, at: 0)
        results = Array(results.prefix(Self.maximumHistoryCount))
        do {
            try Self.writeFile(data, to: imageURL(for: item))
            try persistHistory(results)
        } catch {
            try? FileManager.default.removeItem(at: imageURL(for: item))
            throw MacImageGenerationError.storageFailed
        }
        return item
    }

    private struct HistoryEnvelope: Codable {
        var version: Int
        var results: [ResultItem]
    }

    private func loadPersistedState() {
        if let vault {
            configuration = Self.readStoredSettings(vault)?.configuration
        } else if let data = try? Self.readFile(directory.appendingPathComponent(Self.configFileName),
                                                limit: Self.maximumHistoryBytes),
           let stored = try? JSONDecoder().decode(Configuration.self, from: data) {
            configuration = stored
        }
        if let data = try? Self.readFile(directory.appendingPathComponent(Self.historyFileName),
                                         limit: Self.maximumHistoryBytes),
           let envelope = try? JSONDecoder().decode(HistoryEnvelope.self, from: data),
           envelope.version == Self.historyEnvelopeVersion {
            history = Array(envelope.results.lazy.filter(Self.isCanonical).prefix(Self.maximumHistoryCount))
        }
    }

    private func persistConfiguration(_ config: Configuration) throws {
        try Self.writeFile(JSONEncoder().encode(config),
                           to: directory.appendingPathComponent(Self.configFileName))
    }

    private func persistHistory(_ results: [ResultItem]) throws {
        let envelope = HistoryEnvelope(version: Self.historyEnvelopeVersion, results: results)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maximumHistoryBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try Self.writeFile(data, to: directory.appendingPathComponent(Self.historyFileName))
    }

    // MARK: - Credentials

    private static func readStoredSettings(_ vault: KeychainStore) -> StoredSettings? {
        guard let data = try? vault.read(account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(StoredSettings.self, from: data)
    }

    private func currentKey() -> String? {
        if let vault {
            guard let stored = Self.readStoredSettings(vault), stored.configuration == configuration,
                  !stored.apiKey.isEmpty else { return nil }
            return stored.apiKey
        }
        return sessionKey
    }

    private func admit() -> HostAgentWorkspace.ReleaseWork? {
        do { return try admitWork() }
        catch {
            notice = String(localized: "host.chat.endingSession")
            return nil
        }
    }

    // MARK: - Route construction

    /// Same admission rule as the model-discovery smoke: with Keychain
    /// disabled, the packaged fixture's exact loopback host may acknowledge
    /// plain HTTP. Production saves stay on the validated https rules.
    private static func admitsLoopbackHTTP(with vault: KeychainStore?) -> Bool {
        #if FLOE_MAC_HOST_SMOKE
        return vault == nil
        #else
        return false
        #endif
    }

    private static func makeRoute(presetID: ProviderTemplateID, endpoint: URL, modelID: String,
                                  allowLoopbackHTTP: Bool) -> (profile: ProviderProfile, model: ModelProfile) {
        let preset = ProviderPreset.imagePresets.first { $0.id == presetID } ?? .custom
        var profile = ProviderProfile(kind: preset.kind, wireProtocol: preset.defaultProtocol,
                                      baseURL: endpoint, displayName: preset.displayName,
                                      presetID: preset.id.rawValue)
        if allowLoopbackHTTP, endpoint.host == "127.0.0.1" {
            profile.allowsPlainHTTP = true
        }
        let model = ModelProfile(providerID: profile.id, remoteModelID: modelID, displayName: modelID,
                                 limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
                                 capabilities: [.imageGeneration])
        return (profile, model)
    }

    // MARK: - Verified image bytes

    private enum VerifiedImageFormat: String, CaseIterable {
        case png, jpg, gif, webp
        var fileExtension: String { rawValue }
    }

    private static func isCanonical(_ item: ResultItem) -> Bool {
        VerifiedImageFormat.allCases.contains { item.filename == "\(item.id.uuidString).\($0.fileExtension)" }
    }

    private static func verifiedImageFormat(_ data: Data) -> VerifiedImageFormat? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8_192).contains(width), (1...8_192).contains(height),
              width * height <= 32_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, options) != nil else { return nil }
        return switch type {
        case "public.png": .png
        case "public.jpeg": .jpg
        case "com.compuserve.gif": .gif
        case "org.webmproject.webp": .webp
        default: nil
        }
    }

    // MARK: - Private file IO

    /// Reads at most `limit` bytes from one exact path: no symlinks, regular
    /// files owned by the current user only. Modeled on the workspace draft
    /// store so untrusted or swapped files fail closed.
    private static func readFile(_ url: URL, limit: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno != ENOENT { throw CocoaError(.fileReadNoPermission) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}

extension MacImageGeneration.MacImageGenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "mac.images.invalidConfiguration")
        case .keyRequired, .keychainUnavailable:
            String(localized: "mac.images.keyUnavailable")
        case .admissionRefused:
            String(localized: "host.chat.endingSession")
        case .busy:
            String(localized: "mac.images.busy")
        case .unsupportedResult:
            String(localized: "mac.images.unsupportedResult")
        case .storageFailed:
            String(localized: "mac.images.storageFailed")
        }
    }
}
