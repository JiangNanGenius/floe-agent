// FloeWorkbench — PreparedCore: opt-in media document schema v2 foundation.
//
// This is preparation for image/drawing/video work, not a SwiftUI surface and
// not a renderer. It extends the stable v1 `MediaProject` document with a
// prepared document that:
//   * models typed layer content (raster/text/strokes/vector paths/groups/
//     adjustments) plus mask and clip relationships;
//   * models a typed track graph with rational time and keyframe contracts;
//   * leaves the v1 document untouched until `MediaPreparedUpgrade` is called
//     explicitly, so current v1 UI behavior stays stable.
//
// Rendering, export, SwiftUI wiring and model-tool authorization are out of
// scope for this foundation. Callers must already be inside the existing
// task/permission boundary; this file adds no approval service and no second
// authority beside the document store.
//
// The instruction/lease/journal design follows the independently qualified
// drawing-session research prototype (per-object inverse changes plus revision
// guards, fenced stop, runtime-only leases). The prototype is NOT shipped as a
// competing model: these production types own the document, journal and
// compare-and-swap persistence.

import Foundation
import FloeCore

// MARK: - Errors

/// Structured failures of the prepared document engine and coordinator.
/// All cases are safe to surface to a developer UI; none contain user content.
public enum MediaPreparedCoreError: Error, Sendable, Hashable {
    case unsupportedSchemaVersion(Int)
    case documentNotFound(UUID)
    case notPrepared(UUID)
    case v1MutationRequiresPreparedEngine
    case invalidDocument(String)
    case invalidOperation(String)
    case limitsExceeded(String)
    case unknownObject(MediaPreparedObjectRef)
    case lockedObject(MediaPreparedObjectRef)
    case busyObject(MediaPreparedObjectRef)
    case staleObject(MediaPreparedObjectRef)
    case objectNotOwned(MediaPreparedObjectRef)
    case duplicateOperation(UUID)
    case unknownInstruction(UUID)
    case instructionFinished(UUID)
    case instructionStillRunning(UUID)
    case unknownGroup(UUID)
    case groupAlreadyUndone(UUID)
    case conflict(String)
    case documentChanged
}

extension MediaPreparedCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Media document schema v\(version) is newer than this build supports."
        case .documentNotFound(let id):
            "Media document \(id.uuidString) was not found."
        case .notPrepared(let id):
            "Media document \(id.uuidString) has not been explicitly upgraded to the prepared v2 schema."
        case .v1MutationRequiresPreparedEngine:
            "This project contains prepared v2 content; edit it through the prepared document engine so v2 data is not lost."
        case .invalidDocument(let detail):
            "Prepared media document is invalid: \(detail)"
        case .invalidOperation(let detail):
            "Prepared media operation is invalid: \(detail)"
        case .limitsExceeded(let detail):
            "Prepared media operation exceeds a bound: \(detail)"
        case .unknownObject(let ref):
            "Prepared media object \(ref.id.uuidString) (\(ref.kind.rawValue)) does not exist."
        case .lockedObject(let ref):
            "Prepared media object \(ref.id.uuidString) (\(ref.kind.rawValue)) is locked."
        case .busyObject(let ref):
            "Prepared media object \(ref.id.uuidString) (\(ref.kind.rawValue)) is leased by another instruction."
        case .staleObject(let ref):
            "Prepared media object \(ref.id.uuidString) (\(ref.kind.rawValue)) changed since the operation was prepared."
        case .objectNotOwned(let ref):
            "Instruction does not own prepared media object \(ref.id.uuidString) (\(ref.kind.rawValue))."
        case .duplicateOperation(let id):
            "Prepared media operation \(id.uuidString) was already applied."
        case .unknownInstruction(let id):
            "Prepared media instruction \(id.uuidString) is not active in this process."
        case .instructionFinished(let id):
            "Prepared media instruction \(id.uuidString) has already finished; late results are refused."
        case .instructionStillRunning(let id):
            "Prepared media instruction \(id.uuidString) is still running; stop it before undoing its group."
        case .unknownGroup(let id):
            "Prepared media edit group \(id.uuidString) is not in the durable journal."
        case .groupAlreadyUndone(let id):
            "Prepared media edit group \(id.uuidString) was already undone."
        case .conflict(let detail):
            "Prepared media edit conflicts with newer work: \(detail)"
        case .documentChanged:
            "The prepared media document changed on disk since this instruction started."
        }
    }
}

// MARK: - Schema bounds

public enum MediaPreparedSchema {
    /// Version carried by `MediaPreparedDocument`. The v1 envelope keeps its
    /// own version until the explicit upgrade adapter runs.
    public static let documentVersion = 2
    /// Canonical conversion timescale for v1 seconds -> v2 rational time.
    /// 90 kHz is the MPEG program timescale and exactly represents 24/25/30/60
    /// fps and 30000/1001 frame boundaries.
    public static let timelineTimescale: Int32 = 90_000
    public static let maximumLayers = 4_096
    public static let maximumTracks = 64
    public static let maximumClips = 4_096
    public static let maximumKeyframesPerClip = 4_096
    public static let maximumJournalEntries = 200
    public static let maximumOperationsPerApply = 512
}

// MARK: - Rational time

/// Exact rational time: `value / timescale` seconds. Rendering is not part of
/// this lane; the contract exists so downstream qualifiers share one time
/// representation instead of mixing floating-point seconds.
public struct MediaRationalTime: Sendable, Hashable, Comparable, Codable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else {
            throw MediaPreparedCoreError.invalidOperation("time timescale must be positive")
        }
        self.value = value
        self.timescale = timescale
    }

    /// Converts seconds with half-away-from-zero rounding at `timescale`.
    /// The conversion policy is explicit so a v1 upgrade is repeatable.
    public static func seconds(_ seconds: Double,
                               timescale: Int32 = MediaPreparedSchema.timelineTimescale) throws -> Self {
        guard seconds.isFinite, seconds >= 0 else {
            throw MediaPreparedCoreError.invalidOperation("time seconds must be finite and non-negative")
        }
        guard timescale > 0 else {
            throw MediaPreparedCoreError.invalidOperation("time timescale must be positive")
        }
        let scaled = seconds * Double(timescale)
        guard scaled <= Double(Int64.max) else {
            throw MediaPreparedCoreError.limitsExceeded("time exceeds Int64 at timescale \(timescale)")
        }
        return try Self(value: Int64(scaled.rounded(.toNearestOrAwayFromZero)), timescale: timescale)
    }

    public var seconds: Double {
        Double(value) / Double(timescale)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let (left, leftOverflow) = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let (right, rightOverflow) = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        if !leftOverflow, !rightOverflow { return left < right }
        return lhs.seconds < rhs.seconds
    }

    public func isApproximatelyEqual(to other: Self, toleranceSeconds: Double = 0) -> Bool {
        abs(seconds - other.seconds) <= toleranceSeconds
    }

    enum CodingKeys: String, CodingKey { case value, timescale }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        guard timescale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timescale, in: container,
                debugDescription: "time timescale must be positive")
        }
        self.value = value
        self.timescale = timescale
    }
}

/// Half-open rational interval `[start, start + duration)`. Start and duration
/// share a timescale to keep arithmetic exact.
public struct MediaTimeRange: Sendable, Hashable, Codable {
    public var start: MediaRationalTime
    public var duration: MediaRationalTime

    public init(start: MediaRationalTime, duration: MediaRationalTime) throws {
        guard duration.value >= 0 else {
            throw MediaPreparedCoreError.invalidOperation("time range duration must be non-negative")
        }
        guard start.timescale == duration.timescale else {
            throw MediaPreparedCoreError.invalidOperation("time range start/duration must share a timescale")
        }
        self.start = start
        self.duration = duration
    }

    public var startSeconds: Double { start.seconds }
    public var durationSeconds: Double { duration.seconds }
    public var endSeconds: Double { startSeconds + durationSeconds }

    public func contains(_ time: MediaRationalTime) -> Bool {
        time >= start && time.seconds < endSeconds
    }
}

// MARK: - Keyframes

public enum MediaKeyframeValue: Sendable, Codable, Hashable {
    case number(Double)
    case point(ImageFreehandStroke.Point)
    case colorHex(String)
    case boolean(Bool)
}

public enum MediaKeyframeInterpolation: String, Sendable, Codable, Hashable, CaseIterable {
    case hold
    case linear
    case easeIn
    case easeOut
    case cubicBezier
}

/// One keyframe in a property track. Times are relative to the clip start and
/// strictly ordered by `MediaPreparedIntegrity`.
public struct MediaKeyframe: Sendable, Codable, Hashable {
    public var time: MediaRationalTime
    public var value: MediaKeyframeValue
    public var interpolation: MediaKeyframeInterpolation
    public var curve: MediaCubicBezier?

    public init(time: MediaRationalTime, value: MediaKeyframeValue,
                interpolation: MediaKeyframeInterpolation = .linear, curve: MediaCubicBezier? = nil) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
        self.curve = curve
    }
}

public struct MediaKeyframeTrack: Sendable, Codable, Hashable {
    /// Dotted property path, for example `transform.opacity` or `transform.centerX`.
    public var property: String
    public var keyframes: [MediaKeyframe]

    public init(property: String, keyframes: [MediaKeyframe]) {
        self.property = property
        self.keyframes = keyframes
    }
}

// MARK: - Typed layer content

public enum MediaVectorLineCap: String, Sendable, Codable, Hashable {
    case butt, round, square
}

public enum MediaVectorLineJoin: String, Sendable, Codable, Hashable {
    case miter, round, bevel
}

public enum MediaVectorFillRule: String, Sendable, Codable, Hashable {
    case nonZero, evenOdd
}

/// One path anchor with optional cubic control points, all in normalized
/// canvas space (0...1, top-leading Y).
public struct MediaVectorPoint: Sendable, Codable, Hashable {
    public var point: ImageFreehandStroke.Point
    public var controlIn: ImageFreehandStroke.Point?
    public var controlOut: ImageFreehandStroke.Point?

    public init(point: ImageFreehandStroke.Point,
                controlIn: ImageFreehandStroke.Point? = nil,
                controlOut: ImageFreehandStroke.Point? = nil) {
        self.point = point
        self.controlIn = controlIn
        self.controlOut = controlOut
    }
}

public struct MediaVectorSubpath: Sendable, Codable, Hashable {
    public var points: [MediaVectorPoint]
    public var isClosed: Bool

    public init(points: [MediaVectorPoint], isClosed: Bool = false) {
        self.points = points
        self.isClosed = isClosed
    }
}

/// Non-destructive vector path layer content. Fill/stroke descriptors are
/// stored, never rasterized here.
public struct MediaVectorPath: Sendable, Codable, Hashable {
    public var subpaths: [MediaVectorSubpath]
    public var fillColorHex: String?
    public var strokeColorHex: String?
    public var strokeWidth: Double
    public var lineCap: MediaVectorLineCap
    public var lineJoin: MediaVectorLineJoin
    public var fillRule: MediaVectorFillRule
    public var opacity: Double

    public init(subpaths: [MediaVectorSubpath],
                fillColorHex: String? = "#000000",
                strokeColorHex: String? = nil,
                strokeWidth: Double = 0,
                lineCap: MediaVectorLineCap = .round,
                lineJoin: MediaVectorLineJoin = .round,
                fillRule: MediaVectorFillRule = .nonZero,
                opacity: Double = 1) {
        self.subpaths = subpaths
        self.fillColorHex = fillColorHex
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.fillRule = fillRule
        self.opacity = opacity
    }
}

public enum MediaRasterSource: Sendable, Codable, Hashable {
    /// Imported raster asset (the source bytes are never embedded).
    case asset(UUID)
    /// Solid-color layer masked by its vector mask/clip relationship.
    case solidColor(String)
    /// Empty raster layer (for future paint sessions).
    case empty
}

public struct MediaRasterContent: Sendable, Codable, Hashable {
    public var source: MediaRasterSource
    /// Non-destructive crop normalized to the source frame.
    public var crop: NormalizedRect?

    public init(source: MediaRasterSource, crop: NormalizedRect? = nil) {
        self.source = source
        self.crop = crop
    }
}

public struct MediaGroupContent: Sendable, Codable, Hashable {
    /// Isolated groups composite children before applying group opacity.
    public var isIsolated: Bool
    /// Optional blend identifier interpreted by a future renderer.
    public var blendMode: String?

    public init(isIsolated: Bool = false, blendMode: String? = nil) {
        self.isIsolated = isIsolated
        self.blendMode = blendMode
    }
}

public enum MediaPreparedLayerContentKind: String, Sendable, Codable, Hashable, CaseIterable {
    case raster
    case text
    case strokes
    case vectorPaths
    case group
    case adjustment
}

/// Typed layer payload. The v1 kinds map as:
/// image -> `.raster(.asset)`, fill -> `.raster(.solidColor)`, freehand ->
/// `.strokes`, text -> `.text`. `.vectorPaths`, `.group` and `.adjustment`
/// are new in v2.
public enum MediaPreparedLayerContent: Sendable, Codable, Hashable {
    case raster(MediaRasterContent)
    case text(ImageTextContent)
    case strokes(ImageFreehandContent)
    case vectorPaths(MediaVectorPath)
    case group(MediaGroupContent)
    case adjustment(ImageLayerAdjustment)

    public var kind: MediaPreparedLayerContentKind {
        switch self {
        case .raster: .raster
        case .text: .text
        case .strokes: .strokes
        case .vectorPaths: .vectorPaths
        case .group: .group
        case .adjustment: .adjustment
        }
    }
}

/// Destructive-looking v1 mask state is preserved non-destructively: mask
/// strokes, vector selection masks and region strokes stay declarative.
public struct MediaPreparedLayerMask: Sendable, Codable, Hashable {
    public var strokes: [ImageMaskStroke]
    public var vector: ImageSelection?
    public var isEnabled: Bool
    public var isInverted: Bool

    public init(strokes: [ImageMaskStroke] = [],
                vector: ImageSelection? = nil,
                isEnabled: Bool = true,
                isInverted: Bool = false) {
        self.strokes = strokes
        self.vector = vector
        self.isEnabled = isEnabled
        self.isInverted = isInverted
    }
}

public enum MediaPreparedClipMode: String, Sendable, Codable, Hashable {
    /// Clip to the base layer's alpha.
    case alpha
    /// Clip to the base layer's luminance.
    case luminance
}

/// Explicit clip relationship: this layer is clipped by `baseLayerID`.
public struct MediaPreparedClipRelationship: Sendable, Codable, Hashable {
    public var baseLayerID: UUID
    public var mode: MediaPreparedClipMode
    public var isInverted: Bool

    public init(baseLayerID: UUID, mode: MediaPreparedClipMode = .alpha,
                isInverted: Bool = false) {
        self.baseLayerID = baseLayerID
        self.mode = mode
        self.isInverted = isInverted
    }
}

// MARK: - Layer

/// One prepared layer. Hierarchy is expressed with `parentID` (group
/// membership) while the document's `layers` array owns z-order. Per-object
/// `revision` is the guard used by the journal so disjoint edits never block
/// each other and an overwritten object always conflicts.
public struct MediaPreparedLayer: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var parentID: UUID?
    public var name: String
    public var isVisible: Bool
    public var isLocked: Bool
    public var opacity: Double
    public var transform: ImageLayerTransform
    /// Per-layer non-destructive color/effect adjustments (v1 parity).
    public var adjustment: ImageLayerAdjustment
    public var content: MediaPreparedLayerContent
    public var canvasSpace: MediaLayerCanvasSpace?
    public var mask: MediaPreparedLayerMask?
    public var clip: MediaPreparedClipRelationship?
    public var revision: UInt64

    public init(id: UUID = UUID(), parentID: UUID? = nil, name: String,
                isVisible: Bool = true, isLocked: Bool = false, opacity: Double = 1,
                transform: ImageLayerTransform = .init(),
                adjustment: ImageLayerAdjustment = .init(),
                content: MediaPreparedLayerContent,
                mask: MediaPreparedLayerMask? = nil,
                clip: MediaPreparedClipRelationship? = nil,
                revision: UInt64 = 0) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.opacity = opacity
        self.transform = transform
        self.adjustment = adjustment
        self.content = content
        self.canvasSpace = nil
        self.mask = mask
        self.clip = clip
        self.revision = revision
    }

    public var contentKind: MediaPreparedLayerContentKind { content.kind }
}

// MARK: - Track graph

public enum MediaPreparedTrackKind: String, Sendable, Codable, Hashable, CaseIterable {
    case visual
    case audio
    case caption
    case adjustment
}

/// One clip in a typed track. Timeline and source ranges are rational time;
/// keyframe tracks describe animated properties without implementing
/// interpolation or rendering in this lane.
public struct MediaPreparedClip: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var assetID: UUID?
    public var timelineRange: MediaTimeRange
    public var sourceRange: MediaTimeRange
    public var speed: Double
    public var isMuted: Bool
    public var volume: Double
    /// Source rotation carried by the clip (0/90/180/270 for v1 material).
    public var rotationDegrees: Double
    /// Normalized crop inside the displayed source frame.
    public var crop: NormalizedRect?
    /// Audio fades for music/audio clips.
    public var videoMask: ImageSelection?
    public var fadeIn: MediaRationalTime?
    public var fadeOut: MediaRationalTime?
    /// Caption/title text for `.caption` tracks; nil for media clips.
    public var captionText: String?
    public var captionSource: CaptionSegment.CaptionSource?
    public var sourceCaptionID: UUID?
    public var captionLanguage: String?
    public var leadingTransition: VideoTransitionKind
    public var transitionDuration: MediaRationalTime?
    public var keyframeTracks: [MediaKeyframeTrack]
    public var revision: UInt64
    /// Explicit link for source audio extracted from this visual clip; never inferred from names.
    public var sourceVisualClipID: UUID?
    public var sourcePlayback: MediaSourcePlayback?
    public var motionTitle: MediaMotionTitle?
    public var audioProcessing: MediaAudioProcessing?
    public var chromaKey: MediaVideoChromaKey?
    public var blendMode: MediaVideoBlendMode?
    public var visualOpacity: Double?
    public var videoGrade: MediaVideoGrade?
    public var videoTracking: MediaVideoTracking?
    public var stabilization: MediaVideoStabilization?
    /// Editable one-level source. Only its anchor visual clip carries this value.
    public var compound: MediaPreparedCompound?
    public var compoundAudioOwnerID:UUID?

    public init(id: UUID = UUID(), assetID: UUID? = nil,
                timelineRange: MediaTimeRange, sourceRange: MediaTimeRange,
                speed: Double = 1, isMuted: Bool = false, volume: Double = 1,
                rotationDegrees: Double = 0, crop: NormalizedRect? = nil,
                videoMask: ImageSelection? = nil,
                fadeIn: MediaRationalTime? = nil, fadeOut: MediaRationalTime? = nil,
                captionText: String? = nil,
                captionSource: CaptionSegment.CaptionSource? = nil,
                leadingTransition: VideoTransitionKind = .none,
                transitionDuration: MediaRationalTime? = nil,
                keyframeTracks: [MediaKeyframeTrack] = [],
                revision: UInt64 = 0, sourceVisualClipID: UUID? = nil,
                sourcePlayback: MediaSourcePlayback? = nil, motionTitle: MediaMotionTitle? = nil, audioProcessing: MediaAudioProcessing? = nil, chromaKey: MediaVideoChromaKey? = nil,
                blendMode: MediaVideoBlendMode? = nil, visualOpacity: Double? = nil, videoGrade: MediaVideoGrade? = nil,
                videoTracking: MediaVideoTracking? = nil, stabilization: MediaVideoStabilization? = nil) {
        self.id = id
        self.assetID = assetID
        self.timelineRange = timelineRange
        self.sourceRange = sourceRange
        self.speed = speed
        self.isMuted = isMuted
        self.volume = volume
        self.rotationDegrees = rotationDegrees
        self.crop = crop
        self.videoMask = videoMask
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.captionText = captionText
        self.captionSource = captionSource
        self.sourceCaptionID = nil;self.captionLanguage = nil
        self.leadingTransition = leadingTransition
        self.transitionDuration = transitionDuration
        self.keyframeTracks = keyframeTracks
        self.revision = revision
        self.sourceVisualClipID = sourceVisualClipID
        self.sourcePlayback = sourcePlayback
        self.motionTitle = motionTitle
        self.audioProcessing = audioProcessing
        self.chromaKey = chromaKey;self.blendMode = blendMode;self.visualOpacity = visualOpacity;self.videoGrade = videoGrade
        self.videoTracking = videoTracking; self.stabilization = stabilization
        self.compound = nil;self.compoundAudioOwnerID=nil
    }
}

public struct MediaPreparedTrack: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: MediaPreparedTrackKind
    public var name: String
    public var isMuted: Bool
    public var isLocked: Bool
    public var volume: Double
    public var clips: [MediaPreparedClip]
    public var revision: UInt64

    public init(id: UUID = UUID(), kind: MediaPreparedTrackKind, name: String,
                isMuted: Bool = false, isLocked: Bool = false, volume: Double = 1,
                clips: [MediaPreparedClip] = [], revision: UInt64 = 0) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.volume = volume
        self.clips = clips
        self.revision = revision
    }
}

/// Typed track graph. Track array order is compositing/stack order.
public struct MediaPreparedTrackGraph: Sendable, Codable, Hashable {
    public var tracks: [MediaPreparedTrack]
    public var frameRate: MediaRationalTime?
    public var captionStyle: CaptionStyle?
    /// Independent generation for global subtitle style; absent in older
    /// documents means zero. Clip edits do not invalidate style-only undo.
    public var captionStyleRevision: UInt64?
    /// Master mix of clip audio (v1 `VideoTimeline.primaryVolume/Muted`).
    public var masterVolume: Double
    public var masterMuted: Bool
    /// Explicit cover frame; nil derives the first visual frame.
    public var coverTime: MediaRationalTime?

    public init(tracks: [MediaPreparedTrack] = [],
                frameRate: MediaRationalTime? = nil,
                captionStyle: CaptionStyle? = nil,
                captionStyleRevision: UInt64? = nil,
                masterVolume: Double = 1,
                masterMuted: Bool = false,
                coverTime: MediaRationalTime? = nil) {
        self.tracks = tracks
        self.frameRate = frameRate
        self.captionStyle = captionStyle
        self.captionStyleRevision = captionStyleRevision
        self.masterVolume = masterVolume
        self.masterMuted = masterMuted
        self.coverTime = coverTime
    }

    public func track(_ id: UUID) -> MediaPreparedTrack? {
        tracks.first { $0.id == id }
    }

    public func clip(id: UUID) -> (track: MediaPreparedTrack, clip: MediaPreparedClip)? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return (track, clip)
            }
        }
        return nil
    }

    public var totalDurationSeconds: Double {
        tracks.flatMap(\.clips).map(\.timelineRange.endSeconds).max() ?? 0
    }
}

// MARK: - Document

/// Prepared (v2) document content. It owns content, revision and the typed
/// layer/track state; per-view sessions never do. The v1 `MediaProject`
/// envelope owns persistence and compare-and-swap through `MediaProjectStore`.
public struct MediaPreparedDocument: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = MediaPreparedSchema.documentVersion

    public var schemaVersion: Int
    public var id: UUID
    public var kind: MediaProjectKind
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int64
    public var canvas: MediaCanvas?
    public var canvasRevision: UInt64?
    public var assets: [MediaAssetReference]
    /// Absent for the initial upgraded references; their generation is zero.
    public var assetRevisions: [UUID: UInt64]?
    public var sourceAssetID: UUID?
    public var layers: [MediaPreparedLayer]
    public var canvasAdjustment: ImageLayerAdjustment
    public var trackGraph: MediaPreparedTrackGraph
    /// Unknown operations are preserved byte-for-byte from the v1 envelope.
    public var unknownOperations: [UnknownOperation]
    /// v1 revision the content was upgraded from; nil for a document created
    /// directly in v2.
    public var upgradedFromRevision: Int64?

    public init(schemaVersion: Int = MediaPreparedDocument.currentSchemaVersion,
                id: UUID,
                kind: MediaProjectKind,
                name: String,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                revision: Int64 = 0,
                canvas: MediaCanvas? = nil,
                assets: [MediaAssetReference] = [],
                assetRevisions: [UUID: UInt64]? = nil,
                sourceAssetID: UUID? = nil,
                layers: [MediaPreparedLayer] = [],
                canvasAdjustment: ImageLayerAdjustment = .init(),
                trackGraph: MediaPreparedTrackGraph = .init(),
                unknownOperations: [UnknownOperation] = [],
                upgradedFromRevision: Int64? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.canvas = canvas
        self.canvasRevision = nil
        self.assets = assets
        self.assetRevisions = assetRevisions
        self.sourceAssetID = sourceAssetID
        self.layers = layers
        self.canvasAdjustment = canvasAdjustment
        self.trackGraph = trackGraph
        self.unknownOperations = unknownOperations
        self.upgradedFromRevision = upgradedFromRevision
    }

    public func layer(_ id: UUID) -> MediaPreparedLayer? {
        layers.first { $0.id == id }
    }

    public func asset(_ id: UUID) -> MediaAssetReference? {
        assets.first { $0.id == id }
    }
}

// MARK: - Immutable descriptors

/// Small immutable snapshot handed to downstream qualifiers. It carries
/// identity, revisions and typed content kinds, not mutable document state.
public struct MediaPreparedLayerDescriptor: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let contentKind: MediaPreparedLayerContentKind
    public let revision: UInt64
    public let isLocked: Bool
    public let isVisible: Bool
    public let hasMask: Bool
    public let hasAdjustment: Bool
    public let clipBaseLayerID: UUID?

    public init(id: UUID, parentID: UUID?, contentKind: MediaPreparedLayerContentKind,
                revision: UInt64, isLocked: Bool, isVisible: Bool,
                hasMask: Bool, hasAdjustment: Bool, clipBaseLayerID: UUID?) {
        self.id = id
        self.parentID = parentID
        self.contentKind = contentKind
        self.revision = revision
        self.isLocked = isLocked
        self.isVisible = isVisible
        self.hasMask = hasMask
        self.hasAdjustment = hasAdjustment
        self.clipBaseLayerID = clipBaseLayerID
    }
}

public struct MediaPreparedClipDescriptor: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let assetID: UUID?
    public let revision: UInt64
    public let timelineStartSeconds: Double
    public let timelineDurationSeconds: Double
    public let keyframeTrackCount: Int

    public init(id: UUID, assetID: UUID?, revision: UInt64,
                timelineStartSeconds: Double, timelineDurationSeconds: Double,
                keyframeTrackCount: Int) {
        self.id = id
        self.assetID = assetID
        self.revision = revision
        self.timelineStartSeconds = timelineStartSeconds
        self.timelineDurationSeconds = timelineDurationSeconds
        self.keyframeTrackCount = keyframeTrackCount
    }
}

public struct MediaPreparedTrackDescriptor: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: MediaPreparedTrackKind
    public let revision: UInt64
    public let clips: [MediaPreparedClipDescriptor]

    public init(id: UUID, kind: MediaPreparedTrackKind, revision: UInt64,
                clips: [MediaPreparedClipDescriptor]) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.clips = clips
    }
}

public struct MediaPreparedDocumentDescriptor: Sendable, Codable, Hashable {
    public let documentID: UUID
    public let revision: Int64
    public let schemaVersion: Int
    /// Bottom-to-top layer order; hierarchy is carried by `parentID`.
    public let layerOrder: [UUID]
    public let layers: [MediaPreparedLayerDescriptor]
    public let tracks: [MediaPreparedTrackDescriptor]

    public init(documentID: UUID, revision: Int64, schemaVersion: Int,
                layerOrder: [UUID], layers: [MediaPreparedLayerDescriptor],
                tracks: [MediaPreparedTrackDescriptor]) {
        self.documentID = documentID
        self.revision = revision
        self.schemaVersion = schemaVersion
        self.layerOrder = layerOrder
        self.layers = layers
        self.tracks = tracks
    }
}

public extension MediaPreparedDocument {
    var descriptor: MediaPreparedDocumentDescriptor {
        MediaPreparedDocumentDescriptor(
            documentID: id,
            revision: revision,
            schemaVersion: schemaVersion,
            layerOrder: layers.map(\.id),
            layers: layers.map { layer in
                MediaPreparedLayerDescriptor(
                    id: layer.id, parentID: layer.parentID,
                    contentKind: layer.contentKind, revision: layer.revision,
                    isLocked: layer.isLocked, isVisible: layer.isVisible,
                    hasMask: layer.mask != nil,
                    hasAdjustment: !layer.adjustment.isIdentity,
                    clipBaseLayerID: layer.clip?.baseLayerID)
            },
            tracks: trackGraph.tracks.map { track in
                MediaPreparedTrackDescriptor(
                    id: track.id, kind: track.kind, revision: track.revision,
                    clips: track.clips.map { clip in
                        MediaPreparedClipDescriptor(
                            id: clip.id, assetID: clip.assetID, revision: clip.revision,
                            timelineStartSeconds: clip.timelineRange.startSeconds,
                            timelineDurationSeconds: clip.timelineRange.durationSeconds,
                            keyframeTrackCount: clip.keyframeTracks.count)
                    })
            })
    }
}

// MARK: - Object identity

public enum MediaPreparedObjectKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// One global object per video document, identified by the document ID.
    case captionStyle
    case canvas
    case asset
    case layer
    case track
    case clip
}

/// Stable reference to one prepared object for leases and journal changes.
public struct MediaPreparedObjectRef: Sendable, Codable, Hashable, Identifiable {
    public var kind: MediaPreparedObjectKind
    public var id: UUID

    public init(kind: MediaPreparedObjectKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public var identity: UUID { id }
}

// MARK: - Operations

/// Minimal typed mutation vocabulary. Every operation carries its own stable
/// operation ID so duplicate or replayed callbacks are rejected. Expected
/// object revisions are evaluated after earlier operations in the same batch.
public struct MediaPreparedOperation: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var action: MediaPreparedAction

    public init(id: UUID = UUID(), action: MediaPreparedAction) {
        self.id = id
        self.action = action
    }
}

public enum MediaPreparedAction: Sendable, Codable, Hashable {
    /// One canonical root-clip journal change; inner operation IDs remain replay-fenced.
    case editCompound(clipID:UUID, expectedRevision:UInt64, operations:[MediaPreparedOperation])
    case layoutCanvas(expectedRevision: UInt64,canvas:MediaCanvas,mode:MediaCanvasLayoutMode)
    case setVideoColorProfile(expectedRevision: UInt64, profile: MediaVideoColorProfile?)
    case setLayerCanvasSpace(id:UUID,expectedRevision:UInt64,space:MediaLayerCanvasSpace?)
    case setCaptionStyle(expectedRevision: UInt64, style: CaptionStyle?)
    case insertAsset(MediaAssetReference)
    /// Logical removal only; active references refuse and historical bytes stay.
    case removeAsset(expected: MediaAssetReference, expectedRevision: UInt64)
    case replaceAsset(expected: MediaAssetReference, expectedRevision: UInt64, replacement: MediaAssetReference)
    // Layers
    case insertLayer(layer: MediaPreparedLayer, parentID: UUID?, index: Int?)
    case removeLayer(id: UUID, expectedRevision: UInt64)
    case replaceLayerContent(id: UUID, expectedRevision: UInt64,
                             content: MediaPreparedLayerContent)
    case updateLayerTransform(id: UUID, expectedRevision: UInt64,
                              transform: ImageLayerTransform)
    case updateLayerAdjustment(id: UUID, expectedRevision: UInt64,
                               adjustment: ImageLayerAdjustment)
    case updateLayerFlags(id: UUID, expectedRevision: UInt64, name: String?,
                          isVisible: Bool?, isLocked: Bool?, opacity: Double?)
    case moveLayer(id: UUID, expectedRevision: UInt64, parentID: UUID?, index: Int)
    case setLayerMask(id: UUID, expectedRevision: UInt64, mask: MediaPreparedLayerMask?)
    case setLayerClip(id: UUID, expectedRevision: UInt64,
                      clip: MediaPreparedClipRelationship?)

    // Tracks
    case insertTrack(track: MediaPreparedTrack, index: Int?)
    case removeTrack(id: UUID, expectedRevision: UInt64)
    case updateTrackFlags(id: UUID, expectedRevision: UInt64, name: String?,
                          isMuted: Bool?, isLocked: Bool?, volume: Double?)

    // Clips
    case replaceClip(trackID: UUID, clipID: UUID, expectedRevision: UInt64, clip: MediaPreparedClip)
    case insertClip(trackID: UUID, clip: MediaPreparedClip, index: Int?)
    case removeClip(trackID: UUID, clipID: UUID, expectedRevision: UInt64)
    case replaceClipKeyframes(trackID: UUID, clipID: UUID, expectedRevision: UInt64,
                              keyframeTracks: [MediaKeyframeTrack])
    case updateClipRange(trackID: UUID, clipID: UUID, expectedRevision: UInt64,
                         timelineRange: MediaTimeRange, sourceRange: MediaTimeRange)
}

// MARK: - Actor provenance

/// Provenance only: which surface proposed the instruction. It does not grant
/// authority. The existing tool/permission boundary stays authoritative.
public enum MediaPreparedActorKind: String, Sendable, Codable, Hashable {
    case user
    case model
}

// MARK: - Instruction handle

public struct MediaPreparedInstruction: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var actor: MediaPreparedActorKind
    public var targets: Set<MediaPreparedObjectRef>
    public var startedAt: Date

    public init(id: UUID, documentID: UUID, actor: MediaPreparedActorKind,
                targets: Set<MediaPreparedObjectRef>, startedAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.actor = actor
        self.targets = targets
        self.startedAt = startedAt
    }
}

// MARK: - View sessions

public enum MediaPreparedTool: String, Sendable, Codable, Hashable, CaseIterable {
    case select
    case hand
    case pen
    case eraser
    case text
    case vectorPath
    case mask
    case crop
}

public struct MediaPreparedViewport: Sendable, Codable, Hashable {
    public var originX: Double
    public var originY: Double
    public var zoom: Double

    public init(originX: Double = 0, originY: Double = 0, zoom: Double = 1) {
        self.originX = originX
        self.originY = originY
        self.zoom = zoom
    }
}

/// Per-view state only: which document the view shows, its viewport, selection
/// and active tool. Content, revision and saving stay with the document.
public struct MediaPreparedViewSession: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var viewport: MediaPreparedViewport
    public var selectedObjectIDs: Set<UUID>
    public var tool: MediaPreparedTool

    public init(id: UUID = UUID(), documentID: UUID,
                viewport: MediaPreparedViewport = .init(),
                selectedObjectIDs: Set<UUID> = [], tool: MediaPreparedTool = .select) {
        self.id = id
        self.documentID = documentID
        self.viewport = viewport
        self.selectedObjectIDs = selectedObjectIDs
        self.tool = tool
    }
}

/// Pure session registry. Two sessions may reference the same document; an
/// independent document is another documentID. Closing a session never
/// deletes content.
public struct MediaPreparedSessions: Sendable {
    public private(set) var sessions: [UUID: MediaPreparedViewSession] = [:]

    public init() {}

    @discardableResult
    public mutating func open(documentID: UUID,
                              tool: MediaPreparedTool = .select,
                              viewport: MediaPreparedViewport = .init()) -> MediaPreparedViewSession {
        let session = MediaPreparedViewSession(documentID: documentID,
                                               viewport: viewport, tool: tool)
        sessions[session.id] = session
        return session
    }

    public mutating func update(_ session: MediaPreparedViewSession) throws {
        guard sessions[session.id] != nil else {
            throw MediaPreparedCoreError.invalidOperation("view session does not exist")
        }
        sessions[session.id] = session
    }

    @discardableResult
    public mutating func close(_ sessionID: UUID) -> Bool {
        sessions.removeValue(forKey: sessionID) != nil
    }

    public func sessions(forDocument documentID: UUID) -> [MediaPreparedViewSession] {
        sessions.values.filter { $0.documentID == documentID }
    }

    public var documentIDs: Set<UUID> {
        Set(sessions.values.map(\.documentID))
    }
}
