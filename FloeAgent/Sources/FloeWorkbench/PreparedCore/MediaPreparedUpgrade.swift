// FloeWorkbench — PreparedCore: explicit v1 -> v2 upgrade adapter.
//
// The adapter is opt-in. Loading a v1 project and editing it through the v1
// commands keeps working exactly as before; only an explicit call here writes
// the prepared v2 document. Identity, layer/asset IDs, asset byte metadata,
// unknown-operation bytes and the v1 content projection are preserved. The v1
// revision is recorded in `upgradedFromRevision`; the envelope advances by one
// revision because the upgrade itself is a durable content transaction, which
// keeps the store's compare-and-swap / no-regression guard meaningful.

import Foundation
import FloeCore

public enum MediaPreparedUpgrade {
    /// Upgrades and returns the envelope with `prepared` + an empty journal.
    /// Idempotent: an envelope that is already prepared is returned unchanged.
    public static func upgrade(_ project: MediaProject) throws -> MediaProject {
        guard project.prepared == nil else { return project }
        guard project.schemaVersion <= MediaProject.currentSchemaVersion else {
            throw MediaPreparedCoreError.unsupportedSchemaVersion(project.schemaVersion)
        }

        let originalRevision = project.revision
        let now = Date()
        let document = try document(from: project, originalRevision: originalRevision,
                                    upgradedAt: now)

        var upgraded = project
        upgraded.schemaVersion = MediaProject.currentSchemaVersion
        upgraded.revision = originalRevision + 1
        upgraded.updatedAt = now
        upgraded.prepared = document
        upgraded.preparedJournal = MediaPreparedJournal()
        return upgraded
    }

    /// Builds only the prepared document for callers that already own an
    /// envelope; the returned revision is `project.revision + 1` to match the
    /// upgrade transaction. Prefer `upgrade(_:)` so the envelope and journal
    /// stay coherent.
    public static func document(from project: MediaProject,
                                originalRevision: Int64? = nil,
                                upgradedAt: Date = Date()) throws -> MediaPreparedDocument {
        guard project.schemaVersion <= MediaProject.currentSchemaVersion else {
            throw MediaPreparedCoreError.unsupportedSchemaVersion(project.schemaVersion)
        }
        let sourceRevision = originalRevision ?? project.revision
        let layers = project.imageLayers.enumerated().map { index, layer in
            preparedLayer(layer, index: index)
        }
        let graph = try trackGraph(from: project.videoTimeline, canvas: project.canvas)
        return MediaPreparedDocument(
            id: project.id,
            kind: project.kind,
            name: project.name,
            createdAt: project.createdAt,
            updatedAt: upgradedAt,
            revision: sourceRevision + 1,
            canvas: project.canvas,
            assets: project.assets,
            sourceAssetID: project.sourceAssetID,
            layers: layers,
            canvasAdjustment: project.canvasAdjustment,
            trackGraph: graph,
            unknownOperations: project.unknownOperations,
            upgradedFromRevision: sourceRevision)
    }

    /// One v1 layer -> typed v2 layer. The original layer ID is preserved; the
    /// original v1 layer remains in the envelope untouched.
    private static func preparedLayer(_ layer: ImageLayer, index: Int) -> MediaPreparedLayer {
        let content: MediaPreparedLayerContent
        switch layer.kind {
        case .image:
            content = .raster(MediaRasterContent(
                source: layer.assetID.map { MediaRasterSource.asset($0) } ?? .empty,
                crop: layer.crop))
        case .fill:
            content = .raster(MediaRasterContent(
                source: layer.fillColorHex.map { MediaRasterSource.solidColor($0) } ?? .empty,
                crop: layer.crop))
        case .text:
            content = .text(layer.text ?? ImageTextContent(text: layer.name))
        case .freehand:
            content = .strokes(layer.freehand ?? ImageFreehandContent())
        }

        var mask: MediaPreparedLayerMask?
        if layer.mask != nil || layer.selectionMask != nil {
            mask = MediaPreparedLayerMask(
                strokes: layer.mask?.strokes ?? [],
                vector: layer.selectionMask)
        }

        return MediaPreparedLayer(
            id: layer.id,
            parentID: nil,
            name: layer.name,
            isVisible: !layer.isHidden,
            isLocked: layer.isLocked,
            opacity: layer.opacity,
            transform: layer.transform,
            adjustment: layer.adjustment,
            content: content,
            mask: mask,
            clip: nil,
            revision: 0)
    }

    private static func trackGraph(from timeline: VideoTimeline?,
                                   canvas: MediaCanvas?) throws -> MediaPreparedTrackGraph {
        guard let timeline else {
            return MediaPreparedTrackGraph(
                frameRate: try frameRate(canvas?.frameRate), captionStyle: nil)
        }

        var tracks: [MediaPreparedTrack] = []

        if !timeline.clips.isEmpty {
            var clips: [MediaPreparedClip] = []
            for placed in MediaTimelineMath.placeClips(timeline.clips) {
                let clip = placed.clip
                let duration = placed.duration
                let timelineRange = try MediaTimeRange(
                    start: MediaRationalTime.seconds(placed.timelineStart),
                    duration: MediaRationalTime.seconds(duration))
                let sourceRange = try MediaTimeRange(
                    start: MediaRationalTime.seconds(clip.trimStart),
                    duration: MediaRationalTime.seconds(max(0, clip.trimEnd - clip.trimStart)))
                let transition = clip.leadingTransition == .none
                    ? nil
                    : try MediaRationalTime.seconds(clip.transitionDuration)
                clips.append(MediaPreparedClip(
                    id: clip.id,
                    assetID: clip.assetID,
                    timelineRange: timelineRange,
                    sourceRange: sourceRange,
                    speed: clip.speed,
                    isMuted: clip.isMuted,
                    volume: clip.volume,
                    rotationDegrees: clip.rotationDegrees,
                    crop: clip.crop,
                    leadingTransition: clip.leadingTransition,
                    transitionDuration: transition,
                    revision: 0))
            }
            tracks.append(MediaPreparedTrack(
                kind: .visual, name: "Video", clips: clips, revision: 0))
        }

        if !timeline.music.isEmpty {
            let clips = try timeline.music.map { music in
                MediaPreparedClip(
                    id: music.id,
                    assetID: music.assetID,
                    timelineRange: try MediaTimeRange(
                        start: MediaRationalTime.seconds(music.offsetSeconds),
                        duration: MediaRationalTime.seconds(music.lengthSeconds)),
                    sourceRange: try MediaTimeRange(
                        start: MediaRationalTime.seconds(music.trimStart),
                        duration: MediaRationalTime.seconds(music.lengthSeconds)),
                    volume: music.volume,
                    fadeIn: try MediaRationalTime.seconds(music.fadeInSeconds),
                    fadeOut: try MediaRationalTime.seconds(music.fadeOutSeconds),
                    revision: 0)
            }
            tracks.append(MediaPreparedTrack(
                kind: .audio, name: "Music", clips: clips, revision: 0))
        }

        if !timeline.captions.isEmpty {
            let clips = try timeline.captions.map { caption in
                MediaPreparedClip(
                    id: caption.id,
                    assetID: nil,
                    timelineRange: try MediaTimeRange(
                        start: MediaRationalTime.seconds(caption.start),
                        duration: MediaRationalTime.seconds(max(0, caption.end - caption.start))),
                    sourceRange: try MediaTimeRange(
                        start: MediaRationalTime.seconds(0),
                        duration: MediaRationalTime.seconds(0)),
                    captionText: caption.text,
                    captionSource: caption.source,
                    revision: 0)
            }
            tracks.append(MediaPreparedTrack(
                kind: .caption, name: "Captions", clips: clips, revision: 0))
        }

        return MediaPreparedTrackGraph(
            tracks: tracks,
            frameRate: try frameRate(canvas?.frameRate),
            captionStyle: timeline.captionStyle,
            masterVolume: timeline.primaryVolume,
            masterMuted: timeline.primaryMuted,
            coverTime: try timeline.coverTime.map { try MediaRationalTime.seconds($0) })
    }

    private static func frameRate(_ value: Double?) throws -> MediaRationalTime? {
        guard let value else { return nil }
        // Preserve exact broadcast rates when v1 stored their Double value.
        for numerator: Int64 in [24_000, 30_000, 60_000, 120_000] {
            if abs(value - Double(numerator) / 1_001) < 0.000_000_01 {
                return try MediaRationalTime(value: numerator, timescale: 1_001)
            }
        }
        return try MediaRationalTime.seconds(value, timescale: 1_000_000)
    }
}
