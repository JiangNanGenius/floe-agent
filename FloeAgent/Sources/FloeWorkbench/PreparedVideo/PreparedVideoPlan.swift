// FloeWorkbench — PreparedVideo: immutable resolved render plan.
//
// Adapter boundary:
//   The shared v2 project/document engine owns editing, revisions and the
//   journal. This file owns ONLY the immutable, already-resolved render
//   projection. A v2 adapter (`PreparedVideoPlanResolving`) converts rational
//   track ranges, keyframes, resolved asset URLs and typed content into these
//   values once, after the shared model freezes a revision. Nothing below
//   reads the document store, selects a project/workspace, or mutates source
//   assets. Model-authored edits and local tools converge on the shared owner
//   before the adapter produces this plan.
//
// Track array order is bottom-to-top compositing order. Clip ranges are
// already resolved timeline positions (including any leading transition
// overlap); source ranges are already trimmed. Speed is a per-clip retime;
// the evaluator maps timeline time to source time through it.

import Foundation
import CoreGraphics
import CryptoKit

// MARK: - Plan identity

public struct PreparedVideoPlanID: Sendable, Hashable, Codable {
    public let projectID: UUID
    public let revision: Int64

    public init(projectID: UUID, revision: Int64) {
        self.projectID = projectID
        self.revision = revision
    }

    public var description: String {
        "\(projectID.uuidString)@\(revision)"
    }
}

/// The only document-to-render boundary in this component. The coordinator's
/// v2 adapter implements this by reading one frozen document revision; this
/// component never asks for "the current project".
public protocol PreparedVideoPlanResolving: Sendable {
    func resolvePreparedVideoPlan(projectID: UUID, revision: Int64) async throws -> PreparedVideoPlan
}

// MARK: - Colors

public struct PreparedVideoColor: Sendable, Hashable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) throws {
        let components = [red, green, blue, alpha]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PreparedVideoError.invalidPlan("color components must be finite in 0...1")
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: String) throws {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8 else {
            throw PreparedVideoError.invalidPlan("color must be #RRGGBB or #RRGGBBAA")
        }
        guard let raw = UInt64(value, radix: 16) else {
            throw PreparedVideoError.invalidPlan("color contains non-hexadecimal digits")
        }
        let hasAlpha = value.count == 8
        let red = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(raw & 0xFF) / 255 : 1
        try self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let black = try! PreparedVideoColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = try! PreparedVideoColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let clear = try! PreparedVideoColor(red: 0, green: 0, blue: 0, alpha: 0)

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]) ?? CGColor(gray: 0, alpha: CGFloat(alpha))
    }
}

// MARK: - Assets

public enum PreparedVideoAssetKind: String, Sendable, Hashable, Codable {
    case video
    case image
    case audio
}

/// A resolved external asset. `url` was validated against the project root by
/// the adapter before the plan was frozen. `contentHash` is optional; when it
/// is present it participates in the plan content signature and cache
/// identity. A nil hash means the caller must advance the plan revision when
/// the file bytes change.
public struct PreparedVideoAsset: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let url: URL
    public let kind: PreparedVideoAssetKind
    public let duration: PreparedVideoTime?
    public let frameRate: PreparedVideoFrameRate?
    public let contentHash: String?

    public init(id: UUID, url: URL, kind: PreparedVideoAssetKind,
                duration: PreparedVideoTime? = nil,
                frameRate: PreparedVideoFrameRate? = nil,
                contentHash: String? = nil) {
        self.id = id
        self.url = url
        self.kind = kind
        self.duration = duration
        self.frameRate = frameRate
        self.contentHash = contentHash
    }
}

// MARK: - Visual content

public enum PreparedVideoTextAlignment: String, Sendable, Hashable, Codable {
    case leading
    case center
    case trailing
}

public struct PreparedVideoText: Sendable, Hashable, Codable {
    public let text: String
    public let fontSize: Double
    public let color: PreparedVideoColor
    public let fontName: String?
    public let alignment: PreparedVideoTextAlignment
    public let backgroundColor: PreparedVideoColor?
    public let padding: Double

    public init(text: String, fontSize: Double = 48, color: PreparedVideoColor = .white,
                fontName: String? = nil, alignment: PreparedVideoTextAlignment = .center,
                backgroundColor: PreparedVideoColor? = nil, padding: Double = 12) {
        self.text = text
        self.fontSize = fontSize
        self.color = color
        self.fontName = fontName
        self.alignment = alignment
        self.backgroundColor = backgroundColor
        self.padding = padding
    }
}

public enum PreparedVideoGraphicShape: String, Sendable, Hashable, Codable {
    case rectangle
    case ellipse
}

public struct PreparedVideoGraphic: Sendable, Hashable, Codable {
    public let shape: PreparedVideoGraphicShape
    /// Normalized size of the graphic relative to the plan canvas.
    public let width: Double
    public let height: Double
    public let fillColor: PreparedVideoColor
    public let strokeColor: PreparedVideoColor?
    public let strokeWidth: Double
    public let cornerRadius: Double

    public init(shape: PreparedVideoGraphicShape, width: Double, height: Double,
                fillColor: PreparedVideoColor, strokeColor: PreparedVideoColor? = nil,
                strokeWidth: Double = 0, cornerRadius: Double = 0) {
        self.shape = shape
        self.width = width
        self.height = height
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
    }
}

public enum PreparedVideoVisualContent: Sendable, Hashable, Codable {
    case video(assetID: UUID)
    case image(assetID: UUID)
    case text(PreparedVideoText)
    case graphic(PreparedVideoGraphic)

    public var assetID: UUID? {
        switch self {
        case .video(let id), .image(let id): id
        case .text, .graphic: nil
        }
    }
}

// MARK: - Transform and keyframes

public enum PreparedVideoFit: String, Sendable, Hashable, Codable {
    case aspectFit
    case aspectFill
    case stretch
}

public struct PreparedVideoTransform: Sendable, Hashable, Codable {
    /// Normalized canvas position of the layer center, measured from the
    /// top-leading corner (0...1). This matches the v1 layer contract.
    public let centerX: Double
    public let centerY: Double
    public let scale: Double
    /// Clockwise rotation in degrees in top-leading screen space.
    public let rotationDegrees: Double
    public let fit: PreparedVideoFit

    public init(centerX: Double = 0.5, centerY: Double = 0.5, scale: Double = 1,
                rotationDegrees: Double = 0, fit: PreparedVideoFit = .aspectFit) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.fit = fit
    }
}

public enum PreparedVideoAnimatableProperty: String, Sendable, Hashable, Codable, CaseIterable {
    case opacity
    case centerX
    case centerY
    case scale
    case rotationDegrees
}

public enum PreparedVideoInterpolation: String, Sendable, Hashable, Codable {
    case hold
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case cubicBezier
}

/// One keyframe. `time` is relative to the clip start and shares the plan
/// timescale. Cubic-bezier control points are stored explicitly; x controls
/// must stay in 0...1 so the curve is a function of time.
public struct PreparedVideoKeyframe: Sendable, Hashable, Codable {
    public let time: PreparedVideoTime
    public let value: Double
    public let interpolation: PreparedVideoInterpolation
    public let control1X: Double
    public let control1Y: Double
    public let control2X: Double
    public let control2Y: Double

    public init(time: PreparedVideoTime, value: Double,
                interpolation: PreparedVideoInterpolation = .linear,
                control1X: Double = 0.25, control1Y: Double = 0.1,
                control2X: Double = 0.25, control2Y: Double = 1) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
        self.control1X = control1X
        self.control1Y = control1Y
        self.control2X = control2X
        self.control2Y = control2Y
    }
}

public struct PreparedVideoKeyframeTrack: Sendable, Hashable, Codable {
    public let property: PreparedVideoAnimatableProperty
    public let keyframes: [PreparedVideoKeyframe]

    public init(property: PreparedVideoAnimatableProperty, keyframes: [PreparedVideoKeyframe]) {
        self.property = property
        self.keyframes = keyframes
    }
}

// MARK: - Mask

public enum PreparedVideoMaskShape: String, Sendable, Hashable, Codable {
    case ellipse
    case rectangle
}

/// A layer-local normalized mask. It moves and rotates with the layer, so the
/// same transform and feather code applies to preview and export.
public struct PreparedVideoMask: Sendable, Hashable, Codable {
    public let shape: PreparedVideoMaskShape
    public let centerX: Double
    public let centerY: Double
    public let width: Double
    public let height: Double
    /// Fraction of the mask's shortest side used as Gaussian feather radius.
    /// 0 is a hard edge; 1 is a fully soft edge.
    public let feather: Double
    public let isInverted: Bool

    public init(shape: PreparedVideoMaskShape = .ellipse,
                centerX: Double = 0.5, centerY: Double = 0.5,
                width: Double = 1, height: Double = 1,
                feather: Double = 0, isInverted: Bool = false) {
        self.shape = shape
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.feather = feather
        self.isInverted = isInverted
    }
}

// MARK: - Transitions

public enum PreparedVideoTransitionKind: String, Sendable, Hashable, Codable {
    case crossDissolve
    case dipToBlack
}

public struct PreparedVideoTransition: Sendable, Hashable, Codable {
    public let kind: PreparedVideoTransitionKind
    public let duration: PreparedVideoTime

    public init(kind: PreparedVideoTransitionKind, duration: PreparedVideoTime) {
        self.kind = kind
        self.duration = duration
    }
}

// MARK: - Visual clips and tracks

public struct PreparedVideoClip: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let content: PreparedVideoVisualContent
    public let timelineRange: PreparedVideoTimeRange
    /// Required for video/image content and forbidden for text/graphic.
    public let sourceRange: PreparedVideoTimeRange?
    /// Source duration / timeline duration. 1 is real time.
    public let speed: Double
    public let isVisible: Bool
    public let opacity: Double
    public let transform: PreparedVideoTransform
    public let keyframes: [PreparedVideoKeyframeTrack]
    public let mask: PreparedVideoMask?
    /// Transition rendered where this clip overlaps the previous clip on the
    /// same track. The plan stores resolved overlapping ranges; a nil
    /// transition forbids overlap.
    public let leadingTransition: PreparedVideoTransition?

    public init(id: UUID, content: PreparedVideoVisualContent,
                timelineRange: PreparedVideoTimeRange,
                sourceRange: PreparedVideoTimeRange? = nil,
                speed: Double = 1, isVisible: Bool = true, opacity: Double = 1,
                transform: PreparedVideoTransform = .init(),
                keyframes: [PreparedVideoKeyframeTrack] = [],
                mask: PreparedVideoMask? = nil,
                leadingTransition: PreparedVideoTransition? = nil) {
        self.id = id
        self.content = content
        self.timelineRange = timelineRange
        self.sourceRange = sourceRange
        self.speed = speed
        self.isVisible = isVisible
        self.opacity = opacity
        self.transform = transform
        self.keyframes = keyframes
        self.mask = mask
        self.leadingTransition = leadingTransition
    }

    /// Source time for a timeline time inside this clip.
    public func sourceTime(at timelineTime: PreparedVideoTime) throws -> PreparedVideoTime? {
        guard let sourceRange else { return nil }
        guard timelineTime.timescale == timelineRange.timescale else {
            throw PreparedVideoError.invalidTime("clip and query timescales differ")
        }
        let local = try timelineTime.subtracting(timelineRange.start)
        let sourceOffset = local.seconds * speed
        let absolute = sourceRange.start.seconds + sourceOffset
        let converted = try PreparedVideoTime(seconds: absolute, timescale: sourceRange.timescale)
        guard converted >= sourceRange.start else {
            throw PreparedVideoError.invalidPlan("clip retime produced a source time before the trim")
        }
        guard let end = try? sourceRange.endTime(), converted <= end else {
            throw PreparedVideoError.invalidPlan("clip retime produced a source time after the trim")
        }
        return converted
    }
}

public struct PreparedVideoTrack: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let opacity: Double
    public let isHidden: Bool
    public let clips: [PreparedVideoClip]

    public init(id: UUID, name: String, opacity: Double = 1,
                isHidden: Bool = false, clips: [PreparedVideoClip] = []) {
        self.id = id
        self.name = name
        self.opacity = opacity
        self.isHidden = isHidden
        self.clips = clips
    }
}

// MARK: - Captions

public struct PreparedVideoCaption: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let timelineRange: PreparedVideoTimeRange
    public let text: String

    public init(id: UUID, timelineRange: PreparedVideoTimeRange, text: String) {
        self.id = id
        self.timelineRange = timelineRange
        self.text = text
    }
}

public struct PreparedVideoCaptionStyle: Sendable, Hashable, Codable {
    public let fontSize: Double
    public let color: PreparedVideoColor
    public let backgroundColor: PreparedVideoColor?
    /// Normalized vertical center in 0...1.
    public let positionY: Double
    public let alignment: PreparedVideoTextAlignment
    public let respectsSafeArea: Bool
    public let fontName: String?

    public init(fontSize: Double = 36, color: PreparedVideoColor = .white,
                backgroundColor: PreparedVideoColor? = .black,
                positionY: Double = 0.88,
                alignment: PreparedVideoTextAlignment = .center,
                respectsSafeArea: Bool = true,
                fontName: String? = nil) {
        self.fontSize = fontSize
        self.color = color
        self.backgroundColor = backgroundColor
        self.positionY = positionY
        self.alignment = alignment
        self.respectsSafeArea = respectsSafeArea
        self.fontName = fontName
    }
}

// MARK: - Audio

public enum PreparedVideoEQFilter: String, Sendable, Hashable, Codable {
    case lowShelf
    case parametric
    case highShelf
}

public struct PreparedVideoEQBand: Sendable, Hashable, Codable {
    public let frequency: Double
    public let gain: Double
    public let bandwidth: Double
    public let filter: PreparedVideoEQFilter
    public let isEnabled: Bool

    public init(frequency: Double, gain: Double, bandwidth: Double = 1,
                filter: PreparedVideoEQFilter = .parametric, isEnabled: Bool = true) {
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.filter = filter
        self.isEnabled = isEnabled
    }
}

public struct PreparedVideoDynamics: Sendable, Hashable, Codable {
    public let threshold: Double
    public let headRoom: Double
    public let expansionRatio: Double
    public let attackTime: Double
    public let releaseTime: Double
    public let masterGain: Double

    public init(threshold: Double = -20, headRoom: Double = 5,
                expansionRatio: Double = 2, attackTime: Double = 0.005,
                releaseTime: Double = 0.05, masterGain: Double = 0) {
        self.threshold = threshold
        self.headRoom = headRoom
        self.expansionRatio = expansionRatio
        self.attackTime = attackTime
        self.releaseTime = releaseTime
        self.masterGain = masterGain
    }
}

public struct PreparedVideoAudioClip: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let assetID: UUID
    public let timelineRange: PreparedVideoTimeRange
    public let sourceRange: PreparedVideoTimeRange
    public let volume: Double
    public let fadeInSeconds: Double
    public let fadeOutSeconds: Double

    public init(id: UUID, assetID: UUID,
                timelineRange: PreparedVideoTimeRange,
                sourceRange: PreparedVideoTimeRange,
                volume: Double = 1,
                fadeInSeconds: Double = 0,
                fadeOutSeconds: Double = 0) {
        self.id = id
        self.assetID = assetID
        self.timelineRange = timelineRange
        self.sourceRange = sourceRange
        self.volume = volume
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }
}

public struct PreparedVideoAudioTrack: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let isMuted: Bool
    public let volume: Double
    public let eqBands: [PreparedVideoEQBand]
    public let dynamics: PreparedVideoDynamics?
    public let clips: [PreparedVideoAudioClip]

    public init(id: UUID, name: String, isMuted: Bool = false,
                volume: Double = 1, eqBands: [PreparedVideoEQBand] = [],
                dynamics: PreparedVideoDynamics? = nil,
                clips: [PreparedVideoAudioClip] = []) {
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.volume = volume
        self.eqBands = eqBands
        self.dynamics = dynamics
        self.clips = clips
    }
}

public struct PreparedVideoAudioPlan: Sendable, Hashable, Codable {
    public let tracks: [PreparedVideoAudioTrack]
    public let masterVolume: Double
    /// Extra audio rendered after the requested window to account for effect
    /// tails. It is reported and discarded from the delivered file rather than
    /// silently ignored; `PreparedVideoAudioMixer` documents the contract.
    public let tailSeconds: Double

    public init(tracks: [PreparedVideoAudioTrack] = [], masterVolume: Double = 1,
                tailSeconds: Double = 0.25) {
        self.tracks = tracks
        self.masterVolume = masterVolume
        self.tailSeconds = tailSeconds
    }
}

// MARK: - Plan

public struct PreparedVideoCanvas: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int
    public let backgroundColor: PreparedVideoColor

    public init(width: Int, height: Int, backgroundColor: PreparedVideoColor = .black) {
        self.width = width
        self.height = height
        self.backgroundColor = backgroundColor
    }
}

public struct PreparedVideoPlan: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: PreparedVideoPlanID
    public let timeScale: Int32
    public let frameRate: PreparedVideoFrameRate
    public let duration: PreparedVideoTime
    public let canvas: PreparedVideoCanvas
    public let assets: [PreparedVideoAsset]
    /// Bottom-to-top compositing order.
    public let visualTracks: [PreparedVideoTrack]
    public let captions: [PreparedVideoCaption]
    public let captionStyle: PreparedVideoCaptionStyle
    public let audio: PreparedVideoAudioPlan

    public init(id: PreparedVideoPlanID, timeScale: Int32,
                frameRate: PreparedVideoFrameRate,
                duration: PreparedVideoTime,
                canvas: PreparedVideoCanvas,
                assets: [PreparedVideoAsset],
                visualTracks: [PreparedVideoTrack],
                captions: [PreparedVideoCaption] = [],
                captionStyle: PreparedVideoCaptionStyle = .init(),
                audio: PreparedVideoAudioPlan = .init()) throws {
        let plan = PreparedVideoPlan(
            uncheckedSchemaVersion: Self.schemaVersion,
            id: id, timeScale: timeScale, frameRate: frameRate,
            duration: duration, canvas: canvas, assets: assets,
            visualTracks: visualTracks, captions: captions,
            captionStyle: captionStyle, audio: audio)
        try plan.validateStructure()
        self = plan
    }

    private init(uncheckedSchemaVersion schemaVersion: Int, id: PreparedVideoPlanID,
                 timeScale: Int32, frameRate: PreparedVideoFrameRate,
                 duration: PreparedVideoTime, canvas: PreparedVideoCanvas,
                 assets: [PreparedVideoAsset], visualTracks: [PreparedVideoTrack],
                 captions: [PreparedVideoCaption], captionStyle: PreparedVideoCaptionStyle,
                 audio: PreparedVideoAudioPlan) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.timeScale = timeScale
        self.frameRate = frameRate
        self.duration = duration
        self.canvas = canvas
        self.assets = assets
        self.visualTracks = visualTracks
        self.captions = captions
        self.captionStyle = captionStyle
        self.audio = audio
    }

    public func asset(_ id: UUID) -> PreparedVideoAsset? {
        assets.first { $0.id == id }
    }

    /// Stable plan signature used for cache identity and same-revision checks.
    /// JSONEncoder's sorted keys make the field order deterministic; all plan
    /// values are value types with explicit Codable implementations.
    public var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "unencodable" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Validation

    /// Structural validation performed when the adapter freezes a plan.
    /// File existence is checked by the renderer so a plan can describe a
    /// temporarily offline asset without losing the user's edit.
    public func validateStructure() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw PreparedVideoError.invalidPlan("unsupported schema version \(schemaVersion)")
        }
        guard timeScale > 0 else {
            throw PreparedVideoError.invalidPlan("plan timescale must be positive")
        }
        guard frameRate.numerator > 0, frameRate.denominator > 0 else {
            throw PreparedVideoError.invalidPlan("plan frame rate must be positive")
        }
        guard duration.timescale == timeScale else {
            throw PreparedVideoError.invalidPlan("plan duration must use the plan timescale")
        }
        guard duration.seconds > 0 else {
            throw PreparedVideoError.invalidPlan("plan duration must be positive")
        }
        guard canvas.width > 0, canvas.height > 0,
              canvas.width <= 8_192, canvas.height <= 8_192,
              canvas.width * canvas.height <= 33_177_600 else {
            throw PreparedVideoError.invalidPlan("canvas dimensions are outside the supported bound")
        }

        var assetIDs = Set<UUID>()
        for asset in assets {
            guard assetIDs.insert(asset.id).inserted else {
                throw PreparedVideoError.invalidPlan("asset identifiers must be unique")
            }
            guard asset.url.isFileURL, !asset.url.path.isEmpty else {
                throw PreparedVideoError.invalidPlan("asset URLs must be non-empty file URLs")
            }
            if let assetDuration = asset.duration {
                guard assetDuration.timescale == timeScale, assetDuration.seconds > 0 else {
                    throw PreparedVideoError.invalidPlan("asset duration must be positive and use the plan timescale")
                }
            }
        }

        guard !visualTracks.isEmpty else {
            throw PreparedVideoError.emptyTimeline
        }
        var trackIDs = Set<UUID>()
        var clipIDs = Set<UUID>()
        var clipCount = 0
        for track in visualTracks {
            guard trackIDs.insert(track.id).inserted else {
                throw PreparedVideoError.invalidPlan("visual track identifiers must be unique")
            }
            guard (0...1).contains(track.opacity) else {
                throw PreparedVideoError.invalidPlan("track opacity must be in 0...1")
            }
            guard track.clips.count <= 1_024 else {
                throw PreparedVideoError.invalidPlan("a visual track exceeds the clip bound")
            }
            let ordered = track.clips.sorted { $0.timelineRange.start < $1.timelineRange.start }
            for (index, clip) in ordered.enumerated() {
                clipCount += 1
                guard clipCount <= 4_096 else {
                    throw PreparedVideoError.invalidPlan("the plan exceeds the clip bound")
                }
                guard clipIDs.insert(clip.id).inserted else {
                    throw PreparedVideoError.invalidPlan("clip identifiers must be unique")
                }
                try validate(clip: clip, track: track, index: index, ordered: ordered)
            }
        }

        var captionIDs = Set<UUID>()
        for caption in captions {
            guard captionIDs.insert(caption.id).inserted else {
                throw PreparedVideoError.invalidPlan("caption identifiers must be unique")
            }
            guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PreparedVideoError.invalidPlan("caption text must not be empty")
            }
            guard caption.text.utf8.count <= 20_000 else {
                throw PreparedVideoError.invalidPlan("caption text exceeds the bound")
            }
            guard caption.timelineRange.timescale == timeScale,
                  caption.timelineRange.duration.seconds > 0,
                  caption.timelineRange.start.seconds >= 0,
                  caption.timelineRange.endSeconds <= duration.seconds + 0.000_001 else {
                throw PreparedVideoError.invalidPlan("caption range must lie inside the plan duration")
            }
        }

        guard captionStyle.fontSize > 0, captionStyle.fontSize <= 512,
              (0...1).contains(captionStyle.positionY) else {
            throw PreparedVideoError.invalidPlan("caption style is outside the supported bound")
        }

        var audioTrackIDs = Set<UUID>()
        var audioClipIDs = Set<UUID>()
        for track in audio.tracks {
            guard audioTrackIDs.insert(track.id).inserted else {
                throw PreparedVideoError.invalidPlan("audio track identifiers must be unique")
            }
            guard (0...4).contains(track.volume) else {
                throw PreparedVideoError.invalidPlan("audio track volume must be in 0...4")
            }
            guard track.clips.count <= 1_024 else {
                throw PreparedVideoError.invalidPlan("an audio track exceeds the clip bound")
            }
            for band in track.eqBands {
                guard band.frequency.isFinite, (20...20_000).contains(band.frequency),
                      band.gain.isFinite, (-24...24).contains(band.gain),
                      band.bandwidth.isFinite, (0.05...5).contains(band.bandwidth) else {
                    throw PreparedVideoError.invalidPlan("EQ band is outside the supported range")
                }
            }
            if let dynamics = track.dynamics {
                guard dynamics.threshold.isFinite, (-40...0).contains(dynamics.threshold),
                      dynamics.headRoom.isFinite, (0.1...40).contains(dynamics.headRoom),
                      dynamics.expansionRatio.isFinite, (1...20).contains(dynamics.expansionRatio),
                      dynamics.attackTime.isFinite, (0.000_1...0.2).contains(dynamics.attackTime),
                      dynamics.releaseTime.isFinite, (0.01...3).contains(dynamics.releaseTime),
                      dynamics.masterGain.isFinite, (-24...24).contains(dynamics.masterGain) else {
                    throw PreparedVideoError.invalidPlan("audio dynamics are outside the supported range")
                }
            }
            for clip in track.clips {
                guard audioClipIDs.insert(clip.id).inserted else {
                    throw PreparedVideoError.invalidPlan("audio clip identifiers must be unique")
                }
                guard clip.timelineRange.timescale == timeScale,
                      clip.sourceRange.timescale == timeScale else {
                    throw PreparedVideoError.invalidPlan("audio clip times must use the plan timescale")
                }
                guard clip.timelineRange.start.seconds >= 0,
                      clip.timelineRange.duration.seconds > 0,
                      clip.timelineRange.endSeconds <= duration.seconds + 0.000_001 else {
                    throw PreparedVideoError.invalidPlan("audio clip range must lie inside the plan duration")
                }
                guard clip.sourceRange.duration.seconds > 0 else {
                    throw PreparedVideoError.invalidPlan("audio source range must be positive")
                }
                guard let asset = asset(clip.assetID), asset.kind == .audio else {
                    throw PreparedVideoError.invalidPlan("audio clip references a missing or non-audio asset")
                }
                if let assetDuration = asset.duration {
                    guard clip.sourceRange.endSeconds <= assetDuration.seconds + 0.000_001 else {
                        throw PreparedVideoError.invalidPlan("audio source range exceeds the asset duration")
                    }
                }
                guard (0...4).contains(clip.volume),
                      clip.fadeInSeconds.isFinite, clip.fadeInSeconds >= 0,
                      clip.fadeOutSeconds.isFinite, clip.fadeOutSeconds >= 0,
                      clip.fadeInSeconds <= clip.timelineRange.duration.seconds + 0.000_001,
                      clip.fadeOutSeconds <= clip.timelineRange.duration.seconds + 0.000_001 else {
                    throw PreparedVideoError.invalidPlan("audio clip gain or fades are outside the supported range")
                }
            }
        }
        guard (0...4).contains(audio.masterVolume),
              audio.tailSeconds.isFinite, (0...5).contains(audio.tailSeconds) else {
            throw PreparedVideoError.invalidPlan("audio master volume or tail is outside the supported range")
        }
    }

    /// Validation required immediately before producing a frame or file.
    public func validateForRender() throws {
        try validateStructure()
        let hasVisibleClip = visualTracks.contains { track in
            !track.isHidden && track.clips.contains { $0.isVisible && $0.opacity > 0 }
        }
        guard hasVisibleClip else {
            throw PreparedVideoError.emptyTimeline
        }
    }

    private func validate(clip: PreparedVideoClip, track: PreparedVideoTrack,
                          index: Int, ordered: [PreparedVideoClip]) throws {
        guard clip.timelineRange.timescale == timeScale else {
            throw PreparedVideoError.invalidPlan("clip timeline range must use the plan timescale")
        }
        guard clip.timelineRange.start.seconds >= 0,
              clip.timelineRange.duration.seconds > 0,
              clip.timelineRange.endSeconds <= duration.seconds + 0.000_001 else {
            throw PreparedVideoError.invalidPlan("clip timeline range must lie inside the plan duration")
        }
        guard clip.speed.isFinite, (0.01...16).contains(clip.speed) else {
            throw PreparedVideoError.invalidPlan("clip speed must be finite in 0.01...16")
        }
        guard (0...1).contains(clip.opacity) else {
            throw PreparedVideoError.invalidPlan("clip opacity must be in 0...1")
        }
        guard clip.transform.centerX.isFinite, clip.transform.centerY.isFinite,
              (-2...3).contains(clip.transform.centerX),
              (-2...3).contains(clip.transform.centerY),
              clip.transform.scale.isFinite, (0.000_1...64).contains(clip.transform.scale),
              clip.transform.rotationDegrees.isFinite,
              (-3_600...3_600).contains(clip.transform.rotationDegrees) else {
            throw PreparedVideoError.invalidPlan("clip transform is outside the supported range")
        }

        switch clip.content {
        case .video(let assetID), .image(let assetID):
            guard let asset = asset(assetID) else {
                throw PreparedVideoError.invalidPlan("visual clip references a missing asset")
            }
            let expectedKind: PreparedVideoAssetKind = {
                if case .video = clip.content { return .video }
                return .image
            }()
            guard asset.kind == expectedKind else {
                throw PreparedVideoError.invalidPlan("visual clip asset kind does not match its content")
            }
            guard let sourceRange = clip.sourceRange else {
                throw PreparedVideoError.invalidPlan("media clip requires a source range")
            }
            guard sourceRange.timescale == timeScale, sourceRange.duration.seconds > 0 else {
                throw PreparedVideoError.invalidPlan("clip source range must be positive and use the plan timescale")
            }
            if let assetDuration = asset.duration {
                guard sourceRange.endSeconds <= assetDuration.seconds + 0.000_001 else {
                    throw PreparedVideoError.invalidPlan("clip source range exceeds the asset duration")
                }
            }
            if let sourceFrameRate = asset.frameRate, sourceFrameRate.fps <= 0 {
                throw PreparedVideoError.invalidPlan("asset frame rate must be positive")
            }
        case .text(let text):
            guard clip.sourceRange == nil else {
                throw PreparedVideoError.invalidPlan("text clips must not carry a source range")
            }
            guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.text.utf8.count <= 20_000 else {
                throw PreparedVideoError.invalidPlan("text clip content must be non-empty and bounded")
            }
            guard text.fontSize > 0, text.fontSize <= 512, text.padding >= 0, text.padding <= 512 else {
                throw PreparedVideoError.invalidPlan("text clip font size or padding is outside the supported range")
            }
        case .graphic(let graphic):
            guard clip.sourceRange == nil else {
                throw PreparedVideoError.invalidPlan("graphic clips must not carry a source range")
            }
            guard graphic.width > 0, graphic.width <= 2,
                  graphic.height > 0, graphic.height <= 2,
                  graphic.strokeWidth >= 0, graphic.strokeWidth <= 128,
                  graphic.cornerRadius >= 0, graphic.cornerRadius <= 1 else {
                throw PreparedVideoError.invalidPlan("graphic bounds, stroke or radius are outside the supported range")
            }
        }

        if let mask = clip.mask {
            guard (0...1).contains(mask.centerX), (0...1).contains(mask.centerY),
                  mask.width > 0, mask.width <= 2, mask.height > 0, mask.height <= 2,
                  (0...1).contains(mask.feather) else {
                throw PreparedVideoError.invalidPlan("mask geometry is outside the supported range")
            }
        }

        var properties = Set<PreparedVideoAnimatableProperty>()
        for keyframeTrack in clip.keyframes {
            guard properties.insert(keyframeTrack.property).inserted else {
                throw PreparedVideoError.invalidPlan("a clip has duplicate keyframe tracks")
            }
            guard keyframeTrack.keyframes.count <= 4_096 else {
                throw PreparedVideoError.invalidPlan("a keyframe track exceeds the bound")
            }
            var previousTime: PreparedVideoTime?
            for keyframe in keyframeTrack.keyframes {
                guard keyframe.time.timescale == timeScale,
                      keyframe.time.seconds >= 0,
                      keyframe.time.seconds <= clip.timelineRange.duration.seconds + 0.000_001 else {
                    throw PreparedVideoError.invalidPlan("keyframe time lies outside the clip")
                }
                if let previousTime, keyframe.time < previousTime {
                    throw PreparedVideoError.invalidPlan("keyframes must be strictly ordered")
                }
                if let previousTime, keyframe.time == previousTime {
                    throw PreparedVideoError.invalidPlan("keyframes must not share a time")
                }
                previousTime = keyframe.time
                guard keyframe.value.isFinite,
                      keyframe.control1X.isFinite, keyframe.control1Y.isFinite,
                      keyframe.control2X.isFinite, keyframe.control2Y.isFinite,
                      (0...1).contains(keyframe.control1X),
                      (0...1).contains(keyframe.control2X) else {
                    throw PreparedVideoError.invalidPlan("keyframe value or control point is invalid")
                }
                if keyframeTrack.property == .opacity {
                    guard (0...1).contains(keyframe.value) else {
                        throw PreparedVideoError.invalidPlan("opacity keyframes must stay in 0...1")
                    }
                }
                if keyframeTrack.property == .scale {
                    guard (0.000_1...64).contains(keyframe.value) else {
                        throw PreparedVideoError.invalidPlan("scale keyframes are outside the supported range")
                    }
                }
            }
        }

        if index >= 2 {
            let twoBack = ordered[index - 2]
            if let twoBackEnd = try? twoBack.timelineRange.endTime(),
               clip.timelineRange.start < twoBackEnd {
                throw PreparedVideoError.invalidPlan("more than two clips overlap on one visual track")
            }
        }
        if index > 0 {
            let previous = ordered[index - 1]
            guard let previousEnd = try? previous.timelineRange.endTime() else {
                throw PreparedVideoError.invalidPlan("previous clip range is invalid")
            }
            if clip.timelineRange.start < previousEnd {
                guard let transition = clip.leadingTransition else {
                    throw PreparedVideoError.invalidPlan("overlapping clips require an explicit transition")
                }
                guard transition.duration.timescale == timeScale,
                      transition.duration.seconds > 0 else {
                    throw PreparedVideoError.invalidPlan("transition duration must be positive and use the plan timescale")
                }
                let overlap = previousEnd.seconds - clip.timelineRange.start.seconds
                guard overlap <= transition.duration.seconds + 0.000_001 else {
                    throw PreparedVideoError.invalidPlan("transition overlap exceeds its declared duration")
                }
                let previousDuration = previous.timelineRange.duration.seconds
                let clipDuration = clip.timelineRange.duration.seconds
                guard transition.duration.seconds <= min(previousDuration, clipDuration) + 0.000_001 else {
                    throw PreparedVideoError.invalidPlan("transition is longer than its neighboring clips")
                }
            } else if clip.leadingTransition != nil {
                throw PreparedVideoError.invalidPlan("a transition requires overlapping resolved clip ranges")
            }
        } else if clip.leadingTransition != nil {
            throw PreparedVideoError.invalidPlan("the first clip on a track cannot lead with a transition")
        }
        _ = track
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, timeScale, frameRate, duration, canvas, assets
        case visualTracks, captions, captionStyle, audio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let id = try container.decode(PreparedVideoPlanID.self, forKey: .id)
        let timeScale = try container.decode(Int32.self, forKey: .timeScale)
        let frameRate = try container.decode(PreparedVideoFrameRate.self, forKey: .frameRate)
        let duration = try container.decode(PreparedVideoTime.self, forKey: .duration)
        let canvas = try container.decode(PreparedVideoCanvas.self, forKey: .canvas)
        let assets = try container.decode([PreparedVideoAsset].self, forKey: .assets)
        let visualTracks = try container.decode([PreparedVideoTrack].self, forKey: .visualTracks)
        let captions = try container.decode([PreparedVideoCaption].self, forKey: .captions)
        let captionStyle = try container.decode(PreparedVideoCaptionStyle.self, forKey: .captionStyle)
        let audio = try container.decode(PreparedVideoAudioPlan.self, forKey: .audio)
        let decoded = PreparedVideoPlan(uncheckedSchemaVersion: schemaVersion, id: id,
                                        timeScale: timeScale, frameRate: frameRate,
                                        duration: duration, canvas: canvas, assets: assets,
                                        visualTracks: visualTracks, captions: captions,
                                        captionStyle: captionStyle, audio: audio)
        try decoded.validateStructure()
        self = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(timeScale, forKey: .timeScale)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(duration, forKey: .duration)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(assets, forKey: .assets)
        try container.encode(visualTracks, forKey: .visualTracks)
        try container.encode(captions, forKey: .captions)
        try container.encode(captionStyle, forKey: .captionStyle)
        try container.encode(audio, forKey: .audio)
    }
}

// MARK: - Output settings

public enum PreparedVideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264
    case hevc
}

public struct PreparedVideoOutputSettings: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int
    public let frameRate: PreparedVideoFrameRate
    public let codec: PreparedVideoCodec
    public let quality: Double

    public init(width: Int, height: Int, frameRate: PreparedVideoFrameRate,
                codec: PreparedVideoCodec = .h264, quality: Double = 0.9) throws {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 33_177_600 else {
            throw PreparedVideoError.invalidOutputSettings("dimensions are outside the supported bound")
        }
        guard width % 2 == 0, height % 2 == 0 else {
            throw PreparedVideoError.invalidOutputSettings("encoded output dimensions must be even")
        }
        guard frameRate.numerator > 0, frameRate.denominator > 0 else {
            throw PreparedVideoError.invalidOutputSettings("frame rate must be positive")
        }
        guard quality.isFinite, (0.01...1).contains(quality) else {
            throw PreparedVideoError.invalidOutputSettings("quality must be in 0.01...1")
        }
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.quality = quality
    }

    public var identity: String {
        "\(width)x\(height)@\(frameRate.numerator)/\(frameRate.denominator):\(codec.rawValue):\(String(format: "%.4f", quality))"
    }

    public var pixelCount: Int { width * height }
}
