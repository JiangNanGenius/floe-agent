// FloeWorkbench — PreparedCore: document and envelope integrity.
//
// The validator is shared by the coordinator (before an instruction) and the
// store (before every prepared write). It is intentionally strict about the
// things the journal and renderers depend on: unique identities, resolvable
// hierarchy/clip/mask references, rational-time bounds, sorted keyframes and
// the v1-envelope <-> v2-document identity/revision binding.
//
// It never mutates the document and never repairs data silently.

import Foundation
import FloeCore

public enum MediaPreparedIntegrity {
    // MARK: Document

    public static func validate(_ document: MediaPreparedDocument) throws {
        guard document.schemaVersion == MediaPreparedSchema.documentVersion else {
            throw MediaPreparedCoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        guard document.revision >= 0 else {
            throw MediaPreparedCoreError.invalidDocument("revision is negative")
        }
        guard document.layers.count <= MediaPreparedSchema.maximumLayers else {
            throw MediaPreparedCoreError.limitsExceeded("layer count")
        }
        try requireUniqueIDs(document.assets.map(\.id), label: "asset")
        try requireUniqueIDs(document.layers.map(\.id), label: "layer")

        let assetIDs = Set(document.assets.map(\.id))
        guard document.assets.count <= 4_096,
              (document.assetRevisions ?? [:]).allSatisfy({ assetIDs.contains($0.key) && $0.value < UInt64.max }),
              document.sourceAssetID == nil || assetIDs.contains(document.sourceAssetID!) else {
            throw MediaPreparedCoreError.invalidDocument("asset generations or source identity")
        }
        let layerIDs = Set(document.layers.map(\.id))
        for layer in document.layers {
            try validate(layer, assetIDs: assetIDs, layerIDs: layerIDs)
        }
        try validateHierarchy(document.layers)
        try validateTrackGraph(document.trackGraph, assetIDs: assetIDs)
    }

    private static func validate(_ layer: MediaPreparedLayer,
                                 assetIDs: Set<UUID>, layerIDs: Set<UUID>) throws {
        // Empty layer names are preserved on upgrade; new name edits still
        // refuse an empty value in the engine.
        try validate(transform: layer.transform)
        try validate(adjustment: layer.adjustment)
        guard layer.opacity.isFinite, (0...1).contains(layer.opacity) else {
            throw MediaPreparedCoreError.invalidDocument("layer opacity must be 0...1")
        }
        try validate(layer.content, assetIDs: assetIDs)
        if let mask = layer.mask { try validate(mask) }
        if let clip = layer.clip {
            guard layerIDs.contains(clip.baseLayerID) else {
                throw MediaPreparedCoreError.invalidDocument(
                    "layer clip base \(clip.baseLayerID.uuidString) does not exist")
            }
            guard clip.baseLayerID != layer.id else {
                throw MediaPreparedCoreError.invalidDocument("layer clips to itself")
            }
        }
    }

    private static func validateHierarchy(_ layers: [MediaPreparedLayer]) throws {
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        for layer in layers {
            var visited = Set<UUID>()
            var cursor = layer.parentID
            while let parentID = cursor {
                guard parentID != layer.id else {
                    throw MediaPreparedCoreError.invalidDocument("layer is its own parent")
                }
                guard let parent = byID[parentID] else {
                    throw MediaPreparedCoreError.invalidDocument(
                        "parent layer \(parentID.uuidString) does not exist")
                }
                guard parent.contentKind == .group else {
                    throw MediaPreparedCoreError.invalidDocument("parent layer is not a group")
                }
                guard visited.insert(parentID).inserted else {
                    throw MediaPreparedCoreError.invalidDocument("layer hierarchy contains a cycle")
                }
                cursor = parent.parentID
            }
        }
        // A clipped layer must not itself be a clip base (no chains).
        let bases = Set(layers.compactMap { $0.clip?.baseLayerID })
        if let chained = layers.first(where: { bases.contains($0.id) && $0.clip != nil }) {
            throw MediaPreparedCoreError.invalidDocument(
                "clip chains are not supported (layer \(chained.id.uuidString))")
        }
    }

    private static func validate(_ content: MediaPreparedLayerContent,
                                 assetIDs: Set<UUID>) throws {
        switch content {
        case .raster(let raster):
            switch raster.source {
            case .asset(let id):
                guard assetIDs.contains(id) else {
                    throw MediaPreparedCoreError.invalidDocument(
                        "raster layer references missing asset \(id.uuidString)")
                }
            case .solidColor(let hex):
                guard isColorHex(hex) else {
                    throw MediaPreparedCoreError.invalidDocument("solid color must be #RRGGBB or #RRGGBBAA")
                }
            case .empty:
                break
            }
            if let crop = raster.crop { try validate(crop: crop) }

        case .text(let text):
            try validate(text: text)

        case .strokes(let strokes):
            try validate(freehand: strokes)

        case .vectorPaths(let path):
            try validate(path: path)

        case .group(let group):
            if let blend = group.blendMode, blend.isEmpty {
                throw MediaPreparedCoreError.invalidDocument("group blend mode is empty")
            }

        case .adjustment(let adjustment):
            try validate(adjustment: adjustment)
        }
    }

    private static func validate(transform: ImageLayerTransform) throws {
        guard transform.centerX.isFinite, transform.centerY.isFinite,
              (0...2).contains(transform.centerX), (0...2).contains(transform.centerY),
              transform.scale.isFinite, transform.scale > 0, transform.scale <= 20,
              transform.rotationDegrees.isFinite, abs(transform.rotationDegrees) <= 360 else {
            throw MediaPreparedCoreError.invalidDocument("invalid layer transform")
        }
    }

    private static func validate(crop: NormalizedRect) throws {
        guard (0...1).contains(crop.x), (0...1).contains(crop.y),
              crop.width > 0.01, crop.height > 0.01,
              crop.x + crop.width <= 1.0, crop.y + crop.height <= 1.0 else {
            throw MediaPreparedCoreError.invalidDocument("crop must fit inside the unit square")
        }
    }

    private static func validate(text: ImageTextContent) throws {
        guard !text.text.isEmpty, text.text.utf8.count <= 4_096 else {
            throw MediaPreparedCoreError.invalidDocument("text must be 1 byte...4 KiB")
        }
        guard (1...1_000).contains(text.fontSize) else {
            throw MediaPreparedCoreError.invalidDocument("font size must be 1...1000")
        }
        guard isColorHex(text.colorHex) else {
            throw MediaPreparedCoreError.invalidDocument("text color must be #RRGGBB")
        }
        if let strokeColor = text.strokeColorHex, !isColorHex(strokeColor) {
            throw MediaPreparedCoreError.invalidDocument("text stroke color must be #RRGGBB")
        }
    }

    private static func validate(freehand: ImageFreehandContent) throws {
        guard freehand.strokes.count <= 200 else {
            throw MediaPreparedCoreError.invalidDocument("freehand supports at most 200 strokes")
        }
        for stroke in freehand.strokes {
            guard (1...5_000).contains(stroke.points.count),
                  stroke.width.isFinite, (0...200).contains(stroke.width),
                  isColorHex(stroke.colorHex) else {
                throw MediaPreparedCoreError.invalidDocument("invalid freehand stroke")
            }
            if let hardness = stroke.hardness {
                guard hardness.isFinite, (0...1).contains(hardness) else {
                    throw MediaPreparedCoreError.invalidDocument("freehand hardness must be 0...1")
                }
            }
            if let opacity = stroke.opacity {
                guard opacity.isFinite, (0...1).contains(opacity) else {
                    throw MediaPreparedCoreError.invalidDocument("freehand opacity must be 0...1")
                }
            }
            for point in stroke.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...2).contains(point.x), (0...2).contains(point.y) else {
                    throw MediaPreparedCoreError.invalidDocument("freehand points must be normalized")
                }
                if let pressure = point.pressure {
                    guard pressure.isFinite, (0...1).contains(pressure) else {
                        throw MediaPreparedCoreError.invalidDocument("pressure must be 0...1")
                    }
                }
            }
        }
    }

    private static func validate(path: MediaVectorPath) throws {
        guard (1...1_024).contains(path.subpaths.count) else {
            throw MediaPreparedCoreError.invalidDocument("vector path needs 1...1024 subpaths")
        }
        guard path.strokeWidth.isFinite, (0...2_048).contains(path.strokeWidth),
              path.opacity.isFinite, (0...1).contains(path.opacity) else {
            throw MediaPreparedCoreError.invalidDocument("invalid vector stroke/opacity")
        }
        if let fill = path.fillColorHex, !isColorHex(fill) {
            throw MediaPreparedCoreError.invalidDocument("vector fill must be a color")
        }
        if let stroke = path.strokeColorHex, !isColorHex(stroke) {
            throw MediaPreparedCoreError.invalidDocument("vector stroke must be a color")
        }
        for subpath in path.subpaths {
            guard (1...8_192).contains(subpath.points.count) else {
                throw MediaPreparedCoreError.invalidDocument("vector subpath point count")
            }
            for point in subpath.points {
                try validate(point.point, label: "vector anchor")
                if let control = point.controlIn { try validate(control, label: "vector control") }
                if let control = point.controlOut { try validate(control, label: "vector control") }
            }
        }
    }

    private static func validate(_ point: ImageFreehandStroke.Point, label: String) throws {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw MediaPreparedCoreError.invalidDocument("\(label) must be normalized 0...1")
        }
    }

    private static func validate(_ mask: MediaPreparedLayerMask) throws {
        guard mask.strokes.count <= 512 else {
            throw MediaPreparedCoreError.invalidDocument("mask supports at most 512 strokes")
        }
        for stroke in mask.strokes {
            guard (2...512).contains(stroke.points.count),
                  stroke.width.isFinite, (1...2_048).contains(stroke.width) else {
                throw MediaPreparedCoreError.invalidDocument("invalid mask stroke")
            }
            if let hardness = stroke.hardness {
                guard hardness.isFinite, (0...1).contains(hardness) else {
                    throw MediaPreparedCoreError.invalidDocument("mask hardness must be 0...1")
                }
            }
            for point in stroke.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw MediaPreparedCoreError.invalidDocument("mask points must be normalized")
                }
            }
            if let region = stroke.region { try validate(selection: region) }
        }
        if let vector = mask.vector { try validate(selection: vector) }
    }

    private static func validate(selection: ImageSelection) throws {
        guard selection.shapes.count <= 64 else {
            throw MediaPreparedCoreError.invalidDocument("selection supports at most 64 shapes")
        }
        guard selection.feather.isFinite, (0...0.5).contains(selection.feather) else {
            throw MediaPreparedCoreError.invalidDocument("selection feather must be 0...0.5")
        }
        for shape in selection.shapes {
            switch shape.kind {
            case .rectangle, .ellipse:
                guard shape.points.count == 2 else {
                    throw MediaPreparedCoreError.invalidDocument("rectangle/ellipse needs two corners")
                }
            case .lasso:
                guard (3...512).contains(shape.points.count) else {
                    throw MediaPreparedCoreError.invalidDocument("lasso needs 3...512 points")
                }
            }
            for point in shape.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw MediaPreparedCoreError.invalidDocument("selection points must be normalized")
                }
            }
        }
    }

    private static func validate(adjustment: ImageLayerAdjustment) throws {
        if let saturation = adjustment.saturation {
            guard saturation.isFinite, (0...4).contains(saturation) else {
                throw MediaPreparedCoreError.invalidDocument("saturation must be 0...4")
            }
        }
        for value in [adjustment.contrast, adjustment.brightness].compactMap({ $0 }) {
            guard value.isFinite, abs(value) <= 4 else {
                throw MediaPreparedCoreError.invalidDocument("contrast/brightness out of range")
            }
        }
        if let ev = adjustment.exposureEV {
            guard ev.isFinite, abs(ev) <= 10 else {
                throw MediaPreparedCoreError.invalidDocument("exposure out of range")
            }
        }
        for value in [adjustment.blurRadius, adjustment.sharpenRadius].compactMap({ $0 }) {
            guard value.isFinite, (0...100).contains(value) else {
                throw MediaPreparedCoreError.invalidDocument("radius out of range")
            }
        }
        if let mosaic = adjustment.mosaicBlockSize {
            guard (1...512).contains(mosaic) else {
                throw MediaPreparedCoreError.invalidDocument("mosaic block out of range")
            }
        }
    }

    // MARK: Track graph

    private static func validateTrackGraph(_ graph: MediaPreparedTrackGraph,
                                           assetIDs: Set<UUID>) throws {
        guard graph.tracks.count <= MediaPreparedSchema.maximumTracks else {
            throw MediaPreparedCoreError.limitsExceeded("track count")
        }
        try requireUniqueIDs(graph.tracks.map(\.id), label: "track")
        try requireUniqueIDs(graph.tracks.flatMap { $0.clips.map(\.id) }, label: "clip")
        let clipCount = graph.tracks.reduce(0) { $0 + $1.clips.count }
        guard clipCount <= MediaPreparedSchema.maximumClips else {
            throw MediaPreparedCoreError.limitsExceeded("clip count")
        }
        if let frameRate = graph.frameRate {
            guard frameRate.timescale > 0, frameRate.value > 0, frameRate.seconds.isFinite else {
                throw MediaPreparedCoreError.invalidDocument("frame rate must be positive")
            }
        }
        guard graph.masterVolume.isFinite, (0...4).contains(graph.masterVolume) else {
            throw MediaPreparedCoreError.invalidDocument("master volume must be 0...4")
        }
        if let coverTime = graph.coverTime {
            guard coverTime.timescale > 0, coverTime.value >= 0 else {
                throw MediaPreparedCoreError.invalidDocument("cover time must be non-negative")
            }
        }
        for track in graph.tracks {
            guard !track.name.isEmpty else {
                throw MediaPreparedCoreError.invalidDocument("track name is empty")
            }
            guard track.volume.isFinite, (0...4).contains(track.volume) else {
                throw MediaPreparedCoreError.invalidDocument("track volume must be 0...4")
            }
            for clip in track.clips {
                try validate(clip, kind: track.kind, assetIDs: assetIDs)
            }
        }
    }

    private static func validate(_ clip: MediaPreparedClip, kind: MediaPreparedTrackKind,
                                 assetIDs: Set<UUID>) throws {
        try validate(range: clip.timelineRange)
        try validate(range: clip.sourceRange)
        guard clip.timelineRange.start.value >= 0, clip.sourceRange.start.value >= 0 else {
            throw MediaPreparedCoreError.invalidDocument("clip ranges must start at or after zero")
        }
        guard clip.speed.isFinite, (0.1...16).contains(clip.speed) else {
            throw MediaPreparedCoreError.invalidDocument("clip speed must be 0.1...16")
        }
        guard clip.volume.isFinite, (0...4).contains(clip.volume) else {
            throw MediaPreparedCoreError.invalidDocument("clip volume must be 0...4")
        }
        guard clip.rotationDegrees.isFinite,
              [0, 90, 180, 270, -90, -180, -270].contains(clip.rotationDegrees) else {
            throw MediaPreparedCoreError.invalidDocument("clip rotation must be 0/90/180/270")
        }
        if let crop = clip.crop {
            guard (0...1).contains(crop.x), (0...1).contains(crop.y),
                  crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= 1, crop.y + crop.height <= 1 else {
                throw MediaPreparedCoreError.invalidDocument("clip crop must fit the unit square")
            }
        }
        for fade in [clip.fadeIn, clip.fadeOut].compactMap({ $0 }) {
            guard fade.timescale > 0, fade.value >= 0 else {
                throw MediaPreparedCoreError.invalidDocument("clip fade must be non-negative")
            }
        }
        if let assetID = clip.assetID, !assetIDs.contains(assetID) {
            throw MediaPreparedCoreError.invalidDocument(
                "clip references missing asset \(assetID.uuidString)")
        }
        if kind == .caption {
            guard let text = clip.captionText, !text.isEmpty else {
                throw MediaPreparedCoreError.invalidDocument("caption clip needs text")
            }
        }
        switch clip.leadingTransition {
        case .none:
            break
        case .crossDissolve:
            guard let duration = clip.transitionDuration,
                  duration.value > 0, duration.seconds <= 2 else {
                throw MediaPreparedCoreError.invalidDocument("dissolve must be 0...2 seconds")
            }
        }
        var keyframeCount = 0
        var properties = Set<String>()
        for track in clip.keyframeTracks {
            guard !track.property.isEmpty, properties.insert(track.property).inserted else {
                throw MediaPreparedCoreError.invalidDocument("keyframe property is empty or duplicated")
            }
            keyframeCount += track.keyframes.count
            var previous: MediaRationalTime?
            for keyframe in track.keyframes {
                guard keyframe.time.timescale > 0,
                      keyframe.time.value >= 0,
                      keyframe.time.seconds <= clip.timelineRange.durationSeconds + 0.000_001 else {
                    throw MediaPreparedCoreError.invalidDocument("keyframe time is outside the clip")
                }
                if let previous, !(previous < keyframe.time) {
                    throw MediaPreparedCoreError.invalidDocument("keyframes must be strictly ordered")
                }
                previous = keyframe.time
                if case .number(let value) = keyframe.value, !value.isFinite {
                    throw MediaPreparedCoreError.invalidDocument("keyframe number is not finite")
                }
            }
        }
        guard keyframeCount <= MediaPreparedSchema.maximumKeyframesPerClip else {
            throw MediaPreparedCoreError.limitsExceeded("keyframe count")
        }
    }

    private static func validate(range: MediaTimeRange) throws {
        guard range.start.timescale > 0, range.duration.timescale > 0,
              range.start.timescale == range.duration.timescale,
              range.duration.value >= 0,
              range.start.value.addingReportingOverflow(range.duration.value).overflow == false
        else {
            throw MediaPreparedCoreError.invalidDocument("invalid rational time range")
        }
    }

    private static func requireUniqueIDs(_ ids: [UUID], label: String) throws {
        guard Set(ids).count == ids.count else {
            throw MediaPreparedCoreError.invalidDocument("duplicate \(label) identity")
        }
    }

    private static func isColorHex(_ value: String) -> Bool {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 || hex.count == 8 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }

    // MARK: Envelope coherence

    /// Validates the binding between the v1 envelope, the prepared document
    /// and its journal. Called by the store before every prepared write and by
    /// the coordinator on load, so a v2 document can never be silently
    /// replaced by a stale/missing projection.
    public static func validateEnvelope(_ project: MediaProject) throws {
        guard let prepared = project.prepared else {
            if let journal = project.preparedJournal, !journal.entries.isEmpty {
                throw MediaPreparedCoreError.invalidDocument(
                    "journal exists without a prepared document")
            }
            return
        }
        guard project.schemaVersion >= MediaPreparedSchema.documentVersion else {
            throw MediaPreparedCoreError.invalidDocument(
                "prepared document requires envelope schema v2")
        }
        try validate(prepared)
        guard prepared.id == project.id else {
            throw MediaPreparedCoreError.invalidDocument(
                "prepared document identity does not match the envelope")
        }
        guard prepared.revision == project.revision else {
            throw MediaPreparedCoreError.invalidDocument(
                "prepared document revision does not match the envelope")
        }
        guard prepared.kind == project.kind,
              prepared.name == project.name,
              prepared.canvas == project.canvas,
              prepared.sourceAssetID == project.sourceAssetID else {
            throw MediaPreparedCoreError.invalidDocument(
                "prepared metadata does not match the v1 envelope")
        }
        guard prepared.unknownOperations == project.unknownOperations else {
            throw MediaPreparedCoreError.invalidDocument(
                "unknown operations were not preserved between v1 and v2")
        }

        let journal = project.preparedJournal ?? MediaPreparedJournal()
        try requireUniqueIDs(journal.entries.map(\.id), label: "journal entry")
        for entry in journal.entries {
            guard entry.documentID == project.id else {
                throw MediaPreparedCoreError.invalidDocument(
                    "journal entry belongs to another document")
            }
            guard !entry.changes.isEmpty else {
                throw MediaPreparedCoreError.invalidDocument("journal entry has no changes")
            }
            guard entry.baseRevision <= entry.committedRevision,
                  entry.committedRevision <= prepared.revision else {
                throw MediaPreparedCoreError.invalidDocument("journal revision range is inconsistent")
            }
            var seen = Set<MediaPreparedObjectRef>()
            for change in entry.changes {
                guard seen.insert(change.ref).inserted else {
                    throw MediaPreparedCoreError.invalidDocument("journal repeats an object")
                }
                guard change.before != nil || change.after != nil else {
                    throw MediaPreparedCoreError.invalidDocument("journal change is empty")
                }
                switch change.ref.kind {
                case .asset, .layer, .track:
                    break
                case .clip:
                    guard change.containerID != nil else {
                        throw MediaPreparedCoreError.invalidDocument("clip change has no track")
                    }
                }
            }
        }
    }

    /// v1 content that remains in the envelope must not change once a
    /// prepared document exists: v2 writers own the prepared content. This is
    /// the store-level check that turns an old v1 autosave into a refusal
    /// instead of silent divergence/data loss.
    public static func v1ProjectionEqual(_ lhs: MediaProject, _ rhs: MediaProject) -> Bool {
        lhs.canvas == rhs.canvas
            && lhs.assets == rhs.assets
            && lhs.sourceAssetID == rhs.sourceAssetID
            && lhs.imageLayers == rhs.imageLayers
            && lhs.canvasAdjustment == rhs.canvasAdjustment
            && lhs.videoTimeline == rhs.videoTimeline
            && lhs.imageSelection == rhs.imageSelection
    }
}
