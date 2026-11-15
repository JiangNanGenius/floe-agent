// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import CoreGraphics
import FloeGameCore
import FloeGameEditingCore

/// Main-actor state for the native PNG/sprite editor. Every pixel write goes
/// through `GameEditingSession.editDocument`; this model owns no repository,
/// save or undo stack of its own. The UI previews one gesture cheaply and the
/// commit applies that operation to the session's fresh bytes.
@MainActor
public final class SpriteEditorDocument: ObservableObject {
    public let session: GameEditingSession
    public let path: GameRelativePath
    public let limits: SpritePNGLimits

    @Published public private(set) var image: SpritePixelImage?
    @Published public private(set) var renderedImage: CGImage?
    @Published public private(set) var layout: SpriteSheetLayout?
    @Published public private(set) var selectedFrameIndex: Int = 0
    @Published public private(set) var isLoading = true
    @Published public private(set) var isCommitting = false
    @Published public private(set) var issue: SpriteEditorIssue?
    @Published public private(set) var status: GameEditCopy?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var playbackStep: Int = 0
    @Published public private(set) var fillPreview: SpritePixelImage?
    @Published public private(set) var fillPreviewImage: CGImage?
    @Published public private(set) var activeStrokeTool: SpriteTool?
    @Published public private(set) var strokeRevision: Int = 0
    @Published public private(set) var hasUnsavedChanges = false

    @Published public var tool: SpriteTool = .brush
    @Published public var color: SpriteRGBA = .black
    @Published public var brushSize: Int = 1
    @Published public var fingerDrawingEnabled = false
    @Published public var showsGrid = true
    @Published public var framesPerSecond: Double = 8

    public private(set) var activeStroke: SpriteStroke?

    private var loadedDigest: String?
    private var loadToken = UUID()
    private var refreshToken = UUID()
    private var refreshTask: Task<Void, Never>?
    private var frameImageCache: [Int: CGImage] = [:]

    public init(session: GameEditingSession, path: GameRelativePath,
                limits: SpritePNGLimits = .default) {
        self.session = session
        self.path = path
        self.limits = limits
    }

    // MARK: - Queries

    public var selectedFrameRect: SpritePixelRect? {
        layout?.frameRect(at: selectedFrameIndex)
    }

    public var selectedFrame: SpriteFrameDescriptor? {
        layout?.descriptor(at: selectedFrameIndex)
    }

    public var framePixelSize: SpritePixelSize? {
        layout.map { SpritePixelSize(width: $0.frameWidth, height: $0.frameHeight) }
    }

    public var animationFrameIndices: [Int] {
        guard let layout else { return [] }
        return layout.animationFrameIndices(containing: selectedFrameIndex)
    }

    public var animationSequence: SpriteAnimationSequence? {
        try? SpriteAnimationSequence(frameIndices: animationFrameIndices,
                                     framesPerSecond: clampedFramesPerSecond)
    }

    public var clampedFramesPerSecond: Double {
        guard framesPerSecond.isFinite else { return 8 }
        return min(max(framesPerSecond, SpriteAnimationSequence.minimumFramesPerSecond),
                   SpriteAnimationSequence.maximumFramesPerSecond)
    }

    public var clampedBrushSize: Int { min(max(brushSize, 1), 8) }

    /// Frame shown on the canvas and preview. During playback this is the
    /// animated frame; otherwise it is the explicitly selected frame.
    public var highlightedFrameIndex: Int {
        if isPlaying, let sequence = animationSequence,
           let index = sequence.frameIndex(atStep: playbackStep) {
            return index
        }
        return selectedFrameIndex
    }

    public var selectedFrameRectInPlayback: SpritePixelRect? {
        layout?.frameRect(at: highlightedFrameIndex)
    }

    public func frameImage(at index: Int) -> CGImage? {
        guard let renderedImage, let layout, let rect = layout.frameRect(at: index) else { return nil }
        if let cached = frameImageCache[index] { return cached }
        guard let cropped = renderedImage.cropping(to: rect.cgRect) else { return nil }
        if frameImageCache.count >= 256 { frameImageCache.removeAll(keepingCapacity: true) }
        frameImageCache[index] = cropped
        return cropped
    }

    public var previewFrameImage: CGImage? { frameImage(at: highlightedFrameIndex) }

    public var canEditImage: Bool {
        !isLoading && !isCommitting && !session.isBusy
            && session.pendingDraft == nil && session.conflict == nil
            && session.fileConflicts.isEmpty
    }

    public func clearIssue() { issue = nil }
    public func clearStatus() { status = nil }

    // MARK: - Load / session refresh

    public func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        issue = nil
        defer {
            if token == loadToken { isLoading = false }
        }
        do {
            let bytes = try await session.documentBytes(at: path)
            let digest = GameDigest.sha256(bytes)
            let decoded = try await decodeOffMain(bytes)
            guard token == loadToken, !Task.isCancelled else { return }
            guard let newLayout = layoutPreservingCurrent(for: decoded.size) else {
                throw SpriteEditorIssue(title: GameEditCopy("Frame grid unavailable", "帧网格不可用"),
                    diagnostics: [GameEditDiagnostic(severity: .error,
                        message: GameEditCopy("This image does not fit a usable frame grid.",
                                              "此图片无法建立可用的帧网格。"), path: path)])
            }
            applyLoaded(decoded, digest: digest, layout: newLayout)
            hasUnsavedChanges = session.isDocumentDirty(at: path)
        } catch is CancellationError {
            return
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
        }
    }

    /// Re-reads the session after undo, draft recovery or an external change.
    /// It is intentionally ignored while a gesture is in flight; the gesture
    /// commit then starts from the session's fresh bytes instead of a stale
    /// full-sheet copy.
    public func refreshFromSession() async {
        guard !isLoading, !isCommitting, activeStroke == nil else { return }
        let token = UUID()
        refreshToken = token
        do {
            let bytes = try await session.documentBytes(at: path)
            let digest = GameDigest.sha256(bytes)
            guard digest != loadedDigest else {
                hasUnsavedChanges = session.isDocumentDirty(at: path)
                return
            }
            let decoded = try await decodeOffMain(bytes)
            guard token == refreshToken, activeStroke == nil, !isCommitting else { return }
            guard let newLayout = layoutPreservingCurrent(for: decoded.size) else {
                throw SpriteEditorIssue(title: GameEditCopy("Frame grid unavailable", "帧网格不可用"),
                    diagnostics: [GameEditDiagnostic(severity: .error,
                        message: GameEditCopy("This image does not fit a usable frame grid.",
                                              "此图片无法建立可用的帧网格。"), path: path)])
            }
            applyLoaded(decoded, digest: digest, layout: newLayout)
        } catch is CancellationError {
            return
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
        }
    }

    /// Coalesces session notifications so a busy/undo/save burst does not
    /// decode the full PNG repeatedly.
    public func scheduleSessionRefresh() {
        hasUnsavedChanges = session.isDocumentDirty(at: path)
        guard activeStroke == nil, !isCommitting else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.refreshFromSession()
        }
    }

    public func detach() {
        refreshTask?.cancel()
        refreshTask = nil
        stopPlayback()
        cancelStroke()
    }

    private func decodeOffMain(_ bytes: Data) async throws -> SpritePixelImage {
        let limits = self.limits
        return try await Task.detached(priority: .userInitiated) {
            try SpritePNG.decode(bytes, limits: limits)
        }.value
    }

    private func applyLoaded(_ image: SpritePixelImage, digest: String, layout: SpriteSheetLayout) {
        cancelStroke()
        issue = nil
        self.image = image
        renderedImage = image.makeCGImage()
        self.layout = layout
        selectedFrameIndex = min(max(selectedFrameIndex, 0), max(0, layout.frameCount - 1))
        loadedDigest = digest
        frameImageCache.removeAll(keepingCapacity: true)
        playbackStep = 0
        if let sequence = animationSequence, !sequence.isAnimatable { isPlaying = false }
        hasUnsavedChanges = session.isDocumentDirty(at: path)
    }

    private func layoutPreservingCurrent(for size: SpritePixelSize) -> SpriteSheetLayout? {
        if let layout, let valid = try? layout.validated(for: size) { return valid }
        if let layout, let custom = try? SpriteSheetLayout.custom(
            for: size, columns: layout.columns, rows: layout.rows) {
            return custom
        }
        if let detected = SpriteSheetLayout.detected(for: size) { return detected }
        return try? SpriteSheetLayout.custom(for: size, columns: 1, rows: 1)
    }

    // MARK: - Layout

    public func applyPreset(_ preset: SpriteSheetPreset, scope: SpriteSheetScope) {
        guard let image else { return }
        guard preset != .custom else { return }
        do {
            let newLayout = try SpriteSheetLayout.applying(preset, scope: scope, to: image.size)
            setLayout(newLayout, copy: GameEditCopy("Frame grid updated; pixels were not resized.",
                                                   "帧网格已更新；像素没有被缩放。"))
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
        }
    }

    public func applyCustomGrid(columns: Int, rows: Int) {
        guard let image else { return }
        do {
            let newLayout = try SpriteSheetLayout.custom(for: image.size, columns: columns, rows: rows)
            setLayout(newLayout, copy: GameEditCopy("Custom frame grid applied.",
                                                   "已应用自定义帧网格。"))
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
        }
    }

    public func useDetectedLayout() {
        guard let image else { return }
        if let detected = SpriteSheetLayout.detected(for: image.size) {
            setLayout(detected, copy: GameEditCopy("Detected a common character-sheet grid.",
                                                   "已识别常见的角色图集网格。"))
        } else {
            issue = SpriteEditorIssue(
                title: GameEditCopy("No preset matches", "没有匹配的预设"),
                diagnostics: [GameEditDiagnostic(severity: .warning,
                    message: GameEditCopy("This image has no common XP/VX/MV/MZ grid. Use a custom grid.",
                                          "此图片不符合常见的 XP/VX/MV/MZ 网格，请使用自定义网格。"),
                    path: path)])
        }
    }

    private func setLayout(_ newLayout: SpriteSheetLayout, copy: GameEditCopy) {
        guard let currentImage = image else { return }
        guard (try? newLayout.validated(for: currentImage.size)) != nil else {
            issue = SpriteEditorIssue.make(SpriteSheetError.dimensionsMismatch(
                width: currentImage.width, height: currentImage.height,
                columns: newLayout.columns, rows: newLayout.rows), path: path)
            return
        }
        layout = newLayout
        selectedFrameIndex = min(selectedFrameIndex, max(0, newLayout.frameCount - 1))
        playbackStep = 0
        frameImageCache.removeAll(keepingCapacity: true)
        if let sequence = animationSequence, !sequence.isAnimatable { isPlaying = false }
        status = copy
    }

    public func selectFrame(_ index: Int) {
        guard let layout else { return }
        selectedFrameIndex = min(max(index, 0), max(0, layout.frameCount - 1))
        playbackStep = 0
        if let sequence = animationSequence, !sequence.isAnimatable { isPlaying = false }
    }

    /// Adds a lossless PNG of the selected frame to the same project folder.
    /// Source bytes, ownership, undo and saving remain in the shared session.
    @discardableResult
    public func addSelectedFrameAsAsset() async -> GameRelativePath? {
        guard canEditImage, activeStroke == nil, let layout,
              let rect = layout.frameRect(at: selectedFrameIndex) else { return nil }
        let frameNumber = selectedFrameIndex + 1
        isCommitting = true
        defer { isCommitting = false }
        do {
            let bytes = try await session.documentBytes(at: path)
            let current = try await decodeOffMain(bytes)
            _ = try layout.validated(for: current.size)
            guard let cropped = current.cropped(to: rect) else {
                throw SpritePixelError.invalidCrop
            }
            let limits = self.limits
            let png = try await Task.detached(priority: .userInitiated) {
                try SpritePNG.encode(cropped, limits: limits)
            }.value
            try Task.checkCancellation()
            let parts = path.value.split(separator: "/").map(String.init)
            let folder = parts.dropLast().joined(separator: "/")
            let stem = ((parts.last ?? "sprite") as NSString).deletingPathExtension
            let baseName = stem + "-frame-" + String(format: "%04d", frameNumber)
            let existing = Set(session.existingPaths().map {
                $0.value.precomposedStringWithCanonicalMapping.lowercased()
            })
            for suffix in 0..<1_000 {
                let name = baseName + (suffix == 0 ? "" : "-\(suffix + 1)") + ".png"
                let target = try GameRelativePath(folder.isEmpty ? name : folder + "/" + name)
                guard !existing.contains(target.value.precomposedStringWithCanonicalMapping.lowercased()) else { continue }
                let added = try await session.importAssets([(name: name, bytes: png)],
                                                          into: folder.isEmpty ? nil : folder)
                guard let result = added.first else { return nil }
                status = GameEditCopy("Added \(result.value)", "已添加 \(result.value)")
                return result
            }
            throw GameProjectError.destinationExists
        } catch is CancellationError {
            return nil
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
            return nil
        }
    }

    // MARK: - Colors and tools

    public func setColorRGB(_ value: SpriteRGBA, preservingAlpha: Bool = true) {
        var next = value
        if preservingAlpha { next.alpha = color.alpha }
        color = next
    }

    public func setColorAlpha(_ alpha: UInt8) {
        color.alpha = alpha
    }

    // MARK: - Pixel gestures

    @discardableResult
    public func beginStroke(at point: SpritePixelPoint) -> Bool {
        guard canEditImage, activeStroke == nil, let image, let layout,
              let frameRect = layout.frameRect(at: selectedFrameIndex) else { return false }
        guard image.bounds.contains(point) else { return false }
        switch tool {
        case .eyedropper:
            guard let picked = image.color(at: point) else { return false }
            color = picked
            status = GameEditCopy("Picked RGBA \(picked.hexString).", "已取色 RGBA \(picked.hexString)。")
            return true
        case .fill:
            guard frameRect.contains(point) else { return false }
            let stroke = SpriteStroke(tool: .fill, color: color, brushSize: clampedBrushSize,
                                      clip: frameRect, frameIndex: selectedFrameIndex,
                                      originalSize: image.size, seed: point, image: image)
            activeStroke = stroke
            activeStrokeTool = .fill
            fillPreview = stroke.fillPreview
            fillPreviewImage = stroke.fillPreview?.makeCGImage()
            strokeRevision += 1
            return true
        case .brush, .eraser:
            guard frameRect.contains(point) else { return false }
            let stroke = SpriteStroke(tool: tool, color: color, brushSize: clampedBrushSize,
                                      clip: frameRect, frameIndex: selectedFrameIndex,
                                      originalSize: image.size, seed: point, image: image)
            activeStroke = stroke
            activeStrokeTool = tool
            strokeRevision += 1
            return true
        }
    }

    public func continueStroke(to point: SpritePixelPoint) {
        guard let stroke = activeStroke, let image else { return }
        guard stroke.tool != .fill else { return }
        let clamped = SpriteGeometry.clamped(point, to: image.bounds) ?? point
        stroke.append(clamped)
        strokeRevision += 1
    }

    public func endStroke() async {
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        activeStrokeTool = nil
        fillPreview = nil
        fillPreviewImage = nil
        strokeRevision += 1
        guard stroke.tool.editsPixels else { return }

        isCommitting = true
        defer { isCommitting = false }
        var committedImage: SpritePixelImage?
        do {
            try await session.editDocument(at: path, summary: stroke.summary) { current in
                var target = try SpritePNG.decode(current, limits: self.limits)
                guard target.size == stroke.originalSize else {
                    throw SpriteEditorIssue(
                        title: GameEditCopy("The image changed size", "图片尺寸已变化"),
                        diagnostics: [GameEditDiagnostic(severity: .error,
                            message: GameEditCopy("The sheet changed while this stroke was active. The stroke was not applied.",
                                                  "绘制期间图集尺寸发生变化，本次笔画未应用。"),
                            path: self.path)])
                }
                _ = stroke.apply(to: &target)
                let encoded = try SpritePNG.encode(target, limits: self.limits)
                committedImage = target
                return encoded
            }
            guard let committedImage else { return }
            let bytes = try await session.documentBytes(at: path)
            let digest = GameDigest.sha256(bytes)
            guard let newLayout = layoutPreservingCurrent(for: committedImage.size) else { return }
            applyLoaded(committedImage, digest: digest, layout: newLayout)
            status = stroke.tool.summary
        } catch is CancellationError {
            return
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
            isCommitting = false
            await refreshFromSession()
        }
    }

    public func cancelStroke() {
        guard activeStroke != nil || fillPreview != nil else { return }
        activeStroke = nil
        activeStrokeTool = nil
        fillPreview = nil
        fillPreviewImage = nil
        strokeRevision += 1
    }

    // MARK: - Whole-image transforms

    public func flipHorizontally() async {
        await transform(GameEditCopy("Flip horizontally", "水平翻转"),
                        layout: nil) { $0.flippedHorizontally() }
    }

    public func flipVertically() async {
        await transform(GameEditCopy("Flip vertically", "垂直翻转"),
                        layout: nil) { $0.flippedVertically() }
    }

    public func rotateClockwise() async {
        guard let oldLayout = layout else { return }
        let rotated = oldLayout.transposedForRotation()
        await transform(GameEditCopy("Rotate clockwise", "顺时针旋转"),
                        layout: rotated) { $0.rotated90Clockwise() }
    }

    public func rotateCounterclockwise() async {
        guard let oldLayout = layout else { return }
        let rotated = oldLayout.transposedForRotation()
        await transform(GameEditCopy("Rotate counterclockwise", "逆时针旋转"),
                        layout: rotated) { $0.rotated90Counterclockwise() }
    }

    private func transform(_ summary: GameEditCopy,
                           layout requestedLayout: SpriteSheetLayout?,
                           _ body: @escaping (SpritePixelImage) -> SpritePixelImage) async {
        guard canEditImage, let image else { return }
        isCommitting = true
        defer { isCommitting = false }
        var transformedImage: SpritePixelImage?
        do {
            try await session.editDocument(at: path, summary: summary) { current in
                let target = try SpritePNG.decode(current, limits: self.limits)
                guard target.size == image.size else {
                    throw SpriteEditorIssue(
                        title: GameEditCopy("The image changed size", "图片尺寸已变化"),
                        diagnostics: [GameEditDiagnostic(severity: .error,
                            message: GameEditCopy("The sheet changed elsewhere; reload and try again.",
                                                  "图集在其他地方有改动，请重新载入后再试。"),
                            path: self.path)])
                }
                let result = body(target)
                transformedImage = result
                return try SpritePNG.encode(result, limits: self.limits)
            }
            guard let transformedImage else { return }
            let bytes = try await session.documentBytes(at: path)
            let digest = GameDigest.sha256(bytes)
            let layout = requestedLayout.flatMap { try? $0.validated(for: transformedImage.size) }
                ?? layoutPreservingCurrent(for: transformedImage.size)
            guard let layout else { return }
            applyLoaded(transformedImage, digest: digest, layout: layout)
            status = summary
        } catch is CancellationError {
            return
        } catch {
            issue = SpriteEditorIssue.make(error, path: path)
            isCommitting = false
            await refreshFromSession()
        }
    }

    // MARK: - Animation

    public func startPlayback() {
        guard let sequence = animationSequence, sequence.isAnimatable else {
            status = GameEditCopy("This frame row has only one frame.",
                                  "此帧行只有一帧，无法播放动画。")
            return
        }
        isPlaying = true
        playbackStep = 0
    }

    public func stopPlayback() {
        isPlaying = false
        playbackStep = 0
    }

    public func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    public func advancePlayback() {
        guard isPlaying, let sequence = animationSequence, sequence.isAnimatable else { return }
        playbackStep = (playbackStep + 1) % sequence.frameCount
    }

    /// The view runs this only while visible. Cancelling the view task (or
    /// `stopPlayback`) ends the loop, so a hidden editor never animates.
    public func runPlaybackLoop() async {
        while !Task.isCancelled && isPlaying {
            let fps = clampedFramesPerSecond
            do {
                try await Task.sleep(for: .seconds(1.0 / fps))
            } catch {
                break
            }
            guard !Task.isCancelled, isPlaying else { break }
            advancePlayback()
        }
    }
}
