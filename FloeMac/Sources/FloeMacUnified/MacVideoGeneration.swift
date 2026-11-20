// SPDX-License-Identifier: MPL-2.0

import Combine
import Darwin
import FloeCore
import FloeProviders
import FloeSecurity
import Foundation

/// Durable local video generation for the unified Mac workspace.
///
/// Mirrors `MacImageGeneration`: the provider selection and its key live in
/// one device-bound Keychain item, and verified videos plus the job history
/// live in the app's private directory. Video suppliers are asynchronous
/// provider tasks, so the lifecycle is submit → persist the provider task ID
/// → poll → bounded download → verified local file. Pending jobs recover
/// across relaunches through `resume()` (re-polling the provider for a fresh
/// result URL, since signed URLs are credentials and are never persisted);
/// an identical active request attaches to its durable job instead of paying
/// twice, and a submission whose outcome is unknown is never resubmitted.
@MainActor
final class MacVideoGeneration: ObservableObject {

    typealias Configuration = MacMediaProviderConfiguration

    struct JobItem: Codable, Equatable, Identifiable {
        let id: UUID
        let prompt: String
        var state: MediaGenerationJobState
        let createdAt: Date
        let options: VideoGenerationOptions
        /// Configuration the job was submitted under. Polling and cancelling
        /// only ever use this exact endpoint, and only while the store still
        /// holds the matching credential, so a key can never cross accounts
        /// after a settings change or a relaunch.
        let configuration: Configuration
        /// SHA-256 of the inline reference/first-frame bytes. Distinguishes
        /// otherwise identical requests with different first frames; the
        /// inline bytes themselves are never persisted.
        let referenceFingerprint: String?
        var progress: Double?
        var providerTaskID: String?
        var filename: String?
        var error: String?
    }

    /// Failure surface for `save(_:apiKey:)`; generation failures are
    /// reported through `notice` and the per-job `error` instead.
    enum MacVideoGenerationError: Error, Equatable {
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
        /// Provider bytes failed verification, exceeded the size bound, the
        /// result URL was not an allowed download origin, or the result
        /// download was rejected.
        case unsupportedResult
        /// Result state could not be written to disk.
        case storageFailed
        /// The selected route does not accept a local reference image, or the
        /// image is not a supported bounded regular file.
        case referenceUnsupported
        /// The result download link returned an unsuccessful HTTP status.
        case downloadFailed(Int)
    }

    /// A submit failure after bytes may have shipped: the provider may hold a
    /// paid task this install never learned the ID of. Distinct from cancel
    /// and from a confirmed failure.
    private struct SubmitOutcomeUncertain: Error, LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    @Published private(set) var configuration: Configuration?
    @Published private(set) var hasCredential = false
    @Published private(set) var history: [JobItem] = []
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
    private var foregroundJobID: UUID?
    @Published private var resumedTasks: [UUID: Task<Void, Never>] = [:]

    private static let configFileName = "config.json"
    private static let historyFileName = "history.json"
    private static let keychainAccount = "video-generation.v1"
    private static let historyEnvelopeVersion = 1
    private static let maximumHistoryCount = 200
    private static let maximumHistoryBytes = 1_048_576
    /// Hard ceiling for one provider video; the bounded download stops as
    /// soon as the stream exceeds it.
    private static let maximumVideoBytes = 512 * 1_048_576

    init(directory: URL, namespace: String, useKeychain: Bool,
         workspace: HostAgentWorkspace? = nil, preferences: UserDefaults = .standard,
         admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.providerLink = MacMediaProviderLink(workspace: workspace, preferences: preferences, role: .video)
        self.directory = directory
        self.vault = useKeychain
            ? KeychainStore(service: namespace + ".video", synchronizable: false,
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
        providerLink.catalogueBecameAvailable = { [weak self] in
            // Published account snapshots arrive immediately before assignment.
            Task { [weak self] in self?.resume() }
        }
        providerLink.observe { [weak self] in self?.hasStandaloneConfiguration ?? true }
    }

    // MARK: - Configuration

    func bindProvider(accountID: UUID, modelID: UUID) throws {
        try selectProvider(.init(accountID: accountID, modelID: modelID))
    }

    func useStandaloneConfiguration() throws { try selectProvider(nil) }

    private func selectProvider(_ selection: MacMediaProviderSelection?) throws {
        guard !isGenerating else { throw MacVideoGenerationError.busy }
        guard let release = admit() else { throw MacVideoGenerationError.admissionRefused }
        defer { release() }
        try providerLink.choose(selection)
        notice = nil
    }

    /// Changing the endpoint or preset requires a key for the new connection.
    func save(_ config: Configuration, apiKey: String?) throws {
        guard providerSelection == nil, config.providerSelection == nil else { throw MacVideoGenerationError.invalidConfiguration }
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw MacVideoGenerationError.invalidConfiguration }
        guard let endpointURL = URL(string: endpoint),
              let scheme = endpointURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              endpointURL.host?.isEmpty == false else {
            throw MacVideoGenerationError.invalidConfiguration
        }
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providedKey = trimmedKey.flatMap { $0.isEmpty ? nil : $0 }
        if let providedKey, providedKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw MacVideoGenerationError.invalidConfiguration
        }
        guard !isGenerating, resumedTasks.isEmpty else { throw MacVideoGenerationError.busy }

        let route = Self.makeRoute(configuration: Configuration(presetID: config.presetID, endpoint: endpoint, modelID: modelID),
                                   allowLoopbackHTTP: Self.admitsLoopbackHTTP(with: vault))
        let issues = ProviderConfigurationValidation.issues(for: route.profile)
            + ProviderConfigurationValidation.issues(for: route.model)
        guard issues.isEmpty,
              VideoProviderAdapterFactory().adapter(for: route.profile) != nil,
              providedKey.map({ !endpoint.contains($0) }) ?? true else {
            throw MacVideoGenerationError.invalidConfiguration
        }

        let prepared = Configuration(presetID: config.presetID, endpoint: endpoint, modelID: modelID)
        guard let release = admit() else { throw MacVideoGenerationError.admissionRefused }
        defer { release() }

        let key: String
        if let providedKey {
            key = providedKey
        } else if configuration?.endpoint == prepared.endpoint, configuration?.presetID == prepared.presetID,
                  let previousKey = currentKey() {
            key = previousKey
        } else {
            throw MacVideoGenerationError.keyRequired
        }
        if let vault {
            do {
                try vault.store(account: Self.keychainAccount,
                                secret: JSONEncoder().encode(StoredSettings(configuration: prepared, apiKey: key)))
            } catch {
                throw MacVideoGenerationError.keychainUnavailable
            }
        } else {
            do { try persistConfiguration(prepared) } catch { throw MacVideoGenerationError.storageFailed }
            sessionKey = key
        }
        standaloneConfiguration = prepared
        configuration = prepared
        hasCredential = true
        notice = nil
    }

    // MARK: - Generation

    func parameterContract(for providerOverride: MacMediaProviderSelection?) -> VideoParameterContract? {
        guard let config = configuration(for: providerOverride), let route = route(for: config) else { return nil }
        return VideoModelRegistry.contract(model: route.model, provider: route.profile)
    }

    func supportsReferenceImage(for providerOverride: MacMediaProviderSelection?) -> Bool {
        guard let config = configuration(for: providerOverride), let route = route(for: config) else { return false }
        return VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: route.profile.kind, modelRemoteID: route.model.remoteModelID, baseURL: route.profile.baseURL)
    }

    func generate(prompt: String, options: VideoGenerationOptions = .init(), referenceImage: URL? = nil,
                  providerOverride: MacMediaProviderSelection? = nil) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard let config = configuration(for: providerOverride), key(for: config) != nil else {
            if providerOverride == nil { hasCredential = false }
            notice = String(localized: "mac.videos.keyUnavailable")
            return
        }
        guard let route = route(for: config),
              let adapter = VideoProviderAdapterFactory().adapter(for: route.profile),
              ProviderConfigurationValidation.issues(for: route.profile).isEmpty,
              ProviderConfigurationValidation.issues(for: route.model).isEmpty else {
            notice = String(localized: "mac.videos.invalidConfiguration")
            return
        }
        let normalized: VideoGenerationOptions
        do {
            normalized = try VideoRequestValidator.validate(
                options, contract: VideoModelRegistry.contract(model: route.model, provider: route.profile),
                modelRemoteID: config.modelID)
        } catch {
            applyGenerationFailure(error)
            return
        }
        let reference: (url: URL, fingerprint: String)?
        if let referenceImage {
            do {
                reference = try Self.resolveReferenceImage(referenceImage, route: route, options: normalized)
            } catch {
                applyGenerationFailure(error)
                return
            }
        } else {
            reference = nil
        }
        // An identical active request (including the same first frame)
        // attaches to its durable job instead of paying for a second
        // submission; a still-unresolved submission is reported but never
        // replayed.
        if let existing = history.first(where: {
            !$0.state.isTerminal && $0.prompt == text && $0.options == normalized
                && $0.configuration == config && $0.referenceFingerprint == reference?.fingerprint
        }) {
            guard existing.providerTaskID != nil else {
                notice = String(localized: "mac.videos.submitUncertain")
                return
            }
            guard resumedTasks[existing.id] == nil, foregroundJobID != existing.id else { return }
            guard let release = admit() else { return }
            isGenerating = true
            notice = nil
            foregroundJobID = existing.id
            generationTask = Task { [weak self] in
                guard let self else { release(); return }
                defer { generationTask = nil; foregroundJobID = nil; isGenerating = false; release() }
                await runJob(itemID: existing.id, adapter: adapter, profile: route.profile,
                             reference: reference?.url, foreground: true)
            }
            return
        }
        guard let release = admit() else { return }
        isGenerating = true
        notice = nil
        let item = JobItem(id: UUID(), prompt: text, state: .preparing, createdAt: Date(),
                           options: normalized, configuration: config,
                           referenceFingerprint: reference?.fingerprint)
        var next = [item] + history
        while next.count > Self.maximumHistoryCount,
              let index = next.lastIndex(where: { $0.state.isTerminal }) { next.remove(at: index) }
        do {
            guard next.count <= Self.maximumHistoryCount else { throw MacVideoGenerationError.busy }
            try persistHistory(next)
            history = next
        } catch {
            isGenerating = false
            release()
            notice = String(localized: "mac.videos.storageFailed")
            return
        }
        foregroundJobID = item.id
        let itemID = item.id
        generationTask = Task { [weak self] in
            guard let self else { release(); return }
            defer { generationTask = nil; foregroundJobID = nil; isGenerating = false; release() }
            await runJob(itemID: itemID, adapter: adapter, profile: route.profile,
                         reference: reference?.url, foreground: true)
        }
    }

    /// Cancels one job, or everything in flight when no item is given. A
    /// resumed (background) job can be cancelled individually.
    func cancel(_ item: JobItem? = nil) {
        if let item {
            if foregroundJobID == item.id { generationTask?.cancel() }
            resumedTasks[item.id]?.cancel()
        } else {
            generationTask?.cancel()
        }
    }

    /// Location of one durable result; nil unless the job is ready and the
    /// verified file is still present, so callers never surface a missing or
    /// swapped clip as playable.
    func videoURL(for item: JobItem) -> URL? {
        guard item.state == .ready, Self.isCanonical(item), let filename = item.filename else { return nil }
        let url = directory.appendingPathComponent(filename)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid() else { return nil }
        return url
    }

    // MARK: - Recovery

    /// Resumes each submitted job through its original account and endpoint,
    /// with a currently usable credential, holding the same Bridge
    /// activity lease as a foreground generation for the whole recovery.
    /// Jobs whose settings were changed or whose submit never confirmed a
    /// provider task ID are left untouched so nothing is silently resubmitted
    /// or cross-accounted. Signed result URLs are never persisted, so a
    /// restarted download re-polls the provider for a fresh one.
    func isWorking(on id: UUID) -> Bool { foregroundJobID == id || resumedTasks[id] != nil }

    func canResume(_ item: JobItem) -> Bool {
        !item.state.isTerminal && item.providerTaskID != nil && key(for: item) != nil
    }

    func resume(_ chosenID: UUID? = nil) {
        for item in history where !item.state.isTerminal && (chosenID == nil || chosenID == item.id) {
            guard item.providerTaskID != nil, resumedTasks[item.id] == nil,
                  foregroundJobID != item.id, canResume(item), let route = route(for: item.configuration),
                  let release = try? admitWork() else { continue }
            guard let adapter = VideoProviderAdapterFactory().adapter(for: route.profile),
                  ProviderConfigurationValidation.issues(for: route.profile).isEmpty else {
                release()
                continue
            }
            let itemID = item.id
            resumedTasks[itemID] = Task { [weak self] in
                guard let self else { release(); return }
                defer { resumedTasks.removeValue(forKey: itemID); release() }
                await runJob(itemID: itemID, adapter: adapter, profile: route.profile,
                             reference: nil, foreground: false)
            }
        }
    }

    // MARK: - Job lifecycle

    /// One shared state machine for a foreground generation and for resumed
    /// jobs: submit (persisting the provider task ID before any poll), poll
    /// with bounded backoff, then the bounded verified download. Result URLs
    /// live only in this in-memory flow; only the pollable provider task ID is
    /// durable.
    private func runJob(itemID: UUID, adapter: any VideoProviderAdapter,
                        profile: ProviderProfile,
                        reference: URL?, foreground: Bool) async {
        do {
            let immediate = try await submitIfNeeded(itemID: itemID, adapter: adapter,
                                                     profile: profile, reference: reference)
            if let url = immediate?.resultURL {
                try await downloadResult(itemID: itemID, url: url,
                                         expiresAt: immediate?.resultURLExpiresAt,
                                         profile: profile)
            } else {
                try await pollUntilResolved(itemID: itemID, adapter: adapter,
                                            profile: profile)
            }
            if foreground { notice = nil }
        } catch is CancellationError {
            await handleCancellation(itemID: itemID, adapter: adapter, profile: profile,
                                     foreground: foreground)
        } catch let urlError as URLError where urlError.code == .cancelled {
            await handleCancellation(itemID: itemID, adapter: adapter, profile: profile,
                                     foreground: foreground)
        } catch let floeError as FloeError where floeError == .cancelled {
            await handleCancellation(itemID: itemID, adapter: adapter, profile: profile,
                                     foreground: foreground)
        } catch MacVideoGenerationError.keyRequired {
            // Preserve a submitted job until the original account becomes available again.
            if let item = history.first(where: { $0.id == itemID }), item.providerTaskID == nil {
                failJob(itemID: itemID, error: MacVideoGenerationError.keyRequired, foreground: foreground)
            } else if foreground { notice = String(localized: "mac.videos.keyUnavailable") }
        } catch let uncertain as SubmitOutcomeUncertain {
            // The provider may hold a task this install never learned the ID
            // of. Keep the job preparing with an honest note; never mark it
            // failed (it may have succeeded) and never resubmit it.
            try? updateItem(itemID) { $0.error = uncertain.detail }
            if foreground { notice = String(localized: "mac.videos.submitUncertain") }
        } catch {
            if let item = history.first(where: { $0.id == itemID }), item.state == .downloading,
               (error is URLError || error is CocoaError) {
                try? updateItem(itemID) { $0.error = error.localizedDescription }
                if foreground { notice = String(localized: "mac.videos.retryDownload") }
            } else {
                failJob(itemID: itemID, error: error, foreground: foreground)
            }
        }
    }

    private func submitIfNeeded(itemID: UUID, adapter: any VideoProviderAdapter,
                                profile: ProviderProfile,
                                reference: URL?) async throws -> RemoteVideoSubmission? {
        guard let item = history.first(where: { $0.id == itemID }),
              item.providerTaskID == nil else { return nil }
        guard let key = key(for: item) else { throw MacVideoGenerationError.keyRequired }
        let request = RemoteVideoRequest(
            prompt: item.prompt, modelRemoteID: item.configuration.modelID,
            options: item.options, referenceAssetURLs: reference.map { [$0] } ?? [])
        do {
            let submission = try await adapter.submit(
                request, provider: profile, credentials: ProviderCredentials(apiKey: key))
            // The remote ID is durable before any poll, so a relaunch can
            // always reconcile exactly this task instead of paying twice.
            // The signed result URL is a credential and is never persisted.
            try updateItem(itemID) {
                $0.providerTaskID = submission.providerTaskID
                $0.state = submission.resultURL == nil ? .submitted : .downloading
                $0.error = nil
            }
            try Task.checkCancellation()
            return submission
        } catch let videoError as RemoteVideoError {
            // Adapter-side request validation fails before any network bytes
            // ship: a real rejection. Everything else is an uncertain submit.
            if case .invalidRequest = videoError { throw videoError }
            if case .requestFailed(let message) = videoError,
               [400, 401, 402, 403, 404, 405, 422, 429].contains(where: { message.hasPrefix("HTTP " + String($0) + ":") }) {
                throw videoError
            }
            throw SubmitOutcomeUncertain(detail: videoError.localizedDescription)
        } catch {
            throw SubmitOutcomeUncertain(detail: error.localizedDescription)
        }
    }

    private func pollUntilResolved(itemID: UUID, adapter: any VideoProviderAdapter,
                                   profile: ProviderProfile) async throws {
        var attempt = 0
        var consecutiveErrors = 0
        while true {
            try Task.checkCancellation()
            guard let item = history.first(where: { $0.id == itemID }) else { return }
            // Settings changed: stop polling without claiming a terminal
            // state. The persisted state resumes if the settings return.
            guard let key = key(for: item), let taskID = item.providerTaskID else { throw MacVideoGenerationError.keyRequired }
            let status: RemoteVideoStatus
            do {
                status = try await adapter.status(
                    taskID: taskID, modelRemoteID: item.configuration.modelID,
                    provider: profile, credentials: ProviderCredentials(apiKey: key))
            } catch {
                try Task.checkCancellation()
                consecutiveErrors += 1
                // Preserve its remote ID; the user can resume a disconnected job.
                if consecutiveErrors >= 3 {
                    try updateItem(itemID) { $0.error = error.localizedDescription }
                    return
                }
                try? updateItem(itemID) { $0.error = error.localizedDescription }
                try await Task.sleep(nanoseconds: Self.pollDelay(attempt: attempt))
                attempt += 1
                continue
            }
            consecutiveErrors = 0
            switch status.state {
            case .completed:
                guard let url = status.resultURL else {
                    try updateItem(itemID) {
                        $0.state = .failed
                        $0.error = String(localized: "mac.videos.error.completedNoURL")
                    }
                    return
                }
                // The signed URL is consumed in memory only; a restart
                // re-polls the provider for a fresh one.
                try updateItem(itemID) {
                    $0.state = .downloading
                    $0.error = nil
                }
                try await downloadResult(itemID: itemID, url: url,
                                         expiresAt: status.resultURLExpiresAt,
                                         profile: profile)
                return
            case .failed, .cancelled, .expired:
                try updateItem(itemID) {
                    $0.state = status.state
                    $0.error = status.error.map { SecretRedactor.redact($0, secret: key) }
                }
                return
            default:
                try updateItem(itemID) {
                    $0.state = .running
                    $0.progress = status.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                    $0.error = nil
                }
                try await Task.sleep(nanoseconds: Self.pollDelay(attempt: attempt))
                attempt += 1
            }
        }
    }

    /// Downloads one completed result with the shared redirect policy, a hard
    /// byte ceiling and signature verification, then commits the job as ready
    /// only after the verified bytes are atomically on disk. The download
    /// origin must be HTTPS, or the exact debug loopback fixture origin.
    private func downloadResult(itemID: UUID, url: URL, expiresAt: Date?,
                                profile: ProviderProfile) async throws {
        guard let item = history.first(where: { $0.id == itemID }), let key = key(for: item) else {
            throw MacVideoGenerationError.keyRequired
        }
        guard Self.allowsResultDownload(url: url, profile: profile,
                                        allowLoopbackHTTP: Self.admitsLoopbackHTTP(with: vault)) else {
            throw MacVideoGenerationError.unsupportedResult
        }
        if let expiresAt, expiresAt <= Date() {
            try updateItem(itemID) {
                $0.state = .expired
                $0.error = String(localized: "mac.videos.error.expired")
            }
            return
        }
        // The Google API key is attached only to the exact configured trusted
        // Google API origin; a storage/CDN host named by the response never
        // receives it. Ark and DashScope use pre-signed URLs with no header.
        var headers: [String: String] = [:]
        if profile.kind == .googleGemini, !key.isEmpty,
           let host = url.host, let trustedHost = profile.baseURL.host,
           url.scheme?.lowercased() == profile.baseURL.scheme?.lowercased(),
           (url.port ?? 443) == (profile.baseURL.port ?? 443),
           host.caseInsensitiveCompare(trustedHost) == .orderedSame {
            headers["x-goog-api-key"] = key
        }
        var request = URLRequest(url: url)
        for (header, value) in headers { request.setValue(value, forHTTPHeaderField: header) }
        let file = try await MacVideoDownload.fetch(request: request, directory: directory, jobID: itemID, byteLimit: Self.maximumVideoBytes)
        try updateItem(itemID) {
            $0.filename = file.lastPathComponent
            $0.state = .ready
            $0.error = nil
        }
    }

    /// HTTPS origins only, except the packaged debug fixture whose result
    /// file comes back from the exact configured loopback origin.
    private static func allowsResultDownload(url: URL, profile: ProviderProfile,
                                             allowLoopbackHTTP: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard allowLoopbackHTTP, scheme == "http",
              url.host == "127.0.0.1", url.host == profile.baseURL.host,
              let port = url.port, let basePort = profile.baseURL.port, port == basePort else {
            return false
        }
        return true
    }

    // MARK: - Cancel

    /// Truthful cancellation, shared by the foreground task and resumed jobs.
    /// A job cancelled before its provider task ID was persisted is closed
    /// locally without claiming a remote cancellation; a failed provider
    /// cancel asks the provider for the real outcome first.
    private func handleCancellation(itemID: UUID, adapter: any VideoProviderAdapter,
                                    profile: ProviderProfile,
                                    foreground: Bool) async {
        guard let item = history.first(where: { $0.id == itemID }) else { return }
        // URLSession inherits cancellation. Finish the remote cancel before releasing the job lease.
        await Task { @MainActor in
            await settleCancellation(item: item, adapter: adapter, profile: profile, foreground: foreground)
        }.value
    }

    private func settleCancellation(item: JobItem, adapter: any VideoProviderAdapter, profile: ProviderProfile,
                                    foreground: Bool) async {
        let itemID = item.id
        if let taskID = item.providerTaskID {
            guard let key = key(for: item) else {
                if foreground { notice = String(localized: "mac.videos.keyUnavailable") }
                return
            }
            do {
                try await adapter.cancel(taskID: taskID, provider: profile,
                                         credentials: ProviderCredentials(apiKey: key))
                try? updateItem(itemID) {
                    $0.state = .cancelled
                    $0.error = nil
                }
            } catch {
                if let currentKey = self.key(for: item), let status = try? await adapter.status(
                    taskID: taskID, modelRemoteID: item.configuration.modelID,
                    provider: profile, credentials: ProviderCredentials(apiKey: currentKey)) {
                    switch status.state {
                    case .completed:
                        if let url = status.resultURL {
                            try? updateItem(itemID) { $0.state = .downloading }
                            try? await downloadResult(itemID: itemID, url: url,
                                                      expiresAt: status.resultURLExpiresAt,
                                                      profile: profile)
                            if foreground {
                                notice = String(localized: "mac.videos.finishedBeforeCancel")
                            }
                            return
                        }
                    case .failed, .cancelled, .expired:
                        try? updateItem(itemID) {
                            $0.state = status.state
                            $0.error = status.error.map { SecretRedactor.redact($0, secret: currentKey) }
                        }
                        return
                    default:
                        break
                    }
                }
                // Still running at the provider: keep it alive and honest.
                try? updateItem(itemID) {
                    $0.error = String(localized: "mac.videos.error.cancelFailed \(error.localizedDescription)")
                }
                return
            }
        } else {
            try? updateItem(itemID) {
                $0.state = .cancelled
                $0.error = String(localized: "mac.videos.error.cancelledUnconfirmed")
            }
        }
        if foreground { notice = String(localized: "mac.videos.cancelled") }
    }

    // MARK: - Failure surface

    private func failJob(itemID: UUID?, error: Error, foreground: Bool) {
        if let itemID {
            try? updateItem(itemID) {
                if !$0.state.isTerminal { $0.state = .failed }
                $0.error = error.localizedDescription
            }
        }
        if foreground { applyGenerationFailure(error) }
    }

    private func applyGenerationFailure(_ error: Error) {
        switch error {
        case MacVideoGenerationError.unsupportedResult:
            notice = String(localized: "mac.videos.unsupportedResult")
        case MacVideoGenerationError.storageFailed:
            notice = String(localized: "mac.videos.storageFailed")
        case MacVideoGenerationError.referenceUnsupported:
            notice = String(localized: "mac.videos.referenceUnsupported")
        case MacVideoGenerationError.downloadFailed(let code):
            notice = String(localized: "mac.videos.providerFailed \(code)")
        case let videoError as RemoteVideoError:
            switch videoError {
            case .invalidRequest(let detail), .invalidResponse(let detail), .requestFailed(let detail):
                notice = String(localized: "mac.videos.providerFailed \(detail)")
            case .unsupportedProvider:
                notice = String(localized: "mac.videos.invalidConfiguration")
            }
        case let floeError as FloeError:
            switch floeError {
            case .validationFailed(let message), .invalidConfiguration(let message):
                notice = String(localized: "mac.videos.invalidOptions \(message)")
            default:
                notice = String(localized: "mac.videos.failed")
            }
        default:
            notice = String(localized: "mac.videos.failed")
        }
    }

    // MARK: - Result persistence

    private struct HistoryEnvelope: Codable {
        var version: Int
        var results: [JobItem]
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

    private func persistHistory(_ results: [JobItem]) throws {
        let envelope = HistoryEnvelope(version: Self.historyEnvelopeVersion, results: results)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maximumHistoryBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try Self.writeFile(data, to: directory.appendingPathComponent(Self.historyFileName))
    }

    @discardableResult
    private func updateItem(_ id: UUID, _ mutate: (inout JobItem) -> Void) throws -> JobItem {
        guard let index = history.firstIndex(where: { $0.id == id }) else {
            throw MacVideoGenerationError.storageFailed
        }
        var next = history
        mutate(&next[index])
        if let detail = next[index].error {
            next[index].error = String(SecretRedactor.redact(detail, secret: key(for: next[index])).prefix(500))
        }
        do { try persistHistory(next) } catch { throw MacVideoGenerationError.storageFailed }
        history = next
        return next[index]
    }

    // MARK: - Credentials

    private struct StoredSettings: Codable {
        let configuration: Configuration
        let apiKey: String
    }

    private static func readStoredSettings(_ vault: KeychainStore) -> StoredSettings? {
        guard let data = try? vault.read(account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(StoredSettings.self, from: data)
    }

    private func currentKey() -> String? {
        guard let configuration else { return nil }
        return key(for: configuration)
    }

    private func key(for item: JobItem) -> String? { key(for: item.configuration) }

    private func key(for config: Configuration) -> String? {
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

    /// Same admission rule as the image service and the model-discovery
    /// smoke: with Keychain disabled, the packaged fixture's exact loopback
    /// host may acknowledge plain HTTP. Production saves stay on the
    /// validated https rules.
    private static func admitsLoopbackHTTP(with vault: KeychainStore?) -> Bool {
        #if FLOE_MAC_HOST_SMOKE
        return vault == nil
        #else
        return false
        #endif
    }

    private typealias Route = (profile: ProviderProfile, model: ModelProfile)

    private func route(for config: Configuration) -> Route? {
        if config.providerSelection != nil {
            guard let resolved = providerLink.resolve(config) else { return nil }
            return (resolved.profile, resolved.model)
        }
        return Self.makeRoute(configuration: config, allowLoopbackHTTP: Self.admitsLoopbackHTTP(with: vault))
    }

    private static func makeRoute(configuration: Configuration,
                                  allowLoopbackHTTP: Bool) -> Route {
        let endpoint = URL(string: configuration.endpoint) ?? URL(string: "https://example.invalid")!
        let preset = ProviderPreset.imagePresets.first { $0.id == configuration.presetID } ?? .custom
        var profile = ProviderProfile(kind: preset.kind, wireProtocol: preset.defaultProtocol,
                                      baseURL: endpoint, displayName: preset.displayName,
                                      presetID: preset.id.rawValue)
        if allowLoopbackHTTP, endpoint.host == "127.0.0.1" {
            profile.allowsPlainHTTP = true
        }
        let model = ModelProfile(providerID: profile.id, remoteModelID: configuration.modelID,
                                 displayName: configuration.modelID,
                                 limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
                                 capabilities: [.videoGeneration])
        return (profile, model)
    }

    // MARK: - Reference image

    /// Validates one local reference image for the selected route and returns
    /// the inline `data:` URL expected by `RemoteVideoRequest` together with
    /// a digest fingerprint that distinguishes first-frame inputs. The inline
    /// bytes are never persisted; a route the shared policy does not verify
    /// for image input is rejected instead of silently dropping the image.
    private static func resolveReferenceImage(_ url: URL, route: Route,
                                              options: VideoGenerationOptions) throws
        -> (url: URL, fingerprint: String) {
        guard url.isFileURL else { throw MacVideoGenerationError.referenceUnsupported }
        guard VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: route.profile.kind, modelRemoteID: route.model.remoteModelID,
            baseURL: route.profile.baseURL) else {
            throw MacVideoGenerationError.referenceUnsupported
        }
        // Veo reference images are documented as requiring an 8-second video;
        // reject a conflicting explicit duration before any paid submission.
        if route.profile.kind == .googleGemini,
           !route.model.remoteModelID.hasPrefix("gemini-omni-"),
           let duration = options.durationSeconds, duration != 8 {
            throw MacVideoGenerationError.referenceUnsupported
        }
        guard let data = try readFile(url, limit: VideoReferenceImagePolicy.maximumBytes) else {
            throw MacVideoGenerationError.referenceUnsupported
        }
        do {
            let inline = try VideoReferenceImagePolicy.inlineDataURL(data: data)
            return (inline, FloeDigest.sha256Hex(data))
        } catch {
            throw MacVideoGenerationError.referenceUnsupported
        }
    }

    // MARK: - Polling cadence

    /// 2s after the first status, doubling to a 60s ceiling. Cheap GETs keep
    /// the fixture round-trip seconds-fast while production polling stays
    /// well-bounded; the adapter's own request timeout bounds every call.
    private static func pollDelay(attempt: Int) -> UInt64 {
        UInt64(min(60.0, 2.0 * pow(2.0, Double(attempt))) * 1_000_000_000)
    }

    // MARK: - Verified video bytes

    private static func isCanonical(_ item: JobItem) -> Bool {
        guard let filename = item.filename else { return item.state != .ready }
        return ["mp4", "webm"].contains { filename == item.id.uuidString + "." + $0 }
    }

    // MARK: - Private file IO

    /// Reads at most `limit` bytes from one exact path: no symlinks, regular
    /// files owned by the current user only. Modeled on the workspace draft
    /// store and the image service so untrusted or swapped files fail closed.
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

extension MacVideoGeneration.MacVideoGenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "mac.videos.invalidConfiguration")
        case .keyRequired, .keychainUnavailable:
            String(localized: "mac.videos.keyUnavailable")
        case .admissionRefused:
            String(localized: "host.chat.endingSession")
        case .busy:
            String(localized: "mac.videos.busy")
        case .unsupportedResult:
            String(localized: "mac.videos.unsupportedResult")
        case .storageFailed:
            String(localized: "mac.videos.storageFailed")
        case .referenceUnsupported:
            String(localized: "mac.videos.referenceUnsupported")
        case .downloadFailed(let code):
            String(localized: "mac.videos.providerFailed \(code)")
        }
    }
}
