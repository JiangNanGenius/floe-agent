// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import CryptoKit
import FloeWorkbench

extension MediaV2Session {
    func providerOutpaint(input:MediaV2ToolInput,actor:MediaPreparedActorKind,base:Int64,authority:MediaV2ProviderAuthority) async throws -> MediaV2ToolReceipt {
        guard project.kind == .image,input.objectID==nil,input.objectIDs==nil,let old=document.canvas,
              let width=input.number,let height=input.secondary,width.isFinite,height.isFinite,
              width.rounded()==width,height.rounded()==height,(1...8192).contains(width),(1...8192).contains(height),
              input.points == nil || input.points?.count==1,
              let prompt=input.text?.trimmingCharacters(in:.whitespacesAndNewlines),!prompt.isEmpty,prompt.utf8.count<=32_768 else {
            throw MediaV2CommandError.invalidInput
        }
        let layout=try MediaOutpaintLayout(sourceWidth:old.width,sourceHeight:old.height,width:Int(width),height:Int(height),anchor:input.points?.first ?? .init(x:0.5,y:0.5))
        if actor == .model,let locked=document.layers.first(where:{$0.parentID==nil && $0.isLocked}) {
            throw MediaPreparedCoreError.lockedObject(.init(kind:.layer,id:locked.id))
        }
        let modelID:UUID?
        if let supplied=input.property { guard let parsed=UUID(uuidString:supplied) else { throw MediaV2CommandError.invalidInput };modelID=parsed } else { modelID=nil }
        let frozen=document,assets=try resolvedAssets(),region=selection,sourcePoint=cloneSourcePoint,destinationPoint=cloneDestinationOrigin
        let next=MediaCanvas(width:layout.width,height:layout.height,frameRate:old.frameRate),mode=MediaCanvasLayoutMode.extendCanvas(anchor:layout.effectiveAnchor)
        canvasLayoutInProgress=true
        defer { canvasLayoutInProgress=false }
        providerStatus=WorkbenchText.t("正在准备扩展画布…", "Preparing expanded canvas…")
        // Render the whole editable graph without global canvas grading. That
        // existing grade will apply once to both old content and new margins.
        let image=try await imageRenderer.renderPrepared(frozen,canvas:.init(width:old.width,height:old.height),resolveAsset:{assets[$0]},applyCanvasAdjustment:false)
        let preparation=Task.detached(priority:.userInitiated) {
            let input=try MediaProviderOutpaintPixels.prepare(image,layout:layout)
            let digest=SHA256.hash(data:try MediaProviderEditPixels.pixelDigestInput(image)).map{String(format:"%02x",$0)}.joined()
            let selection=try region.flatMap { try MediaCanvasLayout.remapSelection($0,from:old,to:next,mode:mode) }
            return (input,digest,selection)
        }
        let (reference,digest,rebased)=try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try await authority.authorize(capability:.imageEditing,projectID:self.id,revision:base)
        guard document.revision==base,selection==region else { throw MediaPreparedCoreError.documentChanged }
        providerStatus=WorkbenchText.t("正在生成画布边缘…", "Generating canvas margins…")
        // Width/height identify the real target canvas, independently of the
        // bounded reference PNG dimensions used for transport.
        let response=try await MediaV2ProviderBridge.editImage(.init(sourcePNG:reference.sourcePNG,maskPNG:reference.maskPNG,prompt:prompt,modelID:modelID,width:layout.width,height:layout.height),authority:authority)
        try await authority.authorize(capability:.imageEditing,projectID:self.id,revision:base)
        guard document.revision==base,selection==region else { throw MediaPreparedCoreError.documentChanged }
        let currentAssets=try resolvedAssets()
        let current=try await imageRenderer.renderPrepared(frozen,canvas:.init(width:old.width,height:old.height),resolveAsset:{currentAssets[$0]},applyCanvasAdjustment:false)
        let composite=Task.detached(priority:.userInitiated) {
            let currentDigest=SHA256.hash(data:try MediaProviderEditPixels.pixelDigestInput(current)).map{String(format:"%02x",$0)}.joined()
            guard currentDigest==digest else { throw MediaPreparedCoreError.documentChanged }
            return try MediaProviderOutpaintPixels.margins(response.imageData,layout:layout)
        }
        let margins=try await withTaskCancellationHandler { try await composite.value } onCancel: { composite.cancel() }
        try Task.checkCancellation()
        try await authority.authorize(capability:.imageEditing,projectID:self.id,revision:base)
        guard document.revision==base,selection==region else { throw MediaPreparedCoreError.documentChanged }
        providerStatus=WorkbenchText.t("正在保存扩展画布…", "Saving expanded canvas…")
        let commit=try await commitOutpaintMargins(margins,layout:layout,revision:base,actor:actor)
        selection=rebased
        cloneSourcePoint=try sourcePoint.flatMap { try MediaCanvasLayout.remapPoint($0,from:old,to:next,mode:mode) }
        cloneDestinationOrigin=try destinationPoint.flatMap { try MediaCanvasLayout.remapPoint($0,from:old,to:next,mode:mode) }
        polygonPoints=[]
        return .init(documentID:document.id,revision:document.revision,toolID:"image.outpaint",groupID:commit.groupID,selectionOnly:false)
    }
}
#endif
