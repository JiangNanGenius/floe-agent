// SPDX-License-Identifier: MPL-2.0

// UI-free multi-track timeline model for the Mac creative workbench.
//
// The Mac app target does not link the iPad `FloeWorkbench` package, so this
// file mirrors the shipping v1.8.73 prepared-timeline contracts with the same
// semantics using Foundation only:
//
//   * `MacRationalTime`/`MacTimeRange` mirror `FloeWorkbench.MediaRationalTime`
//     and `MediaTimeRange` (validated non-negative value, positive timescale,
//     90 000 timeline timescale, exact cross-multiplied comparison).
//   * `MacTimelineTrack`/`MacTimelineClip` mirror the `visual`/`audio`/
//     `caption` subset of `MediaPreparedTrack`/`MediaPreparedClip`: typed
//     tracks whose array order is the compositing/stack order, clips carry a
//     timeline range plus a source range, caption clips carry text, visual
//     clips carry a non-destructive `MacVideoGrade`.
//   * `MacTimelineDraft` is the durable unit: a Codable document with strict
//     field checking (unknown keys are rejected, mirroring the iPad media
//     grade decoding policy) so a draft saved by a newer build never opens
//     silently with lost content.
//
// Clips reference their inputs by absolute file URL. The timeline never owns,
// moves or mutates the input bytes; render/export always writes fresh output.
// Every edit is value-typed, validated and unit-testable without AVFoundation.

import FloeCore
import Foundation

// MARK: - Errors

enum MacTimelineError: Error, Hashable, LocalizedError {
    case invalidTime
    case overlap
    case missingTrack(UUID)
    case missingClip(UUID)
    case kindMismatch
    case limit(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTime:
            return MacTimelineStrings.invalidTime
        case .overlap:
            return MacTimelineStrings.overlap
        case .missingTrack(let id):
            return String(format: MacTimelineStrings.missingTrackFormat, id.uuidString)
        case .missingClip(let id):
            return String(format: MacTimelineStrings.missingClipFormat, id.uuidString)
        case .kindMismatch:
            return MacTimelineStrings.kindMismatch
        case .limit(let detail):
            return String(format: MacTimelineStrings.limitFormat, detail)
        case .malformed(let detail):
            return String(format: MacTimelineStrings.malformedFormat, detail)
        }
    }
}

// MARK: - Time

/// Rational timeline time; mirrors `MediaRationalTime` semantics. The
/// cross-multiplied `<` plus equivalent-equality `==` give exact rational
/// comparison; `Comparable` derives `<=`/`>=`/`>` from those two.
struct MacRationalTime: Sendable, Hashable, Codable, Comparable {
    static let timelineTimescale: Int32 = 90_000
    /// Same policy as the iPad media schema: nothing on a timeline exceeds
    /// one day.
    static let maximumSeconds: Double = 86_400

    var value: Int64
    var timescale: Int32

    init(value: Int64, timescale: Int32 = MacRationalTime.timelineTimescale) throws {
        guard timescale > 0 else { throw MacTimelineError.invalidTime }
        guard value >= 0 else { throw MacTimelineError.invalidTime }
        self.value = value
        self.timescale = timescale
    }

    /// Converts seconds with half-away-from-zero rounding at `timescale`,
    /// exactly like `MediaRationalTime.seconds(_:)`.
    static func seconds(_ seconds: Double, timescale: Int32 = MacRationalTime.timelineTimescale) throws -> Self {
        guard seconds.isFinite, seconds >= 0, seconds <= maximumSeconds else { throw MacTimelineError.invalidTime }
        guard timescale > 0 else { throw MacTimelineError.invalidTime }
        let scaled = seconds * Double(timescale)
        guard scaled <= Double(Int64.max) else { throw MacTimelineError.invalidTime }
        return try Self(value: Int64(scaled.rounded(.toNearestOrAwayFromZero)), timescale: timescale)
    }

    var seconds: Double { Double(value) / Double(timescale) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let (left, leftOverflow) = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let (right, rightOverflow) = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        if !leftOverflow, !rightOverflow { return left < right }
        return lhs.seconds < rhs.seconds
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private enum CodingKeys: String, CodingKey { case value, timescale }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        guard timescale > 0, value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: container,
                                                   debugDescription: "time must be non-negative with a positive timescale")
        }
        self.value = value
        self.timescale = timescale
    }
}

/// Half-open rational interval `[start, start + duration)`; mirrors
/// `MediaTimeRange` (start/duration share a timescale, duration non-negative).
struct MacTimeRange: Sendable, Hashable, Codable {
    var start: MacRationalTime
    var duration: MacRationalTime

    init(start: MacRationalTime, duration: MacRationalTime) throws {
        guard duration.value >= 0 else { throw MacTimelineError.invalidTime }
        guard start.timescale == duration.timescale else { throw MacTimelineError.invalidTime }
        guard start.seconds + duration.seconds <= MacRationalTime.maximumSeconds + .ulpOfOne else {
            throw MacTimelineError.invalidTime
        }
        self.start = start
        self.duration = duration
    }

    static func seconds(start: Double, duration: Double) throws -> Self {
        try Self(start: .seconds(start), duration: .seconds(duration))
    }

    var startSeconds: Double { start.seconds }
    var durationSeconds: Double { duration.seconds }
    var endSeconds: Double { startSeconds + durationSeconds }

    func contains(_ time: MacRationalTime) -> Bool {
        time >= start && time.seconds < endSeconds
    }

    /// True when the two ranges intersect with positive length (adjacent
    /// ranges do not overlap).
    func overlaps(_ other: MacTimeRange) -> Bool {
        start.seconds < other.endSeconds && other.start.seconds < endSeconds
    }
}

// MARK: - Tracks and clips

enum MacTrackKind: String, Sendable, Codable, Hashable, CaseIterable {
    case visual, audio, caption
}

/// One clip in a typed track. `sourceURL` is the absolute file URL of the
/// input media (nil for caption-only clips); it is a read-only reference.
struct MacTimelineClip: Sendable, Codable, Hashable, Identifiable {
    static let maximumCaptionBytes = 32_768

    var id: UUID
    var sourceURL: URL?
    var title: String
    var timelineRange: MacTimeRange
    var sourceRange: MacTimeRange
    var isMuted: Bool
    var volume: Double
    /// Caption/title text for `.caption` clips; nil for media clips.
    var captionText: String?
    /// Non-destructive visual grade for `.visual` clips.
    var grade: MacVideoGrade?

    init(id: UUID = UUID(), sourceURL: URL? = nil, title: String = "",
         timelineRange: MacTimeRange, sourceRange: MacTimeRange,
         isMuted: Bool = false, volume: Double = 1,
         captionText: String? = nil, grade: MacVideoGrade? = nil) throws {
        guard volume.isFinite, (0...4).contains(volume) else { throw MacTimelineError.malformed("volume") }
        if let captionText {
            guard !captionText.isEmpty, captionText.utf8.count <= Self.maximumCaptionBytes,
                  !captionText.contains("<"), !captionText.contains(">") else {
                throw MacTimelineError.malformed("caption")
            }
        }
        if let grade { try grade.validate() }
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.timelineRange = timelineRange
        self.sourceRange = sourceRange
        self.isMuted = isMuted
        self.volume = volume
        self.captionText = captionText
        self.grade = grade
    }

    /// A media clip factory; duration comes from the verified asset duration
    /// probed by the caller (same contract as the iPad import path).
    static func media(id: UUID = UUID(), sourceURL: URL, title: String,
                      timelineStart: Double, sourceStart: Double = 0,
                      duration: Double, isMuted: Bool = false, volume: Double = 1) throws -> Self {
        guard duration > 0 else { throw MacTimelineError.invalidTime }
        return try Self(
            id: id, sourceURL: sourceURL, title: title,
            timelineRange: .seconds(start: timelineStart, duration: duration),
            sourceRange: .seconds(start: sourceStart, duration: duration),
            isMuted: isMuted, volume: volume)
    }

    /// A caption clip factory; mirrors the iPad subtitle-import clip shape
    /// (source range starts at zero with the cue duration).
    static func caption(id: UUID = UUID(), timelineStart: Double, duration: Double,
                        text: String, title: String = "") throws -> Self {
        try Self(
            id: id, sourceURL: nil, title: title,
            timelineRange: .seconds(start: timelineStart, duration: duration),
            sourceRange: .seconds(start: 0, duration: duration),
            captionText: text)
    }

    var isCaption: Bool { captionText != nil && sourceURL == nil }
    var timelineEnd: Double { timelineRange.endSeconds }
}

/// One typed track; the track array order is the stack order. Mirrors the
/// `MediaPreparedTrack` subset (no lock/adjustment lanes on the Mac board).
struct MacTimelineTrack: Sendable, Codable, Hashable, Identifiable {
    static let maximumClips = 512

    var id: UUID
    var kind: MacTrackKind
    var name: String
    var isMuted: Bool
    var volume: Double
    var clips: [MacTimelineClip]

    init(id: UUID = UUID(), kind: MacTrackKind, name: String,
         isMuted: Bool = false, volume: Double = 1, clips: [MacTimelineClip] = []) throws {
        guard volume.isFinite, (0...4).contains(volume) else { throw MacTimelineError.malformed("volume") }
        self.id = id
        self.kind = kind
        self.name = name
        self.isMuted = isMuted
        self.volume = volume
        self.clips = []
        for clip in clips { try insert(clip) }
    }

    var duration: Double { clips.map(\.timelineEnd).max() ?? 0 }

    func clip(_ id: UUID) -> MacTimelineClip? { clips.first { $0.id == id } }

    /// True when the clip may live on this track: caption clips only on
    /// caption tracks, media clips only on visual/audio tracks.
    private func accepts(_ clip: MacTimelineClip) -> Bool {
        switch kind {
        case .caption: return clip.captionText != nil
        case .visual, .audio: return clip.captionText == nil
        }
    }

    /// Re-runs every clip invariant through the validated initializer so a
    /// clip mutated after creation can never bypass the model rules.
    private func revalidated(_ clip: MacTimelineClip) throws -> MacTimelineClip {
        try MacTimelineClip(
            id: clip.id, sourceURL: clip.sourceURL, title: clip.title,
            timelineRange: clip.timelineRange, sourceRange: clip.sourceRange,
            isMuted: clip.isMuted, volume: clip.volume,
            captionText: clip.captionText, grade: clip.grade)
    }

    /// Inserts a clip keeping the array sorted by timeline start and refusing
    /// overlaps, mirroring the iPad track-graph integrity rule.
    mutating func insert(_ clip: MacTimelineClip) throws {
        guard clips.count < Self.maximumClips else { throw MacTimelineError.limit("clips") }
        guard accepts(clip) else { throw MacTimelineError.kindMismatch }
        let checked = try revalidated(clip)
        guard clips.allSatisfy({ !$0.timelineRange.overlaps(checked.timelineRange) }) else {
            throw MacTimelineError.overlap
        }
        clips.append(checked)
        clips.sort { $0.timelineRange.start < $1.timelineRange.start }
    }

    /// Replaces a clip in place, re-validating kind, payload and overlap
    /// against its track siblings.
    mutating func replace(_ clip: MacTimelineClip) throws {
        guard accepts(clip) else { throw MacTimelineError.kindMismatch }
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else {
            throw MacTimelineError.missingClip(clip.id)
        }
        let checked = try revalidated(clip)
        let siblings = clips.filter { $0.id != clip.id }
        guard siblings.allSatisfy({ !$0.timelineRange.overlaps(checked.timelineRange) }) else {
            throw MacTimelineError.overlap
        }
        clips[index] = checked
        clips.sort { $0.timelineRange.start < $1.timelineRange.start }
    }

    mutating func remove(_ id: UUID) throws {
        guard clips.contains(where: { $0.id == id }) else { throw MacTimelineError.missingClip(id) }
        clips.removeAll { $0.id == id }
    }
}

// MARK: - Draft document

/// Durable timeline draft. Strict decoding rejects unknown fields so a draft
// saved by a newer build never opens with silently dropped content.
struct MacTimelineDraft: Sendable, Codable, Hashable, Identifiable {
    static let currentSchemaVersion = 1
    static let maximumTracks = 32
    static let defaultCanvasWidth = 1920
    static let defaultCanvasHeight = 1080
    static let defaultFrameRate = 30.0

    var schemaVersion: Int
    var id: UUID
    var name: String
    var canvasWidth: Int
    var canvasHeight: Int
    var frameRate: Double
    var tracks: [MacTimelineTrack]
    var createdAt: Date
    var updatedAt: Date
    var revision: Int64

    init(id: UUID = UUID(), name: String,
         canvasWidth: Int = MacTimelineDraft.defaultCanvasWidth,
         canvasHeight: Int = MacTimelineDraft.defaultCanvasHeight,
         frameRate: Double = MacTimelineDraft.defaultFrameRate,
         tracks: [MacTimelineTrack] = []) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacTimelineError.malformed("name")
        }
        guard canvasWidth >= 16, canvasHeight >= 16, canvasWidth % 2 == 0, canvasHeight % 2 == 0,
              canvasWidth <= 16_384, canvasHeight <= 16_384 else {
            throw MacTimelineError.malformed("canvas")
        }
        guard frameRate.isFinite, (1...120).contains(frameRate) else {
            throw MacTimelineError.malformed("frame rate")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameRate = frameRate
        self.tracks = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.revision = 0
        for track in tracks { try addTrack(track) }
    }

    var totalDurationSeconds: Double {
        tracks.flatMap(\.clips).map(\.timelineEnd).max() ?? 0
    }

    /// True when at least one unmuted visual clip contributes picture, the
    /// same exportability rule as the iPad renderer.
    var hasRenderableVideo: Bool {
        tracks.contains { track in
            track.kind == .visual && !track.isMuted && track.clips.contains { !$0.isMuted && $0.timelineRange.durationSeconds > 0 }
        }
    }

    func track(_ id: UUID) -> MacTimelineTrack? { tracks.first { $0.id == id } }

    func clip(_ id: UUID) -> (track: MacTimelineTrack, clip: MacTimelineClip)? {
        for track in tracks {
            if let clip = track.clip(id) { return (track, clip) }
        }
        return nil
    }

    func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    // MARK: Track edits

    @discardableResult
    mutating func addTrack(_ kind: MacTrackKind, name: String? = nil) throws -> MacTimelineTrack {
        let track = try MacTimelineTrack(kind: kind, name: name ?? Self.defaultName(for: kind))
        try addTrack(track)
        return track
    }

    mutating func addTrack(_ track: MacTimelineTrack) throws {
        guard tracks.count < Self.maximumTracks else { throw MacTimelineError.limit("tracks") }
        guard !tracks.contains(where: { $0.id == track.id }) else { throw MacTimelineError.malformed("duplicate track") }
        tracks.append(track)
        touch()
    }

    mutating func removeTrack(_ id: UUID) throws {
        guard tracks.contains(where: { $0.id == id }) else { throw MacTimelineError.missingTrack(id) }
        tracks.removeAll { $0.id == id }
        touch()
    }

    /// Reorders a track to `index` (clamped), keeping the rest in order.
    mutating func moveTrack(_ id: UUID, to index: Int) throws {
        guard let from = trackIndex(id) else { throw MacTimelineError.missingTrack(id) }
        let track = tracks.remove(at: from)
        tracks.insert(track, at: min(max(index, 0), tracks.count))
        touch()
    }

    mutating func renameTrack(_ id: UUID, name: String) throws {
        guard let index = trackIndex(id) else { throw MacTimelineError.missingTrack(id) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MacTimelineError.malformed("name") }
        tracks[index].name = title
        touch()
    }

    mutating func setTrackMuted(_ id: UUID, muted: Bool) throws {
        guard let index = trackIndex(id) else { throw MacTimelineError.missingTrack(id) }
        tracks[index].isMuted = muted
        touch()
    }

    mutating func setTrackVolume(_ id: UUID, volume: Double) throws {
        guard volume.isFinite, (0...4).contains(volume) else { throw MacTimelineError.malformed("volume") }
        guard let index = trackIndex(id) else { throw MacTimelineError.missingTrack(id) }
        tracks[index].volume = volume
        touch()
    }

    // MARK: Clip edits

    @discardableResult
    mutating func addClip(_ clip: MacTimelineClip, toTrack trackID: UUID) throws -> MacTimelineClip {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        try tracks[index].insert(clip)
        touch()
        return clip
    }

    mutating func removeClip(trackID: UUID, clipID: UUID) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        try tracks[index].remove(clipID)
        touch()
    }

    /// Replaces a whole clip (geometry, source range, caption text, grade,
    /// mute/volume) after re-validating it against its track siblings.
    mutating func replaceClip(trackID: UUID, clip: MacTimelineClip) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        try tracks[index].replace(clip)
        touch()
    }

    /// Moves a clip to a new timeline start; source range is unchanged.
    mutating func moveClip(trackID: UUID, clipID: UUID, newStart: Double) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        guard var clip = tracks[index].clip(clipID) else { throw MacTimelineError.missingClip(clipID) }
        clip.timelineRange = try .seconds(start: newStart, duration: clip.timelineRange.durationSeconds)
        try tracks[index].replace(clip)
        touch()
    }

    /// Re-trims a clip: new timeline duration and a matching source offset.
    /// The source range end is clamped by the caller against the verified
    /// asset duration before reaching this API.
    mutating func trimClip(trackID: UUID, clipID: UUID,
                           newTimelineStart: Double? = nil,
                           newDuration: Double,
                           newSourceStart: Double) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        guard var clip = tracks[index].clip(clipID) else { throw MacTimelineError.missingClip(clipID) }
        guard newDuration > 0, newSourceStart >= 0 else { throw MacTimelineError.invalidTime }
        let start = newTimelineStart ?? clip.timelineRange.startSeconds
        clip.timelineRange = try .seconds(start: start, duration: newDuration)
        clip.sourceRange = try .seconds(start: newSourceStart, duration: newDuration)
        try tracks[index].replace(clip)
        touch()
    }

    mutating func setClipCaption(trackID: UUID, clipID: UUID, text: String) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        guard tracks[index].kind == .caption else { throw MacTimelineError.kindMismatch }
        guard var clip = tracks[index].clip(clipID) else { throw MacTimelineError.missingClip(clipID) }
        guard !text.isEmpty, text.utf8.count <= MacTimelineClip.maximumCaptionBytes,
              !text.contains("<"), !text.contains(">") else { throw MacTimelineError.malformed("caption") }
        clip.captionText = text
        try tracks[index].replace(clip)
        touch()
    }

    mutating func setClipGrade(trackID: UUID, clipID: UUID, grade: MacVideoGrade?) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        guard tracks[index].kind == .visual else { throw MacTimelineError.kindMismatch }
        guard var clip = tracks[index].clip(clipID) else { throw MacTimelineError.missingClip(clipID) }
        if let grade { try grade.validate() }
        clip.grade = grade
        try tracks[index].replace(clip)
        touch()
    }

    mutating func setClipMuted(trackID: UUID, clipID: UUID, muted: Bool) throws {
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        guard var clip = tracks[index].clip(clipID) else { throw MacTimelineError.missingClip(clipID) }
        clip.isMuted = muted
        try tracks[index].replace(clip)
        touch()
    }

    mutating func setClipVolume(trackID: UUID, clipID: UUID, volume: Double) throws {
        guard volume.isFinite, (0...4).contains(volume) else { throw MacTimelineError.malformed("volume") }
        guard let index = trackIndex(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        guard var clip = tracks[index].clip(clipID) else { throw MacTimelineError.missingClip(clipID) }
        clip.volume = volume
        try tracks[index].replace(clip)
        touch()
    }

    mutating func rename(_ name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MacTimelineError.malformed("name") }
        self.name = title
        touch()
    }

    private mutating func touch() {
        updatedAt = Date()
        revision += 1
    }

    static func defaultName(for kind: MacTrackKind) -> String {
        switch kind {
        case .visual: return MacTimelineStrings.defaultVideoTrack
        case .audio: return MacTimelineStrings.defaultAudioTrack
        case .caption: return MacTimelineStrings.defaultCaptionTrack
        }
    }

    // MARK: Strict decoding

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, name, canvasWidth, canvasHeight, frameRate
        case tracks, createdAt, updatedAt, revision
    }

    init(from decoder: any Decoder) throws {
        try MacCodableFields.check(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                                                   debugDescription: "unsupported timeline draft schema \(schemaVersion)")
        }
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        canvasWidth = try c.decode(Int.self, forKey: .canvasWidth)
        canvasHeight = try c.decode(Int.self, forKey: .canvasHeight)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        tracks = try c.decode([MacTimelineTrack].self, forKey: .tracks)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        revision = try c.decode(Int64.self, forKey: .revision)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              canvasWidth >= 16, canvasHeight >= 16, canvasWidth % 2 == 0, canvasHeight % 2 == 0,
              frameRate.isFinite, (1...120).contains(frameRate),
              tracks.count <= Self.maximumTracks else {
            throw DecodingError.dataCorruptedError(forKey: .tracks, in: c,
                                                   debugDescription: "timeline draft bounds are invalid")
        }
    }
}

/// Strict-field decoding helper shared by the parity coders: unknown keys are
/// rejected instead of silently dropped (the iPad media codec policy).
enum MacCodableFields {
    private struct Field: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func check(_ decoder: any Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: Field.self)
        if let unknown = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [unknown],
                                                    debugDescription: "Unknown field \(unknown.stringValue)"))
        }
    }
}

// MARK: - Bilingual strings

enum MacTimelineStrings {
    static var invalidTime: String { t(en: "The time values are invalid.", zh: "时间值无效。") }
    static var overlap: String { t(en: "Clips on a track cannot overlap.", zh: "同一条轨道上的片段不能重叠。") }
    static var missingTrackFormat: String { t(en: "The track %@ no longer exists.", zh: "轨道 %@ 已不存在。") }
    static var missingClipFormat: String { t(en: "The clip %@ no longer exists.", zh: "片段 %@ 已不存在。") }
    static var kindMismatch: String { t(en: "That action does not apply to this track type.", zh: "该操作不适用于此轨道类型。") }
    static var limitFormat: String { t(en: "The timeline limit was reached: %@.", zh: "已达到时间线限制：%@。") }
    static var malformedFormat: String { t(en: "The draft is invalid: %@.", zh: "草稿无效：%@。") }
    static var defaultVideoTrack: String { t(en: "Video", zh: "视频") }
    static var defaultAudioTrack: String { t(en: "Audio", zh: "音频") }
    static var defaultCaptionTrack: String { t(en: "Captions", zh: "字幕") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
