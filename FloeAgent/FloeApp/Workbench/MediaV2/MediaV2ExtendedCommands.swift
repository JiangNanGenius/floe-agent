// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import CoreImage
import FloeWorkbench

extension MediaV2Session {
    static let extendedColorTools:Set<String>=["image.curves","image.balance","image.lut","image.denoise"]
    static let extendedImageTools:Set<String>=["image.remove","image.content-fill","image.heal","image.patch","image.smudge","image.clone","image.gradient","image.blur-brush","image.sharpen-brush","image.layer-effect","image.wand","image.subject","image.refine-edge","image.expand","image.smooth","image.background","image.curves","image.balance","image.lut","image.denoise"]
    func performExtendedImageTool(_ id:String,input:MediaV2ToolInput,layer:MediaPreparedLayer?,region:ImageSelection?,fencedSelection:Bool,actor:MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard !processingTool else{throw MediaPreparedCoreError.conflict("an image operation is running")}
        let base=document.revision,originalSelection=selection
        processingTool=true
        let worker=Task { @MainActor in
            try await executeExtendedImageTool(id,input:input,layer:layer,region:region,fencedSelection:fencedSelection,actor:actor,base:base,originalSelection:originalSelection)
        }
        cancelToolWork={worker.cancel()}
        defer{processingTool=false;cancelToolWork=nil}
        return try await withTaskCancellationHandler{try await worker.value}onCancel:{worker.cancel()}
    }
    private func executeExtendedImageTool(_ id:String,input:MediaV2ToolInput,layer:MediaPreparedLayer?,region:ImageSelection?,fencedSelection:Bool,actor:MediaPreparedActorKind,base:Int64,originalSelection:ImageSelection?) async throws -> MediaV2ToolReceipt {
        guard let canvas=document.canvas else{throw MediaV2CommandError.invalidInput}
        if ["image.remove","image.content-fill"].contains(id) {
            return try await applyContentFill(id,input:input,layer:layer,region:region,fencedSelection:fencedSelection,actor:actor,base:base,originalSelection:originalSelection)
        }
        if Self.nativePaintTools.contains(id) {
            return try await applyNativePaint(id,input:input,layer:layer,region:region,actor:actor,base:base,originalSelection:originalSelection)
        }
        if ["image.curves","image.balance","image.lut","image.denoise"].contains(id) {
            guard let layer,!layer.isLocked else{throw MediaV2CommandError.missingSelection}
            let image=try await renderedLayerImage(layer,revision:base)
            var controls=input.adjustment ?? .init()
            switch id {
            case "image.curves":controls.toneCurve=controls.toneCurve ?? input.points ?? [.init(x:0,y:0),.init(x:0.25,y:0.25),.init(x:0.5,y:0.5),.init(x:0.75,y:0.75),.init(x:1,y:1)]
            case "image.balance":controls.colorBalance=controls.colorBalance ?? .init(midtones:.init(red:input.number ?? 0,green:input.secondary ?? 0))
            case "image.lut":
                if let text=input.text {
                    if MediaNativeColor.supportedFilterIDs.contains(text){controls.filterID=text}
                    else{let parse=Task.detached(priority:.userInitiated){try ImageColorLUT.parseCube(text)};controls.colorLUT=try await withTaskCancellationHandler{try await parse.value}onCancel:{parse.cancel()}}
                }
                guard controls.colorLUT != nil || controls.filterID.map(MediaNativeColor.supportedFilterIDs.contains) == true else{throw MediaV2CommandError.invalidInput}
            default:controls.noiseReduction=controls.noiseReduction ?? input.number ?? 0.5;controls.sharpenRadius=controls.sharpenRadius ?? input.secondary ?? 20
            }
            controls.effectRegion=nil
            let adjustment=controls
            let native=Task.detached(priority:.userInitiated){let source=CIImage(cgImage:image);var result=try MediaNativeColor.apply(adjustment,to:source)
                if let region,let mask=ImageSelectionRasterizer.maskImage(for:region,canvas:CGSize(width:canvas.width,height:canvas.height)){result=result.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:source,kCIInputMaskImageKey:mask])}
                guard let output=CIContext(options:[.cacheIntermediates:false]).createCGImage(result,from:.init(x:0,y:0,width:canvas.width,height:canvas.height)) else{throw MediaV2CommandError.invalidInput};return output}
            let output=try await withTaskCancellationHandler{try await native.value}onCancel:{native.cancel()}
            try Task.checkCancellation();guard selection==originalSelection else{throw MediaPreparedCoreError.documentChanged}
            let commit=try await commitRenderedImage(output,replacing:layer,revision:base,actor:actor)
            return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:commit.groupID,selectionOnly:false)
        }
        let bitmap:ImageSelectionBitmap
        if id == "image.layer-mask",let region {
            bitmap=try MediaNativeSelection.flattened(region,width:canvas.width,height:canvas.height)
        } else if ["image.expand","image.smooth","image.refine-edge"].contains(id) {
            guard fencedSelection,let region else{throw MediaV2CommandError.missingSelection}
            let mode:MediaNativeSelection.Refinement=id == "image.expand" ? .expand:id == "image.smooth" ? .smooth:.refine
            let amount=input.number ?? 6
            let native=Task.detached(priority:.userInitiated){try MediaNativeSelection.refine(region,width:canvas.width,height:canvas.height,mode:mode,amount:amount)}
            bitmap=try await withTaskCancellationHandler{try await native.value}onCancel:{native.cancel()}
        }else{
            guard let layer,!layer.isLocked,layer.parentID==nil,layer.contentKind != .group else{throw MediaV2CommandError.missingSelection}
            let image=try await renderedLayerImage(layer,revision:base,maxEdge:2048)
            try Task.checkCancellation()
            if id == "image.wand" {
                guard let point=input.points?.first else{throw MediaV2CommandError.invalidInput}
                let tolerance=input.number ?? wandTolerance,contiguous=input.flag ?? true
                let native=Task.detached(priority:.userInitiated){try MediaNativeSelection.wand(image:image,point:point,tolerance:tolerance,contiguous:contiguous)}
                bitmap=try await withTaskCancellationHandler{try await native.value}onCancel:{native.cancel()}
            }else{bitmap=try await MediaSubjectMaskService.shared.foregroundMask(image)}
        }
        try Task.checkCancellation()
        guard document.revision==base,selection==originalSelection else{throw MediaPreparedCoreError.documentChanged}
        if id == "image.background" || id == "image.layer-mask" {
            guard let layer else{throw MediaV2CommandError.missingSelection}
            let image=try await renderedLayerImage(layer,revision:base)
            let native=Task.detached(priority:.userInitiated){
                let extent=CGRect(x:0,y:0,width:canvas.width,height:canvas.height)
                guard let mask=ImageSelectionRasterizer.maskImage(for:.init(bitmap:bitmap),canvas:extent.size) else{throw MediaV2CommandError.invalidInput}
                let result=CIImage(cgImage:image).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputMaskImageKey:mask,kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:extent)])
                guard let output=CIContext(options:[.cacheIntermediates:false]).createCGImage(result,from:extent) else{throw MediaV2CommandError.invalidInput};return output
            }
            let output=try await withTaskCancellationHandler{try await native.value}onCancel:{native.cancel()}
            let commit=try await commitRenderedImage(output,replacing:layer,revision:base,actor:actor)
            return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:commit.groupID,selectionOnly:false)
        }
        let operation=ImageSelectionOperation(rawValue:input.property ?? "replace") ?? .replace
        if actor == .model && operation != .replace && !fencedSelection{throw MediaV2CommandError.missingSelection}
        selection=try MediaNativeSelection.combine(bitmap,with:region,operation:operation)
        return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:nil,selectionOnly:true)
    }
}
#endif
