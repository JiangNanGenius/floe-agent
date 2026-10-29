// FloeCore — Shared storage snapshot: layout, persistence, refresh policy and
// the single process-wide scan coordinator.
//
// Why this exists (Build 273 user report: Settings → Data Management showed
// >100 GB on an upgraded iPad while iOS Storage showed ~20 GB for the app, and
// opening the page re-scanned on every appearance):
//
// 1. A scan is expensive; it must produce ONE shared snapshot that the page
//    re-renders immediately on reopen, and it must not run again while that
//    snapshot is still fresh. `StorageSnapshotCenter` owns the single in-flight
//    scan, deduplicates concurrent callers, persists the last valid snapshot
//    and only re-scans when the snapshot is stale, was invalidated by a real
//    mutation, or the user explicitly refreshes.
// 2. The persisted snapshot is validated against a schema/accounting/roots
//    fingerprint; any mismatch (upgrade, layout change, accounting fix) is
//    discarded instead of serving flawed historical values.
// 3. Byte semantics stay measured and honest: pure full-clone APFS streams are
//    deduplicated exactly (public-SDK getattrlist clone-id +
//    SHARES_ALL_BLOCKS), measured private bytes provide a lower bound, and
//    clone-capable bytes that remain shared are an explicit non-additive
//    figure — never silently subtracted, never presented as the app footprint.

import Foundation

/// Version of the accounting semantics. Bump whenever the meaning of the
/// persisted numbers changes so older cached snapshots are discarded.
public enum StorageAccountingVersion {
    /// v4: measured physical-block union (public `fcntl F_LOG2PHYS_EXT`)
    /// becomes the numeric basis when every measured file reconciles with
    /// `st_blocks`, including the optional app-bundle root; the v3 clone-id
    /// figure stays the fallback when the union cannot be collected. Snapshots
    /// from v3 and earlier (allocated estimates only) are discarded ONCE so a
    /// build upgrade cannot keep serving the old inflated total.
    public static let current = "2026-10-16.extent-union.v4"
}

/// Resolved base directories. Injectable so tests (and other Floe components)
/// can point the layout at a fixture tree instead of the live container.
public struct FloeStorageBase: Sendable, Equatable {
    public var applicationSupport: URL?
    public var library: URL?
    public var documents: URL?
    public var caches: URL?
    public var temporary: URL

    public init(
        applicationSupport: URL?,
        library: URL?,
        documents: URL?,
        caches: URL?,
        temporary: URL
    ) {
        self.applicationSupport = applicationSupport
        self.library = library
        self.documents = documents
        self.caches = caches
        self.temporary = temporary
    }

    /// The real app container directories.
    public static var standard: FloeStorageBase {
        let manager = FileManager.default
        return FloeStorageBase(
            applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            library: manager.urls(for: .libraryDirectory, in: .userDomainMask).first,
            documents: manager.urls(for: .documentDirectory, in: .userDomainMask).first,
            caches: manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            temporary: manager.temporaryDirectory
        )
    }
}

/// Static description of the on-disk roots Floe owns. Centralized so Settings,
/// the Linux/environment managers, the model catalog and the asset stores can
/// reuse ONE census instead of each walking a container and mis-reading
/// sparse/clone sizes.
public enum FloeStorageLayout {
    public static func floeAgentRoot(in base: FloeStorageBase) -> URL? {
        base.applicationSupport?.appendingPathComponent("FloeAgent", isDirectory: true)
    }

    /// Runtime v2 lives in a *sibling* of FloeAgent (`<App Support>/Floe/...`).
    public static func runtimeV2Root(in base: FloeStorageBase) -> URL? {
        base.applicationSupport?
            .appendingPathComponent("Floe", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }

    public static let dataManagementMetricLabel = "storage.data_management.v2"

    /// Mutually-exclusive, deepest-match root list for the data-management
    /// snapshot. Clone flags are source-grounded:
    /// * Environments/ContainerCAS materializes environment files with
    ///   `clonefile` (copy-on-write) when the volume supports it.
    /// * LinuxGuest legacy images are cloned by `LinuxGuestRuntimeImage`.
    /// * Runtime v2 blobs/expanded views are content-addressed clones.
    public static func roots(in base: FloeStorageBase) -> [StorageCensusRoot] {
        let support = floeAgentRoot(in: base)
        func app(_ component: String) -> URL? {
            support?.appendingPathComponent(component, isDirectory: true)
        }
        var roots: [StorageCensusRoot] = []
        func add(_ id: String, _ url: URL?,
                 attribution: StorageCensusRoot.Attribution = .category,
                 hidden: Bool = true,
                 potentiallyCloned: Bool = false) {
            guard let url else { return }
            roots.append(StorageCensusRoot(
                id: id, url: url, attribution: attribution,
                includeHiddenFiles: hidden, potentiallyCloned: potentiallyCloned
            ))
        }

        // Most-specific roots first; the census attributes a file to the
        // deepest match and dedups hard links/overlaps by file identity.
        add("models", app("LocalModels"))
        add("workspaces", app("PrivateTasks"))
        add("fonts", app("Fonts"))
        add("attachments", app("Attachments"))
        add("generated", app("GeneratedImages"))
        add("browser", app("BrowserArtifacts"))
        add("checkpoints", app("Checkpoints"))
        add("materials", app("Materials"))
        add("canvases", app("Canvases"))
        add("mediaProjects", app("MediaProjects"))
        add("cad", app("CanvasCAD"))
        // Environment containers hold clone-materialized disks/rootfs files.
        add("environments", app("Environments"), potentiallyCloned: true)
        // Legacy TinyEMU disks (nested under writable layers; deduped by
        // identity). Upgraded installs may still carry them next to Runtime v2.
        add("linuxDisks", app("LinuxGuest"), potentiallyCloned: true)
        // Runtime v2 content-addressed blobs are CoW-cloned across images. They
        // are counted in full (clones can hold unique blocks) but the total is
        // flagged as an upper estimate.
        add("runtimeV2", runtimeV2Root(in: base),
            attribution: .shared, potentiallyCloned: true)
        // Everything else left under FloeAgent.
        add("floeOther", support)

        // Standalone roots outside Application Support but inside the Library
        // parent walk; listed so they get their own bucket labels.
        add("library", base.library)
        add("documents", base.documents)
        add("caches", base.caches)
        add("temporary", base.temporary)
        return roots
    }

    /// Library is the single mutually-exclusive parent: it contains both
    /// Application Support/FloeAgent and Caches. Documents/ and tmp/ are walked
    /// separately because they are not under Library.
    public static func parentURL(in base: FloeStorageBase) -> URL? {
        base.library
    }

    public static func request(
        in base: FloeStorageBase = .standard,
        metricLabel: String = FloeStorageLayout.dataManagementMetricLabel,
        contextFingerprint: String = "",
        bundleURL: URL? = nil
    ) -> StorageCensusRequest {
        StorageCensusRequest(
            roots: roots(in: base),
            parentURL: parentURL(in: base),
            metricLabel: metricLabel,
            contextFingerprint: contextFingerprint,
            bundleURL: bundleURL
        )
    }

    // MARK: - Convenience accessors (default container)

    public static func applicationSupportRoot() -> URL? { FloeStorageBase.standard.applicationSupport }
    public static func floeAgentRoot() -> URL? { floeAgentRoot(in: FloeStorageBase.standard) }
    public static func runtimeV2Root() -> URL? { runtimeV2Root(in: FloeStorageBase.standard) }
    public static func libraryRoot() -> URL? { FloeStorageBase.standard.library }
    public static func documentsRoot() -> URL? { FloeStorageBase.standard.documents }
    public static func cachesRoot() -> URL? { FloeStorageBase.standard.caches }
    public static var temporaryRoot: URL { FloeStorageBase.standard.temporary }
}

/// One complete description of what a census walks. The fingerprint of this
/// value is what a persisted snapshot is validated against.
public struct StorageCensusRequest: Sendable, Equatable {
    public var roots: [StorageCensusRoot]
    public var parentURL: URL?
    public var metricLabel: String
    /// Extra identity of the caller's data model (e.g. app version/build) that
    /// must invalidate a cached snapshot when it changes.
    public var contextFingerprint: String
    /// Optional app-bundle root measured into the same extent union as the
    /// data roots (clone reconciliation across the installer/data boundary).
    /// Part of the snapshot key: a snapshot measured without it is never
    /// served to a request that measures with it.
    public var bundleURL: URL?

    public init(
        roots: [StorageCensusRoot],
        parentURL: URL?,
        metricLabel: String,
        contextFingerprint: String = "",
        bundleURL: URL? = nil
    ) {
        self.roots = roots
        self.parentURL = parentURL
        self.metricLabel = metricLabel
        self.contextFingerprint = contextFingerprint
        self.bundleURL = bundleURL?.standardizedFileURL
    }

    public var key: StorageSnapshotKey {
        StorageSnapshotKey(
            schemaVersion: StorageSnapshot.currentSchemaVersion,
            accountingVersion: StorageAccountingVersion.current,
            rootsFingerprint: Self.rootsFingerprint(
                roots: roots,
                parentURL: parentURL,
                metricLabel: metricLabel,
                contextFingerprint: contextFingerprint,
                bundleURL: bundleURL
            )
        )
    }

    /// Deterministic, order-independent fingerprint over the exact walk
    /// semantics. FNV-1a (64-bit) is sufficient: this detects configuration
    /// drift, it is not a security boundary.
    static func rootsFingerprint(
        roots: [StorageCensusRoot],
        parentURL: URL?,
        metricLabel: String,
        contextFingerprint: String,
        bundleURL: URL? = nil
    ) -> String {
        func canonicalURL(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        var lines: [String] = []
        let sorted = roots.sorted {
            ($0.id, canonicalURL($0.url)) < ($1.id, canonicalURL($1.url))
        }
        for root in sorted {
            let attribution = root.attribution == .shared ? "shared" : "category"
            lines.append([
                "root", root.id, canonicalURL(root.url), attribution,
                root.includeHiddenFiles ? "hidden" : "visible",
                root.potentiallyCloned ? "clone" : "plain"
            ].joined(separator: "\u{1F}"))
        }
        lines.append(["parent", parentURL.map(canonicalURL) ?? "-"].joined(separator: "\u{1F}"))
        lines.append(["metric", metricLabel].joined(separator: "\u{1F}"))
        lines.append(["context", contextFingerprint].joined(separator: "\u{1F}"))
        lines.append(["bundle", bundleURL.map(canonicalURL) ?? "-"].joined(separator: "\u{1F}"))
        return "fnv1a64:" + String(Self.fnv1a64(lines.joined(separator: "\n")), radix: 16)
    }

    /// FNV-1a 64-bit hash, hex encoded by the caller.
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Identity a persisted snapshot must match to be used.
public struct StorageSnapshotKey: Sendable, Equatable {
    public let schemaVersion: Int
    public let accountingVersion: String
    public let rootsFingerprint: String

    public init(schemaVersion: Int, accountingVersion: String, rootsFingerprint: String) {
        self.schemaVersion = schemaVersion
        self.accountingVersion = accountingVersion
        self.rootsFingerprint = rootsFingerprint
    }
}

/// A completed census plus the context needed to render the exact same totals
/// again. Contains category ids, counts and byte figures only — never file
/// names, paths or contents.
public struct StorageSnapshot: Codable, Equatable, Sendable {
    /// 2: the census carries the optional measured-extent union and the
    /// extent-basis diagnostics; schema 1 snapshots are discarded by
    /// ``StorageSnapshotStore/load(key:)`` (decoding fails closed).
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let accountingVersion: String
    public let rootsFingerprint: String
    public let contextFingerprint: String
    public let metricLabel: String
    /// When the census finished (from the census diagnostics).
    public let generatedAt: Date
    /// When this record was persisted.
    public let persistedAt: Date
    public let bundleBytes: Int64
    public let census: StorageCensusReport
    /// What triggered the scan: "initial", "stale", "explicit", "mutation".
    public let scanTrigger: String

    public init(
        schemaVersion: Int = StorageSnapshot.currentSchemaVersion,
        accountingVersion: String = StorageAccountingVersion.current,
        rootsFingerprint: String,
        contextFingerprint: String,
        metricLabel: String,
        generatedAt: Date,
        persistedAt: Date = Date(),
        bundleBytes: Int64,
        census: StorageCensusReport,
        scanTrigger: String
    ) {
        self.schemaVersion = schemaVersion
        self.accountingVersion = accountingVersion
        self.rootsFingerprint = rootsFingerprint
        self.contextFingerprint = contextFingerprint
        self.metricLabel = metricLabel
        self.generatedAt = generatedAt
        self.persistedAt = persistedAt
        self.bundleBytes = bundleBytes
        self.census = census
        self.scanTrigger = scanTrigger
    }

    /// The scan finished but some measurement was unavailable; totals are a
    /// lower/uncertain bound and the UI must say so instead of presenting a
    /// clean number.
    public var isPartial: Bool { census.diagnostics.hasMeasurementGaps }
}

/// Atomic, validated snapshot persistence.
public struct StorageSnapshotStore: Sendable {
    public static let defaultFileName = "storage-snapshot.json"
    public static let maximumSnapshotBytes = 8 * 1024 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.defaultFileName, isDirectory: false)
    }

    /// Loads the snapshot only when it matches the current schema, accounting
    /// version and exact roots. Anything else (upgrade, layout change, corrupt
    /// or oversized file) returns nil: a flawed historical value is discarded,
    /// never shown as if it were current.
    public func load(key: StorageSnapshotKey) -> StorageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              data.count <= Self.maximumSnapshotBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(StorageSnapshot.self, from: data) else { return nil }
        guard snapshot.schemaVersion == key.schemaVersion,
              snapshot.accountingVersion == key.accountingVersion,
              snapshot.rootsFingerprint == key.rootsFingerprint else { return nil }
        return snapshot
    }

    /// Atomic replace: a crash mid-write can never leave a truncated snapshot.
    public func save(_ snapshot: StorageSnapshot) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// When an automatic refresh may run without an explicit user action.
public struct StorageRefreshPolicy: Sendable, Equatable {
    /// A snapshot younger than this is served as-is on view appearance.
    public var freshnessInterval: TimeInterval
    /// After a failed scan, automatic retries wait this long (explicit refresh
    /// always bypasses).
    public var retryCooldown: TimeInterval
    /// When true, a scan is cancelled once its last waiter goes away. Default
    /// false: a bounded scan is allowed to finish and fill the shared cache so
    /// the next appearance is instant.
    public var cancelsScanWithoutWaiters: Bool

    public init(
        freshnessInterval: TimeInterval = 600,
        retryCooldown: TimeInterval = 30,
        cancelsScanWithoutWaiters: Bool = false
    ) {
        self.freshnessInterval = freshnessInterval
        self.retryCooldown = retryCooldown
        self.cancelsScanWithoutWaiters = cancelsScanWithoutWaiters
    }
}

public enum StorageRefreshDecision: Sendable, Equatable {
    /// A scan is required (or an in-flight scan must be joined).
    case scan
    /// The cached snapshot is fresh enough to render as-is.
    case serveCache
    /// The last automatic attempt failed recently; serve the kept snapshot
    /// without hammering the disk again.
    case cooldown
}

public extension StorageRefreshPolicy {
    /// Pure decision function (unit-tested). `hasInFlight` means "join the
    /// running scan"; explicit refresh and real mutations always scan.
    static func decide(
        hasSnapshot: Bool,
        snapshotGeneratedAt: Date?,
        isExplicit: Bool,
        needsRefresh: Bool,
        hasInFlight: Bool,
        consecutiveFailures: Int,
        lastAttemptAt: Date?,
        now: Date,
        policy: StorageRefreshPolicy
    ) -> StorageRefreshDecision {
        if hasInFlight { return .scan }
        if isExplicit { return .scan }
        // Nothing to show yet: always allow an attempt.
        if !hasSnapshot { return .scan }
        // A failed refresh keeps the last valid snapshot on screen and waits
        // out the cooldown instead of re-scanning on every appearance. The
        // pending mutation (needsRefresh) is intentionally satisfied by the
        // first successful scan, not by hammering after a failure.
        if consecutiveFailures > 0, let lastAttempt = lastAttemptAt,
           now.timeIntervalSince(lastAttempt) < policy.retryCooldown {
            return .cooldown
        }
        if needsRefresh { return .scan }
        if let generatedAt = snapshotGeneratedAt,
           now.timeIntervalSince(generatedAt) <= policy.freshnessInterval {
            return .serveCache
        }
        return .scan
    }
}

/// Real, user-visible data mutation. A refresh is forced on the next
/// appearance; explicit refresh is always available regardless.
public enum StorageMutationReason: Sendable, Equatable {
    case cleanupCompleted
    case environmentChanged
    case modelStoreChanged
    case mediaStoreChanged
    case other(String)
}

public enum StorageRefreshOutcome: Sendable, Equatable {
    /// A snapshot is available (freshly scanned or served from the cache).
    case served(StorageSnapshot, fromCache: Bool)
    case cancelled(kept: StorageSnapshot?)
    case failed(kept: StorageSnapshot?)
    /// The finished scan was invalidated by a mutation that happened while it
    /// ran; the kept snapshot is returned and the next refresh scans again.
    case superseded(kept: StorageSnapshot?)
}

/// The single process-wide scan coordinator: one cache, one in-flight scan,
/// one persisted snapshot. All storage surfaces (data management, Linux/
/// environment managers, model catalog, material stores) must go through this
/// instead of starting their own censuses.
/// Thread-safe measured progress for the running census (regular files
/// visited). Shared with the scanner so progress can be polled from any
/// isolation domain without escaping issues.
public final class StorageScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var finished = false

    public init() {}

    public func update(_ value: Int) {
        lock.lock(); count = max(count, value); lock.unlock()
    }

    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    public var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }; return finished
    }
}

public final class StorageSnapshotCenter: @unchecked Sendable {
    public typealias Scanner = @Sendable (StorageCensusRequest, StorageScanProgress) throws -> StorageCensusReport
    public typealias BundleBytesProvider = @Sendable () -> Int64

    /// Production scanner: the identity-deduplicating, sparse-aware census
    /// with the measured physical-extent probe enabled. The optional bundle
    /// root is measured into the same union so the installer and user data
    /// reconcile; when the extent basis cannot be collected the census keeps
    /// the accepted allocated basis and the snapshot publishes no union.
    public static func defaultScanner() -> Scanner {
        { request, progress in
            try StorageCensus(
                roots: request.roots,
                parentURL: request.parentURL,
                metricLabel: request.metricLabel,
                isCancelled: { Task.isCancelled },
                onProgress: { count in progress.update(count) },
                extentProbe: .system,
                bundleMeasurementURL: request.bundleURL
            ).run()
        }
    }

    private enum ScanOutcome: Sendable {
        case report(StorageCensusReport, bundleBytes: Int64)
        case cancelled
        case failed
    }

    private final class ScanJob: @unchecked Sendable {
        let generation: UInt64
        let trigger: String
        let progress = StorageScanProgress()
        /// Guarded by the center lock.
        var waiters = 0
        var task: Task<ScanOutcome, Never>!
        /// Set once, by the first waiter to observe the finished task.
        var finalizedOutcome: StorageRefreshOutcome?
        init(generation: UInt64, trigger: String) {
            self.generation = generation
            self.trigger = trigger
        }
    }

    private final class WaiterToken: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        /// Runs `body` at most once.
        func consume(_ body: () -> Void) {
            lock.lock()
            let shouldRun = active
            active = false
            lock.unlock()
            if shouldRun { body() }
        }
    }

    private let lock = NSLock()
    private let store: StorageSnapshotStore?
    private let request: StorageCensusRequest
    public let policy: StorageRefreshPolicy
    private let scanner: Scanner
    private let bundleBytesProvider: BundleBytesProvider

    private var snapshot: StorageSnapshot?
    private var didHydrate = false
    private var generation: UInt64 = 0
    /// True when a mutation happened after the current snapshot was published.
    private var needsRefresh = false
    private var consecutiveFailures = 0
    private var lastAttemptAt: Date?
    private var lastCompletedFileCount = 0
    private var inFlight: ScanJob?

    public init(
        store: StorageSnapshotStore?,
        request: StorageCensusRequest,
        policy: StorageRefreshPolicy = StorageRefreshPolicy(),
        scanner: @escaping Scanner = StorageSnapshotCenter.defaultScanner(),
        bundleBytesProvider: @escaping BundleBytesProvider = { 0 }
    ) {
        self.store = store
        self.request = request
        self.policy = policy
        self.scanner = scanner
        self.bundleBytesProvider = bundleBytesProvider
    }

    // MARK: - Synchronous state

    /// Loads the persisted snapshot once (cheap, small JSON). A schema/
    /// accounting/roots mismatch is discarded by the store.
    public func hydrateIfNeeded() {
        lock.lock()
        if didHydrate {
            lock.unlock()
            return
        }
        didHydrate = true
        lock.unlock()

        guard let store, let loaded = store.load(key: request.key) else { return }
        lock.lock()
        if snapshot == nil {
            snapshot = loaded
            lastCompletedFileCount = loaded.census.diagnostics.regularFileCount
        }
        lock.unlock()
    }

    public func cachedSnapshot() -> StorageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public var isScanning: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight != nil
    }

    /// Measured regular files visited by the running (or last) census.
    public var scannedFiles: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight?.progress.value ?? lastCompletedFileCount
    }

    /// True when the next `refresh(explicit:)` would actually run/join a scan.
    public func willScan(explicit: Bool) -> Bool {
        hydrateIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return decideLocked(now: Date(), explicit: explicit) == .scan
    }

    /// Real mutation: the snapshot is kept for immediate rendering but
    /// invalidated, so the next automatic refresh scans once.
    public func invalidate(reason: StorageMutationReason) {
        lock.lock()
        generation &+= 1
        needsRefresh = true
        lock.unlock()
    }

    /// Cancels the running scan (user-visible "Stop"). Waiters receive
    /// `.cancelled(kept:)` and the previous snapshot is never cleared.
    public func cancelInFlight() {
        lock.lock()
        let job = inFlight
        lock.unlock()
        job?.task.cancel()
    }

    // MARK: - Refresh

    public func refresh(explicit: Bool) async -> StorageRefreshOutcome {
        hydrateIfNeeded()
        let preparation = prepareRefresh(explicit: explicit)
        guard let job = preparation.job else {
            // No scan needed: serve the cache, or fail closed instead of
            // reporting a zero state.
            return preparation.served ?? .failed(kept: nil)
        }

        let token = WaiterToken()
        let raw = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            // The awaiting view went away. Drop the waiter; by default the
            // bounded scan still finishes and fills the shared cache.
            token.consume { self.dropWaiter(job) }
        }
        token.consume { self.dropWaiter(job) }
        return finalize(job: job, raw: raw)
    }

    // MARK: - Internals

    private struct RefreshPreparation {
        /// Non-nil when the refresh can be answered without scanning.
        let served: StorageRefreshOutcome?
        /// Non-nil when the caller must await the shared scan.
        let job: ScanJob?
    }

    /// Synchronous critical section for `refresh`: all lock acquisition stays
    /// out of the async function (NSLock is not usable across suspension).
    private func prepareRefresh(explicit: Bool) -> RefreshPreparation {
        lock.lock()
        defer { lock.unlock() }
        let decision = decideLocked(now: Date(), explicit: explicit)
        if decision != .scan {
            if let cached = snapshot {
                return RefreshPreparation(
                    served: decision == .cooldown ? .failed(kept: cached) : .served(cached, fromCache: true),
                    job: nil
                )
            }
            return RefreshPreparation(served: .failed(kept: nil), job: nil)
        }
        let job: ScanJob
        if let existing = inFlight {
            job = existing
        } else {
            let trigger = explicit ? "explicit"
                : (snapshot == nil ? "initial" : (needsRefresh ? "mutation" : "stale"))
            job = makeJobLocked(trigger: trigger)
            inFlight = job
        }
        job.waiters += 1
        return RefreshPreparation(served: nil, job: job)
    }

    private func decideLocked(now: Date, explicit: Bool) -> StorageRefreshDecision {
        StorageRefreshPolicy.decide(
            hasSnapshot: snapshot != nil,
            snapshotGeneratedAt: snapshot?.generatedAt,
            isExplicit: explicit,
            needsRefresh: needsRefresh,
            hasInFlight: inFlight != nil,
            consecutiveFailures: consecutiveFailures,
            lastAttemptAt: lastAttemptAt,
            now: now,
            policy: policy
        )
    }

    private func makeJobLocked(trigger: String) -> ScanJob {
        let job = ScanJob(generation: generation, trigger: trigger)
        let request = self.request
        let scanner = self.scanner
        let bundleBytesProvider = self.bundleBytesProvider
        let store = self.store
        job.task = Task.detached(priority: .utility) { [weak self] () -> ScanOutcome in
            defer { job.progress.finish() }
            do {
                let census = try scanner(request, job.progress)
                let bundleBytes = bundleBytesProvider()
                // Persist only a result that still belongs to the current
                // generation; a superseded scan must not overwrite the cache.
                if let self, self.isCurrentGeneration(job.generation), let store {
                    let snapshot = StorageSnapshot(
                        rootsFingerprint: request.key.rootsFingerprint,
                        contextFingerprint: request.contextFingerprint,
                        metricLabel: request.metricLabel,
                        generatedAt: census.diagnostics.completedAt,
                        bundleBytes: bundleBytes,
                        census: census,
                        scanTrigger: job.trigger
                    )
                    try? store.save(snapshot)
                }
                return .report(census, bundleBytes: bundleBytes)
            } catch {
                // Cancellation is judged on the scan task itself: a scanner
                // error while the job was not cancelled is a real failure.
                if Task.isCancelled { return .cancelled }
                return .failed
            }
        }
        return job
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return candidate == generation
    }

    private func dropWaiter(_ job: ScanJob) {
        lock.lock()
        if job.waiters > 0 { job.waiters -= 1 }
        let shouldCancel = job.waiters == 0 && inFlight === job && policy.cancelsScanWithoutWaiters
        lock.unlock()
        if shouldCancel { job.task.cancel() }
    }

    private func finalize(job: ScanJob, raw: ScanOutcome) -> StorageRefreshOutcome {
        lock.lock()
        if let done = job.finalizedOutcome {
            lock.unlock()
            return done
        }
        let outcome: StorageRefreshOutcome
        switch raw {
        case .report(let census, let bundleBytes):
            let built = StorageSnapshot(
                rootsFingerprint: request.key.rootsFingerprint,
                contextFingerprint: request.contextFingerprint,
                metricLabel: request.metricLabel,
                generatedAt: census.diagnostics.completedAt,
                bundleBytes: bundleBytes,
                census: census,
                scanTrigger: job.trigger
            )
            lastAttemptAt = Date()
            consecutiveFailures = 0
            lastCompletedFileCount = census.diagnostics.regularFileCount
            if job.generation == generation {
                snapshot = built
                needsRefresh = false
                outcome = .served(built, fromCache: false)
            } else {
                // A mutation arrived while this scan ran: its numbers may mix
                // pre/post-mutation state. Keep any valid snapshot and let the
                // next refresh scan again; publish only when nothing else
                // exists to render.
                needsRefresh = true
                if snapshot == nil {
                    snapshot = built
                    outcome = .served(built, fromCache: false)
                } else {
                    outcome = .superseded(kept: snapshot)
                }
            }
        case .cancelled:
            outcome = .cancelled(kept: snapshot)
        case .failed:
            lastAttemptAt = Date()
            consecutiveFailures += 1
            outcome = .failed(kept: snapshot)
        }
        job.finalizedOutcome = outcome
        if inFlight === job { inFlight = nil }
        lock.unlock()
        return outcome
    }
}
