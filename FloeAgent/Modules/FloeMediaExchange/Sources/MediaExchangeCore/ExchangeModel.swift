// SPDX-License-Identifier: MPL-2.0
//
// Format-neutral exchange model shared by the FCPXML and OpenTimelineIO
// qualification adapters. This file owns no UI, no player, no renderer and no
// shared MediaProject v2 state. The coordinator connects these values to the
// v2 transaction/ownership service after the core handoff.

import Foundation

// MARK: - Media

public enum ExchangeMediaKind: String, Codable, Hashable, Sendable {
    case video
    case audio
    case image
    case subtitle
}

public enum ExchangeMediaStorage: String, Codable, Hashable, Sendable {
    /// Media bytes are copied under the project package's `media/` directory.
    case packed
    /// Media remains at an external, security-scoped location.
    case external
}

public enum ExchangePathError: Error, Equatable, CustomStringConvertible {
    case emptyPath
    case absolutePath(String)
    case pathTraversal(String)
    case backslash(String)
    case colon(String)
    case controlCharacter(String)
    case componentTooLong(String)
    case pathTooLong(String)
    case symlinkEscape(String)
    case outsidePackageRoot(String)
    case notAFileURL(String)
    case relativeExternalURL(String)
    case videoMediaWithoutVideo(String)
    case audioMediaWithoutAudio(String)
    case missingMediaID(String)
    case duplicateIdentifier(String)
    case invalidItemBounds(String)
    case overlappingItems(track: String)
    case invalidMarker(String)
    case invalidCaption(String)
    case invalidDuration(String)
    case unsupportedEffectOnExport(String)

    public var description: String {
        switch self {
        case .emptyPath: return "path is empty"
        case let .absolutePath(path): return "absolute path is not allowed: \(path)"
        case let .pathTraversal(path): return "path traversal is not allowed: \(path)"
        case let .backslash(path): return "backslash path separators are not allowed: \(path)"
        case let .colon(path): return "drive/colon paths are not allowed: \(path)"
        case let .controlCharacter(path): return "control character in path: \(path)"
        case let .componentTooLong(path): return "path component is too long: \(path)"
        case let .pathTooLong(path): return "path is too long: \(path)"
        case let .symlinkEscape(path): return "symlink escapes the package root: \(path)"
        case let .outsidePackageRoot(path): return "path is outside the package root: \(path)"
        case let .notAFileURL(value): return "external media must be an absolute file URL: \(value)"
        case let .relativeExternalURL(value): return "external media URL is not absolute: \(value)"
        case let .videoMediaWithoutVideo(id): return "media \(id) is used on a video track but hasVideo is false"
        case let .audioMediaWithoutAudio(id): return "media \(id) is used on an audio track but hasAudio is false"
        case let .missingMediaID(id): return "clip references missing media \(id)"
        case let .duplicateIdentifier(id): return "duplicate identifier \(id)"
        case let .invalidItemBounds(id): return "timeline item has invalid bounds: \(id)"
        case let .overlappingItems(track): return "timeline items overlap on track \(track)"
        case let .invalidMarker(id): return "invalid marker \(id)"
        case let .invalidCaption(id): return "invalid caption \(id)"
        case let .invalidDuration(id): return "clip has a zero or invalid duration: \(id)"
        case let .unsupportedEffectOnExport(name):
            return "effect \(name) is not representable by this adapter and cannot be silently dropped"
        }
    }
}

public enum ExchangePathSafety {
    public static let maximumPathBytes = 512
    public static let maximumComponentBytes = 255

    /// Validates a package-relative path. No absolute paths, `.`/`..`
    /// components, backslashes, drive colons, empty components or control
    /// characters are accepted.
    public static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty else { throw ExchangePathError.emptyPath }
        guard path.utf8.count <= maximumPathBytes else { throw ExchangePathError.pathTooLong(path) }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw ExchangePathError.absolutePath(path)
        }
        guard !path.contains("\\") else { throw ExchangePathError.backslash(path) }
        guard !path.contains(":") else { throw ExchangePathError.colon(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw ExchangePathError.pathTraversal(path)
            }
            guard component.utf8.count <= maximumComponentBytes else {
                throw ExchangePathError.componentTooLong(path)
            }
            guard component.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ExchangePathError.controlCharacter(path)
            }
        }
    }

    /// Resolves a packed relative path and proves that neither `..` nor an
    /// existing symlink can escape `root`. The returned URL is standardized.
    public static func resolvePacked(_ relativePath: String, in root: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = resolvedRoot.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolved = resolvedParent.appendingPathComponent(candidate.lastPathComponent)
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw ExchangePathError.outsidePackageRoot(relativePath)
        }
        return resolved
    }

    public static func validateExternalURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.isFileURL else {
            throw ExchangePathError.notAFileURL(value)
        }
        guard url.path.hasPrefix("/") else {
            throw ExchangePathError.relativeExternalURL(value)
        }
        guard url.fragment == nil, url.query == nil else {
            throw ExchangePathError.notAFileURL(value)
        }
        return url.standardizedFileURL
    }
}

public struct ExchangeMediaSource: Codable, Hashable, Sendable {
    public var storage: ExchangeMediaStorage
    public var relativePath: String?
    public var externalURL: String?
    /// Opaque security-scoped bookmark bytes. The qualification adapter never
    /// creates a bookmark implicitly and never starts access on another
    /// owner's URL without the caller's explicit resolve step.
    public var securityScopedBookmark: Data?
    /// Packed media is owned by the package; referenced media remains owned by
    /// the external location. Relinking must not silently change this flag.
    public var ownsMedia: Bool

    public init(packedRelativePath: String) throws {
        try ExchangePathSafety.validateRelativePath(packedRelativePath)
        self.storage = .packed
        self.relativePath = packedRelativePath
        self.externalURL = nil
        self.securityScopedBookmark = nil
        self.ownsMedia = true
    }

    public init(externalURL: String, securityScopedBookmark: Data? = nil) throws {
        _ = try ExchangePathSafety.validateExternalURL(externalURL)
        self.storage = .external
        self.relativePath = nil
        self.externalURL = externalURL
        self.securityScopedBookmark = securityScopedBookmark
        self.ownsMedia = false
    }

    public func validate() throws {
        switch storage {
        case .packed:
            guard ownsMedia else {
                throw ExchangePathError.outsidePackageRoot("packed media must be package-owned")
            }
            guard let relativePath, externalURL == nil, securityScopedBookmark == nil else {
                throw ExchangePathError.outsidePackageRoot("packed media contains external fields")
            }
            try ExchangePathSafety.validateRelativePath(relativePath)
        case .external:
            guard !ownsMedia else {
                throw ExchangePathError.outsidePackageRoot("external media cannot be package-owned")
            }
            guard let externalURL, relativePath == nil else {
                throw ExchangePathError.notAFileURL(externalURL ?? "")
            }
            _ = try ExchangePathSafety.validateExternalURL(externalURL)
        }
    }

    public func resolve(in packageRoot: URL) throws -> URL {
        try validate()
        switch storage {
        case .packed:
            return try ExchangePathSafety.resolvePacked(relativePath ?? "", in: packageRoot)
        case .external:
            return try ExchangePathSafety.validateExternalURL(externalURL ?? "")
        }
    }
}

public struct ExchangeMediaReference: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ExchangeMediaKind
    public var name: String
    public var source: ExchangeMediaSource
    public var duration: ExchangeTime?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Exact source frame rate when known. Mixed-rate timelines keep this
    /// per-media value rather than silently conforming it to the sequence rate.
    public var frameRate: ExchangeFrameRate?
    public var contentHash: String?
    public var byteCount: Int64?
    public var metadata: [String: String]

    public init(
        id: String,
        kind: ExchangeMediaKind,
        name: String,
        source: ExchangeMediaSource,
        duration: ExchangeTime? = nil,
        hasVideo: Bool = true,
        hasAudio: Bool = true,
        frameRate: ExchangeFrameRate? = nil,
        contentHash: String? = nil,
        byteCount: Int64? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.source = source
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.frameRate = frameRate
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.metadata = metadata
    }
}

// MARK: - Timeline

public struct ExchangeRetime: Codable, Hashable, Sendable {
    /// Playback rate relative to the source. 1/1 is normal speed, 2/1 is 2x.
    public var rate: ExchangeTime
    public var preservesPitch: Bool

    public init(rate: ExchangeTime, preservesPitch: Bool = true) {
        self.rate = rate
        self.preservesPitch = preservesPitch
    }
}

public enum ExchangeEffectSupport: String, Codable, Hashable, Sendable {
    case supported
    case reported
}

public struct ExchangeEffect: Codable, Hashable, Sendable {
    public var name: String
    public var kind: String
    public var parameters: [String: String]
    public var support: ExchangeEffectSupport
    /// Original XML/JSON fragment when the effect is not represented by the
    /// documented subset. It is retained so an export can refuse explicitly
    /// or a caller can perform a lossless round-trip outside this adapter.
    public var rawRepresentation: String?

    public init(
        name: String,
        kind: String,
        parameters: [String: String] = [:],
        support: ExchangeEffectSupport = .supported,
        rawRepresentation: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.parameters = parameters
        self.support = support
        self.rawRepresentation = rawRepresentation
    }
}

public struct ExchangeMarker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var start: ExchangeTime
    public var duration: ExchangeTime
    public var note: String?

    public init(
        id: String,
        name: String,
        start: ExchangeTime,
        duration: ExchangeTime = .zero,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.duration = duration
        self.note = note
    }
}

public struct ExchangeCaption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var language: String
    public var role: String?
    public var start: ExchangeTime
    public var duration: ExchangeTime

    public init(
        id: String,
        text: String,
        language: String,
        role: String? = nil,
        start: ExchangeTime,
        duration: ExchangeTime
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.role = role
        self.start = start
        self.duration = duration
    }
}

public struct ExchangeClip: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var mediaID: String
    public var start: ExchangeTime
    public var duration: ExchangeTime
    public var sourceStart: ExchangeTime
    public var enabled: Bool
    public var retime: ExchangeRetime?
    public var effects: [ExchangeEffect]
    public var markers: [ExchangeMarker]
    public var captions: [ExchangeCaption]
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        mediaID: String,
        start: ExchangeTime,
        duration: ExchangeTime,
        sourceStart: ExchangeTime = .zero,
        enabled: Bool = true,
        retime: ExchangeRetime? = nil,
        effects: [ExchangeEffect] = [],
        markers: [ExchangeMarker] = [],
        captions: [ExchangeCaption] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.mediaID = mediaID
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.enabled = enabled
        self.retime = retime
        self.effects = effects
        self.markers = markers
        self.captions = captions
        self.metadata = metadata
    }

    public var end: ExchangeTime {
        (try? start.adding(duration)) ?? start
    }
}

public struct ExchangeGap: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: ExchangeTime
    public var duration: ExchangeTime

    public init(id: String, start: ExchangeTime, duration: ExchangeTime) {
        self.id = id
        self.start = start
        self.duration = duration
    }

    public var end: ExchangeTime {
        (try? start.adding(duration)) ?? start
    }
}

public enum ExchangeTimelineItem: Codable, Hashable, Sendable, Identifiable {
    case clip(ExchangeClip)
    case gap(ExchangeGap)

    public var id: String {
        switch self {
        case let .clip(clip): return clip.id
        case let .gap(gap): return gap.id
        }
    }

    public var start: ExchangeTime {
        switch self {
        case let .clip(clip): return clip.start
        case let .gap(gap): return gap.start
        }
    }

    public var duration: ExchangeTime {
        switch self {
        case let .clip(clip): return clip.duration
        case let .gap(gap): return gap.duration
        }
    }

    public var end: ExchangeTime {
        (try? start.adding(duration)) ?? start
    }
}

public enum ExchangeTrackKind: String, Codable, Hashable, Sendable {
    case video
    case audio
    case subtitle
}

public struct ExchangeTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ExchangeTrackKind
    public var name: String
    public var items: [ExchangeTimelineItem]

    public init(id: String, kind: ExchangeTrackKind, name: String, items: [ExchangeTimelineItem]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.items = items
    }
}

public struct ExchangeTimeline: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var frameRate: ExchangeFrameRate
    public var globalStart: ExchangeTime
    public var tracks: [ExchangeTrack]
    public var media: [ExchangeMediaReference]
    public var markers: [ExchangeMarker]
    public var sourceRevision: UInt64
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        frameRate: ExchangeFrameRate,
        globalStart: ExchangeTime = .zero,
        tracks: [ExchangeTrack],
        media: [ExchangeMediaReference],
        markers: [ExchangeMarker] = [],
        sourceRevision: UInt64 = 1,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.frameRate = frameRate
        self.globalStart = globalStart
        self.tracks = tracks
        self.media = media
        self.markers = markers
        self.sourceRevision = sourceRevision
        self.metadata = metadata
    }

    /// End of the latest item on any track, in the timeline's time base.
    public var duration: ExchangeTime {
        var maximum = ExchangeTime.zero
        for track in tracks {
            for item in track.items where item.end > maximum {
                maximum = item.end
            }
        }
        return maximum
    }

    public var allClips: [ExchangeClip] {
        tracks.flatMap { track in
            track.items.compactMap { item in
                if case let .clip(clip) = item { return clip }
                return nil
            }
        }
    }

    public func track(id: String) -> ExchangeTrack? {
        tracks.first { $0.id == id }
    }

    public func media(id: String) -> ExchangeMediaReference? {
        media.first { $0.id == id }
    }

    /// Validates the structurally checkable subset. It intentionally does not
    /// validate media existence (that requires a package root/bookmark).
    public func validate() throws {
        guard !id.isEmpty else { throw ExchangePathError.missingMediaID("timeline id") }
        var seen = Set<String>()
        for reference in media {
            guard !reference.id.isEmpty else { throw ExchangePathError.missingMediaID("media id") }
            guard seen.insert(reference.id).inserted else {
                throw ExchangePathError.duplicateIdentifier(reference.id)
            }
            try reference.source.validate()
            if let duration = reference.duration, duration.isZero {
                throw ExchangePathError.invalidDuration(reference.id)
            }
            if reference.kind == .audio, !reference.hasAudio {
                throw ExchangePathError.audioMediaWithoutAudio(reference.id)
            }
            if reference.kind == .video, !reference.hasVideo {
                throw ExchangePathError.videoMediaWithoutVideo(reference.id)
            }
        }
        var trackIDs = Set<String>()
        var itemIDs = Set<String>()
        for track in tracks {
            guard !track.id.isEmpty else { throw ExchangePathError.duplicateIdentifier("empty track id") }
            guard trackIDs.insert(track.id).inserted else {
                throw ExchangePathError.duplicateIdentifier(track.id)
            }
            var previousEnd = ExchangeTime.zero
            for item in track.items {
                guard itemIDs.insert(item.id).inserted else {
                    throw ExchangePathError.duplicateIdentifier(item.id)
                }
                guard item.duration.isZero == false else {
                    throw ExchangePathError.invalidDuration(item.id)
                }
                if item.start < previousEnd {
                    throw ExchangePathError.overlappingItems(track: track.id)
                }
                previousEnd = item.end
                switch item {
                case let .gap(gap):
                    guard gap.duration.isZero == false else {
                        throw ExchangePathError.invalidDuration(gap.id)
                    }
                case let .clip(clip):
                    guard let media = media.first(where: { $0.id == clip.mediaID }) else {
                        throw ExchangePathError.missingMediaID(clip.mediaID)
                    }
                    if track.kind == .video, !media.hasVideo {
                        throw ExchangePathError.videoMediaWithoutVideo(media.id)
                    }
                    if track.kind == .audio, !media.hasAudio {
                        throw ExchangePathError.audioMediaWithoutAudio(media.id)
                    }
                    if let retime = clip.retime, retime.rate.isZero {
                        throw ExchangePathError.invalidDuration(clip.id)
                    }
                    for marker in clip.markers {
                        guard marker.start <= clip.duration,
                              marker.duration.isZero || ((try? marker.start.adding(marker.duration)) ?? marker.start) <= clip.duration
                        else { throw ExchangePathError.invalidMarker(marker.id) }
                    }
                    for caption in clip.captions {
                        guard caption.start <= clip.duration,
                              ((try? caption.start.adding(caption.duration)) ?? caption.start) <= clip.duration
                        else { throw ExchangePathError.invalidCaption(caption.id) }
                    }
                }
            }
        }
        for marker in markers {
            guard marker.start <= duration,
                  marker.duration.isZero || ((try? marker.start.adding(marker.duration)) ?? marker.start) <= duration
            else { throw ExchangePathError.invalidMarker(marker.id) }
        }
    }

    public func mediaReference(for clip: ExchangeClip) throws -> ExchangeMediaReference {
        guard let reference = media.first(where: { $0.id == clip.mediaID }) else {
            throw ExchangePathError.missingMediaID(clip.mediaID)
        }
        return reference
    }
}

// MARK: - Image exchange

public struct ExchangeImageDocument: Sendable, Equatable {
    public var document: PortableDocument
    public var sourceRevision: UInt64
    public var unsupported: [ExchangeUnsupportedItem]
    public var warnings: [String]

    public init(
        document: PortableDocument,
        sourceRevision: UInt64 = 1,
        unsupported: [ExchangeUnsupportedItem] = [],
        warnings: [String] = []
    ) {
        self.document = document
        self.sourceRevision = sourceRevision
        self.unsupported = unsupported
        self.warnings = warnings
    }
}

// MARK: - Diagnostics

public struct ExchangeUnsupportedItem: Codable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var reason: String
    public var rawRepresentation: String?

    public init(path: String, name: String, reason: String, rawRepresentation: String? = nil) {
        self.path = path
        self.name = name
        self.reason = reason
        self.rawRepresentation = rawRepresentation
    }
}

public struct ExchangeImportReport: Codable, Hashable, Sendable {
    public var unsupported: [ExchangeUnsupportedItem]
    public var missingMedia: [String]
    public var warnings: [String]
    public var captionsImported: Int
    public var effectsReported: Int
    public var mediaRelinked: [String: String]

    public init(
        unsupported: [ExchangeUnsupportedItem] = [],
        missingMedia: [String] = [],
        warnings: [String] = [],
        captionsImported: Int = 0,
        effectsReported: Int = 0,
        mediaRelinked: [String: String] = [:]
    ) {
        self.unsupported = unsupported
        self.missingMedia = missingMedia
        self.warnings = warnings
        self.captionsImported = captionsImported
        self.effectsReported = effectsReported
        self.mediaRelinked = mediaRelinked
    }

    public var isEmpty: Bool {
        unsupported.isEmpty && missingMedia.isEmpty && warnings.isEmpty
            && captionsImported == 0 && effectsReported == 0 && mediaRelinked.isEmpty
    }
}
