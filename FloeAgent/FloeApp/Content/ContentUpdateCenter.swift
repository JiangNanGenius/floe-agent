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
import FloeAgentRuntime

@MainActor
final class ContentUpdateCenter: ObservableObject {

    /// Reads one object (or commit metadata when `path == nil`) from the
    /// official public content hub over anonymous HTTPS. Production closes
    /// over the app's real `SourceControlCenter`; qualification injects the
    /// identical REST fetch pointed at an immutable commit SHA. Signature and
    /// digest verification, version policy and the atomic install transaction
    /// are always the real production path — this never swaps the trust root
    /// or introduces a parallel updater.
    typealias RepositoryFetch = @MainActor (
        _ owner: String, _ repository: String, _ ref: String, _ path: String?
    ) async throws -> Data


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

    /// Version of the prompt sections compiled into the app. This is a
    /// content version (not the app marketing version): bump it whenever the
    /// compiled method/communication/delivery sections change so app-upgrade
    /// comparison and frozen-run selection treat built-in prompts as an
    /// explicit, versioned content source.
    nonisolated static let builtInPromptsVersion = "1.0.0"
    nonisolated static let maximumBatchEntries = 16

    /// App-bundle baselines. A strictly newer built-in version deactivates an
    /// installed copy (retained in history) so the app-owned content wins;
    /// equal versions keep the installed copy because published bytes are
    /// immutable. Only actually bundled, consumed kinds appear here; no
    /// package is invented for unconsumed types.
    nonisolated static let builtInBaselines: [String: String] = [
        providerPackageID: "1.1.0",
        promptsPackageID: builtInPromptsVersion
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

    /// Anonymous public-hub transport. Production closes over the app's real
    /// `SourceControlCenter`; qualification injects the same fetch pinned to
    /// an immutable commit SHA.
    private let repositoryFetch: RepositoryFetch
    /// Feed ref. Production always reads `main`; qualification pins an
    /// immutable published commit SHA so the run exercises a frozen, auditable
    /// source rather than a moving branch.
    private let feedRef: String
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
    /// Unknown until the monitor reports its first update. Conservative for
    /// WiFi-only automatic downloads: `false` never allows a download.
    private var onWiFi = false
    private var onWiFiKnown = false

    /// Production: the app's real anonymous-hub connector, feed ref `main`.
    convenience init(environment: AppEnvironment, root: URL? = nil) {
        let connector = environment.sourceControlCenter
        self.init(root: root, feedRef: "main", repositoryFetch: { owner, repository, ref, path in
            try await connector.skillRepositoryData(
                owner: owner, repository: repository, ref: ref, path: path,
                usesConnectorCredential: false
            )
        })
    }

    #if DEBUG
    /// Qualification only: drive the real center against an immutable
    /// published commit through the identical anonymous GitHub transport,
    /// without standing up the whole `AppEnvironment`. Trust root, signature
    /// and digest verification, version policy and the atomic install
    /// transaction are unchanged production code; only the bytes' ref and the
    /// on-disk store root are redirected. Never compiled into release.
    static func forImmutableCommit(
        _ commit: String,
        root: URL,
        fetch: @escaping RepositoryFetch
    ) -> ContentUpdateCenter {
        ContentUpdateCenter(root: root, feedRef: commit, repositoryFetch: fetch)
    }
    #endif

    /// Designated: the transport is required (no environment back-reference is
    /// kept — the center only ever needs the fetch closure).
    private init(root: URL?, feedRef: String, repositoryFetch: @escaping RepositoryFetch) {
        self.feedRef = feedRef
        self.repositoryFetch = repositoryFetch
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onWiFi = wifi
                self.onWiFiKnown = true
            }
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
        guard ContentUpdatePolicy.automaticCheckDue(
            lastCheck: lastCheck,
            retryAfter: state?.retryAfter,
            now: Date(),
            automaticChecksEnabled: automaticChecksEnabled
        ) else { return }
        await checkForUpdates(force: false)
    }

    /// `force: true` is reserved for explicit user actions (button,
    /// pull-to-refresh); every other caller respects the cooldown/backoff.
    func checkForUpdates(force: Bool) async {
        await ensureLoaded()
        guard let store else {
            errorMessage = storageError
            return
        }
        guard !isChecking else { return }
        let now = Date()
        if !force {
            guard ContentUpdatePolicy.manualCheckAllowed(
                retryAfter: state?.retryAfter,
                now: now,
                lastCheck: lastCheck
            ), automaticChecksEnabled else { return }
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
        let commitData = try await repositoryFetch(
            source.owner, source.repository, feedRef, nil
        )
        struct Commit: Decodable { let sha: String }
        let commit = try JSONDecoder().decode(Commit.self, from: commitData).sha
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw SignedContentFailure.feed
        }
        let index = try await repositoryFetch(
            source.owner, source.repository, commit, OfficialContentHub.indexPath
        )
        let signature = try await repositoryFetch(
            source.owner, source.repository, commit, OfficialContentHub.signaturePath
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
            guard ContentUpdatePolicy.automaticDownloadAllowed(
                wifiOnly: automaticDownloadOnWiFiOnly,
                onWiFiKnown: onWiFiKnown,
                onWiFi: onWiFi
            ) else { continue }
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
        let next = ContentUpdatePolicy.nextRetry(priorRetryAfter: state?.retryAfter, now: now)
        do {
            _ = try await store.recordCheckFailure(retryAfter: next)
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

        var batch: [ContentUpdateStore.BatchItem] = []
        for id in needed {
            guard let item = plan.items[id] else { continue }
            let zip = try await repositoryFetch(
                OfficialContentHub.owner, OfficialContentHub.repository,
                snapshot.commit, item.entry.path
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
    ///
    /// Boundary: the catalog serves add-time provider discovery only. Runs
    /// never consume it — a run's provider/model configuration is copied at
    /// launch, so there is deliberately no run-scoped mutable catalog
    /// accessor (a previous `providerCatalogIndex(forRunID:)` had no caller
    /// and was removed rather than left as a speculative path).
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
    /// snapshot also freezes the compiled built-in prompt bodies (as a
    /// package-shaped payload) so a run that started on built-in prompts
    /// resumes with byte-identical content even after an app upgrade changes
    /// the compiled bodies.
    func runtimePromptOverlay(runID: UUID, locale: String) async -> AgentPromptOverlay {
        guard let store else { return .empty }
        do {
            let snapshot = try await store.runSnapshot(
                runID: runID,
                builtInVersions: Self.builtInBaselines,
                builtInPayloads: builtInPromptsPayloadForSnapshot()
            )
            if let directory = snapshot.directories[Self.promptsPackageID] {
                let files = try await store.files(directory: directory)
                return try ContentPackageCodec.runtimePromptOverlay(in: files, locale: locale)
            }
            if let frozen = snapshot.builtInDirectories?[Self.promptsPackageID] {
                // Started on built-in prompts: the frozen compiled bodies are
                // the run's content. The freeze stores the package bytes as
                // `payload`; feed them to the exact package codec/overlay
                // validation path as an installed package's content.json.
                let files = try await store.files(directory: frozen)
                guard let payload = files["payload"] else { return .empty }
                return try ContentPackageCodec.runtimePromptOverlay(
                    in: ["content.json": payload], locale: locale
                )
            }
            // Legacy snapshot without frozen prompt bytes: the current
            // compiled bodies are the only source. Snapshots created from
            // this version onward always carry the freeze payload.
            return .empty
        } catch {
            FloeLogger(category: .app).warning(
                "contentPromptOverlay failed run=\(runID.uuidString): \(error.localizedDescription)"
            )
            return .empty
        }
    }

    /// Compiled built-in prompt sections packaged in the signed prompts
    /// schema shape for run freezing.
    private func builtInPromptsPayloadForSnapshot() -> [String: Data] {
        let sections = AgentPromptComposer.builtInReplaceablePromptBodies.map { id, body in
            BuiltInPromptFreeze.section(id: id, compiledBody: body)
        }
        guard let payload = try? BuiltInPromptFreeze.contentJSON(sections: sections) else { return [:] }
        return [Self.promptsPackageID: payload]
    }

    /// Compiled built-in prompt sections, shown by the review UI whenever no
    /// signed prompts package is installed so the offline surface reflects
    /// what the runtime actually uses.
    func builtInPromptSections() -> [ContentPackageCodec.PromptSection] {
        AgentPromptComposer.builtInReplaceablePromptBodies.map { id, body in
            let section = BuiltInPromptFreeze.section(id: id, compiledBody: body)
            return ContentPackageCodec.PromptSection(
                id: section.id,
                title: ["en": section.title],
                body: ["en": section.body]
            )
        }
    }

    /// The effective prompts content version for the currently selected
    /// source: installed package wins; otherwise the compiled built-in
    /// content version.
    func effectivePromptsVersion() -> String {
        installed[Self.promptsPackageID]?.version ?? Self.builtInPromptsVersion
    }

    // MARK: - Run snapshot lifecycle

    /// Releases the frozen content snapshot for a run that reached a final,
    /// non-recoverable state (`completed`, or any run whose conversation is
    /// being deleted). Checkpointed and failed runs keep their snapshots:
    /// both stay resumable via Continue, and recovery must never substitute
    /// newer content for what the run started with.
    func releaseRunSnapshot(_ runID: UUID) async {
        guard let store else { return }
        do {
            try await store.releaseRunSnapshot(runID: runID)
        } catch {
            FloeLogger(category: .app).warning(
                "contentReleaseSnapshot failed run=\(runID.uuidString): \(error.localizedDescription)"
            )
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
        case FloeError.syncUnavailable:
            // The shared connector phrases its failure for the skill source;
            // this is the content feed, so surface a content-specific,
            // localized reason instead of the raw English skill wording.
            return FloeL10n.l("content.update.error.unavailable")
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
