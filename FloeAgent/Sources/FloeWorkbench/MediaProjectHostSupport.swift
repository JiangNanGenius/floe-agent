// FloeWorkbench — Tool support: pending proposal drafts, command JSON coding
// and deterministic project summaries.

import Foundation
import FloeCore

public actor MediaProposalDraftStore {
    private var proposals: [UUID: MediaProposal] = [:]

    public init() {}

    public func put(_ proposal: MediaProposal) {
        proposals[proposal.id] = proposal
    }

    public func get(id: UUID) -> MediaProposal? { proposals[id] }

    public func remove(id: UUID) { proposals.removeValue(forKey: id) }

    public func count() -> Int { proposals.count }

    /// Pending drafts (UI lists them for the project; agent tool reads by id).
    public func values() -> [MediaProposal] { Array(proposals.values) }
}

/// Decodes model-supplied JSON objects into validated `MediaEditCommand`s.
/// Unknown command names throw (they are never silently ignored).
public enum MediaProjectCommandCoding {
    public static func commands(from values: [[String: AnyCodableValue]]) throws -> [MediaEditCommand] {
        try values.map { try command($0) }
    }

    public static func command(_ value: [String: AnyCodableValue]) throws -> MediaEditCommand {
        guard case .string(let name) = value["type"] ?? value["command"] else {
            throw FloeError.validationFailed("each command requires a string 'type'")
        }
        switch name {
        // Assets
        case "add_asset":
            return .addAsset(try asset(value))
        case "relink_asset":
            return .relinkAsset(assetID: try uuid(value, "asset_id"),
                                relativePath: try requiredString(value, "relative_path"))
        case "set_canvas":
            return .setCanvas(width: try int(value, "width"), height: try int(value, "height"),
                              frameRate: double(value, "frame_rate"))

        // Image layers
        case "add_image_layer":
            return .addImageLayer(try layer(value))
        case "update_layer":
            return .updateLayer(
                id: try uuid(value, "id"),
                transform: optionalTransform(value["transform"]),
                opacity: double(value, "opacity"),
                isHidden: bool(value, "is_hidden"),
                isLocked: bool(value, "is_locked"),
                adjustment: value["adjustment"].flatMap { try? adjustment($0) },
                text: value["text"].flatMap { try? textContent($0) },
                crop: cropUpdate(value["crop"]))
        case "reorder_layers":
            return .reorderLayers(orderedIDs: try uuidArray(value, "ordered_ids"))
        case "move_layer":
            return .moveLayer(id: try uuid(value, "id"), toIndex: try int(value, "to_index"))
        case "remove_layer":
            return .removeLayer(id: try uuid(value, "id"))
        case "set_canvas_adjustment":
            return .setCanvasAdjustment(try adjustment(.object(value)))

        // Video clips
        case "append_clip":
            return .appendClip(try clip(value))
        case "update_clip":
            return .updateClip(
                id: try uuid(value, "id"),
                trimStart: double(value, "trim_start"),
                trimEnd: double(value, "trim_end"),
                speed: double(value, "speed"),
                volume: double(value, "volume"),
                isMuted: bool(value, "is_muted"),
                rotationDegrees: double(value, "rotation_degrees"),
                crop: cropUpdate(value["crop"]),
                leadingTransition: (optionalString(value, "leading_transition")).flatMap(VideoTransitionKind.init(rawValue:)),
                transitionDuration: double(value, "transition_duration"))
        case "reorder_clips":
            return .reorderClips(orderedIDs: try uuidArray(value, "ordered_ids"))
        case "split_clip":
            return .splitClip(id: try uuid(value, "id"),
                              atTimelineSeconds: try requireDouble(value, "at_seconds"))
        case "remove_clip":
            return .removeClip(id: try uuid(value, "id"))
        case "set_primary_audio":
            return .setPrimaryAudio(volume: double(value, "volume"), muted: bool(value, "muted"))

        // Music / captions
        case "add_music":
            return .addMusic(try music(value))
        case "update_music":
            return .updateMusic(id: try uuid(value, "id"),
                                offsetSeconds: double(value, "offset_seconds"),
                                trimStart: double(value, "trim_start"),
                                lengthSeconds: double(value, "length_seconds"),
                                volume: double(value, "volume"),
                                fadeInSeconds: double(value, "fade_in_seconds"),
                                fadeOutSeconds: double(value, "fade_out_seconds"))
        case "remove_music":
            return .removeMusic(id: try uuid(value, "id"))
        case "add_caption":
            return .addCaption(try caption(value))
        case "update_caption":
            return .updateCaption(id: try uuid(value, "id"),
                                  start: double(value, "start"),
                                  end: double(value, "end"),
                                  text: try requiredString(value, "text"))
        case "remove_caption":
            return .removeCaption(id: try uuid(value, "id"))
        case "set_caption_style":
            return .setCaptionStyle(try captionStyle(value))

        default:
            throw FloeError.validationFailed("unknown media.project command '\(name)'")
        }
    }

    // MARK: Decoders

    private static func asset(_ value: [String: AnyCodableValue]) throws -> MediaAssetReference {
        let kindRaw = try requiredString(value, "kind")
        guard let kind = MediaAssetKind(rawValue: kindRaw) else {
            throw FloeError.validationFailed("asset kind must be image/video/audio")
        }
        let relativePath = try requiredString(value, "relative_path")
        return MediaAssetReference(kind: kind,
                                   relativePath: relativePath,
                                   originalName: optionalString(value, "original_name")
                                       ?? (relativePath as NSString).lastPathComponent)
    }

    private static func layer(_ value: [String: AnyCodableValue]) throws -> ImageLayer {
        let kindRaw = try requiredString(value, "kind")
        guard let kind = ImageLayerKind(rawValue: kindRaw) else {
            throw FloeError.validationFailed("layer kind must be image/text/freehand")
        }
        return ImageLayer(
            kind: kind,
            name: optionalString(value, "name") ?? kindRaw,
            assetID: value["asset_id"].flatMap { uuidValue($0) },
            transform: optionalTransform(value["transform"]) ?? .init(),
            opacity: double(value, "opacity") ?? 1,
            isHidden: bool(value, "is_hidden") ?? false,
            isLocked: bool(value, "is_locked") ?? false,
            text: value["text"].flatMap { try? textContent($0) },
            freehand: value["freehand"].flatMap { try? freehand($0) },
            crop: try rect(value["crop"]),
            adjustment: value["adjustment"].flatMap { try? adjustment($0) } ?? .init())
    }

    private static func clip(_ value: [String: AnyCodableValue]) throws -> VideoClip {
        VideoClip(
            assetID: try uuid(value, "asset_id"),
            trimStart: try requireDouble(value, "trim_start"),
            trimEnd: try requireDouble(value, "trim_end"),
            speed: double(value, "speed") ?? 1,
            volume: double(value, "volume") ?? 1,
            isMuted: bool(value, "is_muted") ?? false,
            rotationDegrees: double(value, "rotation_degrees") ?? 0,
            crop: value["crop"].flatMap { try? rect($0) },
            leadingTransition: (optionalString(value, "leading_transition")).flatMap(VideoTransitionKind.init(rawValue:)) ?? .none,
            transitionDuration: double(value, "transition_duration") ?? 0.4)
    }

    private static func music(_ value: [String: AnyCodableValue]) throws -> MusicClip {
        MusicClip(assetID: try uuid(value, "asset_id"),
                  offsetSeconds: try requireDouble(value, "offset_seconds"),
                  trimStart: double(value, "trim_start") ?? 0,
                  lengthSeconds: try requireDouble(value, "length_seconds"),
                  volume: double(value, "volume") ?? 1,
                  fadeInSeconds: double(value, "fade_in_seconds") ?? 0,
                  fadeOutSeconds: double(value, "fade_out_seconds") ?? 0)
    }

    private static func caption(_ value: [String: AnyCodableValue]) throws -> CaptionSegment {
        CaptionSegment(start: try requireDouble(value, "start"),
                       end: try requireDouble(value, "end"),
                       text: try requiredString(value, "text"),
                       source: (optionalString(value, "source")).flatMap {
            CaptionSegment.CaptionSource(rawValue: $0)
        } ?? .manual)
    }

    private static func captionStyle(_ value: [String: AnyCodableValue]) throws -> CaptionStyle {
        CaptionStyle(fontSize: double(value, "font_size") ?? 36,
                     colorHex: optionalString(value, "color_hex") ?? "#FFFFFF",
                     backgroundHex: optionalString(value, "background_hex") ?? "#000000",
                     positionY: double(value, "position_y") ?? 0.88)
    }

    private static func adjustment(_ value: AnyCodableValue) throws -> ImageLayerAdjustment {
        let dict = try object(value)
        return ImageLayerAdjustment(
            saturation: dict["saturation"].flatMap(number),
            contrast: dict["contrast"].flatMap(number),
            brightness: dict["brightness"].flatMap(number),
            exposureEV: dict["exposure_ev"].flatMap(number),
            blurRadius: dict["blur_radius"].flatMap(number),
            sharpenRadius: dict["sharpen_radius"].flatMap(number),
            mosaicBlockSize: dict["mosaic_block_size"].flatMap(intValue),
            filterID: dict["filter_id"].flatMap(stringValue))
    }

    private static func textContent(_ value: AnyCodableValue) throws -> ImageTextContent {
        let dict = try object(value)
        return ImageTextContent(text: try requireString(dict, "text"),
                                fontSize: dict["font_size"].flatMap(number) ?? 48,
                                colorHex: dict["color_hex"].flatMap(stringValue) ?? "#000000",
                                fontName: dict["font_name"].flatMap(stringValue))
    }

    private static func freehand(_ value: AnyCodableValue) throws -> ImageFreehandContent {
        let dict = try object(value)
        guard case .array(let strokeValues)? = dict["strokes"] else {
            return ImageFreehandContent(strokes: [])
        }
        let strokes: [ImageFreehandStroke] = try strokeValues.map { raw in
            let stroke = try object(raw)
            guard case .array(let pointValues)? = stroke["points"] else {
                throw FloeError.validationFailed("freehand stroke requires points")
            }
            let points: [ImageFreehandStroke.Point] = try pointValues.map { pointRaw in
                let point = try object(pointRaw)
                return ImageFreehandStroke.Point(x: try requireNumber(point, "x"),
                                                 y: try requireNumber(point, "y"))
            }
            return ImageFreehandStroke(points: points,
                                       width: stroke["width"].flatMap(number) ?? 4,
                                       colorHex: stroke["color_hex"].flatMap(stringValue) ?? "#000000")
        }
        return ImageFreehandContent(strokes: strokes)
    }

    private static func optionalTransform(_ value: AnyCodableValue?) -> ImageLayerTransform? {
        guard let value, let dict = try? object(value) else { return nil }
        return ImageLayerTransform(
            centerX: dict["center_x"].flatMap(number) ?? 0.5,
            centerY: dict["center_y"].flatMap(number) ?? 0.5,
            scale: dict["scale"].flatMap(number) ?? 1,
            rotationDegrees: dict["rotation_degrees"].flatMap(number) ?? 0)
    }

    private static func rect(_ value: AnyCodableValue?) throws -> NormalizedRect? {
        guard let value else { return nil }
        if case .null = value { return nil }
        let dict = try object(value)
        return NormalizedRect(x: try requireNumber(dict, "x"), y: try requireNumber(dict, "y"),
                              width: try requireNumber(dict, "width"),
                              height: try requireNumber(dict, "height"))
    }

    private static func cropUpdate(_ value: AnyCodableValue?) -> OptionalUpdate<NormalizedRect> {
        guard let value else { return .unchanged }
        if case .null = value { return .clear }
        guard let rect = try? rect(value) else { return .unchanged }
        return .set(rect)
    }

    // MARK: Primitives

    private static func object(_ value: AnyCodableValue) throws -> [String: AnyCodableValue] {
        guard case .object(let dict) = value else {
            throw FloeError.validationFailed("expected a JSON object")
        }
        return dict
    }

    private static func requiredString(_ dict: [String: AnyCodableValue], _ key: String) throws -> String {
        guard let value = dict[key] else { throw FloeError.validationFailed("missing '\(key)'") }
        return try requireString([key: value], key)
    }

    private static func requireString(_ dict: [String: AnyCodableValue], _ key: String) throws -> String {
        guard case .string(let value)? = dict[key] else {
            throw FloeError.validationFailed("'\(key)' must be a string")
        }
        return value
    }

    private static func optionalString(_ dict: [String: AnyCodableValue], _ key: String) -> String? {
        dict[key].flatMap(stringValue)
    }

    private static func stringValue(_ value: AnyCodableValue) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }

    private static func requireDouble(_ dict: [String: AnyCodableValue], _ key: String) throws -> Double {
        guard let value = dict[key] else { throw FloeError.validationFailed("missing '\(key)'") }
        return try requireNumber([key: value], key)
    }

    private static func requireNumber(_ dict: [String: AnyCodableValue], _ key: String) throws -> Double {
        guard case .number(let value)? = dict[key] else {
            throw FloeError.validationFailed("'\(key)' must be a number")
        }
        return value
    }

    private static func double(_ dict: [String: AnyCodableValue], _ key: String) -> Double? {
        dict[key].flatMap(number)
    }

    private static func number(_ value: AnyCodableValue) -> Double? {
        if case .number(let n) = value { return n }
        return nil
    }

    private static func int(_ dict: [String: AnyCodableValue], _ key: String) throws -> Int {
        Int(try requireDouble(dict, key))
    }

    private static func intValue(_ value: AnyCodableValue) -> Int? {
        number(value).map(Int.init)
    }

    private static func bool(_ dict: [String: AnyCodableValue], _ key: String) -> Bool? {
        if case .boolean(let b)? = dict[key] { return b }
        return nil
    }

    private static func uuid(_ dict: [String: AnyCodableValue], _ key: String) throws -> UUID {
        guard case .string(let raw)? = dict[key], let id = UUID(uuidString: raw) else {
            throw FloeError.validationFailed("'\(key)' must be a UUID")
        }
        return id
    }

    private static func uuidValue(_ value: AnyCodableValue) -> UUID? {
        if case .string(let raw) = value { return UUID(uuidString: raw) }
        return nil
    }

    private static func uuidArray(_ dict: [String: AnyCodableValue], _ key: String) throws -> [UUID] {
        guard case .array(let values)? = dict[key] else {
            throw FloeError.validationFailed("'\(key)' must be an array of UUIDs")
        }
        return try values.map { raw in
            guard case .string(let s) = raw, let id = UUID(uuidString: s) else {
                throw FloeError.validationFailed("'\(key)' contains an invalid UUID")
            }
            return id
        }
    }
}

// MARK: - Summaries

public enum MediaProjectSummaries {
    public static func summary(_ project: MediaProject) throws -> String {
        var lines: [String] = [
            "media_project: \(project.id.uuidString)",
            "name: \(project.name)",
            "kind: \(project.kind.rawValue)",
            "revision: \(project.revision)"
        ]
        if let canvas = project.canvas {
            var canvasLine = "canvas: \(canvas.width)x\(canvas.height)"
            if let fps = canvas.frameRate { canvasLine += " @ \(String(format: "%.3f", fps))fps" }
            lines.append(canvasLine)
        }
        lines.append("assets: \(project.assets.count)")
        for asset in project.assets {
            lines.append("  - \(asset.id.uuidString) \(asset.kind.rawValue) \(asset.originalName)")
        }
        if project.kind == .image {
            lines.append("layers: \(project.imageLayers.count)")
            for (index, layer) in project.imageLayers.enumerated() {
                lines.append("  \(index). [\(layer.isHidden ? "hidden" : "visible")\(layer.isLocked ? ",locked" : "")] \(layer.kind.rawValue) '\(layer.name)' opacity \(layer.opacity)")
            }
        } else if let timeline = project.videoTimeline {
            lines.append("clips: \(timeline.clips.count) duration \(String(format: "%.2f", timeline.primaryDuration))s")
            for (index, clip) in timeline.clips.enumerated() {
                lines.append("  \(index). \(clip.trimStart)-\(clip.trimEnd)s speed \(clip.speed) transition \(clip.leadingTransition.rawValue)")
            }
            lines.append("music: \(timeline.music.count) captions: \(timeline.captions.count)")
        }
        if !project.unknownOperations.isEmpty {
            lines.append("preserved_unknown_operations: \(project.unknownOperations.count)")
        }
        if !project.recoveryWarnings.isEmpty {
            lines.append("warnings: \(project.recoveryWarnings.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    public static func preview(proposal: MediaProposal, project: MediaProject) throws -> String {
        let draft = try MediaProposalGate.dryRun(proposal, against: project)
        return """
        Pending media proposal \(proposal.id.uuidString) against revision \(proposal.baseRevision)
        \(proposal.summary)
        Commands: \(proposal.commands.count)
        Resulting revision: \(draft.revision)
        Awaiting user acceptance in the workbench UI. The model cannot apply this proposal itself.
        """
    }

    public static func receipt(_ receipt: WorkbenchVideoExportReceipt) -> String {
        "Exported \(receipt.width)x\(receipt.height) \(receipt.codec) \(String(format: "%.2f", receipt.durationSeconds))s -> \(receipt.url.lastPathComponent) (\(receipt.byteCount) bytes, audio: \(receipt.hasAudio))"
    }

    public static func receipt(_ receipt: WorkbenchImageExportReceipt) -> String {
        "Exported \(receipt.width)x\(receipt.height) \(receipt.format) -> \(receipt.url.lastPathComponent) (\(receipt.byteCount) bytes)"
    }
}
