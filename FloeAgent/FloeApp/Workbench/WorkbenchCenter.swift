// FloeApp — Unified media workbench center.
//
// Owns the durable project (MediaProjectStore), the trusted proposal grant
// store, the renderers and the AI candidate/job state for the surfaces that
// present the workbench (Files, workspace preview, Canvas, chat previews).
// Also implements MediaProjectHost so the `media.project` tool goes through
// exactly the same validated transaction engine as the UI.

import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import FloeCore
import FloeMedia
import FloeTools
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Bilingual text

/// EN / zh-CN aligned strings for the workbench. Mirrors the established
/// `OfficeInkText.t` pattern used by other newer app surfaces.
enum WorkbenchText {
    static var isChinese: Bool {
        Locale.current.identifier.hasPrefix("zh")
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

// MARK: - Paths

/// Thread-safe holder for the active project's recorded media root. The video
/// renderer is an actor whose root closure executes off the main actor; a lock
/// box keeps resolution tied to the project owner instead of whatever
/// workspace happens to be open now.
final class ProjectRootBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?

    func set(_ url: URL?) {
        lock.lock()
        value = url
        lock.unlock()
    }

    func get() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Media root used by the workbench. Preference order: the active workspace
/// root, then an app-owned sandbox directory (standalone/chat/Canvas projects
/// that do not live inside a user workspace).
enum WorkbenchPaths {
    static func fallbackRoot() -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("FloeAgent/WorkbenchRoot", isDirectory: true)
    }

    static func mediaRoot(preferred: URL?) -> URL {
        preferred ?? fallbackRoot()
    }

    /// Root for an EXISTING project: its recorded workspace wins over the
    /// currently open workspace so switching workspaces cannot silently
    /// re-point preview/export at the wrong files. A project without a
    /// recorded workspace is app-owned (standalone).
    static func mediaRoot(for project: MediaProject?, current: URL?) -> URL {
        if let recorded = project?.taskWorkspacePath, !recorded.isEmpty {
            return URL(fileURLWithPath: recorded).resolvingSymlinksInPath().standardizedFileURL
        }
        if project != nil { return fallbackRoot() }
        return mediaRoot(preferred: current)
    }
}

// MARK: - Center

@MainActor
final class WorkbenchCenter: ObservableObject {
    enum OwnerKind: String {
        case files
        case workspace
        case canvas
        case chat
        case standalone
    }

    struct Owner {
        var kind: OwnerKind
        var id: UUID?
        var environmentID: String?

        static let standalone = Owner(kind: .standalone, id: nil, environmentID: nil)
    }

    struct Alert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// A verified, user-deliverable export. Only the center's own export
    /// paths construct one, after the renderer re-read/verified the file and
    /// committed it atomically. `attemptID` invalidates results superseded by
    /// a newer attempt (late callbacks, cancellation races).
    struct VerifiedExport: Identifiable, Hashable {
        let id = UUID()
        let attemptID: UUID
        let url: URL
        let kind: MediaProjectKind
        let detail: String
    }

    struct Candidate: Identifiable, Hashable {
        var id: UUID
        var url: URL
        var kind: MediaAssetKind
        var modelName: String
        var parametersSummary: String
        var createdAt: Date
    }

    enum Drawer: String, Identifiable {
        case assets, properties, ai, export
        var id: String { rawValue }
    }

    // Published state
    @Published private(set) var project: MediaProject? {
        didSet { projectRootBox.set(project?.taskWorkspacePath.map { URL(fileURLWithPath: $0) }) }
    }
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var sourcePreviewImage: CGImage?
    @Published private(set) var playerItem: AVPlayerItem?
    /// Actionable preview failure (renderer threw or produced nothing) so a
    /// blank surface is never silent.
    @Published private(set) var previewError: String?
    /// True while the video preview proxy is being (re)rendered.
    @Published private(set) var isRenderingPreview = false
    @Published private(set) var thumbnails: [UUID: [WorkbenchThumbnail]] = [:]
    @Published private(set) var pendingProposals: [MediaProposal] = []
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var aiJobs: [WorkbenchAIJobInfo] = []
    @Published private(set) var projectSummaries: [MediaProjectStore.ProjectSummary] = []
    /// Durable, per-project image request status records (submitted /
    /// interrupted / unknown / failed). Image generation has no provider
    /// job ID to poll, so a dropped call can never be safely retried.
    @Published private(set) var imageRequests: [WorkbenchImageRequestStore.Record] = []
    @Published private(set) var busy = false
    @Published private(set) var exportProgress: Double?
    /// Informational export/save note. A verified, user-deliverable result is
    /// `lastExportResult`; this message alone is never treated as success.
    @Published private(set) var lastExportMessage: String?
    /// The latest VERIFIED export, retained until a newer attempt starts or
    /// the project changes. Failure/cancellation sets this to nil before any
    /// notice is shown, so a stale success can never be shared or called back.
    @Published private(set) var lastExportResult: VerifiedExport?
    @Published var alert: Alert?
    @Published var drawer: Drawer?
    @Published var isFullscreenPreview = false
    @Published var showsProjectLibrary = false
    @Published var compareWithSource = false
    @Published var aiAvailable = true
    @Published var aiReview: AIReviewRequest?
    @Published var aiModelUnavailableReason: String?
    // Shared editing-session UI state (kept in the center so fullscreen and
    // panel collapse never reset the selection or playhead).
    @Published var selectedLayerID: UUID?
    @Published var selectedClipID: UUID?
    @Published var playheadSeconds: Double = 0
    @Published var pixelsPerSecond: Double = 60
    @Published var isDrawingFreehand = false
    @Published var isCropping = false
    @Published var cropRect: NormalizedRect?

    /// Pre-submission review. The payload is typed and immutable so the
    /// confirmed submission always equals what the sheet displayed: image
    /// edits keep their exact source asset + size + count, video jobs keep
    /// their exact duration/aspect/resolution (previously these were rebuilt
    /// as nil and silently degraded generation to plain text-to-image/video).
    struct AIReviewRequest: Identifiable {
        enum Payload: Hashable {
            case image(size: String?, count: Int, sourceAssetID: UUID?)
            case video(options: WorkbenchVideoAIOptions)
        }

        var id = UUID()
        var kind: MediaAssetKind
        var prompt: String
        var modelID: UUID
        var modelName: String
        var payload: Payload
        var assetNames: [String]
        var parameters: [String: String]
        var costNote: String
    }

    // Dependencies
    private let store: MediaProjectStore
    private let candidateStore: WorkbenchCandidateStore
    private let imageRequestStore: WorkbenchImageRequestStore
    private let projectRootBox = ProjectRootBox()
    private let grantStore = MediaProposalGrantStore()
    private let proposalStore = MediaProposalDraftStore()
    private let imageRenderer = WorkbenchImageRenderer()
    private let videoRenderer: WorkbenchVideoRenderer
    private let rootProvider: @Sendable () -> URL?
    private let bridge: WorkbenchAIBridge
    /// One player for the whole editing session: fullscreen/rotation/panel
    /// changes must not recreate the AVPlayer or lose the playhead.
    let playerModel = WorkbenchPlayerModel()
    /// When true the agent tool may not apply a proposal without a UI grant.
    /// Entrance callback invoked exactly once for the first verified export
    /// after registration (canvas attaches the edited video). Re-registered
    /// per workbench presentation; a failed/cancelled export never fires it.
    private var exportEntranceCallback: ((URL) -> Void)?
    private var exportEntranceCallbackPending = false
    private var exportCancellation: CancellationToken?
    private var currentExportAttemptID: UUID?
    private var previewRecoveryAttempts = 0
    private var previewRenderCancellation: CancellationToken?
    private var lastPreviewURL: URL?
    private var previewTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// Jobs the user chose to stop waiting on (local-only; no remote cancel).
    private var stoppedWaitingJobs: Set<UUID> = []
    /// Review request ids already submitted in this center's lifetime: a
    /// single confirmed review may never be submitted twice, even if the
    /// sheet action fires again. Video jobs are deduplicated here too.
    private var confirmedReviewRequestIDs: Set<UUID> = []

    init(rootProvider: @escaping @Sendable () -> URL?,
         bridge: WorkbenchAIBridge) {
        self.rootProvider = rootProvider
        self.bridge = bridge
        // The renderer resolves assets against the ACTIVE project's recorded
        // root; the current workspace is only the fallback while no project
        // is open (new imports). Switching workspaces never re-points an
        // existing project at the wrong files.
        let fallbackRoot = rootProvider
        let rootBox = projectRootBox
        self.videoRenderer = WorkbenchVideoRenderer(rootProvider: {
            if let recorded = rootBox.get() { return recorded }
            return WorkbenchPaths.mediaRoot(preferred: fallbackRoot())
        })
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeAgent/MediaProjects", isDirectory: true)
        self.store = MediaProjectStore(directory: directory)
        self.candidateStore = WorkbenchCandidateStore(
            directory: directory.appendingPathComponent("Candidates", isDirectory: true))
        self.imageRequestStore = WorkbenchImageRequestStore(
            directory: directory.appendingPathComponent("ImageRequests", isDirectory: true))
        playerModel.onTimeChange = { [weak self] seconds in
            self?.playheadSeconds = seconds
        }
        playerModel.onItemFailed = { [weak self] message in
            self?.recoverPreview(after: message)
        }
        playerModel.onItemReady = { [weak self] in
            self?.previewRecoveryAttempts = 0
            self?.previewError = nil
        }
    }

    /// A preview item that fails to prepare leaves a black surface with an
    /// inert play button, and a player whose first item failed can stay
    /// poisoned. Rebuild both, bounded, before surfacing an actionable error.
    private func recoverPreview(after message: String) {
        guard project?.kind == .video else { return }
        if previewRecoveryAttempts >= 3 {
            previewError = WorkbenchText.t(
                "视频预览无法播放：\(message)",
                "Video preview cannot play: \(message)")
            return
        }
        previewRecoveryAttempts += 1
        let attempt = previewRecoveryAttempts
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300 * attempt))
            guard let self else { return }
            self.playerModel.recreatePlayer()
            self.refreshPreview()
        }
    }

    // MARK: - Project lifecycle

    func startImageProject(sourceURL: URL, owner: Owner) async {
        clearExportDelivery()
        await runBusy {
            let asset = try await importAsset(url: sourceURL)
            let probe = try await self.imageRenderer.probe(url: sourceURL)
            // Resource guard: oversized sources never force a full decode. The
            // project becomes a scaled working copy (aspect preserved) and the
            // user is told, instead of crashing or exporting at an invalid size.
            let canvas: MediaCanvas
            var guardWarning: String?
            switch MediaResourceGuard.evaluateImage(width: probe.pixelWidth, height: probe.pixelHeight) {
            case .offerScaledCopy(let maxEdge):
                let scale = Double(maxEdge) / Double(max(probe.pixelWidth, probe.pixelHeight))
                canvas = MediaCanvas(width: MediaResourceGuard.even(Int(Double(probe.pixelWidth) * scale)),
                                     height: MediaResourceGuard.even(Int(Double(probe.pixelHeight) * scale)))
                guardWarning = WorkbenchText.t(
                    "图片尺寸 \(probe.pixelWidth)×\(probe.pixelHeight) 超过编辑上限，已创建最长边 \(maxEdge) 像素的缩放工作副本；导出将按该尺寸输出。",
                    "The source is \(probe.pixelWidth)×\(probe.pixelHeight), above the editing budget; a scaled working copy with a \(maxEdge)px longest edge was created and export follows that size.")
            default:
                canvas = MediaCanvas(width: probe.pixelWidth, height: probe.pixelHeight)
            }
            var project = MediaProject(kind: .image, name: sourceURL.deletingPathExtension().lastPathComponent,
                                       canvas: canvas)
            if let guardWarning { project.recoveryWarnings.append(guardWarning) }
            project.ownerKind = owner.kind.rawValue
            project.ownerID = owner.id
            project.environmentID = owner.environmentID
            project.taskWorkspacePath = self.rootProvider()?.path
            try MediaTransactions.apply(.addAsset(asset), to: &project)
            let layer = ImageLayer(kind: .image, name: WorkbenchText.t("底图", "Base image"), assetID: asset.id)
            try MediaTransactions.apply(.addImageLayer(layer), to: &project)
            try await self.store.save(project)
            self.project = project
            self.candidates = []
            self.refreshPreview()
        }
    }

    func startVideoProject(clipURLs: [URL], musicURL: URL?, owner: Owner) async {
        clearExportDelivery()
        await runBusy {
            guard !clipURLs.isEmpty else {
                throw FloeError.validationFailed(WorkbenchText.t("请选择至少一个视频片段。", "Choose at least one video clip."))
            }
            // A legacy single-asset parameter project for this exact file is
            // migrated instead of starting from scratch; unknown operations
            // are preserved and reported.
            if musicURL == nil, clipURLs.count == 1,
               let migrated = await self.migratedLegacyProject(from: clipURLs[0], owner: owner) {
                try await self.store.save(migrated)
                self.project = migrated
                self.refreshPreview()
                self.refreshThumbnails()
                return
            }
            var project = MediaProject(kind: .video, name: clipURLs[0].deletingPathExtension().lastPathComponent)
            project.ownerKind = owner.kind.rawValue
            project.ownerID = owner.id
            project.environmentID = owner.environmentID
            project.taskWorkspacePath = self.rootProvider()?.path
            var firstSize: CGSize?
            var firstFPS: Double?
            for url in clipURLs {
                let asset = try await self.importAsset(url: url)
                let metadata = try await self.videoRenderer.inspect(assetPath: asset.relativePath)
                try MediaTransactions.apply(.addAsset(asset), to: &project)
                let duration = metadata.durationSeconds ?? 0
                let clip = VideoClip(assetID: asset.id, trimStart: 0, trimEnd: duration)
                if duration <= 0 {
                    throw FloeError.validationFailed(WorkbenchText.t(
                        "\(url.lastPathComponent) 缺少可用的视频轨道时长。",
                        "\(url.lastPathComponent) has no readable duration."))
                }
                try MediaTransactions.apply(.appendClip(clip), to: &project)
                if firstSize == nil {
                    firstSize = CGSize(width: metadata.width ?? 0, height: metadata.height ?? 0)
                    firstFPS = metadata.frameRate
                }
            }
            let probedWidth = firstSize?.width ?? 0
            let probedHeight = firstSize?.height ?? 0
            let width = probedWidth >= 2 ? MediaResourceGuard.even(Int(probedWidth)) : 1280
            let height = probedHeight >= 2 ? MediaResourceGuard.even(Int(probedHeight)) : 720
            let fps = (firstFPS ?? 0) > 0 ? (firstFPS ?? 30) : 30
            try MediaTransactions.apply(.setCanvas(width: max(2, width), height: max(2, height),
                                                   frameRate: min(max(fps, 1), 120)), to: &project)
            if let musicURL {
                let asset = try await self.importAsset(url: musicURL)
                try MediaTransactions.apply(.addAsset(asset), to: &project)
                let duration = await self.audioDuration(url: musicURL)
                guard duration > 0.05 else {
                    throw FloeError.validationFailed(WorkbenchText.t(
                        "\(musicURL.lastPathComponent) 缺少可读的音频时长。",
                        "\(musicURL.lastPathComponent) has no readable audio duration."))
                }
                try MediaTransactions.apply(.addMusic(MusicClip(assetID: asset.id, offsetSeconds: 0,
                                                                trimStart: 0,
                                                                lengthSeconds: min(duration, 3600))),
                                            to: &project)
            }
            try await self.store.save(project)
            self.project = project
            self.candidates = []
            self.previewRecoveryAttempts = 0
            self.refreshPreview()
            self.refreshThumbnails()
        }
    }

    func openProject(id: UUID) async {
        await runBusy {
            guard let loaded = try await self.store.loadProject(id: id) else {
                throw FloeError.notFound("project \(id.uuidString)")
            }
            // A verified result belongs to the previously open project; never
            // surface or share it after switching projects.
            self.exportCancellation?.cancel()
            self.exportCancellation = nil
            self.currentExportAttemptID = nil
            self.exportProgress = nil
            self.lastExportMessage = nil
            self.lastExportResult = nil
            self.project = loaded
            self.candidates = await self.candidateStore.load(projectID: id)
            self.imageRequests = self.imageRequestStore.load(projectID: id)
            self.confirmedReviewRequestIDs = Set(self.imageRequests.map(\.id))
            self.previewRecoveryAttempts = 0
            self.refreshPreview()
            self.refreshThumbnails()
            await self.reloadAISignals()
        }
    }

    /// Flushes the latest draft to disk before tearing the session down; a
    /// close/switch must never cancel an in-flight save and lose edits.
    func closeProject() async {
        await saveNow()
        previewTask?.cancel()
        saveTask?.cancel()
        thumbnailTask?.cancel()
        previewRenderCancellation?.cancel()
        previewRenderCancellation = nil
        exportCancellation?.cancel()
        exportCancellation = nil
        exportEntranceCallback = nil
        exportEntranceCallbackPending = false
        clearExportDelivery()
        isRenderingPreview = false
        if let lastPreviewURL {
            try? FileManager.default.removeItem(at: lastPreviewURL)
        }
        lastPreviewURL = nil
        playerModel.setItem(nil)
        project = nil
        previewImage = nil
        playerItem = nil
        previewError = nil
        previewRecoveryAttempts = 0
        pendingProposals = []
        candidates = []
        imageRequests = []
        aiJobs = []
        confirmedReviewRequestIDs = []
    }

    /// Persisted fork used by canvas "make variant" and by copies of bound
    /// nodes. The fork gets a new identity, parent linkage and fresh history;
    /// asset bytes stay shared by reference.
    func forkProjectForVariant(parentID: UUID) async -> (id: UUID, revision: Int64)? {
        do {
            let fork = try await store.forkProject(
                id: parentID,
                nameSuffix: WorkbenchText.t("分支", "variant"))
            return (fork.id, fork.revision)
        } catch {
            present(error)
            return nil
        }
    }

    func refreshProjectSummaries() async {
        projectSummaries = (try? await store.listProjects()) ?? []
    }

    /// Saved projects visible from the current editing context: same owner
    /// kind, and — when recorded — the same environment, owner id and
    /// workspace. The reopen entry must never offer a project the user cannot
    /// legitimately open from here.
    func savedProjectsForCurrentContext() async -> [MediaProjectStore.ProjectSummary] {
        await refreshProjectSummaries()
        guard let project else { return projectSummaries }
        return projectSummaries.filter { summary in
            guard summary.ownerKind == project.ownerKind else { return false }
            if let environment = project.environmentID, summary.environmentID != environment { return false }
            if let owner = project.ownerID, summary.ownerID != owner { return false }
            if let workspace = project.taskWorkspacePath, summary.workspacePath != workspace { return false }
            return true
        }
    }

    /// Finds an existing project created from the same source file and owner,
    /// so reopening a source can offer "resume" instead of silently starting
    /// a fresh project and orphaning the saved edits.
    func findResumableProject(sourceURLs: [URL], kind: MediaProjectKind,
                              owner: Owner) async -> MediaProjectStore.ProjectSummary? {
        guard let target = sourceURLs.first?.lastPathComponent else { return nil }
        let summaries = (try? await store.listProjects()) ?? []
        for summary in summaries where summary.kind == kind && summary.ownerKind == owner.kind.rawValue {
            if let environment = owner.environmentID, summary.environmentID != environment { continue }
            if let ownerID = owner.id, summary.ownerID != ownerID { continue }
            guard let existing = try? await store.loadProject(id: summary.id) else { continue }
            if existing.assets.contains(where: { $0.originalName == target }) {
                return summary
            }
        }
        return nil
    }

    // MARK: - Edits

    @discardableResult
    func apply(_ command: MediaEditCommand) -> Bool {
        guard var current = project else { return false }
        do {
            try MediaTransactions.apply(command, to: &current)
        } catch {
            present(error)
            return false
        }
        project = current
        scheduleSave()
        refreshPreview()
        if case .appendClip = command { refreshThumbnails() }
        if case .removeClip = command { refreshThumbnails() }
        return true
    }

    func undo() {
        guard var current = project, MediaTransactions.undo(&current) else { return }
        project = current
        scheduleSave()
        refreshPreview()
    }

    func redo() {
        guard var current = project, MediaTransactions.redo(&current) else { return }
        project = current
        scheduleSave()
        refreshPreview()
    }

    func canUndo() -> Bool { project.map(MediaTransactions.canUndo) ?? false }
    func canRedo() -> Bool { project.map(MediaTransactions.canRedo) ?? false }

    func addAssetReference(url: URL) async {
        await runBusy {
            guard var current = self.project else { return }
            let asset = try await self.importAsset(url: url)
            try MediaTransactions.apply(.addAsset(asset), to: &current)
            self.project = current
            self.scheduleSave()
        }
    }

    func reorderLayers(to orderedIDs: [UUID]) {
        apply(.reorderLayers(orderedIDs: orderedIDs))
    }

    func importImageLayer(url: URL) async {
        await runBusy {
            guard var current = self.project, current.kind == .image else {
                throw FloeError.validationFailed(WorkbenchText.t("当前不是图片项目。", "The current project is not an image project."))
            }
            let asset = try await self.importAsset(url: url)
            try MediaTransactions.apply(.addAsset(asset), to: &current)
            let layer = ImageLayer(kind: .image, name: url.deletingPathExtension().lastPathComponent,
                                   assetID: asset.id)
            try MediaTransactions.apply(.addImageLayer(layer), to: &current)
            self.project = current
            self.selectedLayerID = layer.id
            self.scheduleSave()
            self.refreshPreview()
        }
    }

    func importVideoClip(url: URL) async {
        await runBusy {
            guard var current = self.project, current.kind == .video else {
                throw FloeError.validationFailed(WorkbenchText.t("当前不是视频项目。", "The current project is not a video project."))
            }
            let asset = try await self.importAsset(url: url)
            let metadata = try await self.videoRenderer.inspect(assetPath: asset.relativePath)
            try MediaTransactions.apply(.addAsset(asset), to: &current)
            let duration = metadata.durationSeconds ?? 0
            guard duration > 0 else {
                throw FloeError.validationFailed(WorkbenchText.t("视频缺少可读时长。", "The video has no readable duration."))
            }
            let clip = VideoClip(assetID: asset.id, trimStart: 0, trimEnd: duration)
            try MediaTransactions.apply(.appendClip(clip), to: &current)
            self.project = current
            self.selectedClipID = clip.id
            self.scheduleSave()
            self.refreshPreview()
            self.refreshThumbnails()
        }
    }

    func importMusic(url: URL) async {
        await runBusy {
            guard var current = self.project, current.kind == .video else { return }
            let asset = try await self.importAsset(url: url)
            try MediaTransactions.apply(.addAsset(asset), to: &current)
            let duration = await self.audioDuration(url: url)
            guard duration > 0.05 else {
                throw FloeError.validationFailed(WorkbenchText.t("音频缺少可读时长。", "The audio has no readable duration."))
            }
            let music = MusicClip(assetID: asset.id, offsetSeconds: 0, trimStart: 0,
                                  lengthSeconds: min(duration, 3600))
            try MediaTransactions.apply(.addMusic(music), to: &current)
            self.project = current
            self.scheduleSave()
        }
    }

    func setCanvas(width: Int, height: Int, frameRate: Double?) {
        apply(.setCanvas(width: max(2, width), height: max(2, height), frameRate: frameRate))
    }

    // MARK: - Preview

    func refreshPreview() {
        guard let project else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            if project.kind == .image {
                let canvas = project.canvas ?? MediaCanvas(width: 1024, height: 1024)
                let previewEdge = max(800, min(MediaResourceGuard.ImageBudget().previewLongestEdge,
                                              max(canvas.width, canvas.height)))
                let urls = self.assetURLMap(for: project)
                do {
                    let rendered = try await self.imageRenderer.render(
                        project: project,
                        canvas: CGSize(width: canvas.width, height: canvas.height),
                        resolveAsset: { urls[$0] },
                        previewMaxEdge: previewEdge)
                    guard !Task.isCancelled else { return }
                    self.previewImage = rendered
                    self.previewError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.previewImage = nil
                    self.previewError = WorkbenchText.t(
                        "图片预览渲染失败：\(error.localizedDescription)",
                        "Image preview failed: \(error.localizedDescription)")
                }
                // Compare reference: the untouched first source layer.
                if let baseLayer = project.imageLayers.first(where: { $0.kind == .image && $0.assetID != nil }) {
                    var sourceOnly = project
                    var clean = baseLayer
                    clean.transform = .init()
                    clean.adjustment = .init()
                    clean.crop = nil
                    // The reference is the true original: no layer effects at
                    // all, including a non-100% opacity base layer.
                    clean.opacity = 1
                    clean.isHidden = false
                    sourceOnly.imageLayers = [clean]
                    sourceOnly.canvasAdjustment = .init()
                    self.sourcePreviewImage = try? await self.imageRenderer.render(
                        project: sourceOnly,
                        canvas: CGSize(width: canvas.width, height: canvas.height),
                        resolveAsset: { urls[$0] },
                        previewMaxEdge: previewEdge)
                } else {
                    self.sourcePreviewImage = nil
                }
            } else {
                let token = CancellationToken()
                self.previewRenderCancellation?.cancel()
                self.previewRenderCancellation = token
                self.isRenderingPreview = true
                do {
                    let receipt = try await self.videoRenderer.renderPreview(project: project,
                                                                            cancellation: token)
                    guard !Task.isCancelled, !token.isCancelled else { return }
                    if self.previewRenderCancellation === token {
                        self.isRenderingPreview = false
                    }
                    let item = AVPlayerItem(url: receipt.url)
                    // Keep the currently playing proxy until the new one is
                    // ready, then delete the stale file.
                    if let previous = self.lastPreviewURL, previous != receipt.url {
                        try? FileManager.default.removeItem(at: previous)
                    }
                    self.lastPreviewURL = receipt.url
                    self.playerItem = item
                    self.previewError = nil
                } catch {
                    // A render superseded by a newer edit is not a failure.
                    if token.isCancelled || Task.isCancelled { return }
                    self.isRenderingPreview = false
                    self.playerItem = nil
                    self.previewError = WorkbenchText.t(
                        "视频预览渲染失败：\(error.localizedDescription)",
                        "Video preview failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshThumbnails() {
        guard let project, project.kind == .video else { return }
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            let thumbs = (try? await self.videoRenderer.thumbnails(project: project, perClip: 3)) ?? []
            guard !Task.isCancelled else { return }
            var grouped: [UUID: [WorkbenchThumbnail]] = [:]
            for thumb in thumbs { grouped[thumb.clipID, default: []].append(thumb) }
            self.thumbnails = grouped
        }
    }

    // MARK: - Assets

    /// Active media root: the open project's recorded workspace when present,
    /// otherwise the current workspace (new imports) or the app-owned root.
    func mediaRoot() -> URL {
        WorkbenchPaths.mediaRoot(for: project, current: rootProvider())
    }

    /// Copies a file that lives outside the media root into
    /// `Workbench/Assets` so the project keeps a stable external reference
    /// with a relative path; files already inside are referenced in place.
    /// Bounded by explicit size guards.
    private func importAsset(url: URL) async throws -> MediaAssetReference {
        let root = mediaRoot()
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let resourceValues = try source.resourceValues(forKeys: [.contentTypeKey])
        let contentType = resourceValues.contentType
        let kind: MediaAssetKind
        // Order matters: UTType.audio conforms to UTType.audiovisualContent,
        // so audio must be classified before the generic audiovisual branch
        // (otherwise a music file becomes a "video" with no video track).
        if contentType?.conforms(to: .image) == true {
            kind = .image
            guard bytes <= 128 * 1024 * 1024 else {
                throw FloeError.validationFailed(WorkbenchText.t("图片超过 128 MiB 上限。", "Image exceeds the 128 MiB limit."))
            }
        } else if contentType?.conforms(to: .audio) == true {
            kind = .audio
            guard bytes <= 1024 * 1024 * 1024 else {
                throw FloeError.validationFailed(WorkbenchText.t("音频超过 1 GiB 上限。", "Audio exceeds the 1 GiB limit."))
            }
        } else if contentType?.conforms(to: .movie) == true
                    || contentType?.conforms(to: .video) == true
                    || contentType?.conforms(to: .audiovisualContent) == true {
            kind = .video
            guard bytes <= 8 * 1024 * 1024 * 1024 else {
                throw FloeError.validationFailed(WorkbenchText.t("视频超过 8 GiB 上限。", "Video exceeds the 8 GiB limit."))
            }
        } else {
            throw FloeError.validationFailed(WorkbenchText.t("不支持的文件类型。", "Unsupported file type."))
        }
        if source.path.hasPrefix(canonicalRoot.path + "/") {
            let relative = String(source.path.dropFirst(canonicalRoot.path.count + 1))
            return MediaAssetReference(kind: kind, relativePath: relative,
                                       originalName: source.lastPathComponent, byteCount: bytes)
        }
        let assetsDir = canonicalRoot.appendingPathComponent("Workbench/Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let safeName = source.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let destination = assetsDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safeName)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return MediaAssetReference(kind: kind, relativePath: "Workbench/Assets/\(destination.lastPathComponent)",
                                   originalName: source.lastPathComponent, byteCount: bytes)
    }

    func resolvedURL(for assetID: UUID) -> URL? {
        guard let project, let asset = project.asset(assetID) else { return nil }
        let canonicalRoot = mediaRoot().resolvingSymlinksInPath().standardizedFileURL
        let url = asset.relativePath.hasPrefix("/")
            ? URL(fileURLWithPath: asset.relativePath)
            : canonicalRoot.appendingPathComponent(asset.relativePath)
        return url.standardizedFileURL
    }

    func isAssetAvailable(_ id: UUID) -> Bool {
        guard let url = resolvedURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Relinks a missing asset: in-root files are referenced in place, other
    /// files are copied into the media root first. Edits are preserved.
    func relinkAsset(_ assetID: UUID, to url: URL) async {
        await runBusy {
            let reference = try await self.importAsset(url: url)
            self.apply(.relinkAsset(assetID: assetID, relativePath: reference.relativePath))
        }
    }

    /// Pure snapshot of asset URLs for renderer closures, which run off the
    /// main actor and must not synchronously reach isolated state. The root
    /// is resolved from the PASSED project, so an in-flight call frozen to
    /// one project keeps resolving its assets after the user opens another.
    func assetURLMap(for project: MediaProject) -> [UUID: URL] {
        let canonicalRoot = WorkbenchPaths
            .mediaRoot(for: project, current: rootProvider())
            .resolvingSymlinksInPath().standardizedFileURL
        var map: [UUID: URL] = [:]
        for asset in project.assets {
            let url = asset.relativePath.hasPrefix("/")
                ? URL(fileURLWithPath: asset.relativePath)
                : canonicalRoot.appendingPathComponent(asset.relativePath)
            map[asset.id] = url.standardizedFileURL
        }
        return map
    }

    /// Migrates `.floe-media-edits/<sha256(path)>.json` (the legacy
    /// single-asset `VideoEditPlan`) into a workbench project. Known trim /
    /// speed / volume / mute parameters are applied; every other operation is
    /// preserved verbatim in `unknownOperations` and reported, never dropped.
    private func migratedLegacyProject(from clipURL: URL, owner: Owner) async -> MediaProject? {
        guard let root = rootProvider() else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let source = clipURL.resolvingSymlinksInPath().standardizedFileURL
        guard source.path.hasPrefix(canonicalRoot.path + "/") else { return nil }
        let relative = String(source.path.dropFirst(canonicalRoot.path.count + 1))
        let directory = canonicalRoot.appendingPathComponent(".floe-media-edits", isDirectory: true)
        var planData: Data?
        for key in [relative, source.path] {
            let candidate = directory.appendingPathComponent(FloeDigest.sha256Hex(Data(key.utf8)) + ".json")
            if let data = try? Data(contentsOf: candidate) {
                planData = data
                break
            }
        }
        guard let planData,
              let json = try? JSONSerialization.jsonObject(with: planData) as? [String: Any] else {
            return nil
        }
        let recordedInput = json["input"] as? String
        guard recordedInput == nil || recordedInput == relative || recordedInput == source.path else {
            return nil
        }
        let metadata = try? await videoRenderer.inspect(assetPath: relative)
        let asset = MediaAssetReference(kind: .video, relativePath: relative,
                                        originalName: source.lastPathComponent,
                                        metadata: metadata)
        var project = MediaProject(kind: .video, name: source.deletingPathExtension().lastPathComponent,
                                   assets: [asset], sourceAssetID: asset.id)
        project.ownerKind = owner.kind.rawValue
        project.ownerID = owner.id
        project.environmentID = owner.environmentID
        project.taskWorkspacePath = root.path
        var trimStart = 0.0
        var trimEnd = metadata?.durationSeconds ?? 0
        var speed = 1.0
        var volume = 1.0
        var muted = false
        var preserved: [UnknownOperation] = []
        let operations = json["operations"] as? [[String: Any]] ?? []
        for operation in operations {
            if let value = operation["trim"] as? [String: Any],
               let start = value["start"] as? Double, let end = value["end"] as? Double {
                trimStart = start
                trimEnd = min(end, metadata?.durationSeconds ?? end)
            } else if let value = operation["speed"] as? [String: Any],
                      let rate = value["rate"] as? Double {
                speed = rate
            } else if let value = operation["volume"] as? [String: Any],
                      let level = value["level"] as? Double {
                volume = level
            } else if operation["mute"] != nil {
                muted = true
            } else if let name = operation.keys.first {
                if let payload = try? JSONSerialization.data(withJSONObject: operation) {
                    preserved.append(UnknownOperation(kind: name, payload: payload))
                }
            }
        }
        guard trimEnd > trimStart else { return nil }
        if let width = metadata?.width, let height = metadata?.height, width > 0, height > 0 {
            project.canvas = MediaCanvas(width: MediaResourceGuard.even(width),
                                         height: MediaResourceGuard.even(height),
                                         frameRate: metadata?.frameRate ?? 30)
        }
        let clip = VideoClip(assetID: asset.id, trimStart: trimStart, trimEnd: trimEnd,
                             speed: speed, volume: volume, isMuted: muted)
        project.videoTimeline = VideoTimeline(clips: [clip])
        project.unknownOperations = preserved
        project.recoveryWarnings.append(WorkbenchText.t(
            "已从旧版单素材编辑工程迁移（保留 \(preserved.count) 个未识别操作）。",
            "Migrated from the legacy single-asset editor (\(preserved.count) unrecognized operation(s) preserved)."))
        return project
    }

    private func audioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.duration).seconds) ?? 0
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        guard let project else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.store.save(project)
            } catch {
                self.present(error)
            }
        }
    }

    func saveNow() async {
        guard let project else { return }
        do { try await store.save(project) } catch { present(error) }
    }

    // MARK: - Export

    /// Registers the entrance-owned callback (e.g. canvas attaches the
    /// exported video). Fires at most once per registration and only for a
    /// verified export; re-registration re-arms it for the next workbench
    /// presentation. A nil callback clears any previous registration.
    func setExportEntranceCallback(_ callback: ((URL) -> Void)?) {
        exportEntranceCallback = callback
        exportEntranceCallbackPending = callback != nil
    }

    /// Drops the retained verified result and its message. Called when a new
    /// attempt starts and on failure/cancellation/project switch so a stale
    /// success can never be shared or delivered again.
    func clearExportDelivery() {
        lastExportResult = nil
        lastExportMessage = nil
    }

    func exportImage(options: ImageExportOptions) async {
        guard let project, project.kind == .image else { return }
        let attemptID = beginExportAttempt()
        await runBusy {
            do {
                let root = WorkbenchPaths.mediaRoot(for: project, current: self.rootProvider())
                let directory = root.appendingPathComponent("Workbench/Exports", isDirectory: true)
                let destination = directory.appendingPathComponent("\(options.fileName).\(options.format.fileExtension)")
                let urls = self.assetURLMap(for: project)
                let receipt = try await self.imageRenderer.exportImage(
                    project: project, options: options,
                    resolveAsset: { urls[$0] },
                    destination: destination)
                let detail = WorkbenchText.t(
                    "\(receipt.width)×\(receipt.height) \(receipt.format)",
                    "\(receipt.width)×\(receipt.height) \(receipt.format)")
                self.recordVerifiedExport(attemptID: attemptID, url: receipt.url, kind: .image,
                                          detail: detail,
                                  message: WorkbenchText.t(
                                      "已导出 \(receipt.width)×\(receipt.height) \(receipt.format) 到 Workbench/Exports/\(destination.lastPathComponent)。",
                                      "Exported \(receipt.width)×\(receipt.height) \(receipt.format) to Workbench/Exports/\(destination.lastPathComponent)."))
                await self.saveNow()
            } catch {
                self.handleExportFailure(error, attemptID: attemptID)
            }
        }
    }

    /// Exports image bytes for entrances that write back into an existing
    /// workspace file (the workspace preview keeps its own commit path).
    func exportImageData(options: ImageExportOptions) async throws -> Data {
        guard let project, project.kind == .image else {
            throw FloeError.validationFailed(WorkbenchText.t("没有可导出的图片项目。", "No image project to export."))
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-workbench-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let destination = temporaryDirectory.appendingPathComponent("\(options.fileName).\(options.format.fileExtension)")
        let urls = assetURLMap(for: project)
        _ = try await imageRenderer.exportImage(project: project, options: options,
                                                resolveAsset: { urls[$0] },
                                                destination: destination)
        return try Data(contentsOf: destination)
    }

    func exportVideo(options: VideoExportOptions) async {
        guard let project, project.kind == .video else { return }
        // A second press while an export runs must not start a competing
        // encoder writing to the same output; cancel/await the first one.
        guard exportCancellation == nil else { return }
        // Immutable snapshot: freeze the project AND its resolved media root
        // before any await, so a project switch during export can never
        // resolve later clips against another project's files.
        let frozenRoot = WorkbenchPaths.mediaRoot(for: project, current: rootProvider())
        let attemptID = beginExportAttempt()
        let token = CancellationToken()
        exportCancellation = token
        busy = true
        exportProgress = 0
        defer { busy = false }
        do {
            let output = "Workbench/Exports/\(options.fileName).mp4"
            let receipt = try await videoRenderer.export(project: project, options: options,
                                                         to: output, cancellation: token,
                                                         mediaRoot: frozenRoot) { [weak self] progress in
                Task { @MainActor in self?.exportProgress = progress }
            }
            // A success arriving after cancellation/project switch is stale:
            // publish nothing and never delete a previous valid output; the
            // atomic commit replaced only the attempt's own output path.
            guard currentExportAttemptID == attemptID, !token.isCancelled else {
                exportProgress = nil
                exportCancellation = nil
                return
            }
            let detail = WorkbenchText.t(
                "\(receipt.width)×\(receipt.height) \(receipt.codec.uppercased()) · \(String(format: "%.2f", receipt.durationSeconds))s",
                "\(receipt.width)×\(receipt.height) \(receipt.codec.uppercased()) · \(String(format: "%.2f", receipt.durationSeconds))s")
            recordVerifiedExport(attemptID: attemptID, url: receipt.url, kind: .video,
                                 detail: detail,
                                 message: WorkbenchText.t(
                                     "已导出 \(receipt.width)x\(receipt.height) \(receipt.codec) \(String(format: "%.2f", receipt.durationSeconds))s。",
                                     "Exported \(receipt.width)x\(receipt.height) \(receipt.codec) \(String(format: "%.2f", receipt.durationSeconds))s."))
            await saveNow()
        } catch {
            handleExportFailure(error, attemptID: attemptID)
        }
        exportProgress = nil
        exportCancellation = nil
    }

    func cancelExport() {
        exportCancellation?.cancel()
    }

    // MARK: Export delivery internals

    private func beginExportAttempt() -> UUID {
        let attemptID = UUID()
        currentExportAttemptID = attemptID
        // Every new attempt clears the previously retained verified result so
        // a failure/cancel can never leave stale success visible.
        lastExportResult = nil
        lastExportMessage = nil
        return attemptID
    }

    private func recordVerifiedExport(attemptID: UUID, url: URL, kind: MediaProjectKind,
                                      detail: String, message: String) {
        // A superseded attempt (new attempt started, project switched) never
        // publishes a result.
        guard currentExportAttemptID == attemptID else { return }
        let result = VerifiedExport(attemptID: attemptID, url: url, kind: kind, detail: detail)
        lastExportResult = result
        lastExportMessage = message
        // The entrance callback fires exactly once per registration, only on
        // a verified export. It is re-armed whenever the panel presents.
        if exportEntranceCallbackPending, let callback = exportEntranceCallback {
            exportEntranceCallbackPending = false
            callback(url)
        }
    }

    private func handleExportFailure(_ error: Error, attemptID: UUID) {
        guard currentExportAttemptID == attemptID else { return }
        lastExportResult = nil
        if case FloeError.cancelled = error {
            lastExportMessage = WorkbenchText.t("已取消导出。", "Export cancelled.")
        } else {
            lastExportMessage = nil
            present(error)
        }
    }

    // MARK: - Proposals

    func reloadPendingProposals() async {
        guard let project else { return }
        let stored = await proposalStore.all()
        pendingProposals = stored.filter { $0.projectID == project.id }
    }

    /// MainActor-reachable refresh used from nonisolated host methods.
    func refreshProposalCache() async {
        await reloadPendingProposals()
    }

    func acceptProposal(_ proposal: MediaProposal) {
        guard var current = project, current.id == proposal.projectID else { return }
        // Trusted interactive path: the user tapped accept. The gate applies
        // one draft-then-commit transaction; stale revisions are refused.
        do {
            try MediaProposalGate.applyAuthorized(proposal, grant: .authorized, to: &current)
            project = current
            Task { [weak self] in
                await self?.proposalStore.remove(id: proposal.id)
                await self?.reloadPendingProposals()
            }
            scheduleSave()
            refreshPreview()
            if current.kind == .video { refreshThumbnails() }
        } catch {
            present(error)
        }
    }

    func rejectProposal(_ proposal: MediaProposal) {
        Task { [weak self] in
            await self?.proposalStore.remove(id: proposal.id)
            await self?.reloadPendingProposals()
        }
    }

    // MARK: - AI drawer

    func reloadAISignals() async {
        aiAvailable = await bridge.isAvailable()
        guard let project else { return }
        aiJobs = await bridge.jobs(project.id)
    }

    func prepareImageGeneration(prompt: String, modelID: UUID, size: String?, count: Int,
                                sourceAssetID: UUID?) {
        let model = bridge.imageModels().first { $0.id == modelID }
        var assets: [String] = []
        var parameters: [String: String] = [
            WorkbenchText.t("数量", "Count"): String(count)
        ]
        if let size { parameters[WorkbenchText.t("尺寸", "Size")] = size }
        if let sourceAssetID, let asset = project?.asset(sourceAssetID) {
            assets.append(asset.originalName)
            parameters[WorkbenchText.t("参考素材", "Reference")] = asset.originalName
        }
        aiReview = AIReviewRequest(kind: .image, prompt: prompt, modelID: modelID,
                                   modelName: model?.displayName ?? modelID.uuidString,
                                   payload: .image(size: size, count: count, sourceAssetID: sourceAssetID),
                                   assetNames: assets, parameters: parameters,
                                   costNote: bridge.costNote(modelID))
    }

    func confirmImageGeneration(_ request: AIReviewRequest) async {
        guard case .image(let size, let count, let sourceAssetID) = request.payload else { return }
        // One confirmed review submits at most once: a duplicate tap, a
        // replayed sheet action or a restored in-flight request can never
        // resubmit an image generation (no provider job id exists to dedupe
        // server-side).
        guard !confirmedReviewRequestIDs.contains(request.id) else { return }
        confirmedReviewRequestIDs.insert(request.id)
        // Freeze the project this review was confirmed against. The project
        // library can switch projects while the await is in flight; the
        // delivered candidates then belong to the ORIGINAL project.
        guard let frozenProject = project else { return }
        let frozenProjectID = frozenProject.id
        let detail = [
            size.map { WorkbenchText.t("尺寸", "Size") + ": \($0)" },
            WorkbenchText.t("数量", "Count") + ": \(count)",
            sourceAssetID.flatMap { id in frozenProject.asset(id)?.originalName }
                .map { WorkbenchText.t("参考素材", "Reference") + ": \($0)" }
        ].compactMap { $0 }.joined(separator: " · ")
        let record = WorkbenchImageRequestStore.Record(
            id: request.id, projectID: frozenProjectID, prompt: request.prompt,
            modelID: request.modelID, modelName: request.modelName, detail: detail,
            createdAt: Date(), status: .submitted, message: nil)
        try? imageRequestStore.upsert(record)
        if project?.id == frozenProjectID {
            // The request really is in flight; do not let restoration-time
            // reclassification relabel it as interrupted.
            imageRequests = imageRequestStore.current(projectID: frozenProjectID)
        }
        await runBusy {
            do {
                let assetURLs = self.assetURLMap(for: frozenProject)
                let sourceURL = sourceAssetID.flatMap { assetURLs[$0] }
                let urls = try await self.bridge.generateImages(request.prompt, request.modelID,
                                                                size, count, sourceURL)
                // Persist delivered candidates against the ORIGINAL project
                // even when the visible project has since changed.
                var delivered: [Candidate] = []
                for url in urls {
                    delivered.append(Candidate(id: UUID(), url: url, kind: .image,
                                               modelName: request.modelName,
                                               parametersSummary: request.prompt,
                                               createdAt: Date()))
                }
                guard !delivered.isEmpty else {
                    // The provider answered without an identifiable local
                    // failure and returned nothing usable: we cannot prove it
                    // did not generate anything, so mark unknown — never
                    // resubmit automatically.
                    var unknown = record
                    unknown.status = .unknown
                    unknown.message = WorkbenchText.t(
                        "提交后未收到可下载的图片；无法确认服务商是否已生成，不会自动重试。",
                        "No downloadable image was returned after submission; the provider outcome is unknown and it will not be retried automatically.")
                    try? self.imageRequestStore.upsert(unknown)
                    if self.project?.id == frozenProjectID {
                        self.imageRequests = self.imageRequestStore.load(projectID: frozenProjectID)
                    }
                    return
                }
                try? await self.candidateStore.append(projectID: frozenProjectID, candidates: delivered)
                // Delivered candidates retire the request record.
                try? self.imageRequestStore.remove(projectID: frozenProjectID, recordID: record.id)
                if self.project?.id == frozenProjectID {
                    self.candidates = await self.candidateStore.load(projectID: frozenProjectID)
                    self.imageRequests = self.imageRequestStore.load(projectID: frozenProjectID)
                }
            } catch is CancellationError {
                var interrupted = record
                interrupted.status = .interrupted
                interrupted.message = WorkbenchText.t(
                    "等待图片结果时被中断；不会自动重新提交。",
                    "Interrupted while waiting for image results; it will not be resubmitted automatically.")
                try? self.imageRequestStore.upsert(interrupted)
                if self.project?.id == frozenProjectID {
                    self.imageRequests = self.imageRequestStore.load(projectID: frozenProjectID)
                }
            } catch {
                // A local/transport failure after submission cannot prove the
                // provider rejected the request; record unknown rather than
                // resubmitting, except for a clear provider-reported failure.
                let definitive = Self.isDefinitiveProviderFailure(error)
                var outcome = record
                outcome.status = definitive ? .failed : .unknown
                outcome.message = error.localizedDescription
                try? self.imageRequestStore.upsert(outcome)
                if self.project?.id == frozenProjectID {
                    self.imageRequests = self.imageRequestStore.load(projectID: frozenProjectID)
                    if definitive { self.present(error) }
                }
            }
        }
    }

    /// Only an explicit, provider-reported rejection is a definitive failure
    /// the user could correct and retry manually. Timeouts, cancellations and
    /// transport errors are unknown outcomes.
    private nonisolated static func isDefinitiveProviderFailure(_ error: Error) -> Bool {
        if case FloeError.validationFailed = error { return true }
        if case FloeError.invalidConfiguration = error { return true }
        if case FloeError.unauthorized = error { return true }
        return false
    }

    /// Removes a recorded image request after the user acknowledges it.
    func dismissImageRequest(_ recordID: UUID) {
        guard let projectID = project?.id else { return }
        imageRequestStore.remove(projectID: projectID, recordID: recordID)
        imageRequests = imageRequestStore.load(projectID: projectID)
    }

    func prepareVideoGeneration(prompt: String, modelID: UUID, options: WorkbenchVideoAIOptions) {
        let model = bridge.videoModels().first { $0.id == modelID }
        var parameters: [String: String] = [:]
        if let duration = options.durationSeconds { parameters[WorkbenchText.t("时长", "Duration")] = "\(Int(duration))s" }
        if let aspect = options.aspectRatio { parameters[WorkbenchText.t("画幅", "Aspect")] = aspect }
        if let resolution = options.resolution { parameters[WorkbenchText.t("分辨率", "Resolution")] = resolution }
        aiReview = AIReviewRequest(kind: .video, prompt: prompt, modelID: modelID,
                                   modelName: model?.displayName ?? modelID.uuidString,
                                   payload: .video(options: options),
                                   assetNames: [], parameters: parameters,
                                   costNote: bridge.costNote(modelID))
    }

    func confirmVideoGeneration(_ request: AIReviewRequest) async {
        guard case .video(let options) = request.payload else { return }
        // Duplicate confirmations of the same review sheet can never submit a
        // second remote video job.
        guard !confirmedReviewRequestIDs.contains(request.id) else { return }
        confirmedReviewRequestIDs.insert(request.id)
        guard let project else { return }
        await runBusy {
            // The submission carries the reviewed options verbatim.
            _ = try await self.bridge.submitVideo(request.prompt, request.modelID, options,
                                                  project.id, nil)
            await self.reloadAISignals()
        }
    }

    func refreshAIJobs() async {
        guard let project else { return }
        for job in aiJobs where !stoppedWaitingJobs.contains(job.id) && job.isActive {
            _ = try? await bridge.refreshJob(job.id)
        }
        aiJobs = await bridge.jobs(project.id)
    }

    func imageModelsForUI() -> [WorkbenchAIModelInfo] { bridge.imageModels() }

    func noteExportMessage(_ text: String) { lastExportMessage = text }
    func videoModelsForUI() -> [WorkbenchAIModelInfo] { bridge.videoModels() }

    /// Adds a delivered remote result as a candidate (never auto-imported).
    func addImportedCandidate(url: URL) {
        let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey])
        let kind: MediaAssetKind
        if resourceValues?.contentType?.conforms(to: .image) == true {
            kind = .image
        } else if resourceValues?.contentType?.conforms(to: .audio) == true {
            kind = .audio
        } else {
            kind = .video
        }
        candidates.append(Candidate(id: UUID(), url: url, kind: kind,
                                    modelName: WorkbenchText.t("远端任务", "Remote job"),
                                    parametersSummary: url.lastPathComponent,
                                    createdAt: Date()))
        persistCandidates()
    }

    /// Writes the candidate records for the current project so delivered
    /// results survive closing/reopening the workbench.
    private func persistCandidates() {
        guard let projectID = project?.id else { return }
        let snapshot = candidates
        Task { [candidateStore] in
            try? await candidateStore.save(projectID: projectID, candidates: snapshot)
        }
    }

    /// Stops local waiting; the remote task keeps running and can be
    /// recovered later. This is not a cancellation.
    func stopWaiting(jobID: UUID) {
        stoppedWaitingJobs.insert(jobID)
        aiJobs = aiJobs.map { job in
            var copy = job
            if copy.id == jobID { copy.isWaitStopped = true }
            return copy
        }
    }

    func resumeWaiting(jobID: UUID) {
        stoppedWaitingJobs.remove(jobID)
        aiJobs = aiJobs.map { job in
            var copy = job
            if copy.id == jobID { copy.isWaitStopped = false }
            return copy
        }
        Task { await refreshAIJobs() }
    }

    func cancelAIJob(jobID: UUID) async {
        await runBusy {
            try await self.bridge.cancelJob(jobID)
            await self.reloadAISignals()
        }
    }

    func deliverCandidateURL(jobID: UUID) async -> URL? {
        try? await bridge.deliverResult(jobID)
    }

    func acceptCandidate(_ candidate: Candidate) {
        guard var current = project else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                switch (current.kind, candidate.kind) {
                case (.image, _):
                    let asset = MediaAssetReference(kind: .image,
                                                    relativePath: await self.workspaceRelativePath(candidate.url),
                                                    originalName: candidate.url.lastPathComponent)
                    try MediaTransactions.apply(.addAsset(asset), to: &current)
                    let layer = ImageLayer(kind: .image,
                                           name: WorkbenchText.t("AI 图层", "AI layer"), assetID: asset.id)
                    try MediaTransactions.apply(.addImageLayer(layer), to: &current)
                case (.video, _):
                    let asset = MediaAssetReference(kind: .video,
                                                    relativePath: await self.workspaceRelativePath(candidate.url),
                                                    originalName: candidate.url.lastPathComponent)
                    let metadata = try await self.videoRenderer.inspect(assetPath: asset.relativePath)
                    try MediaTransactions.apply(.addAsset(asset), to: &current)
                    let duration = metadata.durationSeconds ?? 0
                    guard duration > 0 else {
                        throw FloeError.validationFailed(WorkbenchText.t("生成的视频没有可读时长。",
                                                                         "The generated video has no readable duration."))
                    }
                    try MediaTransactions.apply(.appendClip(VideoClip(assetID: asset.id,
                                                                      trimStart: 0, trimEnd: duration)),
                                                to: &current)
                }
                self.project = current
                self.candidates.removeAll { $0.id == candidate.id }
                self.persistCandidates()
                self.scheduleSave()
                self.refreshPreview()
            } catch {
                self.present(error)
            }
        }
    }

    func rejectCandidate(_ candidate: Candidate) {
        candidates.removeAll { $0.id == candidate.id }
        persistCandidates()
    }

    private func workspaceRelativePath(_ url: URL) async -> String {
        let canonical = mediaRoot().resolvingSymlinksInPath().standardizedFileURL
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if target.path.hasPrefix(canonical.path + "/") {
            return String(target.path.dropFirst(canonical.path.count + 1))
        }
        if let asset = try? await importAsset(url: url) {
            return asset.relativePath
        }
        return url.path
    }

    // MARK: - Helpers

    private func runBusy(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        if case FloeError.cancelled = error { return }
        alert = Alert(title: WorkbenchText.t("操作未完成", "Action incomplete"),
                      message: error.localizedDescription)
    }
}

extension WorkbenchCenter: MediaProjectHost {
    nonisolated func authorizeAccess(projectID: UUID, access: MediaProjectAccess) async throws {
        // Refuse cross-environment / cross-task / cross-owner access before
        // any read, proposal, apply or export is attempted. A project that
        // records ownership requires the caller to present the SAME context:
        // absent or mismatched context is refused, never treated as a wildcard.
        guard let target = try await loadProject(id: projectID) else { return }
        if let recorded = target.environmentID {
            guard access.environmentID == recorded else { throw FloeError.unauthorized }
        }
        let taskScoped = ["chat", "canvas"].contains(target.ownerKind)
        if taskScoped {
            // Task-scoped projects require the SAME owner; absent context is
            // refused, never treated as a wildcard.
            guard let recorded = target.ownerID,
                  access.ownerID == recorded,
                  access.ownerKind == target.ownerKind else { throw FloeError.unauthorized }
        }
        if let recorded = target.taskWorkspacePath, !recorded.isEmpty {
            guard let requested = access.workspacePath else { throw FloeError.unauthorized }
            let a = URL(fileURLWithPath: recorded).resolvingSymlinksInPath().standardizedFileURL.path
            let b = URL(fileURLWithPath: requested).resolvingSymlinksInPath().standardizedFileURL.path
            guard a == b else { throw FloeError.unauthorized }
        } else if access.workspacePath != nil {
            // A standalone project (no recorded workspace) is not reachable
            // from a workspace-scoped caller.
            throw FloeError.unauthorized
        }
    }
    nonisolated func loadProject(id: UUID) async throws -> MediaProject? {
        if let current = await MainActor.run(body: { self.project }), current.id == id {
            return current
        }
        return try await store.loadProject(id: id)
    }

    nonisolated func persistProject(_ project: MediaProject, expectedRevision: Int64?) async throws {
        try await store.save(project, expectedRevision: expectedRevision)
        await MainActor.run {
            if self.project?.id == project.id { self.project = project }
        }
    }

    nonisolated func storeProposal(_ proposal: MediaProposal) async throws {
        await proposalStore.put(proposal)
        await self.refreshProposalCache()
    }

    nonisolated func loadProposal(id: UUID) async throws -> MediaProposal? {
        await proposalStore.get(id: id)
    }

    nonisolated func removeProposal(id: UUID) async throws {
        await proposalStore.remove(id: id)
        await self.refreshProposalCache()
    }

    nonisolated func consumeGrant(grantID: String, proposalID: UUID, projectID: UUID,
                                  revision: Int64) async -> MediaGrantDecision {
        await grantStore.consume(grantID: grantID, projectID: projectID,
                                 proposalID: proposalID, revision: revision)
    }

    nonisolated func exportVideo(project: MediaProject, options: VideoExportOptions,
                                 relativeOutput: String, cancellation: CancellationToken?) async throws -> WorkbenchVideoExportReceipt {
        // The tool operates on the PASSED project: freeze that project's own
        // recorded root instead of consulting the shared renderer's dynamic
        // root (which follows the currently open UI project).
        let root = await MainActor.run {
            WorkbenchPaths.mediaRoot(for: project, current: self.rootProvider())
        }
        return try await videoRenderer.export(project: project, options: options,
                                              to: relativeOutput, cancellation: cancellation,
                                              mediaRoot: root)
    }

    nonisolated func exportImage(project: MediaProject, options: ImageExportOptions,
                                 relativeOutput: String) async throws -> WorkbenchImageExportReceipt {
        let destination = await MainActor.run {
            self.mediaRoot().appendingPathComponent(relativeOutput)
        }
        let urls = await MainActor.run { self.assetURLMap(for: project) }
        return try await imageRenderer.exportImage(project: project, options: options,
                                                   resolveAsset: { urls[$0] },
                                                   destination: destination)
    }
}

extension MediaProposalDraftStore {
    func all() -> [MediaProposal] { values() }
}