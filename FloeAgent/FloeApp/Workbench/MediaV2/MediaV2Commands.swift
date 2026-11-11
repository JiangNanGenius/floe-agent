// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import FloeWorkbench
import FloeMedia

struct MediaV2ToolInput: Codable, Sendable {
    var objectID: UUID?
    var objectIDs: [UUID]?
    /// Video-only typed clip selection and same-original nested source scope.
    var clipIDs:[UUID]?
    var compoundID:UUID?
    var expectedRevision: Int64?
    var selectionFence: String?
    var number: Double?
    var secondary: Double?
    var start: Double?
    var duration: Double?
    var text: String?
    var color: String?
    var property: String?
    var flag: Bool?
    var points: [ImageFreehandStroke.Point]?
    var captionStyle: CaptionStyle?
    var adjustment: ImageLayerAdjustment?
    var noiseReduction: AudioSpectralDenoiseSettings?
    var dialogueDucking: AudioDuckingSettings?
    var voiceSeparation: AudioVoiceSeparationSelection?
    var audioProcessing: MediaAudioProcessing?
    var chromaKey: MediaVideoChromaKey?
    var videoGrade: MediaVideoGrade?
    init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case objectID, objectIDs, clipIDs, compoundID, expectedRevision, selectionFence, number, secondary, start, duration, text, color, property, flag, points, captionStyle, adjustment, noiseReduction, dialogueDucking, voiceSeparation, audioProcessing, chromaKey, videoGrade
    }
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Field.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = all.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [unknown], debugDescription: "Unknown media tool field"))
        }
        let value = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try value.decodeIfPresent(UUID.self, forKey: .objectID)
        objectIDs = try value.decodeIfPresent([UUID].self, forKey: .objectIDs)
        clipIDs = try value.decodeIfPresent([UUID].self,forKey:.clipIDs)
        compoundID = try value.decodeIfPresent(UUID.self,forKey:.compoundID)
        expectedRevision = try value.decodeIfPresent(Int64.self, forKey: .expectedRevision)
        selectionFence = try value.decodeIfPresent(String.self, forKey: .selectionFence)
        if let selectionFence, selectionFence.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil {
            throw DecodingError.dataCorruptedError(forKey: .selectionFence, in: value, debugDescription: "Use the actual selectionFence from a fresh studio.read")
        }
        number = try value.decodeIfPresent(Double.self, forKey: .number)
        secondary = try value.decodeIfPresent(Double.self, forKey: .secondary)
        start = try value.decodeIfPresent(Double.self, forKey: .start)
        duration = try value.decodeIfPresent(Double.self, forKey: .duration)
        text = try value.decodeIfPresent(String.self, forKey: .text)
        color = try value.decodeIfPresent(String.self, forKey: .color)
        property = try value.decodeIfPresent(String.self, forKey: .property)
        flag = try value.decodeIfPresent(Bool.self, forKey: .flag)
        points = try value.decodeIfPresent([ImageFreehandStroke.Point].self, forKey: .points)
        if value.contains(.captionStyle), try value.decodeNil(forKey: .captionStyle) == false {
            let fields = try value.nestedContainer(keyedBy: Field.self, forKey: .captionStyle)
            let accepted: Set<String> = ["fontSize","colorHex","backgroundHex","positionY","alignment","respectsSafeArea"]
            if let unknown = fields.allKeys.first(where: { !accepted.contains($0.stringValue) }) {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [CodingKeys.captionStyle, unknown], debugDescription: "Unknown caption style field"))
            }
        }
        captionStyle = try value.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)
        adjustment = try value.decodeIfPresent(ImageLayerAdjustment.self, forKey: .adjustment)
        noiseReduction = try value.decodeIfPresent(AudioSpectralDenoiseSettings.self, forKey: .noiseReduction)
        dialogueDucking = try value.decodeIfPresent(AudioDuckingSettings.self, forKey: .dialogueDucking)
        voiceSeparation = try value.decodeIfPresent(AudioVoiceSeparationSelection.self, forKey: .voiceSeparation)
        audioProcessing = try value.decodeIfPresent(MediaAudioProcessing.self,forKey:.audioProcessing)
        chromaKey = try value.decodeIfPresent(MediaVideoChromaKey.self,forKey:.chromaKey)
        videoGrade = try value.decodeIfPresent(MediaVideoGrade.self,forKey:.videoGrade)
    }
}
struct MediaV2ToolReceipt: Codable {
    let documentID: UUID
    let revision: Int64
    let toolID: String
    let groupID: UUID?
    let selectionOnly: Bool
    var analysis: MediaVideoScopeSnapshot? = nil
    var imageWarp: MediaV2ImageWarpReceipt? = nil
    var audioDerivation: MediaV2AudioDerivationReceipt? = nil
    var voiceSeparation: MediaV2VoiceSeparationReceipt? = nil
    var tracking: MediaVideoTracking? = nil
    var stabilization: MediaVideoStabilization? = nil
    var colorMatch: MediaVideoColorMatch? = nil
    var colorProfile: MediaVideoColorProfile? = nil
    var compound:MediaV2CompoundReceipt? = nil
}
enum MediaV2CommandError: Error, LocalizedError {
    case unavailable, missingSelection, invalidInput, invalidCaptionStyle, exportInProgress, missingExport
    var errorDescription: String? {
        switch self {
        case .unavailable: return WorkbenchText.t("此工具的执行服务尚未接入。", "This tool's execution service is not connected yet.")
        case .missingSelection: return WorkbenchText.t("请先选择要编辑的对象。", "Select an object to edit first.")
        case .invalidInput: return WorkbenchText.t("参数无效，请检查后重试。", "Check the parameters and retry.")
        case .invalidCaptionStyle: return WorkbenchText.t("请检查字幕样式。纵向位置应在 0–1，字号应在 0–512；也可使用完整字幕样式设置。", "Check the caption style. Vertical position must be 0–1 and font size 0–512; use the complete caption style settings for other changes.")
        case .exportInProgress: return WorkbenchText.t("正在导出，请等待完成或先取消。", "An export is running. Wait for it or cancel it first.")
        case .missingExport: return WorkbenchText.t("未生成导出文件，请打开详细信息后重试。", "No export file was produced. Open the details and retry.")
        }
    }
}

extension MediaV2Session {
    static let localToolIDs: Set<String> = [
        "image.remove-asset", "video.remove-asset",
        "image.remove", "image.content-fill", "image.heal", "image.patch", "image.smudge", "image.clone", "image.gradient", "image.blur-brush", "image.sharpen-brush", "image.layer-effect",
        "image.perspective", "image.distort", "image.wand", "image.subject", "image.refine-edge", "image.expand", "image.smooth", "image.background", "image.curves", "image.balance", "image.lut", "image.denoise",
        "image.rectangle", "image.ellipse", "image.lasso", "image.polygon", "image.feather", "image.inverse", "image.deselect",
        "image.brush", "image.eraser", "image.fill", "image.eyedropper", "image.layer-mask", "image.vector-mask", "image.clip-mask",
        "image.adjustment-layer", "image.group-layer", "image.duplicate-layer", "image.merge-layer", "image.crop", "image.rotate", "image.flip",
        "image.boolean", "image.path-text", "image.outline", "image.resize", "image.canvas-size", "image.text", "image.shape", "image.pen", "image.anchor", "image.stroke-fill", "image.exposure", "image.levels", "image.hsl", "image.white-balance", "image.bw",
        "video.video-curves", "video.wheels", "video.video-hsl", "video.video-lut", "video.tracking", "video.stabilize", "video.color-match", "video.hdr",
        "video.chroma", "video.video-blend", "video.scopes", "video.eq", "video.compressor", "video.noise", "video.duck",
        "video.graph", "video.motion-path", "video.motion-title", "video.preset-motion",
        "video.reverse", "video.freeze", "video.caption-style", "video.nest",
        "video.trim", "video.split", "video.slip", "video.speed", "video.transition", "video.pip",
        "video.video-mask", "video.video-feather", "video.video-transform", "video.keyframes", "video.easing", "video.caption", "video.caption-time", "video.mix", "video.fades", "video.audio-sync", "video.ripple", "video.roll", "video.srt", "image.align", "image.blend-mode"
    ]
    var catalog: [MediaPreparedToolDescriptor] { (try? MediaPreparedBundledCatalog.load().entries) ?? [] }
    var applicableTools: [MediaPreparedToolDescriptor] { catalog.filter { $0.kind.rawValue == project.kind.rawValue && (compoundScopeID == nil || $0.id != "video.nest") } }

    /// Called only after the existing task authority has admitted the edit.
    /// Every advertised local route below either edits the canonical document
    /// or explicitly reports a selection-only editor operation.
    func performTool(_ id: String, input: MediaV2ToolInput, actor: MediaPreparedActorKind = .user,
                     providerAuthority: MediaV2ProviderAuthority? = nil) async throws -> MediaV2ToolReceipt {
        if input.compoundID != nil { return try await performScopedCompoundTool(id,input:input,actor:actor,authority:providerAuthority) }
        guard input.clipIDs == nil || id == "video.nest" else { throw MediaV2CommandError.invalidInput }
        if id == "video.voice-separate",
           let candidate = input.objectID.flatMap({ document.trackGraph.clip(id: $0) }) ?? (actor == .user ? selectedClip : nil),
           candidate.track.kind == .visual {
            // Resolve an existing source-audio association without editing the
            // document before the provider's native revision/authority checks.
            let linked = document.trackGraph.tracks.filter { $0.kind == .audio }.flatMap { track in
                track.clips.filter { $0.sourceVisualClipID == candidate.clip.id }
            }
            guard linked.count == 1, let audio = linked.first else {
                throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t(
                    "请先提取此视频的音频，再选择音频片段进行人声分离。",
                    "Extract this video's audio first, then select the audio clip for voice separation."))
            }
            var routed = input; routed.objectID = audio.id
            return try await performProviderTool(id,input:routed,actor:actor,suppliedAuthority:providerAuthority)
        }
        if Self.providerToolIDs.contains(id) {
            return try await performProviderTool(id,input:input,actor:actor,suppliedAuthority:providerAuthority)
        }
        guard !canvasLayoutInProgress else { throw MediaPreparedCoreError.conflict("a canvas layout operation is running") }
        guard Self.localToolIDs.contains(id) else { throw MediaV2CommandError.unavailable }
        _ = try MediaPreparedBundledCatalog.load().descriptor(id: id)
        if let expected = input.expectedRevision, expected != document.revision { throw MediaPreparedCoreError.documentChanged }
        let fencedSelection: Bool
        if actor == .model {
            guard input.expectedRevision != nil else { throw MediaPreparedCoreError.documentChanged }
            if let expected = input.selectionFence {
                guard try StudioMediaObservation.media(self).selectionFence == expected else { throw MediaPreparedCoreError.documentChanged }
                fencedSelection = true
            } else { fencedSelection = false }
        } else { fencedSelection = true }
        if id == "image.remove-asset" || id == "video.remove-asset" {
            guard id.hasPrefix(document.kind.rawValue + "."), let assetID = input.objectID,
                  input.objectIDs == nil, !processingTool, imageWarpDraft == nil else { throw MediaV2CommandError.invalidInput }
            let operation = try MediaPreparedAssets.removal(assetID: assetID, in: document)
            let commit = try await apply([operation], expectedRevision: input.expectedRevision ?? document.revision, actor: actor)
            return .init(documentID: document.id, revision: document.revision, toolID: id, groupID: commit.groupID, selectionOnly: false)
        }
        let explicitLayer = input.objectID.flatMap { document.layer($0) }
        let explicitClip = input.objectID.flatMap { document.trackGraph.clip(id: $0) }
        let explicitTrack = input.objectID.flatMap { document.trackGraph.track($0) }
        if input.objectID != nil, explicitLayer == nil, explicitClip == nil, explicitTrack == nil {
            throw MediaV2CommandError.missingSelection // Never fall back to another selected object.
        }
        if actor == .user, let object = input.objectID {
            if document.layer(object) != nil { selectedLayerID = object }
            if let clip = explicitClip { select(clip.track, clip: clip.clip) }
            else if let track = explicitTrack { select(track) }
        }
        let usesImplicitTarget = input.objectID == nil && fencedSelection
        let layer = explicitLayer ?? (usesImplicitTarget ? selectedLayer : nil)
        let selected = explicitClip ?? (usesImplicitTarget ? selectedClip : nil)
        let targetTrack = explicitTrack ?? explicitClip?.track ?? (usesImplicitTarget ? selectedTrack : nil)
        let region = fencedSelection ? selection : nil
        let cursor = fencedSelection ? playhead : 0
        if actor == .model, let ids = input.objectIDs {
            guard !ids.isEmpty, ids.count <= 256, Set(ids).count == ids.count,
                  ids.allSatisfy({ document.layer($0) != nil }) else { throw MediaV2CommandError.invalidInput }
        }
        if ["image.boolean","image.path-text","image.outline"].contains(id) {
            return try await performVectorTextTool(id,input:input,actor:actor,fencedSelection:fencedSelection)
        }
        if ["image.resize","image.canvas-size"].contains(id) {
            return try await performCanvasTool(id,input:input,actor:actor)
        }
        if id == "video.hdr" {
            return try await performHDRTool(input:input,selected:selected,actor:actor)
        }
        if id == "video.color-match" {
            return try await performColorMatchTool(input:input,selected:selected,actor:actor)
        }
        if id == "video.nest" { return try await performCompoundTool(input:input,actor:actor) }
        if ["video.tracking","video.stabilize"].contains(id) {
            return try await performVideoMotionTool(id,input:input,selected:selected,actor:actor)
        }
        if id == "video.scopes" {
            let result = try await readVideoScopes(at:input.start ?? cursor)
            return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:nil,selectionOnly:true,analysis:result)
        }
        if ["video.eq", "video.compressor", "video.noise", "video.duck"].contains(id),let selected,selected.track.kind == .visual {
            let audio = try await editableSourceAudio(for:selected.clip.id)
            var routed = input;routed.objectID = audio.clip.id;routed.expectedRevision = document.revision;routed.selectionFence = nil
            return try await performTool(id,input:routed,actor:actor)
        }
        if Self.audioDerivationToolIDs.contains(id) {
            return try await performAudioDerivationTool(id, input: input, selected: selected, actor: actor)
        }
        if Self.imageWarpToolIDs.contains(id) {
            return try await performImageWarpTool(id, input: input, layer: layer, region: region, actor: actor)
        }
        if Self.extendedAnimationTools.contains(id) {
            return try await performAnimationTool(id,input:input,selected:selected,cursor:cursor,actor:actor)
        }
        if Self.extendedImageTools.contains(id) || (id == "image.layer-mask" && region?.bitmap != nil && input.flag != false) {
            return try await performExtendedImageTool(id,input:input,layer:layer,region:region,fencedSelection:fencedSelection,actor:actor)
        }
        var actions: [MediaPreparedAction] = []
        func layerContent(_ content: MediaPreparedLayerContent) throws {
            guard let layer else { throw MediaV2CommandError.missingSelection }
            actions.append(.replaceLayerContent(id: layer.id, expectedRevision: layer.revision, content: content))
        }
        func replace(_ clip: MediaPreparedClip) throws {
            guard let selected else { throw MediaV2CommandError.missingSelection }
            actions.append(.replaceClip(trackID: selected.track.id, clipID: clip.id, expectedRevision: selected.clip.revision, clip: clip))
        }
        func insertLayer(_ content: MediaPreparedLayerContent, name: String, mask: MediaPreparedLayerMask? = nil) {
            let layer = MediaPreparedLayer(name: name, content: content, mask: mask)
            selectedLayerID = layer.id; actions.append(.insertLayer(layer: layer, parentID: nil, index: nil))
        }
        var selectionOnly = false
        if id == "image.merge-layer" {
            if actor == .model, input.objectIDs == nil { throw MediaV2CommandError.missingSelection }
            let ids = Set(input.objectIDs ?? Array(document.layers.suffix(2)).map(\.id))
            let commit = try await mergeLayers(ids, actor: actor)
            return .init(documentID: document.id, revision: document.revision, toolID: id, groupID: commit.groupID, selectionOnly: false)
        }
        switch id {
        case "image.rectangle", "image.ellipse", "image.lasso", "image.polygon":
            guard let points = input.points, points.count >= 2 else { throw MediaV2CommandError.invalidInput }
            let kind: ImageSelectionKind = id == "image.ellipse" ? .ellipse : id == "image.rectangle" ? .rectangle : .lasso
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  points.count <= 10_000, kind != .lasso || points.count >= 3 else { throw MediaV2CommandError.invalidInput }
            let operation = ImageSelectionOperation(rawValue: input.property ?? "replace") ?? .replace
            if actor == .model, operation != .replace, !fencedSelection { throw MediaV2CommandError.missingSelection }
            let shape = ImageSelectionShape(kind: kind, operation: operation, points: points)
            if operation == .replace { selection = .init(shapes: [shape]) }
            else { var next = selection ?? .init(); next.shapes.append(shape); selection = next }
            polygonPoints = []; selectionOnly = true
        case "image.feather":
            if actor == .model, !fencedSelection { throw MediaV2CommandError.missingSelection }
            guard var next = selection, let canvas = document.canvas else { throw MediaV2CommandError.missingSelection }
            next.feather = min(0.5, max(0, (input.number ?? 12) / Double(min(canvas.width, canvas.height)))); selection = next; selectionOnly = true
        case "image.inverse":
            if actor == .model, !fencedSelection { throw MediaV2CommandError.missingSelection }
            var next = selection ?? .init(); next.inverted.toggle(); selection = next; selectionOnly = true
        case "image.deselect":
            if actor == .model, !fencedSelection { throw MediaV2CommandError.missingSelection }
            selection = nil; selectionOnly = true
        case "image.eyedropper":
            guard let image = preview, let p = input.points?.first else { throw MediaV2CommandError.invalidInput }
            let x = min(image.width - 1, max(0, Int(p.x * Double(image.width))))
            let y = min(image.height - 1, max(0, Int(p.y * Double(image.height))))
            guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { throw MediaV2CommandError.invalidInput }
            var bytes = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MediaV2CommandError.invalidInput }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); colorHex = String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2]); selectionOnly = true
        case "image.brush":
            guard let points = input.points, !points.isEmpty else { throw MediaV2CommandError.invalidInput }
            let stroke = ImageFreehandStroke(points: points, width: input.number ?? brushWidth, colorHex: input.color ?? colorHex, hardness: 1 - brushHardness, opacity: brushOpacity)
            if let layer, case .strokes(var strokes) = layer.content { strokes.strokes.append(stroke); try layerContent(.strokes(strokes)) }
            else {
                if actor == .model, input.objectID != nil { throw MediaV2CommandError.invalidInput }
                insertLayer(.strokes(.init(strokes: [stroke])), name: WorkbenchText.t("笔迹", "Brush stroke"))
            }
        case "image.eraser":
            guard let layer, let points = input.points else { throw MediaV2CommandError.missingSelection }
            var mask = layer.mask ?? .init(); mask.strokes.append(.init(points: points, width: input.number ?? brushWidth, hardness: 1 - brushHardness, restore: input.flag ?? eraserRestores, region: region))
            actions.append(.setLayerMask(id: layer.id, expectedRevision: layer.revision, mask: mask))
        case "image.fill": insertLayer(.raster(.init(source: .solidColor(input.color ?? colorHex))), name: WorkbenchText.t("填色", "Fill"), mask: region.map { .init(vector: $0) })
        case "image.layer-mask", "image.vector-mask":
            guard let layer else { throw MediaV2CommandError.missingSelection }
            if input.flag == false { actions.append(.setLayerMask(id: layer.id, expectedRevision: layer.revision, mask: nil)) }
            else { guard let region else { throw MediaV2CommandError.missingSelection }; actions.append(.setLayerMask(id: layer.id, expectedRevision: layer.revision, mask: .init(vector: region))) }
        case "image.clip-mask":
            guard let layer else { throw MediaV2CommandError.missingSelection }
            if input.flag == false { actions.append(.setLayerClip(id: layer.id, expectedRevision: layer.revision, clip: nil)) }
            else {
                let siblings = document.layers.filter { $0.parentID == layer.parentID }
                guard let index = siblings.firstIndex(where: { $0.id == layer.id }), index > 0 else { throw MediaV2CommandError.missingSelection }
                actions.append(.setLayerClip(id: layer.id, expectedRevision: layer.revision, clip: .init(baseLayerID: siblings[index - 1].id)))
            }
        case "image.blend-mode":
            guard let layer, case .group(var group) = layer.content else { throw MediaV2CommandError.unavailable }
            let mode = input.text ?? input.property ?? "normal"
            guard ["normal", "multiply", "screen", "overlay", "darken", "lighten"].contains(mode) else { throw MediaV2CommandError.invalidInput }
            group.blendMode = mode; try layerContent(.group(group))
        case "image.align":
            if actor == .model, input.objectIDs == nil, layer == nil { throw MediaV2CommandError.missingSelection }
            let ids = Set(input.objectIDs ?? layer.map { [$0.id] } ?? [])
            guard !ids.isEmpty, ids.isSubset(of: Set(document.layers.map(\.id))), ["centerX", "centerY", "center"].contains(input.property ?? "center") else { throw MediaV2CommandError.invalidInput }
            for target in document.layers where ids.contains(target.id) {
                let space=try MediaCanvasLayout.alignedSpace(target,in:document,axis:input.property ?? "center")
                actions.append(.setLayerCanvasSpace(id:target.id,expectedRevision:target.revision,space:space))
            }
        case "image.adjustment-layer": insertLayer(.adjustment(.init(exposureEV: input.number ?? 0)), name: WorkbenchText.t("调整图层", "Adjustment"))
        case "image.group-layer":
            if input.flag == false {
                guard let layer, layer.contentKind == .group,
                      let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { throw MediaV2CommandError.missingSelection }
                for (offset, child) in document.layers.filter({ $0.parentID == layer.id }).enumerated() {
                    actions.append(.moveLayer(id: child.id, expectedRevision: child.revision, parentID: layer.parentID, index: index + offset))
                }
                actions.append(.removeLayer(id: layer.id, expectedRevision: layer.revision))
                break
            }
            if actor == .model, input.objectIDs == nil, layer == nil { throw MediaV2CommandError.missingSelection }
            let group = MediaPreparedLayer(name: input.text ?? WorkbenchText.t("编组", "Group"), content: .group(.init(isIsolated: true)))
            actions.append(.insertLayer(layer: group, parentID: nil, index: nil))
            let groupedIDs = input.objectIDs ?? layer.map { [$0.id] } ?? []
            for member in document.layers where groupedIDs.contains(member.id) {
                actions.append(.moveLayer(id: member.id, expectedRevision: member.revision, parentID: group.id, index: document.layers.count))
            }
            selectedLayerID = group.id
        case "image.duplicate-layer":
            guard let layer else { throw MediaV2CommandError.missingSelection }
            let duplicate = duplicateLayerActions(layer)
            actions.append(contentsOf: duplicate.actions); selectedLayerID = duplicate.id
        case "image.crop":
            guard let layer, case .raster(var raster) = layer.content else { throw MediaV2CommandError.missingSelection }
            guard case .asset = raster.source else { throw MediaV2CommandError.unavailable }
            if input.flag == false { raster.crop = nil }
            else {
                guard let points = input.points, points.count == 2 else { throw MediaV2CommandError.invalidInput }
                if input.property == "canvas" { raster.crop = try sourceCrop(for: layer, canvasPoints: points) }
                else { raster.crop = .init(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y), width: abs(points[0].x - points[1].x), height: abs(points[0].y - points[1].y)) }
            }
            try layerContent(.raster(raster))
        case "image.rotate", "image.flip":
            guard let layer else { throw MediaV2CommandError.missingSelection }
            var transform = layer.transform
            if id == "image.flip" { if input.property == "vertical" { transform.flipY = !(transform.flipY ?? false) } else { transform.flipX = !(transform.flipX ?? false) } } else { transform.rotationDegrees += input.number ?? 90 }
            actions.append(.updateLayerTransform(id: layer.id, expectedRevision: layer.revision, transform: transform))
        case "image.text":
            var content = layer.flatMap { target -> ImageTextContent? in if case .text(let text)=target.content { text } else { nil } } ?? ImageTextContent(text:WorkbenchText.t("文字", "Text"),fontSize:72,colorHex:colorHex)
            if let text=input.text { content.text=text }
            if let size=input.number { content.fontSize=size }
            if let color=input.color { content.colorHex=color }
            if let layer,layer.contentKind == .text,content.pathLayout != nil {
                let commit=try await applyEditablePathText(content,to:layer,revision:document.revision,actor:actor)
                return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:commit.groupID,selectionOnly:false)
            }
            if let layer, layer.contentKind == .text { try layerContent(.text(content)) }
            else {
                if actor == .model, input.objectID != nil { throw MediaV2CommandError.invalidInput }
                insertLayer(.text(content), name: content.text)
            }
        case "image.shape", "image.pen", "image.anchor":
            let points = input.points ?? [.init(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.2), .init(x: 0.8, y: 0.8), .init(x: 0.2, y: 0.8)]
            guard points.count >= 2 else { throw MediaV2CommandError.invalidInput }
            let vector = MediaVectorPath(subpaths: [.init(points: points.map { .init(point: $0) }, isClosed: id == "image.shape")], fillColorHex: id == "image.shape" ? input.color ?? colorHex : nil, strokeColorHex: input.color ?? colorHex, strokeWidth: input.number ?? 3)
            if id == "image.anchor" { try layerContent(.vectorPaths(vector)) } else { insertLayer(.vectorPaths(vector), name: WorkbenchText.t("矢量路径", "Vector path")) }
        case "image.stroke-fill":
            guard let layer, case .vectorPaths(var path) = layer.content else { throw MediaV2CommandError.missingSelection }
            path.fillColorHex = input.color ?? colorHex; path.strokeWidth = input.number ?? path.strokeWidth; try layerContent(.vectorPaths(path))
        case "image.exposure", "image.levels", "image.hsl", "image.white-balance", "image.bw":
            guard let layer else { throw MediaV2CommandError.missingSelection }
            var adjustment = MediaImageColorEditing.controls(of: layer)
            switch id {
            case "image.exposure": adjustment.exposureEV = input.number ?? 0
            case "image.levels": adjustment.levels = .init(black: input.number ?? 0, white: input.secondary ?? 1, gamma: 1)
            case "image.hsl": adjustment.saturation = input.number ?? 1; adjustment.hueDegrees = input.secondary
            case "image.white-balance": adjustment.temperature = input.number ?? 6500
            default: adjustment.saturation = 0
            }
            actions.append(try MediaImageColorEditing.action(layer: layer, controls: adjustment))
        case "video.srt":
            guard let text = input.text else { throw MediaV2CommandError.invalidInput }
            actions.append(contentsOf: try captionImportActions(text, offset: input.start ?? 0))
        case "video.caption", "video.caption-style":
            if id == "video.caption-style", input.captionStyle == nil || input.text != nil || input.start != nil || input.duration != nil { throw MediaV2CommandError.invalidCaptionStyle }
            guard project.kind == .video, input.objectIDs == nil, input.secondary == nil, input.flag == nil, input.points == nil else {
                throw MediaV2CommandError.invalidCaptionStyle
            }
            let hasLegacyStyle = input.color != nil || input.property != nil || input.number != nil
            guard input.captionStyle == nil || !hasLegacyStyle else { throw MediaV2CommandError.invalidCaptionStyle }
            if input.captionStyle != nil || hasLegacyStyle {
                var style = input.captionStyle ?? document.trackGraph.captionStyle ?? CaptionStyle()
                if let color = input.color { style.colorHex = color }
                if let property = input.property {
                    guard let number = input.number else { throw MediaV2CommandError.invalidCaptionStyle }
                    switch property {
                    case "positionY": style.positionY = number
                    case "fontSize": style.fontSize = number
                    default: throw MediaV2CommandError.invalidCaptionStyle
                    }
                } else if input.number != nil { throw MediaV2CommandError.invalidCaptionStyle }
                try MediaPreparedIntegrity.validateCaptionStyle(style)
                actions.append(.setCaptionStyle(expectedRevision: document.trackGraph.captionStyleRevision ?? 0, style: style))
            }
            if let text = input.text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MediaV2CommandError.invalidInput }
            let editsCaption = input.text != nil || input.start != nil || input.duration != nil
            if !editsCaption && (input.captionStyle != nil || hasLegacyStyle) { break }
            if actor == .model, input.objectID != nil, selected?.track.kind != .caption { throw MediaV2CommandError.invalidInput }
            if var clip = selected?.clip, selected?.track.kind == .caption {
                if let text = input.text { clip.captionText = text }
                if input.start != nil || input.duration != nil {
                    let duration = input.duration ?? clip.timelineRange.durationSeconds
                    clip.timelineRange = try Self.range(start: input.start ?? clip.timelineRange.startSeconds, duration: duration)
                    clip.sourceRange = try Self.range(start: 0, duration: duration)
                }
                try replace(clip)
            }
            else {
                guard input.start == nil && input.duration == nil || input.text != nil else { throw MediaV2CommandError.missingSelection }
                let track = document.trackGraph.tracks.first { $0.kind == .caption } ?? .init(kind: .caption, name: WorkbenchText.t("字幕", "Captions"))
                if !document.trackGraph.tracks.contains(where: { $0.id == track.id }) { actions.append(.insertTrack(track: track, index: nil)) }
                let clip = MediaPreparedClip(timelineRange: try Self.range(start: input.start ?? cursor, duration: input.duration ?? 3), sourceRange: try Self.range(start: 0, duration: input.duration ?? 3), captionText: input.text ?? WorkbenchText.t("字幕", "Caption"))
                actions.append(.insertClip(trackID: track.id, clip: clip, index: nil)); selectedTrackID = track.id; selectedClipID = clip.id
            }
        case "video.mix":
            guard let track = targetTrack else { throw MediaV2CommandError.missingSelection }
            actions.append(.updateTrackFlags(id: track.id, expectedRevision: track.revision, name: nil, isMuted: input.flag, isLocked: nil, volume: input.number))
        default:
            guard let selected else { throw MediaV2CommandError.missingSelection }
            var clip = selected.clip
            switch id {
            case "video.trim", "video.ripple":
                let start = input.start ?? clip.sourceRange.startSeconds, length = input.duration ?? clip.sourceRange.durationSeconds
                actions.append(contentsOf: try trimActions(track: selected.track, clip: clip, sourceStart: start, sourceDuration: length, ripple: id == "video.ripple"))
                let commit = try await apply(actions.map { .init(action: $0) }, expectedRevision: input.expectedRevision, actor: actor)
                return .init(documentID: document.id, revision: document.revision, toolID: id, groupID: commit.groupID, selectionOnly: false)
            case "video.roll":
                actions.append(contentsOf: try rollActions(track: selected.track, right: clip, boundary: input.start ?? clip.timelineRange.startSeconds + (input.number ?? 0)))
                let commit = try await apply(actions.map { .init(action: $0) }, expectedRevision: input.expectedRevision, actor: actor)
                return .init(documentID: document.id, revision: document.revision, toolID: id, groupID: commit.groupID, selectionOnly: false)
            case "video.slip":
                let nextStart = max(0, clip.sourceRange.startSeconds + (input.number ?? 0))
                if let hold = clip.sourcePlayback?.holdSeconds { clip.sourcePlayback?.holdSeconds = hold + nextStart - clip.sourceRange.startSeconds }
                clip.sourceRange = try Self.range(start: nextStart, duration: clip.sourceRange.durationSeconds)
                if selected.track.kind == .visual { actions.append(contentsOf:try linkedSourceAudioActions(for:clip)) }
            case "video.caption-time", "video.audio-sync": clip.timelineRange = try Self.range(start: max(0, input.start ?? clip.timelineRange.startSeconds + (input.number ?? 0)), duration: clip.timelineRange.durationSeconds)
            case "video.video-curves", "video.wheels", "video.video-hsl", "video.video-lut":
                guard selected.track.kind == .visual else { throw MediaV2CommandError.missingSelection }
                clip.videoGrade = try Self.updatedVideoGrade(tool: id, input: input, current: clip.videoGrade)
            case "video.chroma":
                guard selected.track.kind == .visual else { throw MediaV2CommandError.missingSelection }
                if input.flag == false { clip.chromaKey = nil }
                else {
                    let key = input.chromaKey ?? .init(colorHex:input.color ?? "#00FF00",tolerance:input.number ?? 0.18,softness:input.secondary ?? 0.12)
                    try key.validate();clip.chromaKey = key
                }
            case "video.video-blend":
                guard selected.track.kind == .visual else { throw MediaV2CommandError.missingSelection }
                if input.flag == false { clip.blendMode = nil;clip.visualOpacity = nil }
                else {
                    guard let mode = MediaVideoBlendMode(rawValue:input.property ?? "normal") else { throw MediaV2CommandError.invalidInput }
                    clip.blendMode = mode;clip.visualOpacity = input.number ?? 1
                }
            case "video.eq", "video.compressor":
                guard selected.track.kind == .audio else { throw MediaV2CommandError.missingSelection }
                var controls = clip.audioProcessing ?? .init()
                if id == "video.eq" {
                    if input.flag == false { controls.eqBands = [] }
                    else if let supplied = input.audioProcessing { controls.eqBands = supplied.eqBands }
                    else {
                        guard let filter = PreparedVideoEQFilter(rawValue:input.property ?? "parametric") else { throw MediaV2CommandError.invalidInput }
                        let frequency = input.secondary ?? (filter == .lowShelf ? 80 : filter == .highShelf ? 8_000 : 1_000)
                        controls.eqBands.removeAll { $0.filter == filter && abs($0.frequency-frequency)<0.01 }
                        controls.eqBands.append(.init(frequency:frequency,gain:input.number ?? 0,filter:filter))
                    }
                } else if input.flag == false { controls.dynamics = nil;controls.limiter = nil }
                else if let supplied = input.audioProcessing { controls.dynamics = supplied.dynamics;controls.limiter = supplied.limiter }
                else if input.property == "limiter" { controls.limiter = .init(ceilingDB:input.number ?? -1) }
                else { controls.dynamics = .init(threshold:input.number ?? -20,headRoom:input.secondary ?? 5) }
                try controls.validate();clip.audioProcessing = controls.isEmpty ? nil : controls
            case "video.reverse", "video.freeze":
                guard selected.track.kind == .visual,
                      clip.assetID.flatMap({ document.asset($0)?.kind }) == .video else { throw MediaV2CommandError.missingSelection }
                if id == "video.reverse" {
                    clip.sourcePlayback = .init(isReversed: input.flag ?? !(clip.sourcePlayback?.isReversed ?? false))
                    clip.timelineRange = try Self.range(start: clip.timelineRange.startSeconds, duration: clip.sourceRange.durationSeconds / clip.speed)
                } else if input.flag == false {
                    clip.sourcePlayback = nil
                    clip.timelineRange = try Self.range(start: clip.timelineRange.startSeconds, duration: clip.sourceRange.durationSeconds / clip.speed)
                } else {
                    guard input.start != nil || fencedSelection else { throw MediaV2CommandError.invalidInput }
                    let at = input.start ?? cursor
                    guard at >= clip.timelineRange.startSeconds, at < clip.timelineRange.endSeconds else { throw MediaV2CommandError.invalidInput }
                    let cadence = 1 / max(1, clip.assetID.flatMap { document.asset($0)?.metadata?.frameRate } ?? document.trackGraph.frameRate?.seconds ?? 30)
                    let hold = try MediaSourcePlaybackMath.sourceSeconds(sourceStart: clip.sourceRange.startSeconds,
                        sourceDuration: clip.sourceRange.durationSeconds, speed: clip.speed,
                        localTime: at - clip.timelineRange.startSeconds, playback: clip.sourcePlayback, frameDuration: cadence)
                    clip.sourcePlayback = .init(holdSeconds: hold)
                    if let duration = input.duration {
                        guard duration.isFinite, duration > 0 else { throw MediaV2CommandError.invalidInput }
                        clip.timelineRange = try Self.range(start: clip.timelineRange.startSeconds, duration: duration)
                    }
                }
                clip.keyframeTracks = try slicedKeyframes(clip.keyframeTracks, from: 0, duration: clip.timelineRange.durationSeconds)
                actions.append(contentsOf: try linkedSourceAudioActions(for: clip))
            case "video.speed":
                guard selected.track.kind == .visual || selected.track.kind == .audio else { throw MediaV2CommandError.unavailable }
                let previousSpeed = clip.speed
                clip.speed = input.number ?? 1; guard clip.speed.isFinite, clip.speed > 0 else { throw MediaV2CommandError.invalidInput }
                let factor = previousSpeed / clip.speed
                let nextDuration = clip.sourcePlayback?.holdSeconds != nil ? clip.timelineRange.durationSeconds * factor : clip.sourceRange.durationSeconds / clip.speed
                clip.timelineRange = try Self.range(start: clip.timelineRange.startSeconds, duration: nextDuration)
                for index in clip.keyframeTracks.indices { for key in clip.keyframeTracks[index].keyframes.indices { clip.keyframeTracks[index].keyframes[key].time = try Self.time(clip.keyframeTracks[index].keyframes[key].time.seconds * factor) } }
                if selected.track.kind == .visual { actions.append(contentsOf: try linkedSourceAudioActions(for: clip, timeScale: factor)) }
            case "video.fades": guard selected.track.kind == .audio else { throw MediaV2CommandError.unavailable }
                clip.fadeIn = try Self.time(min(clip.timelineRange.durationSeconds, max(0, input.number ?? 0))); clip.fadeOut = try Self.time(min(clip.timelineRange.durationSeconds, max(0, input.secondary ?? 0)))
            case "video.pip", "video.video-transform", "video.keyframes", "video.easing", "video.graph":
                guard selected.track.kind == .visual else { throw MediaV2CommandError.unavailable }
                let property = input.property ?? "scale", local = max(0, min(clip.timelineRange.durationSeconds, input.start ?? cursor - clip.timelineRange.startSeconds))
                guard ["scale", "centerX", "centerY", "rotationDegrees", "opacity"].contains(property) else { throw MediaV2CommandError.invalidInput }
                let value = input.number ?? (id == "video.pip" ? 0.4 : 1)
                let interpolation = MediaKeyframeInterpolation(rawValue: input.text ?? "") ?? (id == "video.easing" ? .easeIn : id == "video.graph" ? .cubicBezier : .linear)
                let curve: MediaCubicBezier?
                if let points = input.points {
                    guard points.count == 2 else { throw MediaV2CommandError.invalidInput }
                    curve = .init(control1:points[0],control2:points[1]);try curve?.validate()
                } else { curve = nil }
                let key = MediaKeyframe(time: try Self.time(local), value: .number(value),
                    interpolation: interpolation,curve:curve)
                let propertyName = clip.keyframeTracks.first { $0.property == property || $0.property == "transform." + property }?.property ?? property
                var keys = clip.keyframeTracks.first { $0.property == propertyName }?.keyframes ?? []
                keys.removeAll { abs($0.time.seconds - local) < 0.00001 }; if input.flag != false { keys.append(key) }; keys.sort { $0.time < $1.time }
                clip.keyframeTracks.removeAll { $0.property == propertyName }
                if !keys.isEmpty { clip.keyframeTracks.append(.init(property: propertyName, keyframes: keys)) }
            case "video.video-mask", "video.video-feather":
                guard selected.track.kind == .visual else { throw MediaV2CommandError.unavailable }
                if input.flag == false { clip.videoMask = nil }
                else if id == "video.video-mask" { clip.videoMask = .init(shapes: [.init(kind: input.property == "rectangle" ? .rectangle : .ellipse, points: input.points ?? [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.9)])]) }
                else { guard var mask = clip.videoMask else { throw MediaV2CommandError.missingSelection }; mask.feather = min(0.5, max(0, (input.number ?? 12) / Double(min(document.canvas!.width, document.canvas!.height)))); clip.videoMask = mask }
            case "video.transition":
                guard let previous = selected.track.clips.filter({ $0.id != clip.id && $0.timelineRange.startSeconds < clip.timelineRange.startSeconds }).max(by: { $0.timelineRange.startSeconds < $1.timelineRange.startSeconds }) else { throw MediaV2CommandError.invalidInput }
                let duration = min(input.number ?? 0.5, min(previous.timelineRange.durationSeconds, clip.timelineRange.durationSeconds) / 2)
                clip.leadingTransition = .crossDissolve; clip.transitionDuration = try Self.time(duration)
                clip.timelineRange = try Self.range(start: max(0, previous.timelineRange.endSeconds - duration), duration: clip.timelineRange.durationSeconds)
            case "video.split":
                let at = input.start ?? cursor, offset = at - clip.timelineRange.startSeconds
                guard offset > 0, offset < clip.timelineRange.durationSeconds else { throw MediaV2CommandError.invalidInput }
                var right = clip; right.id = UUID(); right.revision = 0
                right.timelineRange = try Self.range(start: at, duration: clip.timelineRange.durationSeconds - offset)
                let rightSource = try MediaSourcePlaybackMath.sourceTrim(sourceStart: clip.sourceRange.startSeconds,
                    sourceDuration: clip.sourceRange.durationSeconds, speed: clip.speed, offset: offset,
                    duration: right.timelineRange.durationSeconds, playback: clip.sourcePlayback)
                right.sourceRange = try Self.range(start: rightSource.start, duration: rightSource.duration)
                let leftSource = try MediaSourcePlaybackMath.sourceTrim(sourceStart: clip.sourceRange.startSeconds,
                    sourceDuration: clip.sourceRange.durationSeconds, speed: clip.speed, offset: 0,
                    duration: offset, playback: clip.sourcePlayback)
                clip.timelineRange = try Self.range(start: clip.timelineRange.startSeconds, duration: offset)
                clip.sourceRange = try Self.range(start: leftSource.start, duration: leftSource.duration)
                right.keyframeTracks = try slicedKeyframes(selected.clip.keyframeTracks, from: offset, duration: right.timelineRange.durationSeconds)
                clip.keyframeTracks = try slicedKeyframes(selected.clip.keyframeTracks, from: 0, duration: offset)
                if let fade = clip.fadeOut { clip.fadeOut = try Self.time(min(offset, fade.seconds)) }
                if let fade = right.fadeIn { right.fadeIn = try Self.time(min(right.timelineRange.durationSeconds, fade.seconds)) }
                right.leadingTransition = .none; right.transitionDuration = nil
                actions.append(.insertClip(trackID: selected.track.id, clip: right, index: nil))
                if selected.track.kind == .visual {
                    actions.append(contentsOf: try linkedSourceAudioActions(for: clip))
                    for track in document.trackGraph.tracks where track.kind == .audio {
                        for source in track.clips where source.sourceVisualClipID == clip.id {
                            var sound = source; sound.id = UUID(); sound.revision = 0; sound.sourceVisualClipID = right.id
                            sound.timelineRange = right.timelineRange; sound.sourceRange = right.sourceRange
                            sound.sourcePlayback = right.sourcePlayback; sound.fadeIn = nil
                            if let fade = sound.fadeOut { sound.fadeOut = try Self.time(min(fade.seconds,right.timelineRange.durationSeconds)) }
                            actions.append(.insertClip(trackID: track.id, clip: sound, index: nil))
                        }
                    }
                }
            default: throw MediaV2CommandError.unavailable
            }
            try replace(clip)
        }
        let commit = actions.isEmpty ? nil : try await apply(actions.map { .init(action: $0) }, expectedRevision: input.expectedRevision, actor: actor)
        return .init(documentID: document.id, revision: document.revision, toolID: id, groupID: commit?.groupID, selectionOnly: selectionOnly)
    }
}
#endif
