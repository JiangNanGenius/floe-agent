// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    func performCanvasTool(_ tool:String,input:MediaV2ToolInput,actor:MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard project.kind == .image,!processingTool,!saving,let old=document.canvas,
              let width=input.number,let height=input.secondary,width.isFinite,height.isFinite,
              width.rounded() == width,height.rounded() == height,(1...16_384).contains(width),(1...16_384).contains(height) else { throw MediaV2CommandError.invalidInput }
        let base=document.revision
        if actor == .model,input.expectedRevision != base { throw MediaPreparedCoreError.documentChanged }
        let mode:MediaCanvasLayoutMode = tool == "image.resize" ? .scaleImage:.extendCanvas(anchor:input.points?.first ?? .init(x:0.5,y:0.5))
        let actions=try MediaCanvasLayout.actions(document,width:Int(width),height:Int(height),mode:mode)
        guard !actions.isEmpty else { return .init(documentID:id,revision:base,toolID:tool,groupID:nil,selectionOnly:false) }
        let next=MediaCanvas(width:Int(width),height:Int(height),frameRate:old.frameRate)
        let originalSelection=selection,sourcePoint=cloneSourcePoint,destinationPoint=cloneDestinationOrigin
        processingTool=true;canvasLayoutInProgress=true
        let worker=Task { @MainActor in
            let preparation=Task.detached(priority:.userInitiated) {
                try originalSelection.flatMap { try MediaCanvasLayout.remapSelection($0,from:old,to:next,mode:mode) }
            }
            let rebased=try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            guard document.revision == base,selection == originalSelection else { throw MediaPreparedCoreError.documentChanged }
            let commit=try await apply(actions.map{.init(action:$0)},expectedRevision:base,actor:actor)
            selection=rebased
            cloneSourcePoint=try sourcePoint.flatMap { try MediaCanvasLayout.remapPoint($0,from:old,to:next,mode:mode) }
            cloneDestinationOrigin=try destinationPoint.flatMap { try MediaCanvasLayout.remapPoint($0,from:old,to:next,mode:mode) }
            polygonPoints=[]
            return MediaV2ToolReceipt(documentID:id,revision:document.revision,toolID:tool,groupID:commit.groupID,selectionOnly:false)
        }
        cancelToolWork={worker.cancel()}
        defer { processingTool=false;canvasLayoutInProgress=false;cancelToolWork=nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    func moveDisplayedLayer(_ layer:MediaPreparedLayer,delta:ImageFreehandStroke.Point,revision:Int64) {
        guard !saving,!canvasLayoutInProgress,document.revision == revision else { diagnostic=MediaPreparedCoreError.documentChanged.localizedDescription;return }
        do {
            let space=try MediaCanvasLayout.movedSpace(layer,in:document,delta:delta)
            Task { do { _ = try await apply([.init(action:.setLayerCanvasSpace(id:layer.id,expectedRevision:layer.revision,space:space))],expectedRevision:revision,actor:.user) } catch { diagnostic=error.localizedDescription } }
        } catch { diagnostic=error.localizedDescription }
    }
}
#endif
