// FloeApp — Storage diagnostics and ownership-aware safe-cleanup plans.
//
// All figures come from the identity-deduplicating, sparse-aware
// `StorageCensus` in FloeCore. It keeps logical (apparent / configured VM
// capacity) and host-allocated sizes separate, includes previously unscanned
// Floe roots (Environments, the sibling Floe/Runtime/v2 store, Materials and
// others), and labels clone-backed roots as an upper estimate rather than an
// exact freeable total. The physical-device discrepancy between Floe's numbers
// and iOS Storage is not assumed to have a single proven cause; these metrics
// are honest diagnostics, not a claim that the two must match.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// A single categorized bucket for the Data Management UI.
struct StorageCategoryDiagnostic: Identifiable, Sendable {
    let id: String
    let name: String
    let systemImage: String
    /// Host-allocated bytes (sparse-aware). This is the number iOS Storage uses.
    let allocatedBytes: Int64
    /// Apparent/logical bytes. For VM disks this is the *configured guest
    /// capacity*, not the host cost.
    let logicalBytes: Int64
    let fileCount: Int
    /// When true, the allocated figure may include APFS clone blocks that are
    /// shared with other data and is therefore an upper estimate.
    let isSharedEstimate: Bool

    var showsLogicalCapacity: Bool { logicalBytes > allocatedBytes + Self.capacityDeltaThreshold }
    private static let capacityDeltaThreshold: Int64 = 16 * 1024 * 1024
}

/// Category ids whose apparent size mixes sparse VM disk images with other
/// files. The note under these rows states that the apparent figure is NOT
/// the configured guest capacity (no per-VM capacity metadata exists here)
/// and that guest use is only measurable inside the running guest.
let vmDiskMixedCategoryIDs: Set<String> = ["environments", "linuxDisks"]

/// Full snapshot consumed by Settings → Data Management. Carries only
/// category/count/size/error metrics — never file paths, names or contents.
struct StorageDiagnosticReport: Sendable {
    let bundleBytes: Int64
    let categories: [StorageCategoryDiagnostic]
    let unattributed: StorageCategoryDiagnostic?
    let totalAllocatedBytes: Int64
    let totalLogicalBytes: Int64
    let isSharedAllocationEstimate: Bool
    let scanErrorCount: Int
    let changedOrVanishedCount: Int
    let scanDuration: TimeInterval
    let metricLabel: String
    /// When the scan finished (from the census, not the render pass).
    let generatedAt: Date
    /// Regular files visited (measured progress figure).
    let filesScanned: Int

    /// Backwards-compatible rollup for the existing overview rows.
    var combinedBytes: Int64 { bundleBytes + totalAllocatedBytes }
    var dataBytes: Int64 { totalAllocatedBytes }
}

/// Static description of the on-disk roots Floe owns. Centralizing this lets the
/// Linux manager, model catalog and asset stores reuse the same census instead
/// of each walking a container and mis-reading sparse/clone sizes.
enum FloeStorageLayout {
    static func applicationSupportRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
    static func floeAgentRoot() -> URL? {
        applicationSupportRoot()?.appendingPathComponent("FloeAgent", isDirectory: true)
    }
    /// Runtime v2 lives in a *sibling* of FloeAgent (`<App Support>/Floe/...`).
    static func runtimeV2Root() -> URL? {
        applicationSupportRoot()?
            .appendingPathComponent("Floe", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }
    static func libraryRoot() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    }
    static func documentsRoot() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static func cachesRoot() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
    static var temporaryRoot: URL { FileManager.default.temporaryDirectory }
}

@MainActor
final class StorageDiagnosticService: ObservableObject {
    @Published private(set) var report: StorageDiagnosticReport?
    @Published private(set) var isScanning = false
    /// Measured progress: regular files visited so far by the running census.
    @Published private(set) var filesScanned = 0
    @Published private(set) var wasCancelled = false
    /// True when the last scan failed for a reason other than cancellation, so
    /// the UI can say so instead of presenting a silent zero state.
    @Published private(set) var scanFailed = false

    private var currentTask: Task<StorageDiagnosticReport?, Never>?

    func cancel() {
        currentTask?.cancel()
    }

    @discardableResult
    func scan() async -> StorageDiagnosticReport? {
        guard !isScanning else { return report }
        isScanning = true
        wasCancelled = false
        scanFailed = false
        filesScanned = 0
        defer {
            isScanning = false
        }

        let progress = ProgressCounter()
        let task = Task.detached(priority: .utility) { () -> StorageDiagnosticReport? in
            defer { progress.finish() }
            let census = StorageCensus(
                roots: Self.roots(),
                parentURL: Self.parentRoot(),
                metricLabel: "storage.data_management.v2",
                isCancelled: { Task.isCancelled },
                onProgress: { count in progress.update(count) }
            )
            do {
                let result = try census.run()
                return Self.makeReport(from: result)
            } catch {
                return nil
            }
        }
        currentTask = task
        // Publish measured progress while the census runs (real file count,
        // not a synthetic heartbeat). Caller cancellation propagates to the
        // detached census through the cancellation handler; the polling loop
        // exits immediately instead of sleeping again.
        let result = await withTaskCancellationHandler {
            while !progress.isFinished {
                if task.isCancelled || Task.isCancelled { break }
                let count = progress.value
                if count != filesScanned { filesScanned = count }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            filesScanned = progress.value
            return await task.value
        } onCancel: {
            task.cancel()
        }
        if result == nil {
            // Judge cancellation on the detached task that actually ran the
            // census, never on the caller's task.
            if task.isCancelled { wasCancelled = true } else { scanFailed = true }
        }
        if let result { report = result }
        return result
    }

    /// Thread-safe counter for the census progress callback.
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var finished = false

        func update(_ value: Int) {
            lock.lock(); count = max(count, value); lock.unlock()
        }

        func finish() {
            lock.lock(); finished = true; lock.unlock()
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }; return count
        }

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }; return finished
        }
    }

    // MARK: - Root / category mapping

    nonisolated private static func parentRoot() -> URL? {
        // Library is the single mutually-exclusive parent: it contains both
        // Application Support/FloeAgent and Caches. Documents/ and tmp/ are
        // walked separately because they are not under Library.
        FloeStorageLayout.libraryRoot()
    }

    nonisolated private static func roots() -> [StorageCensusRoot] {
        let support = FloeStorageLayout.floeAgentRoot()
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

        // Most-specific roots first; the census attributes a file to the deepest
        // match and dedups hard links/overlaps by file identity.
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
        // Container layers contain sparse per-environment disks.
        add("environments", app("Environments"))
        // Legacy TinyEMU disks (nested under writable layers; deduped by identity).
        add("linuxDisks", app("LinuxGuest"))
        // Runtime v2 content-addressed blobs are CoW-cloned across images. They
        // are counted in full (clones can hold unique blocks) but the total is
        // flagged as an upper estimate.
        add("runtimeV2", FloeStorageLayout.runtimeV2Root(),
            attribution: .shared, potentiallyCloned: true)
        // Everything else left under FloeAgent.
        add("floeOther", support)

        // Standalone roots outside Application Support but inside the Library
        // parent walk; listed so they get their own bucket labels.
        add("library", FloeStorageLayout.libraryRoot())
        add("documents", FloeStorageLayout.documentsRoot())
        add("caches", FloeStorageLayout.cachesRoot())
        add("temporary", FloeStorageLayout.temporaryRoot)
        return roots
    }

    nonisolated private static func makeReport(from result: StorageCensusReport) -> StorageDiagnosticReport {
        let names: [String: (String, String)] = [
            "models": (FloeL10n.l("localmodels.title"), "cpu"),
            "workspaces": (FloeL10n.l("settings.data_management_view.private_workspace"), "folder.badge.gearshape"),
            "fonts": (FloeL10n.l("settings.data_management_view.font_resources"), "textformat"),
            "attachments": (FloeL10n.l("settings.data_management_view.attachments"), "paperclip"),
            "generated": (FloeL10n.l("platform.background_run_coordinator.generate_content"), "photo.on.rectangle"),
            "browser": (FloeL10n.l("settings.data_management_view.browser_downloads"), "globe"),
            "checkpoints": (FloeL10n.l("settings.data_management_view.task_checkpoint"), "arrow.trianglehead.2.clockwise"),
            "materials": (FloeL10n.l("settings.data_management_view.shared_materials"), "square.stack.3d.up"),
            "canvases": (FloeL10n.l("settings.data_management_view.canvases"), "canvas"),
            "mediaProjects": (FloeL10n.l("settings.data_management_view.media_projects"), "film"),
            "cad": (FloeL10n.l("settings.data_management_view.cad_packages"), "cube.box"),
            "environments": (FloeL10n.l("settings.data_management_view.linux_environments"), "desktopcomputer"),
            "linuxDisks": (FloeL10n.l("settings.data_management_view.virtual_machine_disks"), "internaldrive"),
            "runtimeV2": (FloeL10n.l("settings.data_management_view.runtime_images"), "shippingbox.and.arrow.backward"),
            "floeOther": (FloeL10n.l("settings.data_management_view.databases_configuration_and_other_data"), "cylinder"),
            "caches": (FloeL10n.l("settings.data_management_view.rebuildable_caches"), "internaldrive"),
            "temporary": (FloeL10n.l("settings.data_management_view.temporary_files_older_than_one_hour"), "clock.arrow.circlepath"),
            "library": (FloeL10n.l("settings.data_management_view.system_library_data"), "books.vertical"),
            "documents": (FloeL10n.l("settings.data_management_view.documents"), "doc")
        ]

        // Pure arithmetic lives in FloeCore and is unit-tested; every measured
        // bucket is listed exactly once so categories reconcile with the total.
        let report = StorageReportBuilder.build(
            census: result,
            bundleBytes: Self.bundleAllocatedBytes()
        )

        let categories = report.categories.map { category in
            let meta = names[category.id] ?? (category.id, "questionmark.folder")
            return StorageCategoryDiagnostic(
                id: category.id,
                name: meta.0,
                systemImage: meta.1,
                allocatedBytes: category.allocatedBytes,
                logicalBytes: category.logicalBytes,
                fileCount: category.fileCount,
                isSharedEstimate: category.isSharedEstimate
            )
        }

        let unattributed = report.unattributed.map { other in
            StorageCategoryDiagnostic(
                id: other.id,
                name: FloeL10n.l("settings.data_management_view.other_application_data"),
                systemImage: "ellipsis.circle",
                allocatedBytes: other.allocatedBytes,
                logicalBytes: other.logicalBytes,
                fileCount: other.fileCount,
                isSharedEstimate: false
            )
        }

        return StorageDiagnosticReport(
            bundleBytes: report.bundleBytes,
            categories: categories,
            unattributed: unattributed,
            totalAllocatedBytes: report.totalAllocatedBytes,
            totalLogicalBytes: report.totalLogicalBytes,
            isSharedAllocationEstimate: report.isSharedAllocationEstimate,
            scanErrorCount: report.scanErrorCount,
            changedOrVanishedCount: report.changedOrVanishedCount,
            scanDuration: report.scanDuration,
            metricLabel: report.metricLabel,
            generatedAt: report.generatedAt,
            filesScanned: report.filesScanned
        )
    }

    /// Allocated size of the installed app bundle (read-only, shared with the
    /// OS, sparse-aware).
    nonisolated static func bundleAllocatedBytes() -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        let root = Bundle.main.bundleURL
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Registered, explicit cleanup plan. Only Floe-owned regenerable scratch is a
/// candidate; user data and recovery state that live under Caches are
/// registered as *retained* with reasons and are never swept.
enum FloeStorageCleanupRegistry {
    /// Scratch forgotten by one-off components becomes eligible after a day;
    /// anything newer is either still in use or too recent to prove idle.
    static let scratchRetention: TimeInterval = 24 * 60 * 60

    /// Owned scratch directory. Only what Floe itself creates under this
    /// directory (through `FloeScratch.makeDirectory`) is a candidate;
    /// arbitrary tmp content has unknown owners and is never classified as
    /// owned regenerable scratch.
    static func ownedScratchRoot(temporary: URL = FloeStorageLayout.temporaryRoot) -> URL {
        FloeScratch.scratchRoot(temporary: temporary)
    }

    static func plan(
        caches: URL? = FloeStorageLayout.cachesRoot(),
        temporary: URL = FloeStorageLayout.temporaryRoot,
        now: Date = Date()
    ) -> StorageCleanupPlan {
        let cutoff = now.addingTimeInterval(-scratchRetention)
        // One deletable candidate: the dedicated scratch directory that every
        // component's one-off working directories are created in. The whole
        // tmp root is never a candidate; foreign files inside the scratch
        // directory are retained by the name-prefix guard.
        let scratchCandidate = StorageCleanupCandidate(
            id: "floe.scratch",
            owner: .temporary,
            title: FloeL10n.l("settings.data_management_view.cleanup_scratch_title"),
            purpose: FloeL10n.l("settings.data_management_view.cleanup_scratch_purpose"),
            retentionReason: FloeL10n.l("settings.data_management_view.cleanup_scratch_retention"),
            kind: .staleTemporary,
            root: FloeScratch.scratchRoot(temporary: temporary),
            olderThan: cutoff,
            requiredNamePrefixes: Set(Self.scratchPurposes)
        )
        // Real user state that lives in tmp/caches-adjacent places, registered
        // so the plan shows it with its reason instead of ever sweeping it.
        var retained: [StorageCleanupRetained] = [
            StorageCleanupRetained(
                id: "floe.environmentFallbackRoot",
                owner: .environment,
                title: FloeL10n.l("settings.data_management_view.cleanup_environment_fallback"),
                retentionReason: FloeL10n.l("settings.data_management_view.cleanup_environment_fallback_reason"),
                root: FloeScratch.root(temporary: temporary)
            ),
            StorageCleanupRetained(
                id: "floe.checkpoints",
                owner: .temporary,
                title: FloeL10n.l("settings.data_management_view.cleanup_checkpoints"),
                retentionReason: FloeL10n.l("settings.data_management_view.cleanup_checkpoints_reason"),
                root: temporary.appendingPathComponent("FloeAgent-Checkpoints", isDirectory: true)
            )
        ]
        if let caches {
            retained.append(StorageCleanupRetained(
                id: "floe.cacheContainers",
                owner: .floeCache,
                title: FloeL10n.l("settings.data_management_view.cleanup_cache_containers"),
                retentionReason: FloeL10n.l("settings.data_management_view.cleanup_cache_containers_reason"),
                root: caches
            ))
        }
        return StorageCleanupPlan(
            candidates: [scratchCandidate],
            retained: retained,
            generatedAt: now
        )
    }

    /// Purposes whose scratch directories may be reclaimed. A scratch item
    /// with any other prefix is foreign and retained. Must stay in sync with
    /// the `purpose` argument of every `FloeScratch.makeDirectory` call site.
    static let scratchPurposes: [String] = [
        "task", "workspace", "skills", "conversion", "office", "notes", "media", "misc"
    ]
}
#endif
