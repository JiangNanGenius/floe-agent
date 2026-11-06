// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers
import FloeWorkbench

@MainActor @Observable final class MediaV2Session {
    private static var sessions: [String: MediaV2Session] = [:]
    let id: UUID
    let root: URL
    let store: MediaProjectStore
    let coordinator: MediaPreparedCoordinator
    private(set) var project: MediaProject
    var document: MediaPreparedDocument { project.prepared! }
    var selectedLayerID: UUID?
    var selectedTrackID: UUID?
    var selectedClipID: UUID?
    var tool = "image.brush"
    var selection: ImageSelection?
    var selectionMode: ImageSelectionOperation = .replace
    var showSelection = true
    var polygonPoints: [ImageFreehandStroke.Point] = []
    var eraserRestores = false
    var multipleLayerSelection = false
    var selectedLayerIDs: Set<UUID> = []
    var timelineZoom = 1.0
    var timelineSnap = true
    var rippleCurrentTrack = false
    var brushWidth = 12.0
    var brushHardness = 0.8
    var brushOpacity = 1.0
    var colorHex = "#166F74"
    var playhead = 0.0
    var zoom = 1.0
    private(set) var saving = false
    private(set) var preview: CGImage?
    private(set) var rendering = false
    private(set) var exportProgress: Double?
    private(set) var exportedFile: URL?
    var diagnostic: String?
    var player: AVPlayer?
    private var playbackAuthority: NativeCreativeAudioSession?
    private var playbackGeneration = UUID()
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var playbackFile: URL?
    private var cancellation: PreparedVideoCancellation?
    let imageRenderer = WorkbenchImageRenderer()
    private let frameRenderer = PreparedVideoFrameRenderer()
    private let videoDelivery = MediaPreparedVideoDelivery()
    @ObservationIgnored var onCommit: ((MediaProject) -> Void)?

    private init(project: MediaProject, root: URL, store: MediaProjectStore, coordinator: MediaPreparedCoordinator) {
        id = project.id; self.project = project; self.root = root; self.store = store; self.coordinator = coordinator
        selectedLayerID = project.prepared?.layers.last?.id
        selectedTrackID = project.prepared?.trackGraph.tracks.first?.id
        tool = project.kind == .video ? "video.trim" : "image.brush"
    }
    static func open(projectID: UUID, root: URL, store: MediaProjectStore, upgrade: Bool = false) async throws -> MediaV2Session {
        let key = store.storeRootPath + "/" + projectID.uuidString
        if let existing = sessions[key] { try await existing.reload(); return existing }
        let coordinator = MediaPreparedCoordinator(store: store)
        if upgrade { _ = try await coordinator.upgradeDocument(id: projectID) }
        guard let project = try await store.loadProject(id: projectID), project.prepared != nil else { throw PersonalContentError.invalidProject }
        try MediaPreparedIntegrity.validateEnvelope(project)
        let value = MediaV2Session(project: project, root: root, store: store, coordinator: coordinator)
        sessions[key] = value
        value.refreshPreview()
        return value
    }
    var selectedLayer: MediaPreparedLayer? { document.layers.first { $0.id == selectedLayerID } }
    var selectedTrack: MediaPreparedTrack? { document.trackGraph.tracks.first { $0.id == selectedTrackID } }
    var selectedClip: (track: MediaPreparedTrack, clip: MediaPreparedClip)? {
        selectedClipID.flatMap { document.trackGraph.clip(id: $0) }
    }
    var duration: Double { document.trackGraph.totalDurationSeconds }
    var canUndo: Bool { project.preparedJournal?.entries.contains { $0.status == .committed } == true }
    func reload() async throws {
        _ = try await coordinator.reloadDocument(id: id)
        guard let next = try await store.loadProject(id: id) else { throw PersonalContentError.missingDocument }
        project = next; onCommit?(next); refreshPreview()
    }
    @discardableResult
    func apply(_ operations: [MediaPreparedOperation], expectedRevision: Int64? = nil,
               actor: MediaPreparedActorKind = .user) async throws -> MediaPreparedCommit {
        guard !saving else { throw MediaPreparedCoreError.conflict("an edit is saving") }
        if let expectedRevision, expectedRevision != document.revision { throw MediaPreparedCoreError.documentChanged }
        saving = true
        defer { saving = false }
        let commit = try await coordinator.applyUserOperations(operations, to: id, actor: actor)
        try await reload()
        return commit
    }
    func submit(_ actions: [MediaPreparedAction]) {
        let base = document.revision
        Task { do { _ = try await apply(actions.map { .init(action: $0) }, expectedRevision: base) } catch { diagnostic = error.localizedDescription } }
    }
    func undo() {
        guard let entry = project.preparedJournal?.entries.last(where: { $0.status == .committed }) else { return }
        Task { do { _ = try await coordinator.undoGroup(entry.id, in: id); try await reload() } catch { diagnostic = error.localizedDescription } }
    }
    func select(_ layer: MediaPreparedLayer) {
        selectedLayerID = layer.id
        if multipleLayerSelection {
            if selectedLayerIDs.contains(layer.id) { selectedLayerIDs.remove(layer.id) }
            else { selectedLayerIDs.insert(layer.id) }
        } else { selectedLayerIDs = [layer.id] }
    }
    func select(_ track: MediaPreparedTrack, clip: MediaPreparedClip? = nil) { selectedTrackID = track.id; selectedClipID = clip?.id }
    func resolvedAssets() throws -> [UUID: URL] {
        var urls: [UUID: URL] = [:]
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        for asset in document.assets {
            let url = (asset.relativePath.hasPrefix("/") ? URL(fileURLWithPath: asset.relativePath) : canonical.appendingPathComponent(asset.relativePath)).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(canonical.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw PersonalContentError.missingDocument }
            urls[asset.id] = url
        }
        return urls
    }
    func scrub(_ seconds: Double) { playhead = max(0, min(duration, seconds)); refreshPreview() }
    func refreshPreview() {
        previewTask?.cancel()
        let frozen = project, position = playhead
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(60))
                let assets = try resolvedAssets()
                let image: CGImage
                if frozen.kind == .image {
                    let canvas = frozen.canvas ?? .init(width: 1600, height: 1200)
                    image = try await imageRenderer.render(project: frozen, canvas: CGSize(width: canvas.width, height: canvas.height), resolveAsset: { assets[$0] }, previewMaxEdge: 2048)
                } else {
                    guard duration > 0 else { preview = nil; return }
                    let plan = try MediaPreparedVideoDocumentAdapter.resolve(frozen.prepared!, assetURLs: assets, includeAudio: false)
                    let canvas = plan.canvas
                    let scale = min(1, 1280 / Double(max(canvas.width, canvas.height)))
                    let settings = try PreparedVideoOutputSettings(width: max(2, Int(Double(canvas.width) * scale) / 2 * 2), height: max(2, Int(Double(canvas.height) * scale) / 2 * 2), frameRate: plan.frameRate)
                    let frame = min(max(0, plan.frameRate.frameIndex(for: try .init(seconds: position, timescale: plan.timeScale), rounding: .down)), max(0, plan.frameRate.frameIndex(for: plan.duration, rounding: .up) - 1))
                    image = try await frameRenderer.renderFrame(plan: plan, frameIndex: frame, settings: settings).image
                }
                guard !Task.isCancelled, project.id == frozen.id, project.revision == frozen.revision else { return }
                preview = image
            } catch {
                if !Task.isCancelled { preview = nil; diagnostic = error.localizedDescription }
            }
        }
    }
    func addLayer(_ content: MediaPreparedLayerContent, name: String) {
        let layer = MediaPreparedLayer(name: name, content: content)
        selectedLayerID = layer.id
        submit([.insertLayer(layer: layer, parentID: nil, index: nil)])
    }
    func mergeLayers(_ ids: Set<UUID>, actor: MediaPreparedActorKind) async throws -> MediaPreparedCommit {
        let frozen = project, urls = try resolvedAssets()
        let canvas = document.canvas!
        let image = try await imageRenderer.renderMerge(project: frozen, layerIDs: ids,
            canvas: CGSize(width: canvas.width, height: canvas.height), resolveAsset: { urls[$0] })
        guard let data = WorkbenchPNG.encode(image) else { throw MediaV2CommandError.invalidInput }
        let directory = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: file, options: .atomic)
        let asset = MediaAssetReference(kind: .image, relativePath: "Assets/" + file.lastPathComponent, originalName: "merged.png", byteCount: Int64(data.count), contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        var actions: [MediaPreparedAction] = [.insertAsset(asset)]
        for layer in frozen.prepared!.layers where ids.contains(layer.id) { actions.append(.removeLayer(id: layer.id, expectedRevision: layer.revision)) }
        let layer = MediaPreparedLayer(name: WorkbenchText.t("合并图层", "Merged layers"), content: .raster(.init(source: .asset(asset.id))))
        actions.append(.insertLayer(layer: layer, parentID: nil, index: frozen.prepared!.layers.firstIndex { ids.contains($0.id) }))
        let commit = try await apply(actions.map { .init(action: $0) }, expectedRevision: frozen.revision, actor: actor)
        selectedLayerID = layer.id
        return commit
    }
    func updateLayer(_ change: (inout MediaPreparedLayer) -> Void) {
        guard let layer = selectedLayer else { return }
        var next = layer; change(&next)
        var actions: [MediaPreparedAction] = []
        var revision = layer.revision
        if next.content != layer.content { actions.append(.replaceLayerContent(id: layer.id, expectedRevision: revision, content: next.content)); revision += 1 }
        if next.transform != layer.transform { actions.append(.updateLayerTransform(id: layer.id, expectedRevision: revision, transform: next.transform)); revision += 1 }
        if next.adjustment != layer.adjustment { actions.append(.updateLayerAdjustment(id: layer.id, expectedRevision: revision, adjustment: next.adjustment)); revision += 1 }
        if next.mask != layer.mask { actions.append(.setLayerMask(id: layer.id, expectedRevision: revision, mask: next.mask)); revision += 1 }
        if next.clip != layer.clip { actions.append(.setLayerClip(id: layer.id, expectedRevision: revision, clip: next.clip)); revision += 1 }
        if next.opacity != layer.opacity || next.name != layer.name || next.isLocked != layer.isLocked || next.isVisible != layer.isVisible {
            actions.append(.updateLayerFlags(id: layer.id, expectedRevision: revision, name: next.name, isVisible: next.isVisible, isLocked: next.isLocked, opacity: next.opacity))
        }
        if !actions.isEmpty { submit(actions) }
    }
    func updateClip(_ change: (inout MediaPreparedClip) throws -> Void) {
        guard let selected = selectedClip else { return }
        do { var next = selected.clip; try change(&next); submit([.replaceClip(trackID: selected.track.id, clipID: next.id, expectedRevision: selected.clip.revision, clip: next)]) }
        catch { diagnostic = error.localizedDescription }
    }
    func addTrack(_ kind: MediaPreparedTrackKind) {
        let track = MediaPreparedTrack(kind: kind, name: WorkbenchText.t("新轨道", "New track"))
        selectedTrackID = track.id; submit([.insertTrack(track: track, index: nil)])
    }
    func addStroke(_ points: [ImageFreehandStroke.Point]) {
        guard !points.isEmpty else { return }
        let stroke = ImageFreehandStroke(points: points, width: brushWidth, colorHex: colorHex, hardness: 1 - brushHardness, opacity: brushOpacity)
        if tool == "image.eraser" {
            updateLayer { layer in var mask = layer.mask ?? .init(); mask.strokes.append(.init(points: points, width: brushWidth, hardness: 1 - brushHardness, restore: false, region: selection)); layer.mask = mask }
        } else if let layer = selectedLayer, case .strokes(var content) = layer.content {
            content.strokes.append(stroke); updateLayer { $0.content = .strokes(content) }
        } else { addLayer(.strokes(.init(strokes: [stroke])), name: WorkbenchText.t("笔迹", "Brush stroke")) }
    }
    func importFile(_ url: URL) async {
        do {
            let reference = try await stage(url)
            var actions: [MediaPreparedAction] = [.insertAsset(reference)]
            if project.kind == .image {
                guard reference.kind == .image else { throw PersonalContentError.invalidProject }
                let layer = MediaPreparedLayer(name: reference.originalName, content: .raster(.init(source: .asset(reference.id))))
                actions.append(.insertLayer(layer: layer, parentID: nil, index: nil)); selectedLayerID = layer.id
            } else {
                let kind: MediaPreparedTrackKind = reference.kind == .audio ? .audio : .visual
                let track = document.trackGraph.tracks.first { $0.id == selectedTrackID && $0.kind == kind }
                    ?? document.trackGraph.tracks.first { $0.kind == kind }
                    ?? MediaPreparedTrack(kind: kind, name: reference.originalName)
                if !document.trackGraph.tracks.contains(where: { $0.id == track.id }) { actions.append(.insertTrack(track: track, index: nil)) }
                let seconds = reference.kind == .image ? 5 : reference.metadata?.durationSeconds ?? 0
                guard seconds > 0 else { throw PersonalContentError.invalidProject }
                let range = try Self.range(start: playhead, duration: seconds)
                let clip = MediaPreparedClip(assetID: reference.id, timelineRange: range, sourceRange: try Self.range(start: 0, duration: seconds), isMuted: reference.kind == .video && (reference.metadata?.audioTracks ?? 0) > 0)
                actions.append(.insertClip(trackID: track.id, clip: clip, index: nil)); selectedTrackID = track.id; selectedClipID = clip.id
                if reference.kind == .video, (reference.metadata?.audioTracks ?? 0) > 0 {
                    let audio = try await extractAudio(reference)
                    actions.append(.insertAsset(audio))
                    let track = MediaPreparedTrack(kind: .audio, name: reference.originalName + WorkbenchText.t(" · 原声", " · source audio"))
                    actions.append(.insertTrack(track: track, index: nil))
                    actions.append(.insertClip(trackID: track.id, clip: .init(assetID: audio.id, timelineRange: range, sourceRange: try Self.range(start: 0, duration: seconds)), index: nil))
                }
            }
            _ = try await apply(actions.map { .init(action: $0) })
        } catch { diagnostic = error.localizedDescription }
    }
    private func stage(_ source: URL) async throws -> MediaAssetReference {
        let root = root
        return try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 2_147_483_648 else { throw PersonalContentError.invalidProject }
            let type = values.contentType
            let kind: MediaAssetKind
            if type?.conforms(to: .image) == true { kind = .image }
            else if type?.conforms(to: .audio) == true { kind = .audio }
            else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
            else { throw PersonalContentError.invalidProject }
            let directory = root.appendingPathComponent("Assets")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            var hasher = SHA256()
            let file = try FileHandle(forReadingFrom: destination); defer { try? file.close() }
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hasher.update(data: data) }
            var metadata: MediaAssetMetadata?
            if kind != .image {
                let asset = AVURLAsset(url: destination)
                let duration = try await asset.load(.duration).seconds
                let audio = try await asset.loadTracks(withMediaType: .audio)
                metadata = .init(durationSeconds: duration, audioTracks: audio.count)
            }
            return MediaAssetReference(kind: kind, relativePath: "Assets/" + destination.lastPathComponent, originalName: source.lastPathComponent, byteCount: Int64(size), contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(), metadata: metadata)
        }.value
    }
    private func extractAudio(_ reference: MediaAssetReference) async throws -> MediaAssetReference {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let url = (reference.relativePath.hasPrefix("/") ? URL(fileURLWithPath: reference.relativePath) : canonical.appendingPathComponent(reference.relativePath)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path + "/") else { throw PersonalContentError.outsideLibrary }
        let destination = root.appendingPathComponent("Assets/\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else { throw PersonalContentError.invalidProject }
        try await export.export(to: destination, as: .m4a)
        let staged = try await stage(destination)
        try? FileManager.default.removeItem(at: destination)
        return staged
    }
    private func prepareVideoSourceAudio() async throws {
        guard project.kind == .video else { return }
        let frozen = document
        let sources = try resolvedAssets()
        var actions: [MediaPreparedAction] = []
        var staged: [UUID: MediaAssetReference] = [:]
        for track in frozen.trackGraph.tracks where track.kind == .visual {
            for clip in track.clips where !clip.isMuted {
                guard let assetID = clip.assetID, let asset = frozen.asset(assetID), asset.kind == .video else { continue }
                guard let url = sources[assetID] else { throw PersonalContentError.missingDocument }
                let hasAudio = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty == false
                guard hasAudio else { continue }
                guard clip.speed == 1 else { throw PreparedVideoError.unsupportedCapability("retimed source audio") }
                let source: MediaAssetReference
                if let existing = staged[assetID] { source = existing }
                else { source = try await extractAudio(asset); staged[assetID] = source; actions.append(.insertAsset(source)) }
                var visual = clip; visual.isMuted = true
                actions.append(.replaceClip(trackID: track.id, clipID: clip.id, expectedRevision: clip.revision, clip: visual))
                let audio = MediaPreparedTrack(kind: .audio, name: asset.originalName + WorkbenchText.t(" · 原声", " · source audio"), isMuted: track.isMuted, volume: track.volume)
                actions.append(.insertTrack(track: audio, index: nil))
                var sound = clip; sound.id = UUID(); sound.assetID = source.id; sound.isMuted = false; sound.revision = 0
                actions.append(.insertClip(trackID: audio.id, clip: sound, index: nil))
            }
        }
        if !actions.isEmpty { _ = try await apply(actions.map { .init(action: $0) }, expectedRevision: frozen.revision) }
    }
    static func time(_ seconds: Double) throws -> MediaRationalTime {
        guard seconds.isFinite, abs(seconds) <= 100_000 else { throw PersonalContentError.invalidProject }
        return try .init(value: Int64((seconds * 90_000).rounded()), timescale: 90_000)
    }
    static func range(start: Double, duration: Double) throws -> MediaTimeRange { try .init(start: time(start), duration: time(duration)) }
    func export() {
        guard !rendering else { return }
        rendering = true; diagnostic = nil; exportProgress = nil; exportedFile = nil
        let token = PreparedVideoCancellation(); cancellation = token
        exportTask = Task { [self] in
            defer { rendering = false; exportTask = nil }
            do {
                try await prepareVideoSourceAudio()
                let frozen = project
                let urls = try resolvedAssets()
                let folder = root.appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("export-r\(frozen.revision)-\(UUID().uuidString)." + (frozen.kind == .image ? "png" : "mp4"))
                if frozen.kind == .image {
                    _ = try await imageRenderer.exportImage(project: frozen, options: .init(format: .png), resolveAsset: { urls[$0] }, destination: file)
                } else {
                    let canvas = frozen.canvas!
                    _ = try await videoDelivery.export(document: frozen.prepared!, assetURLs: urls,
                        options: .init(width: canvas.width, height: canvas.height, frameRate: frozen.prepared!.trackGraph.frameRate?.seconds ?? 30), destination: file, cancellation: token) { [weak self] value in
                            Task { @MainActor in self?.exportProgress = value }
                        }
                }
                try token.check()
                guard project.id == frozen.id, project.revision == frozen.revision else { throw MediaPreparedCoreError.documentChanged }
                exportedFile = file
            } catch { if !Task.isCancelled { diagnostic = error.localizedDescription } }
        }
    }
    func cancelExport() { cancellation?.cancel(); exportTask?.cancel() }
    func exportAndWait() async throws -> URL {
        guard !rendering else { throw MediaV2CommandError.invalidInput }
        export()
        await exportTask?.value
        try Task.checkCancellation()
        guard let file = exportedFile else { throw MediaV2CommandError.invalidInput }
        return file
    }
    func recordExport(_ url: URL) { exportedFile = url }
    func play(authority: NativeCreativeAudioSession) {
        stopPlayback()
        let generation = playbackGeneration
        playbackTask = Task { [self] in
            do {
                try await prepareVideoSourceAudio()
                let frozen = project
                let assets = try resolvedAssets(), canvas = document.canvas!
                let file = root.appendingPathComponent("Previews/\(UUID().uuidString).mp4")
                _ = try await videoDelivery.export(document: frozen.prepared!, assetURLs: assets,
                    options: .init(width: max(2, canvas.width / 4 / 2 * 2), height: max(2, canvas.height / 4 / 2 * 2), frameRate: document.trackGraph.frameRate?.seconds ?? 30), destination: file)
                guard !Task.isCancelled, generation == playbackGeneration, frozen.revision == project.revision else {
                    try? FileManager.default.removeItem(at: file); return
                }
                try authority.acquirePlayback(); playbackAuthority = authority
                playbackFile = file
                let previewPlayer = AVPlayer(url: file)
                player = previewPlayer
                await previewPlayer.seek(to: .init(seconds: playhead, preferredTimescale: 90_000))
                guard !Task.isCancelled, generation == playbackGeneration,
                      frozen.revision == project.revision, player === previewPlayer else { return }
                previewPlayer.play()
            } catch { if !Task.isCancelled { diagnostic = error.localizedDescription } }
        }
    }
    func stopPlayback() {
        playbackGeneration = UUID(); playbackTask?.cancel(); playbackTask = nil
        player?.pause(); player = nil; playbackAuthority?.releasePlayback(); playbackAuthority = nil
        if let file = playbackFile { playbackFile = nil; try? FileManager.default.removeItem(at: file) }
    }
}
#endif
