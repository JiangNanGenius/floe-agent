// Freeze an explicit shared-document revision into the bounded renderer.
// No storage, environment selection or mutable editor state is created here.
import Foundation

public enum MediaPreparedVideoDocumentAdapter {
    public static func resolve(_ document: MediaPreparedDocument,
                               assetURLs: [UUID: URL], includeAudio: Bool = true) throws -> PreparedVideoPlan {
        try MediaPreparedIntegrity.validate(document)
        guard document.kind == .video, let canvas = document.canvas,
              let rawRate = document.trackGraph.frameRate else {
            throw PreparedVideoError.invalidPlan("video canvas and frame rate are required")
        }
        guard document.unknownOperations.isEmpty, document.layers.isEmpty else {
            throw PreparedVideoError.unsupportedCapability("unresolved operations or image layers")
        }
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? abs(a) : gcd(b, a % b) }
        let divisor = gcd(rawRate.value, Int64(rawRate.timescale))
        guard divisor > 0, let n = Int32(exactly: rawRate.value / divisor),
              let d = Int32(exactly: Int64(rawRate.timescale) / divisor) else {
            throw PreparedVideoError.invalidTime("frame rate cannot be represented")
        }
        let rate = try PreparedVideoFrameRate(numerator: n, denominator: d)
        // Drawing-path vertices and Bezier timing must not collapse to one
        // key per frame. The renderer samples this rational time at frame PTS.
        let scale: Int32 = 90_000
        func time(_ input: MediaRationalTime) throws -> PreparedVideoTime {
            try PreparedVideoTime(seconds: input.seconds, timescale: scale)
        }
        func range(_ input: MediaTimeRange) throws -> PreparedVideoTimeRange {
            try PreparedVideoTimeRange(start: time(input.start), duration: time(input.duration))
        }
        var visuals: [PreparedVideoTrack] = []
        var audio: [PreparedVideoAudioTrack] = []
        var captions: [PreparedVideoCaption] = []
        var used = Set<UUID>()
        for track in document.trackGraph.tracks {
            if track.kind == .audio && !includeAudio { continue }
            var visualClips: [PreparedVideoClip] = []
            var audioClips: [PreparedVideoAudioClip] = []
            for clip in track.clips {
                if track.kind == .caption {
                    if track.isMuted || clip.isMuted { continue }
                    guard clip.keyframeTracks.isEmpty, let text = clip.captionText else {
                        throw PreparedVideoError.unsupportedCapability("animated or empty caption")
                    }
                    captions.append(try PreparedVideoCaption(id: clip.id,
                        timelineRange: range(clip.timelineRange), text: text))
                    continue
                }
                switch track.kind {
                case .visual:
                    let content: PreparedVideoVisualContent
                    let source: PreparedVideoTimeRange?
                    var sourceCadence: Double?
                    if let title = clip.motionTitle {
                        try title.validate()
                        content = .text(.init(text: title.text, fontSize: title.fontSize,
                            color: try PreparedVideoColor(hex: title.colorHex),
                            backgroundColor: try title.backgroundHex.map { try PreparedVideoColor(hex: $0) }))
                        source = nil
                    } else {
                        guard let id = clip.assetID, let asset = document.assets.first(where: { $0.id == id }),
                              asset.kind == .video || asset.kind == .image else {
                            throw PreparedVideoError.invalidPlan("visual clip requires video, image or typed title")
                        }
                        used.insert(id)
                        if includeAudio, asset.kind == .video, !clip.isMuted, !track.isMuted,
                           !document.trackGraph.masterMuted, clip.volume > 0, track.volume > 0 {
                            guard asset.metadata?.audioTracks == 0 else {
                                throw PreparedVideoError.unsupportedCapability("extract video source audio before resolving")
                            }
                        }
                        content = asset.kind == .image ? .image(assetID: id) : .video(assetID: id)
                        source = try range(clip.sourceRange)
                        sourceCadence = clip.stabilization?.source.frameDuration ?? clip.videoTracking?.source.frameDuration
                            ?? (1 / max(1,asset.metadata?.frameRate ?? rate.fps))
                    }
                    for binding in [clip.videoTracking?.source, clip.stabilization?.source].compactMap({ $0 }) {
                        guard let asset = document.assets.first(where: { $0.id == binding.assetID }),
                              asset.kind == .video, (document.assetRevisions?[asset.id] ?? 0) == binding.assetRevision,
                              asset.contentHash == nil || asset.contentHash == binding.contentHash else {
                            throw MediaPreparedCoreError.invalidOperation("motion source changed; re-analyze this clip")
                        }
                    }
                    if let match = clip.videoGrade?.colorMatch {
                        guard let asset = document.assets.first(where: { $0.id == match.target.assetID }),
                              asset.id == clip.assetID, (document.assetRevisions?[asset.id] ?? 0) == match.target.assetRevision,
                              asset.contentHash == nil || asset.contentHash == match.target.contentHash else {
                            throw MediaPreparedCoreError.invalidOperation("color-match target source changed; sample it again")
                        }
                    }
                    guard clip.crop == nil else {
                        throw PreparedVideoError.unsupportedCapability("source crop adapter")
                    }
                    let keyframes = try MediaAnimation.preparedTracks(clip.keyframeTracks,timescale:scale)
                    let transition: PreparedVideoTransition?
                    if clip.leadingTransition == .crossDissolve, let duration = clip.transitionDuration {
                        transition = try .init(kind: .crossDissolve, duration: time(duration))
                    } else { transition = nil }
                    var mask: PreparedVideoMask?
                    if let selection = clip.videoMask {
                        guard selection.shapes.count == 1, let shape = selection.shapes.first,
                              shape.operation == .replace, shape.points.count == 2,
                              shape.kind != .lasso else { throw PreparedVideoError.unsupportedCapability("compound video mask") }
                        let a = shape.points[0], b = shape.points[1]
                        mask = .init(shape: shape.kind == .rectangle ? .rectangle : .ellipse,
                            centerX: (a.x + b.x) / 2, centerY: (a.y + b.y) / 2,
                            width: abs(a.x - b.x), height: abs(a.y - b.y),
                            feather: selection.feather, isInverted: selection.inverted)
                    }
                    visualClips.append(try PreparedVideoClip(
                        id: clip.id, content: content,
                        timelineRange: range(clip.timelineRange), sourceRange: source,
                        speed: clip.speed, opacity: clip.visualOpacity ?? 1, transform: .init(rotationDegrees: clip.rotationDegrees),
                        keyframes: keyframes, mask: mask, leadingTransition: transition,
                        sourcePlayback: clip.sourcePlayback,
                        sourceFrameDuration: sourceCadence,chromaKey:clip.chromaKey,blendMode:clip.blendMode,videoGrade:clip.videoGrade,videoTracking:clip.videoTracking,stabilization:clip.stabilization))
                case .audio:
                    if clip.sourcePlayback?.holdSeconds != nil { continue }
                    guard let id = clip.assetID, let asset = document.assets.first(where: { $0.id == id }),
                          asset.kind == .audio, clip.keyframeTracks.isEmpty else {
                        throw PreparedVideoError.unsupportedCapability("audio asset or animation")
                    }
                    used.insert(id)
                    audioClips.append(try .init(id: clip.id, assetID: id,
                        timelineRange: range(clip.timelineRange), sourceRange: range(clip.sourceRange),
                        volume: clip.isMuted || clip.sourcePlayback?.holdSeconds != nil ? 0 : clip.volume,
                        fadeInSeconds: clip.fadeIn?.seconds ?? 0, fadeOutSeconds: clip.fadeOut?.seconds ?? 0, speed: clip.speed, isReversed: clip.sourcePlayback?.isReversed))
                case .caption: break
                case .adjustment:
                    throw PreparedVideoError.unsupportedCapability("adjustment track")
                }
            }
            switch track.kind {
            case .visual: visuals.append(.init(id: track.id, name: track.name, isHidden: track.isMuted, clips: visualClips))
            case .audio:
                let plain = audioClips.filter { clip in track.clips.first(where:{$0.id == clip.id})?.audioProcessing?.isEmpty != false }
                if !plain.isEmpty { audio.append(.init(id:track.id,name:track.name,isMuted:track.isMuted,volume:track.volume,clips:plain)) }
                for clip in audioClips {
                    guard let effects = track.clips.first(where:{$0.id == clip.id})?.audioProcessing,!effects.isEmpty else { continue }
                    try effects.validate()
                    audio.append(.init(id:clip.id,name:track.name,isMuted:track.isMuted,volume:track.volume,
                        eqBands:effects.eqBands,dynamics:effects.dynamics,limiter:effects.limiter,clips:[clip]))
                }
            case .caption: break
            case .adjustment: throw PreparedVideoError.unsupportedCapability("adjustment track")
            }
        }
        let assets = try document.assets.filter { used.contains($0.id) }.map { asset -> PreparedVideoAsset in
            guard let url = assetURLs[asset.id], url.isFileURL else {
                throw PreparedVideoError.missingAsset(asset.id)
            }
            guard let kind = PreparedVideoAssetKind(rawValue: asset.kind.rawValue) else {
                throw PreparedVideoError.invalidPlan("asset kind")
            }
            return PreparedVideoAsset(id: asset.id, url: url, kind: kind,
                                      contentHash: asset.contentHash)
        }
        let style = document.trackGraph.captionStyle ?? CaptionStyle()
        let alignment: PreparedVideoTextAlignment = switch style.alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
        let captionStyle = try PreparedVideoCaptionStyle(
            fontSize: style.fontSize, color: PreparedVideoColor(hex: style.colorHex),
            backgroundColor: style.backgroundHex.map { try PreparedVideoColor(hex: $0) },
            positionY: style.positionY, alignment: alignment,
            respectsSafeArea: style.respectsSafeArea ?? true)
        return try PreparedVideoPlan(
            id: .init(projectID: document.id, revision: document.revision),
            timeScale: scale, frameRate: rate,
            duration: PreparedVideoTime(seconds: document.trackGraph.totalDurationSeconds, timescale: scale),
            canvas: .init(width: canvas.width, height: canvas.height), assets: assets,
            visualTracks: visuals, captions: captions, captionStyle: captionStyle,
            audio: .init(tracks: audio, masterVolume: document.trackGraph.masterMuted ? 0 : document.trackGraph.masterVolume),colorProfile: canvas.videoColorProfile)
    }
}
