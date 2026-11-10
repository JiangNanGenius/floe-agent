// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreImage
import FloeWorkbench

extension MediaV2Session {
    static let nativePaintTools: Set<String> = ["image.heal","image.patch","image.smudge","image.clone","image.gradient","image.blur-brush","image.sharpen-brush","image.layer-effect"]
    static let nativePaintStrokeTools: Set<String> = ["image.heal","image.patch","image.smudge","image.clone","image.gradient","image.blur-brush","image.sharpen-brush"]
    static func usesDirectStroke(_ tool:String) -> Bool {
        MediaDrawingInputPolicy.isStrokeTool(tool) || nativePaintStrokeTools.contains(tool)
    }
    func applyNativePaint(_ id:String,input:MediaV2ToolInput,layer:MediaPreparedLayer?,region:ImageSelection?,actor:MediaPreparedActorKind,
                          base:Int64,originalSelection:ImageSelection?) async throws -> MediaV2ToolReceipt {
        guard let layer,!layer.isLocked,let canvas = document.canvas else { throw MediaV2CommandError.missingSelection }
        let image = try await renderedLayerImage(layer,revision:base)
        let opacity = brushOpacity,hardness = input.flag.map { $0 ? 1.0 : 0.0 } ?? brushHardness,firstColor = input.color ?? colorHex
        let worker = Task.detached(priority:.userInitiated) {
            var output: CGImage
            switch id {
            case "image.heal","image.patch":
                guard let points = input.points,let first = points.first else { throw MediaV2CommandError.invalidInput }
                let amount = input.secondary ?? 1
                guard amount.isFinite,(0...1).contains(amount) else { throw MediaV2CommandError.invalidInput }
                if id == "image.heal" {
                    guard points.count>=2 else { throw MediaV2CommandError.invalidInput }
                    output = try MediaNativePatchBlend.healStroke(image,points:Array(points.dropFirst()),width:input.number ?? 24,sourceAnchor:first)
                } else {
                    guard let region else { throw MediaV2CommandError.missingSelection }
                    if points.count == 1 { output = try MediaNativePatchBlend.patch(image,selection:region,sourceCenter:first) }
                    else if points.count == 2 { output = try MediaNativePatchBlend.patchDragging(image,selection:region,from:points[0],to:points[1]) }
                    else { throw MediaV2CommandError.invalidInput }
                }
                if amount<1 {
                    let blended = CIImage(cgImage:image).applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:CIImage(cgImage:output),kCIInputTimeKey:amount])
                    guard let result = CIContext(options:[.cacheIntermediates:false]).createCGImage(blended,from:.init(x:0,y:0,width:canvas.width,height:canvas.height)) else { throw MediaV2CommandError.invalidInput }
                    output = result
                }
            case "image.smudge","image.clone":
                guard let points = input.points else { throw MediaV2CommandError.invalidInput }
                if id == "image.clone" {
                    guard let source = points.first,points.count>=2 else { throw MediaV2CommandError.invalidInput }
                    output = try MediaNativeSampleBrush.render(image,points:Array(points.dropFirst()),width:input.number ?? 24,
                        strength:input.secondary ?? 0.7,hardness:hardness,mode:.clone(source:source))
                } else {
                    output = try MediaNativeSampleBrush.render(image,points:points,width:input.number ?? 24,
                        strength:input.secondary ?? 0.7,hardness:hardness,mode:.smudge)
                }
            case "image.gradient":
                guard let points = input.points,points.count == 2 else { throw MediaV2CommandError.invalidInput }
                output = try MediaNativePaintEffects.gradient(image,from:points[0],to:points[1],firstColor:firstColor,
                    lastColor:input.text ?? "#FFFFFF",opacity:input.number ?? 1,radial:input.flag ?? false)
            case "image.blur-brush","image.sharpen-brush":
                guard let points = input.points else { throw MediaV2CommandError.invalidInput }
                output = try MediaNativePaintEffects.filteredStroke(image,points:points,width:input.number ?? 24,
                    amount:input.secondary ?? (id == "image.blur-brush" ? 12 : 30),opacity:opacity,
                    filter:id == "image.blur-brush" ? .blur : .sharpen)
            default:
                output = try MediaNativePaintEffects.layerEffects(image,outlineWidth:input.number ?? 3,outlineColor:firstColor,
                    shadowRadius:input.secondary ?? 8,shadowColor:input.text ?? "#00000080",
                    shadowOffset:input.points?.first ?? .init(x:8,y:8),shadowEnabled:input.flag ?? true)
            }
            if id == "image.patch" { return output }
            guard let region,let mask = ImageSelectionRasterizer.maskImage(for:region,canvas:.init(width:canvas.width,height:canvas.height)) else { return output }
            let blended = CIImage(cgImage:output).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(cgImage:image),kCIInputMaskImageKey:mask])
            guard let final = CIContext(options:[.cacheIntermediates:false]).createCGImage(blended,from:.init(x:0,y:0,width:canvas.width,height:canvas.height)) else { throw MediaV2CommandError.invalidInput }
            return final
        }
        let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation();guard selection == originalSelection else { throw MediaPreparedCoreError.documentChanged }
        let commit = try await commitRenderedImage(output,replacing:layer,revision:base,actor:actor)
        return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:commit.groupID,selectionOnly:false)
    }
}
#endif
