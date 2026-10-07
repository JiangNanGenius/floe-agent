// FloeWorkbench — Versioned, Floe-owned persistent model for the unified
// image/video workbench. Projects reference external assets by path (never
// embed source bytes), keep image layers and video tracks, and advance an
// opaque revision on every committed transaction. The model is platform
// independent and unit-testable on macOS; renderers live behind capability
// guards in files that import Core Graphics / AVFoundation.
//
// Invariants:
//   * The source asset is never overwritten destructively; export is the
//     only pixel-producing path.
//   * Every mutation goes through validated edit commands shared by the UI
//     and the model-facing `media.project` tool.
//   * Unknown operations decoded from a newer document are preserved in
//     `unknownOperations` and surfaced as a recovery warning, never dropped.

import Foundation
import FloeCore

// MARK: - Kind / canvas

public enum MediaProjectKind: String, Sendable, Codable, Hashable {
    case image
    case video
}

/// Pixel-space canvas. Image projects derive it from the decoded source;
/// video projects derive it from the first imported clip and keep an
/// explicit frame rate chosen by the user (never a silent preset).
public struct MediaCanvas: Sendable, Codable, Hashable {
    public var width: Int
    public var height: Int
    public var frameRate: Double?

    public init(width: Int, height: Int, frameRate: Double? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

// MARK: - Assets

public enum MediaAssetKind: String, Sendable, Codable, Hashable {
    case image
    case video
    case audio
}

/// An external file reference. Assets are never copied into the project
/// JSON; `relativePath` is workspace-relative when the project lives inside
/// a workspace, otherwise a bookmark-relative absolute path. `relink` maps
/// missing assets to replacement files after a move/rename.
public struct MediaAssetReference: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: MediaAssetKind
    public var relativePath: String
    /// Original file name for display and relink hints.
    public var originalName: String
    /// Bytes captured at import for honest missing/corrupted detection.
    public var byteCount: Int64?
    public var contentHash: String?
    /// Observed media metadata (filled by importer; nil until probed).
    public var metadata: MediaAssetMetadata?

    public init(id: UUID = UUID(), kind: MediaAssetKind, relativePath: String,
                originalName: String, byteCount: Int64? = nil, contentHash: String? = nil,
                metadata: MediaAssetMetadata? = nil) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.originalName = originalName
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.metadata = metadata
    }
}

public struct MediaAssetMetadata: Sendable, Codable, Hashable {
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var frameRate: Double?
    public var audioTracks: Int?
    /// Rotation in degrees carried by container metadata (0/90/180/270).
    public var rotationDegrees: Double?
    public var hasAlpha: Bool?

    public init(width: Int? = nil, height: Int? = nil, durationSeconds: Double? = nil,
                frameRate: Double? = nil, audioTracks: Int? = nil,
                rotationDegrees: Double? = nil, hasAlpha: Bool? = nil) {
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.audioTracks = audioTracks
        self.rotationDegrees = rotationDegrees
        self.hasAlpha = hasAlpha
    }
}

// MARK: - Image layers

public enum ImageLayerKind: String, Sendable, Codable, Hashable {
    /// Pixel layer backed by an imported image asset.
    case image
    /// Styled text layer.
    case text
    /// Rasterized freehand drawing (bounded point strokes).
    case freehand
    /// Solid color masked by a vector selection (fill/cut-copy results).
    case fill
}

/// Unit-space geometry relative to the canvas. Center anchor + scale keeps
/// drag/resize/rotate math identical for every layer kind.
public struct ImageLayerTransform: Sendable, Codable, Hashable {
    public var centerX: Double
    public var centerY: Double
    /// Uniform scale multiplier; 1 = the layer fills its natural placement.
    public var scale: Double
    public var rotationDegrees: Double
    /// Non-destructive mirror flags (nil/false = unflipped).
    public var flipX: Bool?
    public var flipY: Bool?

    public init(centerX: Double = 0.5, centerY: Double = 0.5, scale: Double = 1,
                rotationDegrees: Double = 0, flipX: Bool? = nil, flipY: Bool? = nil) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.flipX = flipX
        self.flipY = flipY
    }
}

public enum ImageTextAlignment: String, Sendable, Codable, Hashable {
    case left, center, right
}

public struct ImageTextShadow: Sendable, Codable, Hashable {
    public var colorHex: String
    public var blur: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(colorHex: String = "#00000080", blur: Double = 4,
                offsetX: Double = 2, offsetY: Double = 2) {
        self.colorHex = colorHex; self.blur = blur
        self.offsetX = offsetX; self.offsetY = offsetY
    }
}

public struct ImageTextContent: Sendable, Codable, Hashable {
    public var text: String
    public var fontSize: Double
    public var colorHex: String
    /// Resolved font family name; nil uses the system font.
    public var fontName: String?
    /// Letter spacing (points, may be negative).
    public var tracking: Double?
    /// Line spacing (points) for multi-line text.
    public var leading: Double?
    public var alignment: ImageTextAlignment?
    public var strokeColorHex: String?
    public var strokeWidth: Double?
    public var shadow: ImageTextShadow?

    public init(text: String, fontSize: Double = 48, colorHex: String = "#000000",
                fontName: String? = nil, tracking: Double? = nil, leading: Double? = nil,
                alignment: ImageTextAlignment? = nil, strokeColorHex: String? = nil,
                strokeWidth: Double? = nil, shadow: ImageTextShadow? = nil) {
        self.text = text
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.fontName = fontName
        self.tracking = tracking
        self.leading = leading
        self.alignment = alignment
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.shadow = shadow
    }
}

public struct ImageFreehandStroke: Sendable, Codable, Hashable {
    public struct Point: Sendable, Codable, Hashable {
        public var x: Double
        public var y: Double
        /// Apple Pencil pressure in 0...1; nil means a fixed-width finger or
        /// mouse stroke (pressure is never synthesized).
        public var pressure: Double?
        public init(x: Double, y: Double, pressure: Double? = nil) {
            self.x = x; self.y = y; self.pressure = pressure
        }
    }
    public var points: [Point]
    public var width: Double
    public var colorHex: String
    /// Edge softness 0 (hard) ... 1 (soft). nil = default soft edge.
    public var hardness: Double?
    /// Stroke opacity 0...1. nil = 1.
    public var opacity: Double?

    public init(points: [Point], width: Double = 4, colorHex: String = "#000000",
                hardness: Double? = nil, opacity: Double? = nil) {
        self.points = points
        self.width = width
        self.colorHex = colorHex
        self.hardness = hardness
        self.opacity = opacity
    }
}

public struct ImageFreehandContent: Sendable, Codable, Hashable {
    /// Bounded number of strokes; each stroke is bounded by validation.
    public var strokes: [ImageFreehandStroke]

    public init(strokes: [ImageFreehandStroke] = []) { self.strokes = strokes }
}

/// One non-destructive mask stroke. `restore` strokes re-expose erased pixels;
/// both are stored as vector paths so the original pixels are never destroyed.
public struct ImageMaskStroke: Sendable, Codable, Hashable {
    public var points: [ImageFreehandStroke.Point]
    public var width: Double
    public var hardness: Double?
    /// false = erase (hide pixels), true = restore (show pixels again).
    public var restore: Bool
    /// Region form of the stroke (a vector selection): when set, the FILLED
    /// shapes erase/restore instead of the polyline in `points`. Used by
    /// selection cut so a cut is one undoable non-destructive mask stroke.
    public var region: [ImageSelectionShape]?

    public init(points: [ImageFreehandStroke.Point], width: Double = 24,
                hardness: Double? = nil, restore: Bool = false,
                region: [ImageSelectionShape]? = nil) {
        self.points = points; self.width = width; self.hardness = hardness
        self.restore = restore; self.region = region
    }
}

public struct ImageLayerMask: Sendable, Codable, Hashable {
    public var strokes: [ImageMaskStroke]

    public init(strokes: [ImageMaskStroke] = []) { self.strokes = strokes }
}

/// Selection shape in normalized source coordinates.
public enum ImageSelectionKind: String, Sendable, Codable, Hashable {
    case rectangle
    case ellipse
    case lasso
}

public enum ImageSelectionOperation: String, Sendable, Codable, Hashable {
    case replace
    case add
    case subtract
}

public struct ImageSelectionShape: Sendable, Codable, Hashable {
    public var kind: ImageSelectionKind
    public var operation: ImageSelectionOperation
    /// Rectangle/ellipse: two corners. Lasso: the polygon path.
    public var points: [ImageFreehandStroke.Point]

    public init(kind: ImageSelectionKind, operation: ImageSelectionOperation = .replace,
                points: [ImageFreehandStroke.Point]) {
        self.kind = kind; self.operation = operation; self.points = points
    }
}

/// Vector selection with feathering. Coordinates are normalized to the canvas;
/// scaling the canvas or the layer therefore scales the selection geometry, and
/// the feather radius stays a normalized fraction rather than a pixel constant.
public struct ImageSelection: Sendable, Codable, Hashable {
    public var shapes: [ImageSelectionShape]
    public var feather: Double
    public var inverted: Bool

    public init(shapes: [ImageSelectionShape] = [], feather: Double = 0, inverted: Bool = false) {
        self.shapes = shapes; self.feather = feather; self.inverted = inverted
    }

    public var isEmpty: Bool { shapes.isEmpty && !inverted }
}

/// Level adjustment: input black/white points and gamma.
public struct ImageLevels: Sendable, Codable, Hashable {
    public var black: Double
    public var white: Double
    public var gamma: Double

    public init(black: Double = 0, white: Double = 1, gamma: Double = 1) {
        self.black = black; self.white = white; self.gamma = gamma
    }
}

public struct ImageLayer: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: ImageLayerKind
    public var name: String
    /// Asset ID for pixel layers; nil for text/freehand.
    public var assetID: UUID?
    public var transform: ImageLayerTransform
    public var opacity: Double
    public var isHidden: Bool
    public var isLocked: Bool
    public var text: ImageTextContent?
    public var freehand: ImageFreehandContent?
    /// Non-destructive crop of a pixel layer, normalized to the source frame.
    public var crop: NormalizedRect?
    /// Non-destructive erase/restore mask strokes.
    public var mask: ImageLayerMask?
    /// Vector selection limiting this layer's effect (selection-scoped edits).
    public var selectionMask: ImageSelection?
    /// Solid fill color for `.fill` layers, masked by `selectionMask`.
    public var fillColorHex: String?
    /// Per-layer pixel adjustments applied at export. Basic color science is
    /// shared with the deterministic `ImagePipeline` vocabulary.
    public var adjustment: ImageLayerAdjustment

    public init(id: UUID = UUID(), kind: ImageLayerKind, name: String, assetID: UUID? = nil,
                transform: ImageLayerTransform = .init(), opacity: Double = 1,
                isHidden: Bool = false, isLocked: Bool = false,
                text: ImageTextContent? = nil, freehand: ImageFreehandContent? = nil,
                crop: NormalizedRect? = nil,
                adjustment: ImageLayerAdjustment = .init(),
                mask: ImageLayerMask? = nil, selectionMask: ImageSelection? = nil,
                fillColorHex: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.assetID = assetID
        self.transform = transform
        self.opacity = opacity
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.text = text
        self.freehand = freehand
        self.crop = crop
        self.adjustment = adjustment
        self.mask = mask
        self.selectionMask = selectionMask
        self.fillColorHex = fillColorHex
    }
}

/// Per-layer non-destructive color/effect adjustments. nil means unchanged.
public struct ImageLayerAdjustment: Sendable, Codable, Hashable {
    public var saturation: Double?
    public var contrast: Double?
    public var brightness: Double?
    public var exposureEV: Double?
    public var blurRadius: Double?
    public var sharpenRadius: Double?
    /// White-balance temperature in Kelvin (neutral target); nil disables.
    public var temperature: Double?
    /// Hue rotation in degrees (-180...180); nil disables.
    public var hueDegrees: Double?
    /// Input levels; nil disables.
    public var levels: ImageLevels?
    /// Mosaic pixelation block size in canvas pixels; 0/nil disables.
    public var mosaicBlockSize: Int?
    /// Built-in color filter identifier (deterministic Core Image name set).
    public var filterID: String?

    public init(saturation: Double? = nil, contrast: Double? = nil, brightness: Double? = nil,
                exposureEV: Double? = nil, blurRadius: Double? = nil, sharpenRadius: Double? = nil,
                mosaicBlockSize: Int? = nil, filterID: String? = nil,
                temperature: Double? = nil, hueDegrees: Double? = nil, levels: ImageLevels? = nil) {
        self.saturation = saturation
        self.contrast = contrast
        self.brightness = brightness
        self.exposureEV = exposureEV
        self.blurRadius = blurRadius
        self.sharpenRadius = sharpenRadius
        self.mosaicBlockSize = mosaicBlockSize
        self.filterID = filterID
        self.temperature = temperature
        self.hueDegrees = hueDegrees
        self.levels = levels
    }

    public var isIdentity: Bool {
        saturation == nil && contrast == nil && brightness == nil && exposureEV == nil &&
        blurRadius == nil && sharpenRadius == nil && mosaicBlockSize == nil && filterID == nil &&
        temperature == nil && hueDegrees == nil && levels == nil
    }
}

/// Whole-canvas raster adjustments (mosaic/filter/basic color) applied after
/// compositing, so they affect the flattened result exactly once.
public typealias CanvasAdjustment = ImageLayerAdjustment

// MARK: - Geometry

/// Renderer-measured untransformed size of a layer, in canvas-pixel space,
/// supplied by the host so the pure engine can align rendered edges.
public struct LayerNaturalSize: Sendable, Codable, Hashable {
    public var layerID: UUID
    public var width: Double
    public var height: Double

    public init(layerID: UUID, width: Double, height: Double) {
        self.layerID = layerID; self.width = width; self.height = height
    }
}

/// Result of a host-rendered layer merge: a new full-canvas transparent image
/// asset that contains exactly the merged layers' composited pixels. The host
/// renders this through the real image pipeline (not a screen capture),
/// persists it as an asset, and hands the reference to the engine.
public struct MergedLayerRaster: Sendable, Codable, Hashable {
    /// Newly imported asset containing the merged pixels.
    public var assetID: UUID
    public var width: Int
    public var height: Int
    public var contentHash: String?

    public init(assetID: UUID, width: Int, height: Int, contentHash: String? = nil) {
        self.assetID = assetID; self.width = width; self.height = height
        self.contentHash = contentHash
    }
}

/// Unit-square normalized rectangle (0...1 per component).
public struct NormalizedRect: Sendable, Codable, Hashable {    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let unit = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

// MARK: - Video timeline

public enum VideoTransitionKind: String, Sendable, Codable, Hashable {
    case none
    case crossDissolve

    public var isHardCut: Bool { self == .none }
}

public struct VideoClip: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    /// Source range in seconds within the asset.
    public var trimStart: Double
    public var trimEnd: Double
    public var speed: Double
    /// Per-clip volume 0...4 applied to the asset's own audio.
    public var volume: Double
    public var isMuted: Bool
    public var rotationDegrees: Double
    /// Normalized crop rect inside the displayed source frame.
    public var crop: NormalizedRect?
    /// Transition rendered at the leading edge of this clip.
    public var leadingTransition: VideoTransitionKind
    public var transitionDuration: Double

    public init(id: UUID = UUID(), assetID: UUID, trimStart: Double, trimEnd: Double,
                speed: Double = 1, volume: Double = 1, isMuted: Bool = false,
                rotationDegrees: Double = 0, crop: NormalizedRect? = nil,
                leadingTransition: VideoTransitionKind = .none, transitionDuration: Double = 0.4) {
        self.id = id
        self.assetID = assetID
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.speed = speed
        self.volume = volume
        self.isMuted = isMuted
        self.rotationDegrees = rotationDegrees
        self.crop = crop
        self.leadingTransition = leadingTransition
        self.transitionDuration = transitionDuration
    }

    public var sourceDuration: Double { max(0, trimEnd - trimStart) }
    public var timelineDuration: Double { sourceDuration / max(speed, 0.0001) }
}

public struct MusicClip: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    /// Placement on the unified timeline.
    public var offsetSeconds: Double
    public var trimStart: Double
    public var lengthSeconds: Double
    public var volume: Double
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double

    public init(id: UUID = UUID(), assetID: UUID, offsetSeconds: Double, trimStart: Double,
                lengthSeconds: Double, volume: Double = 1, fadeInSeconds: Double = 0,
                fadeOutSeconds: Double = 0) {
        self.id = id
        self.assetID = assetID
        self.offsetSeconds = offsetSeconds
        self.trimStart = trimStart
        self.lengthSeconds = lengthSeconds
        self.volume = volume
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }
}

public struct CaptionSegment: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    /// Timeline seconds (already retimed for clip speed).
    public var start: Double
    public var end: Double
    public var text: String
    /// Origin provenance for honest transcription provenance UI.
    public var source: CaptionSource

    public enum CaptionSource: String, Sendable, Codable, Hashable {
        case manual
        case transcription
    }

    public init(id: UUID = UUID(), start: Double, end: Double, text: String,
                source: CaptionSource = .manual) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.source = source
    }
}

/// Style shared by the subtitle overlay track; deterministic and local.
public enum CaptionAlignment: String, Sendable, Codable, Hashable {
    case leading, center, trailing
}

public struct CaptionStyle: Sendable, Codable, Hashable {
    public var fontSize: Double
    public var colorHex: String
    public var backgroundHex: String?
    /// Vertical position of the caption baseline center, normalized 0...1.
    public var positionY: Double
    /// Horizontal alignment of the rendered caption line.
    public var alignment: CaptionAlignment?
    /// Keep captions inside the title-safe area for the export preset.
    public var respectsSafeArea: Bool?

    public init(fontSize: Double = 36, colorHex: String = "#FFFFFF",
                backgroundHex: String? = "#000000", positionY: Double = 0.88,
                alignment: CaptionAlignment? = nil, respectsSafeArea: Bool? = nil) {
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.backgroundHex = backgroundHex
        self.positionY = positionY
        self.alignment = alignment
        self.respectsSafeArea = respectsSafeArea
    }
}

public struct VideoTimeline: Sendable, Codable, Hashable {
    public var clips: [VideoClip]
    public var music: [MusicClip]
    public var captions: [CaptionSegment]
    public var captionStyle: CaptionStyle
    /// Explicit user-chosen cover frame in timeline seconds; nil derives the
    /// first visual frame. Never guessed from an arbitrary thumbnail.
    public var coverTime: Double?
    /// Master mix of the clips' original audio; music is mixed alongside.
    public var primaryVolume: Double
    public var primaryMuted: Bool

    public init(clips: [VideoClip] = [], music: [MusicClip] = [], captions: [CaptionSegment] = [],
                captionStyle: CaptionStyle = .init(), coverTime: Double? = nil,
                primaryVolume: Double = 1, primaryMuted: Bool = false) {
        self.clips = clips
        self.music = music
        self.captions = captions
        self.captionStyle = captionStyle
        self.coverTime = coverTime
        self.primaryVolume = primaryVolume
        self.primaryMuted = primaryMuted
    }

    /// Timeline duration of the primary track after speed retiming.
    public var primaryDuration: Double {
        clips.reduce(0) { $0 + $1.timelineDuration }
    }
}

// MARK: - Export options

public enum ImageExportFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case png
    case jpeg
    case heic

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpeg"
        case .heic: "heic"
        }
    }

    /// JPEG has no alpha channel; requesting transparency on JPEG is an
    /// invalid combination that must be reported, not flattened silently.
    public var supportsAlpha: Bool { self == .png || self == .heic }
}

public struct ImageExportOptions: Sendable, Codable, Hashable {
    public var format: ImageExportFormat
    /// Explicit pixel dimensions; nil renders at full canvas resolution.
    public var width: Int?
    public var height: Int?
    /// 0.01...1 for lossy containers; ignored by PNG.
    public var quality: Double
    public var preserveTransparency: Bool
    public var stripMetadata: Bool
    /// User-facing filename stem (extension is added from `format`).
    public var fileName: String

    public init(format: ImageExportFormat = .png, width: Int? = nil, height: Int? = nil,
                quality: Double = 0.95, preserveTransparency: Bool = true,
                stripMetadata: Bool = true, fileName: String = "export") {
        self.format = format
        self.width = width
        self.height = height
        self.quality = quality
        self.preserveTransparency = preserveTransparency
        self.stripMetadata = stripMetadata
        self.fileName = fileName
    }
}

public enum VideoExportCodec: String, Sendable, Codable, Hashable, CaseIterable {
    case h264
    case hevc
}

public struct VideoExportOptions: Sendable, Codable, Hashable {
    public var codec: VideoExportCodec
    public var width: Int
    public var height: Int
    public var frameRate: Double
    /// 0.01...1 quality dial mapped to an explicit bitrate budget.
    public var quality: Double
    public var fileName: String

    public init(codec: VideoExportCodec = .h264, width: Int, height: Int, frameRate: Double,
                quality: Double = 0.9, fileName: String = "export") {
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.quality = quality
        self.fileName = fileName
    }

    public var container: String { "mp4" }
}

// MARK: - Project document

public struct MediaProject: Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var kind: MediaProjectKind
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Monotonic revision; every applied transaction advances it exactly once.
    public var revision: Int64
    public var canvas: MediaCanvas?
    public var assets: [MediaAssetReference]
    /// The asset the project was initially created from (may be nil after relink).
    public var sourceAssetID: UUID?
    public var imageLayers: [ImageLayer]
    public var canvasAdjustment: CanvasAdjustment
    public var videoTimeline: VideoTimeline?
    public var lastImageExport: ImageExportOptions?
    public var lastVideoExport: VideoExportOptions?
    /// Explicit ownership: which surface owns this project, which environment
    /// (task workspace) it belongs to and the task root path captured at
    /// creation. The tool host refuses cross-owner/cross-task access.
    public var ownerKind: String
    public var ownerID: UUID?
    public var environmentID: String?
    public var taskWorkspacePath: String?
    /// Operations from newer builds this build cannot interpret; preserved
    /// verbatim so reopening never discards user work.
    public var unknownOperations: [UnknownOperation]
    /// Recovery warnings surfaced once after load (missing assets, migrations).
    public var recoveryWarnings: [String]
    /// Durable undo/redo history persisted with the project so reopening a
    /// workbench project keeps undo available. Snapshots hold editable state
    /// only (assets stay external references), keeping the document small.
    public var undoHistory: [MediaProjectMemento]
    public var redoHistory: [MediaProjectMemento]
    /// Current image-editor selection (vector, normalized, non-destructive).
    public var imageSelection: ImageSelection?
    /// Set when this project is a persisted fork (canvas "make variant" or a
    /// copied bound node). Asset bytes are reused by reference; only editable
    /// state is independent.
    public var parentProjectID: UUID?

    public init(schemaVersion: Int = MediaProject.currentSchemaVersion, id: UUID = UUID(),
                kind: MediaProjectKind, name: String, createdAt: Date = Date(),
                updatedAt: Date = Date(), revision: Int64 = 0, canvas: MediaCanvas? = nil,
                assets: [MediaAssetReference] = [], sourceAssetID: UUID? = nil,
                imageLayers: [ImageLayer] = [], canvasAdjustment: CanvasAdjustment = .init(),
                videoTimeline: VideoTimeline? = nil,                 lastImageExport: ImageExportOptions? = nil,
                lastVideoExport: VideoExportOptions? = nil,
                ownerKind: String = "standalone", ownerID: UUID? = nil,
                environmentID: String? = nil, taskWorkspacePath: String? = nil,
                unknownOperations: [UnknownOperation] = [],
                recoveryWarnings: [String] = [],
                undoHistory: [MediaProjectMemento] = [], redoHistory: [MediaProjectMemento] = [],
                parentProjectID: UUID? = nil, imageSelection: ImageSelection? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.canvas = canvas
        self.assets = assets
        self.sourceAssetID = sourceAssetID
        self.imageLayers = imageLayers
        self.canvasAdjustment = canvasAdjustment
        self.videoTimeline = videoTimeline
        self.lastImageExport = lastImageExport
        self.lastVideoExport = lastVideoExport
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.environmentID = environmentID
        self.taskWorkspacePath = taskWorkspacePath
        self.unknownOperations = unknownOperations
        self.recoveryWarnings = recoveryWarnings
        self.undoHistory = undoHistory
        self.redoHistory = redoHistory
        self.parentProjectID = parentProjectID
        self.imageSelection = imageSelection
    }

    public func asset(_ id: UUID) -> MediaAssetReference? {
        assets.first { $0.id == id }
    }
}

/// Opaque persisted operation this build cannot apply. The raw payload is
/// retained exactly; the UI reports it and offers remove-on-user-action only.
public struct UnknownOperation: Sendable, Codable, Hashable {
    public var kind: String
    public var payload: Data
    public var recordedAt: Date

    public init(kind: String, payload: Data, recordedAt: Date = Date()) {
        self.kind = kind
        self.payload = payload
        self.recordedAt = recordedAt
    }
}

// MARK: - Codable resilience

extension MediaProject {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, name, createdAt, updatedAt, revision, canvas, assets
        case sourceAssetID, imageLayers, canvasAdjustment, videoTimeline
        case lastImageExport, lastVideoExport, unknownOperations, recoveryWarnings
        case ownerKind, ownerID, environmentID, taskWorkspacePath
        case undoHistory, redoHistory, parentProjectID, imageSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MediaProjectKind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        canvas = try container.decodeIfPresent(MediaCanvas.self, forKey: .canvas)
        assets = try container.decodeIfPresent([MediaAssetReference].self, forKey: .assets) ?? []
        sourceAssetID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssetID)
        imageLayers = try container.decodeIfPresent([ImageLayer].self, forKey: .imageLayers) ?? []
        canvasAdjustment = try container.decodeIfPresent(CanvasAdjustment.self, forKey: .canvasAdjustment) ?? .init()
        videoTimeline = try container.decodeIfPresent(VideoTimeline.self, forKey: .videoTimeline)
        lastImageExport = try container.decodeIfPresent(ImageExportOptions.self, forKey: .lastImageExport)
        lastVideoExport = try container.decodeIfPresent(VideoExportOptions.self, forKey: .lastVideoExport)
        ownerKind = try container.decodeIfPresent(String.self, forKey: .ownerKind) ?? "standalone"
        ownerID = try container.decodeIfPresent(UUID.self, forKey: .ownerID)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID)
        taskWorkspacePath = try container.decodeIfPresent(String.self, forKey: .taskWorkspacePath)
        unknownOperations = try container.decodeIfPresent([UnknownOperation].self, forKey: .unknownOperations) ?? []
        recoveryWarnings = []
        undoHistory = try container.decodeIfPresent([MediaProjectMemento].self, forKey: .undoHistory) ?? []
        redoHistory = try container.decodeIfPresent([MediaProjectMemento].self, forKey: .redoHistory) ?? []
        parentProjectID = try container.decodeIfPresent(UUID.self, forKey: .parentProjectID)
        imageSelection = try container.decodeIfPresent(ImageSelection.self, forKey: .imageSelection)
    }
}

/// Serializable undo/redo checkpoint. Contains the editable project state at
/// a revision; identity, assets and provenance stay with the project. Bounded
/// by the store's undo depth so documents cannot grow without limit.
public struct MediaProjectMemento: Sendable, Codable, Hashable {
    public var revision: Int64
    public var canvas: MediaCanvas?
    /// Asset references are part of the undoable state: relinking or adding an
    /// asset must create a real transaction (and be undoable), which is also
    /// why no-op detection compares this field.
    public var assets: [MediaAssetReference]
    public var sourceAssetID: UUID?
    public var imageLayers: [ImageLayer]
    public var canvasAdjustment: CanvasAdjustment
    public var videoTimeline: VideoTimeline?
    /// Project-wide vector selection so selection edits are undoable.
    public var imageSelection: ImageSelection?

    public init(revision: Int64, canvas: MediaCanvas?, assets: [MediaAssetReference] = [],
                sourceAssetID: UUID? = nil, imageLayers: [ImageLayer],
                canvasAdjustment: CanvasAdjustment, videoTimeline: VideoTimeline?,
                imageSelection: ImageSelection? = nil) {
        self.revision = revision
        self.canvas = canvas
        self.assets = assets
        self.sourceAssetID = sourceAssetID
        self.imageLayers = imageLayers
        self.canvasAdjustment = canvasAdjustment
        self.videoTimeline = videoTimeline
        self.imageSelection = imageSelection
    }

    enum CodingKeys: String, CodingKey {
        case revision, canvas, assets, sourceAssetID, imageLayers, canvasAdjustment
        case videoTimeline, imageSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        canvas = try container.decodeIfPresent(MediaCanvas.self, forKey: .canvas)
        assets = try container.decodeIfPresent([MediaAssetReference].self, forKey: .assets) ?? []
        sourceAssetID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssetID)
        imageLayers = try container.decodeIfPresent([ImageLayer].self, forKey: .imageLayers) ?? []
        canvasAdjustment = try container.decodeIfPresent(CanvasAdjustment.self, forKey: .canvasAdjustment) ?? .init()
        videoTimeline = try container.decodeIfPresent(VideoTimeline.self, forKey: .videoTimeline)
        imageSelection = try container.decodeIfPresent(ImageSelection.self, forKey: .imageSelection)
    }
}

public extension MediaProject {
    /// Captures the editable state (not assets/identity) for durable undo.
    func memento() -> MediaProjectMemento {
        MediaProjectMemento(revision: revision, canvas: canvas, assets: assets,
                            sourceAssetID: sourceAssetID, imageLayers: imageLayers,
                            canvasAdjustment: canvasAdjustment, videoTimeline: videoTimeline,
                            imageSelection: imageSelection)
    }

    mutating func restore(_ memento: MediaProjectMemento) {
        canvas = memento.canvas
        assets = memento.assets
        sourceAssetID = memento.sourceAssetID ?? sourceAssetID
        imageLayers = memento.imageLayers
        canvasAdjustment = memento.canvasAdjustment
        videoTimeline = memento.videoTimeline
        imageSelection = memento.imageSelection
        // Revision is intentionally NOT restored: every transition advances
        // monotonically so proposal base revisions never alias via undo ABA.
        updatedAt = Date()
    }
}
