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
                guard let id = c.assetID, c.keyframeTracks.isEmpty, c.crop == nil, c.videoMask == nil,
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
        public var pendingPNGs: [UUID: Data]
    }

    static func importImage(_ input: PortableDocument, name: String) throws -> ImageImportResult {
        guard input.width > 0, input.height > 0, !input.layers.isEmpty, input.layers.count <= 256 else { throw ExchangeError.emptyDocument }
        try MediaCanvasLayout.validate(.init(width: input.width, height: input.height))
        var project = try MediaPreparedUpgrade.upgrade(MediaProject(kind: .image, name: name,
            canvas: .init(width: input.width, height: input.height)))
        var document = project.prepared!, bytes: [UUID: Data] = [:]
        var parents: [UUID] = [], bases: [Int: UUID] = [:]
        for (sourceIndex, source) in input.layers.enumerated() {
            guard source.depth >= 0, source.depth <= 16, source.depth <= parents.count,
                  !source.transparencyProtected else { throw ExchangeError.unsupportedLayerFeature(layer: source.name, feature: "hierarchy or protected alpha") }
            parents = Array(parents.prefix(source.depth))
            let parent = parents.last
            var layer: MediaPreparedLayer
            var outerLayerID: UUID?
            if source.group {
                if source.blendMode == "pass through" {
                    let descendants = input.layers.dropFirst(sourceIndex + 1).prefix { $0.depth > source.depth }
                    guard descendants.allSatisfy({ ($0.blendMode == "normal" || ($0.group && $0.blendMode == "pass through")) && !$0.clipping }) else {
                        throw ExchangeError.unsupportedLayerFeature(layer: source.name, feature: "pass-through group compositing")
                    }
                }
                let mode = source.blendMode == "pass through" ? "normal" : source.blendMode
                guard ["normal", "multiply", "screen", "overlay", "darken", "lighten", "difference", "exclusion"].contains(mode),
                      source.blendMode != "pass through" || (source.opacity == 1 && source.mask == nil) else {
                    throw ExchangeError.unsupportedBlendMode(source.blendMode)
                }
                layer = .init(parentID: parent, name: source.name, isVisible: source.visible, opacity: source.opacity,
                              content: .group(.init(isIsolated: true, blendMode: mode)))
            } else {
                let transform = ImageLayerTransform(centerX: (Double(source.left) + Double(source.image.width) / 2) / Double(input.width),
                    centerY: (Double(source.top) + Double(source.image.height) / 2) / Double(input.height),
                    scale: 1 / min(Double(input.width) / Double(source.image.width), Double(input.height) / Double(source.image.height)))
                if let text = source.text {
                    layer = .init(parentID: parent, name: source.name, isVisible: source.visible, opacity: source.opacity,
                        transform: .init(centerX: transform.centerX, centerY: transform.centerY),
                        content: .text(.init(text: text.text, fontSize: text.fontSize, colorHex: text.colorHex,
                            fontName: text.fontName, alignment: ImageTextAlignment(rawValue: text.alignment) ?? .left)))
                } else {
                    let id = UUID(), png = try PNGCodec.encode(source.image); bytes[id] = png
                    document.assets.append(.init(id: id, kind: .image, relativePath: "assets/\(id.uuidString).png", originalName: source.name + ".png", byteCount: Int64(png.count)))
                    layer = .init(parentID: parent, name: source.name, isVisible: source.visible, opacity: source.opacity,
                        transform: transform, content: .raster(.init(source: .asset(id))))
                }
                if source.blendMode != "normal" {
                    guard ["multiply", "screen", "overlay", "darken", "lighten", "difference", "exclusion"].contains(source.blendMode) else { throw ExchangeError.unsupportedBlendMode(source.blendMode) }
                    let wrapper = MediaPreparedLayer(parentID: parent, name: source.name, isVisible: source.visible,
                        opacity: source.opacity, content: .group(.init(isIsolated: true, blendMode: source.blendMode)))
                    document.layers.append(wrapper); outerLayerID = outerLayerID ?? wrapper.id; layer.parentID = wrapper.id; layer.opacity = 1; layer.isVisible = true
                }
            }
            if let mask = source.mask {
                guard input.width <= 2048, input.height <= 2048 else { throw ExchangeError.unsupportedLayerFeature(layer: source.name, feature: "mask exceeds the canonical coverage budget") }
                // Coverage remains exact. Large/complex masks that exceed the
                // canonical lossless budget fail conversion rather than shrink.
                var alpha = Data(repeating: mask.defaultColor, count: input.width * input.height)
                for y in 0..<mask.image.height {
                    let dy = source.top + mask.top + y
                    guard dy >= 0, dy < input.height else { continue }
                    for x in 0..<mask.image.width {
                        let dx = source.left + mask.left + x
                        if dx >= 0, dx < input.width { alpha[dy * input.width + dx] = mask.image.pixels[(y * mask.image.width + x) * 4] }
                    }
                }
                let selection = ImageSelection(bitmap: try .init(width: input.width, height: input.height, alpha: alpha))
                if source.group {
                    // Imported groups already use canvas coordinates. Keeping
                    // their mask here preserves blending against the backdrop.
                    layer.mask = .init(vector: selection, isEnabled: mask.isEnabled)
                } else {
                    // Raster coverage stays in document coordinates rather
                    // than being transformed with its source pixels.
                    let wrapper = MediaPreparedLayer(parentID: layer.parentID, name: layer.name, isVisible: layer.isVisible,
                        opacity: layer.opacity, content: .group(.init(isIsolated: true)), mask: .init(vector: selection, isEnabled: mask.isEnabled))
                    document.layers.append(wrapper); outerLayerID = outerLayerID ?? wrapper.id; layer.parentID = wrapper.id; layer.opacity = 1; layer.isVisible = true
                }
            }
            if source.clipping {
                guard let base = bases[source.depth] else { throw ExchangeError.unsupportedLayerFeature(layer: source.name, feature: "clipping without a base") }
                // Cross-parent clips are intentionally refused by canonical validation.
                if let outerLayerID, let index = document.layers.firstIndex(where: { $0.id == outerLayerID }) { document.layers[index].clip = .init(baseLayerID: base) }
                else { layer.clip = .init(baseLayerID: base) }
            }
            document.layers.append(layer)
            if !source.clipping { bases[source.depth] = outerLayerID ?? layer.id }
            if source.group { parents.append(layer.id) }
        }
        project.prepared = document
        try MediaPreparedIntegrity.validateEnvelope(project)
        return .init(project: project, pendingPNGs: bytes)
    }

    /// Geometry previews are rendered by the production renderer before this
    /// value adapter runs. Editable text stays typed; unsupported effects are
    /// refused so the complete original project remains the lossless route.
    static func exportImage(_ doc: MediaPreparedDocument, images: [UUID: RGBAImage],
                            layerPreviews: [UUID: PortableLayer] = [:], masks: [UUID: RGBAImage] = [:]) throws -> PortableDocument {
        try MediaPreparedIntegrity.validate(doc)
        guard doc.kind == .image, let canvas = doc.canvas, doc.canvasAdjustment == .init(), doc.unknownOperations.isEmpty else { throw ExchangeError.emptyDocument }
        var output: [PortableLayer] = []
        func collect(_ parent: UUID?, depth: Int) throws {
            guard depth <= 16 else { throw ExchangeError.layerCount(depth) }
            var clippingBase: UUID?
            for layer in doc.layers where layer.parentID == parent {
                if let clip = layer.clip {
                    guard clip.baseLayerID == clippingBase, clip.mode == .alpha, !clip.isInverted else {
                        throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "non-adjacent or luminance clipping")
                    }
                } else { clippingBase = layer.id }
                guard layer.adjustment.isIdentity, layer.canvasSpace == nil else { throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "live effects or canvas mapping") }
                var image: RGBAImage, left = 0, top = 0, group = false, text: PSDText?, blend = "normal"
                switch layer.content {
                case .group(let content):
                    guard content.isIsolated, layer.transform == .init() else { throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "non-isolated group or group transform") }
                    image = try .init(width: 1, height: 1, pixels: [0, 0, 0, 0]); group = true; blend = content.blendMode ?? "normal"
                case .raster(let raster):
                    guard case .asset(let id) = raster.source, let original = images[id] else { throw ExchangeError.missingLayerPixels(layer.name) }
                    if let preview = layerPreviews[layer.id] { image = preview.image; left = preview.left; top = preview.top }
                    else {
                        let scale = min(Double(canvas.width) / Double(original.width), Double(canvas.height) / Double(original.height)) * layer.transform.scale
                        guard raster.crop == nil, abs(scale - 1) < 0.000001, layer.transform.rotationDegrees == 0,
                              layer.transform.flipX != true, layer.transform.flipY != true else { throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "unresolved transform") }
                        image = original
                        left = Int((layer.transform.centerX * Double(canvas.width) - Double(image.width) / 2).rounded())
                        top = Int((layer.transform.centerY * Double(canvas.height) - Double(image.height) / 2).rounded())
                    }
                case .text(let content):
                    guard content.pathLayout == nil, content.shadow == nil, (content.strokeWidth ?? 0) == 0,
                          (content.tracking ?? 0) == 0, (content.leading ?? 0) == 0,
                          content.colorHex.count == 7 || (content.colorHex.count == 9 && content.colorHex.suffix(2).uppercased() == "FF"),
                          layer.transform.rotationDegrees == 0,
                          layer.transform.flipX != true, layer.transform.flipY != true,
                          let preview = layerPreviews[layer.id] else { throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "complex text layout") }
                    image = preview.image; left = preview.left; top = preview.top
                    text = .init(text: content.text, fontName: content.fontName ?? "Helvetica", fontSize: content.fontSize * layer.transform.scale,
                                 colorHex: String(content.colorHex.prefix(7)), alignment: content.alignment?.rawValue ?? "left")
                default: throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "non-raster content or live adjustment")
                }
                let mask: PortableMask?
                if let value = layer.mask {
                    guard let pixels = masks[layer.id] else { throw ExchangeError.missingMaskPixels(layer.name) }
                    mask = .init(image: pixels, left: -left, top: -top, isEnabled: value.isEnabled)
                } else { mask = nil }
                output.append(.init(name: layer.name, image: image, left: left, top: top, opacity: layer.opacity,
                    visible: layer.isVisible, blendMode: blend, clipping: layer.clip != nil, mask: mask, group: group, depth: depth, text: text))
                if group { try collect(layer.id, depth: depth + 1) }
            }
        }
        try collect(nil, depth: 0)
        return .init(width: canvas.width, height: canvas.height, layers: output)
    }
}
