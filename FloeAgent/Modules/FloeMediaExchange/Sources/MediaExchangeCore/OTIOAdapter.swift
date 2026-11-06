// SPDX-License-Identifier: MPL-2.0
//
// OpenTimelineIO JSON adapter for the documented Floe exchange subset.
//
// Supported: Timeline/Stack/Track/Clip/Gap/Marker/ExternalReference and the
// LinearTimeWarp retime effect. Unknown schemas and unknown effects are
// retained in the import report (and, when a JSON object is available, in the
// rawRepresentation field) rather than silently dropped. Captions are outside
// the OTIO subset and must be reported or rejected; they are never guessed
// into text clips.
//
// No Python interpreter is embedded. The adapter is pure Swift JSON.

import Foundation

public enum OTIOError: Error, Equatable, CustomStringConvertible {
    case notAnObject(String)
    case unsupportedSchema(String)
    case missingField(String)
    case invalidField(String)
    case invalidTime(String)
    case invalidFrameRate(String)
    case unsupportedFeature(String)
    case unsupportedEffect(String)
    case invalidTimeline(String)
    case missingMediaReference(String)

    public var description: String {
        switch self {
        case let .notAnObject(field): return "OTIO \(field) is not a JSON object"
        case let .unsupportedSchema(schema): return "unsupported OTIO schema \(schema)"
        case let .missingField(field): return "OTIO is missing \(field)"
        case let .invalidField(field): return "OTIO field is invalid: \(field)"
        case let .invalidTime(field): return "OTIO time is invalid: \(field)"
        case let .invalidFrameRate(field): return "OTIO frame rate is invalid: \(field)"
        case let .unsupportedFeature(feature): return "OTIO adapter does not support \(feature)"
        case let .unsupportedEffect(effect): return "OTIO effect cannot be preserved: \(effect)"
        case let .invalidTimeline(reason): return "invalid OTIO timeline: \(reason)"
        case let .missingMediaReference(id): return "OTIO clip media reference is missing \(id)"
        }
    }
}

public struct OTIOResult: Sendable {
    public var timeline: ExchangeTimeline
    public var report: ExchangeImportReport
    public var rawJSON: Data

    public init(timeline: ExchangeTimeline, report: ExchangeImportReport, rawJSON: Data) {
        self.timeline = timeline
        self.report = report
        self.rawJSON = rawJSON
    }
}

public enum OTIOAdapter {
    public static let schemaVersion = 1

    // MARK: - Export

    /// Serializes the documented subset. Unsupported effects are retained only
    /// when their raw JSON object is available; otherwise this throws instead
    /// of dropping them. Captions are rejected because OTIO has no baseline
    /// caption schema.
    public static func export(_ timeline: ExchangeTimeline) throws -> Data {
        try timeline.validate()
        for clip in timeline.allClips {
            if !clip.captions.isEmpty {
                throw OTIOError.unsupportedFeature(
                    "captions on clip \(clip.id) are not part of the documented OTIO subset"
                )
            }
            for effect in clip.effects {
                if effect.support == .reported {
                    if effect.rawRepresentation.flatMap(parseJSONObject) == nil {
                        throw OTIOError.unsupportedEffect(effect.name)
                    }
                } else if effect.support == .supported {
                    // The documented subset has no general effect mapping.
                    // Refuse instead of silently dropping a "supported" effect
                    // that this adapter cannot actually serialize.
                    throw OTIOError.unsupportedEffect(effect.name)
                }
            }
        }

        let rate = timeline.frameRate.nominal
        var trackObjects: [[String: Any]] = []
        for track in timeline.tracks {
            let kind: String
            switch track.kind {
            case .video: kind = "Video"
            case .audio: kind = "Audio"
            case .subtitle: kind = "Video"
            }
            var children: [[String: Any]] = []
            var cursor = ExchangeTime.zero
            for (index, item) in track.items.sorted(by: { $0.start < $1.start }).enumerated() {
                if item.start > cursor {
                    let impliedDuration = try item.start.subtracting(cursor)
                    let implied = ExchangeGap(
                        id: "implicit-gap-\(track.id)-\(index)",
                        start: cursor,
                        duration: impliedDuration
                    )
                    children.append(gapObject(implied, rate: rate))
                    cursor = item.start
                }
                switch item {
                case let .gap(gap):
                    children.append(gapObject(gap, rate: rate))
                case let .clip(clip):
                    children.append(try clipObject(clip, timeline: timeline, rate: rate))
                }
                cursor = item.end
            }
            trackObjects.append([
                "OTIO_SCHEMA": "Track.1",
                "name": track.name,
                "kind": kind,
                "metadata": [
                    "floe": [
                        "schema": schemaVersion,
                        "id": track.id,
                        "kind": track.kind.rawValue
                    ]
                ],
                "children": children
            ])
        }

        var timelineMetadata: [String: Any] = [
            "schema": schemaVersion,
            "id": timeline.id,
            "name": timeline.name,
            "source_revision": timeline.sourceRevision,
            "frame_rate": [
                "numerator": timeline.frameRate.numerator,
                "denominator": timeline.frameRate.denominator
            ]
        ]
        if !timeline.metadata.isEmpty {
            timelineMetadata["user"] = timeline.metadata
        }
        let stack: [String: Any] = [
            "OTIO_SCHEMA": "Stack.1",
            "name": "tracks",
            "metadata": ["floe": timelineMetadata],
            "children": trackObjects,
            "markers": timeline.markers.map { markerObject($0, rate: rate) }
        ]
        let root: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1",
            "name": timeline.name,
            "global_start_time": rationalTime(
                timeline.globalStart,
                rate: rate,
                metadata: ["value": timeline.globalStart.value, "timescale": timeline.globalStart.timescale]
            ),
            "metadata": [
                "floe": [
                    "schema": schemaVersion,
                    "id": timeline.id,
                    "source_revision": timeline.sourceRevision,
                    "frame_rate": [
                        "numerator": timeline.frameRate.numerator,
                        "denominator": timeline.frameRate.denominator
                    ],
                    "user": timeline.metadata
                ]
            ],
            "tracks": stack
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Import

    /// Parses the documented subset. `packageRoot` enables packed/external
    /// existence checks and missing-media reporting; it does not open or read
    /// the media bytes.
    public static func importTimeline(_ data: Data, packageRoot: URL? = nil) throws -> OTIOResult {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw OTIOError.invalidField("JSON parse error: \(error)")
        }
        guard let root = object as? [String: Any] else {
            throw OTIOError.notAnObject("root")
        }
        guard string(root, "OTIO_SCHEMA") == "Timeline.1" else {
            throw OTIOError.unsupportedSchema(string(root, "OTIO_SCHEMA") ?? "unknown")
        }
        let rootMetadata = nestedDictionary(root["metadata"], key: "floe")
        let rate = try frameRate(from: rootMetadata, fallback: nil)
        let timelineID = string(rootMetadata, "id") ?? string(root, "name") ?? "otio-timeline"
        let name = string(root, "name") ?? "OTIO timeline"
        let globalStart = try exactTime(
            root["global_start_time"],
            metadata: nil,
            fallbackRate: rate,
            field: "global_start_time"
        )
        let sourceRevision = uint64(rootMetadata, "source_revision") ?? 1
        let userMetadata = stringDictionary(rootMetadata?["user"])

        guard let stack = root["tracks"] as? [String: Any] else {
            throw OTIOError.missingField("tracks")
        }
        guard string(stack, "OTIO_SCHEMA") == "Stack.1" else {
            throw OTIOError.unsupportedSchema(string(stack, "OTIO_SCHEMA") ?? "tracks")
        }
        guard let trackArray = stack["children"] as? [Any] else {
            throw OTIOError.missingField("tracks.children")
        }

        var unsupported: [ExchangeUnsupportedItem] = []
        let warnings: [String] = []
        var mediaByID: [String: ExchangeMediaReference] = [:]
        var tracks: [ExchangeTrack] = []
        for (trackIndex, trackValue) in trackArray.enumerated() {
            guard let trackObject = trackValue as? [String: Any] else {
                unsupported.append(ExchangeUnsupportedItem(
                    path: "tracks.children[\(trackIndex)]",
                    name: "non-object",
                    reason: "track entry is not a JSON object"
                ))
                continue
            }
            guard string(trackObject, "OTIO_SCHEMA") == "Track.1" else {
                unsupported.append(ExchangeUnsupportedItem(
                    path: "tracks.children[\(trackIndex)]",
                    name: string(trackObject, "OTIO_SCHEMA") ?? "unknown",
                    reason: "unsupported track schema"
                ))
                continue
            }
            let trackMetadata = nestedDictionary(trackObject["metadata"], key: "floe")
            let trackID = string(trackMetadata, "id") ?? "track-\(trackIndex)"
            let trackKind = trackKind(
                string(trackMetadata, "kind"),
                fallback: string(trackObject, "kind")
            )
            guard let childArray = trackObject["children"] as? [Any] else {
                throw OTIOError.missingField("Track.children")
            }
            var items: [ExchangeTimelineItem] = []
            var cursor = ExchangeTime.zero
            for (childIndex, childValue) in childArray.enumerated() {
                guard let child = childValue as? [String: Any] else {
                    unsupported.append(ExchangeUnsupportedItem(
                        path: "track[\(trackIndex)].children[\(childIndex)]",
                        name: "non-object",
                        reason: "child entry is not a JSON object"
                    ))
                    continue
                }
                let schema = string(child, "OTIO_SCHEMA") ?? ""
                let childMetadata = nestedDictionary(child["metadata"], key: "floe")
                switch schema {
                case "Gap.1":
                    let duration = try sourceRangeDuration(
                        child["source_range"],
                        fallbackRate: rate,
                        field: "Gap.source_range"
                    )
                    let gap = ExchangeGap(
                        id: string(childMetadata, "id") ?? "gap-\(trackIndex)-\(childIndex)",
                        start: cursor,
                        duration: duration
                    )
                    items.append(.gap(gap))
                    cursor = try cursor.adding(duration)
                case "Clip.1":
                    let clipID = string(childMetadata, "id") ?? "clip-\(trackIndex)-\(childIndex)"
                    let duration = try sourceRangeDuration(
                        child["source_range"],
                        fallbackRate: rate,
                        field: "Clip.source_range"
                    )
                    let sourceStart = try sourceRangeStart(
                        child["source_range"],
                        fallbackRate: rate,
                        field: "Clip.source_range"
                    )
                    let mediaReference = try parseMediaReference(
                        child["media_reference"],
                        clipID: clipID,
                        path: "track[\(trackIndex)].clip[\(clipID)]"
                    )
                    if mediaByID[mediaReference.id] == nil {
                        mediaByID[mediaReference.id] = mediaReference
                    }
                    var effects: [ExchangeEffect] = []
                    var retime: ExchangeRetime?
                    if let effectArray = child["effects"] as? [Any] {
                        for (effectIndex, effectValue) in effectArray.enumerated() {
                            guard let effectObject = effectValue as? [String: Any] else {
                                unsupported.append(ExchangeUnsupportedItem(
                                    path: "track[\(trackIndex)].clip[\(clipID)].effects[\(effectIndex)]",
                                    name: "non-object",
                                    reason: "effect entry is not a JSON object"
                                ))
                                continue
                            }
                            let effectSchema = string(effectObject, "OTIO_SCHEMA") ?? ""
                            let effectName = string(effectObject, "name") ?? effectSchema
                            if effectSchema.hasPrefix("LinearTimeWarp") {
                                let scalar = double(effectObject, "time_scalar")
                                if let scalar, scalar > 0 {
                                    let exact = nestedDictionary(effectObject["metadata"], key: "floe")
                                    if let exactRate = try? exactTimeFromMetadata(exact, field: "retime") {
                                        retime = ExchangeRetime(
                                            rate: exactRate,
                                            preservesPitch: bool(effectObject, "preserves_pitch") ?? true
                                        )
                                    } else if let rate = try? ExchangeFrameRate.rationalApproximation(of: scalar) {
                                        retime = ExchangeRetime(
                                            rate: try ExchangeTime(value: rate.numerator, timescale: rate.denominator),
                                            preservesPitch: bool(effectObject, "preserves_pitch") ?? true
                                        )
                                    } else {
                                        unsupported.append(ExchangeUnsupportedItem(
                                            path: "track[\(trackIndex)].clip[\(clipID)].effects[\(effectIndex)]",
                                            name: effectName,
                                            reason: "invalid LinearTimeWarp time_scalar"
                                        ))
                                    }
                                } else {
                                    unsupported.append(ExchangeUnsupportedItem(
                                        path: "track[\(trackIndex)].clip[\(clipID)].effects[\(effectIndex)]",
                                        name: effectName,
                                        reason: "missing or invalid LinearTimeWarp time_scalar"
                                    ))
                                }
                            } else {
                                let raw = try? stringifyJSON(effectObject)
                                effects.append(ExchangeEffect(
                                    name: effectName,
                                    kind: effectSchema,
                                    support: .reported,
                                    rawRepresentation: raw
                                ))
                                unsupported.append(ExchangeUnsupportedItem(
                                    path: "track[\(trackIndex)].clip[\(clipID)].effects[\(effectIndex)]",
                                    name: effectName,
                                    reason: "effect schema \(effectSchema) is outside the documented subset",
                                    rawRepresentation: raw
                                ))
                            }
                        }
                    }
                    var markers: [ExchangeMarker] = []
                    if let markerArray = child["markers"] as? [Any] {
                        for (markerIndex, markerValue) in markerArray.enumerated() {
                            guard let markerObject = markerValue as? [String: Any] else { continue }
                            markers.append(try parseMarker(
                                markerObject,
                                fallbackRate: rate,
                                id: "marker-\(trackIndex)-\(childIndex)-\(markerIndex)",
                                field: "clip markers"
                            ))
                        }
                    }
                    let clip = ExchangeClip(
                        id: clipID,
                        name: string(child, "name") ?? "Clip",
                        mediaID: mediaReference.id,
                        start: cursor,
                        duration: duration,
                        sourceStart: sourceStart,
                        enabled: bool(childMetadata, "enabled") ?? true,
                        retime: retime,
                        effects: effects,
                        markers: markers
                    )
                    items.append(.clip(clip))
                    cursor = try cursor.adding(duration)
                default:
                    unsupported.append(ExchangeUnsupportedItem(
                        path: "track[\(trackIndex)].children[\(childIndex)]",
                        name: schema.isEmpty ? "unknown" : schema,
                        reason: "unsupported OTIO child schema",
                        rawRepresentation: try? stringifyJSON(child)
                    ))
                }
            }
            tracks.append(ExchangeTrack(
                id: trackID,
                kind: trackKind,
                name: string(trackObject, "name") ?? trackID,
                items: items
            ))
        }

        var timelineMarkers: [ExchangeMarker] = []
        if let markerArray = stack["markers"] as? [Any] {
            for (index, value) in markerArray.enumerated() {
                guard let markerObject = value as? [String: Any] else { continue }
                timelineMarkers.append(try parseMarker(
                    markerObject,
                    fallbackRate: rate,
                    id: "timeline-marker-\(index)",
                    field: "timeline markers"
                ))
            }
        }

        var missingMedia: [String] = []
        if let packageRoot {
            for reference in mediaByID.values {
                do {
                    let url = try reference.source.resolve(in: packageRoot)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        missingMedia.append(reference.id)
                    }
                } catch {
                    missingMedia.append(reference.id)
                }
            }
        }

        let timeline = ExchangeTimeline(
            id: timelineID,
            name: name,
            frameRate: rate,
            globalStart: globalStart,
            tracks: tracks,
            media: mediaByID.values.sorted { $0.id < $1.id },
            markers: timelineMarkers,
            sourceRevision: sourceRevision,
            metadata: userMetadata
        )
        do {
            try timeline.validate()
        } catch {
            throw OTIOError.invalidTimeline(String(describing: error))
        }
        let report = ExchangeImportReport(
            unsupported: unsupported,
            missingMedia: missingMedia,
            warnings: warnings,
            captionsImported: 0,
            effectsReported: unsupported.filter { $0.path.contains(".effects[") }.count
        )
        return OTIOResult(timeline: timeline, report: report, rawJSON: data)
    }

    // MARK: - Object builders

    private static func rationalTime(
        _ time: ExchangeTime,
        rate: Double,
        metadata: [String: Any]?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "OTIO_SCHEMA": "RationalTime.1",
            "rate": rate,
            "value": time.seconds * rate
        ]
        if let metadata {
            object["metadata"] = ["floe": metadata.merging([
                "value": time.value,
                "timescale": time.timescale
            ]) { current, _ in current }]
        }
        return object
    }

    private static func timeRange(_ start: ExchangeTime, _ duration: ExchangeTime, rate: Double) -> [String: Any] {
        [
            "OTIO_SCHEMA": "TimeRange.1",
            "start_time": rationalTime(start, rate: rate, metadata: ["value": start.value, "timescale": start.timescale]),
            "duration": rationalTime(duration, rate: rate, metadata: ["value": duration.value, "timescale": duration.timescale])
        ]
    }

    private static func gapObject(_ gap: ExchangeGap, rate: Double) -> [String: Any] {
        [
            "OTIO_SCHEMA": "Gap.1",
            "name": "Gap",
            "source_range": timeRange(.zero, gap.duration, rate: rate),
            "metadata": ["floe": ["id": gap.id, "duration_value": gap.duration.value, "duration_timescale": gap.duration.timescale]]
        ]
    }

    private static func clipObject(
        _ clip: ExchangeClip,
        timeline: ExchangeTimeline,
        rate: Double
    ) throws -> [String: Any] {
        let mediaRate = (try? timeline.mediaReference(for: clip))?.frameRate
        let sourceRate = mediaRate?.nominal ?? rate
        var object: [String: Any] = [
            "OTIO_SCHEMA": "Clip.1",
            "name": clip.name,
            "source_range": timeRange(clip.sourceStart, clip.duration, rate: sourceRate),
            "media_reference": try mediaReferenceObject(clip: clip, timeline: timeline),
            "metadata": [
                "floe": [
                    "id": clip.id,
                    "enabled": clip.enabled,
                    "start_value": clip.start.value,
                    "start_timescale": clip.start.timescale
                ]
            ]
        ]
        var effectObjects: [[String: Any]] = []
        if let retime = clip.retime {
            effectObjects.append([
                "OTIO_SCHEMA": "LinearTimeWarp.1",
                "name": "FloeRetime",
                "time_scalar": retime.rate.seconds,
                "preserves_pitch": retime.preservesPitch,
                "metadata": [
                    "floe": [
                        "value": retime.rate.value,
                        "timescale": retime.rate.timescale
                    ]
                ]
            ])
        }
        for effect in clip.effects where effect.support == .reported {
            if let raw = effect.rawRepresentation,
               let rawObject = parseJSONObject(raw) {
                effectObjects.append(rawObject)
            }
        }
        if !effectObjects.isEmpty {
            object["effects"] = effectObjects
        }
        if !clip.markers.isEmpty {
            object["markers"] = clip.markers.map { markerObject($0, rate: sourceRate) }
        }
        if !clip.metadata.isEmpty {
            object["metadata"] = ["floe": [
                "id": clip.id,
                "enabled": clip.enabled,
                "start_value": clip.start.value,
                "start_timescale": clip.start.timescale,
                "user": clip.metadata
            ]]
        }
        return object
    }

    private static func mediaReferenceObject(
        clip: ExchangeClip,
        timeline: ExchangeTimeline
    ) throws -> [String: Any] {
        let reference = try timeline.mediaReference(for: clip)
        let target: String
        switch reference.source.storage {
        case .packed:
            target = reference.source.relativePath ?? ""
        case .external:
            target = reference.source.externalURL ?? ""
        }
        var metadata: [String: Any] = [
            "id": reference.id,
            "kind": reference.kind.rawValue,
            "storage": reference.source.storage.rawValue,
            "owns_media": reference.source.ownsMedia,
            "original_name": reference.name,
            "has_video": reference.hasVideo,
            "has_audio": reference.hasAudio
        ]
        if let hash = reference.contentHash { metadata["content_hash"] = hash }
        if let bytes = reference.byteCount { metadata["byte_count"] = bytes }
        if let bookmark = reference.source.securityScopedBookmark {
            metadata["security_scoped_bookmark"] = bookmark.base64EncodedString()
        }
        if let frameRate = reference.frameRate {
            metadata["frame_rate_numerator"] = frameRate.numerator
            metadata["frame_rate_denominator"] = frameRate.denominator
        }
        var object: [String: Any] = [
            "OTIO_SCHEMA": "ExternalReference.1",
            "target_url": target,
            "metadata": ["floe": metadata]
        ]
        if let duration = reference.duration {
            object["available_range"] = timeRange(.zero, duration, rate: reference.frameRate?.nominal ?? timeline.frameRate.nominal)
        }
        return object
    }

    private static func markerObject(_ marker: ExchangeMarker, rate: Double) -> [String: Any] {
        [
            "OTIO_SCHEMA": "Marker.2",
            "name": marker.name,
            "marked_range": timeRange(marker.start, marker.duration, rate: rate),
            "metadata": [
                "floe": [
                    "id": marker.id,
                    "note": marker.note ?? "",
                    "value": marker.start.value,
                    "timescale": marker.start.timescale,
                    "duration_value": marker.duration.value,
                    "duration_timescale": marker.duration.timescale
                ]
            ]
        ]
    }

    // MARK: - Parsing helpers

    private static func parseMediaReference(
        _ value: Any?,
        clipID: String,
        path: String
    ) throws -> ExchangeMediaReference {
        guard let object = value as? [String: Any] else {
            throw OTIOError.missingMediaReference(clipID)
        }
        guard string(object, "OTIO_SCHEMA") == "ExternalReference.1" else {
            throw OTIOError.unsupportedSchema(string(object, "OTIO_SCHEMA") ?? "media_reference")
        }
        let metadata = nestedDictionary(object["metadata"], key: "floe")
        let id = string(metadata, "id") ?? "media-\(clipID)"
        let kind = ExchangeMediaKind(rawValue: string(metadata, "kind") ?? "video") ?? .video
        let storage = ExchangeMediaStorage(rawValue: string(metadata, "storage") ?? "")
        let target = string(object, "target_url") ?? ""
        let source: ExchangeMediaSource
        switch storage {
        case .packed:
            source = try ExchangeMediaSource(packedRelativePath: target)
        case .external:
            source = try ExchangeMediaSource(
                externalURL: target,
                securityScopedBookmark: string(metadata, "security_scoped_bookmark").flatMap { Data(base64Encoded: $0) }
            )
        case nil:
            if target.hasPrefix("/") || target.hasPrefix("file:") {
                source = try ExchangeMediaSource(externalURL: target)
            } else {
                source = try ExchangeMediaSource(packedRelativePath: target)
            }
        }
        var frameRate: ExchangeFrameRate?
        if let numerator = uint64(metadata, "frame_rate_numerator"),
           let denominator = uint64(metadata, "frame_rate_denominator") {
            frameRate = try? ExchangeFrameRate(
                numerator: Int64(numerator),
                denominator: Int64(denominator)
            )
        }
        var duration: ExchangeTime?
        if let available = object["available_range"] as? [String: Any],
           let durationValue = available["duration"],
           let parsed = try? exactTime(durationValue, metadata: nil, fallbackRate: .fps24, field: "media available_range") {
            duration = parsed
        }
        return ExchangeMediaReference(
            id: id,
            kind: kind,
            name: string(metadata, "original_name") ?? id,
            source: source,
            duration: duration,
            hasVideo: bool(metadata, "has_video") ?? (kind == .video || kind == .image),
            hasAudio: bool(metadata, "has_audio") ?? (kind == .audio),
            frameRate: frameRate,
            contentHash: string(metadata, "content_hash"),
            byteCount: int64(metadata, "byte_count")
        )
    }

    private static func parseMarker(
        _ object: [String: Any],
        fallbackRate: ExchangeFrameRate,
        id: String,
        field: String
    ) throws -> ExchangeMarker {
        let metadata = nestedDictionary(object["metadata"], key: "floe")
        let start: ExchangeTime
        let duration: ExchangeTime
        if let exactStart = try? exactTimeFromMetadata(metadata, field: "marker start") {
            start = exactStart
        } else if let marked = object["marked_range"] as? [String: Any] {
            start = try exactTime(
                marked["start_time"],
                metadata: nil,
                fallbackRate: fallbackRate,
                field: "\(field) start"
            )
        } else {
            throw OTIOError.missingField("Marker.marked_range")
        }
        if let exactDuration = try? exactTimeFromMetadata(metadata, field: "marker duration", keyPrefix: "duration_") {
            duration = exactDuration
        } else if let marked = object["marked_range"] as? [String: Any] {
            duration = try exactTime(
                marked["duration"],
                metadata: nil,
                fallbackRate: fallbackRate,
                field: "\(field) duration"
            )
        } else {
            duration = .zero
        }
        return ExchangeMarker(
            id: string(metadata, "id") ?? id,
            name: string(object, "name") ?? "Marker",
            start: start,
            duration: duration,
            note: string(metadata, "note")
        )
    }

    private static func sourceRangeDuration(_ value: Any?, fallbackRate: ExchangeFrameRate, field: String) throws -> ExchangeTime {
        guard let range = value as? [String: Any] else { throw OTIOError.missingField(field) }
        return try exactTime(
            range["duration"],
            metadata: nil,
            fallbackRate: fallbackRate,
            field: "\(field).duration"
        )
    }

    private static func sourceRangeStart(_ value: Any?, fallbackRate: ExchangeFrameRate, field: String) throws -> ExchangeTime {
        guard let range = value as? [String: Any] else { throw OTIOError.missingField(field) }
        return try exactTime(
            range["start_time"],
            metadata: nil,
            fallbackRate: fallbackRate,
            field: "\(field).start_time"
        )
    }

    private static func exactTime(
        _ value: Any?,
        metadata: [String: Any]?,
        fallbackRate: ExchangeFrameRate,
        field: String
    ) throws -> ExchangeTime {
        guard let object = value as? [String: Any] else {
            throw OTIOError.missingField(field)
        }
        let embedded = nestedDictionary(object["metadata"], key: "floe")
        if let exact = try? exactTimeFromMetadata(metadata ?? embedded, field: field) {
            return exact
        }
        guard string(object, "OTIO_SCHEMA") == "RationalTime.1" else {
            throw OTIOError.unsupportedSchema(string(object, "OTIO_SCHEMA") ?? field)
        }
        let rate = double(object, "rate") ?? fallbackRate.nominal
        let timeValue = double(object, "value")
        guard let timeValue, rate > 0, timeValue.isFinite, rate.isFinite else {
            throw OTIOError.invalidTime(field)
        }
        let seconds = timeValue / rate
        let numerator = Int64((seconds * 1_000_000).rounded())
        return try ExchangeTime(value: max(0, numerator), timescale: 1_000_000)
    }

    private static func exactTimeFromMetadata(
        _ metadata: [String: Any]?,
        field: String,
        keyPrefix: String = ""
    ) throws -> ExchangeTime {
        guard let metadata,
              let value = int64(metadata, "\(keyPrefix)value"),
              let timescale = int64(metadata, "\(keyPrefix)timescale")
        else { throw OTIOError.missingField("\(field) metadata") }
        return try ExchangeTime(value: max(0, value), timescale: timescale)
    }

    private static func frameRate(
        from metadata: [String: Any]?,
        fallback: Double?
    ) throws -> ExchangeFrameRate {
        if let frameRate = metadata?["frame_rate"] as? [String: Any],
           let numerator = int64(frameRate, "numerator"),
           let denominator = int64(frameRate, "denominator"),
           numerator > 0, denominator > 0 {
            return try ExchangeFrameRate(numerator: numerator, denominator: denominator)
        }
        if let fallback {
            return try ExchangeFrameRate.rationalApproximation(of: fallback)
        }
        return .fps24
    }

    private static func trackKind(_ value: String?, fallback: String?) -> ExchangeTrackKind {
        switch value {
        case "audio": return .audio
        case "subtitle": return .subtitle
        case "video": return .video
        default:
            return fallback == "Audio" ? .audio : .video
        }
    }

    // MARK: - JSON helpers

    private static func string(_ dictionary: [String: Any]?, _ key: String) -> String? {
        dictionary?[key] as? String
    }

    private static func double(_ dictionary: [String: Any]?, _ key: String) -> Double? {
        if let value = dictionary?[key] as? Double { return value }
        if let value = dictionary?[key] as? Int { return Double(value) }
        if let value = dictionary?[key] as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func int64(_ dictionary: [String: Any]?, _ key: String) -> Int64? {
        if let value = dictionary?[key] as? Int64 { return value }
        if let value = dictionary?[key] as? Int { return Int64(value) }
        if let value = dictionary?[key] as? NSNumber { return value.int64Value }
        return nil
    }

    private static func uint64(_ dictionary: [String: Any]?, _ key: String) -> UInt64? {
        guard let value = int64(dictionary, key), value >= 0 else { return nil }
        return UInt64(value)
    }

    private static func bool(_ dictionary: [String: Any]?, _ key: String) -> Bool? {
        if let value = dictionary?[key] as? Bool { return value }
        if let value = dictionary?[key] as? NSNumber { return value.boolValue }
        return nil
    }

    private static func nestedDictionary(_ value: Any?, key: String) -> [String: Any]? {
        (value as? [String: Any])?[key] as? [String: Any]
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if let string = value as? String {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    private static func stringifyJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw OTIOError.invalidField("could not encode raw effect")
        }
        return string
    }

    private static func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }
}
