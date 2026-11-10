// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import CoreImage
import FloeCore
import FloeTools
import FloeWorkbench

struct MediaV2ImageWarpReceipt: Codable, Sendable {
    let source: MediaImageWarpGeometry
    let mode: MediaImageWarpMode
    let destination: MediaImageWarpQuad?
    let applied: Bool
}
struct MediaV2WarpSelectionDelta {
    let layerID: UUID
    private let before: Data?
    private let after: Data?
    init(layerID: UUID, before: ImageSelection?, after: ImageSelection?) throws {
        self.layerID = layerID
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        self.before = try before.map { try encoder.encode($0) }
        self.after = try after.map { try encoder.encode($0) }
    }
    func restored(current: ImageSelection?, redo: Bool) throws -> ImageSelection?? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try current.map({ try encoder.encode($0) }) == (redo ? before : after) else { return nil }
        return .some(try (redo ? after : before).map { try JSONDecoder().decode(ImageSelection.self,from: $0) })
    }
}

extension MediaV2Session {
    static let imageWarpToolIDs: Set<String> = ["image.perspective", "image.distort"]
    func performImageWarpTool(_ toolID: String, input: MediaV2ToolInput, layer: MediaPreparedLayer?, region: ImageSelection?,
        actor: MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard Self.imageWarpToolIDs.contains(toolID), !processingTool, !saving, !canvasLayoutInProgress, let layer, layer.parentID == nil,
              !layer.isLocked, layer.isVisible, ![MediaPreparedLayerContentKind.group, .adjustment].contains(layer.contentKind),
              project.kind == .image else {
            throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("请选择画布顶层可见、未锁定的图片、文字或图形图层。", "Select a visible, unlocked image, text, or shape layer at the top level of the canvas."))
        }
        if let fence = input.selectionFence {
            guard try StudioMediaObservation.media(self).selectionFence == fence else { throw MediaPreparedCoreError.documentChanged }
        }
        let inspect = input.property == "inspect"
        guard input.property == nil || input.property == "apply" || inspect else { throw MediaV2CommandError.invalidInput }
        if !inspect {
            guard input.points?.count == 4, let hash = input.text, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("请先读取变形范围，再应用四个控制点。", "Read the transform bounds before applying four control points."))
            }
        }
        let base = document.revision, originalSelection = selection, token = CancellationToken()
        let mode: MediaImageWarpMode = toolID == "image.perspective" ? .perspective : .bilinear
        processingTool = true
        let worker = Task { @MainActor in
            let frozen = document, assets = try resolvedAssets()
            let bindings = try await MediaV2WarpPixels.shared.captureSources(document: frozen, layerID: layer.id, root: root, assetURLs: assets, token: token)
            let source = try await renderedLayerImage(layer, revision: base)
            let coverage = try await MediaV2WarpPixels.shared.coverage(region, width: source.width, height: source.height, token: token)
            let geometry = try await MediaV2WarpPixels.shared.geometry(source, coverage: coverage, token: token)
            try token.throwIfCancelled(); guard document.revision == base, selection == originalSelection else { throw MediaPreparedCoreError.documentChanged }
            if inspect {
                try await MediaV2WarpPixels.shared.validateSources(bindings, token: token)
                return MediaV2ToolReceipt(documentID: id, revision: base, toolID: toolID, groupID: nil, selectionOnly: true,
                    imageWarp: .init(source: geometry, mode: mode, destination: nil, applied: false))
            }
            guard geometry.pixelSHA256 == input.text else { throw MediaPreparedCoreError.documentChanged }
            let quad = try MediaImageWarpQuad(points: input.points!.map { .init(x: $0.x, y: $0.y) })
            let result = try await MediaV2WarpPixels.shared.apply(source, mode: mode, quad: quad, coverage: coverage, token: token)
            let moved = try await MediaV2WarpPixels.shared.selection(result.transformedCoverage, token: token)
            try await MediaV2WarpPixels.shared.validateSources(bindings, token: token)
            try token.throwIfCancelled(); try Task.checkCancellation()
            guard document.revision == base, selection == originalSelection else { throw MediaPreparedCoreError.documentChanged }
            let selectionDelta = region != nil ? try MediaV2WarpSelectionDelta(layerID: layer.id, before: originalSelection, after: moved) : nil
            let commit = try await commitRenderedImage(result.image, replacing: layer, revision: base, actor: actor)
            if region != nil, selectedLayerID == layer.id, selection == originalSelection {
                if let selectionDelta {
                    imageWarpSelections[commit.groupID] = selectionDelta; imageWarpSelectionOrder.append(commit.groupID)
                    while imageWarpSelectionOrder.count > 16 { imageWarpSelections.removeValue(forKey: imageWarpSelectionOrder.removeFirst()) }
                }
                selection = moved
            }
            if imageWarpDraft?.revision == base, imageWarpDraft?.layer.id == layer.id { imageWarpDraft?.cancelPreview(); imageWarpDraft = nil }
            return MediaV2ToolReceipt(documentID: id, revision: commit.revision, toolID: toolID, groupID: commit.groupID, selectionOnly: false,
                imageWarp: .init(source: result.source, mode: mode, destination: quad, applied: true))
        }
        cancelToolWork = { token.cancel(); worker.cancel() }
        defer { processingTool = false; cancelToolWork = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { token.cancel(); worker.cancel() }
    }

    /// UI selection restoration is keyed by the actual canonical journal
    /// group. It is not a second undo journal and never overwrites a later
    /// independent selection or another selected layer's editor state.
    func restoreImageWarpSelection(groupID: UUID, redo: Bool) {
        guard let delta = imageWarpSelections[groupID], selectedLayerID == delta.layerID else { return }
        do { if let restored = try delta.restored(current: selection, redo: redo) { selection = restored } } catch { /* Keep the current independent UI selection. */ }
    }
    func discardImageWarpDraft() { imageWarpDraft?.cancelPreview(); imageWarpDraft = nil }
}

struct MediaV2WarpSourceBinding: Sendable {
    let url: URL
    let byteCount: Int
    let sha256: String
    let root: URL
}
struct MediaV2WarpPreviewInput: Sendable {
    let geometry: MediaImageWarpGeometry
    let source: CGImage
    let coverage: CGImage?
}

/// Owns raw source hashing, masks and native raster work away from MainActor.
/// Its callers retain the App's normal document/task/selection authority.
actor MediaV2WarpPixels {
    static let shared = MediaV2WarpPixels()
    func captureSources(document: MediaPreparedDocument, layerID: UUID, root: URL, assetURLs: [UUID: URL], token: CancellationToken) throws -> [MediaV2WarpSourceBinding] {
        var visited = Set<UUID>(), assetIDs = Set<UUID>()
        func visit(_ id: UUID) throws {
            guard visited.count <= 128, let layer = document.layer(id) else { throw MediaV2CommandError.invalidInput }
            guard visited.insert(id).inserted else { return }
            if case .raster(let raster) = layer.content, case .asset(let assetID) = raster.source { assetIDs.insert(assetID) }
            if layer.contentKind == .group { for child in document.layers where child.parentID == layer.id { try visit(child.id) } }
            if let clip = layer.clip { try visit(clip.baseLayerID) }
        }
        try visit(layerID)
        guard assetIDs.count <= 64 else { throw MediaV2CommandError.invalidInput }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var result: [MediaV2WarpSourceBinding] = [], total = 0
        for id in assetIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation(); try token.throwIfCancelled()
            guard let asset = document.asset(id), let raw = assetURLs[id] else { throw MediaV2CommandError.missingSelection }
            let url = raw.resolvingSymlinksInPath().standardizedFileURL, values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard url.path.hasPrefix(canonicalRoot.path + "/"), values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= 512 * 1_024 * 1_024 else { throw MediaV2CommandError.invalidInput }
            total += size; guard total <= 1_024 * 1_024 * 1_024 else { throw MediaV2CommandError.invalidInput }
            let hash = try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: { token.isCancelled })
            guard asset.contentHash.map({ $0 == hash }) ?? true, asset.byteCount.map({ $0 == Int64(size) }) ?? true else { throw MediaPreparedCoreError.documentChanged }
            result.append(.init(url: url, byteCount: size, sha256: hash, root: canonicalRoot))
        }
        return result
    }
    func validateSources(_ bindings: [MediaV2WarpSourceBinding], token: CancellationToken) throws {
        for binding in bindings {
            try Task.checkCancellation(); try token.throwIfCancelled()
            let canonical = binding.url.resolvingSymlinksInPath().standardizedFileURL
            let values = try canonical.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard canonical == binding.url, canonical.path.hasPrefix(binding.root.path + "/"), values.isRegularFile == true,
                  values.fileSize == binding.byteCount,
                  try FloeDigest.sha256Hex(ofFileAt: canonical, isCancelled: { token.isCancelled }) == binding.sha256 else { throw MediaPreparedCoreError.documentChanged }
        }
    }
    func coverage(_ selection: ImageSelection?, width: Int, height: Int, token: CancellationToken) throws -> CGImage? {
        try token.throwIfCancelled(); guard let selection else { return nil }
        guard let image = ImageSelectionRasterizer.maskImage(for: selection, canvas: .init(width: width, height: height)),
              let mask = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                .createCGImage(image, from: .init(x: 0,y: 0,width: width,height: height), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else { throw MediaV2CommandError.invalidInput }
        try token.throwIfCancelled(); return mask
    }
    func geometry(_ image: CGImage, coverage: CGImage?, token: CancellationToken) throws -> MediaImageWarpGeometry {
        try MediaNativeImageWarp.geometry(image, coverage: coverage, work: .init(isCancelled: { token.isCancelled }))
    }
    func apply(_ image: CGImage, mode: MediaImageWarpMode, quad: MediaImageWarpQuad, coverage: CGImage?, token: CancellationToken) throws -> MediaImageWarpResult {
        try MediaNativeImageWarp.apply(image, mode: mode, destination: quad, coverage: coverage, work: .init(isCancelled: { token.isCancelled }))
    }
    func previewInput(_ image: CGImage, coverage: CGImage?, token: CancellationToken) throws -> MediaV2WarpPreviewInput {
        let geometry = try geometry(image, coverage: coverage, token: token)
        let resized = try resize(image, maximumEdge: 1_024)
        let mask = try coverage.map { try resize($0, maximumEdge: 1_024, colorManaged: false) }
        try token.throwIfCancelled(); return .init(geometry: geometry, source: resized, coverage: mask)
    }
    func selection(_ mask: CGImage?, token: CancellationToken) throws -> ImageSelection? {
        try token.throwIfCancelled(); guard let mask else { return nil }
        let image = try resize(mask, maximumEdge: 2_048, colorManaged: false), w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0,count: w*h*4)
        let success = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy);context.draw(image,in: .init(x: 0,y: 0,width: w,height: h));return true
        }
        guard success else { throw MediaV2CommandError.invalidInput }
        try token.throwIfCancelled()
        return try .init(bitmap: .init(width: w,height: h,alpha: Data(stride(from: 3,to: pixels.count,by: 4).map { pixels[$0] })))
    }
    private func resize(_ image: CGImage, maximumEdge: Int, colorManaged: Bool = true) throws -> CGImage {
        let scale = min(1,Double(maximumEdge)/Double(max(image.width,image.height)))
        guard scale < 1 else { return image }
        let options: [CIContextOption: Any] = colorManaged ? [.cacheIntermediates: false] : [.cacheIntermediates: false,.workingColorSpace: NSNull(),.outputColorSpace: NSNull()]
        let input = CIImage(cgImage: image, options: colorManaged ? [:] : [.colorSpace: NSNull()]).transformed(by: .init(scaleX: scale,y: scale))
        guard let output = CIContext(options: options).createCGImage(input,from: input.extent,format: .RGBA8,colorSpace: CGColorSpaceCreateDeviceRGB()) else { throw MediaV2CommandError.invalidInput }
        return output
    }
}
#endif
