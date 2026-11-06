// Qualification integration onto the canonical v2 document. No parallel store.
import Foundation
import CryptoKit
import FloeWorkbench
import MediaExchangeCore

public enum MediaPreparedExchangeBridge {
    public struct ImportResult: Sendable {
        public var project: MediaProject
        /// Host retains this alongside the original imported file. Unsupported
        /// metadata and external identifiers never disappear during conversion.
        public var originalTimeline: Data
        public var identifiers: [String: UUID]
    }
    private static func time(_ t: MediaRationalTime) throws -> ExchangeTime {
        try .init(value: t.value, timescale: Int64(t.timescale))
    }
    private static func reject(_ detail: String) throws -> Never {
        throw ExchangePathError.unsupportedEffectOnExport(detail)
    }
    public static func exportTimeline(_ doc: MediaPreparedDocument,
                                      sources: [UUID: ExchangeMediaSource]) throws -> ExchangeTimeline {
        try MediaPreparedIntegrity.validate(doc)
        guard doc.kind == .video, doc.layers.isEmpty, doc.unknownOperations.isEmpty,
              let fps = doc.trackGraph.frameRate,
              doc.trackGraph.masterVolume == 1, !doc.trackGraph.masterMuted else {
            try reject("document or master effects")
        }
        let media = try doc.assets.map { a -> ExchangeMediaReference in
            guard let source = sources[a.id], let kind = ExchangeMediaKind(rawValue: a.kind.rawValue) else {
                throw ExchangePathError.missingMediaID(a.id.uuidString)
            }
            return .init(id: a.id.uuidString, kind: kind, name: a.originalName, source: source,
                         hasVideo: a.kind != .audio, hasAudio: a.kind == .audio || (a.metadata?.audioTracks ?? 0) > 0,
                         contentHash: a.contentHash, byteCount: a.byteCount)
        }
        let tracks = try doc.trackGraph.tracks.map { track -> ExchangeTrack in
            guard track.kind == .visual || track.kind == .audio,
                  !track.isMuted, track.volume == 1 else { try reject("track effects or captions") }
            let items = try track.clips.sorted { $0.timelineRange.start < $1.timelineRange.start }.map { c -> ExchangeTimelineItem in
                guard let id = c.assetID, c.keyframeTracks.isEmpty, c.crop == nil,
                      c.rotationDegrees == 0, c.volume == 1, !c.isMuted,
                      c.fadeIn == nil || c.fadeIn?.value == 0,
                      c.fadeOut == nil || c.fadeOut?.value == 0,
                      c.leadingTransition == .none else { try reject("clip effects") }
                let speed = try ExchangeTime(value: Int64((c.speed * 1_000_000).rounded()), timescale: 1_000_000)
                return try .clip(.init(id: c.id.uuidString, name: track.name, mediaID: id.uuidString,
                    start: time(c.timelineRange.start), duration: time(c.timelineRange.duration),
                    sourceStart: time(c.sourceRange.start), retime: c.speed == 1 ? nil : .init(rate: speed)))
            }
            return .init(id: track.id.uuidString, kind: track.kind == .visual ? .video : .audio,
                         name: track.name, items: items)
        }
        let result = try ExchangeTimeline(id: doc.id.uuidString, name: doc.name,
            frameRate: ExchangeFrameRate(numerator: fps.value, denominator: Int64(fps.timescale)),
            tracks: tracks, media: media, sourceRevision: UInt64(doc.revision))
        try result.validate()
        return result
    }

    /// The host supplies imported/staged assets and an explicit canvas. No URL
    /// grants access, chooses a workspace or transfers ownership in this API.
    public static func importTimeline(_ timeline: ExchangeTimeline, canvas: MediaCanvas,
                                      assets: [String: MediaAssetReference]) throws -> ImportResult {
        try timeline.validate()
        guard timeline.globalStart.isZero, timeline.markers.isEmpty else { try reject("global start or markers") }
        var identities: [String: UUID] = [:]
        func identity(_ text: String) -> UUID {
            if let uuid = UUID(uuidString: text) { identities[text] = uuid; return uuid }
            let hex = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            let positions = [8, 12, 16, 20]
            let formatted = hex.enumerated().map { (positions.contains($0.offset) ? "-" : "") + String($0.element) }.joined()
            let uuid = UUID(uuidString: formatted)!
            identities[text] = uuid
            return uuid
        }
        func rational(_ t: ExchangeTime) throws -> MediaRationalTime {
            guard let scale = Int32(exactly: t.timescale) else { throw ExchangeTimeError.overflow }
            return try .init(value: t.value, timescale: scale)
        }
        var project = MediaProject(id: identity(timeline.id), kind: .video, name: timeline.name,
                                   canvas: canvas, assets: try timeline.media.map { reference in
            guard let asset = assets[reference.id] else { throw ExchangePathError.missingMediaID(reference.id) }
            return asset
        })
        for reference in timeline.media {
            guard let asset = assets[reference.id], asset.kind.rawValue == reference.kind.rawValue else {
                throw ExchangePathError.missingMediaID(reference.id)
            }
        }
        project = try MediaPreparedUpgrade.upgrade(project)
        var doc = project.prepared!
        guard let denominator = Int32(exactly: timeline.frameRate.denominator) else { throw ExchangeTimeError.overflow }
        doc.trackGraph.frameRate = try .init(value: timeline.frameRate.numerator, timescale: denominator)
        doc.trackGraph.tracks = try timeline.tracks.map { track -> MediaPreparedTrack in
            guard track.kind != .subtitle else { try reject("subtitle track conversion") }
            let clips = try track.items.compactMap { item -> MediaPreparedClip? in
                guard case .clip(let c) = item else { return nil } // gaps stay as empty intervals
                guard c.enabled, c.effects.isEmpty, c.markers.isEmpty, c.captions.isEmpty,
                      let asset = assets[c.mediaID] else { try reject("disabled clip, effect, marker or caption") }
                let speed = c.retime?.rate.seconds ?? 1
                let sourceDuration = try c.duration.multiplied(by: c.retime?.rate ?? ExchangeTime(value: 1, timescale: 1))
                return try .init(id: identity(c.id), assetID: asset.id,
                    timelineRange: .init(start: rational(c.start), duration: rational(c.duration)),
                    sourceRange: .init(start: rational(c.sourceStart), duration: rational(sourceDuration)), speed: speed)
            }
            return .init(id: identity(track.id), kind: track.kind == .video ? .visual : .audio,
                         name: track.name, clips: clips)
        }
        project.prepared = doc
        try MediaPreparedIntegrity.validateEnvelope(project)
        return .init(project: project, originalTimeline: try JSONEncoder().encode(timeline), identifiers: identities)
    }
}

public extension MediaPreparedExchangeBridge {
    struct ImageImportResult: Sendable {
        public var project: MediaProject
        /// The existing importer commits these immutable PNGs before saving
        /// the project; this adapter never writes files or assumes a workspace.
        public var pendingPNGs: [UUID: Data]
    }

    static func importImage(_ input: PortableDocument, name: String) throws -> ImageImportResult {
        guard input.width > 0, input.height > 0, !input.layers.isEmpty else { throw ExchangeError.emptyDocument }
        var project = MediaProject(kind: .image, name: name,
                                   canvas: .init(width: input.width, height: input.height))
        var bytes: [UUID: Data] = [:]
        for source in input.layers {
            guard source.blendMode == "normal", !source.clipping, !source.transparencyProtected,
                  source.mask == nil else { throw ExchangeError.unsupportedLayerFeature(layer: source.name, feature: "blend, clipping, protected alpha or mask") }
            let id = UUID()
            let png = try PNGCodec.encode(source.image)
            bytes[id] = png
            project.assets.append(.init(id: id, kind: .image, relativePath: "assets/\(id.uuidString).png",
                                        originalName: source.name + ".png", byteCount: Int64(png.count)))
            let transform = ImageLayerTransform(
                centerX: (Double(source.left) + Double(source.image.width) / 2) / Double(input.width),
                centerY: (Double(source.top) + Double(source.image.height) / 2) / Double(input.height))
            project.imageLayers.append(.init(kind: .image, name: source.name, assetID: id,
                transform: transform, opacity: source.opacity, isHidden: !source.visible))
        }
        return try .init(project: MediaPreparedUpgrade.upgrade(project), pendingPNGs: bytes)
    }

    static func exportImage(_ doc: MediaPreparedDocument, images: [UUID: RGBAImage]) throws -> PortableDocument {
        try MediaPreparedIntegrity.validate(doc)
        guard doc.kind == .image, let canvas = doc.canvas,
              doc.canvasAdjustment == .init(), doc.unknownOperations.isEmpty else { throw ExchangeError.emptyDocument }
        let layers = try doc.layers.map { layer -> PortableLayer in
            guard case .raster(let raster) = layer.content, case .asset(let id) = raster.source,
                  let image = images[id], raster.crop == nil, layer.mask == nil, layer.clip == nil,
                  layer.parentID == nil, layer.adjustment == .init(), layer.transform.scale == 1,
                  layer.transform.rotationDegrees == 0, layer.transform.flipX != true, layer.transform.flipY != true else {
                throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "non-raster content or effects")
            }
            let left = layer.transform.centerX * Double(canvas.width) - Double(image.width) / 2
            let top = layer.transform.centerY * Double(canvas.height) - Double(image.height) / 2
            guard abs(left - left.rounded()) < 0.000001, abs(top - top.rounded()) < 0.000001 else {
                throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "fractional pixel position")
            }
            return .init(name: layer.name, image: image, left: Int(left.rounded()), top: Int(top.rounded()),
                         opacity: layer.opacity, visible: layer.isVisible)
        }
        return .init(width: canvas.width, height: canvas.height, layers: layers)
    }
}
