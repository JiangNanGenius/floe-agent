// Freeze an explicit shared-document revision into the bounded renderer.
// No storage, environment selection or mutable editor state is created here.
import Foundation

public enum MediaPreparedVideoDocumentAdapter {
    public static func resolve(_ document: MediaPreparedDocument,
                               assetURLs: [UUID: URL]) throws -> PreparedVideoPlan {
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
        let scale = rate.numerator
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
            var visualClips: [PreparedVideoClip] = []
            var audioClips: [PreparedVideoAudioClip] = []
            for clip in track.clips {
                if track.kind == .caption {
                    guard clip.keyframeTracks.isEmpty, let text = clip.captionText else {
                        throw PreparedVideoError.unsupportedCapability("animated or empty caption")
                    }
                    captions.append(try PreparedVideoCaption(id: clip.id,
                        timelineRange: range(clip.timelineRange), text: text))
                    continue
                }
                guard let id = clip.assetID, let asset = document.assets.first(where: { $0.id == id }) else {
                    throw PreparedVideoError.invalidPlan("clip requires an asset")
                }
                used.insert(id)
                switch track.kind {
                case .visual:
                    guard asset.kind == .video || asset.kind == .image else {
                        throw PreparedVideoError.invalidPlan("visual clip requires video or image")
                    }
                    // Refuse a lossy projection. These properties stay editable
                    // in the shared document until their render adapter lands.
                    guard clip.crop == nil else {
                        throw PreparedVideoError.unsupportedCapability("source crop adapter")
                    }
                    if asset.kind == .video, !clip.isMuted, !track.isMuted,
                       !document.trackGraph.masterMuted, clip.volume > 0, track.volume > 0 {
                        guard asset.metadata?.audioTracks == 0 else {
                            throw PreparedVideoError.unsupportedCapability("extract video source audio before resolving")
                        }
                    }
                    let keyframes = try clip.keyframeTracks.map { keyTrack -> PreparedVideoKeyframeTrack in
                        let propertyName = keyTrack.property.replacingOccurrences(of: "transform.", with: "")
                        guard let property = PreparedVideoAnimatableProperty(rawValue: propertyName) else {
                            throw PreparedVideoError.unsupportedCapability("keyframe property")
                        }
                        let keys = try keyTrack.keyframes.map { key -> PreparedVideoKeyframe in
                            guard case .number(let value) = key.value,
                                  let interpolation = PreparedVideoInterpolation(rawValue: key.interpolation.rawValue) else {
                                throw PreparedVideoError.unsupportedCapability("keyframe value")
                            }
                            return try PreparedVideoKeyframe(time: time(key.time), value: value,
                                                             interpolation: interpolation)
                        }
                        return .init(property: property, keyframes: keys)
                    }
                    let transition: PreparedVideoTransition?
                    if clip.leadingTransition == .crossDissolve, let duration = clip.transitionDuration {
                        transition = try .init(kind: .crossDissolve, duration: time(duration))
                    } else { transition = nil }
                    visualClips.append(try PreparedVideoClip(
                        id: clip.id, content: asset.kind == .image ? .image(assetID: id) : .video(assetID: id),
                        timelineRange: range(clip.timelineRange), sourceRange: range(clip.sourceRange),
                        speed: clip.speed, transform: .init(rotationDegrees: clip.rotationDegrees),
                        keyframes: keyframes, leadingTransition: transition))
                case .audio:
                    guard asset.kind == .audio, clip.speed == 1, clip.keyframeTracks.isEmpty else {
                        throw PreparedVideoError.unsupportedCapability("audio asset, retime or animation")
                    }
                    audioClips.append(try .init(id: clip.id, assetID: id,
                        timelineRange: range(clip.timelineRange), sourceRange: range(clip.sourceRange),
                        volume: clip.isMuted ? 0 : clip.volume,
                        fadeInSeconds: clip.fadeIn?.seconds ?? 0, fadeOutSeconds: clip.fadeOut?.seconds ?? 0))
                case .caption: break
                case .adjustment:
                    throw PreparedVideoError.unsupportedCapability("adjustment track")
                }
            }
            switch track.kind {
            case .visual: visuals.append(.init(id: track.id, name: track.name, clips: visualClips))
            case .audio: audio.append(.init(id: track.id, name: track.name, isMuted: track.isMuted,
                                            volume: track.volume, clips: audioClips))
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
            audio: .init(tracks: audio))
    }
}
