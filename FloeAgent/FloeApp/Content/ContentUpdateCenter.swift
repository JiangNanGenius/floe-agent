// FloeApp — signed content update center (thin UI facade).
//
// All bytes, hashing, ZIP extraction, manifest IO and pruning live in the
// `ContentUpdateStore` actor (FloeSkills). This class only:
//   * fetches verified feeds/packages through the authenticated connector
//     (async, never blocking the main thread);
//   * mirrors the store's active state into @Published UI state;
//   * applies policy: daily checks, backoff, WiFi-only automatic downloads,
//     built-in baseline takeover and manual actions.
//
// The unsigned provider-catalog cache path was removed: the provider catalog
// is now a signed `providers` package installed through the same transaction
// as every other content kind, and `providerCatalogIndex()` reads the active
// installed version (falling back to the app-bundled file only when nothing
// is installed).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Network
import SwiftUI
import FloeCore
import FloeSkills
import FloeProviders

@MainActor
final class ContentUpdateCenter: ObservableObject {

    struct InstalledRecord: Equatable, Sendable {
        var id: String
        var kind: String
        var version: String
        var digest: String
        var sourceRevision: String
        var containsScripts: Bool
        var installedAt: Date
        var previousVersion: String?
        var previousDigest: String?
    }

    struct AvailableContent: Identifiable, Sendable {
        var id: String { entry.id }
        let entry: SignedContentEntry
        let decision: ContentUpdateDecision
    }

    struct FeedSnapshot: Sendable {
        let commit: String
        let feed: SignedContentFeed
        let plannedByID: [String: ContentUpdateDecision]
    }

    // MARK: - Published UI state

    @Published private(set) var installed: [String: InstalledRecord] = [:]
    @Published private(set) var pinnedVersions: [String: String] = [:]
    @Published private(set) var available: [String: AvailableContent] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var installingIDs: Set<String> = []
    @Published private(set) var lastCheck: Date?
    @Published var errorMessage: String?
    @Published private(set) var providerCatalogCommit: String?
    @Published private(set) var storageAvailable = true

    @Published var automaticChecksEnabled: Bool {
        didSet { defaults.set(automaticChecksEnabled, forKey: Self.automaticChecksKey) }
    }
    @Published var autoUpdateDeclarativeContent: Bool {
        didSet { defaults.set(autoUpdateDeclarativeContent, forKey: Self.autoUpdateKey) }
    }
    @Published var autoInstallScriptedSkills: Bool {
        didSet { defaults.set(autoInstallScriptedSkills, forKey: Self.autoScriptsKey) }
    }
    @Published var automaticDownloadOnWiFiOnly: Bool {
        didSet { defaults.set(automaticDownloadOnWiFiOnly, forKey: Self.wifiKey) }
    }

    // MARK: - Constants

    nonisolated static let providerPackageID = "floe.providers.compatibility"
    nonisolated static let providerCatalogPath = "ProviderCatalog.json"
    nonisolated static let promptsPackageID = "floe.prompts.core"
    nonisolated static let maximumBatchEntries = 16

    /// App-bundle baselines. A strictly newer built-in version deactivates an
    /// installed copy (retained in history) so the app-owned content wins;
    /// equal versions keep the installed copy because published bytes are
    /// immutable.
    nonisolated static let builtInBaselines: [String: String] = [
        providerPackageID: "1.1.0"
    ]

    /// Declarative content may never require credentials. Script runtimes are
    /// gated by the codec's `containsScripts` contract.
    nonisolated static let allowedCapabilities: Set<String> = Set(
        SkillCapability.allCases.map(\.rawValue)
    ).subtracting([SkillCapability.credentials.rawValue])

    private static let automaticChecksKey = "floe.content.update.automaticChecks"
    private static let autoUpdateKey = "floe.content.update.autoDeclarative"
    /// Shared with the Skills UI and SkillsCenter: one policy value, never a
    /// second copy. Scripted updates may apply only when permissions do not
    /// expand.
    nonisolated static let scriptedAutoInstallDefaultsKey = "floe.content.update.autoScriptedSkills"
    private static let autoScriptsKey = scriptedAutoInstallDefaultsKey
    private static let wifiKey = "floe.content.update.wifiOnly"
    private static let lastCheckKey = "floe.content.update.lastCheck"

    // MARK: - Dependencies

    private unowned let environment: AppEnvironment
    private let defaults = UserDefaults.standard
    private let store: ContentUpdateStore?
    private let storageError: String?
    private var didLoad = false
    private var state: ContentUpdateState?
    private var feedSnapshot: FeedSnapshot?
    private var installInFlight: Set<String> = []
    private var providerCatalogCache: ProviderCatalogIndex?
    private var promptSectionCache: [ContentPackageCodec.PromptSection] = []
    private var helpFileCache: [String: [String: Data]] = [:]

    private let networkMonitor = NWPathMonitor()
    private var onWiFi = true

    init(environment: AppEnvironment, root: URL? = nil) {
        self.environment = environment
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        var resolvedStore: ContentUpdateStore?
        var resolvedError: String?
        if let support {
            let base = root ?? support.appendingPathComponent("FloeAgent/Content", isDirectory: true)
            do {
                resolvedStore = try ContentUpdateStore(root: base)
            } catch {
                resolvedError = error.localizedDescription
            }
        } else {
            resolvedError = FloeL10n.l("content.update.error.storage_unavailable")
        }
        self.store = resolvedStore
        self.storageError = resolvedError
        self.storageAvailable = resolvedError == nil
        automaticChecksEnabled = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        autoUpdateDeclarativeContent = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        autoInstallScriptedSkills = defaults.object(forKey: Self.autoScriptsKey) as? Bool ?? false
        automaticDownloadOnWiFiOnly = defaults.object(forKey: Self.wifiKey) as? Bool ?? true
        if let seconds = defaults.object(forKey: Self.lastCheckKey) as? Double {
            lastCheck = Date(timeIntervalSince1970: seconds)
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in self?.onWiFi = wifi }
        }
        networkMonitor.start(queue: DispatchQueue(label: "org.floeagent.content.network"))
        if let resolvedError {
            errorMessage = resolvedError
        }
    }

    deinit {
        networkMonitor.cancel()
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - Loading

    /// Synchronous entry point used by SwiftUI `.task`; state arrives via
    /// @Published after the actor read completes.
    func load() {
        guard !didLoad else { return }
        didLoad = true
        Task { await refreshFromStore() }
    }

    private func ensureLoaded() async {
        if !didLoad {
            didLoad = true
            await refreshFromStore()
        }
    }

    private func refreshFromStore() async {
        guard let store else {
            storageAvailable = false
            errorMessage = storageError
            return
        }
        do {
            var current = await store.currentState()
            current = try await applyBuiltInBaselineTakeover(current)
            await apply(current)
            storageAvailable = true
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func applyBuiltInBaselineTakeover(_ input: ContentUpdateState) async throws -> ContentUpdateState {
        guard let store else { return input }
        var current = input
        for (id, baseline) in Self.builtInBaselines {
            guard let stored = current.entries[id],
                  let installedVersion = try? SignedContentVersion(stored.entry.version),
                  let builtInVersion = try? SignedContentVersion(baseline),
                  builtInVersion > installedVersion else { continue }
            current = try await store.deactivate(id: id)
            FloeLogger(category: .app).info("contentBuiltInTakeover id=\(id) baseline=\(baseline)")
        }
        return current
    }

    private func apply(_ next: ContentUpdateState) async {
        state = next
        installed = next.entries.mapValues { stored in
            let previous = next.history[stored.entry.id]?.first
            return InstalledRecord(
                id: stored.entry.id,
                kind: stored.entry.kind.rawValue,
                version: stored.entry.version,
                digest: stored.entry.contentDigest,
                sourceRevision: stored.entry.sourceRevision,
                containsScripts: stored.entry.containsScripts,
                installedAt: stored.installedAt,
                previousVersion: previous?.entry.version,
                previousDigest: previous?.entry.contentDigest
            )
        }
        pinnedVersions = next.pinned
        await reloadCaches()
    }

    private func reloadCaches() async {
        guard let store else { return }
        if let data = try? await store.file(id: Self.providerPackageID, relativePath: Self.providerCatalogPath),
           let index = try? ProviderCatalogIndex.validated(from: data) {
            providerCatalogCache = index
        } else {
            providerCatalogCache = nil
        }
        if let files = try? await store.files(id: Self.promptsPackageID) {
            promptSectionCache = ContentPackageCodec.promptSections(in: files)
        } else {
            promptSectionCache = []
        }
        var helpCache: [String: [String: Data]] = [:]
        for id in installed.keys {
            guard installed[id]?.kind == SignedContentKind.help.rawValue
                || installed[id]?.kind == SignedContentKind.templates.rawValue else { continue }
            if let files = try? await store.files(id: id) {
                helpCache[id] = files
            }
        }
        helpFileCache = helpCache
    }

    // MARK: - Checking

    func checkAutomaticallyIfDue() async {
        await ensureLoaded()
        guard automaticChecksEnabled else { return }
        if let retryAfter = state?.retryAfter, retryAfter > Date() { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3_600 { return }
        await checkForUpdates(force: false)
    }

    func checkForUpdates(force: Bool) async {
        await ensureLoaded()
        guard let store else {
            errorMessage = storageError
            return
        }
        guard !isChecking else { return }
        let now = Date()
        if !force {
            if let retryAfter = state?.retryAfter, retryAfter > now { return }
            if let lastCheck, now.timeIntervalSince(lastCheck) < 24 * 3_600 { return }
            if !automaticChecksEnabled { return }
        }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            let (feed, commit) = try await fetchVerifiedFeed(store: store)
            let plan = try await store.plan(feed: feed, appVersion: appVersion)
            feedSnapshot = FeedSnapshot(commit: commit, feed: feed, plannedByID: decisions(plan))
            available = plan.items.mapValues { AvailableContent(entry: $0.entry, decision: $0.decision) }
            providerCatalogCommit = commit
            lastCheck = now
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
            try await store.recordCheckSuccess()
            await applyAutomaticUpdates(store: store, snapshot: feedSnapshot)
        } catch is CancellationError {
        } catch {
            errorMessage = Self.describe(error)
            await scheduleRetry(store: store, now: now)
        }
    }

    private func decisions(_ plan: ContentUpdateStore.Plan) -> [String: ContentUpdateDecision] {
        plan.items.mapValues(\.decision)
    }

    private func fetchVerifiedFeed(store: ContentUpdateStore) async throws -> (SignedContentFeed, String) {
        let source = try OfficialContentHub.source()
        let connector = environment.sourceControlCenter
        let commitData = try await connector.skillRepositoryData(
            owner: source.owner, repository: source.repository,
            ref: source.ref, path: nil, usesConnectorCredential: false
        )
        struct Commit: Decodable { let sha: String }
        let commit = try JSONDecoder().decode(Commit.self, from: commitData).sha
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw SignedContentFailure.feed
        }
        let index = try await connector.skillRepositoryData(
            owner: source.owner, repository: source.repository,
            ref: commit, path: OfficialContentHub.indexPath, usesConnectorCredential: false
        )
        let signature = try await connector.skillRepositoryData(
            owner: source.owner, repository: source.repository,
            ref: commit, path: OfficialContentHub.signaturePath, usesConnectorCredential: false
        )
        let feed = try await store.verifyFeed(
            index: index, signature: signature, trustedKeys: OfficialSkillHub.trustedKeys
        )
        return (feed, commit)
    }

    private func applyAutomaticUpdates(store: ContentUpdateStore, snapshot: FeedSnapshot?) async {
        guard let snapshot else { return }
        for id in dependencyOrder(snapshot) {
            guard let decision = snapshot.plannedByID[id], decision.isUpdate else { continue }
            guard let entry = snapshot.feed.entries.first(where: { $0.id == id }) else { continue }
            if entry.containsScripts {
                guard autoInstallScriptedSkills else { continue }
            } else {
                guard autoUpdateDeclarativeContent else { continue }
            }
            guard !(automaticDownloadOnWiFiOnly && !onWiFi) else { continue }
            do {
                try await commitEntries([id], snapshot: snapshot, store: store)
                FloeLogger(category: .app).info("contentAutoUpdated id=\(id) version=\(entry.version)")
            } catch {
                FloeLogger(category: .app).warning(
                    "automatic content update failed id=\(id): \(error.localizedDescription)"
                )
            }
        }
    }

    private func dependencyOrder(_ snapshot: FeedSnapshot) -> [String] {
        var visited: Set<String> = []
        var order: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: snapshot.feed.entries.map { ($0.id, $0) })
        func visit(_ entry: SignedContentEntry) {
            guard visited.insert(entry.id).inserted else { return }
            for dependency in entry.dependencies {
                if let dependencyEntry = byID[dependency] { visit(dependencyEntry) }
            }
            order.append(entry.id)
        }
        for entry in snapshot.feed.entries { visit(entry) }
        return order
    }

    private func scheduleRetry(store: ContentUpdateStore, now: Date) async {
        let base: TimeInterval = 15 * 60
        let capped: TimeInterval = 24 * 3_600
        let prior = state?.retryAfter ?? now
        let next = min(prior.addingTimeInterval(base * 2), now.addingTimeInterval(capped))
        do {
            _ = try await store.recordCheckFailure(retryAfter: max(next, now.addingTimeInterval(base)))
            state = await store.currentState()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Install / rollback

    func install(_ id: String) async {
        await ensureLoaded()
        guard let store, let snapshot = feedSnapshot else {
            if errorMessage == nil { errorMessage = FloeL10n.l("content.update.error.feed") }
            return
        }
        await performInstall(id: id) {
            try await self.commitEntries([id], snapshot: snapshot, store: store)
        }
    }

    private func performInstall(id: String, operation: @escaping () async throws -> Void) async {
        guard !installingIDs.contains(id) else { return }
        installingIDs.insert(id)
        errorMessage = nil
        defer { installingIDs.remove(id) }
        do {
            try await operation()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Authoritative, re-validated commit. The store re-checks version,
    /// immutability, pin and capability rules against its current state; the
    /// frozen feed commit is the only source of bytes. A failure never leaves
    /// a half-applied batch.
    private func commitEntries(
        _ ids: [String],
        snapshot: FeedSnapshot,
        store: ContentUpdateStore
    ) async throws {
        for id in ids {
            guard !installInFlight.contains(id) else {
                throw ContentUpdateStoreError.conflict("already installing \(id)")
            }
        }
        let plan = try await store.plan(feed: snapshot.feed, appVersion: appVersion)
        var needed: [String] = []
        var visited: Set<String> = []
        var batchBytes = 0
        func collect(_ id: String) throws {
            guard visited.insert(id).inserted else { return }
            guard let item = plan.items[id] else {
                throw ContentUpdateStoreError.conflict("unknown content \(id)")
            }
            for dependency in item.entry.dependencies { try collect(dependency) }
            let isActive = installed[id] != nil
            guard item.decision.isUpdate || isActive else {
                throw ContentUpdateStoreError.conflict("blocked \(id)")
            }
            if item.decision.isUpdate {
                needed.append(id)
            }
        }
        for id in ids { try collect(id) }
        guard !needed.isEmpty, needed.count <= Self.maximumBatchEntries else { return }
        for id in needed { installInFlight.insert(id) }
        defer { for id in needed { installInFlight.remove(id) } }

        let connector = environment.sourceControlCenter
        var batch: [ContentUpdateStore.BatchItem] = []
        for id in needed {
            guard let item = plan.items[id] else { continue }
            let zip = try await connector.skillRepositoryData(
                owner: OfficialContentHub.owner, repository: OfficialContentHub.repository,
                ref: snapshot.commit, path: item.entry.path, usesConnectorCredential: false
            )
            batchBytes += zip.count
            guard batchBytes <= 64 * 1_024 * 1_024 else {
                throw ContentUpdateStoreError.conflict("batch exceeds size bounds")
            }
            batch.append(ContentUpdateStore.BatchItem(entry: item.entry, zip: zip))
        }
        let next = try await store.commit(
            batch,
            appVersion: appVersion,
            allowedCapabilities: Self.allowedCapabilities,
            domainValidate: Self.domainValidator
        )
        await apply(next)
        let refreshed = try await store.plan(feed: snapshot.feed, appVersion: appVersion)
        feedSnapshot = FeedSnapshot(
            commit: snapshot.commit, feed: snapshot.feed, plannedByID: decisions(refreshed)
        )
        available = refreshed.items.mapValues { AvailableContent(entry: $0.entry, decision: $0.decision) }
    }

    func rollback(_ id: String) async {
        await ensureLoaded()
        guard let store else {
            errorMessage = storageError
            return
        }
        await performInstall(id: id) {
            let next = try await store.rollback(id: id, appVersion: self.appVersion)
            await self.apply(next)
            if let snapshot = self.feedSnapshot,
               let refreshed = try? await store.plan(feed: snapshot.feed, appVersion: self.appVersion) {
                self.available = refreshed.items.mapValues {
                    AvailableContent(entry: $0.entry, decision: $0.decision)
                }
            }
        }
    }

    func setPinned(_ id: String, version: String?) {
        guard let store else { return }
        Task {
            do {
                let next = try await store.setPinned(id: id, version: version)
                await self.apply(next)
            } catch {
                self.errorMessage = Self.describe(error)
            }
        }
    }

    // MARK: - Provider catalog (signed package only)

    /// Reads the active installed provider package; falls back to the
    /// app-bundled catalog only when nothing signed is installed.
    func providerCatalogIndex() -> ProviderCatalogIndex? {
        providerCatalogCache ?? ProviderCatalogIndex.loadBundled()
    }

    /// Forces a signed check and installs the providers package update using
    /// the same transaction as every other content kind. No unsigned cache
    /// path exists.
    func refreshProviderCatalog() async {
        await ensureLoaded()
        await checkForUpdates(force: true)
        guard let decision = available[Self.providerPackageID]?.decision else { return }
        if decision.isUpdate {
            await performInstall(id: Self.providerPackageID) {
                guard let snapshot = self.feedSnapshot, let store = self.store else {
                    throw ContentUpdateStoreError.conflict("no frozen feed")
                }
                try await self.commitEntries([Self.providerPackageID], snapshot: snapshot, store: store)
            }
        }
    }

    // MARK: - Prompt review + runtime consumption

    func promptSections() -> [ContentPackageCodec.PromptSection] {
        promptSectionCache
    }

    func installedDocument(id: String, preferredPath: String) -> String? {
        guard let files = helpFileCache[id],
              let data = files[preferredPath] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Validated signed-content overlay frozen for this run. Creating the run
    /// snapshot also freezes app-bundled bytes (provider catalog) so recovery
    /// never substitutes a newer bundle for a task that started earlier.
    func runtimePromptOverlay(runID: UUID, locale: String) async -> AgentPromptOverlay {
        guard let store else { return .empty }
        do {
            let snapshot = try await store.runSnapshot(
                runID: runID,
                builtInVersions: Self.builtInBaselines,
                builtInPayloads: builtInPayloadsForSnapshot()
            )
            guard let directory = snapshot.directories[Self.promptsPackageID] else { return .empty }
            let files = try await store.files(directory: directory)
            return try ContentPackageCodec.runtimePromptOverlay(in: files, locale: locale)
        } catch {
            FloeLogger(category: .app).warning(
                "contentPromptOverlay failed run=\(runID.uuidString): \(error.localizedDescription)"
            )
            return .empty
        }
    }

    private func builtInPayloadsForSnapshot() -> [String: Data] {
        guard installed[Self.providerPackageID] == nil else { return [:] }
        guard let url = Bundle.main.url(forResource: "ProviderCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return [Self.providerPackageID: data]
    }

    /// Run-scoped provider catalog. A resumed run never substitutes a new
    /// app bundle for the version it started with: installed bytes first,
    /// then the frozen built-in copy written when the run started.
    func providerCatalogIndex(forRunID runID: UUID) async -> ProviderCatalogIndex? {
        guard let store else { return providerCatalogIndex() }
        do {
            let snapshot = try await store.runSnapshot(
                runID: runID,
                builtInVersions: Self.builtInBaselines,
                builtInPayloads: builtInPayloadsForSnapshot()
            )
            if let directory = snapshot.directories[Self.providerPackageID] {
                let files = try await store.files(directory: directory)
                if let data = files[Self.providerCatalogPath],
                   let index = try? ProviderCatalogIndex.validated(from: data) {
                    return index
                }
            }
            if let frozen = snapshot.builtInDirectories?[Self.providerPackageID] {
                let files = try await store.files(directory: frozen)
                if let data = files["payload"],
                   let index = try? ProviderCatalogIndex.validated(from: data) {
                    return index
                }
            }
            // Legacy snapshot without frozen bytes: use the current bundle
            // only when the recorded baseline still matches.
            let recordedBaseline = snapshot.builtInVersions?[Self.providerPackageID]
            let currentBaseline = Self.builtInBaselines[Self.providerPackageID]
            guard recordedBaseline == currentBaseline else { return nil }
            return ProviderCatalogIndex.loadBundled()
        } catch {
            return nil
        }
    }

    // MARK: - Domain validation

    nonisolated static func domainValidator(entry: SignedContentEntry, files: [String: Data]) throws {
        try ContentPackageCodec(kind: entry.kind).validate(entry: entry, files: files)
        if entry.kind == .providers,
           let catalogData = files[providerCatalogPath] {
            _ = try ProviderCatalogIndex.validated(from: catalogData)
        }
    }

    // MARK: - Error presentation

    static func describe(_ error: Error) -> String {
        switch error {
        case SignedContentFailure.signature:
            return FloeL10n.l("content.update.error.signature")
        case SignedContentFailure.feed:
            return FloeL10n.l("content.update.error.feed")
        case SignedContentFailure.archive:
            return FloeL10n.l("content.update.error.archive")
        case SignedContentFailure.immutableVersion:
            return FloeL10n.l("content.update.error.immutable")
        case SignedContentFailure.incompatible:
            return FloeL10n.l("content.update.error.incompatible")
        case SignedContentFailure.missingDependency:
            return FloeL10n.l("content.update.error.missing_dependency")
        case let storeError as ContentUpdateStoreError:
            switch storeError {
            case .storage:
                return FloeL10n.l("content.update.error.storage_unavailable")
            case .corruptState:
                return FloeL10n.l("content.update.error.corrupt_state")
            case .conflict:
                return FloeL10n.l("content.update.error.conflict")
            case .staging, .persistence:
                return FloeL10n.l("content.update.error.persistence")
            }
        default:
            return FloeL10n.l(
                "content.update.error.generic", SecretRedactor.redact(error.localizedDescription)
            )
        }
    }
}
#endif
