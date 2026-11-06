// SPDX-License-Identifier: MPL-2.0
//
// Native FCPXML 1.10 adapter for the documented Floe exchange subset.
//
// OpenFCPXMLKit 3.3.15 (pin 7f55583a3a5b4fecf336ca2ae4b77fb11f8db46d) is used
// by the independent macOS qualification target. Its public model is annotated
// `@available(macOS 26.0, *)` throughout despite the package declaring iOS 26,
// so this adapter deliberately uses Foundation XMLParser/string writing and
// remains buildable for the iPad target. See the handoff/README for the
// preserved platform evidence.
//
// The adapter supports: resources (format/asset/media-rep), library/event/
// project/sequence/spine, asset-clip, gap, caption/text, marker and a
// per-clip lane mapping. Effects, transforms, transitions, titles, compound
// clips and other unsupported elements are retained in the import report (or
// make export throw); they are never silently dropped.

import Foundation
import MediaExchangeCore

public enum FCPXMLAdapterError: Error, Equatable, CustomStringConvertible {
    case malformedXML(String)
    case unsafeXML(String)
    case unsupportedVersion(String)
    case missingElement(String)
    case missingAttribute(element: String, attribute: String)
    case invalidAttribute(element: String, attribute: String, value: String)
    case missingResource(String)
    case missingMediaReference(String)
    case invalidRationalTime(String)
    case overlappingLane(Int)
    case unsupportedFeature(String)
    case unsupportedEffect(String)
    case emptySpine

    public var description: String {
        switch self {
        case let .malformedXML(reason): return "malformed FCPXML: \(reason)"
        case let .unsafeXML(reason): return "unsafe FCPXML: \(reason)"
        case let .unsupportedVersion(version): return "unsupported FCPXML version \(version)"
        case let .missingElement(name): return "FCPXML is missing <\(name)>"
        case let .missingAttribute(element, attribute): return "FCPXML <\(element)> is missing \(attribute)"
        case let .invalidAttribute(element, attribute, value):
            return "FCPXML <\(element)> has invalid \(attribute)=\(value)"
        case let .missingResource(id): return "FCPXML resource \(id) is missing"
        case let .missingMediaReference(id): return "FCPXML asset \(id) has no media-rep"
        case let .invalidRationalTime(value): return "invalid FCPXML rational time \(value)"
        case let .overlappingLane(lane): return "FCPXML lane \(lane) has overlapping clips"
        case let .unsupportedFeature(feature): return "FCPXML adapter does not support \(feature)"
        case let .unsupportedEffect(name): return "FCPXML effect \(name) cannot be exported without loss"
        case .emptySpine: return "FCPXML spine has no supported items"
        }
    }
}

public struct FCPXMLImportResult: Sendable {
    public var timeline: ExchangeTimeline
    public var report: ExchangeImportReport
    public var rawXML: String

    public init(timeline: ExchangeTimeline, report: ExchangeImportReport, rawXML: String) {
        self.timeline = timeline
        self.report = report
        self.rawXML = rawXML
    }
}

public enum FCPXMLAdapter {
    // MARK: - Export

    public static func export(_ timeline: ExchangeTimeline) throws -> String {
        try timeline.validate()
        if timeline.tracks.contains(where: { $0.kind == .subtitle }) {
            throw FCPXMLAdapterError.unsupportedFeature(
                "subtitle tracks; captions must be attached to a video clip in this subset"
            )
        }
        for clip in timeline.allClips {
            if let retime = clip.retime, retime.rate.seconds != 1 {
                throw FCPXMLAdapterError.unsupportedFeature("clip retime on \(clip.id)")
            }
            for effect in clip.effects {
                throw FCPXMLAdapterError.unsupportedEffect(effect.name)
            }
        }

        let dimensions = timelineDimensions(timeline)
        var formats: [(id: String, rate: ExchangeFrameRate)] = [("r1", timeline.frameRate)]
        for reference in timeline.media {
            guard let rate = reference.frameRate else { continue }
            if formats.contains(where: { $0.rate == rate }) { continue }
            formats.append(("r\(formats.count + 1)", rate))
        }
        func formatID(for rate: ExchangeFrameRate?) -> String? {
            guard let rate else { return nil }
            return formats.first(where: { $0.rate == rate })?.id
        }

        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="no"?>"# + "\n"
        xml += #"<fcpxml version="1.10">"# + "\n"
        xml += "<resources>\n"
        for format in formats {
            let frameDuration = try ExchangeTime(
                value: format.rate.denominator,
                timescale: format.rate.numerator
            ).fcpxmlString
            xml += #"  <format id="\#(escape(format.id))" name="\#(escape(formatName(dimensions: dimensions, rate: format.rate)))" frameDuration="\#(escape(frameDuration))" width="\#(dimensions.width)" height="\#(dimensions.height)"/>"# + "\n"
        }
        for (index, reference) in timeline.media.enumerated() {
            let assetID = "a\(index + 1)"
            let source = sourceString(reference.source)
            xml += #"  <asset id="\#(escape(assetID))" name="\#(escape(reference.name))""#
            if let duration = reference.duration {
                xml += #" duration="\#(escape(duration.fcpxmlString))""#
            }
            if let format = formatID(for: reference.frameRate) {
                xml += #" format="\#(escape(format))""#
            }
            xml += #" hasVideo="\#(reference.hasVideo ? "1" : "0")" hasAudio="\#(reference.hasAudio ? "1" : "0")">"# + "\n"
            xml += #"    <media-rep kind="original-media" src="\#(escape(source))"/>"# + "\n"
            var metadata: [String: String] = ["floe.media_id": reference.id]
            if let hash = reference.contentHash { metadata["floe.content_hash"] = hash }
            if let bytes = reference.byteCount { metadata["floe.byte_count"] = String(bytes) }
            if !metadata.isEmpty {
                xml += "    <metadata>\n"
                for key in metadata.keys.sorted() {
                    xml += #"      <md key="\#(escape(key))" value="\#(escape(metadata[key] ?? ""))"/>"# + "\n"
                }
                xml += "    </metadata>\n"
            }
            xml += "  </asset>\n"
        }
        xml += "</resources>\n"

        let laneTracks = assignedLanes(timeline)
        var sequenceMetadata: [(String, String)] = [
            ("floe.project_id", timeline.id),
            ("floe.source_revision", String(timeline.sourceRevision)),
            ("floe.frame_rate", "\(timeline.frameRate.numerator)/\(timeline.frameRate.denominator)")
        ]
        if !timeline.markers.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(timeline.markers),
               let string = String(data: data, encoding: .utf8) {
                sequenceMetadata.append(("floe.timeline_markers", string))
            }
        }
        xml += "<library>\n"
        xml += #"  <event name="\#(escape(timeline.name))">"# + "\n"
        xml += #"    <project name="\#(escape(timeline.name))">"# + "\n"
        xml += #"      <sequence format="r1" duration="\#(escape(timeline.duration.fcpxmlString))" tcStart="\#(escape(timeline.globalStart.fcpxmlString))" tcFormat="NDF" audioLayout="stereo" audioRate="48k">"# + "\n"
        xml += "        <spine>\n"

        // Primary storyline first. Connected lanes are anchored to it.
        if let primary = laneTracks.first(where: { $0.lane == 0 }) {
            for item in primary.track.items.sorted(by: { $0.start < $1.start }) {
                switch item {
                case let .gap(gap):
                    xml += #"          <gap offset="\#(escape(gap.start.fcpxmlString))" duration="\#(escape(gap.duration.fcpxmlString))">"# + "\n"
                    xml += #"            <metadata><md key="floe.gap_id" value="\#(escape(gap.id))"/></metadata>"# + "\n"
                    xml += "          </gap>\n"
                case let .clip(clip):
                    xml += try clipXML(
                        clip,
                        lane: 0,
                        mediaIndex: mediaIndex(for: clip, timeline: timeline),
                        timeline: timeline,
                        indent: "          "
                    )
                }
            }
        }
        for assignment in laneTracks where assignment.lane != 0 {
            for item in assignment.track.items.sorted(by: { $0.start < $1.start }) {
                guard case let .clip(clip) = item else { continue }
                xml += try clipXML(
                    clip,
                    lane: assignment.lane,
                    mediaIndex: mediaIndex(for: clip, timeline: timeline),
                    timeline: timeline,
                    indent: "          "
                )
            }
        }
        xml += "        </spine>\n"
        xml += "        <metadata>\n"
        for (key, value) in sequenceMetadata {
            xml += #"          <md key="\#(escape(key))" value="\#(escape(value))"/>"# + "\n"
        }
        xml += "        </metadata>\n"
        xml += "      </sequence>\n"
        xml += "    </project>\n"
        xml += "  </event>\n"
        xml += "</library>\n"
        xml += "</fcpxml>\n"
        return xml
    }

    // MARK: - Import

    public static func importTimeline(
        _ xml: String,
        packageRoot: URL? = nil
    ) throws -> FCPXMLImportResult {
        let upper = xml.uppercased()
        guard !upper.contains("<!ENTITY") else {
            throw FCPXMLAdapterError.unsafeXML("ENTITY declarations are not accepted")
        }
        if let doctypeStart = upper.range(of: "<!DOCTYPE") {
            // FCPXML files commonly carry a bare `<!DOCTYPE fcpxml>`.
            // Permit only that literal declaration: no SYSTEM/PUBLIC external
            // id, no internal subset and no second DOCTYPE.
            let tail = upper[doctypeStart.lowerBound...]
            guard let end = tail.firstIndex(of: ">") else {
                throw FCPXMLAdapterError.unsafeXML("unterminated DOCTYPE")
            }
            let declaration = tail[..<end]
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard declaration == "<!DOCTYPE FCPXML" else {
                throw FCPXMLAdapterError.unsafeXML("only a bare <!DOCTYPE fcpxml> is accepted")
            }
            let after = upper[tail.index(after: end)...]
            guard !after.contains("<!DOCTYPE") else {
                throw FCPXMLAdapterError.unsafeXML("multiple DOCTYPE declarations are not accepted")
            }
        }
        let root = try parseXML(Data(xml.utf8))
        guard root.name == "fcpxml" else {
            throw FCPXMLAdapterError.missingElement("fcpxml")
        }
        let version = attribute(root, "version") ?? ""
        guard version.hasPrefix("1.") else {
            throw FCPXMLAdapterError.unsupportedVersion(version)
        }

        let resources = firstChild(root, named: "resources")
        var formats: [String: ExchangeFrameRate] = [:]
        var formatSizes: [String: (Int, Int)] = [:]
        var assets: [String: FCPXMLAsset] = [:]
        if let resources {
            for element in resources.children where element.name == "format" {
                guard let id = attribute(element, "id") else { continue }
                if let frameDuration = attribute(element, "frameDuration"),
                   let rate = try? frameRate(fromFrameDuration: frameDuration) {
                    formats[id] = rate
                }
                if let width = Int(attribute(element, "width") ?? ""),
                   let height = Int(attribute(element, "height") ?? "") {
                    formatSizes[id] = (width, height)
                }
            }
            for element in resources.children where element.name == "asset" {
                guard let id = attribute(element, "id") else { continue }
                let mediaRep = firstChild(element, named: "media-rep")
                guard let source = mediaRep.flatMap({ attribute($0, "src") }) else {
                    throw FCPXMLAdapterError.missingMediaReference(id)
                }
                let formatRef = attribute(element, "format")
                let rate = formatRef.flatMap { formats[$0] }
                let metadata = metadataDictionary(element)
                let kind: ExchangeMediaKind
                let hasVideo = booleanAttribute(element, "hasVideo", default: true)
                let hasAudio = booleanAttribute(element, "hasAudio", default: true)
                if hasVideo && !hasAudio {
                    kind = .video
                } else if hasAudio && !hasVideo {
                    kind = .audio
                } else {
                    kind = .video
                }
                let mediaSource = try sourceValue(source)
                let duration = try attribute(element, "duration").map(exactTime(from:))
                var reference = ExchangeMediaReference(
                    id: metadata["floe.media_id"] ?? id,
                    kind: kind,
                    name: attribute(element, "name") ?? id,
                    source: mediaSource,
                    duration: duration,
                    hasVideo: hasVideo,
                    hasAudio: hasAudio,
                    frameRate: rate,
                    contentHash: metadata["floe.content_hash"],
                    byteCount: metadata["floe.byte_count"].flatMap(Int64.init)
                )
                if let width = formatSizes[formatRef ?? ""]?.0,
                   let height = formatSizes[formatRef ?? ""]?.1 {
                    reference.metadata["width"] = String(width)
                    reference.metadata["height"] = String(height)
                }
                assets[id] = FCPXMLAsset(id: id, reference: reference)
            }
        }

        let project = firstDescendant(root, named: "project")
        let sequence = project.flatMap { firstChild($0, named: "sequence") }
            ?? firstDescendant(root, named: "sequence")
        guard let sequence else { throw FCPXMLAdapterError.missingElement("sequence") }
        let sequenceRate: ExchangeFrameRate
        if let formatRef = attribute(sequence, "format"), let rate = formats[formatRef] {
            sequenceRate = rate
        } else if let first = assets.values.first?.reference.frameRate {
            sequenceRate = first
        } else {
            sequenceRate = .fps24
        }
        let globalStart = try attribute(sequence, "tcStart").map(exactTime(from:)) ?? .zero
        let sequenceMetadata = metadataDictionary(sequence)
        let sourceRevision = sequenceMetadata["floe.source_revision"].flatMap(UInt64.init) ?? 1
        let timelineID = sequenceMetadata["floe.project_id"]
            ?? project.flatMap { attribute($0, "uid") }
            ?? "fcpxml-timeline"
        let timelineName = project.flatMap { attribute($0, "name") }
            ?? attribute(sequence, "name")
            ?? "FCPXML timeline"

        guard let spine = firstChild(sequence, named: "spine") else {
            throw FCPXMLAdapterError.missingElement("spine")
        }

        var timelineMarkers: [ExchangeMarker] = []
        if let markerJSON = sequenceMetadata["floe.timeline_markers"],
           let markerData = markerJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ExchangeMarker].self, from: markerData) {
            timelineMarkers = decoded
        }
        for markerElement in sequence.children where markerElement.name == "marker" {
            timelineMarkers.append(try parseMarker(
                markerElement,
                id: "timeline-marker-\(timelineMarkers.count)"
            ))
        }

        var unsupportedItems: [ExchangeUnsupportedItem] = []
        var laneClips: [Int: [(offset: ExchangeTime, clip: ExchangeClip)]] = [:]
        var laneGaps: [Int: [(offset: ExchangeTime, gap: ExchangeGap)]] = [:]
        var clipCounter = 0
        for child in spine.children {
            switch child.name {
            case "asset-clip":
                let ref = attribute(child, "ref") ?? ""
                guard let asset = assets[ref] else {
                    throw FCPXMLAdapterError.missingResource(ref)
                }
                let lane = Int(attribute(child, "lane") ?? "0") ?? 0
                let offset = try attribute(child, "offset").map(exactTime(from:)) ?? .zero
                let duration = try requiredTime(child, "duration")
                let start = try attribute(child, "start").map(exactTime(from:)) ?? .zero
                let metadata = metadataDictionary(child)
                let clipID = metadata["floe.clip_id"] ?? attribute(child, "id") ?? "clip-\(clipCounter)"
                clipCounter += 1
                var markers: [ExchangeMarker] = []
                var captions: [ExchangeCaption] = []
                var effects: [ExchangeEffect] = []
                for grandchild in child.children {
                    switch grandchild.name {
                    case "caption":
                        let captionID = attribute(grandchild, "id") ?? "caption-\(clipID)-\(captions.count)"
                        let text = firstDescendant(grandchild, named: "text").map(collectText) ?? ""
                        let role = attribute(grandchild, "role")
                        let language = role?.split(separator: ".").last.map(String.init) ?? "und"
                        let captionStart = try attribute(grandchild, "offset").map(exactTime(from:)) ?? .zero
                        let captionDuration = try attribute(grandchild, "duration").map(exactTime(from:)) ?? duration
                        if firstDescendant(grandchild, named: "text-style") != nil {
                            unsupportedItems.append(ExchangeUnsupportedItem(
                                path: "caption/\(captionID)",
                                name: "text-style",
                                reason: "caption styling is not represented by ExchangeCaption",
                                rawRepresentation: serialize(grandchild)
                            ))
                        }
                        captions.append(ExchangeCaption(
                            id: captionID,
                            text: text,
                            language: language,
                            role: role,
                            start: captionStart,
                            duration: captionDuration
                        ))
                    case "marker":
                        markers.append(try parseMarker(grandchild, id: "marker-\(clipID)-\(markers.count)"))
                    case "metadata", "note":
                        continue
                    default:
                        let raw = serialize(grandchild)
                        effects.append(ExchangeEffect(
                            name: grandchild.name,
                            kind: "fcpxml",
                            parameters: grandchild.attributes,
                            support: .reported,
                            rawRepresentation: raw
                        ))
                        unsupportedItems.append(ExchangeUnsupportedItem(
                            path: "asset-clip/\(clipID)/\(grandchild.name)",
                            name: grandchild.name,
                            reason: "element is outside the documented FCPXML subset",
                            rawRepresentation: raw
                        ))
                    }
                }
                let clip = ExchangeClip(
                    id: clipID,
                    name: attribute(child, "name") ?? asset.reference.name,
                    mediaID: asset.reference.id,
                    start: offset,
                    duration: duration,
                    sourceStart: start,
                    enabled: booleanAttribute(child, "enabled", default: true),
                    effects: effects,
                    markers: markers,
                    captions: captions,
                    metadata: metadata.filter { $0.key.hasPrefix("floe.") }
                )
                laneClips[lane, default: []].append((offset, clip))
            case "gap":
                let lane = Int(attribute(child, "lane") ?? "0") ?? 0
                let offset = try attribute(child, "offset").map(exactTime(from:)) ?? .zero
                let duration = try requiredTime(child, "duration")
                if lane == 0 {
                    let gapMetadata = metadataDictionary(child)
                    laneGaps[lane, default: []].append((
                        offset,
                        ExchangeGap(
                            id: gapMetadata["floe.gap_id"] ?? "gap-\(laneGaps[lane]?.count ?? 0)-\(offset.value)",
                            start: offset,
                            duration: duration
                        )
                    ))
                } else {
                    unsupportedItems.append(ExchangeUnsupportedItem(
                        path: "spine/gap",
                        name: "gap",
                        reason: "connected-lane gaps are not represented",
                        rawRepresentation: serialize(child)
                    ))
                }
            case "marker":
                unsupportedItems.append(ExchangeUnsupportedItem(
                    path: "sequence/marker",
                    name: "marker",
                    reason: "sequence-level markers are not part of the imported subset",
                    rawRepresentation: serialize(child)
                ))
            default:
                unsupportedItems.append(ExchangeUnsupportedItem(
                    path: "spine/\(child.name)",
                    name: child.name,
                    reason: "element is outside the documented FCPXML subset",
                    rawRepresentation: serialize(child)
                ))
            }
        }

        var tracks: [ExchangeTrack] = []
        let lanes = Set(laneClips.keys).union(laneGaps.keys).sorted()
        if lanes.isEmpty {
            throw FCPXMLAdapterError.emptySpine
        }
        for lane in lanes {
            let clips = (laneClips[lane] ?? []).sorted { $0.offset < $1.offset }
            var items: [ExchangeTimelineItem] = []
            for (index, entry) in clips.enumerated() {
                if index > 0 {
                    let previous = items[items.count - 1]
                    if entry.offset < previous.end {
                        throw FCPXMLAdapterError.overlappingLane(lane)
                    }
                }
                items.append(.clip(entry.clip))
            }
            if lane == 0 {
                let gaps = (laneGaps[0] ?? []).sorted { $0.offset < $1.offset }
                items.append(contentsOf: gaps.map { .gap($0.gap) })
                items.sort { $0.start < $1.start }
            }
            let kind: ExchangeTrackKind = lane < 0 ? .audio : .video
            let id = lane == 0 ? "v0" : (lane > 0 ? "v\(lane)" : "a\(abs(lane))")
            tracks.append(ExchangeTrack(
                id: id,
                kind: kind,
                name: id,
                items: items
            ))
        }

        var usedMedia = Set<String>()
        for track in tracks {
            for item in track.items {
                if case let .clip(clip) = item { usedMedia.insert(clip.mediaID) }
            }
        }
        let references = assets.values
            .filter { usedMedia.contains($0.reference.id) }
            .map(\.reference)
            .sorted { $0.id < $1.id }

        var missingMedia: [String] = []
        if let packageRoot {
            for reference in references {
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
            name: timelineName,
            frameRate: sequenceRate,
            globalStart: globalStart,
            tracks: tracks,
            media: references,
            markers: timelineMarkers,
            sourceRevision: sourceRevision,
            metadata: [
                "fcpxml.width": String(formatDimensions(for: sequence, formats: formats, dimensions: formatSizes).0),
                "fcpxml.height": String(formatDimensions(for: sequence, formats: formats, dimensions: formatSizes).1)
            ]
        )
        do {
            try timeline.validate()
        } catch {
            throw FCPXMLAdapterError.malformedXML("timeline validation failed: \(error)")
        }
        return FCPXMLImportResult(
            timeline: timeline,
            report: ExchangeImportReport(
                unsupported: unsupportedItems,
                missingMedia: missingMedia,
                warnings: [],
                captionsImported: timeline.allClips.reduce(0) { $0 + $1.captions.count },
                effectsReported: unsupportedItems.filter { $0.path.contains("asset-clip") }.count
            ),
            rawXML: xml
        )
    }

    // MARK: - XML writing helpers

    private static func clipXML(
        _ clip: ExchangeClip,
        lane: Int,
        mediaIndex: Int?,
        timeline: ExchangeTimeline,
        indent: String
    ) throws -> String {
        guard let mediaIndex else {
            throw FCPXMLAdapterError.missingMediaReference(clip.mediaID)
        }
        let assetID = "a\(mediaIndex + 1)"
        var xml = #"\#(indent)<asset-clip ref="\#(escape(assetID))" name="\#(escape(clip.name))" offset="\#(escape(clip.start.fcpxmlString))" duration="\#(escape(clip.duration.fcpxmlString))""#
        if clip.sourceStart != .zero {
            xml += #" start="\#(escape(clip.sourceStart.fcpxmlString))""#
        }
        if lane != 0 {
            xml += #" lane="\#(lane)""#
        }
        if !clip.enabled {
            xml += #" enabled="0""#
        }
        xml += ">\n"
        for marker in clip.markers {
            xml += #"\#(indent)  <marker start="\#(escape(marker.start.fcpxmlString))" duration="\#(escape(marker.duration.fcpxmlString))" value="\#(escape(marker.name))""#
            if let note = marker.note {
                xml += #" note="\#(escape(note))""#
            }
            xml += "/>\n"
        }
        for caption in clip.captions {
            let role = caption.role ?? "iTT?captionFormat=ITT.\(caption.language)"
            xml += #"\#(indent)  <caption role="\#(escape(role))" offset="\#(escape(caption.start.fcpxmlString))" duration="\#(escape(caption.duration.fcpxmlString))">"# + "\n"
            xml += #"\#(indent)    <text>\#(escape(caption.text))</text>"# + "\n"
            xml += #"\#(indent)  </caption>"# + "\n"
        }
        xml += #"\#(indent)  <metadata><md key="floe.clip_id" value="\#(escape(clip.id))"/></metadata>"# + "\n"
        xml += #"\#(indent)</asset-clip>"# + "\n"
        return xml
    }

    private static func assignedLanes(_ timeline: ExchangeTimeline) -> [(track: ExchangeTrack, lane: Int)] {
        var result: [(ExchangeTrack, Int)] = []
        var videoIndex = 0
        var audioIndex = 0
        for track in timeline.tracks {
            switch track.kind {
            case .video:
                result.append((track, videoIndex))
                videoIndex += 1
            case .audio:
                audioIndex += 1
                result.append((track, -audioIndex))
            case .subtitle:
                continue
            }
        }
        return result
    }

    private static func mediaIndex(for clip: ExchangeClip, timeline: ExchangeTimeline) -> Int? {
        timeline.media.firstIndex { $0.id == clip.mediaID }
    }

    private static func timelineDimensions(_ timeline: ExchangeTimeline) -> (width: Int, height: Int) {
        let width = timeline.metadata["width"].flatMap(Int.init) ?? 1920
        let height = timeline.metadata["height"].flatMap(Int.init) ?? 1080
        return (max(1, width), max(1, height))
    }

    private static func formatName(dimensions: (width: Int, height: Int), rate: ExchangeFrameRate) -> String {
        let rateName: String
        switch rate {
        case .fps24: rateName = "24"
        case .fps25: rateName = "25"
        case .fps30: rateName = "30"
        case .fps60: rateName = "60"
        case .ntsc24: rateName = "2398"
        case .ntsc30: rateName = "2997"
        case .ntsc60: rateName = "5994"
        default: rateName = "\(rate.numerator)-\(rate.denominator)"
        }
        let scan: String
        if dimensions.height >= 2160 { scan = "2160p" }
        else if dimensions.height >= 1080 { scan = "1080p" }
        else if dimensions.height >= 720 { scan = "720p" }
        else { scan = "\(dimensions.height)p" }
        return "FFVideoFormat\(scan)\(rateName)"
    }

    private static func sourceString(_ source: ExchangeMediaSource) -> String {
        switch source.storage {
        case .packed: return source.relativePath ?? ""
        case .external: return source.externalURL ?? ""
        }
    }

    private static func sourceValue(_ value: String) throws -> ExchangeMediaSource {
        if value.hasPrefix("file:") {
            return try ExchangeMediaSource(externalURL: value)
        }
        return try ExchangeMediaSource(packedRelativePath: value)
    }

    private static func formatDimensions(
        for sequence: RawElement,
        formats: [String: ExchangeFrameRate],
        dimensions: [String: (Int, Int)]
    ) -> (Int, Int) {
        if let formatRef = attribute(sequence, "format"), let size = dimensions[formatRef] {
            return size
        }
        return (1920, 1080)
    }

    private static func frameRate(fromFrameDuration value: String) throws -> ExchangeFrameRate {
        var text = value
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = Int64(parts[0]),
              let denominator = Int64(parts[1]),
              numerator > 0, denominator > 0
        else {
            throw FCPXMLAdapterError.invalidRationalTime(value)
        }
        // frameDuration = numerator/denominator seconds; rate = denominator/numerator.
        return try ExchangeFrameRate(numerator: denominator, denominator: numerator)
    }

    private static func exactTime(from value: String) throws -> ExchangeTime {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let seconds = Int64(parts[0]), seconds >= 0 else {
                throw FCPXMLAdapterError.invalidRationalTime(value)
            }
            return try ExchangeTime(value: seconds, timescale: 1)
        case 2:
            guard let numerator = Int64(parts[0]), let denominator = Int64(parts[1]),
                  numerator >= 0, denominator > 0 else {
                throw FCPXMLAdapterError.invalidRationalTime(value)
            }
            return try ExchangeTime(value: numerator, timescale: denominator)
        default:
            throw FCPXMLAdapterError.invalidRationalTime(value)
        }
    }

    private static func requiredTime(_ element: RawElement, _ name: String) throws -> ExchangeTime {
        guard let value = attribute(element, name) else {
            throw FCPXMLAdapterError.missingAttribute(element: element.name, attribute: name)
        }
        return try exactTime(from: value)
    }

    private static func parseMarker(_ element: RawElement, id: String) throws -> ExchangeMarker {
        guard let startValue = attribute(element, "start") else {
            throw FCPXMLAdapterError.missingAttribute(element: "marker", attribute: "start")
        }
        let start = try exactTime(from: startValue)
        let duration = try attribute(element, "duration").map(exactTime(from:)) ?? .zero
        return ExchangeMarker(
            id: attribute(element, "id") ?? id,
            name: attribute(element, "value") ?? "Marker",
            start: start,
            duration: duration,
            note: attribute(element, "note")
        )
    }

    private static func metadataDictionary(_ element: RawElement) -> [String: String] {
        var result: [String: String] = [:]
        if let metadata = firstChild(element, named: "metadata") {
            for md in metadata.children where md.name == "md" {
                if let key = attribute(md, "key"), let value = attribute(md, "value") {
                    result[key] = value
                }
            }
        }
        return result
    }

    private static func booleanAttribute(_ element: RawElement, _ name: String, default value: Bool) -> Bool {
        guard let raw = attribute(element, name) else { return value }
        return raw == "1" || raw.lowercased() == "true"
    }

    // MARK: - Raw XML tree

    fileprivate struct RawElement {
        var name: String
        var attributes: [String: String]
        var children: [RawElement]
        var text: String
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: RawElement?
        var stack: [RawElement] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let element = RawElement(name: elementName, attributes: attributeDict, children: [], text: "")
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard var last = stack.popLast() else { return }
            last.text += string
            stack.append(last)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard let element = stack.popLast() else { return }
            if var parent = stack.popLast() {
                parent.children.append(element)
                stack.append(parent)
            } else {
                root = element
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            // XMLParser reports the error; parse() returns false and the caller
            // maps it to malformedXML.
        }
    }

    private static func parseXML(_ data: Data) throws -> RawElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw FCPXMLAdapterError.malformedXML("XMLParser rejected the document")
        }
        return root
    }

    private static func attribute(_ element: RawElement, _ name: String) -> String? {
        element.attributes[name]
    }

    private static func firstChild(_ element: RawElement, named name: String) -> RawElement? {
        element.children.first { $0.name == name }
    }

    private static func firstDescendant(_ element: RawElement, named name: String) -> RawElement? {
        for child in element.children {
            if child.name == name { return child }
            if let found = firstDescendant(child, named: name) { return found }
        }
        return nil
    }

    private static func collectText(_ element: RawElement) -> String {
        var text = element.text
        for child in element.children {
            text += collectText(child)
        }
        return text
    }

    private static func serialize(_ element: RawElement) -> String {
        var xml = "<\(element.name)"
        for key in element.attributes.keys.sorted() {
            xml += #" \#(key)="\#(escape(element.attributes[key] ?? ""))""#
        }
        if element.children.isEmpty && element.text.isEmpty {
            xml += "/>"
            return xml
        }
        xml += ">"
        xml += escape(element.text)
        for child in element.children {
            xml += serialize(child)
        }
        xml += "</\(element.name)>"
        return xml
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    private struct FCPXMLAsset {
        let id: String
        var reference: ExchangeMediaReference
    }
}
