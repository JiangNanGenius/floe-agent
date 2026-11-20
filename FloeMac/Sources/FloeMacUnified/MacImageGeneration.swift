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
/// Resolves the selected model through its provider account. Existing standalone
/// settings keep their original device-bound Keychain item.
/// Verified images and generation history live in the app's private directory.
@MainActor
final class MacImageGeneration: ObservableObject {

    typealias Configuration = MacMediaProviderConfiguration

    struct ResultItem: Codable, Equatable, Identifiable {
        let id: UUID
        let prompt: String
        let createdAt: Date
        let filename: String
    }

    /// User-controlled options for one generation run. Values mirror the
    /// shared iPad `ImageGenerationPresetResolver` contract; the service
    /// clamps and re-validates them against the provider contract before any
    /// billable request is sent.
    struct GenerationOptions: Equatable {
        /// Requested candidate count; clamped to the provider contract.
        var count: Int
        /// Aspect ratio from the contract; nil keeps the provider default.
        var aspectRatio: String?
        /// Resolution tier from the contract; nil keeps the provider default.
        var resolution: String?
        /// Quality tier from the contract; nil keeps the provider default.
        var quality: String?
        /// Reference images for editing; empty performs a pure generation.
        var referenceImages: [Data]

        init(count: Int = 1, aspectRatio: String? = nil, resolution: String? = nil,
             quality: String? = nil, referenceImages: [Data] = []) {
            self.count = count
            self.aspectRatio = aspectRatio
            self.resolution = resolution
            self.quality = quality
            self.referenceImages = referenceImages
        }
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

    private let providerLink: MacMediaProviderLink
    var providerSelection: MacMediaProviderSelection? { providerLink.selection }
    var modelChoices: [MacMediaProviderSelection.Choice] { providerLink.choices }

    func configuration(for providerOverride: MacMediaProviderSelection?) -> Configuration? {
        if let providerOverride { return providerLink.configuration(for: providerOverride) }
        return configuration
    }

    var hasStandaloneConfiguration: Bool { standaloneConfiguration != nil }
    private var standaloneConfiguration: Configuration?

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
    nonisolated private static let maximumImageBytes = 32 * 1_048_576
    /// One reference image stays within the iPad Files staging bound.
    private static let maximumReferenceImageBytes = 12 * 1_048_576

    init(directory: URL, namespace: String, useKeychain: Bool,
         workspace: HostAgentWorkspace? = nil, preferences: UserDefaults = .standard,
         admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.providerLink = MacMediaProviderLink(workspace: workspace, preferences: preferences, role: .image)
        self.directory = directory
        self.vault = useKeychain
            ? KeychainStore(service: namespace + ".image", synchronizable: false,
                            accessibility: .whenUnlockedThisDeviceOnly)
            : nil
        self.admitWork = admitWork
        loadPersistedState()
        standaloneConfiguration = configuration
        hasCredential = currentKey() != nil
        providerLink.didChange = { [weak self] resolved in
            guard let self else { return }
            configuration = providerLink.selection == nil ? standaloneConfiguration : resolved.map(Configuration.init)
            hasCredential = resolved != nil || (providerLink.selection == nil && currentKey() != nil)
        }
        providerLink.observe { [weak self] in self?.hasStandaloneConfiguration ?? true }
    }

    // MARK: - Shared workbench controls

    func parameterContract(for providerOverride: MacMediaProviderSelection?, operation: RemoteImageOperation = .generate)
        -> ImageGenerationPresetResolver.ParameterContract? {
        guard let config = configuration(for: providerOverride), let route = route(for: config),
              let adapter = ImageProviderAdapterFactory().adapter(for: route.profile),
              adapter.supports(operation, for: route.profile),
              route.model.capabilities.contains(operation == .edit ? .imageEditing : .imageGeneration),
              ProviderConfigurationValidation.issues(for: route.profile).isEmpty,
              ProviderConfigurationValidation.issues(for: route.model).isEmpty else { return nil }
        let contract = ImageGenerationPresetResolver.parameterContract(
            provider: route.profile, model: route.model, operation: operation)
        return contract.countStrategy == .unsupported ? nil : contract
    }

    var maximumReferenceImages: Int { maximumReferenceImages(for: nil) }

    func maximumReferenceImages(for providerOverride: MacMediaProviderSelection?) -> Int {
        max(0, parameterContract(for: providerOverride, operation: .edit)?.maximumReferenceImages ?? 0)
    }

    /// Loads one verified reference image from a local file (for example a
    /// creative-canvas export on this Mac). Remote URLs are not fetched here.
    func referenceImageData(from url: URL) -> Data? {
        guard url.isFileURL,
              let data = try? Self.readFile(url, limit: Self.maximumReferenceImageBytes),
              Self.verifiedImageFormat(data) != nil else { return nil }
        return data
    }

    // MARK: - Configuration

    func bindProvider(accountID: UUID, modelID: UUID) throws {
        try selectProvider(.init(accountID: accountID, modelID: modelID))
    }

    func useStandaloneConfiguration() throws { try selectProvider(nil) }

    private func selectProvider(_ selection: MacMediaProviderSelection?) throws {
        guard !isGenerating else { throw MacImageGenerationError.busy }
        guard let release = admit() else { throw MacImageGenerationError.admissionRefused }
        defer { release() }
        try providerLink.choose(selection)
        notice = nil
    }

    /// Changing the endpoint or preset requires a key for the new connection.
    func save(_ config: Configuration, apiKey: String?) throws {
        guard providerSelection == nil, config.providerSelection == nil else { throw MacImageGenerationError.invalidConfiguration }
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
        standaloneConfiguration = prepared
        configuration = prepared
        hasCredential = true
        notice = nil
    }

    // MARK: - Generation

    /// Bounded candidate batch through the shared iPad batch runner. The
    /// runner never replays a successful request, so a partial provider
    /// failure cannot produce duplicate billable submits.
    func generate(prompt: String, options: GenerationOptions = .init(), providerOverride: MacMediaProviderSelection? = nil) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard let config = configuration(for: providerOverride), keyForRequest(config) != nil else {
            if providerOverride == nil { hasCredential = false }
            notice = String(localized: "mac.images.keyUnavailable")
            return
        }
        guard let route = route(for: config) else {
            notice = String(localized: "mac.images.invalidConfiguration")
            return
        }
        let operation: RemoteImageOperation = options.referenceImages.isEmpty ? .generate : .edit
        let adapter = ImageProviderAdapterFactory().adapter(for: route.profile)
        guard let adapter, adapter.supports(operation, for: route.profile),
              route.model.capabilities.contains(operation == .edit ? .imageEditing : .imageGeneration),
              ProviderConfigurationValidation.issues(for: route.profile).isEmpty,
              ProviderConfigurationValidation.issues(for: route.model).isEmpty else {
            notice = String(localized: "mac.images.invalidConfiguration")
            return
        }
        let contract = ImageGenerationPresetResolver.parameterContract(
            provider: route.profile, model: route.model, operation: operation)
        guard contract.countStrategy != .unsupported else {
            notice = String(localized: "mac.images.invalidConfiguration")
            return
        }
        let count = min(max(1, options.count), max(1, contract.maximumCount))
        guard options.referenceImages.count <= max(0, contract.maximumReferenceImages) else {
            notice = MacImageWorkbenchText.referenceLimitExceeded(contract.maximumReferenceImages)
            return
        }
        let selection = ImageGenerationPresetResolver.applyingDefaults(
            ImageGenerationSelection(aspectRatio: options.aspectRatio, resolution: options.resolution,
                                     quality: options.quality),
            provider: route.profile, model: route.model, operation: operation)
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
                    operation: operation, count: count, referenceCount: options.referenceImages.count)
                let plan = try ImageGenerationBatchPlan(contract: contract, requestedCount: count)
                let outcome = try await ImageGenerationBatchRunner.run(plan: plan) { requestCount in
                    try Task.checkCancellation()
                    guard let apiKey = await self.keyForRequest(config) else { throw MacImageGenerationError.keyRequired }
                    let result = try await adapter.perform(RemoteImageRequest(
                        operation: operation, prompt: text, sourceImages: options.referenceImages,
                        selection: selection, count: requestCount, modelRemoteID: modelID),
                        provider: route.profile, credentials: ProviderCredentials(apiKey: apiKey))
                    return ImageGenerationBatchResponse(
                        images: result.images, revisedPrompt: result.revisedPrompt,
                        metadata: result.metadata)
                }
                try Task.checkCancellation()
                let items = try storeResults(data: outcome.images, prompt: text)
                history.insert(contentsOf: items, at: 0)
                if history.count > Self.maximumHistoryCount {
                    history = Array(history.prefix(Self.maximumHistoryCount))
                }
                if outcome.partialFailure {
                    notice = MacImageWorkbenchText.partialFailure(saved: items.count,
                                                                  missed: outcome.failedCount)
                } else {
                    notice = nil
                }
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
        case let batchError as ImageGenerationBatchError:
            notice = batchError.errorDescription
                ?? String(localized: "mac.images.failed")
        case RemoteImageError.providerRejected(let code, _):
            notice = String(localized: "mac.images.providerRejected \(code)")
        default:
            notice = String(localized: "mac.images.failed")
        }
    }

    // MARK: - Result persistence

    /// Verifies every provider payload, writes each image atomically under a
    /// fresh id, then commits the history index once. A failed or superseded
    /// run can never clobber a previous result, and a staging or index failure
    /// removes every staged blob so no half-published batch survives.
    private func storeResults(data: [Data], prompt: String) throws -> [ResultItem] {
        guard !data.isEmpty else { throw MacImageGenerationError.unsupportedResult }
        do { try Self.ensurePrivateDirectory(directory) } catch { throw MacImageGenerationError.storageFailed }
        var staged: [ResultItem] = []
        func discardStaged() {
            for item in staged { try? FileManager.default.removeItem(at: imageURL(for: item)) }
        }
        for bytes in data {
            guard bytes.count <= Self.maximumImageBytes,
                  let format = Self.verifiedImageFormat(bytes) else {
                discardStaged()
                throw MacImageGenerationError.unsupportedResult
            }
            let id = UUID()
            let item = ResultItem(id: id, prompt: prompt, createdAt: Date(),
                                  filename: "\(id.uuidString).\(format.fileExtension)")
            do { try Self.writeFile(bytes, to: imageURL(for: item)) }
            catch {
                discardStaged()
                throw MacImageGenerationError.storageFailed
            }
            staged.append(item)
        }
        var results = staged + history
        results = Array(results.prefix(Self.maximumHistoryCount))
        do { try persistHistory(results) }
        catch {
            discardStaged()
            throw MacImageGenerationError.storageFailed
        }
        return staged
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
        guard let configuration else { return nil }
        return keyForRequest(configuration)
    }

    private func keyForRequest(_ config: Configuration) -> String? {
        if config.providerSelection != nil { return providerLink.resolve(config)?.apiKey }
        guard config == standaloneConfiguration else { return nil }
        if let vault {
            guard let stored = Self.readStoredSettings(vault), stored.configuration == config,
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

    private func route(for config: Configuration) -> (profile: ProviderProfile, model: ModelProfile)? {
        if config.providerSelection != nil {
            guard let route = providerLink.resolve(config) else { return nil }
            return (route.profile, route.model)
        }
        guard let endpoint = URL(string: config.endpoint) else { return nil }
        return Self.makeRoute(presetID: config.presetID, endpoint: endpoint, modelID: config.modelID,
                              allowLoopbackHTTP: Self.admitsLoopbackHTTP(with: vault))
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
        // Editing capability is advertised so the shared reference contract
        // can resolve; providers without an edit adapter still report a zero
        // reference limit and the workbench hides the reference input.
        let model = ModelProfile(providerID: profile.id, remoteModelID: modelID, displayName: modelID,
                                  limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
                                  capabilities: [.imageGeneration, .imageEditing])
        return (profile, model)
    }

    /// Captures the selected account and endpoint without retaining a key or borrowing workbench history.
    func taskTools(conversationID: UUID, autonomous: Bool = false) -> MacTaskImageTools? {
        var configurations = [configuration].compactMap { $0 }
        for choice in modelChoices {
            guard let c = configuration(for: choice.id), !configurations.contains(c) else { continue }
            configurations.append(c)
        }
        let routes = configurations.compactMap { config -> MacTaskImageTools.Route? in
            guard let pair = route(for: config), keyForRequest(config) != nil,
                  ImageGenerationPresetResolver.isEligible(provider: pair.profile, model: pair.model, operation: .generate),
                  pair.model.capabilities.contains(.imageGeneration) else { return nil }
            var model = pair.model
            var profile = pair.profile
            if config.providerSelection == nil {
                // The standalone workbench constructs transient profiles. Stable public model IDs
                // allow a saved conversation to select the same standalone model after restart.
                profile.id = Self.toolIdentity("provider|" + config.presetID.rawValue + "|" + config.endpoint)
                model.id = Self.toolIdentity("model|" + profile.id.uuidString + "|" + config.modelID)
                model.providerID = profile.id
            }
            return .init(configuration: config, profile: profile, model: model)
        }
        let preferred = routes.first { $0.configuration == configuration }?.model.id
        guard !routes.isEmpty, autonomous || preferred != nil else { return nil }
        return MacTaskImageTools(conversationID: conversationID, autonomous: autonomous, preferredID: preferred, routes: routes, available: { [weak self] route in
            self?.keyForRequest(route.configuration) != nil
        }, request: { [weak self] route, input in
            guard let self else { throw CancellationError() }
            return try await self.performTaskImage(route: route, input: input)
        })
    }

    private func performTaskImage(route: MacTaskImageTools.Route, input: RemoteImageRequest) async throws -> RemoteImageResult {
        try Task.checkCancellation()
        guard let key = keyForRequest(route.configuration),
              let adapter = ImageProviderAdapterFactory().adapter(for: route.profile), adapter.supports(.generate, for: route.profile)
        else { throw MacImageGenerationError.keyRequired }
        let release = try admitWork()
        defer { release() }
        return try await adapter.perform(input, provider: route.profile, credentials: ProviderCredentials(apiKey: key))
    }

    private static func toolIdentity(_ value: String) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(Data(value.utf8)).prefix(32))
        return UUID(uuidString: [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-"))!
    }

    nonisolated static func taskImageFormat(_ data: Data) throws -> ImageGenerationImageFormat {
        guard data.count <= maximumImageBytes, let checked = verifiedImageFormat(data) else {
            throw MacImageGenerationError.unsupportedResult
        }
        let type = try ImageGenerationImageFormatResolver.resolve(data)
        guard checked.fileExtension == type.fileExtension else { throw MacImageGenerationError.unsupportedResult }
        return type
    }

    // MARK: - Verified image bytes

    private enum VerifiedImageFormat: String, CaseIterable {
        case png, jpg, gif, webp
        var fileExtension: String { rawValue }
    }

    private static func isCanonical(_ item: ResultItem) -> Bool {
        VerifiedImageFormat.allCases.contains { item.filename == "\(item.id.uuidString).\($0.fileExtension)" }
    }

    nonisolated private static func verifiedImageFormat(_ data: Data) -> VerifiedImageFormat? {
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

/// EN / zh-CN inline strings for the shared image workbench controls and
/// batch notices, following the `MacProviderText` convention: the Mac host
/// mirrors the system language without adding catalog keys.
enum MacImageWorkbenchText {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    static var aspectRatio: String { t("宽高比", "Aspect Ratio") }
    static var resolution: String { t("分辨率", "Resolution") }
    static var quality: String { t("画质", "Quality") }
    static var count: String { t("数量", "Count") }
    static var `default`: String { t("默认", "Default") }
    static var referenceImages: String { t("参考图片", "Reference Images") }
    static var addReference: String { t("添加参考…", "Add Reference…") }
    static var removeReference: String { t("移除参考", "Remove Reference") }
    static var referenceUnreadable: String {
        t("无法读取该图片，请换一张 PNG、JPEG、GIF 或 WebP。", "Couldn't read that image; choose a PNG, JPEG, GIF or WebP.")
    }
    static var referenceLimitReached: String {
        t("参考图片已达上限。", "The reference image limit is reached.")
    }

    static func referenceLimitExceeded(_ limit: Int) -> String {
        t("参考图片超过该模型上限（最多 \(limit) 张）。",
          "Too many reference images for this model (maximum \(limit)).")
    }

    static func partialFailure(saved: Int, missed: Int) -> String {
        t("已保存 \(saved) 张图片，\(missed) 张未生成。",
          "Saved \(saved) images; \(missed) could not be generated.")
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
