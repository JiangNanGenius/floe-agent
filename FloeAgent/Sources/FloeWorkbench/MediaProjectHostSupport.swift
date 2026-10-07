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

/// Host callbacks used to enrich model-only commands (align/merge) with
/// renderer measurements and raster assets before validation.
public protocol MediaCommandEnrichmentHost: Sendable {
    func measureLayers(project: MediaProject, layerIDs: [UUID]) async throws -> [LayerNaturalSize]
    func renderMergeAsset(project: MediaProject, layerIDs: [UUID], name: String?) async throws -> MergePreparation
    /// Best-effort removal of a staged merge asset whose proposal was invalid
    /// or rejected and which the project does not reference. Never deletes a
    /// referenced asset. Default no-op.
    func discardStagedAsset(_ asset: MediaAssetReference) async
}

public extension MediaCommandEnrichmentHost {
    func discardStagedAsset(_ asset: MediaAssetReference) async {}
}

public enum MediaCommandEnrichment {
    /// Fills renderer-dependent payloads SEQUENTIALLY against a validated
    /// evolving draft, so a batch such as `update_layer` → `align_layers` or
    /// `add_image_layer` → `merge_layers` measures the state the earlier
    /// commands produce (not the stale original). The returned command list is
    /// still applied atomically by the proposal gate; the local draft is only
    /// enrichment context.
    ///
    /// On any failure the staged merge assets created so far are discarded, so
    /// an invalid batch never leaks files.
    public static func enrich(
        _ commands: [MediaEditCommand],
        project: MediaProject,
        host: MediaCommandEnrichmentHost
    ) async throws -> [MediaEditCommand] {
        var draft = project
        var out: [MediaEditCommand] = []
        out.reserveCapacity(commands.count)
        var staged: [MediaAssetReference] = []
        do {
            for command in commands {
                switch command {
                case .alignLayers(let ids, let alignment, let sizes) where sizes.isEmpty:
                    // Measure against the current draft (after earlier commands).
                    let measured = try await host.measureLayers(project: draft, layerIDs: ids)
                    let byID = Set(measured.map(\.layerID))
                    guard Set(ids).subtracting(byID).isEmpty else {
                        throw FloeError.validationFailed(
                            "renderer could not measure layers; alignment refused")
                    }
                    let enriched = MediaEditCommand.alignLayers(
                        ids: ids, alignment: alignment, naturalSizes: measured)
                    try MediaEditCommandApplier.apply(enriched, to: &draft)
                    out.append(enriched)
                case .mergeLayers(let ids, let name, let raster) where raster.width == 0:
                    // Render against the current draft so newly added layers are
                    // resolvable and the merged pixels match the batch outcome.
                    let prep = try await host.renderMergeAsset(project: draft, layerIDs: ids, name: name)
                    staged.append(prep.asset)
                    let addAsset = MediaEditCommand.addAsset(prep.asset)
                    try MediaEditCommandApplier.apply(addAsset, to: &draft)
                    out.append(addAsset)
                    let merge = MediaEditCommand.mergeLayers(ids: ids, name: name, raster: prep.raster)
                    try MediaEditCommandApplier.apply(merge, to: &draft)
                    out.append(merge)
                default:
                    try MediaEditCommandApplier.apply(command, to: &draft)
                    out.append(command)
                }
            }
        } catch {
            for asset in staged {
                await host.discardStagedAsset(asset)
            }
            throw error
        }
        return out
    }

    /// Staged assets referenced by merge commands, used to clean up rejected
    /// proposals whose project never adopted them.
    public static func stagedAssets(in commands: [MediaEditCommand]) -> [MediaAssetReference] {
        var assets: [MediaAssetReference] = []
        var index = 0
        while index < commands.count {
            if case .addAsset(let asset) = commands[index],
               index + 1 < commands.count,
               case .mergeLayers(_, _, let raster) = commands[index + 1],
               raster.assetID == asset.id {
                assets.append(asset)
                index += 2
                continue
            }
            index += 1
        }
        return assets
    }
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
                transform: try optionalValue(value["transform"]) { try requiredTransform($0) },
                opacity: double(value, "opacity"),
                isHidden: bool(value, "is_hidden"),
                isLocked: bool(value, "is_locked"),
                adjustment: try optionalValue(value["adjustment"]) { try adjustment($0) },
                text: try optionalValue(value["text"]) { try textContent($0) },
                crop: cropUpdate(value["crop"]))
        case "reorder_layers":
            return .reorderLayers(orderedIDs: try uuidArray(value, "ordered_ids"))
        case "move_layer":
            return .moveLayer(id: try uuid(value, "id"), toIndex: try int(value, "to_index"))
        case "duplicate_layer":
            return .duplicateLayer(id: try uuid(value, "id"), name: optionalString(value, "name"))
        case "add_freehand_stroke":
            return .addFreehandStroke(id: try uuid(value, "id"), stroke: try requiredStroke(value))
        case "remove_layer":
            return .removeLayer(id: try uuid(value, "id"))
        case "set_selection":
            return .setImageSelection(try selection(value["selection"]))
        case "clear_selection":
            return .setImageSelection(nil)
        case "set_layer_selection":
            return .setLayerSelectionMask(
                id: try uuid(value, "id"),
                selection: try selectionUpdate(value["selection"]))
        case "add_mask_stroke":
            return .addLayerMaskStroke(id: try uuid(value, "id"), stroke: try maskStroke(value))
        case "clear_layer_mask":
            return .clearLayerMask(id: try uuid(value, "id"))
        case "flip_layer":
            return .flipLayer(id: try uuid(value, "id"),
                              horizontal: bool(value, "horizontal") ?? true)
        case "align_layers":
            guard let alignmentRaw = optionalString(value, "alignment"),
                  let alignment = LayerAlignment(rawValue: alignmentRaw) else {
                throw FloeError.validationFailed(
                    "alignment must be one of left/centerX/right/top/centerY/bottom")
            }
            // Measured natural sizes are supplied by the host renderer during
            // proposal enrichment (the pure decoder has no asset bytes).
            return .alignLayers(ids: try uuidArray(value, "ids"), alignment: alignment,
                                naturalSizes: [])
        case "merge_layers":
            // The raster asset is rendered/registered by the host during
            // proposal enrichment; placeholder is replaced before validation.
            return .mergeLayers(ids: try uuidArray(value, "ids"),
                                name: optionalString(value, "name"),
                                raster: MergedLayerRaster(assetID: UUID(), width: 0, height: 0))
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
        case "duplicate_clip":
            return .duplicateClip(id: try uuid(value, "id"))
        case "remove_clip":
            return .removeClip(id: try uuid(value, "id"))
        case "set_cover":
            return .setCover(time: double(value, "time"))
        case "shift_captions":
            return .shiftCaptions(bySeconds: try requireDouble(value, "by_seconds"))
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
            throw FloeError.validationFailed("layer kind must be image/text/freehand/fill")
        }
        return ImageLayer(
            kind: kind,
            name: optionalString(value, "name") ?? kindRaw,
            assetID: value["asset_id"].flatMap { uuidValue($0) },
            transform: try optionalValue(value["transform"]) { try requiredTransform($0) } ?? .init(),
            opacity: double(value, "opacity") ?? 1,
            isHidden: bool(value, "is_hidden") ?? false,
            isLocked: bool(value, "is_locked") ?? false,
            text: try optionalValue(value["text"]) { try textContent($0) },
            freehand: try optionalValue(value["freehand"]) { try freehand($0) },
            crop: try rect(value["crop"]),
            adjustment: try optionalValue(value["adjustment"]) { try adjustment($0) } ?? .init(),
            mask: try optionalValue(value["mask"]) { try layerMask($0) },
            selectionMask: try optionalValue(value["selection_mask"]) { try requiredSelection($0) },
            fillColorHex: optionalString(value, "fill_color_hex"))
    }

    private static func layerMask(_ value: AnyCodableValue) throws -> ImageLayerMask {
        let dict = try object(value)
        guard case .array(let strokeValues)? = dict["strokes"] else {
            return ImageLayerMask(strokes: [])
        }
        let strokes: [ImageMaskStroke] = try strokeValues.map { raw in
            let stroke = try object(raw)
            guard case .array(let pointValues)? = stroke["points"] else {
                throw FloeError.validationFailed("mask stroke requires points")
            }
            let points: [ImageFreehandStroke.Point] = try pointValues.map { pointRaw in
                let point = try object(pointRaw)
                return ImageFreehandStroke.Point(x: try requireNumber(point, "x"),
                                                 y: try requireNumber(point, "y"))
            }
            return ImageMaskStroke(points: points,
                                   width: stroke["width"].flatMap(number) ?? 24,
                                   hardness: stroke["hardness"].flatMap(number),
                                   restore: bool(stroke, "restore") ?? false)
        }
        return ImageLayerMask(strokes: strokes)
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
                     positionY: double(value, "position_y") ?? 0.88,
                     alignment: optionalString(value, "alignment")
                        .flatMap(CaptionAlignment.init(rawValue:)),
                     respectsSafeArea: bool(value, "respects_safe_area"))
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
            filterID: dict["filter_id"].flatMap(stringValue),
            temperature: dict["temperature"].flatMap(number),
            hueDegrees: dict["hue_degrees"].flatMap(number),
            levels: dict["levels"].flatMap { raw in
                guard let levelsDict = try? object(raw) else { return nil }
                return ImageLevels(
                    black: levelsDict["black"].flatMap(number) ?? 0,
                    white: levelsDict["white"].flatMap(number) ?? 1,
                    gamma: levelsDict["gamma"].flatMap(number) ?? 1)
            })
    }

    private static func textContent(_ value: AnyCodableValue) throws -> ImageTextContent {
        let dict = try object(value)
        return ImageTextContent(
            text: try requireString(dict, "text"),
            fontSize: dict["font_size"].flatMap(number) ?? 48,
            colorHex: dict["color_hex"].flatMap(stringValue) ?? "#000000",
            fontName: dict["font_name"].flatMap(stringValue),
            tracking: dict["tracking"].flatMap(number),
            leading: dict["leading"].flatMap(number),
            alignment: dict["alignment"].flatMap(stringValue)
                .flatMap(ImageTextAlignment.init(rawValue:)),
            strokeColorHex: dict["stroke_color_hex"].flatMap(stringValue),
            strokeWidth: dict["stroke_width"].flatMap(number),
            shadow: dict["shadow"].flatMap { raw in
                guard let shadowDict = try? object(raw) else { return nil }
                return ImageTextShadow(
                    colorHex: shadowDict["color_hex"].flatMap(stringValue) ?? "#00000080",
                    blur: shadowDict["blur"].flatMap(number) ?? 4,
                    offsetX: shadowDict["offset_x"].flatMap(number) ?? 2,
                    offsetY: shadowDict["offset_y"].flatMap(number) ?? 2)
            })
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
                                                 y: try requireNumber(point, "y"),
                                                 pressure: point["pressure"].flatMap(number))
            }
            return ImageFreehandStroke(points: points,
                                       width: stroke["width"].flatMap(number) ?? 4,
                                       colorHex: stroke["color_hex"].flatMap(stringValue) ?? "#000000",
                                       hardness: stroke["hardness"].flatMap(number),
                                       opacity: stroke["opacity"].flatMap(number))
        }
        return ImageFreehandContent(strokes: strokes)
    }

    // MARK: Selection / mask

    private static func selection(_ value: AnyCodableValue?) throws -> ImageSelection? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return try requiredSelection(value)
    }

    private static func requiredSelection(_ value: AnyCodableValue) throws -> ImageSelection {
        let dict = try object(value)
        guard case .array(let shapeValues)? = dict["shapes"] else {
            throw FloeError.validationFailed("selection requires a 'shapes' array")
        }
        let shapes: [ImageSelectionShape] = try shapeValues.map { raw in
            let shape = try object(raw)
            let kindRaw = try requireString(shape, "kind")
            guard let kind = ImageSelectionKind(rawValue: kindRaw) else {
                throw FloeError.validationFailed("selection kind must be rectangle/ellipse/lasso")
            }
            let operation = optionalString(shape, "operation")
                .flatMap(ImageSelectionOperation.init(rawValue:)) ?? .replace
            guard case .array(let pointValues)? = shape["points"] else {
                throw FloeError.validationFailed("selection shape requires points")
            }
            let points: [ImageFreehandStroke.Point] = try pointValues.map { pointRaw in
                let point = try object(pointRaw)
                return ImageFreehandStroke.Point(x: try requireNumber(point, "x"),
                                                 y: try requireNumber(point, "y"),
                                                 pressure: point["pressure"].flatMap(number))
            }
            return ImageSelectionShape(kind: kind, operation: operation, points: points)
        }
        return ImageSelection(shapes: shapes,
                              feather: dict["feather"].flatMap(number) ?? 0,
                              inverted: dict["inverted"].flatMap(boolValue) ?? false)
    }

    private static func selectionUpdate(_ value: AnyCodableValue?) throws -> OptionalUpdate<ImageSelection> {
        guard let value else { return .unchanged }
        if case .null = value { return .clear }
        if let selection = try selection(value) { return .set(selection) }
        return .clear
    }

    private static func requiredStroke(_ value: [String: AnyCodableValue]) throws -> ImageFreehandStroke {
        guard case .array(let pointValues)? = value["points"] else {
            throw FloeError.validationFailed("freehand stroke requires points")
        }
        let points: [ImageFreehandStroke.Point] = try pointValues.map { pointRaw in
            let point = try object(pointRaw)
            return ImageFreehandStroke.Point(x: try requireNumber(point, "x"),
                                             y: try requireNumber(point, "y"),
                                             pressure: point["pressure"].flatMap(number))
        }
        return ImageFreehandStroke(points: points,
                                   width: value["width"].flatMap(number) ?? 4,
                                   colorHex: optionalString(value, "color_hex") ?? "#000000",
                                   hardness: value["hardness"].flatMap(number),
                                   opacity: value["opacity"].flatMap(number))
    }

    private static func maskStroke(_ value: [String: AnyCodableValue]) throws -> ImageMaskStroke {
        guard case .array(let pointValues)? = value["points"] else {
            throw FloeError.validationFailed("mask stroke requires points")
        }
        let points: [ImageFreehandStroke.Point] = try pointValues.map { pointRaw in
            let point = try object(pointRaw)
            return ImageFreehandStroke.Point(x: try requireNumber(point, "x"),
                                             y: try requireNumber(point, "y"),
                                             pressure: point["pressure"].flatMap(number))
        }
        return ImageMaskStroke(points: points,
                               width: value["width"].flatMap(number) ?? 24,
                               hardness: value["hardness"].flatMap(number),
                               restore: bool(value, "restore") ?? false)
    }

    private static func boolValue(_ value: AnyCodableValue) -> Bool? {
        if case .boolean(let b) = value { return b }
        return nil
    }

    /// Decodes an optional JSON value: absent or null → nil; present values are
    /// decoded strictly and a malformed value throws instead of silently
    /// becoming a no-op.
    private static func optionalValue<T>(_ value: AnyCodableValue?,
                                         _ parse: (AnyCodableValue) throws -> T) throws -> T? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return try parse(value)
    }

    private static func requiredTransform(_ value: AnyCodableValue) throws -> ImageLayerTransform {
        let dict = try object(value)
        func strictNumber(_ key: String, _ fallback: Double) throws -> Double {
            guard let raw = dict[key] else { return fallback }
            guard let n = number(raw) else {
                throw FloeError.validationFailed("transform '\(key)' must be a number")
            }
            return n
        }
        func strictBool(_ key: String) throws -> Bool? {
            guard let raw = dict[key] else { return nil }
            guard let b = boolValue(raw) else {
                throw FloeError.validationFailed("transform '\(key)' must be a boolean")
            }
            return b
        }
        return ImageLayerTransform(
            centerX: try strictNumber("center_x", 0.5),
            centerY: try strictNumber("center_y", 0.5),
            scale: try strictNumber("scale", 1),
            rotationDegrees: try strictNumber("rotation_degrees", 0),
            flipX: try strictBool("flip_x"),
            flipY: try strictBool("flip_y"))
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
    /// Dynamic capability report for the current project kind/state. This is
    /// derived from the live model (not a hard-coded promise): it lists the
    /// commands that actually apply to this kind and reflects whether editing
    /// is possible (canvas initialized, project open).
    public static func capabilities(_ project: MediaProject) -> String {
        var lines: [String] = [
            "media_project_capabilities",
            "project_id: \(project.id.uuidString)",
            "kind: \(project.kind.rawValue)",
            "revision: \(project.revision)",
            "canvas_ready: \(project.canvas != nil)",
            "workflow: capabilities -> read -> propose -> user_confirm(grant) -> apply -> verify_revision_or_export",
            "draft_vs_applied: propose only stores a revision-bound draft; the project changes only after a UI-issued grant.",
            "modify_vs_variant: edit the bound project to modify the current draft; a forked project (parent_project_id) is a variant.",
            "actions: capabilities, read, propose, apply, export"
        ]
        if project.kind == .image {
            lines += [
                "image_commands: add_image_layer, update_layer, add_freehand_stroke, reorder_layers, move_layer, duplicate_layer, remove_layer, "
                    + "set_selection, clear_selection, set_layer_selection, add_mask_stroke, clear_layer_mask, flip_layer, "
                    + "align_layers, merge_layers, set_canvas_adjustment, add_asset, relink_asset, set_canvas",
                "selection: rectangle|ellipse|lasso with replace|add|subtract, feather 0..0.5, invert",
                "masks: non-destructive erase/restore strokes; original pixels are never destroyed",
                "brushes: width, hardness 0..1, opacity 0..1, color #RRGGBB, Pencil pressure (finger strokes are fixed width)",
                "typography: size, tracking, leading, alignment, stroke, shadow, named fonts",
                "adjustments: saturation, contrast, brightness, exposure, blur, sharpen, temperature, hue, levels, mosaic, filters",
                "merge: visible image/text/ink layers raster-compose through the renderer into one reversible image layer",
                "export_formats: png (alpha), heic (alpha), jpeg (no alpha; transparency is rejected, not silently flattened)"
            ]
        } else {
            lines += [
                "video_commands: append_clip, update_clip, reorder_clips, split_clip, duplicate_clip, remove_clip, "
                    + "set_primary_audio, set_cover, shift_captions, add_music, update_music, remove_music, "
                    + "add_caption, update_caption, remove_caption, set_caption_style",
                "tracks: one primary video track only (no multi-track/keyframes)",
                "time: exact HH:MM:SS:FF timecode, frame stepping, clip-edge snapping; trims retime captions",
                "audio: single music track with volume/fade visuals; per-clip volume and primary mix",
                "captions: batch style/alignment/safe-area and global time shift",
                "export_presets: landscape1080p, portrait1080p, square1080 with explicit codec h264|hevc and frame_rate"
            ]
        }
        if !project.recoveryWarnings.isEmpty {
            lines.append("warnings: \(project.recoveryWarnings.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

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
