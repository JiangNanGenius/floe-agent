// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    func applyContentFill(_ tool:String,input:MediaV2ToolInput,layer:MediaPreparedLayer?,region:ImageSelection?,fencedSelection:Bool,actor:MediaPreparedActorKind,base:Int64,originalSelection:ImageSelection?) async throws -> MediaV2ToolReceipt {
        guard let layer,!layer.isLocked,layer.isVisible,layer.parentID==nil,![MediaPreparedLayerContentKind.group,.adjustment].contains(layer.contentKind),fencedSelection,let region,let canvas=document.canvas,
              canvas.width<=8192,canvas.height<=8192,canvas.width*canvas.height<=8_388_608 else { throw MediaV2CommandError.missingSelection }
        guard input.text==nil,let mode=MediaContentFillMode(rawValue:input.property ?? "adaptive") else { throw MediaV2CommandError.invalidInput }
        let expansion=input.number ?? 0,qualityValue=input.secondary ?? 1
        guard expansion.isFinite,(0...12).contains(expansion),qualityValue.isFinite,qualityValue.rounded()==qualityValue,(0...2).contains(qualityValue),let quality=MediaContentFillQuality(rawValue:Int(qualityValue)) else { throw MediaV2CommandError.invalidInput }
        let sourceBounds:NormalizedRect?
        if let points=input.points {
            guard points.count==2,points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}) else { throw MediaV2CommandError.invalidInput }
            sourceBounds = .init(x:min(points[0].x,points[1].x),y:min(points[0].y,points[1].y),width:abs(points[1].x-points[0].x),height:abs(points[1].y-points[0].y))
        } else { sourceBounds=nil }
        let source=try await renderedLayerImage(layer,revision:base),nearby=input.flag ?? true
        let computation=Task.detached(priority:.userInitiated) {
            let target:ImageSelection
            if expansion>0 { target = .init(bitmap:try MediaNativeSelection.refine(region,width:canvas.width,height:canvas.height,mode:.expand,amount:expansion)) } else { target=region }
            return try MediaNativeContentFill.fill(source,selection:target,mode:mode,quality:quality,nearbyOnly:nearby,samplingBounds:sourceBounds)
        }
        let output=try await withTaskCancellationHandler { try await computation.value } onCancel: { computation.cancel() }
        try Task.checkCancellation()
        guard document.revision==base,selection==originalSelection else { throw MediaPreparedCoreError.documentChanged }
        let commit=try await commitRenderedImage(output,replacing:layer,revision:base,actor:actor)
        return .init(documentID:document.id,revision:document.revision,toolID:tool,groupID:commit.groupID,selectionOnly:false)
    }
}
#endif
