// FloeWorkbench — Shared, validated edit commands.
//
// Both the SwiftUI workbench and the model-facing `media.project` tool
// mutate projects exclusively through `MediaEditCommand`. Commands validate
// their arguments, apply one undoable transaction to the document and are
// the single place where structural rules live.

import Foundation
import FloeCore

/// Explicit three-way update for nullable fields (distinguishes "leave
/// unchanged" from "clear the value" across the Codable proposal boundary).
public enum OptionalUpdate<Value: Sendable & Codable & Hashable>: Sendable, Codable, Hashable {
    case unchanged
    case clear
    case set(Value)
}

public enum MediaEditCommand: Sendable, Codable, Hashable {
    // Project / assets
    case addAsset(MediaAssetReference)
    case relinkAsset(assetID: UUID, relativePath: String)
    case setCanvas(width: Int, height: Int, frameRate: Double?)

    // Image layers
    case addImageLayer(ImageLayer)
    case updateLayer(id: UUID, transform: ImageLayerTransform?, opacity: Double?, isHidden: Bool?,
                     isLocked: Bool?, adjustment: ImageLayerAdjustment?, text: ImageTextContent?,
                     crop: OptionalUpdate<NormalizedRect>)
    case reorderLayers(orderedIDs: [UUID])
    case moveLayer(id: UUID, toIndex: Int)
    case removeLayer(id: UUID)
    /// Duplicates a layer directly after its original with a fresh identity.
    case duplicateLayer(id: UUID, name: String?)
    /// Appends a brush stroke to an existing freehand layer (bounded).
    case addFreehandStroke(id: UUID, stroke: ImageFreehandStroke)
    /// Sets the project-wide vector selection (nil clears it). Undoable.
    case setImageSelection(ImageSelection?)
    /// Sets a single layer's selection-limiting mask (`.clear` removes it).
    case setLayerSelectionMask(id: UUID, selection: OptionalUpdate<ImageSelection>)
    /// Appends a non-destructive erase/restore mask stroke to a layer.
    case addLayerMaskStroke(id: UUID, stroke: ImageMaskStroke)
    /// Removes every mask stroke from a layer.
    case clearLayerMask(id: UUID)
    /// Toggles a non-destructive horizontal/vertical mirror flag on a layer.
    case flipLayer(id: UUID, horizontal: Bool)
    /// Aligns the rendered edges/centers of two or more layers. Locked layers
    /// are rejected. `naturalSizes` are renderer-measured untransformed layer
    /// sizes in canvas-unit space; alignment moves only transform anchors.
    case alignLayers(ids: [UUID], alignment: LayerAlignment, naturalSizes: [LayerNaturalSize])
    /// Raster-merges two or more contiguous visible layers into one full-canvas
    /// transparent image layer. `raster` is the renderer-produced snapshot
    /// (a persisted image asset). Original layers stay in undo history, so the
    /// merge is reversible; no screenshot of the screen is used.
    case mergeLayers(ids: [UUID], name: String?, raster: MergedLayerRaster)
    /// Fills the current project selection with a solid color as a new
    /// `.fill` layer (masked by the selection). UI entry 选区填充.
    case fillSelection(colorHex: String, opacity: Double, name: String?)
    /// Non-destructive cut: appends one region mask stroke erasing the
    /// current selection from the layer. Undo removes the stroke and the
    /// pixels return; the original bytes are never modified.
    case cutSelection(layerID: UUID)
    /// Raster-copies the selected region of one layer into a NEW full-canvas
    /// image layer. `raster` is the renderer-produced masked snapshot (a
    /// persisted image asset); pixels are real content, not a screen capture.
    case copySelection(sourceLayerID: UUID, name: String?, raster: MergedLayerRaster)

    // Whole-canvas effects
    case setCanvasAdjustment(CanvasAdjustment)

    // Video timeline — primary track
    case appendClip(VideoClip)
    case updateClip(id: UUID, trimStart: Double?, trimEnd: Double?, speed: Double?, volume: Double?,
                    isMuted: Bool?, rotationDegrees: Double?, crop: OptionalUpdate<NormalizedRect>,
                    leadingTransition: VideoTransitionKind?, transitionDuration: Double?)
    case reorderClips(orderedIDs: [UUID])
    case splitClip(id: UUID, atTimelineSeconds: Double)
    /// Duplicates a clip directly after its original (fresh identity, same
    /// source range and per-clip options).
    case duplicateClip(id: UUID)
    case removeClip(id: UUID)
    case setPrimaryAudio(volume: Double?, muted: Bool?)
    /// Explicit cover frame in timeline seconds; nil derives the first frame.
    case setCover(time: Double?)
    /// Batch time correction for every caption.
    case shiftCaptions(bySeconds: Double)

    // Music / captions
    case addMusic(MusicClip)
    case updateMusic(id: UUID, offsetSeconds: Double?, trimStart: Double?, lengthSeconds: Double?,
                     volume: Double?, fadeInSeconds: Double?, fadeOutSeconds: Double?)
    case removeMusic(id: UUID)
    case addCaption(CaptionSegment)
    case updateCaption(id: UUID, start: Double?, end: Double?, text: String?)
    case removeCaption(id: UUID)
    case setCaptionStyle(CaptionStyle)
}

/// Layer alignment anchors applied to transform centers in canvas unit space.
public enum LayerAlignment: String, Sendable, Codable, CaseIterable {
    case left, centerX, right
    case top, centerY, bottom

    /// Vertical distribution axis implied by this alignment.
    public var isHorizontal: Bool {
        switch self {
        case .left, .centerX, .right: return true
        case .top, .centerY, .bottom: return false
        }
    }
}

public enum MediaCommandError: Error, Sendable {
    case validation(String)
    case notFound(String)
    case conflict(String)
}

public extension MediaCommandError {
    var floeError: FloeError {
        switch self {
        case .validation(let detail): .validationFailed(detail)
        case .notFound(let what): .notFound(what)
        case .conflict(let detail): .validationFailed(detail)
        }
    }
}

public enum MediaEditCommandApplier {
    /// Validates the command against the current document WITHOUT mutating.
    public static func validate(_ command: MediaEditCommand, in project: MediaProject) throws {
        switch command {
        case .addAsset(let asset):
            guard !asset.relativePath.isEmpty else { throw MediaCommandError.validation("asset path is empty") }
            guard project.assets.contains(where: { $0.id == asset.id }) == false else {
                throw MediaCommandError.conflict("asset already exists")
            }

        case .relinkAsset(let assetID, let path):
            guard project.assets.contains(where: { $0.id == assetID }) else {
                throw MediaCommandError.notFound("asset \(assetID)")
            }
            guard !path.isEmpty else { throw MediaCommandError.validation("relink path is empty") }

        case .setCanvas(let width, let height, let frameRate):
            guard width >= 2, height >= 2, width <= 8192, height <= 8192 else {
                throw MediaCommandError.validation("canvas dimensions must be 2...8192")
            }
            if let frameRate {
                guard frameRate.isFinite, frameRate > 0, frameRate <= 240 else {
                    throw MediaCommandError.validation("frame rate must be in (0, 240]")
                }
            }

        case .addImageLayer(let layer):
            guard project.kind == .image else { throw MediaCommandError.validation("image layers belong to image projects") }
            if let assetID = layer.assetID {
                guard let asset = project.asset(assetID), asset.kind == .image else {
                    throw MediaCommandError.validation("image layer requires an imported image asset")
                }
            }
            try validate(transform: layer.transform, opacity: layer.opacity)
            switch layer.kind {
            case .text:
                guard let text = layer.text, !text.text.isEmpty else {
                    throw MediaCommandError.validation("text layer requires text")
                }
                try validateText(text)
            case .freehand:
                guard let freehand = layer.freehand, !freehand.strokes.isEmpty else {
                    throw MediaCommandError.validation("freehand layer requires at least one stroke")
                }
                try validateFreehand(freehand)
            case .image:
                guard layer.assetID != nil else {
                    throw MediaCommandError.validation("image layer requires an asset")
                }
            case .fill:
                guard let hex = layer.fillColorHex, !hex.isEmpty else {
                    throw MediaCommandError.validation("fill layer requires a color")
                }
                guard let selection = layer.selectionMask, !selection.isEmpty else {
                    throw MediaCommandError.validation("fill layer requires a selection")
                }
            }
            if let mask = layer.mask { try validateMask(mask) }
            if let selection = layer.selectionMask { try validateSelection(selection) }
            try validateAdjustment(layer.adjustment)

        case .updateLayer(let id, let transform, let opacity, let isHidden, let isLocked, let adjustment, let text, let crop):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if project.imageLayers[index].isLocked
                && (transform != nil || text != nil || adjustment != nil) {
                throw MediaCommandError.conflict("layer is locked; unlock before editing geometry or content")
            }
            if let transform { try validate(transform: transform, opacity: 1) }
            if let opacity { try validate(transform: .init(), opacity: opacity) }
            if let adjustment { try validateAdjustment(adjustment) }
            if let text { try validateText(text) }
            if case .set(let rect) = crop { try validateCrop(rect) }
            _ = isHidden; _ = isLocked

        case .reorderLayers(let orderedIDs):
            guard Set(orderedIDs) == Set(project.imageLayers.map(\.id)), orderedIDs.count == project.imageLayers.count else {
                throw MediaCommandError.validation("reorder must list every layer exactly once")
            }

        case .moveLayer(let id, let toIndex):
            guard project.imageLayers.contains(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            guard project.imageLayers.indices.contains(toIndex) else {
                throw MediaCommandError.validation("layer index out of range")
            }

        case .removeLayer(let id):
            guard project.imageLayers.contains(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }

        case .duplicateLayer(let id, let name):
            guard project.imageLayers.contains(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if let name, name.isEmpty { throw MediaCommandError.validation("layer name must not be empty") }

        case .addFreehandStroke(let id, let stroke):
            guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if layer.isLocked {
                throw MediaCommandError.conflict("layer is locked; unlock before drawing")
            }
            guard layer.kind == .freehand else {
                throw MediaCommandError.validation("brush strokes can only be added to a freehand layer")
            }
            let existing = layer.freehand?.strokes ?? []
            guard existing.count < 200 else {
                throw MediaCommandError.validation("too many strokes (200 max)")
            }
            // Validate a content with every accumulated stroke so the bound is
            // enforced against the real result, not just the new stroke.
            try validateFreehand(ImageFreehandContent(strokes: existing + [stroke]))

        case .setImageSelection(let selection):
            if let selection { try validateSelection(selection) }

        case .setLayerSelectionMask(let id, let update):
            guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if layer.isLocked {
                throw MediaCommandError.conflict("layer is locked; unlock before changing its selection")
            }
            if case .set(let selection) = update { try validateSelection(selection) }

        case .addLayerMaskStroke(let id, let stroke):
            guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if layer.isLocked {
                throw MediaCommandError.conflict("layer is locked; unlock before masking")
            }
            // Validate the FULLY accumulated stroke list (parenthesized so the
            // new stroke is never dropped when a mask already exists).
            let accumulated = (project.imageLayers.first { $0.id == id }?.mask?.strokes ?? []) + [stroke]
            try validateMask(ImageLayerMask(strokes: accumulated))

        case .clearLayerMask(let id):
            guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if layer.isLocked {
                throw MediaCommandError.conflict("layer is locked; unlock before clearing its mask")
            }

        case .flipLayer(let id, _):
            guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if layer.isLocked { throw MediaCommandError.conflict("layer is locked; unlock before flipping") }

        case .alignLayers(let ids, _, let naturalSizes):
            guard ids.count >= 2, Set(ids).count == ids.count else {
                throw MediaCommandError.validation("alignment needs at least two distinct layers")
            }
            guard project.canvas != nil else {
                throw MediaCommandError.validation("canvas must be initialized before aligning layers")
            }
            for id in ids {
                guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                    throw MediaCommandError.notFound("layer \(id)")
                }
                if layer.isLocked {
                    throw MediaCommandError.conflict("layer '\(layer.name)' is locked; unlock before aligning")
                }
                guard naturalSizes.contains(where: { $0.layerID == id }) else {
                    throw MediaCommandError.validation("missing measured size for layer \(id)")
                }
            }

        case .mergeLayers(let ids, let name, let raster):
            guard ids.count >= 2, Set(ids).count == ids.count else {
                throw MediaCommandError.validation("merge needs at least two distinct layers")
            }
            if let name, name.isEmpty { throw MediaCommandError.validation("layer name must not be empty") }
            for id in ids {
                guard let layer = project.imageLayers.first(where: { $0.id == id }) else {
                    throw MediaCommandError.notFound("layer \(id)")
                }
                if layer.isLocked {
                    throw MediaCommandError.conflict("layer '\(layer.name)' is locked; unlock before merging")
                }
            }
            // The host renders the merged pixels through the real pipeline and
            // registers a transparent full-canvas asset referenced here.
            guard let rasterAsset = project.asset(raster.assetID), rasterAsset.kind == .image else {
                throw MediaCommandError.validation(
                    "merge raster asset \(raster.assetID) must be an imported image asset")
            }
            if let hash = rasterAsset.contentHash, let rasterHash = raster.contentHash, hash != rasterHash {
                throw MediaCommandError.conflict("merge raster hash does not match the registered asset")
            }
            guard raster.width > 0, raster.height > 0 else {
                throw MediaCommandError.validation("merge raster dimensions must be positive")
            }

        case .fillSelection(let colorHex, let opacity, let name):
            let selection = try requireSelection(project)
            _ = selection
            guard project.canvas != nil else {
                throw MediaCommandError.validation("fill requires a canvas")
            }
            guard isValidColorHex(colorHex) else {
                throw MediaCommandError.validation("fill color must be a #RRGGBB or #RRGGBBAA hex value")
            }
            guard opacity.isFinite, (0...1).contains(opacity) else {
                throw MediaCommandError.validation("fill opacity must be 0...1")
            }
            if let name, name.isEmpty { throw MediaCommandError.validation("layer name must not be empty") }

        case .cutSelection(let layerID):
            let selection = try requireSelection(project)
            guard let layer = project.imageLayers.first(where: { $0.id == layerID }) else {
                throw MediaCommandError.notFound("layer \(layerID)")
            }
            if layer.isLocked {
                throw MediaCommandError.conflict("layer '\(layer.name)' is locked; unlock before cutting")
            }
            guard !selection.shapes.isEmpty else {
                throw MediaCommandError.validation("cut requires a shaped selection (Select All works)")
            }

        case .copySelection(let sourceLayerID, let name, let raster):
            let selection = try requireSelection(project)
            guard let layer = project.imageLayers.first(where: { $0.id == sourceLayerID }) else {
                throw MediaCommandError.notFound("layer \(sourceLayerID)")
            }
            if layer.isLocked {
                throw MediaCommandError.conflict("layer '\(layer.name)' is locked; unlock before copying")
            }
            guard !selection.shapes.isEmpty else {
                throw MediaCommandError.validation("copy requires a shaped selection (Select All works)")
            }
            if let name, name.isEmpty { throw MediaCommandError.validation("layer name must not be empty") }
            guard let canvas = project.canvas else {
                throw MediaCommandError.validation("copy requires a canvas")
            }
            guard let rasterAsset = project.asset(raster.assetID), rasterAsset.kind == .image else {
                throw MediaCommandError.validation(
                    "copy raster asset \(raster.assetID) must be an imported image asset")
            }
            if let hash = rasterAsset.contentHash, let rasterHash = raster.contentHash, hash != rasterHash {
                throw MediaCommandError.conflict("copy raster hash does not match the registered asset")
            }
            guard raster.width == canvas.width, raster.height == canvas.height else {
                throw MediaCommandError.validation("copy raster must be full-canvas")
            }

        case .setCanvasAdjustment(let adjustment):
            try validateAdjustment(adjustment)

        case .appendClip(let clip):
            guard project.kind == .video else { throw MediaCommandError.validation("clips belong to video projects") }
            guard let asset = project.asset(clip.assetID), asset.kind == .video else {
                throw MediaCommandError.validation("clip requires an imported video asset")
            }
            try validate(clip: clip, asset: asset)

        case .updateClip(let id, let trimStart, let trimEnd, let speed, let volume, let isMuted,
                         let rotation, let crop, let transition, let transitionDuration):
            guard let clip = project.videoTimeline?.clips.first(where: { $0.id == id }),
                  let asset = project.asset(clip.assetID) else {
                throw MediaCommandError.notFound("clip \(id)")
            }
            var candidate = clip
            if let trimStart { candidate.trimStart = trimStart }
            if let trimEnd { candidate.trimEnd = trimEnd }
            if let speed { candidate.speed = speed }
            if let volume { candidate.volume = volume }
            if let isMuted { candidate.isMuted = isMuted }
            if let rotation { candidate.rotationDegrees = rotation }
            switch crop {
            case .unchanged: break
            case .clear: candidate.crop = nil
            case .set(let rect): candidate.crop = rect
            }
            if let transition { candidate.leadingTransition = transition }
            if let transitionDuration { candidate.transitionDuration = transitionDuration }
            try validate(clip: candidate, asset: asset)

        case .reorderClips(let orderedIDs):
            guard let timeline = project.videoTimeline,
                  Set(orderedIDs) == Set(timeline.clips.map(\.id)),
                  orderedIDs.count == timeline.clips.count else {
                throw MediaCommandError.validation("reorder must list every clip exactly once")
            }

        case .splitClip(let id, let at):
            guard let timeline = project.videoTimeline,
                  let clip = timeline.clips.first(where: { $0.id == id }),
                  let asset = project.asset(clip.assetID) else {
                throw MediaCommandError.notFound("clip \(id)")
            }
            let sourceSeconds = clip.trimStart + at * clip.speed
            guard sourceSeconds > clip.trimStart + 0.05, sourceSeconds < clip.trimEnd - 0.05 else {
                throw MediaCommandError.validation("split point is too close to a clip edge")
            }
            _ = asset

        case .removeClip(let id):
            guard project.videoTimeline?.clips.contains(where: { $0.id == id }) == true else {
                throw MediaCommandError.notFound("clip \(id)")
            }

        case .duplicateClip(let id):
            guard project.videoTimeline?.clips.contains(where: { $0.id == id }) == true else {
                throw MediaCommandError.notFound("clip \(id)")
            }

        case .setCover(let time):
            if let time {
                guard time.isFinite, time >= 0 else {
                    throw MediaCommandError.validation("cover time must be a non-negative finite number")
                }
                guard let timeline = project.videoTimeline,
                      time <= MediaTimelineMath.primaryDuration(timeline) + 0.5 else {
                    throw MediaCommandError.validation("cover time is outside the timeline")
                }
            }

        case .shiftCaptions(let offset):
            guard offset.isFinite, abs(offset) <= 86_400 else {
                throw MediaCommandError.validation("caption shift must be finite and under 24h")
            }

        case .setPrimaryAudio(let volume, let muted):
            if let volume {
                guard volume.isFinite, (0...4).contains(volume) else {
                    throw MediaCommandError.validation("primary volume must be 0...4")
                }
            }
            _ = muted

        case .addMusic(let music):
            guard project.kind == .video else { throw MediaCommandError.validation("music belongs to video projects") }
            guard let asset = project.asset(music.assetID), asset.kind == .audio else {
                throw MediaCommandError.validation("music requires an imported audio asset")
            }
            try validate(music: music, asset: asset)

        case .updateMusic(let id, let offset, let trimStart, let length, let volume, let fadeIn, let fadeOut):
            guard let music = project.videoTimeline?.music.first(where: { $0.id == id }),
                  let asset = project.asset(music.assetID) else {
                throw MediaCommandError.notFound("music \(id)")
            }
            var candidate = music
            if let offset { candidate.offsetSeconds = offset }
            if let trimStart { candidate.trimStart = trimStart }
            if let length { candidate.lengthSeconds = length }
            if let volume { candidate.volume = volume }
            if let fadeIn { candidate.fadeInSeconds = fadeIn }
            if let fadeOut { candidate.fadeOutSeconds = fadeOut }
            try validate(music: candidate, asset: asset)

        case .removeMusic(let id):
            guard project.videoTimeline?.music.contains(where: { $0.id == id }) == true else {
                throw MediaCommandError.notFound("music \(id)")
            }

        case .addCaption(let caption):
            try validate(caption: caption)

        case .updateCaption(let id, let start, let end, let text):
            guard project.videoTimeline?.captions.contains(where: { $0.id == id }) == true else {
                throw MediaCommandError.notFound("caption \(id)")
            }
            var candidate = CaptionSegment(start: 0, end: 1, text: "")
            if let existing = project.videoTimeline?.captions.first(where: { $0.id == id }) {
                candidate = existing
            }
            if let start { candidate.start = start }
            if let end { candidate.end = end }
            if let text { candidate.text = text }
            try validate(caption: candidate)

        case .removeCaption(let id):
            guard project.videoTimeline?.captions.contains(where: { $0.id == id }) == true else {
                throw MediaCommandError.notFound("caption \(id)")
            }

        case .setCaptionStyle(let style):
            guard style.fontSize > 0, style.fontSize <= 400,
                  (0...1).contains(style.positionY) else {
                throw MediaCommandError.validation("invalid caption style")
            }
        }
    }

    /// Applies a validated command. Callers must validate first; this applies
    /// defensively and advances `updatedAt` (revision is owned by the store).
    public static func apply(_ command: MediaEditCommand, to project: inout MediaProject) throws {
        try validate(command, in: project)
        switch command {
        case .addAsset(let asset):
            project.assets.append(asset)
            if project.sourceAssetID == nil { project.sourceAssetID = asset.id }

        case .relinkAsset(let assetID, let path):
            guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else {
                throw MediaCommandError.notFound("asset \(assetID)")
            }
            project.assets[index].relativePath = path
            project.assets[index].metadata = nil

        case .setCanvas(let width, let height, let frameRate):
            project.canvas = MediaCanvas(width: width, height: height,
                                         frameRate: frameRate ?? project.canvas?.frameRate)

        case .addImageLayer(let layer):
            project.imageLayers.append(layer)

        case .updateLayer(let id, let transform, let opacity, let isHidden, let isLocked, let adjustment, let text, let crop):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else {
                throw MediaCommandError.notFound("layer \(id)")
            }
            if let transform { project.imageLayers[index].transform = transform }
            if let opacity { project.imageLayers[index].opacity = opacity }
            if let isHidden { project.imageLayers[index].isHidden = isHidden }
            if let isLocked { project.imageLayers[index].isLocked = isLocked }
            if let adjustment { project.imageLayers[index].adjustment = adjustment }
            if let text { project.imageLayers[index].text = text }
            switch crop {
            case .unchanged: break
            case .clear: project.imageLayers[index].crop = nil
            case .set(let rect): project.imageLayers[index].crop = rect
            }

        case .reorderLayers(let orderedIDs):
            var byID = Dictionary(uniqueKeysWithValues: project.imageLayers.map { ($0.id, $0) })
            project.imageLayers = orderedIDs.compactMap { byID.removeValue(forKey: $0) }

        case .moveLayer(let id, let toIndex):
            guard let from = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            let layer = project.imageLayers.remove(at: from)
            project.imageLayers.insert(layer, at: toIndex)

        case .removeLayer(let id):
            project.imageLayers.removeAll { $0.id == id }

        case .duplicateLayer(let id, let name):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            var copy = project.imageLayers[index]
            copy.id = UUID()
            copy.name = name ?? "\(copy.name) copy"
            project.imageLayers.insert(copy, at: index + 1)

        case .addFreehandStroke(let id, let stroke):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            var content = project.imageLayers[index].freehand ?? ImageFreehandContent()
            content.strokes.append(stroke)
            project.imageLayers[index].freehand = content

        case .setImageSelection(let selection):
            project.imageSelection = selection

        case .setLayerSelectionMask(let id, let update):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            switch update {
            case .unchanged: break
            case .clear: project.imageLayers[index].selectionMask = nil
            case .set(let selection): project.imageLayers[index].selectionMask = selection
            }

        case .addLayerMaskStroke(let id, let stroke):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            var mask = project.imageLayers[index].mask ?? ImageLayerMask()
            mask.strokes.append(stroke)
            project.imageLayers[index].mask = mask

        case .clearLayerMask(let id):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            project.imageLayers[index].mask = nil

        case .flipLayer(let id, let horizontal):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == id }) else { return }
            if horizontal {
                let current = project.imageLayers[index].transform.flipX ?? false
                project.imageLayers[index].transform.flipX = !current
            } else {
                let current = project.imageLayers[index].transform.flipY ?? false
                project.imageLayers[index].transform.flipY = !current
            }

        case .alignLayers(let ids, let alignment, let naturalSizes):
            guard let canvas = project.canvas else { return }
            let sizeByID = Dictionary(uniqueKeysWithValues: naturalSizes.map { ($0.layerID, $0) })
            let entries: [LayerLayoutEntry] = ids.compactMap { id in
                guard let layer = project.imageLayers.first(where: { $0.id == id }),
                      let size = sizeByID[id] else { return nil }
                return LayerLayoutEntry(id: id, naturalWidth: size.width,
                                        naturalHeight: size.height, transform: layer.transform)
            }
            guard entries.count == ids.count else { return }
            let deltas = LayerLayout.alignmentDeltas(
                entries, alignment: alignment,
                canvasSize: (Double(canvas.width), Double(canvas.height)))
            for id in ids {
                guard let delta = deltas[id],
                      let i = project.imageLayers.firstIndex(where: { $0.id == id }) else { continue }
                project.imageLayers[i].transform.centerX += delta.dx
                project.imageLayers[i].transform.centerY += delta.dy
            }

        case .mergeLayers(let ids, let name, let raster):
            // Validate already guarantees the host registered the raster asset.
            let merging = project.imageLayers.filter { ids.contains($0.id) }
            guard merging.count >= 2 else { return }
            // Insert at the position of the topmost merged layer (renders last)
            // so the composite's stacking order matches the source layers.
            let insertIndex = merging.map { project.imageLayers.firstIndex(of: $0) ?? 0 }.max() ?? 0
            project.imageLayers.removeAll { ids.contains($0.id) }
            let merged = ImageLayer(
                kind: .image,
                name: name ?? "Merged \(merging.count) layers",
                assetID: raster.assetID,
                // The raster is already full-canvas composited pixels; keep an
                // identity placement so they land exactly where they rendered.
                transform: .init(centerX: 0.5, centerY: 0.5, scale: 1),
                opacity: 1)
            project.imageLayers.insert(merged, at: min(insertIndex, project.imageLayers.count))

        case .fillSelection(let colorHex, let opacity, let name):
            guard let selection = project.imageSelection, !selection.isEmpty else { return }
            let fill = ImageLayer(
                kind: .fill,
                name: name ?? "Fill",
                transform: .init(centerX: 0.5, centerY: 0.5, scale: 1),
                opacity: opacity,
                selectionMask: selection,
                fillColorHex: colorHex)
            project.imageLayers.append(fill)

        case .cutSelection(let layerID):
            guard let index = project.imageLayers.firstIndex(where: { $0.id == layerID }),
                  let selection = project.imageSelection, !selection.shapes.isEmpty else { return }
            // The COMPLETE selection snapshot (operations/inverted/feather) is
            // stored so the cut erases exactly the displayed selection.
            let stroke = ImageMaskStroke(points: [], width: 0, hardness: nil, restore: false,
                                         region: selection)
            var mask = project.imageLayers[index].mask ?? ImageLayerMask()
            mask.strokes.append(stroke)
            project.imageLayers[index].mask = mask

        case .copySelection(let sourceLayerID, let name, let raster):
            guard project.imageLayers.contains(where: { $0.id == sourceLayerID }) else { return }
            // Insert directly above the source layer.
            let insertIndex = (project.imageLayers.firstIndex(where: { $0.id == sourceLayerID }) ?? 0) + 1
            let copied = ImageLayer(
                kind: .image,
                name: name ?? "Copy",
                assetID: raster.assetID,
                transform: .init(centerX: 0.5, centerY: 0.5, scale: 1),
                opacity: 1)
            project.imageLayers.insert(copied, at: min(insertIndex, project.imageLayers.count))

        case .setCanvasAdjustment(let adjustment):
            project.canvasAdjustment = adjustment

        case .appendClip(let clip):
            if project.videoTimeline == nil { project.videoTimeline = VideoTimeline() }
            project.videoTimeline?.clips.append(clip)

        case .updateClip(let id, let trimStart, let trimEnd, let speed, let volume, let isMuted,
                         let rotation, let crop, let transition, let transitionDuration):
            guard let timeline = project.videoTimeline,
                  let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
            if let trimStart { project.videoTimeline?.clips[index].trimStart = trimStart }
            if let trimEnd { project.videoTimeline?.clips[index].trimEnd = trimEnd }
            if let speed { project.videoTimeline?.clips[index].speed = speed }
            if let volume { project.videoTimeline?.clips[index].volume = volume }
            if let isMuted { project.videoTimeline?.clips[index].isMuted = isMuted }
            if let rotation { project.videoTimeline?.clips[index].rotationDegrees = rotation }
            switch crop {
            case .unchanged: break
            case .clear: project.videoTimeline?.clips[index].crop = nil
            case .set(let rect): project.videoTimeline?.clips[index].crop = rect
            }
            if let transition { project.videoTimeline?.clips[index].leadingTransition = transition }
            if let transitionDuration { project.videoTimeline?.clips[index].transitionDuration = transitionDuration }

        case .reorderClips(let orderedIDs):
            var byID = Dictionary(uniqueKeysWithValues: (project.videoTimeline?.clips ?? []).map { ($0.id, $0) })
            project.videoTimeline?.clips = orderedIDs.compactMap { byID.removeValue(forKey: $0) }

        case .splitClip(let id, let atTimelineSeconds):
            guard let timeline = project.videoTimeline,
                  let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
            let original = timeline.clips[index]
            let splitSourceSeconds = original.trimStart + atTimelineSeconds * original.speed
            let first = VideoClip(assetID: original.assetID,
                                  trimStart: original.trimStart, trimEnd: splitSourceSeconds,
                                  speed: original.speed, volume: original.volume, isMuted: original.isMuted,
                                  rotationDegrees: original.rotationDegrees, crop: original.crop,
                                  leadingTransition: original.leadingTransition,
                                  transitionDuration: original.transitionDuration)
            let second = VideoClip(assetID: original.assetID,
                                   trimStart: splitSourceSeconds, trimEnd: original.trimEnd,
                                   speed: original.speed, volume: original.volume, isMuted: original.isMuted,
                                   rotationDegrees: original.rotationDegrees, crop: original.crop,
                                   leadingTransition: .none, transitionDuration: original.transitionDuration)
            project.videoTimeline?.clips[index] = first
            project.videoTimeline?.clips.insert(second, at: index + 1)

        case .duplicateClip(let id):
            guard let timeline = project.videoTimeline,
                  let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
            let copy = MediaTimelineMath.duplicatedClip(timeline.clips[index])
            project.videoTimeline?.clips.insert(copy, at: index + 1)

        case .removeClip(let id):
            project.videoTimeline?.clips.removeAll { $0.id == id }

        case .setCover(let time):
            if project.videoTimeline == nil { project.videoTimeline = VideoTimeline() }
            project.videoTimeline?.coverTime = time

        case .shiftCaptions(let offset):
            guard let timeline = project.videoTimeline else { return }
            let duration = MediaTimelineMath.primaryDuration(timeline)
            project.videoTimeline?.captions = MediaTimelineMath.shiftCaptions(
                timeline.captions, by: offset, duration: duration)

        case .setPrimaryAudio(let volume, let muted):
            if project.videoTimeline == nil { project.videoTimeline = VideoTimeline() }
            if let volume { project.videoTimeline?.primaryVolume = volume }
            if let muted { project.videoTimeline?.primaryMuted = muted }

        case .addMusic(let music):
            if project.videoTimeline == nil { project.videoTimeline = VideoTimeline() }
            project.videoTimeline?.music.append(music)

        case .updateMusic(let id, let offset, let trimStart, let length, let volume, let fadeIn, let fadeOut):
            guard let index = project.videoTimeline?.music.firstIndex(where: { $0.id == id }) else { return }
            if let offset { project.videoTimeline?.music[index].offsetSeconds = offset }
            if let trimStart { project.videoTimeline?.music[index].trimStart = trimStart }
            if let length { project.videoTimeline?.music[index].lengthSeconds = length }
            if let volume { project.videoTimeline?.music[index].volume = volume }
            if let fadeIn { project.videoTimeline?.music[index].fadeInSeconds = fadeIn }
            if let fadeOut { project.videoTimeline?.music[index].fadeOutSeconds = fadeOut }

        case .removeMusic(let id):
            project.videoTimeline?.music.removeAll { $0.id == id }

        case .addCaption(let caption):
            if project.videoTimeline == nil { project.videoTimeline = VideoTimeline() }
            project.videoTimeline?.captions.append(caption)

        case .updateCaption(let id, let start, let end, let text):
            guard let index = project.videoTimeline?.captions.firstIndex(where: { $0.id == id }) else { return }
            if let start { project.videoTimeline?.captions[index].start = start }
            if let end { project.videoTimeline?.captions[index].end = end }
            if let text { project.videoTimeline?.captions[index].text = text }

        case .removeCaption(let id):
            project.videoTimeline?.captions.removeAll { $0.id == id }

        case .setCaptionStyle(let style):
            if project.videoTimeline == nil { project.videoTimeline = VideoTimeline() }
            project.videoTimeline?.captionStyle = style
        }
        project.updatedAt = Date()
    }

    // MARK: Validation helpers

    private static func validate(transform: ImageLayerTransform, opacity: Double) throws {        guard transform.centerX.isFinite, transform.centerY.isFinite,
              (0...2).contains(transform.centerX), (0...2).contains(transform.centerY),
              transform.scale.isFinite, transform.scale > 0, transform.scale <= 20,
              transform.rotationDegrees.isFinite, abs(transform.rotationDegrees) <= 360 else {
            throw MediaCommandError.validation("invalid layer transform")
        }
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw MediaCommandError.validation("opacity must be 0...1")
        }
    }

    private static func validateCrop(_ rect: NormalizedRect) throws {
        guard (0...1).contains(rect.x), (0...1).contains(rect.y),
              rect.width > 0.01, rect.height > 0.01,
              rect.x + rect.width <= 1.0, rect.y + rect.height <= 1.0 else {
            throw MediaCommandError.validation("crop must fit inside the unit square")
        }
    }

    private static func validateSelection(_ selection: ImageSelection) throws {
        guard selection.shapes.count <= 64 else {
            throw MediaCommandError.validation("selection supports at most 64 shapes")
        }
        guard selection.feather.isFinite, (0...0.5).contains(selection.feather) else {
            throw MediaCommandError.validation("selection feather must be 0...0.5")
        }
        for shape in selection.shapes {
            switch shape.kind {
            case .rectangle, .ellipse:
                guard shape.points.count == 2 else {
                    throw MediaCommandError.validation("rectangle/ellipse selection needs two corners")
                }
            case .lasso:
                guard (3...512).contains(shape.points.count) else {
                    throw MediaCommandError.validation("lasso selection needs 3...512 points")
                }
            }
            for point in shape.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw MediaCommandError.validation("selection points must be normalized 0...1")
                }
            }
        }
    }

    private static func validateMask(_ mask: ImageLayerMask) throws {
        guard mask.strokes.count <= 512 else {
            throw MediaCommandError.validation("mask supports at most 512 strokes")
        }
        for stroke in mask.strokes {
            guard (2...512).contains(stroke.points.count) else {
                throw MediaCommandError.validation("mask stroke needs 2...512 points")
            }
            guard stroke.width.isFinite, (1...2048).contains(stroke.width) else {
                throw MediaCommandError.validation("mask stroke width must be 1...2048")
            }
            if let hardness = stroke.hardness {
                guard hardness.isFinite, (0...1).contains(hardness) else {
                    throw MediaCommandError.validation("mask hardness must be 0...1")
                }
            }
            for point in stroke.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw MediaCommandError.validation("mask points must be normalized 0...1")
                }
            }
        }
    }

    private static func validateText(_ text: ImageTextContent) throws {
        guard text.text.utf8.count <= 4096 else { throw MediaCommandError.validation("text exceeds 4 KiB") }
        guard (1...1000).contains(text.fontSize) else { throw MediaCommandError.validation("font size must be 1...1000") }
        guard text.colorHex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil else {
            throw MediaCommandError.validation("color must be #RRGGBB")
        }
    }

    private static func validateFreehand(_ freehand: ImageFreehandContent) throws {
        guard freehand.strokes.count <= 200 else { throw MediaCommandError.validation("too many strokes (200 max)") }
        for stroke in freehand.strokes {
            guard stroke.points.count >= 2, stroke.points.count <= 5000,
                  stroke.width > 0, stroke.width <= 200,
                  stroke.colorHex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
                  stroke.points.allSatisfy({ (0...2).contains($0.x) && (0...2).contains($0.y) }) else {
                throw MediaCommandError.validation("invalid freehand stroke")
            }
        }
    }

    private static func requireSelection(_ project: MediaProject) throws -> ImageSelection {
        guard let selection = project.imageSelection, !selection.isEmpty else {
            throw MediaCommandError.validation("a non-empty selection is required (use Select All to start)")
        }
        return selection
    }

    private static func isValidColorHex(_ value: String) -> Bool {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 || hex.count == 8 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }

    private static func validateAdjustment(_ adjustment: ImageLayerAdjustment) throws {
        if let saturation = adjustment.saturation {
            guard saturation.isFinite, (0...4).contains(saturation) else {
                throw MediaCommandError.validation("saturation must be 0...4")
            }
        }
        for value in [adjustment.contrast, adjustment.brightness].compactMap({ $0 }) {
            guard value.isFinite, abs(value) <= 4 else {
                throw MediaCommandError.validation("contrast/brightness must be within ±4")
            }
        }
        if let ev = adjustment.exposureEV {
            guard ev.isFinite, abs(ev) <= 10 else {
                throw MediaCommandError.validation("exposure must be within ±10 EV")
            }
        }
        for value in [adjustment.blurRadius, adjustment.sharpenRadius].compactMap({ $0 }) {
            guard value.isFinite, (0...100).contains(value) else {
                throw MediaCommandError.validation("radius must be 0...100")
            }
        }
        if let mosaic = adjustment.mosaicBlockSize {
            guard (1...512).contains(mosaic) else {
                throw MediaCommandError.validation("mosaic block must be 1...512 px")
            }
        }
    }

    private static func validate(clip: VideoClip, asset: MediaAssetReference) throws {
        let duration = asset.metadata?.durationSeconds
        guard clip.trimStart >= 0, clip.trimEnd > clip.trimStart else {
            throw MediaCommandError.validation("trim requires 0 <= start < end")
        }
        if let duration {
            guard clip.trimEnd <= duration + 0.05 else {
                throw MediaCommandError.validation("trim end \(clip.trimEnd)s exceeds source duration \(String(format: "%.2f", duration))s")
            }
        }
        guard clip.speed.isFinite, (0.1...16).contains(clip.speed) else {
            throw MediaCommandError.validation("speed must be 0.1...16")
        }
        guard clip.volume.isFinite, (0...4).contains(clip.volume) else {
            throw MediaCommandError.validation("clip volume must be 0...4")
        }
        guard clip.rotationDegrees.isFinite,
              [0, 90, 180, 270, -90, -180, -270].contains(clip.rotationDegrees) else {
            throw MediaCommandError.validation("rotation must be 0/90/180/270 degrees")
        }
        if let crop = clip.crop {
            guard (0...1).contains(crop.x), (0...1).contains(crop.y),
                  crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= 1, crop.y + crop.height <= 1 else {
                throw MediaCommandError.validation("crop must fit inside the unit square")
            }
        }
        if clip.leadingTransition == .crossDissolve {
            guard clip.transitionDuration > 0, clip.transitionDuration <= 2 else {
                throw MediaCommandError.validation("dissolve must be within 2 seconds")
            }
        }
    }

    private static func validate(music: MusicClip, asset: MediaAssetReference) throws {
        let duration = asset.metadata?.durationSeconds
        guard music.offsetSeconds.isFinite, music.offsetSeconds >= 0 else {
            throw MediaCommandError.validation("music offset must be >= 0")
        }
        guard music.trimStart >= 0, music.lengthSeconds > 0 else {
            throw MediaCommandError.validation("music trim requires start >= 0 and positive length")
        }
        if let duration {
            guard music.trimStart + music.lengthSeconds <= duration + 0.05 else {
                throw MediaCommandError.validation("music trim exceeds audio duration")
            }
        }
        guard music.volume.isFinite, (0...4).contains(music.volume) else {
            throw MediaCommandError.validation("music volume must be 0...4")
        }
        guard music.fadeInSeconds >= 0, music.fadeOutSeconds >= 0,
              music.fadeInSeconds + music.fadeOutSeconds <= music.lengthSeconds else {
            throw MediaCommandError.validation("audio fades overlap or exceed the clip length")
        }
    }

    private static func validate(caption: CaptionSegment) throws {
        guard caption.start >= 0, caption.end > caption.start else {
            throw MediaCommandError.validation("caption requires 0 <= start < end")
        }
        guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaCommandError.validation("caption text is empty")
        }
        guard caption.text.utf8.count <= 2000 else {
            throw MediaCommandError.validation("caption exceeds 2000 bytes")
        }
    }
}
