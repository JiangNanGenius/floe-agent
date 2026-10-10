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
    @Published private(set) var scanProgress: Double?
    @Published private(set) var wasCancelled = false

    private var currentTask: Task<StorageDiagnosticReport?, Never>?

    func cancel() {
        currentTask?.cancel()
    }

    @discardableResult
    func scan() async -> StorageDiagnosticReport? {
        guard !isScanning else { return report }
        isScanning = true
        wasCancelled = false
        scanProgress = nil
        defer {
            isScanning = false
            scanProgress = nil
        }

        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                scanProgress = (scanProgress ?? 0) + 0.06
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        let task = Task.detached(priority: .utility) { () -> StorageDiagnosticReport? in
            let census = StorageCensus(
                roots: Self.roots(),
                parentURL: Self.parentRoot(),
                metricLabel: "storage.data_management.v2"
            ) {
                Task.isCancelled
            }
            do {
                let result = try census.run()
                return Self.makeReport(from: result)
            } catch StorageCensusError.cancelled {
                return nil
            } catch {
                return nil
            }
        }
        currentTask = task
        let result = await task.value
        heartbeat.cancel()
        if Task.isCancelled || result == nil { wasCancelled = result == nil }
        if let result { report = result }
        return result
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
            "library": (FloeL10n.l("settings.data_management_view.system_library_data"), "books.vertical"),
            "documents": (FloeL10n.l("settings.data_management_view.documents"), "doc")
        ]

        // Pure arithmetic lives in FloeCore and is unit-tested; each bucket is
        // counted exactly once there (caches/tmp are in the total but not listed
        // as user-data categories).
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
            metricLabel: report.metricLabel
        )
    }
}

/// Registered, explicit cleanup plan. Only Floe-owned regenerable scratch is a
/// candidate; user data and recovery state that live under Caches are
/// registered as *retained* with reasons and are never swept.
enum FloeStorageCleanupRegistry {
    /// Owned scratch directory. Only what Floe itself creates under this
    /// directory is a candidate; arbitrary tmp content has unknown owners and is
    /// never classified as owned regenerable scratch.
    static func ownedScratchRoot(temporary: URL = FloeStorageLayout.temporaryRoot) -> URL {
        temporary.appendingPathComponent("FloeAgent", isDirectory: true)
    }

    static func plan(
        caches: URL? = FloeStorageLayout.cachesRoot(),
        temporary: URL = FloeStorageLayout.temporaryRoot,
        now: Date = Date()
    ) -> StorageCleanupPlan {
        var candidates: [StorageCleanupCandidate] = []
        var retained: [StorageCleanupRetained] = []

        // Only Floe's own scratch subdirectory, older than one hour, with the
        // owner probe required to prove idle. If the directory does not exist
        // the plan is effectively empty.
        candidates.append(
            StorageCleanupCandidate(
                id: "floeScratch",
                owner: .temporary,
                title: FloeL10n.l("settings.data_management_view.floe_scratch_files"),
                purpose: FloeL10n.l("settings.data_management_view.finished_scratch_left_in_temporary"),
                retentionReason: FloeL10n.l("settings.data_management_view.recent_and_active_scratch_is_kept"),
                kind: .staleTemporary,
                root: ownedScratchRoot(temporary: temporary),
                olderThan: now.addingTimeInterval(-3_600)
            )
        )

        if let caches {
            let floeCaches = caches.appendingPathComponent("FloeAgent", isDirectory: true)
            retained.append(StorageCleanupRetained(
                id: "promptLibrary",
                owner: .floeCache,
                title: FloeL10n.l("settings.data_management_view.prompt_library"),
                retentionReason: FloeL10n.l("settings.data_management_view.prompt_library_retention"),
                root: floeCaches.appendingPathComponent("PromptLibrary", isDirectory: true)
            ))
            retained.append(StorageCleanupRetained(
                id: "diagnosticsLog",
                owner: .floeCache,
                title: FloeL10n.l("settings.data_management_view.diagnostics_log"),
                retentionReason: FloeL10n.l("settings.data_management_view.diagnostics_log_retention"),
                root: floeCaches.appendingPathComponent("diagnostics-log.json")
            ))
            retained.append(StorageCleanupRetained(
                id: "pdfOperationJournal",
                owner: .floeCache,
                title: FloeL10n.l("settings.data_management_view.pdf_operation_journal"),
                retentionReason: FloeL10n.l("settings.data_management_view.pdf_journal_retention"),
                root: floeCaches.appendingPathComponent("pdf-operation-journal.jsonl")
            ))
        }
        return StorageCleanupPlan(candidates: candidates, retained: retained, generatedAt: now)
    }
}
#endif
