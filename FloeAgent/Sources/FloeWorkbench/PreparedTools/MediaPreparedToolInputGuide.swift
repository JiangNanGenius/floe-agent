// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct MediaPreparedToolInputExample: Codable,Sendable {
    public let toolID: String
    public let executionTool: String
    public let inputJSON: String?
    public let requiresSelectionFence: Bool
    public let guidance: String
    public let unavailableReason: String?
}
/// Executable examples are derived from an actual document revision and real
/// object IDs. This performs no editor selection, file read or mutation.
public enum MediaPreparedToolInputGuide {
    public static func make(document: MediaPreparedDocument,implementedToolIDs: Set<String>,selectionFence: String? = nil,hasImageRegion: Bool = false,hasRenderedImagePreview: Bool = false) throws -> [MediaPreparedToolInputExample] {
        var result = [MediaPreparedToolInputExample]()
        let layer = document.layers.first { !$0.isLocked && $0.isVisible && $0.parentID == nil && ![MediaPreparedLayerContentKind.group,.adjustment].contains($0.contentKind) }
        let visuals = document.trackGraph.tracks.filter{$0.kind == .visual && !$0.isLocked}.flatMap(\.clips)
        let visual = visuals.first
        let video = visuals.first{$0.assetID.flatMap{document.asset($0)?.kind} == .video}
        let audio = document.trackGraph.tracks.filter{$0.kind == .audio && !$0.isLocked}.flatMap(\.clips).first
        let caption = document.trackGraph.tracks.first{$0.kind == .caption && !$0.isLocked && !$0.clips.isEmpty}
        let textLayer=document.layers.first{!$0.isLocked && $0.parentID==nil && $0.contentKind == .text && $0.mask==nil && $0.clip==nil && $0.adjustment.isIdentity}
        let nativePaths=document.layers.filter{$0.parentID==nil && $0.contentKind == .vectorPaths && $0.mask==nil && $0.clip==nil && $0.adjustment.isIdentity}
        let shapes=nativePaths.filter{if case .vectorPaths(let path)=$0.content { !$0.isLocked && path.fillColorHex != nil && path.subpaths.allSatisfy(\.isClosed) } else { false }}
        let textPath=nativePaths.first{if case .vectorPaths(let path)=$0.content { path.subpaths.count==1 } else { false }}
        let providerIDs: Set<String> = ["image.inpaint","image.outpaint","video.transcribe","video.translate","video.voice-separate"]
        func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
        func add(_ id: String,_ values: [String:Any] = [:],target: UUID? = nil,requiresTarget: Bool = true,selection: Bool = false,fenceOnly: Bool = false,unavailableReason: String? = nil,_ guidance: String) throws {
            guard implementedToolIDs.contains(id),id.hasPrefix(document.kind == .image ? "image.":"video.") else { return }
            var object = values;object["expectedRevision"] = String(document.revision)
            if let target { object["objectID"] = target.uuidString }
            let needsFence = selection || fenceOnly
            if needsFence,let selectionFence { object["selectionFence"] = selectionFence }
            let missing = unavailableReason ?? (requiresTarget && target == nil ? "No editable matching source object. Unlock, import or create it, then read again."
                : selection && (selectionFence == nil || !hasImageRegion) ? "Create the required native selection and read again for its actual selectionFence."
                : needsFence && selectionFence == nil ? "Read the existing native session for its current selectionFence before changing its selection state." : nil)
            let bytes = missing == nil ? try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) : nil
            result.append(.init(toolID:id,executionTool:providerIDs.contains(id) ? "studio.media.provider":"studio.media",inputJSON:bytes.map{String(decoding:$0,as:UTF8.self)},requiresSelectionFence:needsFence,
                guidance:guidance+" Example IDs demonstrate the input shape; choose the actual object required by the user's task. Always use a fresh revision.",unavailableReason:missing))
        }
        let line: [[String:Double]] = [["x":0.3,"y":0.3],["x":0.55,"y":0.5],["x":0.7,"y":0.55]]
        let strokeLayer = document.layers.first { !$0.isLocked && $0.isVisible && $0.parentID == nil && $0.contentKind == .strokes }
        let rasterLayer = document.layers.first { candidate in
            guard !candidate.isLocked, candidate.isVisible, candidate.parentID == nil,
                  case .raster(let raster) = candidate.content, case .asset(let id) = raster.source else { return false }
            return document.asset(id)?.kind == .image
        }
        let groupMembers = document.layers.filter { !$0.isLocked && $0.isVisible && $0.parentID == nil }.prefix(2)
        try add("image.rectangle", ["points":[["x":0.2,"y":0.2],["x":0.7,"y":0.7]],"property":"replace"], requiresTarget:false,
                "Creates a native rectangular selection, not new pixels or a layer. points are two user-chosen opposite corners in normalized top-left canvas coordinates. Replace needs no prior selection; add/subtract needs the actual current selectionFence. Example corners are only an input shape, never an inferred target.")
        try add("image.brush", ["points":line,"number":12,"color":"#3366FF"], target:strokeLayer?.id, requiresTarget:false,
                "points are the actual requested stroke in normalized canvas coordinates; number=diameter in canvas pixels. An explicit objectID must be a real unlocked strokes layer; omit it to create a new editable drawing layer. Never target a raster/text layer expecting destructive paint. Original layers remain unchanged.")
        var eraserValues: [String:Any] = ["points":line,"number":12,"flag":false]
        if hasImageRegion, let selectionFence { eraserValues["selectionFence"] = selectionFence }
        try add("image.eraser", eraserValues, target:layer?.id,
                "objectID is the actual editable layer. points are a normalized canvas stroke; number=diameter in canvas pixels; flag=false erases, true restores the existing mask. This is a non-destructive layer mask. The example includes selectionFence only when an actual native region exists; otherwise it affects the full stroke, not an invented selection.")
        try add("image.crop", ["points":[["x":0.05,"y":0.05],["x":0.95,"y":0.95]]], target:rasterLayer?.id,
                unavailableReason:rasterLayer == nil ? "Import an unlocked image asset layer before cropping; solid-color, vector and text layers are not crop sources." : nil,
                "objectID is the real raster asset layer. Two points specify source-normalized opposite crop corners; these example corners do not identify an object. property=canvas instead uses normalized canvas coordinates. flag=false removes the crop. Source bytes remain intact, with journal undo.")
        let savedText: ImageTextContent? = textLayer.flatMap { if case .text(let content) = $0.content { content } else { nil } }
        try add("image.text", ["text":savedText?.text ?? "Text","number":savedText?.fontSize ?? 72,"color":savedText?.colorHex ?? "#3366FF"], target:textLayer?.id, requiresTarget:false,
                "An actual text-layer objectID updates that layer while preserving its other style. Omit objectID to create a new text layer; never supply another layer type. text is content and number is font size in canvas pixels. Use the requested text, not this example's existing/default content.")
        try add("image.shape", ["points":[["x":0.2,"y":0.2],["x":0.7,"y":0.2],["x":0.7,"y":0.7],["x":0.2,"y":0.7]],"number":3,"color":"#3366FF"], requiresTarget:false,
                "Creates a new editable closed vector shape. Omit objectID; points are the requested normalized canvas vertices, number is stroke width in canvas pixels, color is fill and stroke. Example vertices demonstrate format only.")
        try add("image.duplicate-layer", target:layer?.id,
                "objectID is the real layer to duplicate. Copies editable content (and a group's descendants) to new layer IDs, retaining original source assets and one undo group. It does not modify the original.")
        try add("image.group-layer", ["objectIDs":groupMembers.map { $0.id.uuidString }], target:groupMembers.first?.id,
                unavailableReason:groupMembers.isEmpty ? "Create or unlock at least one actual layer before grouping it." : nil,
                "objectIDs are the actual unlocked sibling layer IDs to group, not asset IDs. The example uses existing root layers; select the layers required by the user. flag=false with a real group objectID ungroups it. Grouping retains editable children and journal undo.")
        for id in ["image.ellipse", "image.lasso", "image.polygon"] {
            let points = id == "image.ellipse" ? [["x":0.2,"y":0.2],["x":0.7,"y":0.7]] : [["x":0.2,"y":0.2],["x":0.7,"y":0.3],["x":0.4,"y":0.7]]
            try add(id, ["points":points,"property":"replace"], requiresTarget:false,
                    "Creates native selection geometry, not pixels. Ellipse uses two normalized opposite corners; lasso/polygon need at least three normalized canvas points. property=replace/add/subtract; add/subtract requires the actual current selectionFence. Example points only show format, not a detected subject.")
        }
        try add("image.feather", ["number":12], requiresTarget:false, selection:true,
                unavailableReason:document.canvas == nil ? "The original needs a valid canvas before feathering a selection." : nil,
                "Feathers the actual native selection; number is radius in original canvas pixels. Keep its current selectionFence. This changes selection state only, not the stored source image.")
        for id in ["image.inverse", "image.deselect"] {
            try add(id, requiresTarget:false, fenceOnly:true,
                    "Uses the actual current native selectionFence and changes selection state only. inverse toggles the region's inversion (an empty selection may become the full canvas); deselect clears it. A nonempty region is not required, but an actual native session fence is.")
        }
        try add("image.fill", ["color":"#3366FF"], requiresTarget:false, selection:hasImageRegion,
                "Creates a new editable solid-color layer. With an actual native region, include its selectionFence to mask the fill; without a region this fills the canvas. Omit objectID; color is explicit RGB/RGBA, not an inferred palette value.")
        try add("image.adjustment-layer", ["number":0], requiresTarget:false,
                "Creates a new editable adjustment layer; number is its initial exposureEV (default0). Omit objectID. Later color controls update the actual new layer ID from a fresh read.")
        for id in ["image.layer-mask", "image.vector-mask"] {
            let remove = !hasImageRegion && layer?.mask != nil
            try add(id, ["flag":!remove], target:layer?.id, selection:!remove,
                    "Applies the actual native region as this layer's non-destructive mask with flag=true and its current selectionFence. flag=false removes an existing mask from the explicit target without requiring a region. The example removes only when there is no native region and this actual layer already has a mask.")
        }
        let roots = document.layers.filter { $0.parentID == nil }
        let clipIndex = roots.indices.dropFirst().first { index in
            !roots[index].isLocked && roots[index].isVisible && roots[index].contentKind != .adjustment &&
                roots[index - 1].isVisible && roots[index - 1].contentKind != .adjustment
        }
        let clipLayer = clipIndex.map { roots[$0] }
        try add("image.clip-mask", ["flag":true], target:clipLayer?.id,
                unavailableReason:clipLayer == nil ? "Create an unlocked target above an actual sibling layer before enabling a clipping mask." : nil,
                "objectID is the actual target; flag=true clips it to the immediately preceding saved sibling layer. Read current order before choosing the target. flag=false removes only the clipping link and does not need a base layer.")
        let groupLayer = document.layers.first { !$0.isLocked && $0.isVisible && $0.contentKind == .group }
        try add("image.blend-mode", ["property":"multiply"], target:groupLayer?.id,
                unavailableReason:groupLayer == nil ? "Create or unlock a native group layer before changing its group blend mode." : nil,
                "objectID must be a real group. property=normal/multiply/screen/overlay/darken/lighten. This route changes group compositing, not an arbitrary raster layer's blend mode.")
        try add("image.align", ["property":"center"], target:layer?.id,
                "Aligns the actual objectID in canonical canvas space. property=centerX/centerY/center; optional objectIDs is the complete real layer set to align. Source content and journal undo are preserved.")
        let mergePair = document.layers.indices.dropLast().lazy.compactMap { index -> [MediaPreparedLayer]? in
            let pair = [document.layers[index], document.layers[index + 1]]
            let ids = Set(pair.map(\.id))
            guard pair.allSatisfy({ $0.parentID == nil && !$0.isLocked && $0.isVisible && $0.contentKind != .group }),
                  !document.layers.contains(where: { !ids.contains($0.id) && $0.clip.map { ids.contains($0.baseLayerID) } == true }) else { return nil }
            return pair
        }.first
        try add("image.merge-layer", ["objectIDs":mergePair?.map { $0.id.uuidString } ?? []], requiresTarget:false,
                unavailableReason:mergePair == nil ? "Select at least two adjacent unlocked top-level non-group layers with no outside clipping dependency before merging." : nil,
                "objectIDs are actual contiguous unlocked top-level layer IDs, not arbitrary groups or asset IDs. Their sources must resolve. Renders this exact set into one new image layer through the existing native transaction; originals remain available by undo.")
        try add("image.pen", ["points":line,"number":3,"color":"#3366FF"], requiresTarget:false,
                "Creates a new editable open vector path from explicit normalized canvas points; number=stroke width in canvas pixels, color=stroke. Omit objectID. This is the existing straight-segment path route, not freehand raster paint or implicit Bezier fitting.")
        let anchorLayer = nativePaths.first { candidate in
            guard !candidate.isLocked, candidate.isVisible, case .vectorPaths(let path) = candidate.content,
                  path.subpaths.count == 1, let subpath = path.subpaths.first,
                  !subpath.isClosed, subpath.points.count >= 2, path.fillColorHex == nil,
                  path.strokeColorHex != nil, path.strokeWidth > 0,
                  path.lineCap == .round, path.lineJoin == .round, path.fillRule == .nonZero, path.opacity == 1 else { return false }
            return subpath.points.allSatisfy { $0.controlIn == nil && $0.controlOut == nil }
        }
        let anchorPath: MediaVectorPath? = anchorLayer.flatMap { if case .vectorPaths(let path) = $0.content { path } else { nil } }
        try add("image.anchor", ["points":anchorPath?.subpaths.first?.points.map { ["x":$0.point.x,"y":$0.point.y] } ?? [],"number":anchorPath?.strokeWidth ?? 3,"color":anchorPath?.strokeColorHex ?? "#3366FF"], target:anchorLayer?.id,
                unavailableReason:anchorLayer == nil ? "This anchor route replaces a complete open straight path. Create or select that native path; it cannot preserve unmentioned closed contours or Bezier handles." : nil,
                "objectID is the actual open straight path. Supply its COMPLETE normalized point list, including unchanged anchors, plus intended stroke width/color. This replaces its path content; it is not a one-anchor patch. The example copies real vertices and retains represented style rather than inventing a new shape.")
        let styledPath = nativePaths.first { !$0.isLocked && $0.isVisible }
        try add("image.stroke-fill", ["color":"#3366FF","number":3], target:styledPath?.id,
                unavailableReason:styledPath == nil ? "Create or unlock an actual native vector path before changing its fill and stroke width." : nil,
                "objectID is a real vectorPaths layer. color sets its fill; number sets stroke width in canvas pixels. Existing path geometry, stroke color and unrelated layer controls are retained.")
        for id in ["image.rotate", "image.flip"] {
            let values: [String:Any] = id == "image.rotate" ? ["number":90] : ["property":"horizontal"]
            try add(id, values, target:layer?.id,
                    "Uses an actual layer objectID. rotate adds number degrees (default90). flip toggles vertical when property=vertical, otherwise horizontal. This is a non-destructive layer transform, not a canvas resize.")
        }
        for id in ["image.exposure", "image.levels", "image.hsl", "image.white-balance", "image.bw"] {
            let values: [String:Any]
            switch id {
            case "image.exposure": values = ["number":0.5]
            case "image.levels": values = ["number":0.05,"secondary":0.95]
            case "image.hsl": values = ["number":1.1,"secondary":10]
            case "image.white-balance": values = ["number":6500]
            default: values = [:]
            }
            try add(id, values, target:layer?.id,
                    "Updates real layer color controls. exposure: number=EV; levels: number=black, secondary=white, gamma stays1; hsl: number=saturation, secondary=hue degrees, no separate lightness in this route; white-balance: number=temperature; bw: saturation becomes0 without numeric parameters. Other controls and source pixels are preserved.")
        }
        try add("image.eyedropper", ["points":[["x":0.5,"y":0.5]]], requiresTarget:false, fenceOnly:true,
                unavailableReason:!hasRenderedImagePreview ? "Wait for the existing native image preview, then read again before sampling its actual pixels." : nil,
                "Samples the ACTUAL rendered preview at the requested normalized point, not a guessed color. After the call, studio.read returns the actual current palette as liveSelection.media.paletteColorHex. The native palette changes; the document and selectionFence do not. Example point only shows the input shape.")
        let unusedAsset = document.assets.first { MediaPreparedAssets.references(to: $0.id, in: document).isEmpty }
        try add(document.kind == .image ? "image.remove-asset" : "video.remove-asset", target: unusedAsset?.id,
                unavailableReason: unusedAsset == nil ? "No unused project asset. Remove its layer, clip or compound uses first; original sources remain protected." : nil,
                "objectID is the exact asset UUID from the current document, not a layer/clip UUID or file path. Removes only an unused project asset through the canonical journal. In-use and opaque content refuse; original/backing files remain available for undo and recovery.")
        let curve: [ImageFreehandStroke.Point] = [.init(x:0,y:0),.init(x:0.25,y:0.3),.init(x:0.5,y:0.6),.init(x:0.75,y:0.85),.init(x:1,y:1)]
        try add("image.boolean",["objectIDs":shapes.prefix(2).map{$0.id.uuidString},"property":"union"],target:shapes.first?.id,unavailableReason:shapes.count<2 ? "Create two unlocked filled closed vector shapes, then read again.":nil,"Real editable filled-path Boolean geometry. objectIDs2...16 are actual shape UUIDs, objectID optionally chooses the primary shape/style; property=union/subtract/intersect/xor. Subtract removes other shapes from the primary. Masks/grades/groups need separate editing first. Empty intersections are truly empty and remain undoable.")
        let savedTextPath:MediaTextPathLayout? = textLayer.flatMap { if case .text(let text)=$0.content { text.pathLayout } else { nil } }
        var pathTextValues:[String:Any] = ["number":savedTextPath?.startOffset ?? 0,"secondary":savedTextPath?.normalOffset ?? 0,"flag":savedTextPath?.isReversed ?? false]
        if let textPath { pathTextValues["property"]=textPath.id.uuidString }
        try add("image.path-text",pathTextValues,target:textLayer?.id,unavailableReason:textPath==nil && savedTextPath==nil ? "Create one continuous vector path, then read again.":nil,"objectID is the actual text layer; property is a real vector-path layer UUID. number=start offset in path pixels; secondary=baseline offset pixels; flag=reverse path direction. Optional text edits the text while retaining its font/style. Text stays editable and saves a geometry snapshot, so deleting the source path is safe. Omit property to reuse an already saved path. The complete line must fit; reduce font size or extend the path if it does not.")
        try add("image.outline",target:textLayer?.id,"Converts actual shaped glyphs including fallback fonts to editable Bezier paths. Original text is restored by undo. Color emoji, unresolved glyphs, overflow, masks/shadow/grades are explicitly refused rather than silently dropped.")
        try add("image.resize",["number":document.canvas?.width ?? 1600,"secondary":document.canvas?.height ?? 1200],requiresTarget:false,"number=width and secondary=height in integer pixels. Applies a canonical non-destructive whole-document image-size transaction with layer hierarchy/masks/undo preserved. Locked model targets remain protected.")
        try add("image.canvas-size",["number":document.canvas?.width ?? 1600,"secondary":document.canvas?.height ?? 1200,"points":[["x":0.5,"y":0.5]]],requiresTarget:false,"number=canvas width, secondary=height in integer pixels; points[0]=top-leading anchor0...1 (default center). Extends/crops boundaries while retaining existing pixel geometry, editable layers and original sources.")
        for id in ["image.perspective","image.distort"] {
            try add(id,["property":"inspect"],target:layer?.id,"First inspect the ACTUAL rendered layer alpha/selection bounds. It returns imageWarp.source (width/height/contentBounds/sourceQuad/pixelSHA256/coverageSHA256). Then apply using the SAME actual target/revision, property=apply, text=that pixelSHA256, points=exactly four destination canvas-normalized top-leading points in TL/TR/BR/BL source-corner order. Destination may extend off-canvas within -4...4 and is clipped to the canvas. Quad must be convex, no crossed/degenerate edges. image.perspective uses true projective Core Image; image.distort uses true bilinear interpolation, not the same renamed transform. Add actual selectionFence from studio.read to move a selection/holes; omit for the whole layer. The transform keeps source assets and saves through the same revision/CAS/undo group. An inspect request does not mutate. Never invent the source digest or use arbitrary full-canvas corners for a small source.")
        }
        try add("image.wand",["points":[["x":0.4,"y":0.4]],"number":0.1,"flag":true,"property":"replace"],target:layer?.id,"points[0] is normalized x/y; number=tolerance0...1; flag=contiguous; property=replace/add/subtract. Add/subtract additionally needs selectionFence.")
        try add("image.subject",target:layer?.id,"Select the actual foreground subject on this individual layer.")
        for id in ["image.refine-edge","image.expand","image.smooth"] {
            try add(id,["number":4],requiresTarget:false,selection:true,"number is radius in canvas pixels. image.expand supports negative radius to contract. Native coverage and holes are retained.")
        }
        try add("image.gradient",["points":[["x":0.1,"y":0.1],["x":0.9,"y":0.9]],"color":"#3366FF","text":"#FFFFFF","number":1,"flag":false],target:layer?.id,"Two normalized endpoints; color/text are endpoint colors; number=opacity0...1; flag=radial. Add selectionFence to limit an existing selection.")
        for id in ["image.smudge","image.blur-brush","image.sharpen-brush"] {
            try add(id,["points":line,"number":16,"secondary":id == "image.smudge" ? 0.5:12],target:layer?.id,"points is a normalized stroke; number=diameter in canvas pixels. secondary is smudge strength0...1, blur radius0...200, or sharpen amount0...200 respectively.")
        }
        try add("image.clone",["points":line,"number":16,"secondary":0.7,"flag":false],target:layer?.id,"points[0] is source anchor; remaining points are destination stroke. number=diameter px; secondary=strength0...1; flag=false selects a soft brush.")
        for id in ["image.remove","image.content-fill"] {
            try add(id,["property":"adaptive","number":0,"secondary":1,"flag":true],target:layer?.id,selection:true,"Local exemplar synthesis requires the real native selection. property=adaptive/texture; number=explicit selection-edge expansion0...12px (default0); secondary=quality0fast/1balanced/2detailed; flag=sample nearby (false=full layer). Optional points[0...1] are normalized opposite corners restricting donor sampling, not the target selection. Up to8MP image and65536 selected pixels; no text prompt. Preserve all zero-coverage pixels and holes; original pixels stay available by undo.")
        }
        try add("image.heal",["points":line,"number":12,"secondary":1],target:layer?.id,"points[0] is source anchor, remaining normalized points are repair stroke. number=diameter px; secondary=repair mix0...1; real source-gradient blending preserves texture.")
        try add("image.patch",["points":[["x":0.25,"y":0.25]],"secondary":1],target:layer?.id,selection:true,"A native selection is required. One normalized point is source center, or two points are destination drag start/end. secondary=repair mix0...1.")
        try add("image.layer-effect",["number":3,"secondary":8,"color":"#FFFFFF","text":"#00000080","points":[["x":8,"y":8]],"flag":true],target:layer?.id,"number=outline width px; secondary=shadow blur px; color=outline; text=shadow RGBA. points[0] is shadow offset in PIXELS with y down, not normalized. flag enables shadow.")
        try add("image.background",target:layer?.id,"Remove actual foreground-excluded pixels to transparency, retaining the original source asset.")
        try add("image.curves",["adjustment":["toneCurve":try encoded(curve)]],target:layer?.id,"Exactly five ordered normalized toneCurve x/y points. Optional channelCurves.red/green/blue use the same five-point form. Edits save live parameters on the selected layer or adjustment layer; source pixels stay unchanged.")
        try add("image.balance",["adjustment":["colorBalance":try encoded(ImageColorBalance(midtones:.init(red:0.2,blue:-0.1)))]],target:layer?.id,"colorBalance has independent shadows/midtones/highlights RGB shifts in -1...1 and preserveLuminance.")
        try add("image.lut",["text":"CIPhotoEffectMono"],target:layer?.id,"text is a supported native preset or bounded full .cube text; adjustment.colorLUT is the typed Float32 RGBA form. Keep the overall256KiB tool input budget.")
        try add("image.denoise",["number":0.5,"secondary":20],target:layer?.id,"number=noise reduction0...1; secondary=sharpen0...100. Optional adjustment fields can provide the same values.")
        try add("image.inpaint",["text":"Replace the selected flowers with white daisies"],target:layer?.id,selection:true,"Cloud edit requires studio.media.provider authority, an existing selected area and prompt text. property optionally names an actual configured image model UUID; omission follows saved routing. Original pixels outside the mask are protected.")
        if let canvas=document.canvas,let layout=try? MediaOutpaintLayout(sourceWidth:canvas.width,sourceHeight:canvas.height,width:Int((Double(canvas.width)*1.25).rounded()),height:Int((Double(canvas.height)*1.25).rounded()),anchor:.init(x:0.5,y:0.5)) {
            try add("image.outpaint",["number":layout.width,"secondary":layout.height,"points":[["x":0.5,"y":0.5]],"text":"Extend the surrounding scene naturally"],requiresTarget:false,unavailableReason:document.layers.contains(where:{$0.parentID==nil && $0.isLocked}) ? "Unlock the protected root layer in the editor before requesting a model-driven canvas expansion.":nil,"Whole-image expansion: omit objectID. number=target width and secondary=height in integer pixels; neither may shrink and at least one must expand, up to8MP. points[0]=original-content top-leading anchor0...1. Requires studio.media.provider authority. Adds generated margins beneath intact original editable layers; a model with compatible output aspect ratio is required. property optionally names a configured image-model UUID.")
        } else {
            try add("image.outpaint", requiresTarget:false,
                    unavailableReason:document.canvas == nil ? "The original needs a valid canvas before expansion." : "The proposed canvas expansion exceeds the existing8MP/8192px bounds or cannot expand an edge. Use a smaller source or a valid explicit target size.",
                    "Uses the existing task-authorized image provider route. Target dimensions may not shrink and must expand at least one edge within8MP/8192px. No placeholder expansion or silent row omission is used when a safe example cannot be proposed.")
        }
        try add("video.reverse",["flag":true],target:video?.id,"Explicit source video clip. flag=true reverses, false restores forward playback; linked source audio follows.")
        try add("video.freeze",["start":video?.timelineRange.startSeconds ?? 0,"duration":2,"flag":true],target:video?.id,"start is absolute timeline seconds inside this video clip; duration is hold length seconds. flag=false restores ordinary source playback.")
        try add("video.chroma",["chromaKey":try encoded(MediaVideoChromaKey())],target:visual?.id,"chromaKey fields colorHex,tolerance,softness,spillSuppression are optional with semantic defaults. Numeric controls0...1. flag=false removes only chroma key.")
        try add("video.video-blend",["property":"screen","number":0.7],target:visual?.id,"property=normal/multiply/screen/overlay/darken/lighten/add/difference; number=opacity0...1. flag=false resets blend and opacity.")
        try add("video.graph",["property":"opacity","start":0,"number":0.5,"text":"cubicBezier","points":[["x":0.25,"y":0.1],["x":0.75,"y":1]]],target:visual?.id,"Add/update one key: start is CLIP-LOCAL seconds; number is property value; text=interpolation. Two normalized points are Bezier handles, not motion path. property=opacity/scale/centerX/centerY/rotationDegrees.")
        try add("video.motion-path",["points":line,"start":0,"duration":min(1,visual?.timelineRange.durationSeconds ?? 1)],target:visual?.id,"points2...512 are normalized canvas positions with actual path vertices retained; start/duration are clip-local seconds. Updates position keys only.")
        try add("video.motion-title",["text":"Title","number":48,"color":"#FFFFFF","start":0,"duration":3,"property":"fade"],requiresTarget:false,"Creates a native title clip when objectID is omitted; supply an existing title clip UUID to edit it. number=font size; property=motion preset. No placeholder image asset is needed.")
        try add("video.preset-motion",["text":"fade"],target:visual?.id,"text=fade/slide-left/rise/zoom-in/pulse/spin. Preserves unrelated animated properties.")
        try add("video.caption-style",["captionStyle":try encoded(CaptionStyle())],requiresTarget:false,"Complete typed CaptionStyle object affects the project's caption renderer; no text/start/duration/flag/points with caption-style.")
        try add("video.hdr",["property":"rec2020HLG"],requiresTarget:false,"Project-wide native color management: omit objectID for explicit profile. property=standard(nil/legacy sRGB SDR),rec709,rec2020HLG or rec2020PQ; flag=false restores legacy SDR. True HDR uses matched source dynamic range, wide floating frames and actual10-bit HEVC with verified2020/HLG orPQ properties; native preview/playback/export share the profile. Preserves originals/dimensions/frame rate and supports canvas-generation CAS/undo. property=source requires an actual source clip objectID (or fresh native selectionFence) and detects real transfer metadata, never a filename guess. Existing waveform/vectorscope remains an SDR preview measurement, not absolute HDR nits. HDR+transparent proxy depends on a genuinely supported writer combination and must never silently quantize to SDR.")
        let colorTarget = visuals.first { $0.assetID.flatMap { document.asset($0)?.kind }.map { $0 == .video || $0 == .image } == true }
        let colorReference = document.trackGraph.tracks.filter { $0.kind == .visual }.flatMap(\.clips).first { candidate in candidate.id != colorTarget?.id && candidate.assetID.flatMap { document.asset($0)?.kind }.map { $0 == .video || $0 == .image } == true }
        if let target = colorTarget,let colorReference {
            let referenceTime = colorReference.assetID.flatMap { document.asset($0)?.kind } == .image ? 0 : colorReference.sourceRange.startSeconds
            let targetTime = target.assetID.flatMap { document.asset($0)?.kind } == .image ? 0 : target.sourceRange.startSeconds
            try add("video.color-match",["property":colorReference.id.uuidString,"start":targetTime,"secondary":referenceTime,"number":1,"text":"color-and-contrast"],target:target.id,"objectID is the actual target clip; property is a distinct reference clip UUID, never a model or host path. start=target absolute source seconds; secondary=reference absolute source seconds (both0 for still images). number=mix0...1; text=color or color-and-contrast. Samples actual saved source grading/masks, matches measured Lab moments via the shared native pixel pipeline, snapshots the look, preserves other grades/source/undo. Later reference edits do not change captured correction; replacing target source requires re-sampling. flag=false clears matching only.")
        } else if implementedToolIDs.contains("video.color-match"),document.kind == .video {
            result.append(.init(toolID:"video.color-match",executionTool:"studio.media",inputJSON:nil,requiresSelectionFence:false,guidance:"Import/select an actual target and a distinct image/video reference clip, then studio.read again for their IDs. property is the reference clip UUID; start/secondary are absolute source times,0 for stills. flag=false clears matching on an existing target without needing its former reference.",unavailableReason:"No distinct target and reference source clips are available."))
        }
        if implementedToolIDs.contains("video.nest"),document.kind == .video {
            try add("video.nest",["property":"inspect"],requiresTarget:false,"First inspect this original for actual compound anchor IDs. To create use property=create and typed clipIDs:[actual video/caption/audio clip UUIDs], optional text=name. Existing linked source audio is retained automatically. Inspect an anchor with objectID=that UUID, property=inspect to read its full actual source IDs; all supported native tools can then operate inside it using compoundID=the anchor UUID plus the same current original expectedRevision and actual INNER objectID. This selects a scope in the same original, never another project or image objectIDs. property=refresh rebuilds the real transparent/audio proxy after inner edits; property=expand restores editable source clips when outer effects can be preserved. If outer trims/effects prevent safe expansion use property=restoreMutedCopy: keeps the current result/effects and restores actual editable source on muted tracks. Current source is saved on every edit, old proxy remains until verified replacement; no nested nesting. Source/import/save/undo use the canonical original coordinator.")
        }
        try add("video.tracking",["points":[["x":0.2,"y":0.2],["x":0.5,"y":0.5]],"number":0.3,"secondary":15],target:video?.id,"points are two corners of the actual object in the clip FIRST oriented SOURCE frame, normalized top-left. First use studio.run inspectFrame with expectedRevision and sourceClipID=this actual clip UUID; source seconds defaults to sourceRange.start. Use that upright source PNG and the user target; never infer an object from this example rectangle. number=minimum confidence0.05...0.95; secondary=sample fps1...30, capped by real source fps. Analyzes the source interval up to120s, saves actual observations/confidence/loss, preserves source/undo, returns tracking; does not move the video to its own object trajectory. property=clear removes tracking only.")
        try add("video.stabilize",["number":0.3,"secondary":1,"flag":true],target:video?.id,"Real sampled Vision translation registration, smoothed source-time correction, same preview/export path. number=smoothing window0.05...2s; secondary=strength0...1; flag=crop moving edges(defaulttrue). Source interval max120s, actual sampling15fps capped by source cadence. Excessive crop or scene cut fails, never silently clamps; property=clear removes stabilization only. Trim/reverse/speed keep source-time samples, extending or replacing source requires re-analysis.")
        try add("video.scopes",["start":visual?.timelineRange.startSeconds ?? 0],requiresTarget:false,"Read real rendered-frame waveform/vectorscope. start=absolute timeline seconds. Returns measured structured analysis without editing the document.")
        try add("video.eq",["audioProcessing":try encoded(MediaAudioProcessing(eqBands:[.init(frequency:1000,gain:3)]))],target:(audio ?? video)?.id,"Complete typed eqBands are provided, max8; each frequency20...20000Hz, gain-24...24dB, bandwidth0.05...5octaves. Visual video target resolves/extracts only its explicitly linked source audio.")
        try add("video.noise",["noiseReduction":["amount":0.8,"maximumReductionDB":18]],target:(audio ?? video)?.id,"Real native spectral noise reduction of this clip's source interval. Optional noiseReduction.noiseOnlyRange uses clip-local SOURCE seconds, startSeconds>=0 and durationSeconds>=2048/sourceSampleRate, entirely inside its source interval. Omit for automatic estimation. Keeps original source, speed/reverse, gain/fades/EQ and supports undo; output identity/measurements are returned. It is not a gate or a speech/ML separator.")
        let narration = document.trackGraph.tracks.filter { $0.kind == .audio && !$0.isLocked && !$0.isMuted && $0.volume > 0 }.flatMap(\.clips).first { candidate in
            candidate.id != audio?.id && !candidate.isMuted && candidate.sourcePlayback?.holdSeconds == nil && candidate.volume > 0 && audio.map { min($0.timelineRange.endSeconds,candidate.timelineRange.endSeconds) > max($0.timelineRange.startSeconds,candidate.timelineRange.startSeconds) } == true
        }
        if let audio,let narration {
            try add("video.duck",["property":narration.id.uuidString,"dialogueDucking":["reductionDB":12,"thresholdDB":-38]],target:audio.id,"objectID is the MUSIC audio clip, property is the distinct actual NARRATION clip UUID (not objectIDs/layer IDs). Both must overlap in timeline time; narration must be unmuted. Example IDs only demonstrate shape, not inferred content roles. Handles speed/reverse/time alignment, follows narration activity and recovers music. Full optional settings: kneeDB0.1...24, attackSeconds0.001...1, releaseSeconds0.01...5, holdSeconds0...2, lookAheadSeconds0...0.1. Original saved mix controls apply once, and undo restores the source.")
        } else if implementedToolIDs.contains("video.duck"),document.kind == .video {
            result.append(.init(toolID:"video.duck",executionTool:"studio.media",inputJSON:nil,requiresSelectionFence:false,guidance:"Choose the actual music and a distinct audible narration clip; objectID=music clip UUID, property=narration clip UUID. Read again after importing/unmuting clips.",unavailableReason:"No distinct audible narration and music pair overlaps on the timeline."))
        }
        try add("video.voice-separate",["voiceSeparation":["mode":"musicAI"]],target:(audio ?? video)?.id,"M55 voice separation. objectID is one unlocked audio clip (a visual clip's linked source audio resolves automatically). Optional voiceSeparation: {\"mode\":\"localModel\",\"modelID\":\"<installed artifact id>\"} runs the shared-store CoreML bundle ON-DEVICE and sends nothing to any provider; {\"mode\":\"musicAI\"} uses the user-configured Music.AI route, uploads ONLY the frozen selected source interval (<=128 MiB) and keeps the original. Omit voiceSeparation for automatic (installed local model first, then configured cloud). Both routes commit two new stems tracks plus muting the original as ONE undo group with real source-hash CAS; a timed-out owned cloud job resumes by its stored remote ID and is never re-created or double-paid. Separation quality is the model/provider output, not a local guarantee.")
        try add("video.compressor",["audioProcessing":try encoded(MediaAudioProcessing(dynamics:.init(),limiter:.init()))],target:(audio ?? video)?.id,"Typed dynamics and limiter; limiter ceilingDB-24...0, attackTime0.001...0.03s, decayTime0.001...0.06s. flag=false clears this processing only.")
        try add("video.video-curves",["videoGrade":["toneCurve":try encoded(curve)]],target:visual?.id,"Exactly five ordered normalized tone curve points. flag=false removes only curve, retaining other saved grades.")
        try add("video.wheels",["videoGrade":["colorBalance":try encoded(ImageColorBalance(midtones:.init(red:0.2,blue:-0.1)))]],target:visual?.id,"Shadow/midtone/highlight shifts are each red/green/blue in -1...1; preserveLuminance defaults true. flag=false removes only the wheels.")
        try add("video.video-hsl",["videoGrade":["secondary":try encoded(MediaHSLSecondary(hueShift:30))]],target:visual?.id,"secondary qualifies circular hueCenter0...360,hueWidth/Feather0...180 plus saturation/lightness min/max0...1 and rangeFeather. Only qualified pixels get hueShift-180...180,saturationScale0...2,lightnessShift-1...1,mix0...1.")
        try add("video.video-lut",["text":"CIPhotoEffectMono"],target:visual?.id,"Use text preset or videoGrade.colorLUT typed data. colorLUT and filterID cannot coexist. flag=false removes only LUT; overall tool input remains256KiB.")
        try add("video.transcribe",target:(audio ?? video)?.id,"Requires studio.media.provider authority and a real forward audio/video source clip. Uses sourceRange only, maps timestamps through speed, and creates a new caption track without overwriting existing captions.")
        try add("video.translate",["text":"English"],target:caption?.id,"Requires studio.media.provider authority. objectID is a caption track (all clips) or caption clip UUID. text=target language. Creates a translated track preserving original IDs as provenance, original timing and source text.")
        return result.sorted{$0.toolID<$1.toolID}
    }
}
