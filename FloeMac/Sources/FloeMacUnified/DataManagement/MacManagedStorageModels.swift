// SPDX-License-Identifier: MPL-2.0

import Foundation
import FloeCore

// FloeMacUnified — Mac data management models.
//
// Bounded, Floe-owned-only view of what this app keeps on disk. The host
// injects the real roots (construct-and-pass); nothing here walks user
// libraries beyond the registered roots. Measurement reuses the shared
// `StorageCensus` in FloeCore (sparse-aware, identity-deduplicated,
// symlink-fail-safe), so the byte totals are the same honest numbers the
// iPad data-management page shows. Categories that hold databases, current
// tasks, credentials, live jobs or rollback artifacts are inspect/reveal
// only; the only deletable bytes come from the explicit cleanup plan in
// `MacManagedStorageCleanupRegistry`, executed by the FloeCore
// ownership-aware cleanup engine with an injected, fail-closed authority.

enum MacManagedStorageText {
    static func t(_ chinese: String, _ english: String) -> String {
        if let language = Locale.current.language.languageCode?.identifier,
           language == "zh" { return chinese }
        return english
    }
}

/// What a category holds; drives iconography and which actions apply.
enum MacManagedStorageCategoryKind: String, Sendable {
    /// Ordinary app data (drafts, generated media, browser records, …).
    case store
    /// The agent database file — inspect/reveal only, never deletable.
    case database
    /// Rebuildable caches — inspect/reveal only; children become deletable
    /// only when explicitly registered as cleanup candidates.
    case cache
    /// One-off component scratch — the regenerable cleanup target.
    case scratch
    /// WebKit website data (incl. remembered-site jars) — inspect/reveal
    /// only here; deletion flows through the SiteData surface so per-site
    /// jars and their registry stay consistent.
    case websiteData
}

/// The static description of one category row.
struct MacManagedStorageCategoryDescriptor: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let kind: MacManagedStorageCategoryKind
    /// Registered census root (nil when the category is measured another
    /// way, e.g. the database file row).
    let root: URL?
    /// True when the Finder can be opened at this category's location.
    let isRevealable: Bool

    init(
        id: String,
        title: String,
        systemImage: String,
        kind: MacManagedStorageCategoryKind,
        root: URL? = nil,
        isRevealable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.root = root
        self.isRevealable = isRevealable
    }
}

/// One scanned category row. Byte figures are host-allocated (sparse-aware)
/// unless labelled otherwise; `isPartial` rows come from a scan that had
/// measurement gaps and must be presented as estimates.
struct MacManagedStorageCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let kind: MacManagedStorageCategoryKind
    let root: URL?
    let isRevealable: Bool
    let exists: Bool
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int

    var isEmpty: Bool { !exists || (allocatedBytes == 0 && fileCount == 0) }
}

/// Result of one bounded scan. Carries category/count/size/error metrics
/// only — never file names, paths or contents (paths stay in the injected
/// descriptor set inside the process).
struct MacManagedStorageScanReport: Sendable {
    var categories: [MacManagedStorageCategory]
    /// Files counted but not attributed to any registered category.
    var other: MacManagedStorageCategory?
    var totalAllocatedBytes: Int64
    var totalLogicalBytes: Int64
    var fileCount: Int
    var symbolicLinkCount: Int
    var scanErrorCount: Int
    var isPartial: Bool
    var generatedAt: Date
    var duration: TimeInterval
}

/// The host-injected storage roots. Every scan/cleanup path is bounded by
/// these URLs; the backstop validator refuses any root that does not live
/// under one of `allowedBases`.
struct MacManagedStorageRoots: Sendable {
    /// The host's managed directory ("Floe Mac Agent"): database, drafts,
    /// images, videos, canvases, browser records, workbench tools, catalogs.
    var managed: URL?
    /// Runtime artifacts root (`Application Support/FloeAgent`).
    var runtime: URL?
    /// App caches root (`Library/Caches/<bundle id>`).
    var caches: URL?
    /// WebKit website-data root (`Library/WebKit/<bundle id>`).
    var webKit: URL?
    /// Scratch parent (`tmp/FloeAgent`).
    var scratch: URL?
    /// System temporary root used to locate the owned scratch directory.
    var temporary: URL
    /// Safety backstop: every non-nil root above must live under one of
    /// these bases (e.g. the user's Library/Application Support, Library/
    /// Caches, the temp root). Tests inject a fixture base.
    var allowedBases: [URL]

    /// Real roots for the running app. The host may replace any field.
    static func standard(bundleIdentifier: String) -> MacManagedStorageRoots {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let temporary = manager.temporaryDirectory
        let managedName = bundleIdentifier == "org.floeagent.macbridge"
            ? "Floe Mac Agent"
            : "Floe Mac Agent Development"
        var bases = Set<URL>()
        if let support { bases.insert(support.standardizedFileURL) }
        if let library { bases.insert(library.standardizedFileURL) }
        bases.insert(temporary.standardizedFileURL)
        return MacManagedStorageRoots(
            managed: support?.appendingPathComponent(managedName, isDirectory: true),
            runtime: support?.appendingPathComponent("FloeAgent", isDirectory: true),
            caches: library?.appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true),
            webKit: library?.appendingPathComponent("WebKit", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true),
            scratch: FloeScratch.scratchRoot(temporary: temporary),
            temporary: temporary,
            allowedBases: Array(bases)
        )
    }

    /// The category descriptors these roots describe. Children of `managed`
    /// are attributed by deepest match inside the managed walk; everything
    /// else under `managed` is reported as "other".
    func categoryDescriptors() -> [MacManagedStorageCategoryDescriptor] {
        func child(_ id: String, _ name: String, _ image: String, _ kind: MacManagedStorageCategoryKind, _ path: String) -> MacManagedStorageCategoryDescriptor {
            MacManagedStorageCategoryDescriptor(
                id: id, title: name, systemImage: image, kind: kind,
                root: managed?.appendingPathComponent(path, isDirectory: true)
            )
        }
        let database = managed?.appendingPathComponent("floe.sqlite")
        return [
            MacManagedStorageCategoryDescriptor(
                id: "database", title: MacManagedStorageText.t("任务数据库", "Task database"),
                systemImage: "cylinder", kind: .database, root: database
            ),
            child("drafts", MacManagedStorageText.t("草稿与附件", "Drafts and attachments"), "doc.text", .store, "Drafts"),
            child("images", MacManagedStorageText.t("生成的图片", "Generated images"), "photo.on.rectangle", .store, "Images"),
            child("videos", MacManagedStorageText.t("生成的视频", "Generated videos"), "film", .store, "Videos"),
            child("canvases", MacManagedStorageText.t("画布", "Canvases"), "canvas", .store, "Canvases"),
            child("browser", MacManagedStorageText.t("浏览器记录", "Browser records"), "globe", .store, "Browser"),
            child("workbenchTools", MacManagedStorageText.t("工作台工具", "Workbench tools"), "wrench.and.screwdriver", .store, "WorkbenchTools"),
            child("providerCatalogs", MacManagedStorageText.t("供应商目录", "Provider catalogs"), "list.bullet.rectangle", .store, "ProviderCatalogs"),
            child("localModels", MacManagedStorageText.t("本地模型", "On-device models"), "cpu", .store, "LocalModels"),
            child("deviceSync", MacManagedStorageText.t("设备同步", "Device sync"), "arrow.triangle.2.circlepath", .store, "DeviceSync"),
            MacManagedStorageCategoryDescriptor(
                id: "runtime", title: MacManagedStorageText.t("运行时数据", "Runtime data"),
                systemImage: "shippingbox.and.arrow.backward", kind: .store, root: runtime
            ),
            MacManagedStorageCategoryDescriptor(
                id: "caches", title: MacManagedStorageText.t("缓存", "Caches"),
                systemImage: "internaldrive", kind: .cache, root: caches
            ),
            MacManagedStorageCategoryDescriptor(
                id: "webKit", title: MacManagedStorageText.t("网站数据（WebKit）", "Website data (WebKit)"),
                systemImage: "globe.badge.chevron.backward", kind: .websiteData, root: webKit
            ),
            MacManagedStorageCategoryDescriptor(
                id: "scratch", title: MacManagedStorageText.t("临时工作目录", "Temporary work directories"),
                systemImage: "clock.arrow.circlepath", kind: .scratch, root: scratch
            ),
        ]
    }
}

/// Backstop for injected roots: a root is only ever scanned when it sits
/// strictly inside one of the allowed bases. Both sides are canonicalized
/// (`standardizedFileURL` + `resolvingSymlinksInPath`) so a spelling like
/// `/var/tmp/…` cannot escape a `/private/var` base and a legitimate
/// scratch path spelled through `/var` is not excluded. This is defense in
/// depth on top of the bounded descriptor set — it can never widen the
/// walk, only narrow it (a rejected root reports an empty,
/// non-revealable row).
enum MacManagedStorageRootPolicy {
    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isAllowed(_ root: URL?, bases: [URL]) -> Bool {
        guard let root else { return false }
        let path = canonicalPath(root)
        guard path != "/", path != NSHomeDirectory() else { return false }
        return bases.contains { base in
            let basePath = canonicalPath(base)
            // Strict inside: the base itself is never a valid root.
            return path != basePath && path.hasPrefix(basePath + "/")
        }
    }
}

/// Explicit, registered cleanup plan for the Mac. Only owned regenerable
/// scratch is a deletion candidate; every real store (database, drafts,
/// media, runtime, caches root, WebKit data, temp root) is registered as
/// retained with its reason so the UI shows it instead of ever sweeping it.
/// Mirrored on the iPad `FloeStorageCleanupRegistry` semantics.
enum MacManagedStorageCleanupRegistry {
    /// Scratch forgotten by one-off components becomes eligible after a day;
    /// anything newer is either still in use or too recent to prove idle.
    static let scratchRetention: TimeInterval = 24 * 60 * 60

    /// Purposes whose scratch directories may be reclaimed. A scratch item
    /// with any other prefix is foreign and retained. Keep in sync with the
    /// `purpose` argument of every `FloeScratch.makeDirectory` /
    /// `StorageCleanupLeaseCenter.makeLeasedScratch` call site.
    static let scratchPurposes: Set<String> = [
        "task", "workspace", "skills", "conversion", "office", "notes", "media", "misc"
    ]

    static func plan(roots: MacManagedStorageRoots, now: Date = Date()) -> StorageCleanupPlan {
        let cutoff = now.addingTimeInterval(-scratchRetention)
        let scratchCandidate = StorageCleanupCandidate(
            id: "floe.scratch",
            owner: .temporary,
            title: MacManagedStorageText.t("临时工作目录", "Temporary work directories"),
            purpose: MacManagedStorageText.t(
                "各组件一次性工作目录（转换、 office 预览、媒体暂存等），长时间未使用后安全。",
                "One-off component working directories (conversion, office previews, media staging, …); safe once long unused."
            ),
            retentionReason: MacManagedStorageText.t(
                "最近一天内或仍在使用的目录会被保留。",
                "Directories used or modified within the last day are kept."
            ),
            kind: .staleTemporary,
            root: FloeScratch.scratchRoot(temporary: roots.temporary),
            olderThan: cutoff,
            requiredNamePrefixes: scratchPurposes
        )
        var retained: [StorageCleanupRetained] = [
            StorageCleanupRetained(
                id: "floe.managedRoot",
                owner: .temporary,
                title: MacManagedStorageText.t("应用数据", "App data"),
                retentionReason: MacManagedStorageText.t(
                    "包含任务数据库、草稿与当前工作内容，绝不自动删除。",
                    "Contains the task database, drafts and current work; never auto-deleted."
                ),
                root: roots.managed ?? URL(fileURLWithPath: "/")
            ),
            StorageCleanupRetained(
                id: "floe.runtimeRoot",
                owner: .environment,
                title: MacManagedStorageText.t("运行时数据", "Runtime data"),
                retentionReason: MacManagedStorageText.t(
                    "运行环境与回滚所需，绝不自动删除。",
                    "Required by the runtime and for rollback; never auto-deleted."
                ),
                root: roots.runtime ?? URL(fileURLWithPath: "/")
            ),
            StorageCleanupRetained(
                id: "floe.cacheRoot",
                owner: .floeCache,
                title: MacManagedStorageText.t("缓存", "Caches"),
                retentionReason: MacManagedStorageText.t(
                    "缓存根目录中可能包含正在进行的任务数据；只通过明确登记的候选项清理。",
                    "The caches root may hold in-progress task data; only explicitly registered candidates are cleaned."
                ),
                root: roots.caches ?? URL(fileURLWithPath: "/")
            ),
            StorageCleanupRetained(
                id: "floe.webKitRoot",
                owner: .floeCache,
                title: MacManagedStorageText.t("网站数据", "Website data"),
                retentionReason: MacManagedStorageText.t(
                    "通过“网站数据”设置按站点清理。",
                    "Cleared per site from the Website data settings."
                ),
                root: roots.webKit ?? URL(fileURLWithPath: "/")
            ),
        ]
        retained.removeAll { $0.root.path == "/" }
        return StorageCleanupPlan(
            candidates: [scratchCandidate],
            retained: retained,
            generatedAt: now
        )
    }
}
