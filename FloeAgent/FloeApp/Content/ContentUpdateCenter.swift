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
import FloeExecution
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

    /// The exact stage one service-owned content install transaction is at.
    /// `fetching` covers the signed package downloads (cancellable network
    /// stage); `committing` covers validation, staging and atomic promotion.
    /// Cancellation remains available until the store starts its atomic write;
    /// after promotion the receipt preserves the actual installed result.
    enum ContentInstallPhase: String, Equatable, Sendable {
        case fetching
        case committing
    }

    /// Per-content-id truth for the newest install attempt this service owns.
    /// Normal cancellation and a real error are distinct: `wasCancelled` is
    /// set only for a cancelled job with no promotion. `promoted` is the
    /// atomic receipt — recorded the moment the store transaction (install
    /// promotion or rollback re-point) completes, BEFORE any mirroring or
    /// refresh tail. It survives a later tail error (then `failure` carries
    /// that real error while `promoted` stays true: the content really is
    /// installed/re-pointed), and it wins over a cancellation request that
    /// arrived too late to stop the transaction. Starting a new attempt for
    /// the same id replaces this record, so a retry clears exactly that id's
    /// old error and stale callbacks can never overwrite a newer attempt. The
    /// dictionary is process memory only: after a restart the published
    /// state mirrors the store's real installed/history records through
    /// `installed`, and a job that died with the process is never shown as
    /// still running.
    struct ContentInstallState: Equatable, Sendable {
        let attempt: UUID
        var running = false
        var cancelling = false
        var phase: ContentInstallPhase?
        var failure: String?
        var wasCancelled = false
        var promoted = false

        init(
            attempt: UUID,
            running: Bool = false,
            cancelling: Bool = false,
            phase: ContentInstallPhase? = nil,
            failure: String? = nil,
            wasCancelled: Bool = false,
            promoted: Bool = false
        ) {
            self.attempt = attempt
            self.running = running
            self.cancelling = cancelling
            self.phase = phase
            self.failure = failure
            self.wasCancelled = wasCancelled
            self.promoted = promoted
        }
    }

    // MARK: - Published UI state

    @Published private(set) var installed: [String: InstalledRecord] = [:]
    @Published private(set) var available: [String: AvailableContent] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var installingIDs: Set<String> = []
    /// Newest attempt state per content id for every service-owned install
    /// (explicit, guide, provider/search refresh and rollback). Views mirror
    /// this; it never claims work the service does not own.
    @Published private(set) var installStates: [String: ContentInstallState] = [:]
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

    /// Independently versioned signed search-provider catalog. It reuses the
    /// existing `providers` content kind, signature root and install
    /// transaction; only the package identity and payload differ, so a
    /// search-catalog release never republishes the provider compatibility
    /// package and vice versa.
    nonisolated static let searchProviderPackageID = SearchProviderCatalog.packageID
    nonisolated static let searchProviderCatalogPath = SearchProviderCatalog.payloadFileName

    /// Version of the search catalog compiled into the app bundle. A signed
    /// package at this version or newer wins; a strictly newer built-in takes
    /// over exactly like every other bundled baseline.
    nonisolated static let builtInSearchProvidersVersion = "1.0.0"

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
        providerPackageID: "1.1.1",
        promptsPackageID: builtInPromptsVersion,
        searchProviderPackageID: builtInSearchProvidersVersion
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
    /// One live service-owned transaction task per content id. The task, not
    /// the presenting view, owns the install: navigation/teardown can never
    /// cancel it, only `cancelInstall(_:)` does. A caller that arrives while
    /// an attempt is live joins that exact task instead of starting a second
    /// download for the same id.
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var providerCatalogCache: ProviderCatalogIndex?
    private var searchProviderCatalogCache: SearchProviderCatalogIndex?
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
            do { current = try await store.removeVersionPins() }
            catch {
                // A policy migration write failure must not hide already
                // installed content. Keep its real state visible and retry
                // pin retirement before any later update check/commit.
                errorMessage = Self.describe(error)
            }
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
        guard let store else { return }
        let actions = await store.actionSnapshot(appVersion: appVersion,
            builtInBaselines: Self.builtInBaselines, domainValidate: Self.domainValidator)
        // Another content action may finish while the actor is validating
        // retained bytes. Never replace a newer mirrored revision with this one.
        guard actions.state.revision >= (state?.revision ?? 0), actions.state.revision >= next.revision else { return }
        state = actions.state
        installed = actions.state.entries.mapValues { stored in
            let previous = actions.rollbackTargets[stored.entry.id]
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
        if let data = try? await store.file(
            id: Self.searchProviderPackageID,
            relativePath: Self.searchProviderCatalogPath
        ), let index = try? SearchProviderCatalogIndex.validated(from: data) {
            searchProviderCatalogCache = index
        } else {
            searchProviderCatalogCache = nil
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
            // Retry migration if a previous launch could not persist it.
            _ = try await store.removeVersionPins()
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
            guard ContentUpdateActionPolicy.automaticUpdateAllowed(id: id, version: entry.version,
                state: await store.currentState()) else { continue }
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
                try await commitEntries([id], snapshot: snapshot, store: store, automatic: true)
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

    /// Identity of one service-owned install attempt: the content id plus the
    /// attempt token. Only a live attempt carries a token; every phase or
    /// terminal write is fenced on it so a callback from a finished (or
    /// cancelled) attempt can never touch a newer attempt's state.
    struct ContentInstallAttempt: Equatable, Sendable {
        let id: String
        let token: UUID
    }

    /// Legacy entry point, signature and completion behaviour unchanged: the
    /// caller waits until this id's install reaches its terminal transition.
    /// While an attempt for the same id is live the caller JOINS it (a second
    /// caller never starts a second download and never returns early while
    /// bytes are still moving). The caller's own cancellation — for example
    /// the presenting view being torn down — does not cancel the service task;
    /// only `cancelInstall(_:)` does. Real errors keep populating the global
    /// `errorMessage` for existing views; a normal cancellation does not.
    func install(_ id: String) async {
        await ensureLoaded()
        guard let store, let snapshot = feedSnapshot else {
            if errorMessage == nil { errorMessage = FloeL10n.l("content.update.error.feed") }
            noteAttemptBlocked(id: id, message: FloeL10n.l("content.update.error.feed"))
            return
        }
        await performAttempt(id: id) { attempt in
            try await self.commitEntries([id], snapshot: snapshot, store: store, attempt: attempt)
        }
    }

    /// Non-blocking entry for observing owners (the setup guide): start this
    /// id's service-owned install, or join the live attempt if one exists, and
    /// return immediately. Progress, cancellation and the per-id failure truth
    /// arrive through `installStates[id]`; the job survives navigation because
    /// the center, not the view, owns the task.
    func beginInstall(_ id: String) async {
        await ensureLoaded()
        guard let store, let snapshot = feedSnapshot else {
            if errorMessage == nil { errorMessage = FloeL10n.l("content.update.error.feed") }
            noteAttemptBlocked(id: id, message: FloeL10n.l("content.update.error.feed"))
            return
        }
        _ = startAttempt(id: id) { attempt in
            try await self.commitEntries([id], snapshot: snapshot, store: store, attempt: attempt)
        }
    }

    /// Cancels exactly one job: the live install/rollback transaction for this
    /// content id. Nothing else — not another id's install, not installed
    /// content, not unrelated files — is touched. The cancellation aborts the
    /// remaining network/check stages at their next fence, and the store's own
    /// validation/staging steps keep observing the same task cancellation
    /// (removing only the directories that call staged, never the manifest).
    /// The atomic manifest promotion itself can never be interrupted or rolled
    /// back once entered; if it completes despite the cancel, the attempt
    /// reports the real installed truth (`promoted == true`), not a fake
    /// cancellation. No force-quit is promised or performed: a network read
    /// already inside the transport unwinds when the transport itself observes
    /// cancellation.
    func cancelInstall(_ id: String) {
        guard let task = installTasks[id], installStates[id]?.running == true else { return }
        if var state = installStates[id] {
            state.cancelling = true
            installStates[id] = state
        }
        task.cancel()
    }

    /// Starts the attempt or joins the live one (never two per id). The
    /// prologue runs synchronously on the main actor, so concurrent callers
    /// cannot both pass the "no live task" check. Terminal transitions are
    /// fenced on the attempt token: a late callback from an old task can never
    /// replace a newer attempt's state.
    @discardableResult
    func performAttempt(
        id: String,
        operation: @escaping @MainActor @Sendable (ContentInstallAttempt) async throws -> Void
    ) async -> ContentInstallState? {
        let task = startAttempt(id: id, operation: operation)
        await task.value
        return installStates[id]
    }

    /// Creates and registers the service-owned task, or returns the live one.
    /// A new attempt for an id replaces that id's previous record, which is
    /// what clears the matching old error (nothing else loses state).
    @discardableResult
    func startAttempt(
        id: String,
        operation: @escaping @MainActor @Sendable (ContentInstallAttempt) async throws -> Void
    ) -> Task<Void, Never> {
        if let existing = installTasks[id] { return existing }
        let attempt = ContentInstallAttempt(id: id, token: UUID())
        installStates[id] = ContentInstallState(attempt: attempt.token, running: true)
        installingIDs.insert(id)
        errorMessage = nil
        let task = Task { @MainActor in
            do {
                try await operation(attempt)
                // The transaction finished. Even if cancellation arrived on
                // the way, everything before the atomic promotion that was
                // still required ran: report the installed truth.
                self.finishAttempt(attempt) { state in
                    state.running = false
                    state.cancelling = false
                    state.phase = nil
                    state.promoted = true
                    state.wasCancelled = false
                }
            } catch {
                self.finishAttempt(attempt) { state in
                    state.running = false
                    state.phase = nil
                    if state.promoted {
                        // The atomic transaction ALREADY completed (receipt
                        // recorded when the store returned). A failure in the
                        // mirroring/refresh tail afterwards keeps BOTH truths:
                        // the content really is installed/re-pointed, and the
                        // tail error is visible. Cancellation is moot now.
                        state.cancelling = false
                        state.wasCancelled = false
                        state.failure = Self.describe(error)
                        self.errorMessage = state.failure
                    } else if error is CancellationError {
                        state.cancelling = false
                        state.wasCancelled = true
                    } else if state.cancelling && Self.isCancellationFlavoured(error) {
                        // A cancelled job that ended without promoting is a
                        // normal cancellation, not a failure.
                        state.cancelling = false
                        state.wasCancelled = true
                    } else {
                        // Real error — also visible through the global
                        // message for every existing consumer.
                        state.failure = Self.describe(error)
                        self.errorMessage = state.failure
                    }
                }
            }
        }
        installTasks[id] = task
        return task
    }

    /// Records that this attempt's ATOMIC store transaction completed (an
    /// install promotion or a rollback re-point). The receipt is written the
    /// moment the store returns, before any mirroring/refresh tail, so a
    /// later tail failure can never rewrite the installed truth: the attempt
    /// then reports BOTH `promoted == true` and the real error. Owner-internal
    /// (the commit paths call it; focused tests exercise the boundary).
    func recordPromotion(_ attempt: ContentInstallAttempt?) {
        guard let attempt, var state = installStates[attempt.id],
              state.attempt == attempt.token, state.running else { return }
        state.promoted = true
        installStates[attempt.id] = state
    }

    /// Applies a terminal transition to the LATEST attempt only. A stale
    /// callback (attempt token mismatch) is dropped untouched.
    private func finishAttempt(
        _ attempt: ContentInstallAttempt,
        _ mutate: (inout ContentInstallState) -> Void
    ) {
        guard var state = installStates[attempt.id], state.attempt == attempt.token else { return }
        mutate(&state)
        installStates[attempt.id] = state
        if !state.running {
            if installTasks[attempt.id] != nil { installTasks[attempt.id] = nil }
            installingIDs.remove(attempt.id)
        }
    }

    /// Records the service's actual reason an install could not even start
    /// (no frozen verified feed), as a real per-id failure — never as a
    /// phantom running task. A live attempt for the same id wins.
    private func noteAttemptBlocked(id: String, message: String) {
        if let state = installStates[id], state.running { return }
        installStates[id] = ContentInstallState(attempt: UUID(), running: false, failure: message)
    }

    /// Phase is only ever advanced by the live attempt it belongs to, and only
    /// while that attempt is still running.
    private func setInstallPhase(_ attempt: ContentInstallAttempt?, _ phase: ContentInstallPhase) {
        guard let attempt, var state = installStates[attempt.id],
              state.attempt == attempt.token, state.running else { return }
        state.phase = phase
        installStates[attempt.id] = state
    }

    /// Errors the transport raises because the caller's task was cancelled.
    /// Only classified as a normal cancellation when this center actually
    /// requested it (`cancelling`), so a network blip is never laundered into
    /// "the user cancelled".
    static func isCancellationFlavoured(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        // Foundation's CocoaError cancellation code is `.userCancelled`;
        // `.cancelled` exists only on URLError (verified against the real
        // Foundation type by Main's review).
        if let cocoaError = error as? CocoaError { return cocoaError.code == .userCancelled }
        if let posix = error as? POSIXError { return posix.code == ECANCELED }
        return false
    }

    /// Authoritative, re-validated commit. The store re-checks version,
    /// immutability, pin and capability rules against its current state; the
    /// frozen feed commit is the only source of bytes. A failure never leaves
    /// a half-applied batch.
    ///
    /// Cancellation contract (`attempt` set when this runs as a service-owned
    /// job): every network/check stage is fenced, and the final fence sits
    /// immediately BEFORE the atomic manifest promotion is started, so a
    /// cancel can only ever stop work that has not promoted anything. Once
    /// `store.commit`/`commitAutomatically` is invoked it is never interrupted,
    /// never rolled back and its result is reported as the installed truth —
    /// including when cancellation arrived while it was running. No content,
    /// history or unrelated file is deleted on the cancel path.
    private func commitEntries(
        _ ids: [String],
        snapshot: FeedSnapshot,
        store: ContentUpdateStore,
        automatic: Bool = false,
        attempt: ContentInstallAttempt? = nil
    ) async throws {
        for id in ids {
            guard !installInFlight.contains(id) else {
                throw ContentUpdateStoreError.conflict("already installing \(id)")
            }
        }
        // Fence 0: the job was cancelled before any of its stages started.
        try Task.checkCancellation()
        _ = try await store.removeVersionPins()
        let plan = try await store.plan(feed: snapshot.feed, appVersion: appVersion)
        let planningState = await store.currentState()
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
                if automatic && !ContentUpdateActionPolicy.automaticUpdateAllowed(id: id,
                    version: item.entry.version, state: planningState) {
                    throw ContentUpdateStoreError.conflict("automatic dependency would undo rollback for \(id)")
                }
                needed.append(id)
            }
        }
        for id in ids { try collect(id) }
        guard !needed.isEmpty, needed.count <= Self.maximumBatchEntries else { return }
        for id in needed { installInFlight.insert(id) }
        defer { for id in needed { installInFlight.remove(id) } }

        setInstallPhase(attempt, .fetching)
        var batch: [ContentUpdateStore.BatchItem] = []
        for id in needed {
            // Fence per package: an abandoned job never fetches the next
            // signed payload.
            try Task.checkCancellation()
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
        setInstallPhase(attempt, .committing)
        // Final fence, AFTER the last await and BEFORE the atomic promotion:
        // once the store transaction is invoked below it runs to completion
        // and its result is the truth, cancellation or not.
        try Task.checkCancellation()
        let next: ContentUpdateState
        if automatic {
            next = try await store.commitAutomatically(batch, appVersion: appVersion,
                allowedCapabilities: Self.allowedCapabilities, domainValidate: Self.domainValidator)
        } else {
            next = try await store.commit(batch, appVersion: appVersion,
                allowedCapabilities: Self.allowedCapabilities, domainValidate: Self.domainValidator)
        }
        // Promotion receipt FIRST, before any tail: everything below only
        // mirrors/refreshes published state; a failure there keeps this
        // attempt's `promoted == true` alongside the real error.
        recordPromotion(attempt)
        await apply(next)
        let refreshed = try await store.plan(feed: snapshot.feed, appVersion: appVersion)
        feedSnapshot = FeedSnapshot(
            commit: snapshot.commit, feed: snapshot.feed, plannedByID: decisions(refreshed)
        )
        available = refreshed.items.mapValues { AvailableContent(entry: $0.entry, decision: $0.decision) }
    }

    /// Rollback shares the same service-owned attempt machinery as install:
    /// per-id state, join-if-live, `cancelInstall(_:)` targets it, and the
    /// manifest re-point is an atomic store transaction that a cancellation
    /// can only refuse to START (fence below), never interrupt midway.
    func rollback(_ id: String) async {
        await ensureLoaded()
        guard let store else {
            errorMessage = storageError
            noteAttemptBlocked(id: id, message: storageError ?? FloeL10n.l("content.update.error.storage_unavailable"))
            return
        }
        await performAttempt(id: id) { attempt in
            let actions = await store.actionSnapshot(appVersion: self.appVersion,
                builtInBaselines: Self.builtInBaselines, domainValidate: Self.domainValidator)
            guard let target = actions.rollbackTargets[id] else {
                await self.apply(actions.state)
                throw ContentUpdateStoreError.conflict("no usable retained version for \(id)")
            }
            // Fence immediately before the atomic manifest re-point.
            try Task.checkCancellation()
            self.setInstallPhase(attempt, .committing)
            _ = try await store.rollback(id: id, appVersion: self.appVersion, toVersion: target.entry.version)
            // Re-point receipt BEFORE the tail: if the pin retirement/refresh
            // below fails, the rollback itself really happened and the
            // attempt reports the rolled-back truth alongside the error.
            self.recordPromotion(attempt)
            // The old store pins explicit restores. No hidden pin survives
            // this UI action now that the pin control has been retired.
            do {
                let next = try await store.removeVersionPins()
                await self.apply(next)
            } catch {
                await self.apply(await store.currentState())
                throw error
            }
            if let snapshot = self.feedSnapshot,
               let refreshed = try? await store.plan(feed: snapshot.feed, appVersion: self.appVersion) {
                self.available = refreshed.items.mapValues {
                    AvailableContent(entry: $0.entry, decision: $0.decision)
                }
            }
        }
    }

    func canRollback(_ id: String) -> Bool {
        installed[id]?.previousVersion != nil && !installingIDs.contains(id)
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
            await performAttempt(id: Self.providerPackageID) { attempt in
                guard let snapshot = self.feedSnapshot, let store = self.store else {
                    throw ContentUpdateStoreError.conflict("no frozen feed")
                }
                try await self.commitEntries(
                    [Self.providerPackageID], snapshot: snapshot, store: store, attempt: attempt
                )
            }
        }
    }

    // MARK: - Search provider catalog (signed package only)

    /// The effective search-provider catalog: the active signed install when
    /// one exists, otherwise the app-bundled copy. Never fetched unsigned and
    /// never mutated by UI code; a corrupt/absent install silently falls back
    /// to the bundle so the add page keeps working while the update surface
    /// explains the failure.
    func searchProviderCatalog() -> SearchProviderCatalogIndex? {
        searchProviderCatalogCache ?? SearchProviderCatalogIndex.loadBundled()
    }

    /// True when a signed catalog revision newer than the active/bundled one
    /// is available for review. The instance list shows per-instance update
    /// badges only for real endpoint/option/credential diffs; the catalog-
    /// owned official supplier titles refresh automatically through the
    /// settings center's title sync and never appear as a manual update.
    var searchProviderCatalogUpdateAvailable: Bool {
        available[Self.searchProviderPackageID]?.decision.isUpdate == true
    }

    /// Signed refresh + install for the search catalog only. Delegated from
    /// both the Content Updates page and the Add Provider page through this
    /// single owner; verification, version policy and atomic install are the
    /// unchanged production path.
    func refreshSearchProviderCatalog() async {
        await ensureLoaded()
        await checkForUpdates(force: true)
        guard let decision = available[Self.searchProviderPackageID]?.decision else { return }
        if decision.isUpdate {
            await performAttempt(id: Self.searchProviderPackageID) { attempt in
                guard let snapshot = self.feedSnapshot, let store = self.store else {
                    throw ContentUpdateStoreError.conflict("no frozen feed")
                }
                try await self.commitEntries(
                    [Self.searchProviderPackageID], snapshot: snapshot, store: store, attempt: attempt
                )
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
        if entry.kind == .providers {
            // Narrow dispatch by package identity/payload. The compatibility
            // package keeps its full ProviderCatalog validation; the search
            // catalog package must pass the typed search-catalog gate. Each
            // payload validator is only applied to its own package, so neither
            // gate is weakened for the other.
            if entry.id == searchProviderPackageID,
               let catalogData = files[searchProviderCatalogPath] {
                _ = try SearchProviderCatalogDocument.validated(from: catalogData)
            }
            if let catalogData = files[providerCatalogPath] {
                _ = try ProviderCatalogIndex.validated(from: catalogData)
            }
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
